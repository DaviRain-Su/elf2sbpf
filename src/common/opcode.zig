// Opcode — BPF instruction opcode enum, one u8 value per variant.
//
// Mirrors Rust sbpf-common::opcode::Opcode (sbpf/crates/common/src/opcode.rs L178-295).
// Byte values taken from the Rust TryFrom<u8> impl (L382-510).
//
// Zig's `enum(u8)` gives us From<Opcode> for u8 and TryFrom<u8> for free:
//   - `@intFromEnum(op)`        → u8 (encode)
//   - `@enumFromInt(byte)` catch null → Opcode (decode, via fromByte wrapper)
//
// C1 scope (per 03-technical-spec.md §2.1):
//   - enum + decode/encode  ✓ this file
//   - toStr for diagnostics  ✓ this file
//   - fromSize / toSize / toOperator / is32bit  — deferred to D
//     (assembler-text-parser-only; byteparser doesn't need them)
//
// Tests: 05-test-spec.md §4.3

const std = @import("std");

pub const Opcode = enum(u8) {
    // Loads
    Lddw = 0x18,
    Ldxb = 0x71,
    Ldxh = 0x69,
    Ldxw = 0x61,
    Ldxdw = 0x79,

    // Stores (immediate)
    Stb = 0x72,
    Sth = 0x6a,
    Stw = 0x62,
    Stdw = 0x7a,

    // Stores (register)
    Stxb = 0x73,
    Stxh = 0x6b,
    Stxw = 0x63,
    Stxdw = 0x7b,

    // 32-bit ALU (standard)
    Add32Imm = 0x04,
    Add32Reg = 0x0c,
    Sub32Imm = 0x14,
    Sub32Reg = 0x1c,
    Mul32Imm = 0x24,
    Mul32Reg = 0x2c,
    Div32Imm = 0x34,
    Div32Reg = 0x3c,
    Or32Imm = 0x44,
    Or32Reg = 0x4c,
    And32Imm = 0x54,
    And32Reg = 0x5c,
    Lsh32Imm = 0x64,
    Lsh32Reg = 0x6c,
    Rsh32Imm = 0x74,
    Rsh32Reg = 0x7c,
    Mod32Imm = 0x94,
    Mod32Reg = 0x9c,
    Xor32Imm = 0xa4,
    Xor32Reg = 0xac,
    Mov32Imm = 0xb4,
    Mov32Reg = 0xbc,
    Arsh32Imm = 0xc4,
    Arsh32Reg = 0xcc,

    // 32-bit ALU (SBPF-extended)
    Lmul32Imm = 0x86,
    Lmul32Reg = 0x8e,
    Udiv32Imm = 0x46,
    Udiv32Reg = 0x4e,
    Urem32Imm = 0x66,
    Urem32Reg = 0x6e,
    Sdiv32Imm = 0xc6,
    Sdiv32Reg = 0xce,
    Srem32Imm = 0xe6,
    Srem32Reg = 0xee,

    // Endian conversions
    Le = 0xd4,
    Be = 0xdc,

    // 64-bit ALU (standard)
    Add64Imm = 0x07,
    Add64Reg = 0x0f,
    Sub64Imm = 0x17,
    Sub64Reg = 0x1f,
    Mul64Imm = 0x27,
    Mul64Reg = 0x2f,
    Div64Imm = 0x37,
    Div64Reg = 0x3f,
    Or64Imm = 0x47,
    Or64Reg = 0x4f,
    And64Imm = 0x57,
    And64Reg = 0x5f,
    Lsh64Imm = 0x67,
    Lsh64Reg = 0x6f,
    Rsh64Imm = 0x77,
    Rsh64Reg = 0x7f,
    Mod64Imm = 0x97,
    Mod64Reg = 0x9f,
    Xor64Imm = 0xa7,
    Xor64Reg = 0xaf,
    Mov64Imm = 0xb7,
    Mov64Reg = 0xbf,
    Arsh64Imm = 0xc7,
    Arsh64Reg = 0xcf,
    Hor64Imm = 0xf7,

    // 64-bit ALU (SBPF-extended)
    Lmul64Imm = 0x96,
    Lmul64Reg = 0x9e,
    Uhmul64Imm = 0x36,
    Uhmul64Reg = 0x3e,
    Udiv64Imm = 0x56,
    Udiv64Reg = 0x5e,
    Urem64Imm = 0x76,
    Urem64Reg = 0x7e,
    Shmul64Imm = 0xb6,
    Shmul64Reg = 0xbe,
    Sdiv64Imm = 0xd6,
    Sdiv64Reg = 0xde,
    Srem64Imm = 0xf6,
    Srem64Reg = 0xfe,

    // Negation
    Neg32 = 0x84,
    Neg64 = 0x87,

    // Jumps
    Ja = 0x05,
    JeqImm = 0x15,
    JeqReg = 0x1d,
    JgtImm = 0x25,
    JgtReg = 0x2d,
    JgeImm = 0x35,
    JgeReg = 0x3d,
    JltImm = 0xa5,
    JltReg = 0xad,
    JleImm = 0xb5,
    JleReg = 0xbd,
    JsetImm = 0x45,
    JsetReg = 0x4d,
    JneImm = 0x55,
    JneReg = 0x5d,
    JsgtImm = 0x65,
    JsgtReg = 0x6d,
    JsgeImm = 0x75,
    JsgeReg = 0x7d,
    JsltImm = 0xc5,
    JsltReg = 0xcd,
    JsleImm = 0xd5,
    JsleReg = 0xdd,

    // Call / exit
    Call = 0x85,
    Callx = 0x8d,
    Exit = 0x95,

    /// Decode a byte into an Opcode, returning null if the byte does not
    /// correspond to any known SBPF V0-compatible opcode.
    ///
    /// Mirrors Rust TryFrom<u8> impl (opcode.rs L382-510) but uses an
    /// optional return type instead of an error (callers convert to
    /// LinkError.InstructionDecodeFailed when they want to propagate).
    pub fn fromByte(byte: u8) ?Opcode {
        // Exhaustive-enum-safe conversion: validate against the declared
        // field values before casting. `@enumFromInt` on an unlisted value
        // is undefined behavior for an exhaustive enum, so we must guard.
        inline for (@typeInfo(Opcode).@"enum".fields) |f| {
            if (byte == f.value) return @enumFromInt(f.value);
        }
        return null;
    }

    /// Encode an Opcode as a u8. Always succeeds (Zig's enum(u8) enforces it).
    pub fn toByte(self: Opcode) u8 {
        return @intFromEnum(self);
    }

    /// Human-readable mnemonic, used for diagnostics. Matches Rust Display
    /// impl (opcode.rs L376-380, which delegates to to_str at L636+).
    pub fn toStr(self: Opcode) []const u8 {
        return switch (self) {
            .Lddw => "lddw",
            .Ldxb => "ldxb",
            .Ldxh => "ldxh",
            .Ldxw => "ldxw",
            .Ldxdw => "ldxdw",
            .Stb => "stb",
            .Sth => "sth",
            .Stw => "stw",
            .Stdw => "stdw",
            .Stxb => "stxb",
            .Stxh => "stxh",
            .Stxw => "stxw",
            .Stxdw => "stxdw",
            .Add32Imm, .Add32Reg => "add32",
            .Sub32Imm, .Sub32Reg => "sub32",
            .Mul32Imm, .Mul32Reg => "mul32",
            .Div32Imm, .Div32Reg => "div32",
            .Or32Imm, .Or32Reg => "or32",
            .And32Imm, .And32Reg => "and32",
            .Lsh32Imm, .Lsh32Reg => "lsh32",
            .Rsh32Imm, .Rsh32Reg => "rsh32",
            .Mod32Imm, .Mod32Reg => "mod32",
            .Xor32Imm, .Xor32Reg => "xor32",
            .Mov32Imm, .Mov32Reg => "mov32",
            .Arsh32Imm, .Arsh32Reg => "arsh32",
            .Lmul32Imm, .Lmul32Reg => "lmul32",
            .Udiv32Imm, .Udiv32Reg => "udiv32",
            .Urem32Imm, .Urem32Reg => "urem32",
            .Sdiv32Imm, .Sdiv32Reg => "sdiv32",
            .Srem32Imm, .Srem32Reg => "srem32",
            .Le => "le",
            .Be => "be",
            .Add64Imm, .Add64Reg => "add64",
            .Sub64Imm, .Sub64Reg => "sub64",
            .Mul64Imm, .Mul64Reg => "mul64",
            .Div64Imm, .Div64Reg => "div64",
            .Or64Imm, .Or64Reg => "or64",
            .And64Imm, .And64Reg => "and64",
            .Lsh64Imm, .Lsh64Reg => "lsh64",
            .Rsh64Imm, .Rsh64Reg => "rsh64",
            .Mod64Imm, .Mod64Reg => "mod64",
            .Xor64Imm, .Xor64Reg => "xor64",
            .Mov64Imm, .Mov64Reg => "mov64",
            .Arsh64Imm, .Arsh64Reg => "arsh64",
            .Hor64Imm => "hor64",
            .Lmul64Imm, .Lmul64Reg => "lmul64",
            .Uhmul64Imm, .Uhmul64Reg => "uhmul64",
            .Udiv64Imm, .Udiv64Reg => "udiv64",
            .Urem64Imm, .Urem64Reg => "urem64",
            .Shmul64Imm, .Shmul64Reg => "shmul64",
            .Sdiv64Imm, .Sdiv64Reg => "sdiv64",
            .Srem64Imm, .Srem64Reg => "srem64",
            .Neg32 => "neg32",
            .Neg64 => "neg64",
            .Ja => "ja",
            .JeqImm, .JeqReg => "jeq",
            .JgtImm, .JgtReg => "jgt",
            .JgeImm, .JgeReg => "jge",
            .JltImm, .JltReg => "jlt",
            .JleImm, .JleReg => "jle",
            .JsetImm, .JsetReg => "jset",
            .JneImm, .JneReg => "jne",
            .JsgtImm, .JsgtReg => "jsgt",
            .JsgeImm, .JsgeReg => "jsge",
            .JsltImm, .JsltReg => "jslt",
            .JsleImm, .JsleReg => "jsle",
            .Call => "call",
            .Callx => "callx",
            .Exit => "exit",
        };
    }
};

// --- tests ---

test "Opcode byte values match SBPF spec (sample)" {
    // Spot-check a handful of critical opcodes. If any is wrong the entire
    // pipeline mis-decodes. Round-trip via fromByte / toByte.
    try std.testing.expectEqual(Opcode.Lddw, Opcode.fromByte(0x18).?);
    try std.testing.expectEqual(@as(u8, 0x18), Opcode.Lddw.toByte());

    try std.testing.expectEqual(Opcode.Call, Opcode.fromByte(0x85).?);
    try std.testing.expectEqual(Opcode.Exit, Opcode.fromByte(0x95).?);
    try std.testing.expectEqual(Opcode.Ja, Opcode.fromByte(0x05).?);
    try std.testing.expectEqual(Opcode.JeqImm, Opcode.fromByte(0x15).?);
    try std.testing.expectEqual(Opcode.Mov64Imm, Opcode.fromByte(0xb7).?);
    try std.testing.expectEqual(Opcode.Add64Imm, Opcode.fromByte(0x07).?);
}

test "Opcode.fromByte rejects unknown bytes" {
    // Byte values that are not in the Opcode enum.
    try std.testing.expectEqual(@as(?Opcode, null), Opcode.fromByte(0x00));
    try std.testing.expectEqual(@as(?Opcode, null), Opcode.fromByte(0xff));
    // 0x16 is JMP32 jeq32 — Solana V0 does not support this; we must reject it.
    try std.testing.expectEqual(@as(?Opcode, null), Opcode.fromByte(0x16));
}

test "Opcode.toByte is inverse of fromByte for all variants" {
    // Comptime-generated coverage of every enum value.
    inline for (@typeInfo(Opcode).@"enum".fields) |field| {
        const op: Opcode = @enumFromInt(field.value);
        try std.testing.expectEqual(op, Opcode.fromByte(op.toByte()).?);
    }
}

test "Opcode.toStr returns non-empty mnemonic for every variant" {
    inline for (@typeInfo(Opcode).@"enum".fields) |field| {
        const op: Opcode = @enumFromInt(field.value);
        const s = op.toStr();
        try std.testing.expect(s.len > 0);
    }
}

test "Opcode.toStr key mnemonics" {
    try std.testing.expectEqualStrings("lddw", Opcode.Lddw.toStr());
    try std.testing.expectEqualStrings("call", Opcode.Call.toStr());
    try std.testing.expectEqualStrings("exit", Opcode.Exit.toStr());
    try std.testing.expectEqualStrings("jeq", Opcode.JeqImm.toStr());
    try std.testing.expectEqualStrings("jeq", Opcode.JeqReg.toStr()); // Reg variant shares mnemonic
    try std.testing.expectEqualStrings("add64", Opcode.Add64Imm.toStr());
}
