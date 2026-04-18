// AST — the mid-level representation between byteparser and the emit
// stage. Holds two ordered lists (text nodes and rodata nodes) plus the
// merged-image sizes.
//
// Rust sbpf-assembler::ast::AST (sbpf/crates/assembler/src/ast.rs L19-30).
// C1 ports just enough for buildProgram (E.3); the full text-parser
// variants of AST construction are deferred to D.
//
// Spec: 03-technical-spec.md §2.3
// Tests: 05-test-spec.md §4.8

const std = @import("std");
const node_mod = @import("node.zig");
const instruction_mod = @import("../common/instruction.zig");
const number_mod = @import("../common/number.zig");
const syscall_mod = @import("../common/syscalls.zig");

pub const ASTNode = node_mod.ASTNode;
pub const Label = node_mod.Label;
pub const ROData = node_mod.ROData;
pub const GlobalDecl = node_mod.GlobalDecl;

const NumericLabelEntry = struct {
    name: []const u8,
    offset: u64,
    idx: usize,
};

/// Target SBPF architecture. V0 is what elf2sbpf C1 MVP targets; V3 is
/// deferred to D.
pub const SbpfArch = enum { V0, V3 };

// ---------------------------------------------------------------------------
// ParseResult and sub-types (E.3 bridge to emit layer)
// ---------------------------------------------------------------------------

/// A dynamic symbol entry — either a syscall call-target or the program
/// entrypoint. Mirrors Rust dynsym.rs concepts.
pub const DynamicSymbolEntry = struct {
    name: []const u8,
    offset: u64,
    is_entry_point: bool = false,
};

/// Collects dynamic symbols produced by buildProgram.
pub const DynamicSymbolMap = struct {
    entries: std.ArrayList(DynamicSymbolEntry),

    pub fn init(_: std.mem.Allocator) DynamicSymbolMap {
        return .{ .entries = .empty };
    }

    pub fn deinit(self: *DynamicSymbolMap, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn addCallTarget(self: *DynamicSymbolMap, allocator: std.mem.Allocator, name: []const u8, offset: u64) !void {
        try self.entries.append(allocator, .{ .name = name, .offset = offset });
    }

    pub fn addEntryPoint(self: *DynamicSymbolMap, allocator: std.mem.Allocator, name: []const u8, offset: u64) !void {
        try self.entries.append(allocator, .{ .name = name, .offset = offset, .is_entry_point = true });
    }
};

/// Relocation types that buildProgram emits.
pub const RelocationType = enum {
    RSbfSyscall,
    RSbf64Relative,
};

/// A single relocation entry in the .rel.dyn-equivalent table.
pub const RelocationEntry = struct {
    offset: u64,
    type: RelocationType,
    symbol_name: []const u8,
};

/// Collects relocations produced by buildProgram.
pub const RelDynMap = struct {
    entries: std.ArrayList(RelocationEntry),

    pub fn init(_: std.mem.Allocator) RelDynMap {
        return .{ .entries = .empty };
    }

    pub fn deinit(self: *RelDynMap, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn addRelDyn(self: *RelDynMap, allocator: std.mem.Allocator, offset: u64, typ: RelocationType, name: []const u8) !void {
        try self.entries.append(allocator, .{ .offset = offset, .type = typ, .symbol_name = name });
    }
};

/// Debug section payload carried through to emit.
pub const DebugSection = struct {
    name: []const u8,
    data: []const u8,
};

/// Code section payload — holds text-image nodes after buildProgram.
pub const CodeSection = struct {
    nodes: std.ArrayList(ASTNode),
    size: u64,

    pub fn new(nodes: std.ArrayList(ASTNode), size: u64) CodeSection {
        return .{ .nodes = nodes, .size = size };
    }
};

/// Data section payload — holds rodata-image nodes after buildProgram.
pub const DataSection = struct {
    nodes: std.ArrayList(ASTNode),
    size: u64,

    pub fn new(nodes: std.ArrayList(ASTNode), size: u64) DataSection {
        return .{ .nodes = nodes, .size = size };
    }
};

/// Final output of buildProgram. Bridge between AST and emit layer.
pub const ParseResult = struct {
    code_section: CodeSection,
    data_section: DataSection,
    dynamic_symbols: DynamicSymbolMap,
    relocation_data: RelDynMap,
    prog_is_static: bool,
    arch: SbpfArch,
    debug_sections: []const DebugSection,

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        self.code_section.nodes.deinit(allocator);
        self.data_section.nodes.deinit(allocator);
        self.dynamic_symbols.deinit(allocator);
        self.relocation_data.deinit(allocator);
        allocator.free(self.debug_sections);
    }
};

// ---------------------------------------------------------------------------
// AST owner struct
// ---------------------------------------------------------------------------

/// Owner of the node lists plus merged-image sizes.
pub const AST = struct {
    allocator: std.mem.Allocator,
    /// Text-image nodes: Label + Instruction + GlobalDecl, in emit order.
    /// (GlobalDecl has no offset but lives here to match Rust's single
    /// node list for the ast-building algorithm.)
    nodes: std.ArrayList(ASTNode),
    /// Rodata-image nodes: ROData only.
    rodata_nodes: std.ArrayList(ASTNode),
    /// Total size of the merged text image in bytes.
    text_size: u64,
    /// Total size of the merged rodata image in bytes.
    rodata_size: u64,

    pub fn init(allocator: std.mem.Allocator) AST {
        return AST{
            .allocator = allocator,
            .nodes = .empty,
            .rodata_nodes = .empty,
            .text_size = 0,
            .rodata_size = 0,
        };
    }

    pub fn deinit(self: *AST) void {
        self.nodes.deinit(self.allocator);
        self.rodata_nodes.deinit(self.allocator);
    }

    pub fn setTextSize(self: *AST, size: u64) void {
        self.text_size = size;
    }

    pub fn setRodataSize(self: *AST, size: u64) void {
        self.rodata_size = size;
    }

    pub fn pushNode(self: *AST, n: ASTNode) !void {
        try self.nodes.append(self.allocator, n);
    }

    pub fn pushRodataNode(self: *AST, n: ASTNode) !void {
        try self.rodata_nodes.append(self.allocator, n);
    }

    /// Find the Instruction node whose offset matches `offset`. Returns a
    /// mutable pointer so E.3's buildProgram can rewrite `imm`/`off`
    /// fields in place.
    ///
    /// Rust ast.rs L48-61. Linear scan is fine — N is bounded by the
    /// number of instructions (~200 for counter.o); a binary search
    /// would require keeping nodes sorted, which isn't guaranteed by
    /// the build order.
    pub fn getInstructionAtOffset(self: *AST, offset: u64) ?*instruction_mod.Instruction {
        for (self.nodes.items) |*n| {
            switch (n.*) {
                .Instruction => |*payload| {
                    if (payload.offset == offset) return &payload.instruction;
                },
                else => {},
            }
        }
        return null;
    }

    /// Lookup a rodata node by its in-rodata offset. Mirrors Rust's
    /// get_rodata_at_offset (ast.rs L63-78).
    pub fn getRodataAtOffset(self: *AST, offset: u64) ?*ROData {
        for (self.rodata_nodes.items) |*n| {
            switch (n.*) {
                .ROData => |*payload| {
                    if (payload.offset == offset) return &payload.rodata;
                },
                else => {},
            }
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // E.3: buildProgram
    // -----------------------------------------------------------------------

    pub const BuildProgramError = error{
        OutOfMemory,
        UndefinedLabel,
    };

    /// Build a ParseResult from this AST, resolving all symbolic labels
    /// into concrete offsets / addresses.
    ///
    /// **Consumes the AST** — after this call `self.nodes` and
    /// `self.rodata_nodes` are empty; ownership is transferred to the
    /// returned ParseResult. Callers must not use the AST again.
    ///
    /// Spec: 03-technical-spec.md §6.3
    pub fn buildProgram(self: *AST, arch: SbpfArch, debug_sections: []const DebugSection) BuildProgramError!ParseResult {
        const alloc = self.allocator;

        // Phase A: collect label → offset mappings.
        var label_map = std.StringHashMap(u64).init(alloc);
        defer label_map.deinit();

        var numeric_labels: std.ArrayList(NumericLabelEntry) = .empty;
        defer numeric_labels.deinit(alloc);

        for (self.nodes.items, 0..) |*n, idx| {
            switch (n.*) {
                .Label => |payload| {
                    try label_map.put(payload.label.name, payload.offset);
                    if (isNumericLabel(payload.label.name)) {
                        try numeric_labels.append(alloc, .{
                            .name = payload.label.name,
                            .offset = payload.offset,
                            .idx = idx,
                        });
                    }
                },
                else => {},
            }
        }

        // ROData nodes live after the text image.
        for (self.rodata_nodes.items) |*n| {
            switch (n.*) {
                .ROData => |payload| {
                    try label_map.put(payload.rodata.name, payload.offset + self.text_size);
                },
                else => {},
            }
        }

        // Phase B: determine prog_is_static.
        //
        // Rust ast.rs L135-140:
        //   program_is_static = arch.is_v3() || !any(
        //     is_syscall() || (opcode == Lddw && imm is Left)
        //   )
        //
        // V3 programs are always static. V0 programs are static only when
        // they emit NO syscalls and NO symbolic lddw (i.e. no rodata
        // references requiring R_SBF_64_RELATIVE at load time).
        var prog_is_static = true;
        if (arch != .V3) {
            for (self.nodes.items, 0..) |*n, idx| {
                switch (n.*) {
                    .Instruction => |payload| {
                        const inst = payload.instruction;
                        if (isSyscallCandidate(inst, &label_map, numeric_labels.items, idx)) {
                            prog_is_static = false;
                            break;
                        }
                        if (inst.opcode == .Lddw) {
                            if (inst.imm) |imm| switch (imm) {
                                .left => {
                                    prog_is_static = false;
                                },
                                else => {},
                            };
                            if (!prog_is_static) break;
                        }
                    },
                    else => {},
                }
            }
        }

        var dynamic_symbols = DynamicSymbolMap.init(alloc);
        var relocation_data = RelDynMap.init(alloc);

        // Phase C: syscall injection.
        // Syscalls are Call instructions with an unresolved (.left) imm label.
        // We mark them by setting src=1, imm=-1 (V0) or resolve to hash (V3).
        // This marker is checked in Phase D to skip syscall calls.
        for (self.nodes.items, 0..) |*n, idx| {
            switch (n.*) {
                .Instruction => |*payload| {
                    var inst = &payload.instruction;
                    if (!isSyscallCandidate(inst.*, &label_map, numeric_labels.items, idx)) continue;
                    const name = switch (inst.imm.?) {
                        .left => |label| label,
                        .right => continue,
                    };
                    if (arch == .V3) {
                        inst.src = .{ .n = 0 };
                        inst.imm = .{ .right = .{ .Int = @intCast(syscall_mod.murmur3_32(name)) } };
                    } else {
                        // Mark as syscall: src=1, imm=-1. Phase D skips these.
                        inst.src = .{ .n = 1 };
                        inst.imm = .{ .right = .{ .Int = -1 } };
                        try relocation_data.addRelDyn(alloc, payload.offset, .RSbfSyscall, name);
                        try dynamic_symbols.addCallTarget(alloc, name, payload.offset);
                    }
                },
                else => {},
            }
        }

        // Phase D: jump / call label resolution.
        for (self.nodes.items, 0..) |*n, idx| {
            switch (n.*) {
                .Instruction => |*payload| {
                    var inst = &payload.instruction;
                    const offset = payload.offset;

                    // Jump resolution.
                    if (inst.isJump()) {
                        const off_imm = inst.off orelse continue;
                        const label_name = switch (off_imm) {
                            .left => |label| label,
                            .right => continue,
                        };
                        const target_offset = try resolveLabel(&label_map, numeric_labels.items, idx, label_name);
                        const rel_offset = @divExact(@as(i64, @intCast(target_offset)) - @as(i64, @intCast(offset)), 8) - 1;
                        inst.off = .{ .right = @intCast(rel_offset) };
                        continue;
                    }

                    // Call resolution (non-syscall calls).
                    if (inst.opcode == .Call) {
                        const imm_val = inst.imm orelse continue;
                        const label_name = switch (imm_val) {
                            .left => |label| label,
                            .right => continue,
                        };
                        // Skip syscalls: marked by src=1, imm=-1 in Phase C.
                        const is_marked_syscall = inst.src != null and inst.src.?.n == 1 and
                            inst.imm != null and inst.imm.? == .right and inst.imm.?.right == .Int and inst.imm.?.right.Int == -1;
                        if (is_marked_syscall) continue;

                        const target_offset = try resolveLabel(&label_map, numeric_labels.items, idx, label_name);
                        const rel_offset = @divExact(@as(i64, @intCast(target_offset)) - @as(i64, @intCast(offset)), 8) - 1;
                        inst.src = .{ .n = 1 };
                        inst.imm = .{ .right = .{ .Int = rel_offset } };
                    }
                },
                else => {},
            }
        }

        // Phase E: lddw absolutization.
        const ph_count: u64 = if (prog_is_static) 1 else 3;
        const ph_offset: u64 = 64 + ph_count * 56;

        for (self.nodes.items, 0..) |*n, idx| {
            switch (n.*) {
                .Instruction => |*payload| {
                    var inst = &payload.instruction;
                    if (inst.opcode != .Lddw) continue;
                    const imm_val = inst.imm orelse continue;
                    const label_name = switch (imm_val) {
                        .left => |label| label,
                        .right => continue,
                    };
                    const target_offset = try resolveLabel(&label_map, numeric_labels.items, idx, label_name);

                    if (arch != .V3) {
                        try relocation_data.addRelDyn(alloc, payload.offset, .RSbf64Relative, label_name);
                    }

                    const abs: u64 = if (arch == .V3)
                        target_offset - self.text_size
                    else
                        target_offset + ph_offset;

                    inst.imm = .{ .right = .{ .Addr = @intCast(abs) } };
                },
                else => {},
            }
        }

        // Phase F: collect entry_point.
        for (self.nodes.items) |*n| {
            switch (n.*) {
                .GlobalDecl => |payload| {
                    const entry_label = payload.global_decl.entry_label;
                    const offset = label_map.get(entry_label) orelse continue;
                    try dynamic_symbols.addEntryPoint(alloc, entry_label, offset);
                },
                else => {},
            }
        }

        // Phase G: assemble ParseResult.
        // Move node lists out of AST so ParseResult owns them.
        const code_nodes = self.nodes;
        self.nodes = .empty;
        const rodata_nodes = self.rodata_nodes;
        self.rodata_nodes = .empty;

        return ParseResult{
            .code_section = CodeSection.new(code_nodes, self.text_size),
            .data_section = DataSection.new(rodata_nodes, self.rodata_size),
            .dynamic_symbols = dynamic_symbols,
            .relocation_data = relocation_data,
            .prog_is_static = prog_is_static,
            .arch = arch,
            .debug_sections = debug_sections,
        };
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn isNumericLabel(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn parseNumericLabelReference(name: []const u8) ?struct { base: []const u8, forward: bool } {
    if (name.len < 2) return null;
    const suffix = name[name.len - 1];
    if (suffix != 'f' and suffix != 'b') return null;
    const base = name[0 .. name.len - 1];
    if (!isNumericLabel(base)) return null;
    return .{ .base = base, .forward = suffix == 'f' };
}

fn resolveNumericLabel(
    numeric_labels: []const NumericLabelEntry,
    current_idx: usize,
    label_name: []const u8,
) ?u64 {
    const ref = parseNumericLabelReference(label_name) orelse return null;
    if (ref.forward) {
        for (numeric_labels) |entry| {
            if (entry.idx > current_idx and std.mem.eql(u8, entry.name, ref.base)) {
                return entry.offset;
            }
        }
        return null;
    }

    var i = numeric_labels.len;
    while (i > 0) {
        i -= 1;
        const entry = numeric_labels[i];
        if (entry.idx < current_idx and std.mem.eql(u8, entry.name, ref.base)) {
            return entry.offset;
        }
    }
    return null;
}

fn isSyscallCandidate(
    inst: instruction_mod.Instruction,
    label_map: *std.StringHashMap(u64),
    numeric_labels: []const NumericLabelEntry,
    current_idx: usize,
) bool {
    if (inst.opcode != .Call) return false;
    const imm = inst.imm orelse return false;
    const label_name = switch (imm) {
        .left => |label| label,
        .right => return false,
    };
    _ = resolveLabel(label_map, numeric_labels, current_idx, label_name) catch
        return true;
    return false;
}

fn resolveLabel(
    label_map: *std.StringHashMap(u64),
    numeric_labels: []const NumericLabelEntry,
    current_idx: usize,
    label_name: []const u8,
) AST.BuildProgramError!u64 {
    if (resolveNumericLabel(numeric_labels, current_idx, label_name)) |offset| {
        return offset;
    }
    return label_map.get(label_name) orelse AST.BuildProgramError.UndefinedLabel;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "AST init/deinit clean baseline" {
    var ast = AST.init(testing.allocator);
    defer ast.deinit();
    try testing.expectEqual(@as(usize, 0), ast.nodes.items.len);
    try testing.expectEqual(@as(usize, 0), ast.rodata_nodes.items.len);
    try testing.expectEqual(@as(u64, 0), ast.text_size);
    try testing.expectEqual(@as(u64, 0), ast.rodata_size);
}

test "AST.setTextSize / setRodataSize update fields" {
    var ast = AST.init(testing.allocator);
    defer ast.deinit();
    ast.setTextSize(64);
    ast.setRodataSize(23);
    try testing.expectEqual(@as(u64, 64), ast.text_size);
    try testing.expectEqual(@as(u64, 23), ast.rodata_size);
}

test "AST.pushNode / pushRodataNode append in order" {
    var ast = AST.init(testing.allocator);
    defer ast.deinit();
    try ast.pushNode(.{ .Label = .{
        .label = .{ .name = "a", .span = .{ .start = 0, .end = 1 } },
        .offset = 0,
    } });
    try ast.pushNode(.{ .Label = .{
        .label = .{ .name = "b", .span = .{ .start = 0, .end = 1 } },
        .offset = 8,
    } });
    try ast.pushRodataNode(.{ .ROData = .{
        .rodata = .{ .name = "foo", .bytes = "x", .span = .{ .start = 0, .end = 1 } },
        .offset = 0,
    } });

    try testing.expectEqual(@as(usize, 2), ast.nodes.items.len);
    try testing.expectEqual(@as(usize, 1), ast.rodata_nodes.items.len);

    const first = ast.nodes.items[0];
    try testing.expectEqualStrings("a", first.Label.label.name);
    const second = ast.nodes.items[1];
    try testing.expectEqual(@as(u64, 8), second.Label.offset);
}

test "AST.getInstructionAtOffset finds matching instruction" {
    var ast = AST.init(testing.allocator);
    defer ast.deinit();

    // Put two instructions at offsets 0 and 8, plus a label in between.
    const exit_inst = instruction_mod.Instruction{
        .opcode = .Exit,
        .dst = null,
        .src = null,
        .off = null,
        .imm = null,
        .span = .{ .start = 0, .end = 8 },
    };
    const mov_inst = instruction_mod.Instruction{
        .opcode = .Mov64Imm,
        .dst = .{ .n = 0 },
        .src = null,
        .off = null,
        .imm = .{ .right = .{ .Int = 0 } },
        .span = .{ .start = 0, .end = 8 },
    };
    try ast.pushNode(.{ .Instruction = .{ .instruction = mov_inst, .offset = 0 } });
    try ast.pushNode(.{ .Label = .{
        .label = .{ .name = "mid", .span = .{ .start = 0, .end = 1 } },
        .offset = 8,
    } });
    try ast.pushNode(.{ .Instruction = .{ .instruction = exit_inst, .offset = 8 } });

    const found = ast.getInstructionAtOffset(8) orelse return error.TestExpectedFound;
    try testing.expectEqual(instruction_mod.Instruction.getSize(found.*), 8);
    try testing.expectEqual(@as(@TypeOf(exit_inst.opcode), .Exit), found.opcode);

    try testing.expect(ast.getInstructionAtOffset(100) == null);

    // Mutate via the returned pointer.
    found.dst = .{ .n = 7 };
    const again = ast.getInstructionAtOffset(8).?;
    try testing.expectEqual(@as(u8, 7), again.dst.?.n);
}

test "AST.getRodataAtOffset finds matching rodata entry" {
    var ast = AST.init(testing.allocator);
    defer ast.deinit();

    try ast.pushRodataNode(.{ .ROData = .{
        .rodata = .{ .name = "FOO", .bytes = "abc", .span = .{ .start = 0, .end = 3 } },
        .offset = 0,
    } });
    try ast.pushRodataNode(.{ .ROData = .{
        .rodata = .{ .name = "BAR", .bytes = "xy", .span = .{ .start = 0, .end = 2 } },
        .offset = 3,
    } });

    const foo = ast.getRodataAtOffset(0) orelse return error.TestExpectedFound;
    try testing.expectEqualStrings("FOO", foo.name);

    const bar = ast.getRodataAtOffset(3) orelse return error.TestExpectedFound;
    try testing.expectEqualStrings("BAR", bar.name);
    try testing.expectEqualSlices(u8, "xy", bar.bytes);

    try testing.expect(ast.getRodataAtOffset(100) == null);
}

// E.3 tests -------------------------------------------------------------

test "buildProgram: empty AST → empty ParseResult" {
    var ast = AST.init(testing.allocator);
    defer ast.deinit();

    var pr = try ast.buildProgram(.V0, &.{});
    defer pr.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), pr.code_section.nodes.items.len);
    try testing.expectEqual(@as(usize, 0), pr.data_section.nodes.items.len);
    try testing.expectEqual(@as(usize, 0), pr.dynamic_symbols.entries.items.len);
    try testing.expectEqual(@as(usize, 0), pr.relocation_data.entries.items.len);
    try testing.expect(pr.prog_is_static);
    try testing.expectEqual(.V0, pr.arch);
}

test "buildProgram: single label entrypoint → label_offset_map effective" {
    var ast = AST.init(testing.allocator);
    defer ast.deinit();
    ast.setTextSize(64);

    try ast.pushNode(.{ .Label = .{
        .label = .{ .name = "entrypoint", .span = .{ .start = 0, .end = 1 } },
        .offset = 0,
    } });
    try ast.pushNode(.{ .GlobalDecl = .{
        .global_decl = .{ .entry_label = "entrypoint", .span = .{ .start = 0, .end = 1 } },
    } });

    var pr = try ast.buildProgram(.V0, &.{});
    defer pr.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), pr.dynamic_symbols.entries.items.len);
    const sym = pr.dynamic_symbols.entries.items[0];
    try testing.expect(sym.is_entry_point);
    try testing.expectEqualStrings("entrypoint", sym.name);
    try testing.expectEqual(@as(u64, 0), sym.offset);
}

test "buildProgram: syscall injection V0" {
    var ast = AST.init(testing.allocator);
    defer ast.deinit();
    ast.setTextSize(8);

    const call_inst = instruction_mod.Instruction{
        .opcode = .Call,
        .dst = null,
        .src = null,
        .off = null,
        .imm = .{ .left = "sol_log_" },
        .span = .{ .start = 0, .end = 8 },
    };
    try ast.pushNode(.{ .Instruction = .{ .instruction = call_inst, .offset = 0 } });

    var pr = try ast.buildProgram(.V0, &.{});
    defer pr.deinit(testing.allocator);

    // Syscall injected: src=1, imm=-1
    const inst = pr.code_section.nodes.items[0].Instruction.instruction;
    try testing.expectEqual(@as(u8, 1), inst.src.?.n);
    const imm_val = inst.imm.?;
    try testing.expect(imm_val == .right);
    try testing.expectEqual(@as(i64, -1), imm_val.right.Int);

    // Relocation and dynamic symbol added.
    try testing.expectEqual(@as(usize, 1), pr.relocation_data.entries.items.len);
    try testing.expectEqual(@as(usize, 1), pr.dynamic_symbols.entries.items.len);
    try testing.expectEqualStrings("sol_log_", pr.relocation_data.entries.items[0].symbol_name);
    try testing.expectEqualStrings("sol_log_", pr.dynamic_symbols.entries.items[0].name);
}

test "buildProgram: ordinary symbolic call resolves as relative call" {
    var ast = AST.init(testing.allocator);
    defer ast.deinit();
    ast.setTextSize(16);

    const call_inst = instruction_mod.Instruction{
        .opcode = .Call,
        .dst = null,
        .src = null,
        .off = null,
        .imm = .{ .left = "foo" },
        .span = .{ .start = 0, .end = 8 },
    };
    try ast.pushNode(.{ .Instruction = .{ .instruction = call_inst, .offset = 0 } });
    try ast.pushNode(.{ .Label = .{
        .label = .{ .name = "foo", .span = .{ .start = 0, .end = 1 } },
        .offset = 8,
    } });

    var pr = try ast.buildProgram(.V0, &.{});
    defer pr.deinit(testing.allocator);

    const inst = pr.code_section.nodes.items[0].Instruction.instruction;
    try testing.expectEqual(@as(u8, 1), inst.src.?.n);
    try testing.expect(inst.imm.? == .right);
    try testing.expectEqual(@as(i64, 0), inst.imm.?.right.Int);
    try testing.expectEqual(@as(usize, 0), pr.relocation_data.entries.items.len);
    try testing.expectEqual(@as(usize, 0), pr.dynamic_symbols.entries.items.len);
    try testing.expect(pr.prog_is_static);
}

test "buildProgram: jump label resolution" {
    var ast = AST.init(testing.allocator);
    defer ast.deinit();
    ast.setTextSize(16);

    // ja <target> at offset 0, target label at offset 8.
    const ja_inst = instruction_mod.Instruction{
        .opcode = .Ja,
        .dst = null,
        .src = null,
        .off = .{ .left = "target" },
        .imm = null,
        .span = .{ .start = 0, .end = 8 },
    };
    try ast.pushNode(.{ .Instruction = .{ .instruction = ja_inst, .offset = 0 } });
    try ast.pushNode(.{ .Label = .{
        .label = .{ .name = "target", .span = .{ .start = 0, .end = 1 } },
        .offset = 8,
    } });

    var pr = try ast.buildProgram(.V0, &.{});
    defer pr.deinit(testing.allocator);

    const resolved = pr.code_section.nodes.items[0].Instruction.instruction;
    const off_val = resolved.off.?;
    try testing.expect(off_val == .right);
    // rel = (8 - 0) / 8 - 1 = 0
    try testing.expectEqual(@as(i16, 0), off_val.right);
}

test "buildProgram: numeric forward label resolution" {
    var ast = AST.init(testing.allocator);
    defer ast.deinit();
    ast.setTextSize(16);

    const ja_inst = instruction_mod.Instruction{
        .opcode = .Ja,
        .dst = null,
        .src = null,
        .off = .{ .left = "1f" },
        .imm = null,
        .span = .{ .start = 0, .end = 8 },
    };
    try ast.pushNode(.{ .Instruction = .{ .instruction = ja_inst, .offset = 0 } });
    try ast.pushNode(.{ .Label = .{
        .label = .{ .name = "1", .span = .{ .start = 0, .end = 1 } },
        .offset = 8,
    } });

    var pr = try ast.buildProgram(.V0, &.{});
    defer pr.deinit(testing.allocator);

    const resolved = pr.code_section.nodes.items[0].Instruction.instruction;
    try testing.expect(resolved.off.? == .right);
    try testing.expectEqual(@as(i16, 0), resolved.off.?.right);
}

test "buildProgram: lddw absolutization V0 (symbolic-imm → dynamic)" {
    var ast = AST.init(testing.allocator);
    defer ast.deinit();
    const text_size: u64 = 16;
    ast.setTextSize(text_size);
    ast.setRodataSize(23);

    // lddw <rodata> at offset 0, rodata at offset 0 (text_size=16).
    const lddw_inst = instruction_mod.Instruction{
        .opcode = .Lddw,
        .dst = .{ .n = 1 },
        .src = null,
        .off = null,
        .imm = .{ .left = ".rodata.__anon_0_0" },
        .span = .{ .start = 0, .end = 16 },
    };
    try ast.pushNode(.{ .Instruction = .{ .instruction = lddw_inst, .offset = 0 } });
    try ast.pushRodataNode(.{ .ROData = .{
        .rodata = .{ .name = ".rodata.__anon_0_0", .bytes = "Hello", .span = .{ .start = 0, .end = 5 } },
        .offset = 0,
    } });

    var pr = try ast.buildProgram(.V0, &.{});
    defer pr.deinit(testing.allocator);

    // A program with a symbolic lddw is NOT static — it needs a
    // RSbf64Relative relocation at load time. Rust algorithm
    // ast.rs L135-140.
    try testing.expect(!pr.prog_is_static);
    const ph_count: u64 = 3;
    const ph_offset: u64 = 64 + ph_count * 56;
    const expected_abs = text_size + ph_offset; // rodata label = text_size + 0

    const resolved = pr.code_section.nodes.items[0].Instruction.instruction;
    const imm_val = resolved.imm.?;
    try testing.expect(imm_val == .right);
    try testing.expectEqual(@as(i64, @intCast(expected_abs)), imm_val.right.Addr);

    // RSbf64Relative relocation added.
    try testing.expectEqual(@as(usize, 1), pr.relocation_data.entries.items.len);
    try testing.expectEqual(RelocationType.RSbf64Relative, pr.relocation_data.entries.items[0].type);
}

test "buildProgram: lddw absolutization V0 dynamic" {
    var ast = AST.init(testing.allocator);
    defer ast.deinit();
    ast.setTextSize(16);
    ast.setRodataSize(23);

    // lddw <rodata> at offset 0, plus a syscall to force dynamic.
    const lddw_inst = instruction_mod.Instruction{
        .opcode = .Lddw,
        .dst = .{ .n = 1 },
        .src = null,
        .off = null,
        .imm = .{ .left = ".rodata.__anon_0_0" },
        .span = .{ .start = 0, .end = 16 },
    };
    const call_inst = instruction_mod.Instruction{
        .opcode = .Call,
        .dst = null,
        .src = null,
        .off = null,
        .imm = .{ .left = "sol_log_" },
        .span = .{ .start = 0, .end = 8 },
    };
    try ast.pushNode(.{ .Instruction = .{ .instruction = lddw_inst, .offset = 0 } });
    try ast.pushNode(.{ .Instruction = .{ .instruction = call_inst, .offset = 16 } });
    try ast.pushRodataNode(.{ .ROData = .{
        .rodata = .{ .name = ".rodata.__anon_0_0", .bytes = "Hello", .span = .{ .start = 0, .end = 5 } },
        .offset = 0,
    } });

    var pr = try ast.buildProgram(.V0, &.{});
    defer pr.deinit(testing.allocator);

    try testing.expect(!pr.prog_is_static);
    const ph_count: u64 = 3;
    const ph_offset: u64 = 64 + ph_count * 56;
    const expected_abs = ast.text_size + ph_offset;

    const resolved = pr.code_section.nodes.items[0].Instruction.instruction;
    const imm_val = resolved.imm.?;
    try testing.expect(imm_val == .right);
    try testing.expectEqual(@as(i64, @intCast(expected_abs)), imm_val.right.Addr);
}
