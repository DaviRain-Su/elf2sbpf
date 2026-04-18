// Section type writers — NullSection, ShStrTabSection, CodeSection,
// DataSection, DynamicSection, DynSymSection, DynStrSection,
// RelDynSection, DebugSection.
//
// Port of Rust sbpf-assembler::section (sbpf/crates/assembler/src/section.rs).
// Each section type provides two emit functions:
//   - `bytecode(allocator) []u8` — the section content bytes
//   - `sectionHeaderBytecode(*[64]u8)` — the 64-byte entry in the
//     section header table
//
// F.4 covers NullSection + ShStrTabSection. F.5-F.12 fill in the rest.
//
// Spec: 03-technical-spec.md §2.4, §6.4
// Tests: 05-test-spec.md §4.9

const std = @import("std");
const header_mod = @import("header.zig");
const SectionHeader = header_mod.SectionHeader;
const ast_mod = @import("../ast/ast.zig");
const ASTNode = ast_mod.ASTNode;
const instruction_mod = @import("../common/instruction.zig");

// ---------------------------------------------------------------------------
// NullSection — the mandatory SHT_NULL entry at index 0 of every ELF.
// ---------------------------------------------------------------------------

/// The NULL section has no content and a full-zero section header.
/// Every ELF's section table must begin with one.
pub const NullSection = struct {
    pub fn init() NullSection {
        return .{};
    }

    /// NullSection has no data.
    pub fn bytecode(self: NullSection, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        return try allocator.alloc(u8, 0);
    }

    /// Returns empty content size.
    pub fn size(self: NullSection) u64 {
        _ = self;
        return 0;
    }

    /// Full-zero 64-byte section header.
    pub fn sectionHeaderBytecode(self: NullSection, out: *[64]u8) void {
        _ = self;
        const sh = SectionHeader.init(0, header_mod.SHT_NULL, 0, 0, 0, 0, 0, 0, 0, 0);
        sh.bytecode(out);
    }
};

// ---------------------------------------------------------------------------
// ShStrTabSection — the section-header name string table.
// ---------------------------------------------------------------------------

/// A concatenation of null-terminated section name strings, starting with
/// a single null byte. The offset into this table is what `sh_name` in
/// every other SectionHeader references.
///
/// Rust section.rs L207-290. Ownership:
///   - `name_offset` — this section's own name offset (".s" at the end)
///   - `section_names` — names for all emitted sections; caller supplies
///     them in section-table order
///
/// The writer's `bytecode()` is size-padded to a multiple of 8 (matches
/// Rust's trailing null-pad loop). `size()` returns the **unpadded** size
/// — i.e. the total string bytes only — because that's what Rust does
/// and that's what Epic G's offset accumulator expects (it aligns
/// separately via `shoff` padding).
pub const ShStrTabSection = struct {
    /// This section's own name offset inside itself ("`.s`" entry).
    name_offset: u32,
    /// Borrowed list of section names in emission order. The last
    /// element is implicitly ".s" (this section); callers don't need
    /// to append it themselves — they provide the names of the OTHER
    /// sections and we synthesize ".s" in the output.
    section_names: []const []const u8,
    /// Offset of this section's content within the output file. Set by
    /// Program::fromParseResult before the final emit.
    offset: u64 = 0,

    /// This section's display name (always ".s").
    pub fn name(self: ShStrTabSection) []const u8 {
        _ = self;
        return ".s";
    }

    pub fn setOffset(self: *ShStrTabSection, o: u64) void {
        self.offset = o;
    }

    /// Unpadded logical byte count — leading null + each non-empty name
    /// + null terminator + the implicit ".s" trailer. This is what
    /// section_header_bytecode reports as `sh_size` (matches Rust's
    /// `size()` return value at L276-289).
    pub fn size(self: ShStrTabSection) u64 {
        var total: u64 = 1; // leading null byte
        for (self.section_names) |n| {
            if (n.len == 0) continue;
            total += n.len + 1; // name + null terminator
        }
        // Include the implicit ".s" entry.
        total += 2 + 1; // ".s" length 2 + null
        return total;
    }

    /// Bytes actually emitted by `bytecode()` — unpadded size rounded
    /// up to the next 8-byte boundary. Use this for file-offset
    /// tracking in the layout pass.
    pub fn paddedSize(self: ShStrTabSection) u64 {
        return (self.size() + 7) & ~@as(u64, 7);
    }

    /// Emit: leading null byte + each non-empty name + null terminator,
    /// trailing ".s\0", then 0-padding to a multiple of 8.
    pub fn bytecode(self: ShStrTabSection, allocator: std.mem.Allocator) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);

        try list.append(allocator, 0); // leading null

        for (self.section_names) |n| {
            if (n.len == 0) continue;
            try list.appendSlice(allocator, n);
            try list.append(allocator, 0);
        }

        // Implicit trailing ".s" entry for this section itself.
        try list.appendSlice(allocator, ".s");
        try list.append(allocator, 0);

        // Pad to 8-byte boundary.
        while (list.items.len % 8 != 0) {
            try list.append(allocator, 0);
        }

        return list.toOwnedSlice(allocator);
    }

    pub fn sectionHeaderBytecode(self: ShStrTabSection, out: *[64]u8) void {
        const sh = SectionHeader.init(
            self.name_offset,
            header_mod.SHT_STRTAB,
            0, // flags
            0, // addr
            self.offset,
            self.size(),
            0, // link
            0, // info
            1, // addralign
            0, // entsize
        );
        sh.bytecode(out);
    }
};

// ---------------------------------------------------------------------------
// CodeSection — the merged .text image (executable instructions).
// ---------------------------------------------------------------------------

/// Holds the instruction-bearing AST nodes plus the final merged size.
/// Rust section.rs L29-95.
///
/// `nodes` is a slice of the code-section ASTNode list (borrowed from
/// ParseResult). Emission walks the list in order, serializing only the
/// Instruction variants — Label and GlobalDecl are metadata that don't
/// contribute bytes.
pub const CodeSection = struct {
    /// Borrowed slice of the code-section AST nodes.
    nodes: []const ASTNode,
    /// Total emitted size = sum of Instruction.getSize() for each
    /// Instruction node in `nodes`. Provided by caller (from AST.text_size).
    size: u64,
    /// Offset of the name string inside the shstrtab.
    name_offset: u32 = 0,
    /// Offset into the output file. Set by Program::fromParseResult
    /// during layout.
    offset: u64 = 0,

    pub fn name(self: CodeSection) []const u8 {
        _ = self;
        return ".text";
    }

    pub fn setOffset(self: *CodeSection, o: u64) void {
        self.offset = o;
    }

    pub fn setNameOffset(self: *CodeSection, o: u32) void {
        self.name_offset = o;
    }

    /// Serialize all Instruction nodes back to bytes via
    /// Instruction.toBytes. Caller owns the returned slice.
    ///
    /// Size of the returned buffer == self.size (the caller-provided
    /// total). If a node carries an unresolved .left(label) in imm/off,
    /// returns EncodeError.UnresolvedLabel — i.e. caller forgot to run
    /// buildProgram before emitting.
    pub fn bytecode(self: CodeSection, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, @intCast(self.size));
        errdefer allocator.free(buf);

        var cursor: usize = 0;
        for (self.nodes) |n| {
            switch (n) {
                .Instruction => |payload| {
                    const inst = payload.instruction;
                    const step: usize = @intCast(inst.getSize());
                    if (cursor + step > buf.len) return error.TextTooLarge;
                    if (step == 16) {
                        try inst.toBytes(buf[cursor .. cursor + 16][0..16]);
                    } else {
                        try inst.toBytes(buf[cursor .. cursor + 8][0..8]);
                    }
                    cursor += step;
                },
                else => {},
            }
        }

        // Any unused tail bytes stay as their initial value (allocator
        // provides undefined content) — zero them to be deterministic.
        @memset(buf[cursor..], 0);

        return buf;
    }

    /// 64-byte section header: PROGBITS + ALLOC|EXECINSTR, align 4.
    pub fn sectionHeaderBytecode(self: CodeSection, out: *[64]u8) void {
        const flags = header_mod.SHF_ALLOC | header_mod.SHF_EXECINSTR;
        const sh = SectionHeader.init(
            self.name_offset,
            header_mod.SHT_PROGBITS,
            flags,
            self.offset,
            self.offset,
            self.size,
            0,
            0,
            4,
            0,
        );
        sh.bytecode(out);
    }
};

// ---------------------------------------------------------------------------
// DataSection — the merged .rodata image (read-only constants).
// ---------------------------------------------------------------------------

/// Holds the ROData nodes plus the final rodata size.
/// Rust section.rs L97-185.
pub const DataSection = struct {
    nodes: []const ASTNode,
    size: u64,
    name_offset: u32 = 0,
    offset: u64 = 0,

    pub fn name(self: DataSection) []const u8 {
        _ = self;
        return ".rodata";
    }

    pub fn setOffset(self: *DataSection, o: u64) void {
        self.offset = o;
    }

    pub fn setNameOffset(self: *DataSection, o: u32) void {
        self.name_offset = o;
    }

    /// Content size rounded up to 8-byte boundary. The raw size field
    /// (pre-padding) stays in the section header to match the ELF
    /// convention that sh_size counts only logical content.
    pub fn alignedSize(self: DataSection) u64 {
        return (self.size + 7) & ~@as(u64, 7);
    }

    /// Concatenate all ROData.bytes slices and 8-byte-pad the tail.
    pub fn bytecode(self: DataSection, allocator: std.mem.Allocator) ![]u8 {
        const aligned = self.alignedSize();
        const buf = try allocator.alloc(u8, @intCast(aligned));
        errdefer allocator.free(buf);
        @memset(buf, 0);

        var cursor: usize = 0;
        for (self.nodes) |n| {
            switch (n) {
                .ROData => |payload| {
                    const bytes = payload.rodata.bytes;
                    if (cursor + bytes.len > buf.len) return error.RodataTooLarge;
                    @memcpy(buf[cursor .. cursor + bytes.len], bytes);
                    cursor += bytes.len;
                },
                else => {},
            }
        }

        return buf;
    }

    pub fn sectionHeaderBytecode(self: DataSection, out: *[64]u8) void {
        const sh = SectionHeader.init(
            self.name_offset,
            header_mod.SHT_PROGBITS,
            header_mod.SHF_ALLOC,
            self.offset,
            self.offset,
            self.size, // sh_size holds unpadded logical size
            0,
            0,
            1,
            0,
        );
        sh.bytecode(out);
    }
};

// ---------------------------------------------------------------------------
// DynSymSection — dynamic symbol table (.dynsym), 24 bytes per entry.
// ---------------------------------------------------------------------------

/// STB_GLOBAL | STT_NOTYPE — the info byte Rust uses for every entry
/// in `bytecode_v0` at sbpf-assembler::program.rs.
pub const STB_GLOBAL_STT_NOTYPE: u8 = (1 << 4) | 0;

/// One entry in the .dynsym table. Fixed 24 bytes per ELF64 spec.
pub const DynSymEntry = struct {
    /// Index into .dynstr of this symbol's name. Entry 0 is STN_UNDEF
    /// with name=0 (empty string at dynstr offset 0).
    name: u32,
    info: u8 = STB_GLOBAL_STT_NOTYPE,
    other: u8 = 0,
    /// Section index — 0 for UND (syscalls are undefined), 1 for
    /// entrypoints defined in .text.
    shndx: u16,
    value: u64,
    size: u64 = 0,

    pub fn bytecode(self: DynSymEntry, out: *[24]u8) void {
        std.mem.writeInt(u32, out[0..4], self.name, .little);
        out[4] = self.info;
        out[5] = self.other;
        std.mem.writeInt(u16, out[6..8], self.shndx, .little);
        std.mem.writeInt(u64, out[8..16], self.value, .little);
        std.mem.writeInt(u64, out[16..24], self.size, .little);
    }
};

pub const DynSymSection = struct {
    name_offset: u32,
    /// Borrowed slice of entries. Entry 0 is always STN_UNDEF; callers
    /// that accept DynSymSection must include it themselves.
    entries: []const DynSymEntry,
    /// Byte offset of this section in the output file.
    offset: u64 = 0,
    /// sh_link — points at .dynstr's section index.
    link: u32 = 0,

    pub fn name(self: DynSymSection) []const u8 {
        _ = self;
        return ".dynsym";
    }

    pub fn setOffset(self: *DynSymSection, o: u64) void {
        self.offset = o;
    }

    pub fn setLink(self: *DynSymSection, l: u32) void {
        self.link = l;
    }

    pub fn size(self: DynSymSection) u64 {
        return @as(u64, self.entries.len) * 24;
    }

    pub fn bytecode(self: DynSymSection, allocator: std.mem.Allocator) ![]u8 {
        const sz: usize = @intCast(self.size());
        const buf = try allocator.alloc(u8, sz);
        errdefer allocator.free(buf);
        for (self.entries, 0..) |e, idx| {
            e.bytecode(buf[idx * 24 ..][0..24]);
        }
        return buf;
    }

    pub fn sectionHeaderBytecode(self: DynSymSection, out: *[64]u8) void {
        const sh = SectionHeader.init(
            self.name_offset,
            header_mod.SHT_DYNSYM,
            header_mod.SHF_ALLOC,
            self.offset,
            self.offset,
            self.size(),
            self.link,
            1, // sh_info = first non-local symbol index (all ours are global → 1)
            8,
            24,
        );
        sh.bytecode(out);
    }
};

// ---------------------------------------------------------------------------
// DynStrSection — dynamic symbol name string table.
// ---------------------------------------------------------------------------

/// The string table used by .dynsym. Layout:
///   [0]                = 0  (empty string for STN_UNDEF)
///   [offset1..]        = name1 \0
///   [offset2..]        = name2 \0
///   ...                 padded to 8-byte boundary
pub const DynStrSection = struct {
    name_offset: u32,
    symbol_names: []const []const u8,
    offset: u64 = 0,

    pub fn name(self: DynStrSection) []const u8 {
        _ = self;
        return ".dynstr";
    }

    pub fn setOffset(self: *DynStrSection, o: u64) void {
        self.offset = o;
    }

    /// Padded size in bytes (Rust returns the padded size here, unlike
    /// ShStrTabSection's unpadded convention).
    pub fn size(self: DynStrSection) u64 {
        var total: u64 = 1; // leading null
        for (self.symbol_names) |n| total += n.len + 1;
        total = (total + 7) & ~@as(u64, 7);
        return total;
    }

    pub fn bytecode(self: DynStrSection, allocator: std.mem.Allocator) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        try list.append(allocator, 0);
        for (self.symbol_names) |n| {
            try list.appendSlice(allocator, n);
            try list.append(allocator, 0);
        }
        while (list.items.len % 8 != 0) {
            try list.append(allocator, 0);
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn sectionHeaderBytecode(self: DynStrSection, out: *[64]u8) void {
        const sh = SectionHeader.init(
            self.name_offset,
            header_mod.SHT_STRTAB,
            header_mod.SHF_ALLOC,
            self.offset,
            self.offset,
            self.size(),
            0,
            0,
            1,
            0,
        );
        sh.bytecode(out);
    }
};

// ---------------------------------------------------------------------------
// RelDynSection — dynamic relocation table (.rel.dyn). 16 bytes per entry.
// ---------------------------------------------------------------------------

/// Constants from the Rust `RelocationType` enum.
pub const R_SBF_64_RELATIVE: u64 = 0x08;
pub const R_SBF_SYSCALL: u64 = 0x0a;

/// One .rel.dyn entry: 16 bytes. ELF Rel format:
///   r_offset (u64) | r_info (u64)
/// r_info encodes (symbol_index << 32) | r_type, but for Solana we
/// actually store dynstr_offset in the high 32 bits (Rust puts it
/// there directly). See sbpf-assembler::dynsym::RelDyn.bytecode.
pub const RelDynEntry = struct {
    offset: u64,
    rel_type: u64,
    dynstr_offset: u64,

    pub fn bytecode(self: RelDynEntry, out: *[16]u8) void {
        std.mem.writeInt(u64, out[0..8], self.offset, .little);
        // r_info = (dynstr_offset << 32) | rel_type
        const r_info = (self.dynstr_offset << 32) | self.rel_type;
        std.mem.writeInt(u64, out[8..16], r_info, .little);
    }
};

pub const RelDynSection = struct {
    name_offset: u32,
    entries: []const RelDynEntry,
    offset: u64 = 0,
    link: u32 = 0,

    pub fn name(self: RelDynSection) []const u8 {
        _ = self;
        return ".rel.dyn";
    }

    pub fn setOffset(self: *RelDynSection, o: u64) void {
        self.offset = o;
    }

    pub fn setLink(self: *RelDynSection, l: u32) void {
        self.link = l;
    }

    pub fn size(self: RelDynSection) u64 {
        return @as(u64, self.entries.len) * 16;
    }

    pub fn bytecode(self: RelDynSection, allocator: std.mem.Allocator) ![]u8 {
        const sz: usize = @intCast(self.size());
        const buf = try allocator.alloc(u8, sz);
        errdefer allocator.free(buf);
        for (self.entries, 0..) |e, idx| {
            e.bytecode(buf[idx * 16 ..][0..16]);
        }
        return buf;
    }

    pub fn sectionHeaderBytecode(self: RelDynSection, out: *[64]u8) void {
        const sh = SectionHeader.init(
            self.name_offset,
            header_mod.SHT_REL,
            header_mod.SHF_ALLOC,
            self.offset,
            self.offset,
            self.size(),
            self.link,
            0,
            8,
            16,
        );
        sh.bytecode(out);
    }
};

// ---------------------------------------------------------------------------
// DynamicSection — the .dynamic table pointing at the other dyn sections.
// ---------------------------------------------------------------------------

/// Dynamic tag constants from the ELF spec.
pub const DT_NULL: u64 = 0x00;
pub const DT_STRTAB: u64 = 0x05;
pub const DT_SYMTAB: u64 = 0x06;
pub const DT_STRSZ: u64 = 0x0a;
pub const DT_SYMENT: u64 = 0x0b;
pub const DT_REL: u64 = 0x11;
pub const DT_RELSZ: u64 = 0x12;
pub const DT_RELENT: u64 = 0x13;
pub const DT_TEXTREL: u64 = 0x16;
pub const DT_FLAGS: u64 = 0x1e;
pub const DT_RELCOUNT: u64 = 0x6fff_fffa;

pub const DF_TEXTREL: u64 = 0x04;

pub const DynamicSection = struct {
    name_offset: u32,
    offset: u64 = 0,
    /// sh_link → .dynstr section index.
    link: u32 = 0,
    rel_offset: u64 = 0,
    rel_size: u64 = 0,
    rel_count: u64 = 0,
    dynsym_offset: u64 = 0,
    dynstr_offset: u64 = 0,
    dynstr_size: u64 = 0,

    pub fn name(self: DynamicSection) []const u8 {
        _ = self;
        return ".dynamic";
    }

    pub fn setOffset(self: *DynamicSection, o: u64) void {
        self.offset = o;
    }

    pub fn setLink(self: *DynamicSection, l: u32) void {
        self.link = l;
    }

    /// 10 or 11 tags × 16 bytes. RELCOUNT is omitted when rel_count=0.
    pub fn size(self: DynamicSection) u64 {
        return if (self.rel_count > 0) 11 * 16 else 10 * 16;
    }

    pub fn bytecode(self: DynamicSection, allocator: std.mem.Allocator) ![]u8 {
        const sz: usize = @intCast(self.size());
        const buf = try allocator.alloc(u8, sz);
        errdefer allocator.free(buf);

        var cursor: usize = 0;
        const writeTag = struct {
            fn go(dst: []u8, cur: *usize, tag: u64, val: u64) void {
                std.mem.writeInt(u64, dst[cur.* .. cur.* + 8][0..8], tag, .little);
                std.mem.writeInt(u64, dst[cur.* + 8 .. cur.* + 16][0..8], val, .little);
                cur.* += 16;
            }
        }.go;

        writeTag(buf, &cursor, DT_FLAGS, DF_TEXTREL);
        writeTag(buf, &cursor, DT_REL, self.rel_offset);
        writeTag(buf, &cursor, DT_RELSZ, self.rel_size);
        writeTag(buf, &cursor, DT_RELENT, 0x10);
        if (self.rel_count > 0) {
            writeTag(buf, &cursor, DT_RELCOUNT, self.rel_count);
        }
        writeTag(buf, &cursor, DT_SYMTAB, self.dynsym_offset);
        writeTag(buf, &cursor, DT_SYMENT, 0x18);
        writeTag(buf, &cursor, DT_STRTAB, self.dynstr_offset);
        writeTag(buf, &cursor, DT_STRSZ, self.dynstr_size);
        writeTag(buf, &cursor, DT_TEXTREL, 0);
        writeTag(buf, &cursor, DT_NULL, 0);

        return buf;
    }

    pub fn sectionHeaderBytecode(self: DynamicSection, out: *[64]u8) void {
        const sh = SectionHeader.init(
            self.name_offset,
            header_mod.SHT_DYNAMIC,
            header_mod.SHF_ALLOC | header_mod.SHF_WRITE,
            self.offset,
            self.offset,
            self.size(),
            self.link,
            0,
            8,
            16,
        );
        sh.bytecode(out);
    }
};

// ---------------------------------------------------------------------------
// DebugSection — pass-through for `.debug_*` / `.BTF` / other non-loadable
// bytes preserved from the input ELF. The emit layer copies `data` verbatim
// into the output; loader never maps these into VM memory.
// ---------------------------------------------------------------------------

pub const DebugSection = struct {
    section_name: []const u8,
    name_offset: u32,
    data: []const u8,
    offset: u64 = 0,

    pub fn name(self: DebugSection) []const u8 {
        return self.section_name;
    }

    pub fn setOffset(self: *DebugSection, o: u64) void {
        self.offset = o;
    }

    pub fn size(self: DebugSection) u64 {
        return self.data.len;
    }

    /// Verbatim copy of the preserved bytes. No padding, no realignment —
    /// debug sections stay exactly as the input compiler emitted them.
    pub fn bytecode(self: DebugSection, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, self.data.len);
        errdefer allocator.free(buf);
        @memcpy(buf, self.data);
        return buf;
    }

    pub fn sectionHeaderBytecode(self: DebugSection, out: *[64]u8) void {
        // SHT_PROGBITS, no flags (not loadable), alignment 1.
        const sh = SectionHeader.init(
            self.name_offset,
            header_mod.SHT_PROGBITS,
            0,
            0,
            self.offset,
            self.size(),
            0,
            0,
            1,
            0,
        );
        sh.bytecode(out);
    }
};

// ---------------------------------------------------------------------------
// SectionType — tagged union over the 9 concrete section writers.
//
// Lets `Program::emitBytecode` iterate a heterogeneous list of sections
// without type-dispatching at every call site. Every variant exposes the
// same shape: `name() / size() / setOffset() / bytecode() /
// sectionHeaderBytecode()`. NullSection has no offset (it's always 0) — the
// union's setOffset tolerates that by no-oping for Null.
// ---------------------------------------------------------------------------

pub const SectionType = union(enum) {
    null_: NullSection,
    shstrtab: ShStrTabSection,
    code: CodeSection,
    data: DataSection,
    dynsym: DynSymSection,
    dynstr: DynStrSection,
    dynamic: DynamicSection,
    reldyn: RelDynSection,
    debug: DebugSection,

    pub fn name(self: SectionType) []const u8 {
        return switch (self) {
            .null_ => "",
            .shstrtab => |s| s.name(),
            .code => |s| s.name(),
            .data => |s| s.name(),
            .dynsym => |s| s.name(),
            .dynstr => |s| s.name(),
            .dynamic => |s| s.name(),
            .reldyn => |s| s.name(),
            .debug => |s| s.name(),
        };
    }

    /// Bytes actually written by `bytecode()`. Padded sizes for
    /// ShStrTab / Data; raw sizes for the rest (already 8-aligned or
    /// never padded).
    pub fn size(self: SectionType) u64 {
        return switch (self) {
            .null_ => |s| s.size(),
            .shstrtab => |s| s.paddedSize(),
            .code => |s| s.size,
            .data => |s| s.alignedSize(),
            .dynsym => |s| s.size(),
            .dynstr => |s| s.size(),
            .dynamic => |s| s.size(),
            .reldyn => |s| s.size(),
            .debug => |s| s.size(),
        };
    }

    pub fn setOffset(self: *SectionType, o: u64) void {
        switch (self.*) {
            .null_ => {}, // NullSection has no offset field.
            .shstrtab => |*s| s.setOffset(o),
            .code => |*s| s.setOffset(o),
            .data => |*s| s.setOffset(o),
            .dynsym => |*s| s.setOffset(o),
            .dynstr => |*s| s.setOffset(o),
            .dynamic => |*s| s.setOffset(o),
            .reldyn => |*s| s.setOffset(o),
            .debug => |*s| s.setOffset(o),
        }
    }

    pub fn bytecode(self: SectionType, allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .null_ => |s| s.bytecode(allocator),
            .shstrtab => |s| s.bytecode(allocator),
            .code => |s| s.bytecode(allocator),
            .data => |s| s.bytecode(allocator),
            .dynsym => |s| s.bytecode(allocator),
            .dynstr => |s| s.bytecode(allocator),
            .dynamic => |s| s.bytecode(allocator),
            .reldyn => |s| s.bytecode(allocator),
            .debug => |s| s.bytecode(allocator),
        };
    }

    pub fn sectionHeaderBytecode(self: SectionType, out: *[64]u8) void {
        switch (self) {
            .null_ => |s| s.sectionHeaderBytecode(out),
            .shstrtab => |s| s.sectionHeaderBytecode(out),
            .code => |s| s.sectionHeaderBytecode(out),
            .data => |s| s.sectionHeaderBytecode(out),
            .dynsym => |s| s.sectionHeaderBytecode(out),
            .dynstr => |s| s.sectionHeaderBytecode(out),
            .dynamic => |s| s.sectionHeaderBytecode(out),
            .reldyn => |s| s.sectionHeaderBytecode(out),
            .debug => |s| s.sectionHeaderBytecode(out),
        }
    }

    pub fn setNameOffset(self: *SectionType, o: u32) void {
        switch (self.*) {
            .null_ => {},
            .shstrtab => |*s| s.name_offset = o,
            .code => |*s| s.setNameOffset(o),
            .data => |*s| s.setNameOffset(o),
            .dynsym => |*s| s.name_offset = o,
            .dynstr => |*s| s.name_offset = o,
            .dynamic => |*s| s.name_offset = o,
            .reldyn => |*s| s.name_offset = o,
            .debug => |*s| s.name_offset = o,
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "NullSection: empty content and zero section header" {
    const ns = NullSection.init();

    const bytes = try ns.bytecode(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 0), bytes.len);

    try testing.expectEqual(@as(u64, 0), ns.size());

    var out: [64]u8 = undefined;
    ns.sectionHeaderBytecode(&out);
    // All 64 bytes must be zero.
    for (out) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "ShStrTabSection: single name produces expected layout" {
    const names = [_][]const u8{".text"};
    var sh = ShStrTabSection{
        .name_offset = 7, // offset of ".s" in the final table
        .section_names = &names,
    };

    const bytes = try sh.bytecode(testing.allocator);
    defer testing.allocator.free(bytes);

    // Expected content before padding:
    //   [0] = 0
    //   [1..6]  = ".text"
    //   [6]     = 0
    //   [7..9]  = ".s"
    //   [9]     = 0
    // Total 10 bytes, padded to 16.
    try testing.expectEqual(@as(u8, 0), bytes[0]);
    try testing.expectEqualStrings(".text", bytes[1..6]);
    try testing.expectEqual(@as(u8, 0), bytes[6]);
    try testing.expectEqualStrings(".s", bytes[7..9]);
    try testing.expectEqual(@as(u8, 0), bytes[9]);
    try testing.expectEqual(@as(usize, 16), bytes.len); // padded to 8-multiple

    // size() excludes the padding — matches Rust behavior.
    try testing.expectEqual(@as(u64, 10), sh.size());
}

test "ShStrTabSection: empty names skipped, leading null preserved" {
    const names = [_][]const u8{ "", ".text", "", ".rodata", "" };
    const sh = ShStrTabSection{
        .name_offset = 0,
        .section_names = &names,
    };

    const bytes = try sh.bytecode(testing.allocator);
    defer testing.allocator.free(bytes);

    // Content: \0.text\0.rodata\0.s\0
    //   1 + 5 + 1 + 7 + 1 + 2 + 1 = 18 bytes, padded to 24.
    try testing.expectEqual(@as(usize, 24), bytes.len);
    try testing.expectEqual(@as(u64, 18), sh.size());
    try testing.expectEqualStrings(".text", bytes[1..6]);
    try testing.expectEqualStrings(".rodata", bytes[7..14]);
    try testing.expectEqualStrings(".s", bytes[15..17]);
}

test "ShStrTabSection: section header uses SHT_STRTAB with addralign=1" {
    const names = [_][]const u8{".text"};
    var sh = ShStrTabSection{
        .name_offset = 7,
        .section_names = &names,
    };
    sh.setOffset(0x200);

    var out: [64]u8 = undefined;
    sh.sectionHeaderBytecode(&out);

    // sh_name at offset 0 = 7
    try testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, out[0..4], .little));
    // sh_type at offset 4 = SHT_STRTAB (3)
    try testing.expectEqual(@as(u32, header_mod.SHT_STRTAB), std.mem.readInt(u32, out[4..8], .little));
    // sh_flags at offset 8 = 0
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, out[8..16], .little));
    // sh_offset at offset 24 = 0x200
    try testing.expectEqual(@as(u64, 0x200), std.mem.readInt(u64, out[24..32], .little));
    // sh_size at offset 32 = 10
    try testing.expectEqual(@as(u64, 10), std.mem.readInt(u64, out[32..40], .little));
    // sh_addralign at offset 48 = 1
    try testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, out[48..56], .little));
}

test "CodeSection: emit a single exit instruction (8 bytes)" {
    const exit_inst = instruction_mod.Instruction{
        .opcode = .Exit,
        .dst = null,
        .src = null,
        .off = null,
        .imm = null,
        .span = .{ .start = 0, .end = 8 },
    };
    const nodes = [_]ASTNode{
        .{ .Instruction = .{ .instruction = exit_inst, .offset = 0 } },
    };
    const cs = CodeSection{ .nodes = &nodes, .size = 8 };

    const bytes = try cs.bytecode(testing.allocator);
    defer testing.allocator.free(bytes);

    try testing.expectEqual(@as(usize, 8), bytes.len);
    // Exit encodes to 95 00 00 00 00 00 00 00
    try testing.expectEqual(@as(u8, 0x95), bytes[0]);
    for (bytes[1..]) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "CodeSection: skips Label and GlobalDecl nodes, emits only Instructions" {
    const mov_inst = instruction_mod.Instruction{
        .opcode = .Mov64Imm,
        .dst = .{ .n = 0 },
        .src = null,
        .off = null,
        .imm = .{ .right = .{ .Int = 42 } },
        .span = .{ .start = 0, .end = 8 },
    };
    const exit_inst = instruction_mod.Instruction{
        .opcode = .Exit,
        .dst = null,
        .src = null,
        .off = null,
        .imm = null,
        .span = .{ .start = 0, .end = 8 },
    };
    const nodes = [_]ASTNode{
        .{ .Label = .{ .label = .{ .name = "entry", .span = .{ .start = 0, .end = 1 } }, .offset = 0 } },
        .{ .Instruction = .{ .instruction = mov_inst, .offset = 0 } },
        .{ .GlobalDecl = .{ .global_decl = .{ .entry_label = "entry", .span = .{ .start = 0, .end = 1 } } } },
        .{ .Instruction = .{ .instruction = exit_inst, .offset = 8 } },
    };
    const cs = CodeSection{ .nodes = &nodes, .size = 16 };

    const bytes = try cs.bytecode(testing.allocator);
    defer testing.allocator.free(bytes);

    try testing.expectEqual(@as(usize, 16), bytes.len);
    try testing.expectEqual(@as(u8, 0xb7), bytes[0]); // mov64 imm opcode
    try testing.expectEqual(@as(u8, 42), bytes[4]); // imm low byte
    try testing.expectEqual(@as(u8, 0x95), bytes[8]); // exit opcode
}

test "CodeSection: section header uses PROGBITS + ALLOC|EXECINSTR, align 4" {
    const cs = CodeSection{
        .nodes = &.{},
        .size = 0x40,
        .name_offset = 1,
        .offset = 0xe8,
    };
    var out: [64]u8 = undefined;
    cs.sectionHeaderBytecode(&out);

    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[0..4], .little)); // sh_name
    try testing.expectEqual(@as(u32, header_mod.SHT_PROGBITS), std.mem.readInt(u32, out[4..8], .little));
    try testing.expectEqual(header_mod.SHF_ALLOC | header_mod.SHF_EXECINSTR, std.mem.readInt(u64, out[8..16], .little));
    try testing.expectEqual(@as(u64, 0xe8), std.mem.readInt(u64, out[16..24], .little)); // sh_addr
    try testing.expectEqual(@as(u64, 0xe8), std.mem.readInt(u64, out[24..32], .little)); // sh_offset
    try testing.expectEqual(@as(u64, 0x40), std.mem.readInt(u64, out[32..40], .little)); // sh_size
    try testing.expectEqual(@as(u64, 4), std.mem.readInt(u64, out[48..56], .little)); // sh_addralign
}

test "DataSection: pads bytes to 8-byte boundary" {
    const ro1 = ast_mod.ROData{
        .name = "A",
        .bytes = "Hello",
        .span = .{ .start = 0, .end = 5 },
    };
    const nodes = [_]ASTNode{
        .{ .ROData = .{ .rodata = ro1, .offset = 0 } },
    };
    const ds = DataSection{ .nodes = &nodes, .size = 5 };

    const bytes = try ds.bytecode(testing.allocator);
    defer testing.allocator.free(bytes);

    // 5 bytes "Hello" + 3 zero bytes → 8.
    try testing.expectEqual(@as(usize, 8), bytes.len);
    try testing.expectEqualStrings("Hello", bytes[0..5]);
    try testing.expectEqual(@as(u8, 0), bytes[5]);
    try testing.expectEqual(@as(u8, 0), bytes[6]);
    try testing.expectEqual(@as(u8, 0), bytes[7]);
}

test "DataSection: concatenates multiple rodata entries in order" {
    const ro1 = ast_mod.ROData{ .name = "A", .bytes = "foo", .span = .{ .start = 0, .end = 3 } };
    const ro2 = ast_mod.ROData{ .name = "B", .bytes = "bar", .span = .{ .start = 0, .end = 3 } };
    const nodes = [_]ASTNode{
        .{ .ROData = .{ .rodata = ro1, .offset = 0 } },
        .{ .ROData = .{ .rodata = ro2, .offset = 3 } },
    };
    const ds = DataSection{ .nodes = &nodes, .size = 6 };

    const bytes = try ds.bytecode(testing.allocator);
    defer testing.allocator.free(bytes);

    try testing.expectEqual(@as(usize, 8), bytes.len); // 6 + 2 pad
    try testing.expectEqualStrings("foobar", bytes[0..6]);
}

test "DataSection: section header uses PROGBITS + ALLOC, unpadded sh_size" {
    const ds = DataSection{
        .nodes = &.{},
        .size = 5, // logical content size
        .name_offset = 7,
        .offset = 0x128,
    };
    var out: [64]u8 = undefined;
    ds.sectionHeaderBytecode(&out);

    try testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, out[0..4], .little)); // sh_name
    try testing.expectEqual(header_mod.SHF_ALLOC, std.mem.readInt(u64, out[8..16], .little));
    try testing.expectEqual(@as(u64, 5), std.mem.readInt(u64, out[32..40], .little)); // unpadded
    try testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, out[48..56], .little)); // align 1
}

test "DynSymEntry: 24-byte layout" {
    const e = DynSymEntry{
        .name = 1,
        .shndx = 1,
        .value = 0xe8,
        .size = 0,
    };
    var out: [24]u8 = undefined;
    e.bytecode(&out);

    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[0..4], .little));
    try testing.expectEqual(STB_GLOBAL_STT_NOTYPE, out[4]);
    try testing.expectEqual(@as(u8, 0), out[5]);
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[6..8], .little));
    try testing.expectEqual(@as(u64, 0xe8), std.mem.readInt(u64, out[8..16], .little));
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, out[16..24], .little));
}

test "DynSymSection: 3 entries → 72 bytes + header fields" {
    const entries = [_]DynSymEntry{
        .{ .name = 0, .shndx = 0, .value = 0 }, // STN_UNDEF
        .{ .name = 1, .shndx = 1, .value = 0xe8 }, // entrypoint
        .{ .name = 12, .shndx = 0, .value = 0 }, // sol_log_
    };
    const sym = DynSymSection{
        .name_offset = 0,
        .entries = &entries,
        .offset = 0x1f0,
        .link = 5,
    };

    const bytes = try sym.bytecode(testing.allocator);
    defer testing.allocator.free(bytes);

    try testing.expectEqual(@as(usize, 72), bytes.len);
    try testing.expectEqual(@as(u64, 72), sym.size());

    // First entry is STN_UNDEF (name=0, shndx=0, value=0).
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[0..4], .little));

    var hdr: [64]u8 = undefined;
    sym.sectionHeaderBytecode(&hdr);
    try testing.expectEqual(@as(u32, header_mod.SHT_DYNSYM), std.mem.readInt(u32, hdr[4..8], .little));
    try testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, hdr[40..44], .little)); // sh_link
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, hdr[44..48], .little)); // sh_info
    try testing.expectEqual(@as(u64, 24), std.mem.readInt(u64, hdr[56..64], .little)); // entsize
}

test "DynStrSection: names + leading null, padded to 8" {
    const names = [_][]const u8{ "entrypoint", "sol_log_" };
    var ds = DynStrSection{
        .name_offset = 0,
        .symbol_names = &names,
    };
    ds.setOffset(0x238);

    const bytes = try ds.bytecode(testing.allocator);
    defer testing.allocator.free(bytes);

    // Layout:
    //  [0]     = 0
    //  [1..11] = "entrypoint"
    //  [11]    = 0
    //  [12..20] = "sol_log_"
    //  [20]    = 0
    //  Total 21 bytes → padded to 24.
    try testing.expectEqual(@as(usize, 24), bytes.len);
    try testing.expectEqual(@as(u64, 24), ds.size());
    try testing.expectEqual(@as(u8, 0), bytes[0]);
    try testing.expectEqualStrings("entrypoint", bytes[1..11]);
    try testing.expectEqualStrings("sol_log_", bytes[12..20]);
}

test "RelDynEntry: packs r_info with (dynstr << 32) | rel_type" {
    const e = RelDynEntry{
        .offset = 0x110,
        .rel_type = R_SBF_SYSCALL,
        .dynstr_offset = 2,
    };
    var out: [16]u8 = undefined;
    e.bytecode(&out);

    try testing.expectEqual(@as(u64, 0x110), std.mem.readInt(u64, out[0..8], .little));
    const r_info = std.mem.readInt(u64, out[8..16], .little);
    try testing.expectEqual(@as(u64, (2 << 32) | R_SBF_SYSCALL), r_info);
}

test "DynamicSection: base size 160 (no RELCOUNT)" {
    const dyn = DynamicSection{
        .name_offset = 0,
        .offset = 0x140,
        .rel_offset = 0x250,
        .rel_size = 32,
        .rel_count = 0, // omits RELCOUNT tag
        .dynsym_offset = 0x1f0,
        .dynstr_offset = 0x238,
        .dynstr_size = 24,
    };

    const bytes = try dyn.bytecode(testing.allocator);
    defer testing.allocator.free(bytes);

    // 10 tags × 16 bytes = 160.
    try testing.expectEqual(@as(usize, 160), bytes.len);

    // First tag is DT_FLAGS = 0x1e, value = DF_TEXTREL = 0x04.
    try testing.expectEqual(DT_FLAGS, std.mem.readInt(u64, bytes[0..8], .little));
    try testing.expectEqual(DF_TEXTREL, std.mem.readInt(u64, bytes[8..16], .little));
    // Second tag is DT_REL.
    try testing.expectEqual(DT_REL, std.mem.readInt(u64, bytes[16..24], .little));
    try testing.expectEqual(@as(u64, 0x250), std.mem.readInt(u64, bytes[24..32], .little));
}

test "DynamicSection: with rel_count adds DT_RELCOUNT (176 bytes)" {
    const dyn = DynamicSection{
        .name_offset = 0,
        .rel_count = 1,
    };
    const bytes = try dyn.bytecode(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 176), bytes.len);
}

test "DynamicSection: header uses SHT_DYNAMIC + ALLOC|WRITE" {
    const dyn = DynamicSection{
        .name_offset = 3,
        .offset = 0x140,
        .link = 5,
    };
    var out: [64]u8 = undefined;
    dyn.sectionHeaderBytecode(&out);
    try testing.expectEqual(@as(u32, header_mod.SHT_DYNAMIC), std.mem.readInt(u32, out[4..8], .little));
    try testing.expectEqual(
        header_mod.SHF_ALLOC | header_mod.SHF_WRITE,
        std.mem.readInt(u64, out[8..16], .little),
    );
    try testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, out[40..44], .little));
    try testing.expectEqual(@as(u64, 16), std.mem.readInt(u64, out[56..64], .little));
}

test "DebugSection: bytecode is a verbatim copy of the input" {
    const payload = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x00, 0x01, 0x02, 0x03, 0x04 };
    const sec = DebugSection{
        .section_name = ".debug_info",
        .name_offset = 17,
        .data = &payload,
    };
    try testing.expectEqual(@as(u64, 9), sec.size());

    const bytes = try sec.bytecode(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &payload, bytes);
}

test "DebugSection: empty data yields zero-length section" {
    const sec = DebugSection{
        .section_name = ".debug_abbrev",
        .name_offset = 29,
        .data = &[_]u8{},
    };
    try testing.expectEqual(@as(u64, 0), sec.size());

    const bytes = try sec.bytecode(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 0), bytes.len);
}

test "DebugSection: header uses SHT_PROGBITS with zero flags and align 1" {
    const payload = [_]u8{ 0x11, 0x22, 0x33 };
    const sec = DebugSection{
        .section_name = ".debug_line",
        .name_offset = 41,
        .data = &payload,
        .offset = 0x2000,
    };
    var out: [64]u8 = undefined;
    sec.sectionHeaderBytecode(&out);
    // sh_name
    try testing.expectEqual(@as(u32, 41), std.mem.readInt(u32, out[0..4], .little));
    // sh_type == PROGBITS
    try testing.expectEqual(@as(u32, header_mod.SHT_PROGBITS), std.mem.readInt(u32, out[4..8], .little));
    // sh_flags == 0 (not loadable, not executable, not writable)
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, out[8..16], .little));
    // sh_addr == 0 (no VM mapping)
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, out[16..24], .little));
    // sh_offset
    try testing.expectEqual(@as(u64, 0x2000), std.mem.readInt(u64, out[24..32], .little));
    // sh_size
    try testing.expectEqual(@as(u64, 3), std.mem.readInt(u64, out[32..40], .little));
    // sh_addralign
    try testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, out[48..56], .little));
}

test "SectionType: dispatches name/size through each variant" {
    const ns: SectionType = .{ .null_ = NullSection.init() };
    try testing.expectEqualStrings("", ns.name());
    try testing.expectEqual(@as(u64, 0), ns.size());

    const names = [_][]const u8{".text"};
    const sh: SectionType = .{ .shstrtab = ShStrTabSection{
        .name_offset = 7,
        .section_names = &names,
    } };
    try testing.expectEqualStrings(".s", sh.name());

    const cs: SectionType = .{ .code = CodeSection{ .nodes = &.{}, .size = 0x40 } };
    try testing.expectEqualStrings(".text", cs.name());
    try testing.expectEqual(@as(u64, 0x40), cs.size());

    const ds: SectionType = .{ .data = DataSection{ .nodes = &.{}, .size = 5 } };
    try testing.expectEqualStrings(".rodata", ds.name());
    // Union dispatch returns emit-accurate (padded) size: 5 → 8.
    try testing.expectEqual(@as(u64, 8), ds.size());

    const debug_payload = [_]u8{ 1, 2, 3, 4 };
    const dbg: SectionType = .{ .debug = DebugSection{
        .section_name = ".debug_info",
        .name_offset = 0,
        .data = &debug_payload,
    } };
    try testing.expectEqualStrings(".debug_info", dbg.name());
    try testing.expectEqual(@as(u64, 4), dbg.size());
}

test "SectionType: setOffset propagates to the inner variant" {
    var cs: SectionType = .{ .code = CodeSection{ .nodes = &.{}, .size = 0x10 } };
    cs.setOffset(0x200);
    try testing.expectEqual(@as(u64, 0x200), cs.code.offset);

    var ns: SectionType = .{ .null_ = NullSection.init() };
    ns.setOffset(0xdead); // no-op — must not panic
    try testing.expect(@as(std.meta.Tag(SectionType), ns) == .null_);
}

test "SectionType: setNameOffset propagates to the inner variant" {
    var ds: SectionType = .{ .data = DataSection{ .nodes = &.{}, .size = 0x8 } };
    ds.setNameOffset(42);
    try testing.expectEqual(@as(u32, 42), ds.data.name_offset);

    var dbg: SectionType = .{ .debug = DebugSection{
        .section_name = ".debug_line",
        .name_offset = 0,
        .data = &[_]u8{},
    } };
    dbg.setNameOffset(99);
    try testing.expectEqual(@as(u32, 99), dbg.debug.name_offset);
}

test "SectionType: bytecode matches the concrete variant" {
    const cs_variant: SectionType = .{ .code = CodeSection{
        .nodes = &.{},
        .size = 0,
    } };
    const a = try cs_variant.bytecode(testing.allocator);
    defer testing.allocator.free(a);
    try testing.expectEqual(@as(usize, 0), a.len);

    const ns: SectionType = .{ .null_ = NullSection.init() };
    const b = try ns.bytecode(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 0), b.len);
}

test "SectionType: sectionHeaderBytecode threads name_offset through the variant" {
    var cs: SectionType = .{ .code = CodeSection{
        .nodes = &.{},
        .size = 0x40,
        .offset = 0xe8,
    } };
    cs.setNameOffset(1);

    var out: [64]u8 = undefined;
    cs.sectionHeaderBytecode(&out);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[0..4], .little));
    try testing.expectEqual(@as(u32, header_mod.SHT_PROGBITS), std.mem.readInt(u32, out[4..8], .little));
}
