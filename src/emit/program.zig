// Program — the final assembler between ParseResult and the raw .so bytes.
//
// Port of Rust sbpf-assembler::program. The layout follows the Rust
// implementation exactly; the plan:
//
//   Epic G.1 — Program struct + allocator-owned sections/names storage
//               and a thin init/deinit pair (this file)
//   Epic G.2 — `fromParseResult` builder: walk the ParseResult and append
//               section instances in the correct order
//   Epic G.3 — layout pass: assign offsets, sh_link fixups, program_headers
//   Epic G.4 — `emitBytecode`: serialize ELF header + program headers +
//               section contents + section header table, byte-for-byte
//               matching the reference-shim output
//
// Spec: 03-technical-spec.md §6 (ELF output contract)
// Tests: 05-test-spec.md §4.10

const std = @import("std");
const header_mod = @import("header.zig");
const section_mod = @import("section_types.zig");

pub const ElfHeader = header_mod.ElfHeader;
pub const ProgramHeader = header_mod.ProgramHeader;
pub const SectionType = section_mod.SectionType;

/// Assembled .so image, not yet serialized.
///
/// Ownership:
///   - `sections` is owned (ArrayList), freed by `deinit`
///   - `program_headers` is owned (ArrayList), freed by `deinit`
///   - Individual SectionType variants may borrow ParseResult storage
///     (e.g. CodeSection.nodes, DataSection.nodes, DebugSection.data).
///     Callers must keep the ParseResult alive as long as the Program is
///     live. See `fromParseResult` for the full ownership story.
///   - `section_names` keeps the backing strings for shstrtab name
///     lookups. G.2 will populate; freed by `deinit`.
pub const Program = struct {
    elf_header: ElfHeader,
    program_headers: std.ArrayList(ProgramHeader),
    sections: std.ArrayList(SectionType),
    section_names: std.ArrayList([]const u8),

    /// Construct an empty Program. Callers normally use `fromParseResult`
    /// (G.2) instead; this constructor exists for the G.1 skeleton tests
    /// and for callers that want to drive the assembly manually.
    pub fn init() Program {
        return .{
            .elf_header = ElfHeader.init(),
            .program_headers = .empty,
            .sections = .empty,
            .section_names = .empty,
        };
    }

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        self.program_headers.deinit(allocator);
        self.sections.deinit(allocator);
        self.section_names.deinit(allocator);
    }

    /// Count the sections currently in the section table.
    pub fn sectionCount(self: Program) u16 {
        return @intCast(self.sections.items.len);
    }

    /// Count the program headers currently emitted.
    pub fn programHeaderCount(self: Program) u16 {
        return @intCast(self.program_headers.items.len);
    }

    /// True if a .rodata DataSection variant is present in the section list.
    pub fn hasRodata(self: Program) bool {
        for (self.sections.items) |s| {
            if (s == .data) return true;
        }
        return false;
    }

    /// Append a pre-built section to the program. G.2's `fromParseResult`
    /// uses this internally; exposed for unit tests that want to drive the
    /// layout step-by-step.
    pub fn appendSection(
        self: *Program,
        allocator: std.mem.Allocator,
        section: SectionType,
    ) !void {
        try self.sections.append(allocator, section);
    }

    /// Append a program header (PT_LOAD / PT_DYNAMIC / ...).
    pub fn appendProgramHeader(
        self: *Program,
        allocator: std.mem.Allocator,
        ph: ProgramHeader,
    ) !void {
        try self.program_headers.append(allocator, ph);
    }

    /// Reserve capacity for N section names. Used by G.2 before it knows
    /// the exact count (V0 dynamic has 1 + code + rodata? + 4 dynamic + N
    /// debug + 1 shstrtab; V3 is smaller).
    pub fn reserveSectionNames(
        self: *Program,
        allocator: std.mem.Allocator,
        n: usize,
    ) !void {
        try self.section_names.ensureTotalCapacity(allocator, n);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Program: init produces an empty assembly" {
    var prog = Program.init();
    defer prog.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 0), prog.sectionCount());
    try testing.expectEqual(@as(u16, 0), prog.programHeaderCount());
    try testing.expectEqual(false, prog.hasRodata());
    try testing.expectEqual(@as(u16, header_mod.ET_DYN), prog.elf_header.e_type);
    try testing.expectEqual(@as(u16, header_mod.EM_BPF), prog.elf_header.e_machine);
    try testing.expectEqual(@as(u64, header_mod.ELF64_HEADER_SIZE), prog.elf_header.e_phoff);
}

test "Program: appendSection stores SectionType by value" {
    var prog = Program.init();
    defer prog.deinit(testing.allocator);

    const null_section: SectionType = .{ .null_ = section_mod.NullSection.init() };
    try prog.appendSection(testing.allocator, null_section);

    try testing.expectEqual(@as(u16, 1), prog.sectionCount());
    try testing.expect(std.meta.activeTag(prog.sections.items[0]) == .null_);
    try testing.expectEqual(false, prog.hasRodata());
}

test "Program: hasRodata detects a DataSection variant" {
    var prog = Program.init();
    defer prog.deinit(testing.allocator);

    const null_section: SectionType = .{ .null_ = section_mod.NullSection.init() };
    try prog.appendSection(testing.allocator, null_section);

    const data_section: SectionType = .{ .data = section_mod.DataSection{
        .nodes = &.{},
        .size = 0,
    } };
    try prog.appendSection(testing.allocator, data_section);

    try testing.expectEqual(true, prog.hasRodata());
    try testing.expectEqual(@as(u16, 2), prog.sectionCount());
}

test "Program: appendProgramHeader tracks the header count" {
    var prog = Program.init();
    defer prog.deinit(testing.allocator);

    const ph = ProgramHeader.newDynamic(0x1000, 0x60);
    try prog.appendProgramHeader(testing.allocator, ph);

    try testing.expectEqual(@as(u16, 1), prog.programHeaderCount());
    try testing.expectEqual(@as(u32, header_mod.PT_DYNAMIC), prog.program_headers.items[0].p_type);
}
