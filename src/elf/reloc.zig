// Relocation — a zero-copy view of a single ELF relocation entry.
//
// For BPF ELF objects we target, relocations live in SHT_REL sections (no
// explicit addend — the addend is hidden inside the relocated instruction's
// immediate field). SHT_RELA is also accepted here so that future tooling
// can feed us its output, but byteparser only needs SHT_REL for today's
// zignocchio fixtures.
//
// The type field (spec §7.3) distinguishes lddw targets (R_BPF_64_64) from
// call targets (R_BPF_64_32) — byteparser dispatches on this.
//
// Same by-value + memcpy pattern as C.2/C.3 (arbitrary input alignment).
//
// Spec: 03-technical-spec.md §2.2
// Tests: 05-test-spec.md §4.6

const std = @import("std");
const elf = std.elf;
const ElfFile = @import("reader.zig").ElfFile;
const section_mod = @import("section.zig");

pub const RelocError = error{
    /// The provided section is not a SHT_REL or SHT_RELA.
    NotARelocationSection,
    /// sh_entsize doesn't match the expected Elf64_Rel/Rela size.
    CorruptRelocationTable,
    /// Section contents extend past the file bytes.
    OutOfRange,
};

/// BPF-specific relocation types. Values taken from
/// 03-technical-spec.md §7.3, which cross-references the LLVM BPF backend.
pub const RelocType = enum(u32) {
    BPF_64_64 = 1,        // 64-bit absolute (lddw target)
    BPF_64_ABS64 = 2,     // alternative encoding for the same meaning
    BPF_64_ABS32 = 3,
    BPF_64_NODYLD32 = 4,
    BPF_64_32 = 10,       // 32-bit PC-relative (call target)
    _,                    // non-exhaustive: any future BPF reloc type
};

/// A single decoded relocation entry. Works for both Elf64_Rel (no addend,
/// `addend` is null) and Elf64_Rela (addend explicit).
pub const Reloc = struct {
    /// Index within the containing section's relocation list.
    index: u32,
    /// Offset of the target instruction within the **section this relocation
    /// applies to** (determined by the sh_info of the REL section).
    offset: u64,
    /// Raw relocation type byte. Convert via `kind()`.
    type_raw: u32,
    /// Index into the associated symbol table of the target symbol.
    symbol_index: u32,
    /// Explicit addend for SHT_RELA; null for SHT_REL (where the addend is
    /// embedded in the target instruction's immediate field).
    addend: ?i64,

    /// Typed view of the relocation type. Unknown / Solana-specific types
    /// map to the non-exhaustive `_` case.
    pub fn kind(self: Reloc) RelocType {
        return @enumFromInt(self.type_raw);
    }
};

/// Iterator over one relocation section's entries.
pub const RelocIter = struct {
    file: *const ElfFile,
    table_offset: usize,
    count: u32,
    /// Size of one entry: 16 for Elf64_Rel, 24 for Elf64_Rela.
    entry_size: usize,
    /// True if this is SHT_RELA (entries carry r_addend); false for SHT_REL.
    has_addend: bool,
    index: u32 = 0,

    pub fn next(self: *RelocIter) ?Reloc {
        if (self.index >= self.count) return null;
        const idx = self.index;
        self.index += 1;

        const off = self.table_offset + @as(usize, idx) * self.entry_size;
        if (self.has_addend) {
            var r: elf.Elf64_Rela = undefined;
            @memcpy(
                std.mem.asBytes(&r),
                self.file.bytes[off .. off + @sizeOf(elf.Elf64_Rela)],
            );
            return Reloc{
                .index = idx,
                .offset = r.r_offset,
                .type_raw = r.r_type(),
                .symbol_index = r.r_sym(),
                .addend = r.r_addend,
            };
        } else {
            var r: elf.Elf64_Rel = undefined;
            @memcpy(
                std.mem.asBytes(&r),
                self.file.bytes[off .. off + @sizeOf(elf.Elf64_Rel)],
            );
            return Reloc{
                .index = idx,
                .offset = r.r_offset,
                .type_raw = r.r_type(),
                .symbol_index = r.r_sym(),
                .addend = null,
            };
        }
    }
};

/// Build an iterator for the relocations defined by `rel_section`.
/// `rel_section` must itself be a SHT_REL or SHT_RELA; callers locate it
/// either by name (".rel.text", ".rela.text") or by `sh_info` pointing to
/// the relocated section.
pub fn makeIter(file: *const ElfFile, rel_section: section_mod.Section) RelocError!RelocIter {
    const has_addend = switch (rel_section.kind()) {
        elf.SHT_REL => false,
        elf.SHT_RELA => true,
        else => return RelocError.NotARelocationSection,
    };

    const expected_entsize: usize = if (has_addend)
        @sizeOf(elf.Elf64_Rela)
    else
        @sizeOf(elf.Elf64_Rel);

    const entsize: usize = @intCast(rel_section.header.sh_entsize);
    if (entsize != expected_entsize) return RelocError.CorruptRelocationTable;

    const size: usize = @intCast(rel_section.header.sh_size);
    const offset: usize = @intCast(rel_section.header.sh_offset);
    if (offset + size > file.bytes.len) return RelocError.OutOfRange;
    if (size % entsize != 0) return RelocError.CorruptRelocationTable;

    const count: u32 = @intCast(size / entsize);
    return RelocIter{
        .file = file,
        .table_offset = offset,
        .count = count,
        .entry_size = entsize,
        .has_addend = has_addend,
    };
}

// --- tests ---

const testing = std.testing;

/// Build a 4-section ELF: NULL, .text, .rel.text, .shstrtab. .rel.text
/// has 2 entries targeting offsets 0x10 and 0x20 in .text.
///
/// Byte layout:
///   0     Elf64_Ehdr                    (64)
///  64    SH[0] NULL                     (64)
/// 128    SH[1] .text                    (64)
/// 192    SH[2] .rel.text                (64)
/// 256    SH[3] .shstrtab                (64)
/// 320    .text data (16 bytes, zeros)
/// 336    .rel.text data (2 × 16)
/// 368    .shstrtab
fn makeRelElf(out: *[512]u8) void {
    @memset(out, 0);

    // --- shstrtab: "\0.text\0.rel.text\0.shstrtab\0"
    //  offsets: 0='', 1='.text', 7='.rel.text', 17='.shstrtab'
    const shstrtab_off: usize = 368;
    const shstrtab_content = "\x00.text\x00.rel.text\x00.shstrtab\x00";
    @memcpy(out[shstrtab_off .. shstrtab_off + shstrtab_content.len], shstrtab_content);

    // --- Ehdr ---
    out[0] = 0x7f; out[1] = 'E'; out[2] = 'L'; out[3] = 'F';
    out[elf.EI.CLASS] = elf.ELFCLASS64;
    out[elf.EI.DATA] = elf.ELFDATA2LSB;
    out[elf.EI.VERSION] = 1;
    out[16] = 3; out[18] = 247; out[20] = 1;
    std.mem.writeInt(u64, out[40..48], 64, .little);
    out[52] = 64; out[58] = 64;
    out[60] = 4;    // e_shnum
    out[62] = 3;    // e_shstrndx

    // --- SH[1]: .text at offset 128 ---
    std.mem.writeInt(u32, out[128..132], 1, .little);
    std.mem.writeInt(u32, out[132..136], elf.SHT_PROGBITS, .little);
    std.mem.writeInt(u64, out[152..160], 320, .little); // sh_offset
    std.mem.writeInt(u64, out[160..168], 16, .little);  // sh_size

    // --- SH[2]: .rel.text at offset 192 ---
    std.mem.writeInt(u32, out[192..196], 7, .little);   // sh_name
    std.mem.writeInt(u32, out[196..200], elf.SHT_REL, .little);
    std.mem.writeInt(u64, out[216..224], 336, .little); // sh_offset
    std.mem.writeInt(u64, out[224..232], 32, .little);  // sh_size (2 × 16)
    std.mem.writeInt(u32, out[232..236], 0, .little);   // sh_link: symtab idx (unused here)
    std.mem.writeInt(u32, out[236..240], 1, .little);   // sh_info: which section relocated (= 1 for .text)
    std.mem.writeInt(u64, out[248..256], 16, .little);  // sh_entsize

    // --- SH[3]: .shstrtab at offset 256 ---
    std.mem.writeInt(u32, out[256..260], 17, .little);  // sh_name
    std.mem.writeInt(u32, out[260..264], elf.SHT_STRTAB, .little);
    std.mem.writeInt(u64, out[280..288], shstrtab_off, .little);
    std.mem.writeInt(u64, out[288..296], 27, .little);

    // --- .rel.text data at offset 336 (2 × Elf64_Rel = 32 bytes) ---
    // Reloc 0: offset=0x10, type=R_BPF_64_64 (=1), sym=0x42
    // r_info = (sym << 32) | type  →  (0x42 << 32) | 1
    std.mem.writeInt(u64, out[336..344], 0x10, .little); // r_offset
    const r0_info: u64 = (@as(u64, 0x42) << 32) | 1;
    std.mem.writeInt(u64, out[344..352], r0_info, .little);

    // Reloc 1: offset=0x20, type=R_BPF_64_32 (=10), sym=0x13
    std.mem.writeInt(u64, out[352..360], 0x20, .little);
    const r1_info: u64 = (@as(u64, 0x13) << 32) | 10;
    std.mem.writeInt(u64, out[360..368], r1_info, .little);
}

test "iterRelocs: decode SHT_REL section with 2 entries" {
    var bytes: [512]u8 = undefined;
    makeRelElf(&bytes);

    const file = try ElfFile.parse(&bytes);
    const rel_section = try file.sectionByIndex(2);
    try testing.expectEqual(@as(u32, elf.SHT_REL), rel_section.kind());

    var it = try makeIter(&file, rel_section);
    try testing.expectEqual(@as(u32, 2), it.count);
    try testing.expectEqual(false, it.has_addend);

    const r0 = it.next().?;
    try testing.expectEqual(@as(u64, 0x10), r0.offset);
    try testing.expectEqual(@as(u32, 0x42), r0.symbol_index);
    try testing.expectEqual(RelocType.BPF_64_64, r0.kind());
    try testing.expectEqual(@as(?i64, null), r0.addend);

    const r1 = it.next().?;
    try testing.expectEqual(@as(u64, 0x20), r1.offset);
    try testing.expectEqual(@as(u32, 0x13), r1.symbol_index);
    try testing.expectEqual(RelocType.BPF_64_32, r1.kind());

    try testing.expectEqual(@as(?Reloc, null), it.next());
}

test "iterRelocs: rejects non-relocation section" {
    var bytes: [512]u8 = undefined;
    makeRelElf(&bytes);
    const file = try ElfFile.parse(&bytes);

    // Section 1 is .text (SHT_PROGBITS) — not a relocation section.
    const text = try file.sectionByIndex(1);
    try testing.expectError(RelocError.NotARelocationSection, makeIter(&file, text));
}

test "RelocType is non-exhaustive (unknown values preserved)" {
    const r = Reloc{
        .index = 0, .offset = 0, .type_raw = 999, .symbol_index = 0, .addend = null,
    };
    // 999 is not one of the named variants, but @enumFromInt into a
    // non-exhaustive enum should still yield a valid enum value.
    const k = r.kind();
    try testing.expectEqual(@as(u32, 999), @intFromEnum(k));
}
