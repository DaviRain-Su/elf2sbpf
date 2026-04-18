// Symbol — a zero-copy view of a single ELF symbol table entry.
//
// Given an ElfFile, call `iterSymbols()` to iterate every symbol in either
// the regular symbol table (SHT_SYMTAB) or the dynamic symbol table
// (SHT_DYNSYM), as selected by the SymTableKind argument.
//
// For byteparser's use:
//   - .symtab is where per-function symbols, rodata symbols, etc. live for
//     relocatable (.o) input ELFs — the Zig/clang output we ingest
//   - .dynsym is only present on linked .so files — we emit it, we don't
//     read it
//
// Same by-value memcpy pattern as Section (see 06-implementation-log.md §C.2
// for why): we can't assume input alignment, so each Elf64_Sym is copied.
//
// Spec: 03-technical-spec.md §2.2
// Tests: 05-test-spec.md §4.6

const std = @import("std");
const elf = std.elf;
const ElfFile = @import("reader.zig").ElfFile;

pub const SymbolError = error{
    /// No SHT_SYMTAB section found (or SHT_DYNSYM for the dynamic flavor).
    NoSymbolTable,
    /// The symbol table's sh_link points at an invalid / non-STRTAB section.
    BadStringTable,
    /// sh_entsize != sizeof(Elf64_Sym), or the table extends past bytes.
    CorruptSymbolTable,
    /// Symbol's st_name points past the string table.
    NameOutOfRange,
};

pub const SymTableKind = enum {
    symtab,  // SHT_SYMTAB — static symbol table (in .o files)
    dynsym,  // SHT_DYNSYM — dynamic symbol table (in .so files)
};

pub const SymbolKind = enum {
    NoType,     // STT_NOTYPE
    Object,     // STT_OBJECT — data
    Func,       // STT_FUNC — code
    Section,    // STT_SECTION — identifies a section
    File,       // STT_FILE
    Common,     // STT_COMMON
    Tls,        // STT_TLS
    Unknown,    // any other value
};

pub const SymbolBinding = enum {
    Local,      // STB_LOCAL
    Global,     // STB_GLOBAL
    Weak,       // STB_WEAK
    Unknown,    // any other value
};

/// Handle over a single symbol. `raw` is by-value to avoid input alignment
/// constraints; `name` is a slice into the string table (zero-copy).
pub const Symbol = struct {
    /// 0-based index into the symbol table.
    index: u32,
    /// Copy of the raw symbol entry.
    raw: elf.Elf64_Sym,
    /// Resolved symbol name (from linked string table). Empty for
    /// unnamed symbols (e.g. the first STN_UNDEF entry).
    name: []const u8,

    /// Section this symbol is defined in. null for SHN_UNDEF (0) and
    /// SHN_ABS (0xfff1) — these aren't ordinary section references.
    pub fn sectionIndex(self: Symbol) ?u16 {
        const idx = self.raw.st_shndx;
        if (idx == elf.SHN_UNDEF or idx == elf.SHN_ABS) return null;
        return idx;
    }

    /// Address within the symbol's defining section (or 0 for external symbols).
    pub fn address(self: Symbol) u64 {
        return self.raw.st_value;
    }

    /// Size in bytes of whatever the symbol names (0 for STT_SECTION typically).
    pub fn size(self: Symbol) u64 {
        return self.raw.st_size;
    }

    pub fn kind(self: Symbol) SymbolKind {
        return switch (self.raw.st_type()) {
            elf.STT_NOTYPE => .NoType,
            elf.STT_OBJECT => .Object,
            elf.STT_FUNC => .Func,
            elf.STT_SECTION => .Section,
            elf.STT_FILE => .File,
            5 => .Common,
            6 => .Tls,
            else => .Unknown,
        };
    }

    pub fn binding(self: Symbol) SymbolBinding {
        return switch (self.raw.st_bind()) {
            elf.STB_LOCAL => .Local,
            elf.STB_GLOBAL => .Global,
            elf.STB_WEAK => .Weak,
            else => .Unknown,
        };
    }
};

/// Iterator over symbols in the selected symbol table. Constructed via
/// `ElfFile.iterSymbols(kind)`; no allocator required — both the table
/// and the string table are referenced directly from the input bytes.
pub const SymbolIter = struct {
    file: *const ElfFile,
    /// Offset in `file.bytes` of the symbol table contents.
    table_offset: usize,
    /// Number of symbol entries in the table.
    count: u32,
    /// String table slice.
    strtab: []const u8,
    /// Current index, 0-based.
    index: u32 = 0,

    pub fn next(self: *SymbolIter) SymbolError!?Symbol {
        if (self.index >= self.count) return null;
        const idx = self.index;
        self.index += 1;

        const off = self.table_offset + @as(usize, idx) * @sizeOf(elf.Elf64_Sym);
        var sym: elf.Elf64_Sym = undefined;
        @memcpy(
            std.mem.asBytes(&sym),
            self.file.bytes[off .. off + @sizeOf(elf.Elf64_Sym)],
        );

        const name_off: usize = @intCast(sym.st_name);
        if (name_off >= self.strtab.len) return SymbolError.NameOutOfRange;
        const name = cstrAt(self.strtab, name_off);

        return Symbol{
            .index = idx,
            .raw = sym,
            .name = name,
        };
    }
};

/// Locate the symbol table (SHT_SYMTAB or SHT_DYNSYM), validate its layout
/// and linked string table, and return a ready-to-use iterator.
///
/// If no matching symbol table exists, returns SymbolError.NoSymbolTable —
/// callers can treat that as "no symbols" rather than a hard error.
pub fn makeIter(file: *const ElfFile, kind: SymTableKind) SymbolError!SymbolIter {
    const want_type: u32 = switch (kind) {
        .symtab => elf.SHT_SYMTAB,
        .dynsym => elf.SHT_DYNSYM,
    };

    // Scan section headers for the symbol table.
    var i: u16 = 0;
    while (i < file.sh_count) : (i += 1) {
        const sh = file.sectionHeaderAt(i);
        if (sh.sh_type != want_type) continue;

        // Validate entry size and table bounds.
        const ent: usize = @intCast(sh.sh_entsize);
        const sz: usize = @intCast(sh.sh_size);
        const off: usize = @intCast(sh.sh_offset);
        if (ent != @sizeOf(elf.Elf64_Sym)) return SymbolError.CorruptSymbolTable;
        if (off + sz > file.bytes.len) return SymbolError.CorruptSymbolTable;
        if (sz % ent != 0) return SymbolError.CorruptSymbolTable;

        const count: u32 = @intCast(sz / ent);

        // Resolve linked string table via sh_link.
        const link_raw = sh.sh_link;
        if (link_raw > std.math.maxInt(u16)) return SymbolError.BadStringTable;
        const link_idx: u16 = @intCast(link_raw);
        if (link_idx >= file.sh_count) return SymbolError.BadStringTable;
        const strtab_hdr = file.sectionHeaderAt(link_idx);
        if (strtab_hdr.sh_type != elf.SHT_STRTAB) return SymbolError.BadStringTable;
        const strtab_off: usize = @intCast(strtab_hdr.sh_offset);
        const strtab_sz: usize = @intCast(strtab_hdr.sh_size);
        if (strtab_off + strtab_sz > file.bytes.len) return SymbolError.BadStringTable;
        const strtab = file.bytes[strtab_off .. strtab_off + strtab_sz];

        return SymbolIter{
            .file = file,
            .table_offset = off,
            .count = count,
            .strtab = strtab,
        };
    }

    return SymbolError.NoSymbolTable;
}

fn cstrAt(buf: []const u8, offset: usize) []const u8 {
    if (offset >= buf.len) return "";
    var end = offset;
    while (end < buf.len and buf[end] != 0) : (end += 1) {}
    return buf[offset..end];
}

// --- tests ---

const testing = std.testing;

/// Builds a synthetic ELF with: NULL / .symtab / .strtab / .shstrtab.
/// .symtab has 3 entries: [STN_UNDEF, entrypoint (FUNC, GLOBAL), foo (OBJECT, LOCAL)].
///
/// Layout:
///   0     Elf64_Ehdr                    (64 bytes)
///  64    section header [0] NULL        (64)
/// 128    section header [1] .symtab     (64)
/// 192    section header [2] .strtab     (64)
/// 256    section header [3] .shstrtab   (64)
/// 320    .symtab contents (3 × 24)      (72)
/// 392    .strtab contents               (varies)
/// ...    .shstrtab contents
fn makeSymtabElf(out: *[512]u8) void {
    @memset(out, 0);

    // --- strtab content: "\0entrypoint\0foo\0"
    // offsets: 0 -> "", 1 -> "entrypoint", 12 -> "foo"
    const strtab_off: usize = 392;
    const strtab_content = "\x00entrypoint\x00foo\x00"; // 16 bytes
    @memcpy(out[strtab_off .. strtab_off + strtab_content.len], strtab_content);

    // --- shstrtab content: "\0.symtab\0.strtab\0.shstrtab\0"
    const shstrtab_off: usize = 408;
    const shstrtab_content = "\x00.symtab\x00.strtab\x00.shstrtab\x00"; // 27 bytes
    @memcpy(out[shstrtab_off .. shstrtab_off + shstrtab_content.len], shstrtab_content);

    // --- Elf64_Ehdr ---
    out[0] = 0x7f; out[1] = 'E'; out[2] = 'L'; out[3] = 'F';
    out[elf.EI.CLASS] = elf.ELFCLASS64;
    out[elf.EI.DATA] = elf.ELFDATA2LSB;
    out[elf.EI.VERSION] = 1;
    out[16] = 3;
    out[18] = 247;
    out[20] = 1;
    std.mem.writeInt(u64, out[40..48], 64, .little); // e_shoff
    out[52] = 64;
    out[58] = 64;
    out[60] = 4;   // e_shnum (4 sections)
    out[62] = 3;   // e_shstrndx = index of .shstrtab

    // --- Section header [1]: .symtab at offset 128 ---
    std.mem.writeInt(u32, out[128..132], 1, .little);    // sh_name: ".symtab" starts at 1
    std.mem.writeInt(u32, out[132..136], elf.SHT_SYMTAB, .little);
    std.mem.writeInt(u64, out[152..160], 320, .little);  // sh_offset
    std.mem.writeInt(u64, out[160..168], 72, .little);   // sh_size (3 × 24)
    std.mem.writeInt(u32, out[168..172], 2, .little);    // sh_link → .strtab at idx 2
    std.mem.writeInt(u64, out[184..192], 24, .little);   // sh_entsize

    // --- Section header [2]: .strtab at offset 192 ---
    std.mem.writeInt(u32, out[192..196], 9, .little);    // sh_name: ".strtab" at 9
    std.mem.writeInt(u32, out[196..200], elf.SHT_STRTAB, .little);
    std.mem.writeInt(u64, out[216..224], 392, .little);  // sh_offset
    std.mem.writeInt(u64, out[224..232], 16, .little);   // sh_size

    // --- Section header [3]: .shstrtab at offset 256 ---
    std.mem.writeInt(u32, out[256..260], 17, .little);   // sh_name: ".shstrtab" at 17
    std.mem.writeInt(u32, out[260..264], elf.SHT_STRTAB, .little);
    std.mem.writeInt(u64, out[280..288], 408, .little);  // sh_offset
    std.mem.writeInt(u64, out[288..296], 27, .little);   // sh_size

    // --- Symbol table content at offset 320 (3 × 24 = 72 bytes) ---
    const sym_base: usize = 320;

    // Symbol 0: STN_UNDEF (all zeros — already memset)

    // Symbol 1: "entrypoint", FUNC + GLOBAL, section 1, value 0, size 64
    const sym1 = sym_base + 24;
    std.mem.writeInt(u32, out[sym1 .. sym1 + 4][0..4], 1, .little);  // st_name: "entrypoint" at 1
    out[sym1 + 4] = (@as(u8, elf.STB_GLOBAL) << 4) | @as(u8, elf.STT_FUNC); // st_info
    out[sym1 + 5] = 0;                                               // st_other
    std.mem.writeInt(u16, out[sym1 + 6 .. sym1 + 8][0..2], 1, .little); // st_shndx: section 1
    std.mem.writeInt(u64, out[sym1 + 8 .. sym1 + 16][0..8], 0, .little); // st_value
    std.mem.writeInt(u64, out[sym1 + 16 .. sym1 + 24][0..8], 64, .little); // st_size

    // Symbol 2: "foo", OBJECT + LOCAL, SHN_UNDEF, value 0, size 0
    const sym2 = sym_base + 48;
    std.mem.writeInt(u32, out[sym2 .. sym2 + 4][0..4], 12, .little); // st_name: "foo" at 12
    out[sym2 + 4] = (@as(u8, elf.STB_LOCAL) << 4) | @as(u8, elf.STT_OBJECT);
    out[sym2 + 5] = 0;
    std.mem.writeInt(u16, out[sym2 + 6 .. sym2 + 8][0..2], elf.SHN_UNDEF, .little);
}

test "iterSymbols: iterate all 3 symbols and decode fields" {
    var bytes: [512]u8 = undefined;
    makeSymtabElf(&bytes);

    const file = try ElfFile.parse(&bytes);
    var it = try makeIter(&file, .symtab);

    // Symbol 0: STN_UNDEF
    const s0 = (try it.next()).?;
    try testing.expectEqual(@as(u32, 0), s0.index);
    try testing.expectEqualStrings("", s0.name);
    try testing.expectEqual(SymbolKind.NoType, s0.kind());
    try testing.expectEqual(SymbolBinding.Local, s0.binding());
    try testing.expectEqual(@as(?u16, null), s0.sectionIndex());

    // Symbol 1: "entrypoint", FUNC GLOBAL, section 1, value 0, size 64
    const s1 = (try it.next()).?;
    try testing.expectEqual(@as(u32, 1), s1.index);
    try testing.expectEqualStrings("entrypoint", s1.name);
    try testing.expectEqual(SymbolKind.Func, s1.kind());
    try testing.expectEqual(SymbolBinding.Global, s1.binding());
    try testing.expectEqual(@as(?u16, 1), s1.sectionIndex());
    try testing.expectEqual(@as(u64, 0), s1.address());
    try testing.expectEqual(@as(u64, 64), s1.size());

    // Symbol 2: "foo", OBJECT LOCAL, SHN_UNDEF
    const s2 = (try it.next()).?;
    try testing.expectEqual(@as(u32, 2), s2.index);
    try testing.expectEqualStrings("foo", s2.name);
    try testing.expectEqual(SymbolKind.Object, s2.kind());
    try testing.expectEqual(SymbolBinding.Local, s2.binding());
    try testing.expectEqual(@as(?u16, null), s2.sectionIndex());

    // End.
    try testing.expectEqual(@as(?Symbol, null), try it.next());
}

test "iterSymbols: NoSymbolTable when no SHT_SYMTAB present" {
    // Minimal header with no sections — no symbol table.
    var out: [@sizeOf(elf.Elf64_Ehdr)]u8 = @splat(0);
    out[0] = 0x7f; out[1] = 'E'; out[2] = 'L'; out[3] = 'F';
    out[elf.EI.CLASS] = elf.ELFCLASS64;
    out[elf.EI.DATA] = elf.ELFDATA2LSB;
    out[elf.EI.VERSION] = 1;
    out[16] = 3; out[18] = 247; out[20] = 1;
    out[52] = 64;
    out[58] = 64;
    const file = try ElfFile.parse(&out);
    try testing.expectError(SymbolError.NoSymbolTable, makeIter(&file, .symtab));
}

test "iterSymbols: dynsym flavor returns NoSymbolTable for a .symtab-only ELF" {
    var bytes: [512]u8 = undefined;
    makeSymtabElf(&bytes);
    const file = try ElfFile.parse(&bytes);
    try testing.expectError(SymbolError.NoSymbolTable, makeIter(&file, .dynsym));
}

test "iterSymbols: NameOutOfRange when st_name equals strtab size" {
    var bytes: [512]u8 = undefined;
    makeSymtabElf(&bytes);

    // Symbol 1 starts at 320 + 24. Set st_name to .strtab size (=16),
    // which is one-past-end and must be rejected.
    const sym1 = 320 + 24;
    std.mem.writeInt(u32, bytes[sym1 .. sym1 + 4][0..4], 16, .little);

    const file = try ElfFile.parse(&bytes);
    var it = try makeIter(&file, .symtab);

    // STN_UNDEF first symbol still parses.
    _ = (try it.next()).?;
    // Next symbol name offset is exactly at end of strtab -> error.
    try testing.expectError(SymbolError.NameOutOfRange, it.next());
}

test "makeIter: BadStringTable when sh_link does not fit u16" {
    var bytes: [512]u8 = undefined;
    makeSymtabElf(&bytes);

    // .symtab section header is at offset 128; sh_link field at 168..172.
    // Force a value larger than u16 max to validate guarded cast.
    std.mem.writeInt(u32, bytes[168..172], 70000, .little);

    const file = try ElfFile.parse(&bytes);
    try testing.expectError(SymbolError.BadStringTable, makeIter(&file, .symtab));
}
