// elf2sbpf CLI entry point.
//
// Current state: A.1 scaffold — no functionality yet.
// Per 03-technical-spec.md §1.1, the CLI signature is:
//
//     elf2sbpf <input.o> <output.so>
//
// Real argument parsing, file I/O, and calling into lib.linkProgram will be
// added in Epic C1-H. For now this is just enough code for `zig build` to
// succeed and for `zig build test` to have something to run.

const std = @import("std");

pub fn main() !void {
    std.debug.print("elf2sbpf v0.1.0 (C1 scaffold)\n", .{});
}

test "main module scaffold compiles" {
    // Smoke test: proves the build system + test runner are wired up.
    // Will be replaced with real CLI-behavior tests in Epic C1-H.
    try std.testing.expect(true);
}
