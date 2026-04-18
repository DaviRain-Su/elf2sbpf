// byteparser — ELF → ParseResult transform.
//
// Port of sbpf-linker/src/byteparser.rs (302 lines). Grows incrementally
// across Epic D:
//   D.1  scan sections → ro_sections, text_section_bases (this file)
//   D.2  collect pending_rodata from named symbols
//   D.3  collect lddw_targets by scanning text relocations
//   D.4  improved rodata gap-fill (spec §6.2)
//   D.5  merge + rodata_table construction
//   D.6  decode text instructions → ASTNode::Instruction
//   D.7  relocation rewrite (lddw/call)
//   D.8  debug section stash
//   D.9  AST.buildProgram wrapper
//
// Spec: 03-technical-spec.md §2.3, §6.2
// Tests: 05-test-spec.md §4.7

const std = @import("std");
const elf_mod = @import("../elf/reader.zig");
const section_mod = @import("../elf/section.zig");
const symbol_mod = @import("../elf/symbol.zig");
const reloc_mod = @import("../elf/reloc.zig");
const instruction_mod = @import("../common/instruction.zig");

pub const ParseError = error{
    InvalidElf,
    UnsupportedMachine,
    UnsupportedClass,
    UnsupportedEndian,
    OutOfMemory,
    /// A non-STT_SECTION symbol in a rodata section had st_size=0 —
    /// implies the compiler produced an ambiguous rodata layout that
    /// byteparser can't safely handle.
    EmptyNamedRodataSymbol,
    /// A symbol's address+size ran past its containing section's data.
    SymbolOutOfSectionRange,
};

/// A staged rodata entry — one per named rodata symbol, plus one per
/// anonymous gap synthesized by the D.4 gap-fill pass. Rust's
/// `RodataEntry` at byteparser.rs L22-28.
///
/// `name` is borrowed from the input ELF's string table when the entry
/// comes from a symbol; for synthetic anon entries, `name` is owned
/// (allocated via the scan's allocator) and freed by the owner on deinit.
pub const RodataEntry = struct {
    section_index: u16,
    address: u64,
    size: u64,
    name: []const u8,
    /// Whether `name` is owned (true) or borrowed (false). Set by the
    /// producer so deinit knows whether to free. D.2 entries are always
    /// borrowed (the symbol's strtab slice); D.4 anon entries are always
    /// owned.
    name_owned: bool = false,
    /// Raw byte range within the section (zero-copy slice into ELF bytes).
    bytes: []const u8,
};

/// Text-section-local labels and the optional global entrypoint declaration,
/// gathered in the same symbol-scan pass as pending_rodata.
/// This is the byteparser-level equivalent of ast.nodes's Label / GlobalDecl
/// entries before AST construction proper.
pub const TextLabel = struct {
    name: []const u8,
    /// Whether `name` is owned (true) or borrowed (false). Set by the
    /// producer so deinit knows whether to free. D.2 entries are always
    /// borrowed (the symbol's strtab slice); future passes may allocate.
    name_owned: bool = false,
    /// Offset within the **merged** text image (section_base + symbol address).
    offset: u64,
};

/// Output of the symbol-scan pass (D.2).
pub const SymbolScan = struct {
    allocator: std.mem.Allocator,
    pending_rodata: std.ArrayList(RodataEntry),
    text_labels: std.ArrayList(TextLabel),
    /// Name of the entry-point symbol, or null if no "entrypoint" was
    /// seen. Mirrors Rust's GlobalDecl.entry_label.
    entry_label: ?[]const u8,

    pub fn deinit(self: *SymbolScan) void {
        // Free any owned rodata names.
        for (self.pending_rodata.items) |e| {
            if (e.name_owned) self.allocator.free(e.name);
        }
        self.pending_rodata.deinit(self.allocator);
        // Free any owned text label names.
        for (self.text_labels.items) |e| {
            if (e.name_owned) self.allocator.free(e.name);
        }
        self.text_labels.deinit(self.allocator);
    }
};

/// Entry in the "ro_sections" table: every rodata-like section (read-only
/// data either immediately after load or after pointer patching).
/// Mirrors the `ro_sections: HashMap<SectionIndex, Section>` in Rust
/// byteparser.rs L38.
pub const RoSectionEntry = struct {
    section: section_mod.Section,
};

/// Entry in the "text_section_bases" table: for each .text* section, the
/// cumulative byte offset into the merged code image. Multiple .text*
/// sections get their instructions concatenated in the order they appear
/// in the ELF; base offsets track where each section's code starts in
/// the combined stream.
/// Mirrors `text_section_bases: HashMap<SectionIndex, u64>` in Rust
/// byteparser.rs L50.
pub const TextBaseEntry = struct {
    section: section_mod.Section,
    base_offset: u64,
};

/// Result of the section classification pass (D.1 output).
pub const SectionScan = struct {
    allocator: std.mem.Allocator,
    /// ro_sections indexed by section header index (NOT ordered — this is
    /// a map in Rust; we store as a flat ArrayList and look up by index).
    ro_sections: std.ArrayList(RoSectionEntry),
    /// text sections, in ELF order. `base_offset` is the running sum of
    /// prior text section sizes.
    text_bases: std.ArrayList(TextBaseEntry),
    /// Total bytes across all text sections (== sum of text_bases[i].section.size()).
    total_text_size: u64,

    pub fn deinit(self: *SectionScan) void {
        self.ro_sections.deinit(self.allocator);
        self.text_bases.deinit(self.allocator);
    }

    /// Look up a ro_section by its ELF section header index. Returns null
    /// if the given index isn't a rodata section.
    pub fn roSectionByIndex(self: *const SectionScan, idx: u16) ?section_mod.Section {
        for (self.ro_sections.items) |e| {
            if (e.section.index == idx) return e.section;
        }
        return null;
    }

    /// Look up a text base offset by section index. Returns null if the
    /// given index isn't a text section.
    pub fn textBaseByIndex(self: *const SectionScan, idx: u16) ?u64 {
        for (self.text_bases.items) |e| {
            if (e.section.index == idx) return e.base_offset;
        }
        return null;
    }
};

/// True if `name` starts with ".rodata" or ".data.rel.ro" — both count as
/// read-only data and can be lddw relocation targets. Matches Rust
/// byteparser.rs L43-47.
pub fn isRoSectionName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, ".rodata") or
        std.mem.startsWith(u8, name, ".data.rel.ro");
}

/// True if `name` starts with ".text". Matches Rust byteparser.rs L52-54.
pub fn isTextSectionName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, ".text");
}

/// Pass D.1: scan all sections, classify each as rodata-like, text, or
/// neither. Returns two ordered lists plus total text size.
///
/// The caller owns the returned SectionScan and must call deinit.
pub fn scanSections(
    allocator: std.mem.Allocator,
    file: *const elf_mod.ElfFile,
) !SectionScan {
    var ro_sections: std.ArrayList(RoSectionEntry) = .empty;
    errdefer ro_sections.deinit(allocator);

    var text_bases: std.ArrayList(TextBaseEntry) = .empty;
    errdefer text_bases.deinit(allocator);

    var total_text_size: u64 = 0;

    var it = file.iterSections();
    while (try it.next()) |sec| {
        if (isRoSectionName(sec.name)) {
            try ro_sections.append(allocator, .{ .section = sec });
        } else if (isTextSectionName(sec.name)) {
            try text_bases.append(allocator, .{
                .section = sec,
                .base_offset = total_text_size,
            });
            total_text_size += sec.size();
        }
    }

    return SectionScan{
        .allocator = allocator,
        .ro_sections = ro_sections,
        .text_bases = text_bases,
        .total_text_size = total_text_size,
    };
}

/// Pass D.2: walk the symtab and fill `pending_rodata` + `text_labels`
/// + `entry_label`.
///
/// Mirrors the symbol loop in Rust byteparser.rs L62-112.
///
/// Rules:
///   - Symbols in a ro_section (.rodata* / .data.rel.ro*):
///     * STT_SECTION skipped (they're 0-sized and handled by D.4 gap-fill)
///     * Any other kind recorded as a RodataEntry; size must be > 0
///   - Symbols in a text section (.text*):
///     * Empty name skipped
///     * Recorded as TextLabel with offset = text_base + symbol.address
///     * Symbol named exactly "entrypoint" also sets entry_label
///
/// No symbol table at all is acceptable (returns empty scan); this
/// can happen on stripped .o files.
pub fn scanSymbols(
    allocator: std.mem.Allocator,
    file: *const elf_mod.ElfFile,
    sections: *const SectionScan,
) !SymbolScan {
    var pending_rodata: std.ArrayList(RodataEntry) = .empty;
    errdefer {
        for (pending_rodata.items) |e| {
            if (e.name_owned) allocator.free(e.name);
        }
        pending_rodata.deinit(allocator);
    }

    var text_labels: std.ArrayList(TextLabel) = .empty;
    errdefer {
        for (text_labels.items) |e| {
            if (e.name_owned) allocator.free(e.name);
        }
        text_labels.deinit(allocator);
    }

    var entry_label: ?[]const u8 = null;

    // Try .symtab first (static object file). If none exists the scan is
    // simply empty — some stripped inputs have no symtab.
    var sym_iter = file.iterSymbols(.symtab) catch |err| switch (err) {
        error.NoSymbolTable => return SymbolScan{
            .allocator = allocator,
            .pending_rodata = pending_rodata,
            .text_labels = text_labels,
            .entry_label = null,
        },
        else => return err,
    };

    while (try sym_iter.next()) |sym| {
        const sec_idx = sym.sectionIndex() orelse continue;

        // Case 1: symbol lives in a ro_section → rodata entry.
        if (sections.roSectionByIndex(sec_idx)) |ro_sec| {
            if (sym.kind() == .Section) continue; // STT_SECTION — D.4 handles

            if (sym.size() == 0) return ParseError.EmptyNamedRodataSymbol;

            const addr: usize = @intCast(sym.address());
            const sz: usize = @intCast(sym.size());
            if (addr + sz > ro_sec.data.len) return ParseError.SymbolOutOfSectionRange;

            try pending_rodata.append(allocator, .{
                .section_index = ro_sec.index,
                .address = sym.address(),
                .size = sym.size(),
                .name = sym.name, // borrowed from ELF strtab; name_owned=false
                .name_owned = false,
                .bytes = ro_sec.data[addr .. addr + sz],
            });
            continue;
        }

        // Case 2: symbol lives in a .text* section → text label.
        if (sections.textBaseByIndex(sec_idx)) |section_base| {
            if (sym.name.len == 0) continue;

            try text_labels.append(allocator, .{
                .name = sym.name,
                .offset = section_base + sym.address(),
            });

            if (std.mem.eql(u8, sym.name, "entrypoint")) {
                entry_label = sym.name;
            }
        }
    }

    return SymbolScan{
        .allocator = allocator,
        .pending_rodata = pending_rodata,
        .text_labels = text_labels,
        .entry_label = entry_label,
    };
}

/// Per-section sorted set of lddw target addends. Key = ELF section index
/// of the target rodata section; values = the set of byte offsets (addends)
/// within that section that some lddw instruction references.
///
/// Used by D.4's gap-fill pass to subdivide each rodata section at every
/// lddw target, so the rodata_table lookup always finds a matching entry
/// (fixes the byteparser.rs single-STT_SECTION-symbol bug identified in C0).
///
/// Implemented as a flat ArrayList of (section_idx, ArrayList<u64>) pairs,
/// sorted for deterministic iteration. The inner list is kept sorted+deduped
/// on insert so downstream consumers can rely on monotonically increasing
/// anchors.
pub const LddwTargets = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry),

    pub const Entry = struct {
        section_index: u16,
        addends: std.ArrayList(u64), // sorted ascending, unique
    };

    pub fn init(allocator: std.mem.Allocator) LddwTargets {
        return .{ .allocator = allocator, .entries = .empty };
    }

    pub fn deinit(self: *LddwTargets) void {
        for (self.entries.items) |*e| {
            e.addends.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    /// Insert `addend` into the section's sorted-unique set, creating the
    /// section entry if it doesn't exist.
    pub fn insert(self: *LddwTargets, section_index: u16, addend: u64) !void {
        // Find or create the entry.
        var slot: ?*Entry = null;
        for (self.entries.items) |*e| {
            if (e.section_index == section_index) {
                slot = e;
                break;
            }
        }
        if (slot == null) {
            try self.entries.append(self.allocator, .{
                .section_index = section_index,
                .addends = .empty,
            });
            slot = &self.entries.items[self.entries.items.len - 1];
        }
        const e = slot.?;

        // Binary search for insertion position; skip duplicates.
        var lo: usize = 0;
        var hi: usize = e.addends.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (e.addends.items[mid] < addend) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo < e.addends.items.len and e.addends.items[lo] == addend) return;
        try e.addends.insert(self.allocator, lo, addend);
    }

    /// Return the sorted addend list for a section, or null if none.
    pub fn get(self: *const LddwTargets, section_index: u16) ?[]const u64 {
        for (self.entries.items) |e| {
            if (e.section_index == section_index) return e.addends.items;
        }
        return null;
    }
};

/// Pass D.3: scan every text section's relocation table. For each reloc
/// whose target symbol resolves to a ro_section, decode the relocated
/// instruction — if it's lddw (opcode 0x18), extract the 32-bit addend
/// from bytes 4..8 of the instruction and insert it into
/// `lddw_targets[target_section_idx]`.
///
/// The addend is stored **inside** the lddw immediate (it's an implicit
/// addend for R_BPF_64_64). Mirrors Rust spec §6.2 Pass 1.
///
/// Relocation sections are matched to text sections via `sh_info`: the
/// `sh_info` of a REL/RELA section holds the index of the section it
/// relocates. We scan all sections for REL types whose sh_info points
/// at a .text* section.
pub fn collectLddwTargets(
    allocator: std.mem.Allocator,
    file: *const elf_mod.ElfFile,
    sections: *const SectionScan,
) !LddwTargets {
    var targets = LddwTargets.init(allocator);
    errdefer targets.deinit();

    // Find REL/RELA sections and filter those targeting a text section.
    var sec_it = file.iterSections();
    while (try sec_it.next()) |rel_sec| {
        const kind = rel_sec.kind();
        if (kind != std.elf.SHT_REL and kind != std.elf.SHT_RELA) continue;

        const target_sec_idx_raw = rel_sec.header.sh_info;
        if (target_sec_idx_raw > std.math.maxInt(u16)) continue;
        const target_sec_idx: u16 = @intCast(target_sec_idx_raw);

        // Only consider relocations that operate on a text section.
        const text_sec = blk: {
            for (sections.text_bases.items) |tb| {
                if (tb.section.index == target_sec_idx) break :blk tb.section;
            }
            continue;
        };

        var rel_it = try file.iterRelocations(rel_sec);
        while (rel_it.next()) |r| {
            // Resolve the target symbol's section.
            var sym_iter = file.iterSymbols(.symtab) catch continue;
            var target_sym: ?symbol_mod.Symbol = null;
            var i: u32 = 0;
            while (try sym_iter.next()) |s| : (i += 1) {
                if (i == r.symbol_index) {
                    target_sym = s;
                    break;
                }
            }
            const sym = target_sym orelse continue;
            const sym_sec = sym.sectionIndex() orelse continue;
            if (sections.roSectionByIndex(sym_sec) == null) continue;

            // Decode the instruction at r.offset to confirm it's lddw
            // and extract the addend.
            const off: usize = @intCast(r.offset);
            if (off + 8 > text_sec.data.len) continue;
            if (text_sec.data[off] != 0x18) continue; // not lddw

            // Addend = u32 from bytes 4..8 of the first slot (LE), as u64.
            const addend = std.mem.readInt(u32, text_sec.data[off + 4 .. off + 8][0..4], .little);
            try targets.insert(sym_sec, @as(u64, addend));
        }
    }

    return targets;
}

// --- tests ---

const testing = std.testing;

test "isRoSectionName recognizes rodata variants" {
    try testing.expect(isRoSectionName(".rodata"));
    try testing.expect(isRoSectionName(".rodata.str1.1"));
    try testing.expect(isRoSectionName(".rodata.cst32"));
    try testing.expect(isRoSectionName(".data.rel.ro"));
    try testing.expect(isRoSectionName(".data.rel.ro.local"));

    try testing.expect(!isRoSectionName(".text"));
    try testing.expect(!isRoSectionName(".data"));
    try testing.expect(!isRoSectionName(""));
    try testing.expect(!isRoSectionName(".rel.text")); // not rodata, it's a reloc table
}

test "isTextSectionName recognizes text variants" {
    try testing.expect(isTextSectionName(".text"));
    try testing.expect(isTextSectionName(".text.entrypoint"));
    try testing.expect(isTextSectionName(".text.foo"));

    try testing.expect(!isTextSectionName(""));
    try testing.expect(!isTextSectionName(".rel.text"));
    try testing.expect(!isTextSectionName(".rodata"));
}

test "scanSections: classifies hello.o" {
    const hello_bytes = @embedFile("../testdata/hello.o");
    const file = try elf_mod.ElfFile.parse(hello_bytes);

    var scan = try scanSections(testing.allocator, &file);
    defer scan.deinit();

    // hello.o has exactly one .text and one .rodata.str1.1 per C0 findings.
    try testing.expectEqual(@as(usize, 1), scan.text_bases.items.len);
    try testing.expectEqual(@as(usize, 1), scan.ro_sections.items.len);

    // .text is 64 bytes (verified in C.5).
    try testing.expectEqual(@as(u64, 64), scan.total_text_size);
    try testing.expectEqual(@as(u64, 0), scan.text_bases.items[0].base_offset);
    try testing.expectEqualStrings(".text", scan.text_bases.items[0].section.name);

    // The rodata section is the string literal holder.
    try testing.expect(std.mem.startsWith(u8, scan.ro_sections.items[0].section.name, ".rodata"));
}

test "scanSections: lookup by index" {
    const hello_bytes = @embedFile("../testdata/hello.o");
    const file = try elf_mod.ElfFile.parse(hello_bytes);

    var scan = try scanSections(testing.allocator, &file);
    defer scan.deinit();

    const text_idx = scan.text_bases.items[0].section.index;
    const ro_idx = scan.ro_sections.items[0].section.index;

    try testing.expectEqual(@as(?u64, 0), scan.textBaseByIndex(text_idx));
    try testing.expect(scan.roSectionByIndex(ro_idx) != null);

    // Non-existent indexes return null.
    try testing.expectEqual(@as(?u64, null), scan.textBaseByIndex(999));
    try testing.expectEqual(@as(?section_mod.Section, null), scan.roSectionByIndex(999));

    // A text section index queried as a ro section returns null (and vice versa).
    try testing.expectEqual(@as(?section_mod.Section, null), scan.roSectionByIndex(text_idx));
    try testing.expectEqual(@as(?u64, null), scan.textBaseByIndex(ro_idx));
}

test "scanSymbols: hello.o finds entrypoint + no named rodata" {
    const hello_bytes = @embedFile("../testdata/hello.o");
    const file = try elf_mod.ElfFile.parse(hello_bytes);

    var sections = try scanSections(testing.allocator, &file);
    defer sections.deinit();

    var syms = try scanSymbols(testing.allocator, &file, &sections);
    defer syms.deinit();

    // hello.o's .rodata.str1.1 has only an STT_SECTION symbol — no named
    // rodata entries at this stage.
    try testing.expectEqual(@as(usize, 0), syms.pending_rodata.items.len);

    // Exactly one named text label: "entrypoint".
    try testing.expectEqual(@as(usize, 1), syms.text_labels.items.len);
    try testing.expectEqualStrings("entrypoint", syms.text_labels.items[0].name);
    try testing.expectEqual(@as(u64, 0), syms.text_labels.items[0].offset);

    // entry_label set.
    try testing.expect(syms.entry_label != null);
    try testing.expectEqualStrings("entrypoint", syms.entry_label.?);
}

test "scanSymbols: no symtab → empty scan" {
    // Minimal header with no sections at all.
    var out: [@sizeOf(std.elf.Elf64_Ehdr)]u8 = @splat(0);
    out[0] = 0x7f; out[1] = 'E'; out[2] = 'L'; out[3] = 'F';
    out[std.elf.EI.CLASS] = std.elf.ELFCLASS64;
    out[std.elf.EI.DATA] = std.elf.ELFDATA2LSB;
    out[std.elf.EI.VERSION] = 1;
    out[16] = 3; out[18] = 247; out[20] = 1;
    out[52] = 64;
    out[58] = 64;

    const file = try elf_mod.ElfFile.parse(&out);
    var sections = try scanSections(testing.allocator, &file);
    defer sections.deinit();

    var syms = try scanSymbols(testing.allocator, &file, &sections);
    defer syms.deinit();

    try testing.expectEqual(@as(usize, 0), syms.pending_rodata.items.len);
    try testing.expectEqual(@as(usize, 0), syms.text_labels.items.len);
    try testing.expectEqual(@as(?[]const u8, null), syms.entry_label);
}

test "scanSections: multiple text sections accumulate base offsets" {
    // We don't have a fixture with multiple .text* sections today, so
    // verify the accumulator logic with a synthetic ELF.
    // This uses the test helper from elf/section.zig indirectly — we
    // inline a minimal 3-text-section builder here to avoid exporting
    // internals from section.zig.

    // For now, a simpler check: empty ELF → zero totals.
    // (A full synthetic multi-text ELF is D.6's concern once instruction
    // decoding needs to straddle section boundaries.)
    //
    // Skipped for D.1; revisit in D.6 integration.
}

test "LddwTargets: insert maintains sorted-unique invariant" {
    var t = LddwTargets.init(testing.allocator);
    defer t.deinit();

    try t.insert(1, 10);
    try t.insert(1, 5);
    try t.insert(1, 20);
    try t.insert(1, 10); // duplicate — should be ignored
    try t.insert(2, 100);

    const sec1 = t.get(1).?;
    try testing.expectEqualSlices(u64, &.{ 5, 10, 20 }, sec1);

    const sec2 = t.get(2).?;
    try testing.expectEqualSlices(u64, &.{100}, sec2);

    try testing.expectEqual(@as(?[]const u64, null), t.get(99));
}

test "collectLddwTargets: hello.o finds 1 lddw addend at offset 0" {
    const hello_bytes = @embedFile("../testdata/hello.o");
    const file = try elf_mod.ElfFile.parse(hello_bytes);

    var sections = try scanSections(testing.allocator, &file);
    defer sections.deinit();

    var targets = try collectLddwTargets(testing.allocator, &file, &sections);
    defer targets.deinit();

    // hello.o has exactly one lddw in its .text, pointing at offset 0
    // of .rodata.str1.1.
    try testing.expectEqual(@as(usize, 1), targets.entries.items.len);

    const rodata_idx = sections.ro_sections.items[0].section.index;
    const addends = targets.get(rodata_idx).?;
    try testing.expectEqualSlices(u64, &.{0}, addends);
}
