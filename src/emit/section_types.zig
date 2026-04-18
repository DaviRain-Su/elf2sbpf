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

    /// Size in bytes of the string table content, **without** trailing
    /// 8-byte padding (matches Rust's `size()` at L276-289). The padding
    /// in bytecode() is Emit-layer alignment convenience; downstream
    /// offsetting should use this unpadded size.
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
    pub fn sectionHeaderBytecode(
        self: CodeSection,
        name_offset: u32,
        out: *[64]u8,
    ) void {
        const flags = header_mod.SHF_ALLOC | header_mod.SHF_EXECINSTR;
        const sh = SectionHeader.init(
            name_offset,
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
    offset: u64 = 0,

    pub fn name(self: DataSection) []const u8 {
        _ = self;
        return ".rodata";
    }

    pub fn setOffset(self: *DataSection, o: u64) void {
        self.offset = o;
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

    pub fn sectionHeaderBytecode(
        self: DataSection,
        name_offset: u32,
        out: *[64]u8,
    ) void {
        const sh = SectionHeader.init(
            name_offset,
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
        .dst = null, .src = null, .off = null, .imm = null,
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
        .dst = .{ .n = 0 }, .src = null, .off = null,
        .imm = .{ .right = .{ .Int = 42 } },
        .span = .{ .start = 0, .end = 8 },
    };
    const exit_inst = instruction_mod.Instruction{
        .opcode = .Exit,
        .dst = null, .src = null, .off = null, .imm = null,
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
        .offset = 0xe8,
    };
    var out: [64]u8 = undefined;
    cs.sectionHeaderBytecode(1, &out);

    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[0..4], .little)); // sh_name
    try testing.expectEqual(@as(u32, header_mod.SHT_PROGBITS), std.mem.readInt(u32, out[4..8], .little));
    try testing.expectEqual(header_mod.SHF_ALLOC | header_mod.SHF_EXECINSTR, std.mem.readInt(u64, out[8..16], .little));
    try testing.expectEqual(@as(u64, 0xe8), std.mem.readInt(u64, out[16..24], .little)); // sh_addr
    try testing.expectEqual(@as(u64, 0xe8), std.mem.readInt(u64, out[24..32], .little)); // sh_offset
    try testing.expectEqual(@as(u64, 0x40), std.mem.readInt(u64, out[32..40], .little)); // sh_size
    try testing.expectEqual(@as(u64, 4), std.mem.readInt(u64, out[48..56], .little));   // sh_addralign
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
        .offset = 0x128,
    };
    var out: [64]u8 = undefined;
    ds.sectionHeaderBytecode(7, &out);

    try testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, out[0..4], .little)); // sh_name
    try testing.expectEqual(header_mod.SHF_ALLOC, std.mem.readInt(u64, out[8..16], .little));
    try testing.expectEqual(@as(u64, 5), std.mem.readInt(u64, out[32..40], .little)); // unpadded
    try testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, out[48..56], .little)); // align 1
}
