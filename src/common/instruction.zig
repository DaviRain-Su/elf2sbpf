// Instruction — a decoded BPF instruction with either resolved or unresolved
// operands.
//
// Mirrors Rust sbpf-common::instruction::Instruction (sbpf/crates/common/src/instruction.rs L21-29).
//
// Spec: 03-technical-spec.md §2.1
// Tests: 05-test-spec.md §4.4

const std = @import("std");
const opcode_mod = @import("opcode.zig");
const Opcode = opcode_mod.Opcode;
const OperationType = opcode_mod.OperationType;
const Number = @import("number.zig").Number;
const Register = @import("register.zig").Register;

/// Errors returned by Instruction byte encode/decode.
pub const DecodeError = error{
    TooShort,
    UnknownOpcode,
    FieldMustBeZero, // an opcode's "must be zero" field had a non-zero value
    InvalidSrcRegister, // Call imm's src must be 0 or 1
};

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
    ///
    /// Port of Rust sbpf-common::decode::* family (decode.rs) dispatched through
    /// the per-opcode OperationType classification. Byte layout (little-endian):
    ///
    ///   Byte 0:    opcode
    ///   Byte 1:    (src << 4) | dst  (4 bits each)
    ///   Bytes 2-3: off (i16)
    ///   Bytes 4-7: imm (i32; for Lddw this is the low 32 bits)
    ///   Bytes 8-15 (Lddw only): second slot — bytes 12-15 hold the high 32 bits
    ///
    /// Fields not valid for an opcode are set to null; this follows the
    /// Rust decoder's convention so that `toBytes` can write zeros for them.
    ///
    /// For Solana syscall resolution (Call opcode with src=0): Rust's decoder
    /// looks up the imm value in the SYSCALLS table and returns `.left(name)`.
    /// We do not have that table yet (B.9 — syscalls.zig), so for now we
    /// always return `.right(Number.Int(imm))`. The byteparser overwrites imm
    /// with `.left(symbol_name)` via ELF relocations anyway, so this is
    /// correct for elf2sbpf's pipeline.
    pub fn fromBytes(bytes: []const u8) DecodeError!Instruction {
        if (bytes.len < 8) return DecodeError.TooShort;

        const op = Opcode.fromByte(bytes[0]) orelse return DecodeError.UnknownOpcode;

        // Parse the common 8-byte layout.
        const regs: u8 = bytes[1];
        const dst_raw: u8 = regs & 0x0f;
        const src_raw: u8 = regs >> 4;
        const off_raw: i16 = @bitCast(std.mem.readInt(u16, bytes[2..4], .little));
        const imm_raw: i32 = @bitCast(std.mem.readInt(u32, bytes[4..8], .little));

        var inst = Instruction{
            .opcode = op,
            .dst = null,
            .src = null,
            .off = null,
            .imm = null,
            .span = .{ .start = 0, .end = 8 },
        };

        switch (op.operationType()) {
            .LoadImmediate => {
                // Lddw: 16-byte instruction; src/off must be 0 in the first
                // slot; imm_high comes from bytes 12..15 of the second slot.
                if (bytes.len < 16) return DecodeError.TooShort;
                if (src_raw != 0 or off_raw != 0) return DecodeError.FieldMustBeZero;

                const imm_high: i32 = @bitCast(std.mem.readInt(u32, bytes[12..16], .little));
                // Combine: high 32 bits in top, unsigned low 32 bits in bottom.
                const imm_u64: u64 = (@as(u64, @as(u32, @bitCast(imm_high))) << 32) | @as(u32, @bitCast(imm_raw));
                const imm_i64: i64 = @bitCast(imm_u64);

                inst.dst = Register{ .n = dst_raw };
                inst.imm = .{ .right = Number{ .Int = imm_i64 } };
                inst.span = .{ .start = 0, .end = 16 };
            },

            .LoadMemory => {
                // dst, src, off; imm must be 0.
                if (imm_raw != 0) return DecodeError.FieldMustBeZero;
                inst.dst = Register{ .n = dst_raw };
                inst.src = Register{ .n = src_raw };
                inst.off = .{ .right = off_raw };
            },

            .StoreImmediate => {
                // dst, off, imm; src must be 0.
                if (src_raw != 0) return DecodeError.FieldMustBeZero;
                inst.dst = Register{ .n = dst_raw };
                inst.off = .{ .right = off_raw };
                inst.imm = .{ .right = Number{ .Int = imm_raw } };
            },

            .StoreRegister => {
                // dst, src, off; imm must be 0.
                if (imm_raw != 0) return DecodeError.FieldMustBeZero;
                inst.dst = Register{ .n = dst_raw };
                inst.src = Register{ .n = src_raw };
                inst.off = .{ .right = off_raw };
            },

            .BinaryImmediate => {
                // dst, imm; src and off must be 0.
                if (src_raw != 0 or off_raw != 0) return DecodeError.FieldMustBeZero;
                inst.dst = Register{ .n = dst_raw };
                inst.imm = .{ .right = Number{ .Int = imm_raw } };
            },

            .BinaryRegister => {
                // dst, src; off and imm must be 0.
                if (off_raw != 0 or imm_raw != 0) return DecodeError.FieldMustBeZero;
                inst.dst = Register{ .n = dst_raw };
                inst.src = Register{ .n = src_raw };
            },

            .Unary => {
                // dst only; src, off, imm must be 0.
                if (src_raw != 0 or off_raw != 0 or imm_raw != 0) return DecodeError.FieldMustBeZero;
                inst.dst = Register{ .n = dst_raw };
            },

            .Jump => {
                // off only (Ja); dst, src, imm must be 0.
                if (dst_raw != 0 or src_raw != 0 or imm_raw != 0) return DecodeError.FieldMustBeZero;
                inst.off = .{ .right = off_raw };
            },

            .JumpImmediate => {
                // dst, off, imm; src must be 0.
                if (src_raw != 0) return DecodeError.FieldMustBeZero;
                inst.dst = Register{ .n = dst_raw };
                inst.off = .{ .right = off_raw };
                inst.imm = .{ .right = Number{ .Int = imm_raw } };
            },

            .JumpRegister => {
                // dst, src, off; imm must be 0.
                if (imm_raw != 0) return DecodeError.FieldMustBeZero;
                inst.dst = Register{ .n = dst_raw };
                inst.src = Register{ .n = src_raw };
                inst.off = .{ .right = off_raw };
            },

            .CallImmediate => {
                // Call: dst and off must be 0. src is 0 (static syscall) or
                // 1 (pc-relative). The imm means different things:
                //   src=0: syscall hash (resolved via whitelist → .left(name));
                //          if no whitelist match, kept as .right(hash)
                //   src=1: pc-relative target offset (.right)
                if (dst_raw != 0 or off_raw != 0) return DecodeError.FieldMustBeZero;
                if (src_raw != 0 and src_raw != 1) return DecodeError.InvalidSrcRegister;
                inst.src = Register{ .n = src_raw };
                // Syscall whitelist lookup deferred to B.9. For now always
                // return numeric imm; byteparser overwrites with .left via
                // ELF relocation processing anyway.
                inst.imm = .{ .right = Number{ .Int = imm_raw } };
            },

            .CallRegister => {
                // Callx: SBPF encodes dst_reg in the imm field for back-compat.
                // Normalize: if dst==0 and imm!=0, take dst from imm.
                var final_dst = dst_raw;
                var final_imm = imm_raw;
                if (final_dst == 0 and final_imm != 0) {
                    final_dst = @intCast(final_imm & 0xff);
                    final_imm = 0;
                }
                if (src_raw != 0 or off_raw != 0 or final_imm != 0) {
                    return DecodeError.FieldMustBeZero;
                }
                inst.dst = Register{ .n = final_dst };
            },

            .Exit => {
                // No fields; all raws must be 0.
                if (dst_raw != 0 or src_raw != 0 or off_raw != 0 or imm_raw != 0) {
                    return DecodeError.FieldMustBeZero;
                }
            },
        }

        return inst;
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

// --- fromBytes tests ---

test "fromBytes rejects < 8 bytes" {
    try std.testing.expectError(DecodeError.TooShort, Instruction.fromBytes(&[_]u8{}));
    try std.testing.expectError(DecodeError.TooShort, Instruction.fromBytes(&[_]u8{ 0, 0, 0, 0, 0, 0, 0 }));
}

test "fromBytes rejects unknown opcode 0xff" {
    const bytes = [_]u8{ 0xff, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(DecodeError.UnknownOpcode, Instruction.fromBytes(&bytes));
}

test "fromBytes rejects JMP32 (0x16) — spec §8 #16" {
    const bytes = [_]u8{ 0x16, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(DecodeError.UnknownOpcode, Instruction.fromBytes(&bytes));
}

test "fromBytes decodes `r0 = 0` (mov64 imm)" {
    // b7 00 00 00 00 00 00 00 — real hello.o instruction (next-to-last)
    const bytes = [_]u8{ 0xb7, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const inst = try Instruction.fromBytes(&bytes);
    try std.testing.expectEqual(Opcode.Mov64Imm, inst.opcode);
    try std.testing.expectEqual(@as(u8, 0), inst.dst.?.n);
    try std.testing.expect(inst.src == null);
    try std.testing.expect(inst.off == null);
    try std.testing.expectEqual(@as(i64, 0), inst.imm.?.right.Int);
    try std.testing.expectEqual(@as(u64, 8), inst.getSize());
}

test "fromBytes decodes `exit`" {
    // 95 00 00 00 00 00 00 00 — hello.o last instruction
    const bytes = [_]u8{ 0x95, 0, 0, 0, 0, 0, 0, 0 };
    const inst = try Instruction.fromBytes(&bytes);
    try std.testing.expectEqual(Opcode.Exit, inst.opcode);
    try std.testing.expect(inst.dst == null);
    try std.testing.expect(inst.src == null);
    try std.testing.expect(inst.off == null);
    try std.testing.expect(inst.imm == null);
}

test "fromBytes decodes `call 0x207559bd` (sol_log_ hash)" {
    // 85 00 00 00 bd 59 75 20 — hello.o call to sol_log_
    const bytes = [_]u8{ 0x85, 0x00, 0x00, 0x00, 0xbd, 0x59, 0x75, 0x20 };
    const inst = try Instruction.fromBytes(&bytes);
    try std.testing.expectEqual(Opcode.Call, inst.opcode);
    try std.testing.expect(inst.dst == null);
    try std.testing.expectEqual(@as(u8, 0), inst.src.?.n);
    try std.testing.expectEqual(@as(i64, 0x207559bd), inst.imm.?.right.Int);
}

test "fromBytes decodes lddw (16 bytes)" {
    // Synthetic: lddw r1, 0x123456789abcdef0
    // first 8:  18 01 00 00 f0 de bc 9a   (opcode=0x18, dst=1, low=0x9abcdef0)
    // second 8: 00 00 00 00 78 56 34 12   (pseudo-slot, high=0x12345678)
    const bytes = [_]u8{
        0x18, 0x01, 0x00, 0x00, 0xf0, 0xde, 0xbc, 0x9a,
        0x00, 0x00, 0x00, 0x00, 0x78, 0x56, 0x34, 0x12,
    };
    const inst = try Instruction.fromBytes(&bytes);
    try std.testing.expectEqual(Opcode.Lddw, inst.opcode);
    try std.testing.expectEqual(@as(u8, 1), inst.dst.?.n);
    try std.testing.expect(inst.src == null);
    try std.testing.expect(inst.off == null);
    try std.testing.expectEqual(@as(i64, 0x123456789abcdef0), inst.imm.?.right.Int);
    try std.testing.expectEqual(@as(u64, 16), inst.getSize());
}

test "fromBytes decodes mov reg (bf 16 00 00 00 00 00 00 = r6 = r1)" {
    // counter.o instruction 0: r6 = r1 — BinaryRegister class, no imm/off.
    const bytes = [_]u8{ 0xbf, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const inst = try Instruction.fromBytes(&bytes);
    try std.testing.expectEqual(Opcode.Mov64Reg, inst.opcode);
    try std.testing.expectEqual(@as(u8, 6), inst.dst.?.n);
    try std.testing.expectEqual(@as(u8, 1), inst.src.?.n);
    try std.testing.expect(inst.off == null);
    try std.testing.expect(inst.imm == null);
}

test "fromBytes decodes load memory (79 11 00 00 00 00 00 00 = r1 = *(u64*)(r1 + 0))" {
    // hello.o instruction 0.
    const bytes = [_]u8{ 0x79, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const inst = try Instruction.fromBytes(&bytes);
    try std.testing.expectEqual(Opcode.Ldxdw, inst.opcode);
    try std.testing.expectEqual(@as(u8, 1), inst.dst.?.n);
    try std.testing.expectEqual(@as(u8, 1), inst.src.?.n);
    try std.testing.expectEqual(@as(i16, 0), inst.off.?.right);
    try std.testing.expect(inst.imm == null);
}

test "fromBytes decodes jump with negative offset" {
    // Synthetic: if r1 != 0 goto -8  (JneImm, dst=1, off=-8, imm=0)
    // 55 01 f8 ff 00 00 00 00
    const bytes = [_]u8{ 0x55, 0x01, 0xf8, 0xff, 0x00, 0x00, 0x00, 0x00 };
    const inst = try Instruction.fromBytes(&bytes);
    try std.testing.expectEqual(Opcode.JneImm, inst.opcode);
    try std.testing.expectEqual(@as(u8, 1), inst.dst.?.n);
    try std.testing.expect(inst.src == null);
    try std.testing.expectEqual(@as(i16, -8), inst.off.?.right);
    try std.testing.expectEqual(@as(i64, 0), inst.imm.?.right.Int);
}

test "fromBytes rejects Lddw with non-zero src" {
    const bytes = [_]u8{
        0x18, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // src=1 — illegal
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    try std.testing.expectError(DecodeError.FieldMustBeZero, Instruction.fromBytes(&bytes));
}

test "fromBytes rejects Exit with non-zero dst" {
    const bytes = [_]u8{ 0x95, 0x01, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(DecodeError.FieldMustBeZero, Instruction.fromBytes(&bytes));
}

test "fromBytes rejects Call with src not in {0, 1}" {
    // src=2 is invalid per Rust decode_call_immediate (L283-288).
    const bytes = [_]u8{ 0x85, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expectError(DecodeError.InvalidSrcRegister, Instruction.fromBytes(&bytes));
}

test "fromBytes rejects Lddw with < 16 bytes" {
    const bytes = [_]u8{ 0x18, 0x00, 0, 0, 0, 0, 0, 0 }; // only 8 bytes
    try std.testing.expectError(DecodeError.TooShort, Instruction.fromBytes(&bytes));
}
