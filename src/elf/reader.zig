// ElfFile — a parsed handle over BPF ELF64 LE bytes.
//
// Provides access to the header + section header table. Individual sections,
// symbols, and relocations are exposed via iterators added in C.2-C.4.
//
// Alignment note: we do NOT require the input slice to be 8-byte aligned.
// Instead, we @memcpy the header (64 bytes) and copy each section header on
// demand (64 bytes each). This costs ~1 KB of copies for typical ELFs but
// removes a fragile alignment constraint on the API.
//
// Spec: 03-technical-spec.md §2.2
// Tests: 05-test-spec.md §4.6

const std = @import("std");
const elf = std.elf;
const section_mod = @import("section.zig");
const symbol_mod = @import("symbol.zig");

pub const ParseError = error{
    /// Bytes too short to contain a 64-byte ELF header.
    TooShort,
    /// e_ident[0..4] != "\x7fELF".
    NotElf,
    /// e_ident[EI_CLASS] != ELFCLASS64.
    Not64Bit,
    /// e_ident[EI_DATA] != ELFDATA2LSB.
    NotLittleEndian,
    /// e_machine != EM_BPF (247).
    NotBpf,
    /// Section header table location or size doesn't fit within bytes.
    CorruptSectionTable,
    /// e_shstrndx out of range or points at a non-STRTAB section.
    BadShStrIndex,
};

pub const ElfFile = struct {
    /// Borrowed slice; the ElfFile does not own these bytes. Section `data`
    /// slices and `shstrtab` reference this buffer, so it must outlive the
    /// ElfFile.
    bytes: []const u8,
    /// ELF header (stored by value — 64 bytes copied at parse time to sidestep
    /// alignment issues).
    header: elf.Elf64_Ehdr,
    /// Offset of the section header table within `bytes`.
    sh_offset: usize,
    /// Number of section header entries.
    sh_count: u16,
    /// Section-header string table content (slice into `bytes`; safe because
    /// it's just a byte view, no alignment required).
    shstrtab: []const u8,

    /// Validate and parse the ELF header. On success, returns a handle that
    /// keeps a reference to `bytes` — the caller must keep `bytes` alive.
    pub fn parse(bytes: []const u8) ParseError!ElfFile {
        if (bytes.len < @sizeOf(elf.Elf64_Ehdr)) return ParseError.TooShort;

        // ELF magic.
        if (bytes[0] != 0x7f or bytes[1] != 'E' or bytes[2] != 'L' or bytes[3] != 'F') {
            return ParseError.NotElf;
        }
        // 64-bit.
        if (bytes[elf.EI.CLASS] != elf.ELFCLASS64) {
            return ParseError.Not64Bit;
        }
        // Little-endian.
        if (bytes[elf.EI.DATA] != elf.ELFDATA2LSB) {
            return ParseError.NotLittleEndian;
        }

        // Copy the header by value. @memcpy bypasses alignment requirements
        // of the destination extern struct.
        var hdr: elf.Elf64_Ehdr = undefined;
        @memcpy(std.mem.asBytes(&hdr), bytes[0..@sizeOf(elf.Elf64_Ehdr)]);

        if (hdr.e_machine != .BPF) return ParseError.NotBpf;

        // Validate the section header table location.
        const sh_count: u16 = hdr.e_shnum;
        const sh_entsize: usize = hdr.e_shentsize;
        const sh_off: usize = @intCast(hdr.e_shoff);
        if (sh_entsize != @sizeOf(elf.Elf64_Shdr)) return ParseError.CorruptSectionTable;
        if (sh_count > 0) {
            const table_end = sh_off + @as(usize, sh_count) * sh_entsize;
            if (table_end > bytes.len) return ParseError.CorruptSectionTable;
        }

        // Locate shstrtab via e_shstrndx.
        var shstrtab: []const u8 = &.{};
        if (sh_count > 0) {
            const idx: u16 = hdr.e_shstrndx;
            if (idx >= sh_count) return ParseError.BadShStrIndex;

            // Copy the strtab's section header to check its type and locate
            // the string data.
            const strtab_hdr_off = sh_off + @as(usize, idx) * sh_entsize;
            var strtab_hdr: elf.Elf64_Shdr = undefined;
            @memcpy(
                std.mem.asBytes(&strtab_hdr),
                bytes[strtab_hdr_off .. strtab_hdr_off + @sizeOf(elf.Elf64_Shdr)],
            );
            if (strtab_hdr.sh_type != elf.SHT_STRTAB) return ParseError.BadShStrIndex;

            const off: usize = @intCast(strtab_hdr.sh_offset);
            const size: usize = @intCast(strtab_hdr.sh_size);
            if (off + size > bytes.len) return ParseError.CorruptSectionTable;
            shstrtab = bytes[off .. off + size];
        }

        return ElfFile{
            .bytes = bytes,
            .header = hdr,
            .sh_offset = sh_off,
            .sh_count = sh_count,
            .shstrtab = shstrtab,
        };
    }

    /// Number of sections.
    pub fn sectionCount(self: ElfFile) usize {
        return self.sh_count;
    }

    /// Copy a section header by index. Asserts idx is in range.
    pub fn sectionHeaderAt(self: *const ElfFile, idx: u16) elf.Elf64_Shdr {
        std.debug.assert(idx < self.sh_count);
        const off = self.sh_offset + @as(usize, idx) * @sizeOf(elf.Elf64_Shdr);
        var shdr: elf.Elf64_Shdr = undefined;
        @memcpy(
            std.mem.asBytes(&shdr),
            self.bytes[off .. off + @sizeOf(elf.Elf64_Shdr)],
        );
        return shdr;
    }

    /// Iterator over all sections, in header order.
    pub fn iterSections(self: *const ElfFile) section_mod.SectionIter {
        return .{ .file = self, .index = 0 };
    }

    /// Direct lookup by section index.
    pub fn sectionByIndex(self: *const ElfFile, idx: u16) section_mod.SectionError!section_mod.Section {
        std.debug.assert(idx < self.sh_count);
        return section_mod.buildSection(self, idx);
    }

    /// Iterator over symbols in the requested symbol table (static .symtab
    /// or dynamic .dynsym). Returns SymbolError.NoSymbolTable if no table
    /// of that kind exists.
    pub fn iterSymbols(
        self: *const ElfFile,
        kind: symbol_mod.SymTableKind,
    ) symbol_mod.SymbolError!symbol_mod.SymbolIter {
        return symbol_mod.makeIter(self, kind);
    }
};

// ---- tests ----

const testing = std.testing;

/// Build a minimal valid BPF ELF64 header with no sections, for positive
/// tests. 64 bytes, all "required zero" fields zeroed.
fn makeMinimalHeader() [@sizeOf(elf.Elf64_Ehdr)]u8 {
    var out: [@sizeOf(elf.Elf64_Ehdr)]u8 = @splat(0);
    out[0] = 0x7f;
    out[1] = 'E';
    out[2] = 'L';
    out[3] = 'F';
    out[elf.EI.CLASS] = elf.ELFCLASS64;
    out[elf.EI.DATA] = elf.ELFDATA2LSB;
    out[elf.EI.VERSION] = 1;
    out[16] = 3;             // e_type = ET_DYN
    out[18] = 247;           // e_machine = EM_BPF
    out[20] = 1;             // e_version = 1
    out[52] = 64;            // e_ehsize
    out[58] = 64;            // e_shentsize
    return out;
}

test "parse rejects bytes shorter than ELF header (spec §8 #1)" {
    try testing.expectError(ParseError.TooShort, ElfFile.parse(&.{}));
    const short: [63]u8 = @splat(0);
    try testing.expectError(ParseError.TooShort, ElfFile.parse(&short));
}

test "parse rejects non-ELF magic (spec §8 #3)" {
    var bytes = makeMinimalHeader();
    bytes[0] = 0x42;
    try testing.expectError(ParseError.NotElf, ElfFile.parse(&bytes));
}

test "parse rejects 32-bit ELF (spec §8 #5)" {
    var bytes = makeMinimalHeader();
    bytes[elf.EI.CLASS] = elf.ELFCLASS32;
    try testing.expectError(ParseError.Not64Bit, ElfFile.parse(&bytes));
}

test "parse rejects big-endian ELF (spec §8 #4)" {
    var bytes = makeMinimalHeader();
    bytes[elf.EI.DATA] = elf.ELFDATA2MSB;
    try testing.expectError(ParseError.NotLittleEndian, ElfFile.parse(&bytes));
}

test "parse rejects e_machine != EM_BPF (spec §8 #2)" {
    var bytes = makeMinimalHeader();
    bytes[18] = 62;
    bytes[19] = 0;
    try testing.expectError(ParseError.NotBpf, ElfFile.parse(&bytes));
}

test "parse accepts a minimal header with no sections" {
    const bytes = makeMinimalHeader();
    const file = try ElfFile.parse(&bytes);
    try testing.expectEqual(@as(usize, 0), file.sectionCount());
    try testing.expect(file.header.e_machine == .BPF);
    try testing.expectEqual(elf.ELFCLASS64, file.header.e_ident[elf.EI.CLASS]);
}

// Real-file integration tests live in `tests/integration.zig` — @embedFile
// can't reach outside src/.
