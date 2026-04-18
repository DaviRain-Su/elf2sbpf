// Section — a zero-copy view of a single ELF section.
//
// Given an ElfFile, `iterSections()` yields a Section for every entry in the
// section header table. Section exposes the three pieces byteparser cares
// about: name (resolved via shstrtab), data (slice of the original bytes),
// and the raw Elf64_Shdr flags/size/type.
//
// Spec: 03-technical-spec.md §2.2
// Tests: 05-test-spec.md §4.6

const std = @import("std");
const elf = std.elf;
const ElfFile = @import("reader.zig").ElfFile;
const util = @import("../common/util.zig");

pub const SectionError = error{
    IndexOutOfRange, // section index >= sh_count
    NameOutOfRange, // sh_name points outside shstrtab
    DataOutOfRange, // sh_offset + sh_size > bytes.len (for PROGBITS-style)
};

/// Zero-copy handle over one section. `header` is by value (64 bytes copied
/// on demand) to avoid imposing alignment requirements on the input bytes.
/// `name` and `data` are slices into the ElfFile's byte buffer.
pub const Section = struct {
    /// 0-based index into the section header table.
    index: u16,
    /// Copy of the section header entry.
    header: elf.Elf64_Shdr,
    /// Resolved section name (from shstrtab). Empty string for the NULL
    /// section at index 0.
    name: []const u8,
    /// Raw section bytes. For SHT_NULL and SHT_NOBITS sections this is empty.
    data: []const u8,

    /// Section header flags (SHF_*, bit-ORed u64).
    pub fn flags(self: Section) u64 {
        return self.header.sh_flags;
    }

    /// Size in bytes as declared by the section header.
    pub fn size(self: Section) u64 {
        return self.header.sh_size;
    }

    /// Section type (SHT_* constant as u32).
    pub fn kind(self: Section) u32 {
        return self.header.sh_type;
    }
};

/// Iterator over all sections in an ElfFile. Usage:
///     var it = file.iterSections();
///     while (try it.next()) |section| { ... }
pub const SectionIter = struct {
    file: *const ElfFile,
    index: u16 = 0,

    /// Returns the next section, or null when the iterator is exhausted.
    /// Returns an error if the current section's header references bytes
    /// outside the ELF file (corrupt input).
    pub fn next(self: *SectionIter) SectionError!?Section {
        if (self.index >= self.file.sh_count) return null;
        const idx = self.index;
        self.index += 1;
        return try buildSection(self.file, idx);
    }
};

/// Resolve a single section by index. Used by both the iterator and
/// direct `sectionByIndex` lookups.
pub fn buildSection(file: *const ElfFile, idx: u16) SectionError!Section {
    if (idx >= file.sh_count) return SectionError.IndexOutOfRange;
    const hdr = file.sectionHeaderAt(idx) catch return SectionError.IndexOutOfRange;

    // Name resolution via shstrtab. sh_name is a byte offset.
    const name_off: usize = @intCast(hdr.sh_name);
    if (name_off >= file.shstrtab.len) return SectionError.NameOutOfRange;
    const name = util.cstrAt(file.shstrtab, name_off);

    // Data slicing. SHT_NULL has sh_offset=0 and sh_size=0, giving an empty slice.
    // SHT_NOBITS has sh_size>0 but no file bytes — still return empty slice.
    const off: usize = @intCast(hdr.sh_offset);
    const sz: usize = @intCast(hdr.sh_size);
    const data: []const u8 = blk: {
        if (hdr.sh_type == elf.SHT_NULL or hdr.sh_type == elf.SHT_NOBITS) {
            break :blk &.{};
        }
        if (off + sz > file.bytes.len) return SectionError.DataOutOfRange;
        break :blk file.bytes[off .. off + sz];
    };

    return Section{
        .index = idx,
        .header = hdr,
        .name = name,
        .data = data,
    };
}

// --- tests ---

const testing = std.testing;

// Build a minimal ELF with exactly one non-NULL section ".text" containing
// 3 bytes of data, plus the mandatory NULL section and the shstrtab.
//
// Layout (byte offsets):
//   0     Elf64_Ehdr                      (64 bytes)
//  64    section header [0] = NULL        (64 bytes)
// 128    section header [1] = .text       (64 bytes)
// 192    section header [2] = .shstrtab   (64 bytes)
// 256    ".text" bytes: DE AD BE          ( 3 bytes)
// 259    shstrtab: "\0.text\0.shstrtab\0" (17 bytes)
// 276    end
fn makeThreeSectionElf() [276]u8 {
    var buf: [276]u8 = @splat(0);

    // --- Elf64_Ehdr ---
    buf[0] = 0x7f;
    buf[1] = 'E';
    buf[2] = 'L';
    buf[3] = 'F';
    buf[elf.EI.CLASS] = elf.ELFCLASS64;
    buf[elf.EI.DATA] = elf.ELFDATA2LSB;
    buf[elf.EI.VERSION] = 1;
    buf[16] = 3; // e_type = ET_DYN
    buf[18] = 247; // e_machine = EM_BPF
    buf[20] = 1; // e_version = 1
    // e_shoff = 64 (section headers start right after ehdr)
    std.mem.writeInt(u64, buf[40..48], 64, .little);
    buf[52] = 64; // e_ehsize
    buf[58] = 64; // e_shentsize
    buf[60] = 3; // e_shnum (3 sections)
    buf[62] = 2; // e_shstrndx (index 2 = .shstrtab)

    // --- Section header [0]: SHT_NULL, all zeros. Already zeroed. ---

    // --- Section header [1]: .text ---
    // sh_name = 1 (offset of ".text" in shstrtab)
    std.mem.writeInt(u32, buf[128..132], 1, .little);
    std.mem.writeInt(u32, buf[132..136], elf.SHT_PROGBITS, .little); // sh_type
    // sh_flags at offset 136 (u64): ALLOC | EXEC = 0x2 | 0x4 = 0x6
    std.mem.writeInt(u64, buf[136..144], 0x6, .little);
    // sh_offset at 152 (u64): 256
    std.mem.writeInt(u64, buf[152..160], 256, .little);
    // sh_size at 160 (u64): 3
    std.mem.writeInt(u64, buf[160..168], 3, .little);

    // --- Section header [2]: .shstrtab ---
    // sh_name = 7 (offset of ".shstrtab" in shstrtab)
    std.mem.writeInt(u32, buf[192..196], 7, .little);
    std.mem.writeInt(u32, buf[196..200], elf.SHT_STRTAB, .little);
    // sh_offset = 259
    std.mem.writeInt(u64, buf[216..224], 259, .little);
    // sh_size = 17
    std.mem.writeInt(u64, buf[224..232], 17, .little);

    // --- .text data at offset 256 ---
    buf[256] = 0xde;
    buf[257] = 0xad;
    buf[258] = 0xbe;

    // --- shstrtab data at offset 259 ---
    //     "\0.text\0.shstrtab\0"
    //       ^  ^     ^
    //       0  1     7
    buf[259] = 0;
    buf[260] = '.';
    buf[261] = 't';
    buf[262] = 'e';
    buf[263] = 'x';
    buf[264] = 't';
    buf[265] = 0;
    buf[266] = '.';
    buf[267] = 's';
    buf[268] = 'h';
    buf[269] = 's';
    buf[270] = 't';
    buf[271] = 'r';
    buf[272] = 't';
    buf[273] = 'a';
    buf[274] = 'b';
    buf[275] = 0;

    return buf;
}

test "SectionIter yields all sections in order" {
    const bytes = makeThreeSectionElf();
    const file = try ElfFile.parse(&bytes);

    var it = SectionIter{ .file = &file };
    var count: usize = 0;
    while (try it.next()) |sec| : (count += 1) {
        try testing.expectEqual(count, sec.index);
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "Section name resolution via shstrtab" {
    const bytes = makeThreeSectionElf();
    const file = try ElfFile.parse(&bytes);

    const s0 = try buildSection(&file, 0);
    try testing.expectEqualStrings("", s0.name);

    const s1 = try buildSection(&file, 1);
    try testing.expectEqualStrings(".text", s1.name);

    const s2 = try buildSection(&file, 2);
    try testing.expectEqualStrings(".shstrtab", s2.name);
}

test "Section.data is a zero-copy slice of the original bytes" {
    const bytes = makeThreeSectionElf();
    const file = try ElfFile.parse(&bytes);

    const text = try buildSection(&file, 1);
    try testing.expectEqual(@as(usize, 3), text.data.len);
    try testing.expectEqual(@as(u8, 0xde), text.data[0]);
    try testing.expectEqual(@as(u8, 0xad), text.data[1]);
    try testing.expectEqual(@as(u8, 0xbe), text.data[2]);
}

test "Section.flags / size / kind accessors" {
    const bytes = makeThreeSectionElf();
    const file = try ElfFile.parse(&bytes);

    const text = try buildSection(&file, 1);
    try testing.expectEqual(@as(u64, 0x6), text.flags()); // SHF_ALLOC | SHF_EXECINSTR
    try testing.expectEqual(@as(u64, 3), text.size());
    try testing.expectEqual(@as(u32, elf.SHT_PROGBITS), text.kind());

    const strtab = try buildSection(&file, 2);
    try testing.expectEqual(@as(u32, elf.SHT_STRTAB), strtab.kind());
}

test "SHT_NULL section has empty data regardless of header fields" {
    const bytes = makeThreeSectionElf();
    const file = try ElfFile.parse(&bytes);

    const null_sec = try buildSection(&file, 0);
    try testing.expectEqual(@as(usize, 0), null_sec.data.len);
    try testing.expectEqualStrings("", null_sec.name);
    try testing.expectEqual(@as(u32, elf.SHT_NULL), null_sec.kind());
}
