// AST node types — a tagged union covering the 4 node kinds byteparser
// actually produces (Label, ROData, Instruction, GlobalDecl).
//
// Rust sbpf-assembler has 8 variants total; the other 4 (Directive,
// EquDecl, ExternDecl, RodataDecl) are only emitted by the assembler
// text parser, which C1 doesn't port. They'll be added in D if that
// path is ever ported.
//
// Spec: 03-technical-spec.md §2.3
// Tests: 05-test-spec.md §4.8

const std = @import("std");
const instruction_mod = @import("../common/instruction.zig");
const number_mod = @import("../common/number.zig");

pub const Span = instruction_mod.Span;

/// A symbolic label — either an entrypoint from the Rust `Label` struct
/// or a jump target within a text section. Rust astnode.rs L89-93.
pub const Label = struct {
    name: []const u8,
    span: Span,
};

/// A rodata entry in the AST. Rust astnode.rs L95-100. For byteparser-
/// produced ASTs, `args` always holds a single VectorLiteral of u8
/// byte values; the assembler's text parser can produce other shapes
/// (StringLiteral, multiple Directive tokens) that we don't need here.
pub const ROData = struct {
    name: []const u8,
    /// Byte values for the rodata entry. Stored as a byte slice to avoid
    /// the `Vec<Number>` allocation Rust uses — the semantics are the
    /// same, just skipping the per-byte tagged union.
    bytes: []const u8,
    span: Span,
};

/// Declaration that a particular label is the program entrypoint.
/// Rust astnode.rs L47-51.
pub const GlobalDecl = struct {
    entry_label: []const u8,
    span: Span,
};

/// The 4-variant subset of Rust's ASTNode enum that byteparser produces.
/// Each variant that has a location in the merged text image carries an
/// explicit `offset` field (Label, Instruction, ROData).
///
/// Memory ownership:
///   - `Label.name` / `GlobalDecl.entry_label` are borrowed from the
///     ELF strtab (their backing buffer is `file.bytes`).
///   - `ROData.name` may be borrowed (from a named symbol) or owned
///     by the caller's arena (from D.4 gap-fill); the AST doesn't track
///     this — `ByteParseResult.deinit` owns the lifetime.
///   - `ROData.bytes` is always borrowed from `ElfFile.bytes`.
///   - `Instruction.imm.left` strings likewise borrow from strtab or
///     from gap-fill names; see byteparser.zig for the provenance.
pub const ASTNode = union(enum) {
    Label: struct { label: Label, offset: u64 },
    Instruction: struct { instruction: instruction_mod.Instruction, offset: u64 },
    ROData: struct { rodata: ROData, offset: u64 },
    GlobalDecl: struct { global_decl: GlobalDecl },

    /// True if this node lives in the text image (Label or Instruction).
    pub fn isTextNode(self: ASTNode) bool {
        return switch (self) {
            .Label, .Instruction => true,
            else => false,
        };
    }

    /// True if this node lives in the rodata image.
    pub fn isRodataNode(self: ASTNode) bool {
        return switch (self) {
            .ROData => true,
            else => false,
        };
    }

    /// Returns the offset field for nodes that carry one; null for
    /// GlobalDecl (which doesn't live in either image).
    pub fn offset(self: ASTNode) ?u64 {
        return switch (self) {
            .Label => |n| n.offset,
            .Instruction => |n| n.offset,
            .ROData => |n| n.offset,
            .GlobalDecl => null,
        };
    }
};

// --- tests ---

const testing = std.testing;

test "ASTNode.Label constructs and classifies as text" {
    const node = ASTNode{
        .Label = .{
            .label = .{ .name = "foo", .span = .{ .start = 0, .end = 3 } },
            .offset = 16,
        },
    };
    try testing.expect(node.isTextNode());
    try testing.expect(!node.isRodataNode());
    try testing.expectEqual(@as(?u64, 16), node.offset());
}

test "ASTNode.Instruction constructs and classifies as text" {
    const inst = instruction_mod.Instruction{
        .opcode = .Exit,
        .dst = null,
        .src = null,
        .off = null,
        .imm = null,
        .span = .{ .start = 0, .end = 8 },
    };
    const node = ASTNode{
        .Instruction = .{ .instruction = inst, .offset = 56 },
    };
    try testing.expect(node.isTextNode());
    try testing.expect(!node.isRodataNode());
    try testing.expectEqual(@as(?u64, 56), node.offset());
}

test "ASTNode.ROData constructs and classifies as rodata" {
    const rodata = ROData{
        .name = ".rodata.__anon_x_0",
        .bytes = "Hello\x00",
        .span = .{ .start = 0, .end = 1 },
    };
    const node = ASTNode{ .ROData = .{ .rodata = rodata, .offset = 0 } };
    try testing.expect(!node.isTextNode());
    try testing.expect(node.isRodataNode());
    try testing.expectEqual(@as(?u64, 0), node.offset());
    try testing.expectEqualStrings("Hello\x00", node.ROData.rodata.bytes);
}

test "ASTNode.GlobalDecl has no offset" {
    const node = ASTNode{
        .GlobalDecl = .{
            .global_decl = .{
                .entry_label = "entrypoint",
                .span = .{ .start = 0, .end = 10 },
            },
        },
    };
    try testing.expect(!node.isTextNode());
    try testing.expect(!node.isRodataNode());
    try testing.expectEqual(@as(?u64, null), node.offset());
}

test "Label stores span correctly" {
    const label = Label{
        .name = "entrypoint",
        .span = .{ .start = 10, .end = 20 },
    };
    try testing.expectEqualStrings("entrypoint", label.name);
    try testing.expectEqual(@as(usize, 10), label.span.start);
    try testing.expectEqual(@as(usize, 20), label.span.end);
}

test "ROData exposes name and bytes via fields" {
    const ro = ROData{
        .name = "FOO",
        .bytes = "\x01\x02\x03",
        .span = .{ .start = 0, .end = 3 },
    };
    try testing.expectEqualStrings("FOO", ro.name);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, ro.bytes);
}
