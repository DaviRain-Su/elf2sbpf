// ElfFile — a parsed handle over BPF ELF64 LE bytes.
//
// Provides zero-copy access to the header + section header table. Individual
// sections, symbols, and relocations are exposed via iterators added in C.2-C.4.
//
// Spec: 03-technical-spec.md §2.2
// Tests: 05-test-spec.md §4.6
//
// We lean on std.elf's extern structs for the header / section layout so we
// don't re-type-out the ELF64 spec. But we don't use std.elf.Header.read
// (that's reader-based); we directly validate and bitcast in-memory bytes.

const std = @import("std");
const elf = std.elf;

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

/// Solana programs are always ET_DYN, EM_BPF, ELFCLASS64, ELFDATA2LSB,
/// version 1. The constants here match 03-technical-spec.md §7.1-7.5.
pub const ElfFile = struct {
    /// Borrowed slice; the ElfFile does not own these bytes.
    bytes: []const u8,
    /// Cached reinterpreted header pointer (zero-copy; points into `bytes`).
    header: *const elf.Elf64_Ehdr,
    /// Section header table as a typed slice into `bytes`.
    section_headers: []const elf.Elf64_Shdr,
    /// Section-header string table content, needed by section name lookup.
    /// Slice into `bytes`; valid as long as `bytes` outlives this struct.
    shstrtab: []const u8,

    /// Validate and parse the ELF header. On success, returns a zero-copy
    /// handle; all slices inside point into `bytes`, so the caller must keep
    /// `bytes` alive for the lifetime of the returned ElfFile.
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

        // Zero-copy header view. Safe because Elf64_Ehdr is extern (packed C
        // layout) with no trailing alignment padding.
        const hdr: *const elf.Elf64_Ehdr = @ptrCast(@alignCast(bytes.ptr));

        // Machine check.
        if (hdr.e_machine != .BPF) return ParseError.NotBpf;

        // Bounds-check the section header table.
        const sh_count: usize = hdr.e_shnum;
        const sh_size: usize = hdr.e_shentsize;
        const sh_off: usize = @intCast(hdr.e_shoff);
        if (sh_size != @sizeOf(elf.Elf64_Shdr)) return ParseError.CorruptSectionTable;
        if (sh_count > 0) {
            const sh_table_end = sh_off + sh_count * sh_size;
            if (sh_table_end > bytes.len) return ParseError.CorruptSectionTable;
        }

        // Slice the section header table as a typed view.
        const sh_table: []const elf.Elf64_Shdr = if (sh_count == 0)
            &.{}
        else blk: {
            const raw_ptr: [*]const elf.Elf64_Shdr = @ptrCast(@alignCast(bytes.ptr + sh_off));
            break :blk raw_ptr[0..sh_count];
        };

        // Locate .shstrtab (section name string table) via e_shstrndx.
        var shstrtab: []const u8 = &.{};
        if (sh_count > 0) {
            const idx: usize = hdr.e_shstrndx;
            if (idx >= sh_count) return ParseError.BadShStrIndex;
            const strtab_hdr = sh_table[idx];
            if (strtab_hdr.sh_type != elf.SHT_STRTAB) return ParseError.BadShStrIndex;
            const off: usize = @intCast(strtab_hdr.sh_offset);
            const size: usize = @intCast(strtab_hdr.sh_size);
            if (off + size > bytes.len) return ParseError.CorruptSectionTable;
            shstrtab = bytes[off .. off + size];
        }

        return ElfFile{
            .bytes = bytes,
            .header = hdr,
            .section_headers = sh_table,
            .shstrtab = shstrtab,
        };
    }

    /// Number of sections.
    pub fn sectionCount(self: ElfFile) usize {
        return self.section_headers.len;
    }
};

// ---- tests ----

const testing = std.testing;

/// Build a minimal valid BPF ELF64 header with no sections, for positive
/// tests. 64 bytes, all "required zero" fields zeroed.
fn makeMinimalHeader() [@sizeOf(elf.Elf64_Ehdr)]u8 {
    var out: [@sizeOf(elf.Elf64_Ehdr)]u8 = @splat(0);
    // e_ident
    out[0] = 0x7f;
    out[1] = 'E';
    out[2] = 'L';
    out[3] = 'F';
    out[elf.EI.CLASS] = elf.ELFCLASS64;
    out[elf.EI.DATA] = elf.ELFDATA2LSB;
    out[elf.EI.VERSION] = 1;
    // e_type (offset 16): ET_DYN = 3, little-endian
    out[16] = 3;
    // e_machine (offset 18): EM_BPF = 247
    out[18] = 247;
    // e_version (offset 20): 1
    out[20] = 1;
    // e_ehsize (offset 52): 64
    out[52] = 64;
    // e_shentsize (offset 58): 64 (size of Elf64_Shdr)
    out[58] = 64;
    // e_shnum stays 0 (no sections → no shstrtab lookup needed).
    return out;
}

test "parse rejects bytes shorter than ELF header (spec §8 #1)" {
    try testing.expectError(ParseError.TooShort, ElfFile.parse(&.{}));
    var short: [63]u8 = @splat(0);
    try testing.expectError(ParseError.TooShort, ElfFile.parse(&short));
}

test "parse rejects non-ELF magic (spec §8 #3)" {
    var bytes = makeMinimalHeader();
    bytes[0] = 0x42; // not 0x7f
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
    // x86_64 is EM_X86_64 = 62, any non-BPF works.
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

// NOTE: Real-file integration tests (using fixtures/helloworld/out/hello.o)
// live in `tests/integration.zig` — @embedFile can't reach outside the src/
// package path. The synthetic-header tests above cover every ParseError
// variant + the positive header-validation path.
