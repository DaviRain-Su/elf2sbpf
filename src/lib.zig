// elf2sbpf library root.
//
// Per 02-architecture.md §3.4, all linker logic lives under this module so it
// can be @import("elf2sbpf") by other Zig projects. main.zig will end up being
// a thin wrapper over linkProgram (03-technical-spec.md §1.2).
//
// A.1 scaffold: stubbed LinkError enum and a not-yet-implemented linkProgram.
// Individual layers (common / elf / parse / ast / emit) are added under their
// own Epics — they'll be re-exported from this file as they come online.

const std = @import("std");

// Sub-modules — re-exported so that external consumers can reach them
// via `@import("elf2sbpf").Number` etc.
pub const Number = @import("common/number.zig").Number;
pub const Register = @import("common/register.zig").Register;
pub const Opcode = @import("common/opcode.zig").Opcode;

// Make sub-module tests runnable via `zig build test`.
test {
    _ = @import("common/number.zig");
    _ = @import("common/register.zig");
    _ = @import("common/opcode.zig");
}

/// Error set returned by any entry point that can fail because of input data
/// (as opposed to internal bugs). Mirrors 03-technical-spec.md §1.3.
pub const LinkError = error{
    // ELF parsing
    InvalidElf,
    UnsupportedMachine,
    UnsupportedClass,
    UnsupportedEndian,

    // byteparser
    InstructionDecodeFailed,
    LddwTargetOutsideRodata,
    LddwTargetInsideNamedEntry,
    CallTargetUnresolvable,

    // AST buildProgram
    UndefinedLabel,
    RodataSectionOverflow,

    // emit
    RodataTooLarge,
    TextTooLarge,

    // allocation
    OutOfMemory,
};

/// Convert a BPF ELF object into a Solana SBPF program. Caller owns the
/// returned slice and must free it with the same allocator.
///
/// Contract (per 03-technical-spec.md §1.2):
///   - `elf_bytes` must be a valid little-endian ELF64 BPF object.
///   - Return value owned by caller; free with `allocator.free`.
///   - Pure function: same input produces the same output.
///   - Any failure returns a `LinkError` member; never panics on bad input.
pub fn linkProgram(
    allocator: std.mem.Allocator,
    elf_bytes: []const u8,
) LinkError![]u8 {
    _ = allocator;
    _ = elf_bytes;
    // Will be implemented over the course of Epics C1-C through C1-G.
    return LinkError.InvalidElf;
}

test "linkProgram stub returns InvalidElf (scaffold)" {
    const allocator = std.testing.allocator;
    const result = linkProgram(allocator, &.{});
    try std.testing.expectError(LinkError.InvalidElf, result);
}

test "LinkError has all required variants" {
    // Spec compliance: every error listed in 03-technical-spec.md §1.3 must
    // exist in this enum. @errorName forces the compiler to resolve each
    // identifier — if you remove or rename one, this test stops compiling
    // and you must update the spec first.
    const names = [_][]const u8{
        @errorName(LinkError.InvalidElf),
        @errorName(LinkError.UnsupportedMachine),
        @errorName(LinkError.UnsupportedClass),
        @errorName(LinkError.UnsupportedEndian),
        @errorName(LinkError.InstructionDecodeFailed),
        @errorName(LinkError.LddwTargetOutsideRodata),
        @errorName(LinkError.LddwTargetInsideNamedEntry),
        @errorName(LinkError.CallTargetUnresolvable),
        @errorName(LinkError.UndefinedLabel),
        @errorName(LinkError.RodataSectionOverflow),
        @errorName(LinkError.RodataTooLarge),
        @errorName(LinkError.TextTooLarge),
        @errorName(LinkError.OutOfMemory),
    };
    try std.testing.expectEqual(@as(usize, 13), names.len);
}
