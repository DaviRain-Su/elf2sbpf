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
// V2 rewriter (D.7.10 V2.0 — strict non-interleaved cluster only)
// ---------------------------------------------------------------------

/// Summary of a rewrite pass. Every skipped candidate carries a reason
/// so diagnostics / tests can assert what happened.
pub const RewriteResult = struct {
    clusters_rewritten: usize,
    clusters_skipped: usize,
    insns_deleted: usize,
};

/// Whitelist of opcodes that may appear *inside* a cluster span. Any
/// other opcode forces us to skip — safety requires no unrelated
/// side-effects between the 8 ldxb and the final `or`.
fn isClusterBodyOpcode(op: Opcode) bool {
    return switch (op) {
        .Ldxb, .Lsh64Imm, .Or64Reg, .Or32Reg => true,
        else => false,
    };
}

fn offNumeric(inst: instruction_mod.Instruction) ?i64 {
    const v = inst.off orelse return null;
    return switch (v) {
        .left => null,
        .right => |raw| @as(i64, raw),
    };
}

fn callImmNumeric(inst: instruction_mod.Instruction) ?i64 {
    const v = inst.imm orelse return null;
    return switch (v) {
        .left => null,
        .right => |num| num.toI64(),
    };
}

/// Walk all Instruction nodes and check whether any numeric jump or
/// local call lands inside the byte range `[del_start_byte, del_end_byte)`
/// **from a source outside the range**. If yes, the cluster cannot be
/// safely removed without invalidating that jump's target.
fn anyJumpTargetsInside(
    nodes: []const ASTNode,
    del_start_byte: u64,
    del_end_byte: u64,
) bool {
    for (nodes) |node| {
        const inst_node = switch (node) {
            .Instruction => |n| n,
            else => continue,
        };
        const src_byte = inst_node.offset;
        // Sources inside the deletion range are removed anyway; their
        // targets don't constrain us.
        if (src_byte >= del_start_byte and src_byte < del_end_byte) continue;

        const inst = inst_node.instruction;
        var rel_off: i64 = 0;
        var has_target = false;
        if (inst.isJump()) {
            rel_off = offNumeric(inst) orelse continue;
            has_target = true;
        } else if (inst.opcode == .Call) {
            // Local call: src=1, imm = numeric PC-relative insn count.
            // Syscalls (src=0) and unresolved calls (imm = .left) skip.
            const src_reg = inst.src orelse continue;
            if (src_reg.n != 1) continue;
            rel_off = callImmNumeric(inst) orelse continue;
            has_target = true;
        }
        if (!has_target) continue;

        const target_byte: i64 = @as(i64, @intCast(src_byte)) + 8 + rel_off * 8;
        if (target_byte < 0) continue;
        const tb: u64 = @intCast(target_byte);
        // A target exactly on `del_start_byte` is fine — the replacement
        // ldxdw lives there. A target strictly inside the range or
        // exactly on `del_end_byte` with no surviving insn at that PC
        // is unsafe. We treat `[del_start_byte+8, del_end_byte)` as the
        // unsafe region — the start byte remains valid.
        if (tb > del_start_byte and tb < del_end_byte) return true;
    }
    return false;
}

/// Walk from `g.last_idx` forward while each node is a whitelist-
/// Instruction. The first non-whitelist node (or label) ends the span.
/// Returns the inclusive end index.
fn computeSpanEnd(nodes: []const ASTNode, g: Ldxb8Group) usize {
    // Cap the walk to avoid runaway scans on pathological inputs.
    const MAX_EXTRA: usize = 8;
    var i: usize = g.last_idx + 1;
    const stop_at = @min(nodes.len, g.last_idx + 1 + MAX_EXTRA);
    while (i < stop_at) : (i += 1) {
        switch (nodes[i]) {
            .Instruction => |n| {
                if (!isClusterBodyOpcode(n.instruction.opcode)) return i - 1;
            },
            else => return i - 1,
        }
    }
    return stop_at - 1;
}

/// Verify that a cluster can be rewritten. Returns null on success or a
/// static reason string for diagnostics / tests on skip.
fn verifyCluster(nodes: []const ASTNode, g: Ldxb8Group) ?[]const u8 {
    const span_end = computeSpanEnd(nodes, g);
    if (span_end < g.last_idx) return "span collapsed";

    var instructions_in_span: usize = 0;
    var first_byte: u64 = std.math.maxInt(u64);
    var last_byte: u64 = 0;
    var final_or_dst: ?u8 = null;

    var i: usize = g.first_idx;
    while (i <= span_end) : (i += 1) {
        switch (nodes[i]) {
            .Label => return "label inside cluster span",
            .GlobalDecl, .ROData => {}, // don't occur in text image past fromByteParse, but benign
            .Instruction => |n| {
                const inst = n.instruction;
                if (!isClusterBodyOpcode(inst.opcode)) return "foreign opcode inside span";
                // Track final dst of Or64Reg — that's the register where
                // the u64 lands after all shifts + merges.
                if (inst.opcode == .Or64Reg) {
                    if (inst.dst) |d| final_or_dst = d.n;
                }
                instructions_in_span += 1;
                if (n.offset < first_byte) first_byte = n.offset;
                if (n.offset + inst.getSize() > last_byte) last_byte = n.offset + inst.getSize();
            },
        }
    }

    // Typical pattern: 22 instructions. Reject anything outside
    // [18, 30] — same span length but different instruction count
    // means something unusual is packed in.
    if (instructions_in_span < 18 or instructions_in_span > 30)
        return "unusual instruction count inside span";
    if (final_or_dst == null) return "no Or64Reg to identify final dst";

    if (anyJumpTargetsInside(nodes, first_byte, last_byte))
        return "jump/call target inside cluster";

    return null;
}

/// Determine the final destination register for a cluster by scanning
/// its span for the LAST `Or64Reg` (or the only `Or64Reg` — matches
/// bpfel -O2 emission where the ultimate merge is the final `or64`).
fn clusterFinalDst(nodes: []const ASTNode, g: Ldxb8Group, span_end_inclusive: usize) u8 {
    var final: u8 = 0;
    var i: usize = g.first_idx;
    while (i <= span_end_inclusive) : (i += 1) {
        const inst_node = switch (nodes[i]) {
            .Instruction => |n| n,
            else => continue,
        };
        if (inst_node.instruction.opcode == .Or64Reg) {
            if (inst_node.instruction.dst) |d| final = d.n;
        }
    }
    return final;
}

/// Rewrite a single cluster in place on `ast.nodes`. Deletes all
/// instructions in `[g.first_idx .. g.last_idx + 6]`, inserts a single
/// `Ldxdw` at position `g.first_idx`, then renumbers every subsequent
/// Instruction / Label offset by the byte delta and adjusts every
/// surviving numeric jump / call that crosses the deleted region.
///
/// Returns the net number of instructions removed (e.g. `21` for a
/// 22→1 rewrite). Panics if verifyCluster would have returned non-null
/// — caller must call verifyCluster first.
fn applyRewrite(
    ast: anytype, // *ast_mod.AST to avoid import cycle
    g: Ldxb8Group,
) !usize {
    const span_first = g.first_idx;
    const span_last_inclusive = computeSpanEnd(ast.nodes.items, g);

    // Collect bytes to delete + first-instruction offset for the
    // replacement ldxdw.
    var del_start_byte: u64 = std.math.maxInt(u64);
    var del_end_byte: u64 = 0;
    var insns_removed: usize = 0;
    var k: usize = span_first;
    while (k <= span_last_inclusive) : (k += 1) {
        switch (ast.nodes.items[k]) {
            .Instruction => |n| {
                if (n.offset < del_start_byte) del_start_byte = n.offset;
                const end = n.offset + n.instruction.getSize();
                if (end > del_end_byte) del_end_byte = end;
                insns_removed += 1;
            },
            else => {},
        }
    }

    const dst = clusterFinalDst(ast.nodes.items, g, span_last_inclusive);
    const new_inst: Instruction = .{
        .opcode = .Ldxdw,
        .dst = .{ .n = dst },
        .src = .{ .n = g.base_reg },
        .off = .{ .right = g.base_offset },
        .imm = null,
        .span = .{ .start = 0, .end = 8 },
    };

    // Remove span_first..span_last_inclusive (inclusive), insert one
    // replacement at span_first. ArrayList has no removeRange; do it
    // manually by shifting.
    const total_removed: usize = span_last_inclusive - span_first + 1;
    const new_ldxdw_node: ASTNode = .{
        .Instruction = .{ .instruction = new_inst, .offset = del_start_byte },
    };
    ast.nodes.items[span_first] = new_ldxdw_node;
    // Shift everything after span_last_inclusive down by (total_removed - 1).
    var src_i: usize = span_last_inclusive + 1;
    var dst_i: usize = span_first + 1;
    while (src_i < ast.nodes.items.len) : (src_i += 1) {
        ast.nodes.items[dst_i] = ast.nodes.items[src_i];
        dst_i += 1;
    }
    ast.nodes.shrinkRetainingCapacity(dst_i);

    // Renumber: every Label / Instruction with offset >= del_end_byte
    // decreases by `(del_end_byte - del_start_byte) - 8` bytes (we kept
    // 8 bytes for the new ldxdw).
    const byte_delta: u64 = (del_end_byte - del_start_byte) - 8;
    var idx: usize = 0;
    while (idx < ast.nodes.items.len) : (idx += 1) {
        switch (ast.nodes.items[idx]) {
            .Instruction => |*payload| {
                if (payload.offset >= del_end_byte) payload.offset -= byte_delta;
            },
            .Label => |*payload| {
                if (payload.offset >= del_end_byte) payload.offset -= byte_delta;
            },
            else => {},
        }
    }
    ast.text_size -= byte_delta;

    // Fix up numeric jumps / local calls that cross the deleted region.
    // The replacement ldxdw occupies bytes [del_start_byte, del_start_byte+8).
    // A jump from `src_byte` to `target_byte` "crosses" the deletion iff
    // (a) src < del_start AND target >= del_end_byte, or
    // (b) src >= del_end_byte AND target <= del_start_byte (backwards jump).
    // In both cases the instruction-count between src and target shrank
    // by (total_removed - 1) = 21.
    const insn_delta: i64 = @intCast(total_removed - 1);
    idx = 0;
    while (idx < ast.nodes.items.len) : (idx += 1) {
        const node = &ast.nodes.items[idx];
        const payload: *@TypeOf(node.Instruction) = switch (node.*) {
            .Instruction => |*p| p,
            else => continue,
        };
        // Note: offsets here are already POST-renumber. Compare against
        // del_start_byte (unchanged) and del_end_byte - byte_delta (the
        // new post-renumber boundary) — but since the only "inside" span
        // is now a single ldxdw at del_start_byte, we just need to know
        // if src and original-target straddle del_start_byte..(del_start_byte+8).
        const inst = &payload.instruction;
        const src_byte_post = payload.offset;
        const is_jump = inst.isJump();
        const is_local_call = inst.opcode == .Call and
            (inst.src != null and inst.src.?.n == 1);
        if (!is_jump and !is_local_call) continue;

        const raw_off: i64 = if (is_jump)
            (offNumeric(inst.*) orelse continue)
        else
            (callImmNumeric(inst.*) orelse continue);

        // Reconstruct original src byte and original target byte. If
        // src_byte was after del_end_byte, the renumber already shifted
        // it down — so original src_byte = src_byte_post + byte_delta.
        const orig_src_byte: i64 = if (src_byte_post >= del_start_byte)
            @as(i64, @intCast(src_byte_post)) + @as(i64, @intCast(byte_delta))
        else
            @as(i64, @intCast(src_byte_post));
        const orig_target_byte: i64 = orig_src_byte + 8 + raw_off * 8;

        const d_start: i64 = @intCast(del_start_byte);
        const d_end: i64 = @intCast(del_end_byte);
        const crosses_forward = orig_src_byte < d_start and orig_target_byte >= d_end;
        const crosses_backward = orig_src_byte >= d_end and orig_target_byte <= d_start;
        if (!crosses_forward and !crosses_backward) continue;

        const new_off = if (crosses_forward) raw_off - insn_delta else raw_off + insn_delta;
        if (is_jump) {
            inst.off = .{ .right = @intCast(new_off) };
        } else {
            inst.imm = .{ .right = .{ .Int = new_off } };
        }
    }

    return total_removed - 1;
}

/// Check whether another cluster's ldxb_node_indices overlap with
/// `g`'s span `[first_idx..span_end_inclusive]`. If so the two clusters
/// are interleaved — rewriting one would orphan the other's shift/or
/// chain. V2.0 handles this by refusing to rewrite any interleaved
/// cluster (both sides stay untouched).
fn hasInterleavedCluster(
    all: []const Ldxb8Group,
    self_idx: usize,
    span_first: usize,
    span_end_inclusive: usize,
) bool {
    for (all, 0..) |other, i| {
        if (i == self_idx) continue;
        for (other.ldxb_node_indices) |nidx| {
            if (nidx >= span_first and nidx <= span_end_inclusive) return true;
        }
    }
    return false;
}

/// Top-level: scan + rewrite every safe cluster. Processes clusters in
/// *descending* node-order so earlier rewrites don't invalidate indices
/// for later ones. Unsafe clusters are silently skipped (counted in
/// `RewriteResult.clusters_skipped`).
pub fn rewriteAll(
    allocator: std.mem.Allocator,
    ast: anytype, // *ast_mod.AST
) !RewriteResult {
    var report = try scan(allocator, ast.nodes.items);
    defer report.deinit(allocator);

    // Sort clusters by first_idx descending so that rewriting a later
    // cluster doesn't shift the indices of earlier ones.
    std.mem.sort(Ldxb8Group, report.groups, {}, struct {
        fn gt(_: void, a: Ldxb8Group, b: Ldxb8Group) bool {
            return a.first_idx > b.first_idx;
        }
    }.gt);

    var rewritten: usize = 0;
    var skipped: usize = 0;
    var total_insn_delta: usize = 0;

    for (report.groups, 0..) |g, idx| {
        const span_end = computeSpanEnd(ast.nodes.items, g);
        if (hasInterleavedCluster(report.groups, idx, g.first_idx, span_end)) {
            skipped += 1;
            continue;
        }
        if (verifyCluster(ast.nodes.items, g) != null) {
            skipped += 1;
            continue;
        }
        const removed = applyRewrite(ast, g) catch {
            skipped += 1;
            continue;
        };
        total_insn_delta += removed;
        rewritten += 1;
    }

    return .{
        .clusters_rewritten = rewritten,
        .clusters_skipped = skipped,
        .insns_deleted = total_insn_delta,
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
