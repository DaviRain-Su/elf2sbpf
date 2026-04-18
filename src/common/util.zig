// Shared utility functions used across the elf2sbpf codebase.

const std = @import("std");

/// Read a null-terminated string starting at `offset` within `buf`.
/// If `offset` reaches the end of the buffer without a terminator, returns
/// the remainder of the buffer (defensive — ELF strtabs should always end
/// in a 0 byte, but we don't crash if not).
pub fn cstrAt(buf: []const u8, offset: usize) []const u8 {
    if (offset >= buf.len) return "";
    var end = offset;
    while (end < buf.len and buf[end] != 0) : (end += 1) {}
    return buf[offset..end];
}

// --- tests ---

const testing = std.testing;

test "cstrAt reads C strings correctly" {
    // "\0.text\0.rodata\0"
    const buf = "\x00.text\x00.rodata\x00";
    try testing.expectEqualStrings("", cstrAt(buf, 0));
    try testing.expectEqualStrings(".text", cstrAt(buf, 1));
    try testing.expectEqualStrings(".rodata", cstrAt(buf, 7));
}

test "cstrAt handles out-of-range offset" {
    const buf = "hello";
    try testing.expectEqualStrings("", cstrAt(buf, 100));
}

test "cstrAt handles missing terminator" {
    // No trailing zero — should return the rest of the buffer instead of
    // crashing.
    const buf = "nonul";
    try testing.expectEqualStrings("nonul", cstrAt(buf, 0));
}
