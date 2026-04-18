// Peephole detector — D.7.10 V1 (detector only; does not modify
// bytecode).
//
// Background: stock LLVM's `bpfel` backend (as shipped in Zig 0.16)
// lowers `load i64 align 1` into 8 × ldxb + ~13 shift/or instructions.
// Solana's LLVM fork allows unaligned 64-bit loads, so a single `ldxdw`
// suffices there. Programs compiled via stock Zig → elf2sbpf therefore
// pay 20+ extra instructions per unaligned u64 load at runtime.
//
// This module scans an instruction stream for the recognizable *8-byte
// load cluster* and reports candidates. It does **not** rewrite the
// bytecode — that is D.7.10 V2, which also requires jump / call / reloc
// renumbering. V1 exists so we can measure how much CU a real program
// could save before committing to the rewriter.
//
// See `docs/D-tasks.md` §D.7.10 for the full rationale and V2 plan.

const std = @import("std");
const opcode_mod = @import("../common/opcode.zig");
const instruction_mod = @import("../common/instruction.zig");
const node_mod = @import("node.zig");

const Opcode = opcode_mod.Opcode;
const Instruction = instruction_mod.Instruction;
const ASTNode = node_mod.ASTNode;

/// A detected 8-consecutive-ldxb cluster. All eight loads share a base
/// register and their offsets form a contiguous [N..N+7] range.
///
/// `first_idx` / `last_idx` are the smallest/largest *node indices* in
/// the AST node list, so the cluster spans `last_idx - first_idx + 1`
/// consecutive nodes (some of which are the interleaved shift/or
/// instructions that also belong to the pattern).
pub const Ldxb8Group = struct {
    base_reg: u8,
    base_offset: i16,
    ldxb_node_indices: [8]usize,
    first_idx: usize,
    last_idx: usize,
};

/// Peephole scan result. Caller owns `groups`; free with
/// `report.deinit(allocator)`.
pub const Report = struct {
    groups: []Ldxb8Group,
    ldxb_total: usize,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.groups);
        self.groups = &.{};
    }

    /// Conservative upper bound on instructions that could be eliminated
    /// by V2: each group of 8 ldxb becomes 1 ldxdw and drops ~21 support
    /// instructions (shifts/ors). We report `21 * groups.len` so CU
    /// estimates stay pessimistic (V2 may save fewer if not all shifts
    /// are dead after replacement).
    pub fn insnSavingsEstimate(self: Report) usize {
        return self.groups.len * 21;
    }
};

/// Scan an AST node list for 8-byte-load clusters.
///
/// Node indices in the returned `Ldxb8Group.ldxb_node_indices` refer to
/// positions in the caller-supplied `nodes` slice. Non-Instruction
/// nodes (Label, GlobalDecl, ROData) are skipped — they don't contain
/// ldxb and don't disqualify a pattern that straddles them.
pub fn scan(
    allocator: std.mem.Allocator,
    nodes: []const ASTNode,
) !Report {
    // Collect all ldxb instructions with their position, base reg, offset.
    const Entry = struct {
        node_idx: usize,
        base: u8,
        offset: i16,
    };
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);

    for (nodes, 0..) |node, idx| {
        const inst = switch (node) {
            .Instruction => |n| n.instruction,
            else => continue,
        };
        if (inst.opcode != .Ldxb) continue;
        const src = inst.src orelse continue;
        const off_either = inst.off orelse continue;
        const off = switch (off_either) {
            .right => |n| n,
            .left => continue, // still symbolic; not our pattern
        };
        try entries.append(allocator, .{
            .node_idx = idx,
            .base = src.n,
            .offset = off,
        });
    }

    // Group by base register, then within each group sort by offset and
    // look for windows of exactly 8 consecutive offsets. Greedy: once an
    // ldxb is consumed by a group, skip it on subsequent windows.
    var groups: std.ArrayList(Ldxb8Group) = .empty;
    errdefer groups.deinit(allocator);

    // Sort: primary by base, secondary by offset, tertiary by node_idx.
    const sorted_entries = try allocator.dupe(Entry, entries.items);
    defer allocator.free(sorted_entries);
    std.mem.sort(Entry, sorted_entries, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            if (a.base != b.base) return a.base < b.base;
            if (a.offset != b.offset) return a.offset < b.offset;
            return a.node_idx < b.node_idx;
        }
    }.lessThan);

    var consumed = try allocator.alloc(bool, sorted_entries.len);
    defer allocator.free(consumed);
    @memset(consumed, false);

    var i: usize = 0;
    while (i + 8 <= sorted_entries.len) : (i += 1) {
        if (consumed[i]) continue;
        const base = sorted_entries[i].base;
        const start_off = sorted_entries[i].offset;

        // Pick 8 entries starting at i that share base, have offsets
        // start_off..start_off+7, each used exactly once. Duplicates at
        // the same offset are tolerated (greedy picks the first).
        var picked: [8]usize = undefined;
        var want_off: i16 = start_off;
        var picks: u8 = 0;
        var cursor: usize = i;
        while (cursor < sorted_entries.len and picks < 8) : (cursor += 1) {
            if (consumed[cursor]) continue;
            const e = sorted_entries[cursor];
            if (e.base != base) break;
            if (e.offset < want_off) continue; // shouldn't happen post-sort
            if (e.offset > want_off) break; // gap — pattern fails
            picked[picks] = cursor;
            picks += 1;
            want_off += 1;
        }

        if (picks < 8) continue;

        var first_idx: usize = std.math.maxInt(usize);
        var last_idx: usize = 0;
        var node_idxs: [8]usize = undefined;
        for (picked, 0..) |p, k| {
            const ni = sorted_entries[p].node_idx;
            node_idxs[k] = ni;
            if (ni < first_idx) first_idx = ni;
            if (ni > last_idx) last_idx = ni;
        }

        // Locality guard: the 8 ldxb for a single u64 load are packed
        // within ~35 instructions in bpfel -O2 output (confirmed on
        // pubkey/transfer benchmarks). Cross-function or cross-basic-
        // block loads from the same base+offsets are false positives —
        // skip them and let greedy pick the next candidate.
        const SPAN_LIMIT: usize = 40;
        if (last_idx - first_idx > SPAN_LIMIT) continue;

        for (picked) |p| consumed[p] = true;

        try groups.append(allocator, .{
            .base_reg = base,
            .base_offset = start_off,
            .ldxb_node_indices = node_idxs,
            .first_idx = first_idx,
            .last_idx = last_idx,
        });
    }

    return .{
        .groups = try groups.toOwnedSlice(allocator),
        .ldxb_total = entries.items.len,
    };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;
const Register = @import("../common/register.zig").Register;
const Either = instruction_mod.Either;
const Number = @import("../common/number.zig").Number;

fn mkLdxb(dst: u8, src: u8, off: i16) ASTNode {
    return .{
        .Instruction = .{
            .instruction = .{
                .opcode = .Ldxb,
                .dst = .{ .n = dst },
                .src = .{ .n = src },
                .off = .{ .right = off },
                .imm = null,
                .span = .{ .start = 0, .end = 8 },
            },
            .offset = 0,
        },
    };
}

fn mkAlu(op: Opcode, dst: u8) ASTNode {
    return .{
        .Instruction = .{
            .instruction = .{
                .opcode = op,
                .dst = .{ .n = dst },
                .src = null,
                .off = null,
                .imm = .{ .right = .{ .Int = 8 } },
                .span = .{ .start = 0, .end = 8 },
            },
            .offset = 0,
        },
    };
}

test "scan finds a single 8-ldxb cluster with contiguous offsets" {
    var nodes: [8]ASTNode = undefined;
    for (0..8) |k| nodes[k] = mkLdxb(@as(u8, @intCast(k + 2)), 1, @intCast(0x30 + k));

    var report = try scan(testing.allocator, &nodes);
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), report.groups.len);
    try testing.expectEqual(@as(u8, 1), report.groups[0].base_reg);
    try testing.expectEqual(@as(i16, 0x30), report.groups[0].base_offset);
    try testing.expectEqual(@as(usize, 21), report.insnSavingsEstimate());
}

test "scan finds two back-to-back clusters (16 contiguous bytes)" {
    var nodes: [16]ASTNode = undefined;
    for (0..16) |k| nodes[k] = mkLdxb(@as(u8, @intCast((k % 8) + 2)), 1, @intCast(k));

    var report = try scan(testing.allocator, &nodes);
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), report.groups.len);
    try testing.expectEqual(@as(i16, 0), report.groups[0].base_offset);
    try testing.expectEqual(@as(i16, 8), report.groups[1].base_offset);
}

test "scan ignores isolated ldxbs with gaps" {
    var nodes: [7]ASTNode = undefined;
    for (0..7) |k| nodes[k] = mkLdxb(@as(u8, @intCast(k + 2)), 1, @intCast(k));

    var report = try scan(testing.allocator, &nodes);
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), report.groups.len);
    try testing.expectEqual(@as(usize, 7), report.ldxb_total);
}

test "scan does not merge loads across base registers" {
    var nodes: [16]ASTNode = undefined;
    for (0..8) |k| nodes[k] = mkLdxb(@as(u8, @intCast(k + 2)), 1, @intCast(k));
    for (0..8) |k| nodes[k + 8] = mkLdxb(@as(u8, @intCast(k + 2)), 2, @intCast(k));

    var report = try scan(testing.allocator, &nodes);
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), report.groups.len);
    try testing.expect(report.groups[0].base_reg != report.groups[1].base_reg);
}

test "scan rejects same-base+consecutive-offsets when span > 40 (cross-BB)" {
    // 8 ldxb with identical (base, offsets 0..7) but spread across
    // 200 unrelated instructions — should NOT be reported: these are
    // almost certainly scattered byte accesses from different basic
    // blocks that happen to reuse the same base register. Confirmed
    // false-positive pattern in vault.o.
    var nodes_list: std.ArrayList(ASTNode) = .empty;
    defer nodes_list.deinit(testing.allocator);
    for (0..8) |k| {
        try nodes_list.append(testing.allocator, mkLdxb(2, 1, @intCast(k)));
        for (0..30) |_| try nodes_list.append(testing.allocator, mkAlu(.Mov32Imm, 3));
    }

    var report = try scan(testing.allocator, nodes_list.items);
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), report.groups.len);
    try testing.expectEqual(@as(usize, 8), report.ldxb_total);
}

test "scan tolerates interleaved shift/or instructions" {
    // Simulates the actual LLVM output: ldxb interleaved with alu ops.
    var nodes_list: std.ArrayList(ASTNode) = .empty;
    defer nodes_list.deinit(testing.allocator);
    for (0..8) |k| {
        try nodes_list.append(testing.allocator, mkLdxb(@as(u8, @intCast(k + 2)), 1, @intCast(0x30 + k)));
        try nodes_list.append(testing.allocator, mkAlu(.Lsh64Imm, @as(u8, @intCast(k + 2))));
        try nodes_list.append(testing.allocator, mkAlu(.Or64Reg, 3));
    }

    var report = try scan(testing.allocator, nodes_list.items);
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), report.groups.len);
    try testing.expectEqual(@as(i16, 0x30), report.groups[0].base_offset);
}
