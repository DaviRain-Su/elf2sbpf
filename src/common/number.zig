// Number — tagged union of Int / Addr immediate values.
//
// Mirrors Rust sbpf-common::inst_param::Number (sbpf/crates/common/src/inst_param.rs L17-21).
//
// Semantic note: Addr and Int carry the same u64 payload but the *variant*
// discriminates "numeric literal" from "address-relative value". Arithmetic
// operations (Add/Sub/Mul/Div) in the Rust version promote any mix to Addr;
// we omit them in C1 (byteparser doesn't need them).
//
// Spec: 03-technical-spec.md §2.1
// Tests: 05-test-spec.md §4.1

const std = @import("std");

pub const Number = union(enum) {
    Int: i64,
    Addr: i64,

    /// Return the raw i64 payload regardless of variant.
    pub fn toI64(self: Number) i64 {
        return switch (self) {
            .Int => |v| v,
            .Addr => |a| a,
        };
    }

    /// Return the low 16 bits of the payload, reinterpreted as signed.
    /// Matches Rust `as i16` semantics (wrap, not clamp).
    pub fn toI16(self: Number) i16 {
        return @bitCast(@as(u16, @truncate(@as(u64, @bitCast(self.toI64())))));
    }
};

// --- tests ---

test "Number.Int.toI64 returns payload" {
    const n = Number{ .Int = 5 };
    try std.testing.expectEqual(@as(i64, 5), n.toI64());
}

test "Number.Addr.toI64 returns payload (negative)" {
    const n = Number{ .Addr = -1 };
    try std.testing.expectEqual(@as(i64, -1), n.toI64());
}

test "Number.toI16 upper bound fits" {
    const n = Number{ .Int = 0x7fff };
    try std.testing.expectEqual(@as(i16, 0x7fff), n.toI16());
}

test "Number.toI16 truncates (wrap semantics)" {
    const n = Number{ .Int = 0x10000 };
    try std.testing.expectEqual(@as(i16, 0), n.toI16());
}

test "Number.toI16 wraps negative correctly" {
    // i64 -1 is u64 0xffff_ffff_ffff_ffff; low 16 bits = 0xffff = i16 -1
    const n = Number{ .Int = -1 };
    try std.testing.expectEqual(@as(i16, -1), n.toI16());
}

test "Number round-trip Int payload" {
    const original: i64 = 42;
    const n = Number{ .Int = original };
    const recovered = Number{ .Int = n.toI64() };
    try std.testing.expectEqual(n, recovered);
}

test "Number variants are distinct" {
    // Int(5) and Addr(5) should not compare equal (tag differs).
    const a = Number{ .Int = 5 };
    const b = Number{ .Addr = 5 };
    try std.testing.expect(!std.meta.eql(a, b));
}
