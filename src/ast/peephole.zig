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

/// Check whether two clusters overlap — either's span contains any of
/// the other's ldxb nodes. If so, they're interleaved and must be
/// rewritten together as a super-cluster (or both skipped).
fn clustersInterleaved(
    nodes: []const ASTNode,
    a: Ldxb8Group,
    b: Ldxb8Group,
) bool {
    const a_span_end = computeSpanEnd(nodes, a);
    const b_span_end = computeSpanEnd(nodes, b);
    for (b.ldxb_node_indices) |nidx| {
        if (nidx >= a.first_idx and nidx <= a_span_end) return true;
    }
    for (a.ldxb_node_indices) |nidx| {
        if (nidx >= b.first_idx and nidx <= b_span_end) return true;
    }
    return false;
}

// ---------------------------------------------------------------------
// V2.1 super-cluster rewriter (handles interleaved clusters)
// ---------------------------------------------------------------------

/// Per-register taint set used to match each surviving output register
/// back to the cluster(s) it represents. We track **which (base_reg,
/// base_offset) pairs fed this register via Ldxb + shift/or chain**.
/// Each u64 result covers exactly 8 bytes from the same base, so after
/// taint propagation an "output" register has a bitmask with 8 ones.
const RegTaint = struct {
    base_reg: u8,
    /// Bit `i` set means offset `base_min + i` participated. We use a
    /// 64-bit mask and a single `base_min` anchor; any ldxb further
    /// than 63 bytes from an existing anchor resets taint (unlikely
    /// in practice).
    base_min: i16,
    mask: u64,
};

const OPT_OPT: ?RegTaint = null;

fn mergeTaint(a: ?RegTaint, b: ?RegTaint) ?RegTaint {
    const ta = a orelse return b;
    const tb = b orelse return a;
    if (ta.base_reg != tb.base_reg) return null;
    // Re-anchor both masks to the smaller base_min.
    const new_anchor = @min(ta.base_min, tb.base_min);
    const shift_a: u6 = @intCast(ta.base_min - new_anchor);
    const shift_b: u6 = @intCast(tb.base_min - new_anchor);
    return .{
        .base_reg = ta.base_reg,
        .base_min = new_anchor,
        .mask = (ta.mask << shift_a) | (tb.mask << shift_b),
    };
}

/// Run taint propagation across the super-span. On return:
///   * `taint[r]` holds the merged origin of register `r` after the
///     last instruction in the span.
///   * A register whose taint.mask has exactly 8 consecutive bits set
///     starting at bit 0 is a candidate "u64 output": its 8 bytes map
///     to `[base_min, base_min + 7]`.
fn taintPropagate(
    nodes: []const ASTNode,
    span_first: usize,
    span_last_inclusive: usize,
) [11]?RegTaint {
    var taint: [11]?RegTaint = @splat(null);
    var i: usize = span_first;
    while (i <= span_last_inclusive) : (i += 1) {
        const inst_node = switch (nodes[i]) {
            .Instruction => |n| n,
            else => continue,
        };
        const inst = inst_node.instruction;
        const dst = if (inst.dst) |d| d.n else continue;
        if (dst >= 11) continue;
        switch (inst.opcode) {
            .Ldxb => {
                const src = inst.src orelse continue;
                const off = switch (inst.off orelse continue) {
                    .right => |v| v,
                    .left => continue,
                };
                taint[dst] = .{
                    .base_reg = src.n,
                    .base_min = off,
                    .mask = 0b1,
                };
            },
            .Lsh64Imm => {
                // Shift: taint stays with dst (represents the same
                // byte set, just at a different position within the
                // eventual u64 — we don't track bit positions, only
                // byte membership).
            },
            .Or64Reg, .Or32Reg => {
                const src = inst.src orelse continue;
                if (src.n >= 11) continue;
                taint[dst] = mergeTaint(taint[dst], taint[src.n]);
            },
            else => {
                // Non-whitelist op: clobber dst's taint conservatively.
                taint[dst] = null;
            },
        }
    }
    return taint;
}

/// Match each cluster in the super-group to the register whose final
/// taint exactly covers its [base_offset, base_offset+7] byte range.
/// Returns `null` if any cluster cannot be matched unambiguously.
fn matchClustersToRegs(
    nodes: []const ASTNode,
    span_first: usize,
    span_last_inclusive: usize,
    clusters: []const Ldxb8Group,
    out_regs: []u8,
) bool {
    const taint = taintPropagate(nodes, span_first, span_last_inclusive);

    for (clusters, 0..) |c, ci| {
        var matched: ?u8 = null;
        for (taint, 0..) |maybe_t, reg| {
            const t = maybe_t orelse continue;
            if (t.base_reg != c.base_reg) continue;
            if (t.base_min != c.base_offset) continue;
            if (t.mask != 0xff) continue;
            if (matched != null) return false; // ambiguous
            matched = @intCast(reg);
        }
        const m = matched orelse return false;
        out_regs[ci] = m;
    }

    return true;
}

/// Apply a super-cluster rewrite: delete the entire super-span, insert
/// one `Ldxdw` per member cluster (in ascending base_offset order), and
/// renumber the rest of the AST.
fn applyRewriteSuper(
    ast: anytype,
    clusters: []const Ldxb8Group,
    span_first: usize,
    span_last_inclusive: usize,
    dst_regs: []const u8,
) !usize {
    // Collect byte range to delete.
    var del_start_byte: u64 = std.math.maxInt(u64);
    var del_end_byte: u64 = 0;
    var k: usize = span_first;
    while (k <= span_last_inclusive) : (k += 1) {
        switch (ast.nodes.items[k]) {
            .Instruction => |n| {
                if (n.offset < del_start_byte) del_start_byte = n.offset;
                const end = n.offset + n.instruction.getSize();
                if (end > del_end_byte) del_end_byte = end;
            },
            else => {},
        }
    }

    // Node-index removal count: all nodes in [span_first, span_last_inclusive].
    const nodes_deleted: usize = span_last_inclusive - span_first + 1;
    // Instruction count = nodes_deleted if no Labels/GlobalDecls inside.
    // Net instruction delta = nodes_deleted - len(clusters).
    const insn_delta: i64 = @as(i64, @intCast(nodes_deleted - clusters.len));

    // Emit order: topological sort so "reads rX" ldxdws come before
    // "writes rX" ones. Otherwise a self-overwriting base (e.g. the
    // pubkey tail case where the cluster at r1+0x28 writes its result
    // into r1 while a later cluster still loads from r1+0x48) would
    // read from the already-clobbered base.
    //
    // Concretely: for each pair (a, b), if clusters[a].base_reg ==
    // dst_regs[b], we must emit a before b. Repeatedly pick a cluster
    // with no outstanding "is-read-as-base-by-others" dependency.
    var order: [16]usize = undefined;
    std.debug.assert(clusters.len <= order.len);

    var remaining: [16]bool = undefined;
    @memset(remaining[0..clusters.len], true);

    var emitted: usize = 0;
    while (emitted < clusters.len) {
        var picked: ?usize = null;
        for (clusters, 0..) |_, i| {
            if (!remaining[i]) continue;
            // A cluster `i` is *blocked* if some still-remaining cluster
            // `j` would read a base register that `i` writes. Emitting
            // `i` early would clobber `j`'s base.
            var blocked = false;
            for (clusters, 0..) |cj, j| {
                if (i == j) continue;
                if (!remaining[j]) continue;
                if (cj.base_reg == dst_regs[i]) {
                    blocked = true;
                    break;
                }
            }
            if (!blocked) {
                picked = i;
                break;
            }
        }
        const p = picked orelse blk: {
            // Cycle (e.g. `ldxdw r1, [r2]` + `ldxdw r2, [r1]`).
            // Fall back to ascending base_offset — behavior may be
            // wrong but at least deterministic; caller should have
            // rejected this super-cluster via safety checks.
            for (clusters, 0..) |_, i| {
                if (remaining[i]) break :blk i;
            }
            return 0;
        };
        order[emitted] = p;
        remaining[p] = false;
        emitted += 1;
    }

    // Overwrite span_first..span_first+len(clusters)-1 with the new
    // ldxdws, shift the tail down.
    const byte_delta: u64 = (del_end_byte - del_start_byte) - @as(u64, @intCast(clusters.len * 8));

    for (order[0..clusters.len], 0..) |ord, i| {
        const c = clusters[ord];
        const ldxdw: instruction_mod.Instruction = .{
            .opcode = .Ldxdw,
            .dst = .{ .n = dst_regs[ord] },
            .src = .{ .n = c.base_reg },
            .off = .{ .right = c.base_offset },
            .imm = null,
            .span = .{ .start = 0, .end = 8 },
        };
        ast.nodes.items[span_first + i] = .{
            .Instruction = .{
                .instruction = ldxdw,
                .offset = del_start_byte + i * 8,
            },
        };
    }

    var src_i: usize = span_last_inclusive + 1;
    var dst_i: usize = span_first + clusters.len;
    while (src_i < ast.nodes.items.len) : (src_i += 1) {
        ast.nodes.items[dst_i] = ast.nodes.items[src_i];
        dst_i += 1;
    }
    ast.nodes.shrinkRetainingCapacity(dst_i);

    // Renumber offsets past del_end_byte.
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

    // Fix numeric jumps / calls that cross the deleted region. Same
    // algebra as applyRewrite, but the instruction-delta is
    // `nodes_deleted - clusters.len` instead of a fixed 21.
    idx = 0;
    while (idx < ast.nodes.items.len) : (idx += 1) {
        const node = &ast.nodes.items[idx];
        const payload: *@TypeOf(node.Instruction) = switch (node.*) {
            .Instruction => |*p| p,
            else => continue,
        };
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

    return @intCast(insn_delta);
}

/// Group interleaved clusters into super-clusters via union-find.
/// Returns a slice of component-id-per-cluster (same length as
/// `groups`). Components with size 1 are ordinary clusters; size ≥ 2
/// are super-clusters.
fn buildComponents(
    allocator: std.mem.Allocator,
    nodes: []const ASTNode,
    groups: []const Ldxb8Group,
) ![]usize {
    var parent = try allocator.alloc(usize, groups.len);
    for (parent, 0..) |*p, i| p.* = i;

    const find = struct {
        fn f(par: []usize, x: usize) usize {
            var cur = x;
            while (par[cur] != cur) : (cur = par[cur]) par[cur] = par[par[cur]];
            return cur;
        }
    }.f;

    for (groups, 0..) |a, i| {
        var j: usize = i + 1;
        while (j < groups.len) : (j += 1) {
            if (clustersInterleaved(nodes, a, groups[j])) {
                const ra = find(parent, i);
                const rb = find(parent, j);
                if (ra != rb) parent[ra] = rb;
            }
        }
    }

    // Normalise: every cluster's entry = its root.
    for (parent, 0..) |*p, i| p.* = find(parent, i);
    return parent;
}

/// Top-level: scan + rewrite every safe cluster. V2.1: groups
/// interleaved clusters into super-clusters and rewrites them together
/// so pubkey-style bpfel output (multiple u64 loads whose ldxb streams
/// are interleaved by LLVM's scheduler) gets handled too.
///
/// Processing order: super-clusters in **descending first_idx** so
/// earlier rewrites don't shift indices of later ones.
pub fn rewriteAll(
    allocator: std.mem.Allocator,
    ast: anytype, // *ast_mod.AST
) !RewriteResult {
    var report = try scan(allocator, ast.nodes.items);
    defer report.deinit(allocator);

    const parent = try buildComponents(allocator, ast.nodes.items, report.groups);
    defer allocator.free(parent);

    // Gather components into Index lists, sorted descending by their
    // earliest cluster first_idx.
    const Component = struct {
        members: []usize,
        earliest_first: usize,
    };
    var comps: std.ArrayList(Component) = .empty;
    defer {
        for (comps.items) |c| allocator.free(c.members);
        comps.deinit(allocator);
    }

    var seen = try allocator.alloc(bool, report.groups.len);
    defer allocator.free(seen);
    @memset(seen, false);

    for (report.groups, 0..) |_, i| {
        if (seen[i]) continue;
        const root = parent[i];
        var members: std.ArrayList(usize) = .empty;
        errdefer members.deinit(allocator);
        var earliest: usize = std.math.maxInt(usize);
        for (report.groups, 0..) |gj, j| {
            if (parent[j] != root) continue;
            seen[j] = true;
            try members.append(allocator, j);
            if (gj.first_idx < earliest) earliest = gj.first_idx;
        }
        try comps.append(allocator, .{
            .members = try members.toOwnedSlice(allocator),
            .earliest_first = earliest,
        });
    }

    std.mem.sort(Component, comps.items, {}, struct {
        fn gt(_: void, a: Component, b: Component) bool {
            return a.earliest_first > b.earliest_first;
        }
    }.gt);

    var rewritten: usize = 0;
    var skipped: usize = 0;
    var total_insn_delta: usize = 0;

    for (comps.items) |comp| {
        // Uniform path: every component — singleton or super — goes
        // through the taint-matched rewrite. Singletons just have one
        // member. This is stricter and safer than V2.0's
        // `clusterFinalDst` heuristic ("last Or64Reg in span"), which
        // mismatched on token's .o where the span can end with an
        // unrelated Or64Reg from a neighboring computation.
        var super_first: usize = std.math.maxInt(usize);
        var super_last: usize = 0;
        var member_clusters_buf: [16]Ldxb8Group = undefined;
        if (comp.members.len > member_clusters_buf.len) {
            skipped += comp.members.len;
            continue;
        }
        for (comp.members, 0..) |mi, out_i| {
            const g = report.groups[mi];
            member_clusters_buf[out_i] = g;
            if (g.first_idx < super_first) super_first = g.first_idx;
            const end = computeSpanEnd(ast.nodes.items, g);
            if (end > super_last) super_last = end;
        }
        // Bounded forward extension: each cluster in the super needs at
        // most 2 trailing whitelist instructions (`lsh << 32; or`) for
        // the final high/low merge. Extend up to `2*N + 2` but stop
        // at the first non-whitelist op or at any instruction that
        // writes a register used as a base by a later unrelated ldxb
        // (would falsely pool that ldxb into our super-span).
        const ext_budget: usize = comp.members.len * 2 + 2;
        var ext: usize = 0;
        while (ext < ext_budget and super_last + 1 < ast.nodes.items.len) : (ext += 1) {
            const next = ast.nodes.items[super_last + 1];
            const op = switch (next) {
                .Instruction => |n| n.instruction.opcode,
                else => break,
            };
            // Don't cross a naked Ldxb — that almost certainly starts
            // the next cluster / a scatter byte-load from the same
            // base register. computeSpanEnd already picked up this
            // cluster's own trailing shift/or tail; further ldxb is
            // always foreign.
            if (op == .Ldxb) break;
            if (!isClusterBodyOpcode(op)) break;
            super_last += 1;
        }
        const members = member_clusters_buf[0..comp.members.len];

        // Safety: every node in super-span must be a whitelist
        // Instruction (no Labels, no foreign opcodes).
        var super_safe = true;
        var scan_i: usize = super_first;
        while (scan_i <= super_last) : (scan_i += 1) {
            switch (ast.nodes.items[scan_i]) {
                .Instruction => |n| if (!isClusterBodyOpcode(n.instruction.opcode)) {
                    super_safe = false;
                    break;
                },
                else => {
                    super_safe = false;
                    break;
                },
            }
        }

        // Jumps into the super-span?
        var super_start_byte: u64 = std.math.maxInt(u64);
        var super_end_byte: u64 = 0;
        var bi: usize = super_first;
        while (bi <= super_last) : (bi += 1) {
            const inst_node = switch (ast.nodes.items[bi]) {
                .Instruction => |n| n,
                else => continue,
            };
            if (inst_node.offset < super_start_byte) super_start_byte = inst_node.offset;
            const end = inst_node.offset + inst_node.instruction.getSize();
            if (end > super_end_byte) super_end_byte = end;
        }
        if (super_safe and anyJumpTargetsInside(ast.nodes.items, super_start_byte, super_end_byte)) {
            super_safe = false;
        }

        // Taint-match clusters to output regs (only if span passed the
        // other checks).
        var dst_regs_buf: [16]u8 = undefined;
        if (super_safe and !matchClustersToRegs(
            ast.nodes.items,
            super_first,
            super_last,
            members,
            dst_regs_buf[0..members.len],
        )) {
            super_safe = false;
        }

        if (super_safe) {
            if (applyRewriteSuper(
                ast,
                members,
                super_first,
                super_last,
                dst_regs_buf[0..members.len],
            )) |removed| {
                total_insn_delta += removed;
                rewritten += members.len;
                continue;
            } else |_| {}
        }

        // Super-cluster path failed. We *cannot* safely fall back to
        // per-member V2.0 rewriting here: the members are mutually
        // interleaved (that's why we grouped them), so rewriting any
        // one of them would delete the others' ldxb data paths and
        // corrupt the program. Skip them all and let the next pass or
        // the user decide.
        skipped += comp.members.len;
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
