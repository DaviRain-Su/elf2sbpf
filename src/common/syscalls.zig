// Syscall name → 32-bit hash.
//
// Mirrors Rust sbpf-syscall-map::hash::murmur3_32 (sbpf/crates/sbpf-syscall-map/src/hash.rs).
// Rust uses this to convert syscall identifiers into the u32 immediate that
// appears in Solana SBPF V3 static syscall instructions, and to detect
// dynamic syscall call sites.
//
// Spec: 03-technical-spec.md §6.1
// Tests: 05-test-spec.md §4.5
//
// This MUST be byte-for-byte equivalent with the Rust implementation —
// Solana runtime looks up syscalls by this exact hash. A single wrong bit
// breaks every call.

const std = @import("std");

const C1: u32 = 0xcc9e2d51;
const C2: u32 = 0x1b873593;
const R1: u5 = 15;
const R2: u5 = 13;
const M: u32 = 5;
const N: u32 = 0xe6546b64;
const F1: u32 = 0x85ebca6b;
const F2: u32 = 0xc2b2ae35;

/// Apply the "pre_mix" stage used by both the body and tail: read 4 bytes LE
/// as u32, then the mul-rotate-mul sequence.
inline fn preMix(buf: [4]u8) u32 {
    var k: u32 = std.mem.readInt(u32, &buf, .little);
    k *%= C1;
    k = std.math.rotl(u32, k, R1);
    k *%= C2;
    return k;
}

/// MurmurHash3 32-bit for a byte slice (typically a syscall name).
pub fn murmur3_32(input: []const u8) u32 {
    var hash: u32 = 0;

    // Body: process each 4-byte chunk.
    var i: usize = 0;
    while (i + 4 <= input.len) : (i += 4) {
        const chunk: [4]u8 = .{ input[i], input[i + 1], input[i + 2], input[i + 3] };
        hash ^= preMix(chunk);
        hash = std.math.rotl(u32, hash, R2);
        hash = hash *% M +% N;
    }

    // Tail: 0..3 remaining bytes, padded with zeros on the high end.
    const tail_len = input.len - i;
    if (tail_len > 0) {
        var padded: [4]u8 = .{ 0, 0, 0, 0 };
        var j: usize = 0;
        while (j < tail_len) : (j += 1) {
            padded[j] = input[i + j];
        }
        hash ^= preMix(padded);
    }

    // Finalization: mix in length, then Avalanche the bits.
    hash ^= @as(u32, @intCast(input.len));
    hash ^= hash >> 16;
    hash *%= F1;
    hash ^= hash >> 13;
    hash *%= F2;
    hash ^= hash >> 16;

    return hash;
}

// --- tests ---

test "murmur3_32 is deterministic" {
    try std.testing.expectEqual(murmur3_32("abort"), murmur3_32("abort"));
    try std.testing.expectEqual(murmur3_32("sol_log_"), murmur3_32("sol_log_"));
}

test "murmur3_32 distinguishes different inputs" {
    try std.testing.expect(murmur3_32("abort") != murmur3_32("sol_log_"));
    try std.testing.expect(murmur3_32("") != murmur3_32("a"));
}

test "murmur3_32('sol_log_') matches Solana runtime hash 0x207559bd" {
    // This is the hash hello.o calls (see llvm-objdump on hello.o: `call 0x207559bd`).
    // If any bit is wrong here, every syscall break.
    try std.testing.expectEqual(@as(u32, 0x207559bd), murmur3_32("sol_log_"));
}

test "murmur3_32('sol_log_64_') matches 0x5c2a3178" {
    try std.testing.expectEqual(@as(u32, 0x5c2a3178), murmur3_32("sol_log_64_"));
}

test "murmur3_32('') matches 0x00000000" {
    try std.testing.expectEqual(@as(u32, 0x00000000), murmur3_32(""));
}

test "murmur3_32('sol_log_pubkey') matches 0x7ef088ca" {
    try std.testing.expectEqual(@as(u32, 0x7ef088ca), murmur3_32("sol_log_pubkey"));
}

test "murmur3_32('sol_memcpy_') matches 0x717cc4a3" {
    try std.testing.expectEqual(@as(u32, 0x717cc4a3), murmur3_32("sol_memcpy_"));
}

test "murmur3_32('sol_invoke_signed_c') matches 0xa22b9c85" {
    try std.testing.expectEqual(@as(u32, 0xa22b9c85), murmur3_32("sol_invoke_signed_c"));
}

test "murmur3_32 handles all tail lengths (0, 1, 2, 3)" {
    // Empty string: body runs 0 times, tail runs 0 times, only finalization.
    // hash starts at 0, gets XORed with 0 (length), then avalanche.
    const empty_hash = murmur3_32("");
    try std.testing.expectEqual(@as(u32, 0), empty_hash);

    // 1-byte tail (body=0, tail=1)
    _ = murmur3_32("a");

    // 2-byte tail (body=0, tail=2)
    _ = murmur3_32("ab");

    // 3-byte tail (body=0, tail=3)
    _ = murmur3_32("abc");

    // 4-byte exact (body=1, tail=0)
    _ = murmur3_32("abcd");

    // 5-byte (body=1, tail=1)
    _ = murmur3_32("abcde");

    // 8-byte exact (body=2, tail=0) — sol_log_ is here
    _ = murmur3_32("abcdefgh");
}

/// Registered Solana syscalls. Mirrors Rust sbpf-common::syscalls::
/// REGISTERED_SYSCALLS. Order matters only for documentation — lookup
/// is by hash.
pub const REGISTERED_SYSCALLS = [_][]const u8{
    "abort",
    "sol_panic_",
    "sol_log_",
    "sol_log_64_",
    "sol_log_compute_units_",
    "sol_log_pubkey",
    "sol_create_program_address",
    "sol_try_find_program_address",
    "sol_sha256",
    "sol_keccak256",
    "sol_secp256k1_recover",
    "sol_blake3",
    "sol_curve_validate_point",
    "sol_curve_group_op",
    "sol_get_clock_sysvar",
    "sol_get_epoch_schedule_sysvar",
    "sol_get_fees_sysvar",
    "sol_get_rent_sysvar",
    "sol_memcpy_",
    "sol_memmove_",
    "sol_memcmp_",
    "sol_memset_",
    "sol_invoke_signed_c",
    "sol_invoke_signed_rust",
    "sol_alloc_free_",
    "sol_set_return_data",
    "sol_get_return_data",
    "sol_log_data",
    "sol_get_processed_sibling_instruction",
    "sol_get_stack_height",
};

/// Reverse-lookup a murmur3-hashed syscall identifier. Returns the
/// registered name, or `null` if the hash doesn't correspond to any
/// known syscall.
///
/// Used by `Instruction.fromBytes` to resolve `call src=0, imm=hash`
/// back to the syscall name so buildProgram can produce the correct
/// V0 dynsym / rel.dyn entries.
pub fn nameForHash(hash: u32) ?[]const u8 {
    inline for (REGISTERED_SYSCALLS) |name| {
        if (murmur3_32(name) == hash) return name;
    }
    return null;
}

test "nameForHash resolves sol_log_" {
    const hash = murmur3_32("sol_log_");
    try std.testing.expectEqualStrings("sol_log_", nameForHash(hash).?);
}

test "nameForHash returns null for unknown hash" {
    try std.testing.expectEqual(@as(?[]const u8, null), nameForHash(0xdead_beef));
}
