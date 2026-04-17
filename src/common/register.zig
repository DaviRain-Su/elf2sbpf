// Register — a BPF register reference (r0..r10).
//
// Mirrors Rust sbpf-common::inst_param::Register (sbpf/crates/common/src/inst_param.rs L7-9).
//
// Spec: 03-technical-spec.md §2.1
// Tests: 05-test-spec.md §4.2

const std = @import("std");

pub const Register = struct {
    n: u8,

    /// Format as `r{n}`, matching Rust's Display impl.
    pub fn format(
        self: Register,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("r{d}", .{self.n});
    }
};

// --- tests ---

test "Register{.n = 0} constructs" {
    const r = Register{ .n = 0 };
    try std.testing.expectEqual(@as(u8, 0), r.n);
}

test "Register{.n = 10} constructs (r10)" {
    const r = Register{ .n = 10 };
    try std.testing.expectEqual(@as(u8, 10), r.n);
}

test "Register format produces 'r{n}'" {
    var buf: [8]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try fbs.print("{f}", .{Register{ .n = 3 }});
    try std.testing.expectEqualStrings("r3", fbs.buffered());
}

test "Register format works for r10" {
    var buf: [8]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try fbs.print("{f}", .{Register{ .n = 10 }});
    try std.testing.expectEqualStrings("r10", fbs.buffered());
}
