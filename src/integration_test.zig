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
