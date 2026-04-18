// AST — the mid-level representation between byteparser and the emit
// stage. Holds two ordered lists (text nodes and rodata nodes) plus the
// merged-image sizes.
//
// Rust sbpf-assembler::ast::AST (sbpf/crates/assembler/src/ast.rs L19-30).
// C1 ports just enough for buildProgram (E.3); the full text-parser
// variants of AST construction are deferred to D.
//
// Spec: 03-technical-spec.md §2.3
// Tests: 05-test-spec.md §4.8

const std = @import("std");
const node_mod = @import("node.zig");
const instruction_mod = @import("../common/instruction.zig");

pub const ASTNode = node_mod.ASTNode;
pub const Label = node_mod.Label;
pub const ROData = node_mod.ROData;
pub const GlobalDecl = node_mod.GlobalDecl;

/// Target SBPF architecture. V0 is what elf2sbpf C1 MVP targets; V3 is
/// deferred to D.
pub const SbpfArch = enum { V0, V3 };

/// Owner of the node lists plus merged-image sizes.
pub const AST = struct {
    allocator: std.mem.Allocator,
    /// Text-image nodes: Label + Instruction + GlobalDecl, in emit order.
    /// (GlobalDecl has no offset but lives here to match Rust's single
    /// node list for the ast-building algorithm.)
    nodes: std.ArrayList(ASTNode),
    /// Rodata-image nodes: ROData only.
    rodata_nodes: std.ArrayList(ASTNode),
    /// Total size of the merged text image in bytes.
    text_size: u64,
    /// Total size of the merged rodata image in bytes.
    rodata_size: u64,

    pub fn init(allocator: std.mem.Allocator) AST {
        return AST{
            .allocator = allocator,
            .nodes = .empty,
            .rodata_nodes = .empty,
            .text_size = 0,
            .rodata_size = 0,
        };
    }

    pub fn deinit(self: *AST) void {
        self.nodes.deinit(self.allocator);
        self.rodata_nodes.deinit(self.allocator);
    }

    pub fn setTextSize(self: *AST, size: u64) void {
        self.text_size = size;
    }

    pub fn setRodataSize(self: *AST, size: u64) void {
        self.rodata_size = size;
    }

    pub fn pushNode(self: *AST, n: ASTNode) !void {
        try self.nodes.append(self.allocator, n);
    }

    pub fn pushRodataNode(self: *AST, n: ASTNode) !void {
        try self.rodata_nodes.append(self.allocator, n);
    }

    /// Find the Instruction node whose offset matches `offset`. Returns a
    /// mutable pointer so E.3's buildProgram can rewrite `imm`/`off`
    /// fields in place.
    ///
    /// Rust ast.rs L48-61. Linear scan is fine — N is bounded by the
    /// number of instructions (~200 for counter.o); a binary search
    /// would require keeping nodes sorted, which isn't guaranteed by
    /// the build order.
    pub fn getInstructionAtOffset(self: *AST, offset: u64) ?*instruction_mod.Instruction {
        for (self.nodes.items) |*n| {
            switch (n.*) {
                .Instruction => |*payload| {
                    if (payload.offset == offset) return &payload.instruction;
                },
                else => {},
            }
        }
        return null;
    }

    /// Lookup a rodata node by its in-rodata offset. Mirrors Rust's
    /// get_rodata_at_offset (ast.rs L63-78).
    pub fn getRodataAtOffset(self: *AST, offset: u64) ?*ROData {
        for (self.rodata_nodes.items) |*n| {
            switch (n.*) {
                .ROData => |*payload| {
                    if (payload.offset == offset) return &payload.rodata;
                },
                else => {},
            }
        }
        return null;
    }
};

// --- tests ---

const testing = std.testing;

test "AST init/deinit clean baseline" {
    var ast = AST.init(testing.allocator);
    defer ast.deinit();
    try testing.expectEqual(@as(usize, 0), ast.nodes.items.len);
    try testing.expectEqual(@as(usize, 0), ast.rodata_nodes.items.len);
    try testing.expectEqual(@as(u64, 0), ast.text_size);
    try testing.expectEqual(@as(u64, 0), ast.rodata_size);
}

test "AST.setTextSize / setRodataSize update fields" {
    var ast = AST.init(testing.allocator);
    defer ast.deinit();
    ast.setTextSize(64);
    ast.setRodataSize(23);
    try testing.expectEqual(@as(u64, 64), ast.text_size);
    try testing.expectEqual(@as(u64, 23), ast.rodata_size);
}

test "AST.pushNode / pushRodataNode append in order" {
    var ast = AST.init(testing.allocator);
    defer ast.deinit();
    try ast.pushNode(.{ .Label = .{
        .label = .{ .name = "a", .span = .{ .start = 0, .end = 1 } },
        .offset = 0,
    } });
    try ast.pushNode(.{ .Label = .{
        .label = .{ .name = "b", .span = .{ .start = 0, .end = 1 } },
        .offset = 8,
    } });
    try ast.pushRodataNode(.{ .ROData = .{
        .rodata = .{ .name = "foo", .bytes = "x", .span = .{ .start = 0, .end = 1 } },
        .offset = 0,
    } });

    try testing.expectEqual(@as(usize, 2), ast.nodes.items.len);
    try testing.expectEqual(@as(usize, 1), ast.rodata_nodes.items.len);

    const first = ast.nodes.items[0];
    try testing.expectEqualStrings("a", first.Label.label.name);
    const second = ast.nodes.items[1];
    try testing.expectEqual(@as(u64, 8), second.Label.offset);
}

test "AST.getInstructionAtOffset finds matching instruction" {
    var ast = AST.init(testing.allocator);
    defer ast.deinit();

    // Put two instructions at offsets 0 and 8, plus a label in between.
    const exit_inst = instruction_mod.Instruction{
        .opcode = .Exit,
        .dst = null,
        .src = null,
        .off = null,
        .imm = null,
        .span = .{ .start = 0, .end = 8 },
    };
    const mov_inst = instruction_mod.Instruction{
        .opcode = .Mov64Imm,
        .dst = .{ .n = 0 },
        .src = null,
        .off = null,
        .imm = .{ .right = .{ .Int = 0 } },
        .span = .{ .start = 0, .end = 8 },
    };
    try ast.pushNode(.{ .Instruction = .{ .instruction = mov_inst, .offset = 0 } });
    try ast.pushNode(.{ .Label = .{
        .label = .{ .name = "mid", .span = .{ .start = 0, .end = 1 } },
        .offset = 8,
    } });
    try ast.pushNode(.{ .Instruction = .{ .instruction = exit_inst, .offset = 8 } });

    const found = ast.getInstructionAtOffset(8) orelse return error.TestExpectedFound;
    try testing.expectEqual(instruction_mod.Instruction.getSize(found.*), 8);
    try testing.expectEqual(@as(@TypeOf(exit_inst.opcode), .Exit), found.opcode);

    try testing.expect(ast.getInstructionAtOffset(100) == null);

    // Mutate via the returned pointer.
    found.dst = .{ .n = 7 };
    const again = ast.getInstructionAtOffset(8).?;
    try testing.expectEqual(@as(u8, 7), again.dst.?.n);
}

test "AST.getRodataAtOffset finds matching rodata entry" {
    var ast = AST.init(testing.allocator);
    defer ast.deinit();

    try ast.pushRodataNode(.{ .ROData = .{
        .rodata = .{ .name = "FOO", .bytes = "abc", .span = .{ .start = 0, .end = 3 } },
        .offset = 0,
    } });
    try ast.pushRodataNode(.{ .ROData = .{
        .rodata = .{ .name = "BAR", .bytes = "xy", .span = .{ .start = 0, .end = 2 } },
        .offset = 3,
    } });

    const foo = ast.getRodataAtOffset(0) orelse return error.TestExpectedFound;
    try testing.expectEqualStrings("FOO", foo.name);

    const bar = ast.getRodataAtOffset(3) orelse return error.TestExpectedFound;
    try testing.expectEqualStrings("BAR", bar.name);
    try testing.expectEqualSlices(u8, "xy", bar.bytes);

    try testing.expect(ast.getRodataAtOffset(100) == null);
}
