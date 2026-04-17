// Instruction — a decoded BPF instruction with either resolved or unresolved
// operands.
//
// Mirrors Rust sbpf-common::instruction::Instruction (sbpf/crates/common/src/instruction.rs L21-29).
//
// Spec: 03-technical-spec.md §2.1
// Tests: 05-test-spec.md §4.4

const std = @import("std");
const Opcode = @import("opcode.zig").Opcode;
const Number = @import("number.zig").Number;
const Register = @import("register.zig").Register;

/// Byte range into the original source — used for error reporting. The name
/// mirrors Rust's `Range<usize>` in sbpf-common; we use a named struct so
/// that `.start` / `.end` are self-documenting.
pub const Span = struct {
    start: usize,
    end: usize,
};

/// Either-of-two tagged union. Rust uses the `either` crate's `Either<L, R>`;
/// Zig stdlib has no equivalent so we define our own comptime function.
///
/// Convention matches `either::Either`:
///   - `left`  → typically an unresolved symbolic name / label
///   - `right` → typically a resolved numeric value
pub fn Either(comptime L: type, comptime R: type) type {
    return union(enum) {
        left: L,
        right: R,
    };
}

/// Number of bytes a single BPF instruction occupies in the text section.
/// Lddw is the only 16-byte form; everything else is 8.
pub const INSTRUCTION_SIZE: u64 = 8;
pub const LDDW_SIZE: u64 = 16;

/// A single BPF instruction.
///
/// All operand fields are optional because each opcode uses a different
/// subset (e.g. `exit` uses none, `add64 r1, r2` uses dst+src only,
/// `call imm` uses imm). Before relocation resolution, `off` and `imm`
/// may be symbolic labels (`.left`) rather than numeric values (`.right`).
pub const Instruction = struct {
    opcode: Opcode,
    dst: ?Register,
    src: ?Register,
    off: ?Either([]const u8, i16),
    imm: ?Either([]const u8, Number),
    span: Span,

    /// Size in bytes of this instruction in the text section.
    /// Per BPF spec: Lddw is 16 bytes (two slots); every other opcode is 8.
    pub fn getSize(self: Instruction) u64 {
        return switch (self.opcode) {
            .Lddw => LDDW_SIZE,
            else => INSTRUCTION_SIZE,
        };
    }

    /// True iff this is a branch instruction (jumps, including unconditional).
    /// Call, Callx, Exit are intentionally **not** considered jumps —
    /// matching Rust's OperationType classification (opcode.rs L16-30).
    pub fn isJump(self: Instruction) bool {
        return switch (self.opcode) {
            .Ja,
            .JeqImm, .JeqReg,
            .JgtImm, .JgtReg,
            .JgeImm, .JgeReg,
            .JltImm, .JltReg,
            .JleImm, .JleReg,
            .JsetImm, .JsetReg,
            .JneImm, .JneReg,
            .JsgtImm, .JsgtReg,
            .JsgeImm, .JsgeReg,
            .JsltImm, .JsltReg,
            .JsleImm, .JsleReg,
            => true,
            else => false,
        };
    }

    /// True iff this is a Call whose target is still an unresolved symbol —
    /// i.e. a syscall candidate waiting for relocation. After buildProgram
    /// (ast.zig) resolves syscalls, imm becomes `.right(Number.Int(hash))`
    /// and this returns false.
    ///
    /// Simplified version of Rust is_syscall (instruction.rs L52-59): Rust
    /// consults a REGISTERED_SYSCALLS whitelist; we do not have the whitelist
    /// yet (syscalls.zig lands in B.9). For C1, every unresolved Call label
    /// is treated as a syscall candidate — byteparser only ever reaches this
    /// with syscall-bound labels, so the under-check has no practical impact.
    /// TODO(B.9): swap in the whitelist once syscalls.zig is ready.
    pub fn isSyscall(self: Instruction) bool {
        if (self.opcode != .Call) return false;
        const imm = self.imm orelse return false;
        return switch (imm) {
            .left => true,
            .right => false,
        };
    }

    /// Decode a BPF instruction from raw bytes.
    /// Consumes either 8 bytes (most opcodes) or 16 bytes (Lddw).
    /// Not yet implemented — B.6.
    pub fn fromBytes(bytes: []const u8) !Instruction {
        _ = bytes;
        @panic("Instruction.fromBytes not implemented yet (task B.6)");
    }

    /// Encode an Instruction into bytes.
    /// Writes either 8 or 16 bytes into `out` depending on opcode.
    /// Not yet implemented — B.7.
    pub fn toBytes(self: Instruction, out: []u8) !void {
        _ = self;
        _ = out;
        @panic("Instruction.toBytes not implemented yet (task B.7)");
    }
};

// --- tests ---

test "Span struct" {
    const s = Span{ .start = 10, .end = 20 };
    try std.testing.expectEqual(@as(usize, 10), s.start);
    try std.testing.expectEqual(@as(usize, 20), s.end);
}

test "Either.left / Either.right construct and dispatch" {
    const E = Either([]const u8, i16);
    const l = E{ .left = "label" };
    const r = E{ .right = 42 };

    try std.testing.expectEqualStrings("label", l.left);
    try std.testing.expectEqual(@as(i16, 42), r.right);
}

test "Instruction.getSize: Lddw is 16" {
    const inst = Instruction{
        .opcode = .Lddw,
        .dst = Register{ .n = 1 },
        .src = null,
        .off = null,
        .imm = .{ .right = .{ .Int = 0 } },
        .span = .{ .start = 0, .end = 16 },
    };
    try std.testing.expectEqual(@as(u64, 16), inst.getSize());
}

test "Instruction.getSize: non-Lddw is 8" {
    const inst = Instruction{
        .opcode = .Exit,
        .dst = null,
        .src = null,
        .off = null,
        .imm = null,
        .span = .{ .start = 0, .end = 8 },
    };
    try std.testing.expectEqual(@as(u64, 8), inst.getSize());
}

test "Instruction.isJump: true for all Jxx opcodes" {
    const jump_opcodes = [_]Opcode{
        .Ja,
        .JeqImm,    .JeqReg,
        .JgtImm,    .JgtReg,
        .JgeImm,    .JgeReg,
        .JltImm,    .JltReg,
        .JleImm,    .JleReg,
        .JsetImm,   .JsetReg,
        .JneImm,    .JneReg,
        .JsgtImm,   .JsgtReg,
        .JsgeImm,   .JsgeReg,
        .JsltImm,   .JsltReg,
        .JsleImm,   .JsleReg,
    };
    for (jump_opcodes) |op| {
        const inst = Instruction{
            .opcode = op,
            .dst = null,
            .src = null,
            .off = null,
            .imm = null,
            .span = .{ .start = 0, .end = 8 },
        };
        try std.testing.expect(inst.isJump());
    }
}

test "Instruction.isJump: false for Call / Callx / Exit" {
    const non_jumps = [_]Opcode{ .Call, .Callx, .Exit };
    for (non_jumps) |op| {
        const inst = Instruction{
            .opcode = op,
            .dst = null,
            .src = null,
            .off = null,
            .imm = null,
            .span = .{ .start = 0, .end = 8 },
        };
        try std.testing.expect(!inst.isJump());
    }
}

test "Instruction.isJump: false for ALU / load / store" {
    const non_jumps = [_]Opcode{ .Add64Imm, .Mov32Reg, .Ldxw, .Stxb, .Lddw };
    for (non_jumps) |op| {
        const inst = Instruction{
            .opcode = op,
            .dst = null,
            .src = null,
            .off = null,
            .imm = null,
            .span = .{ .start = 0, .end = 8 },
        };
        try std.testing.expect(!inst.isJump());
    }
}

test "Instruction.isSyscall: true for Call with left(label)" {
    const inst = Instruction{
        .opcode = .Call,
        .dst = null,
        .src = null,
        .off = null,
        .imm = .{ .left = "sol_log_" },
        .span = .{ .start = 0, .end = 8 },
    };
    try std.testing.expect(inst.isSyscall());
}

test "Instruction.isSyscall: false for Call with right(resolved)" {
    const inst = Instruction{
        .opcode = .Call,
        .dst = null,
        .src = null,
        .off = null,
        .imm = .{ .right = .{ .Int = 0x207559bd } },
        .span = .{ .start = 0, .end = 8 },
    };
    try std.testing.expect(!inst.isSyscall());
}

test "Instruction.isSyscall: false for non-Call" {
    const inst = Instruction{
        .opcode = .Add64Imm,
        .dst = null,
        .src = null,
        .off = null,
        .imm = .{ .left = "some_name" },
        .span = .{ .start = 0, .end = 8 },
    };
    try std.testing.expect(!inst.isSyscall());
}
