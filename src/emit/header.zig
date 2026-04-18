// ELF header + program header + section header writers.
//
// Port of Rust sbpf-assembler::header (sbpf/crates/assembler/src/header.rs).
// Produces the 64-byte ELF64 header, 56-byte program headers, and 64-byte
// section headers that the Solana SBPF runtime expects.
//
// All three structs emit bytes via `bytecode(&self, out: *[N]u8)` which
// writes exactly the header's fixed size. No ArrayList — we know sizes
// at compile time.
//
// Spec: 03-technical-spec.md §2.4 + §7.1-7.5
// Tests: 05-test-spec.md §4.9

const std = @import("std");
const ast_mod = @import("../ast/ast.zig");
const SbpfArch = ast_mod.SbpfArch;

/// Fixed sizes that downstream code hardcodes.
pub const ELF64_HEADER_SIZE: u16 = 64;
pub const PROGRAM_HEADER_SIZE: u16 = 56;
pub const SECTION_HEADER_SIZE: u16 = 64;

// ---------------------------------------------------------------------------
// ElfHeader — 64 bytes
// ---------------------------------------------------------------------------

/// Identity bytes baked into every Solana SBPF `.so`. Matches Rust
/// sbpf-assembler::header::ElfHeader::SOLANA_IDENT.
pub const SOLANA_IDENT: [16]u8 = .{
    0x7f, 0x45, 0x4c, 0x46, // "\x7FELF"
    0x02, // EI_CLASS = ELFCLASS64
    0x01, // EI_DATA = ELFDATA2LSB
    0x01, // EI_VERSION = EV_CURRENT
    0x00, // EI_OSABI = SYSV
    0x00, // EI_ABIVERSION
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // EI_PAD
};

/// e_type for Solana programs.
pub const ET_DYN: u16 = 3;

/// e_machine for BPF.
pub const EM_BPF: u16 = 247;

/// e_version = EV_CURRENT = 1.
pub const EV_CURRENT: u32 = 1;

pub const ElfHeader = struct {
    e_ident: [16]u8 = SOLANA_IDENT,
    e_type: u16 = ET_DYN,
    e_machine: u16 = EM_BPF,
    e_version: u32 = EV_CURRENT,
    e_entry: u64 = 0,
    /// Phoff starts right after the 64-byte header by default.
    e_phoff: u64 = ELF64_HEADER_SIZE,
    e_shoff: u64 = 0,
    e_flags: u32 = 0,
    e_ehsize: u16 = ELF64_HEADER_SIZE,
    e_phentsize: u16 = PROGRAM_HEADER_SIZE,
    e_phnum: u16 = 0,
    e_shentsize: u16 = SECTION_HEADER_SIZE,
    e_shnum: u16 = 0,
    e_shstrndx: u16 = 0,

    pub fn init() ElfHeader {
        return .{};
    }

    /// Write this header's 64 bytes into the provided buffer.
    pub fn bytecode(self: ElfHeader, out: *[64]u8) void {
        @memcpy(out[0..16], &self.e_ident);
        std.mem.writeInt(u16, out[16..18], self.e_type, .little);
        std.mem.writeInt(u16, out[18..20], self.e_machine, .little);
        std.mem.writeInt(u32, out[20..24], self.e_version, .little);
        std.mem.writeInt(u64, out[24..32], self.e_entry, .little);
        std.mem.writeInt(u64, out[32..40], self.e_phoff, .little);
        std.mem.writeInt(u64, out[40..48], self.e_shoff, .little);
        std.mem.writeInt(u32, out[48..52], self.e_flags, .little);
        std.mem.writeInt(u16, out[52..54], self.e_ehsize, .little);
        std.mem.writeInt(u16, out[54..56], self.e_phentsize, .little);
        std.mem.writeInt(u16, out[56..58], self.e_phnum, .little);
        std.mem.writeInt(u16, out[58..60], self.e_shentsize, .little);
        std.mem.writeInt(u16, out[60..62], self.e_shnum, .little);
        std.mem.writeInt(u16, out[62..64], self.e_shstrndx, .little);
    }
};

// ---------------------------------------------------------------------------
// ProgramHeader — 56 bytes
// ---------------------------------------------------------------------------

pub const PT_LOAD: u32 = 1;
pub const PT_DYNAMIC: u32 = 2;

pub const PF_X: u32 = 1;
pub const PF_W: u32 = 2;
pub const PF_R: u32 = 4;

const PAGE_SIZE: u64 = 4096;

/// V3-specific virtual addresses.
pub const V3_RODATA_VADDR: u64 = 0 << 32;
pub const V3_BYTECODE_VADDR: u64 = @as(u64, 1) << 32;

pub const ProgramHeader = struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,

    /// Construct a PT_LOAD segment. V0 sets vaddr=offset with 4K alignment;
    /// V3 uses fixed virtual addresses at (1<<32) for code, 0 for rodata,
    /// and zero alignment.
    pub fn newLoad(offset: u64, size: u64, executable: bool, arch: SbpfArch) ProgramHeader {
        var flags: u32 = 0;
        var vaddr: u64 = 0;
        var p_align: u64 = 0;

        if (arch == .V3) {
            if (executable) {
                flags = PF_X;
                vaddr = V3_BYTECODE_VADDR;
            } else {
                flags = PF_R;
                vaddr = V3_RODATA_VADDR;
            }
            p_align = 0;
        } else {
            // V0
            flags = if (executable) (PF_R | PF_X) else PF_R;
            vaddr = offset;
            p_align = PAGE_SIZE;
        }

        return .{
            .p_type = PT_LOAD,
            .p_flags = flags,
            .p_offset = offset,
            .p_vaddr = vaddr,
            .p_paddr = vaddr,
            .p_filesz = size,
            .p_memsz = size,
            .p_align = p_align,
        };
    }

    /// Construct a PT_DYNAMIC segment for the .dynamic section.
    pub fn newDynamic(offset: u64, size: u64) ProgramHeader {
        return .{
            .p_type = PT_DYNAMIC,
            .p_flags = PF_R | PF_W,
            .p_offset = offset,
            .p_vaddr = offset,
            .p_paddr = offset,
            .p_filesz = size,
            .p_memsz = size,
            .p_align = 8,
        };
    }

    /// Write this program header's 56 bytes into the buffer.
    pub fn bytecode(self: ProgramHeader, out: *[56]u8) void {
        std.mem.writeInt(u32, out[0..4], self.p_type, .little);
        std.mem.writeInt(u32, out[4..8], self.p_flags, .little);
        std.mem.writeInt(u64, out[8..16], self.p_offset, .little);
        std.mem.writeInt(u64, out[16..24], self.p_vaddr, .little);
        std.mem.writeInt(u64, out[24..32], self.p_paddr, .little);
        std.mem.writeInt(u64, out[32..40], self.p_filesz, .little);
        std.mem.writeInt(u64, out[40..48], self.p_memsz, .little);
        std.mem.writeInt(u64, out[48..56], self.p_align, .little);
    }
};

// ---------------------------------------------------------------------------
// SectionHeader — 64 bytes
// ---------------------------------------------------------------------------

/// Section types used by elf2sbpf. Rust sbpf-assembler defines the same set
/// at header.rs L180-186.
pub const SHT_NULL: u32 = 0;
pub const SHT_PROGBITS: u32 = 1;
pub const SHT_STRTAB: u32 = 3;
pub const SHT_DYNAMIC: u32 = 6;
pub const SHT_REL: u32 = 9;
pub const SHT_NOBITS: u32 = 8;
pub const SHT_DYNSYM: u32 = 11;

/// Section flags.
pub const SHF_WRITE: u64 = 0x1;
pub const SHF_ALLOC: u64 = 0x2;
pub const SHF_EXECINSTR: u64 = 0x4;

pub const SectionHeader = struct {
    sh_name: u32,
    sh_type: u32,
    sh_flags: u64,
    sh_addr: u64,
    sh_offset: u64,
    sh_size: u64,
    sh_link: u32,
    sh_info: u32,
    sh_addralign: u64,
    sh_entsize: u64,

    pub fn init(
        name_offset: u32,
        sh_type: u32,
        flags: u64,
        addr: u64,
        offset: u64,
        size: u64,
        link: u32,
        info: u32,
        addralign: u64,
        entsize: u64,
    ) SectionHeader {
        return .{
            .sh_name = name_offset,
            .sh_type = sh_type,
            .sh_flags = flags,
            .sh_addr = addr,
            .sh_offset = offset,
            .sh_size = size,
            .sh_link = link,
            .sh_info = info,
            .sh_addralign = addralign,
            .sh_entsize = entsize,
        };
    }

    /// Write this section header's 64 bytes into the buffer.
    pub fn bytecode(self: SectionHeader, out: *[64]u8) void {
        std.mem.writeInt(u32, out[0..4], self.sh_name, .little);
        std.mem.writeInt(u32, out[4..8], self.sh_type, .little);
        std.mem.writeInt(u64, out[8..16], self.sh_flags, .little);
        std.mem.writeInt(u64, out[16..24], self.sh_addr, .little);
        std.mem.writeInt(u64, out[24..32], self.sh_offset, .little);
        std.mem.writeInt(u64, out[32..40], self.sh_size, .little);
        std.mem.writeInt(u32, out[40..44], self.sh_link, .little);
        std.mem.writeInt(u32, out[44..48], self.sh_info, .little);
        std.mem.writeInt(u64, out[48..56], self.sh_addralign, .little);
        std.mem.writeInt(u64, out[56..64], self.sh_entsize, .little);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ElfHeader defaults match Solana constants" {
    const hdr = ElfHeader.init();
    try testing.expectEqualSlices(u8, &SOLANA_IDENT, &hdr.e_ident);
    try testing.expectEqual(@as(u16, 3), hdr.e_type); // ET_DYN
    try testing.expectEqual(@as(u16, 247), hdr.e_machine); // EM_BPF
    try testing.expectEqual(@as(u32, 1), hdr.e_version);
    try testing.expectEqual(@as(u16, 64), hdr.e_ehsize);
    try testing.expectEqual(@as(u16, 56), hdr.e_phentsize);
    try testing.expectEqual(@as(u16, 64), hdr.e_shentsize);
    try testing.expectEqual(@as(u64, 64), hdr.e_phoff);
}

test "ElfHeader.bytecode writes 64 bytes with correct magic" {
    const hdr = ElfHeader.init();
    var out: [64]u8 = undefined;
    hdr.bytecode(&out);

    // Magic.
    try testing.expectEqual(@as(u8, 0x7f), out[0]);
    try testing.expectEqual(@as(u8, 'E'), out[1]);
    try testing.expectEqual(@as(u8, 'L'), out[2]);
    try testing.expectEqual(@as(u8, 'F'), out[3]);
    try testing.expectEqual(@as(u8, 2), out[4]); // ELFCLASS64
    try testing.expectEqual(@as(u8, 1), out[5]); // ELFDATA2LSB

    // e_type (offset 16) = 3, little-endian.
    try testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, out[16..18], .little));

    // e_machine (offset 18) = 247.
    try testing.expectEqual(@as(u16, 247), std.mem.readInt(u16, out[18..20], .little));

    // e_phoff (offset 32) = 64.
    try testing.expectEqual(@as(u64, 64), std.mem.readInt(u64, out[32..40], .little));

    // e_shoff (offset 40) = 0 by default.
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, out[40..48], .little));

    // e_ehsize (offset 52) = 64.
    try testing.expectEqual(@as(u16, 64), std.mem.readInt(u16, out[52..54], .little));
}

test "ElfHeader.bytecode round-trips custom fields" {
    var hdr = ElfHeader.init();
    hdr.e_entry = 0x1234;
    hdr.e_shoff = 0x200;
    hdr.e_flags = 0xa5;
    hdr.e_phnum = 3;
    hdr.e_shnum = 7;
    hdr.e_shstrndx = 6;

    var out: [64]u8 = undefined;
    hdr.bytecode(&out);

    try testing.expectEqual(@as(u64, 0x1234), std.mem.readInt(u64, out[24..32], .little));
    try testing.expectEqual(@as(u64, 0x200), std.mem.readInt(u64, out[40..48], .little));
    try testing.expectEqual(@as(u32, 0xa5), std.mem.readInt(u32, out[48..52], .little));
    try testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, out[56..58], .little));
    try testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, out[60..62], .little));
    try testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, out[62..64], .little));
}

test "ProgramHeader.newLoad V0 executable has PF_R|PF_X and vaddr=offset" {
    const ph = ProgramHeader.newLoad(0x100, 0x40, true, .V0);
    try testing.expectEqual(PT_LOAD, ph.p_type);
    try testing.expectEqual(PF_R | PF_X, ph.p_flags);
    try testing.expectEqual(@as(u64, 0x100), ph.p_offset);
    try testing.expectEqual(@as(u64, 0x100), ph.p_vaddr);
    try testing.expectEqual(@as(u64, 0x40), ph.p_filesz);
    try testing.expectEqual(@as(u64, 4096), ph.p_align);
}

test "ProgramHeader.newLoad V0 rodata has PF_R only" {
    const ph = ProgramHeader.newLoad(0x100, 0x10, false, .V0);
    try testing.expectEqual(PF_R, ph.p_flags);
    try testing.expectEqual(@as(u64, 0x100), ph.p_vaddr);
}

test "ProgramHeader.newLoad V3 executable uses V3_BYTECODE_VADDR" {
    const ph = ProgramHeader.newLoad(0x100, 0x40, true, .V3);
    try testing.expectEqual(PF_X, ph.p_flags);
    try testing.expectEqual(V3_BYTECODE_VADDR, ph.p_vaddr);
    try testing.expectEqual(@as(u64, 0), ph.p_align);
}

test "ProgramHeader.newDynamic sets PT_DYNAMIC flags and alignment" {
    const ph = ProgramHeader.newDynamic(0x200, 0x30);
    try testing.expectEqual(PT_DYNAMIC, ph.p_type);
    try testing.expectEqual(PF_R | PF_W, ph.p_flags);
    try testing.expectEqual(@as(u64, 8), ph.p_align);
}

test "ProgramHeader.bytecode writes 56 bytes" {
    const ph = ProgramHeader.newLoad(0x100, 0x40, true, .V0);
    var out: [56]u8 = undefined;
    ph.bytecode(&out);

    try testing.expectEqual(PT_LOAD, std.mem.readInt(u32, out[0..4], .little));
    try testing.expectEqual(PF_R | PF_X, std.mem.readInt(u32, out[4..8], .little));
    try testing.expectEqual(@as(u64, 0x100), std.mem.readInt(u64, out[8..16], .little));
    try testing.expectEqual(@as(u64, 0x40), std.mem.readInt(u64, out[32..40], .little));
    try testing.expectEqual(@as(u64, 4096), std.mem.readInt(u64, out[48..56], .little));
}

test "SectionHeader.init + bytecode" {
    const sh = SectionHeader.init(
        1, // sh_name (offset 1 in shstrtab)
        SHT_PROGBITS,
        SHF_ALLOC | SHF_EXECINSTR,
        0xe8, // sh_addr
        0xe8, // sh_offset
        0x40, // sh_size
        0, // sh_link
        0, // sh_info
        4, // sh_addralign
        0, // sh_entsize
    );

    var out: [64]u8 = undefined;
    sh.bytecode(&out);

    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[0..4], .little));
    try testing.expectEqual(SHT_PROGBITS, std.mem.readInt(u32, out[4..8], .little));
    try testing.expectEqual(SHF_ALLOC | SHF_EXECINSTR, std.mem.readInt(u64, out[8..16], .little));
    try testing.expectEqual(@as(u64, 0xe8), std.mem.readInt(u64, out[16..24], .little));
    try testing.expectEqual(@as(u64, 0xe8), std.mem.readInt(u64, out[24..32], .little));
    try testing.expectEqual(@as(u64, 0x40), std.mem.readInt(u64, out[32..40], .little));
    try testing.expectEqual(@as(u64, 4), std.mem.readInt(u64, out[48..56], .little));
}
