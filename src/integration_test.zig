// Integration tests against real fixture ELF objects.
//
// `@embedFile` only reaches within the src/ package, hence the fixtures live
// under src/testdata/ — they're pre-built with:
//
//     ZIGNOCCHIO_DIR=/path/to/zignocchio ./scripts/build-bc.sh hello
//     cp fixtures/helloworld/out/hello.o src/testdata/hello.o
//
// These tests verify that the section/symbol/reloc iterators work together
// against a real zignocchio-produced BPF ELF — covering corner cases the
// synthetic-header unit tests don't reach (e.g. multiple section types,
// real symbol layout, llvm-generated rodata conventions).
//
// Phase: integration / end-of-Epic-C smoke test.
// Tests: 05-test-spec.md §4.6 (elf layer real-data corner)

const std = @import("std");
const testing = std.testing;

const lib = @import("lib.zig");
const ElfFile = lib.ElfFile;
const SymTableKind = lib.SymTableKind;
const RelocType = lib.RelocType;

const hello_bytes = @embedFile("testdata/hello.o");
const hello_shim_so = @embedFile("testdata/hello.shim.so");

test "integration: hello.o parses as valid BPF ELF" {
    const file = try ElfFile.parse(hello_bytes);
    try testing.expect(file.header.e_machine == .BPF);
    // .o files are ET_REL (1), not ET_DYN. ET_DYN is for linked .so programs.
    try testing.expectEqual(@as(u64, 1), @as(u64, @intFromEnum(file.header.e_type)));
    try testing.expect(file.sectionCount() >= 5);
    try testing.expect(file.shstrtab.len > 0);
}

test "integration: hello.o sections include .text and .rodata" {
    const file = try ElfFile.parse(hello_bytes);

    var found_text = false;
    var found_rodata = false;
    var found_rel_text = false;

    var it = file.iterSections();
    while (try it.next()) |sec| {
        if (std.mem.eql(u8, sec.name, ".text")) {
            found_text = true;
            // .text must be AX (allocatable + executable).
            try testing.expect(sec.flags() & 0x2 != 0); // SHF_ALLOC
            try testing.expect(sec.flags() & 0x4 != 0); // SHF_EXECINSTR
            try testing.expect(sec.size() > 0);
            try testing.expect(sec.data.len == sec.size());
        } else if (std.mem.startsWith(u8, sec.name, ".rodata")) {
            found_rodata = true;
        } else if (std.mem.eql(u8, sec.name, ".rel.text")) {
            found_rel_text = true;
        }
    }

    try testing.expect(found_text);
    try testing.expect(found_rodata);
    try testing.expect(found_rel_text);
}

test "integration: hello.o symtab contains entrypoint as GLOBAL FUNC" {
    const file = try ElfFile.parse(hello_bytes);
    var sym_it = try file.iterSymbols(.symtab);

    var found_entrypoint = false;
    while (try sym_it.next()) |sym| {
        if (std.mem.eql(u8, sym.name, "entrypoint")) {
            found_entrypoint = true;
            try testing.expectEqual(lib.SymbolKind.Func, sym.kind());
            try testing.expectEqual(lib.SymbolBinding.Global, sym.binding());
            try testing.expect(sym.size() > 0); // entrypoint has 8 instructions = 64 bytes
            try testing.expect(sym.sectionIndex() != null);
        }
    }
    try testing.expect(found_entrypoint);
}

test "integration: hello.o .rel.text has one R_BPF_64_64 to .rodata" {
    const file = try ElfFile.parse(hello_bytes);

    // Find .rel.text.
    var rel_section_opt: ?lib.Section = null;
    var sit = file.iterSections();
    while (try sit.next()) |sec| {
        if (std.mem.eql(u8, sec.name, ".rel.text")) {
            rel_section_opt = sec;
            break;
        }
    }
    try testing.expect(rel_section_opt != null);

    var rit = try file.iterRelocations(rel_section_opt.?);
    try testing.expect(rit.count >= 1);

    // First reloc should be BPF_64_64 per C0-findings.md (lddw to string).
    const r = rit.next().?;
    try testing.expectEqual(RelocType.BPF_64_64, r.kind());
    try testing.expectEqual(@as(?i64, null), r.addend); // SHT_REL: no explicit addend
}

test "integration: hello.o .text decodes as 7 valid instructions (with 1 lddw)" {
    const Instruction = lib.Instruction;
    const file = try ElfFile.parse(hello_bytes);

    var text_data: ?[]const u8 = null;
    var sit = file.iterSections();
    while (try sit.next()) |sec| {
        if (std.mem.eql(u8, sec.name, ".text")) {
            text_data = sec.data;
            break;
        }
    }
    try testing.expect(text_data != null);

    // Walk the instruction stream: Lddw consumes 16 bytes, everything else 8.
    var off: usize = 0;
    var count: usize = 0;
    var lddw_count: usize = 0;
    while (off < text_data.?.len) {
        const inst = try Instruction.fromBytes(text_data.?[off..]);
        if (inst.opcode == .Lddw) lddw_count += 1;
        off += @intCast(inst.getSize());
        count += 1;
    }

    // Per llvm-objdump, hello.o has 7 instructions:
    //   ldxdw, jeq, lddw, mov64imm, call, mov64imm, exit
    // That's 6×8B + 1×16B = 64 bytes. The lddw counts as one instruction
    // despite consuming two 8-byte slots.
    try testing.expectEqual(@as(usize, 7), count);
    try testing.expectEqual(@as(usize, 1), lddw_count);
    try testing.expectEqual(@as(usize, 64), off);
}

// ---------------------------------------------------------------------------
// G.4 — end-to-end pipeline: hello.o → Program.emitBytecode → byte-diff
// against reference-shim golden output (testdata/hello-shim.so).
// ---------------------------------------------------------------------------

/// End-to-end: parse ELF bytes → byteparser → AST → buildProgram →
/// Program.fromParseResult → emitBytecode. Caller owns the returned bytes.
fn runPipeline(allocator: std.mem.Allocator, elf_bytes: []const u8) ![]u8 {
    const elf_file = try lib.ElfFile.parse(elf_bytes);

    var bpr = try lib.byteparser.byteParse(allocator, &elf_file);
    defer bpr.deinit();

    var ast = try lib.AST.fromByteParse(allocator, &bpr);
    // buildProgram consumes ast.nodes/rodata_nodes; keep the AST handle
    // alive for the remaining (now-empty) list teardown.

    // Convert ByteParseResult.debug → []ast.DebugSection (allocator-owned
    // slice; ParseResult takes ownership after buildProgram consumes it).
    const debug_slice = try allocator.alloc(lib.ast.DebugSection, bpr.debug.entries.items.len);
    for (bpr.debug.entries.items, 0..) |e, i| {
        debug_slice[i] = .{ .name = e.name, .data = e.data };
    }

    var parse_result = try ast.buildProgram(.V0, debug_slice);
    // ParseResult owns the rest; ast itself is now empty.
    ast.deinit();

    defer parse_result.deinit(allocator);

    var program = try lib.Program.fromParseResult(allocator, &parse_result);
    defer program.deinit(allocator);

    return try program.emitBytecode(allocator);
}

test "integration: hello.o emitBytecode produces a valid ELF" {
    const allocator = testing.allocator;

    const bytes = try runPipeline(allocator, hello_bytes);
    defer allocator.free(bytes);

    // Must be a well-formed ELF with 3 program headers (V0 dynamic) and
    // enough sections to cover the dynamic layout.
    try testing.expectEqualSlices(u8, "\x7fELF", bytes[0..4]);
    const e_phnum = std.mem.readInt(u16, bytes[56..58], .little);
    try testing.expectEqual(@as(u16, 3), e_phnum);

    const e_shnum = std.mem.readInt(u16, bytes[60..62], .little);
    try testing.expect(e_shnum >= 7); // at least Null+Code+Dyn+Sym+Str+Rel+ShStrTab
    const e_shoff = std.mem.readInt(u64, bytes[40..48], .little);
    try testing.expectEqual(bytes.len, e_shoff + @as(u64, e_shnum) * 64);
}

test "integration: hello.o emitBytecode matches reference-shim golden output" {
    const allocator = testing.allocator;

    const bytes = try runPipeline(allocator, hello_bytes);
    defer allocator.free(bytes);

    // Byte-for-byte equality with the reference-shim's hello.o output.
    // This is the headline C1 milestone (per PRD D.6): Zig port and the
    // Rust shim produce the same .so bytes. Any regression here indicates
    // a divergence in byteparser / buildProgram / Program layout.
    try testing.expectEqual(hello_shim_so.len, bytes.len);
    try testing.expectEqualSlices(u8, hello_shim_so, bytes);
}

// ---------------------------------------------------------------------------
// I.2 + I.3 — 9-example byte-diff matrix against reference-shim goldens.
//
// Each (.o → .shim.so) pair was produced by the reference-shim build and
// committed under src/testdata/. The Zig pipeline must reproduce the same
// bytes for every example. This is the C1 acceptance gate.
// ---------------------------------------------------------------------------

const Golden = struct {
    name: []const u8,
    input: []const u8,
    shim_so: []const u8,
};

const goldens = [_]Golden{
    .{
        .name = "hello",
        .input = @embedFile("testdata/hello.o"),
        .shim_so = @embedFile("testdata/hello.shim.so"),
    },
    .{
        .name = "noop",
        .input = @embedFile("testdata/noop.o"),
        .shim_so = @embedFile("testdata/noop.shim.so"),
    },
    .{
        .name = "logonly",
        .input = @embedFile("testdata/logonly.o"),
        .shim_so = @embedFile("testdata/logonly.shim.so"),
    },
    .{
        .name = "counter",
        .input = @embedFile("testdata/counter.o"),
        .shim_so = @embedFile("testdata/counter.shim.so"),
    },
    .{
        .name = "vault",
        .input = @embedFile("testdata/vault.o"),
        .shim_so = @embedFile("testdata/vault.shim.so"),
    },
    .{
        .name = "transfer-sol",
        .input = @embedFile("testdata/transfer-sol.o"),
        .shim_so = @embedFile("testdata/transfer-sol.shim.so"),
    },
    .{
        .name = "pda-storage",
        .input = @embedFile("testdata/pda-storage.o"),
        .shim_so = @embedFile("testdata/pda-storage.shim.so"),
    },
    .{
        .name = "escrow",
        .input = @embedFile("testdata/escrow.o"),
        .shim_so = @embedFile("testdata/escrow.shim.so"),
    },
    .{
        .name = "token-vault",
        .input = @embedFile("testdata/token-vault.o"),
        .shim_so = @embedFile("testdata/token-vault.shim.so"),
    },
    // D.2 fixture — a minimal BPF program built with `-g` to exercise the
    // `.debug_loc/.debug_abbrev/.debug_info/.debug_str/.debug_line`
    // preservation path. The 9 zignocchio examples use `-O ReleaseSmall`
    // and have no DWARF sections, so this is the only byte-diff that
    // covers the debug-reuse code path in Program.appendDebugSections.
    .{
        .name = "mini-debug",
        .input = @embedFile("testdata/mini-debug.o"),
        .shim_so = @embedFile("testdata/mini-debug.shim.so"),
    },
};

test "integration: 9 zignocchio examples byte-match reference-shim" {
    const allocator = testing.allocator;

    for (goldens) |g| {
        const bytes = runPipeline(allocator, g.input) catch |err| {
            std.debug.print("[{s}] pipeline failed: {s}\n", .{ g.name, @errorName(err) });
            return err;
        };
        defer allocator.free(bytes);

        if (bytes.len != g.shim_so.len) {
            std.debug.print(
                "[{s}] length mismatch: zig={d} shim={d}\n",
                .{ g.name, bytes.len, g.shim_so.len },
            );
            return error.TestExpectedEqual;
        }

        if (!std.mem.eql(u8, bytes, g.shim_so)) {
            // Find first differing byte for easier diagnosis.
            var first_diff: usize = 0;
            while (first_diff < bytes.len and bytes[first_diff] == g.shim_so[first_diff]) {
                first_diff += 1;
            }
            std.debug.print(
                "[{s}] byte differ at offset 0x{x}: zig=0x{x:0>2} shim=0x{x:0>2}\n",
                .{ g.name, first_diff, bytes[first_diff], g.shim_so[first_diff] },
            );
            return error.TestExpectedEqual;
        }
    }
}
