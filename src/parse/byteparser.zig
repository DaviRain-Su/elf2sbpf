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
const opcode_mod = @import("../common/opcode.zig");

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

        // Bind to the symbol table referenced by this relocation section.
        const symtab_idx_raw = rel_sec.header.sh_link;
        if (symtab_idx_raw > std.math.maxInt(u16)) continue;
        const symtab_idx: u16 = @intCast(symtab_idx_raw);

        // Pre-build symbol lookup for this relocation section's symtab.
        var sym_lookup = buildSymbolLookupAt(allocator, file, symtab_idx) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer sym_lookup.deinit(allocator);

        var rel_it = try file.iterRelocations(rel_sec);
        while (rel_it.next()) |r| {
            // Resolve target symbol via O(1) lookup.
            if (r.symbol_index >= sym_lookup.items.len) continue;
            const sym = sym_lookup.items[r.symbol_index];
            const sym_sec = sym.sectionIndex() orelse continue;
            if (sections.roSectionByIndex(sym_sec) == null) continue;

            // Decode the instruction at r.offset to confirm it's lddw
            // and extract the addend.
            const off: usize = @intCast(r.offset);
            if (off + 8 > text_sec.data.len) continue;
            if (text_sec.data[off] != 0x18) continue; // not lddw

            const addend: u64 = if (r.addend) |rela_addend| blk: {
                if (rela_addend < 0) continue;
                break :blk @intCast(rela_addend);
            } else @as(u64, std.mem.readInt(
                u32,
                text_sec.data[off + 4 .. off + 8][0..4],
                .little,
            ));
            try targets.insert(sym_sec, addend);
        }
    }

    return targets;
}

/// Pass D.4: improved rodata gap-fill. For each ro_section, build an
/// anchor set from:
///   • 0 and section size
///   • each named entry's [address, address+size] pair
///   • each lddw target addend (truncated to inside-the-section)
/// and synthesize an anon RodataEntry for every consecutive [start,end)
/// window not already owned by a named entry.
///
/// Spec §6.2 Pass 2+3. Naming matches Rust byteparser convention:
///     ".rodata.__anon_<section_idx_hex>_<offset_hex>"
///
/// Appends new entries into `syms.pending_rodata`. Entries created here
/// carry `name_owned=true` so `SymbolScan.deinit` will free them.
///
/// Returns error.LddwTargetInsideNamedEntry if a lddw target falls strictly
/// inside a named rodata symbol's range — this would require splitting a
/// user-declared symbol, which no sane compiler emits.
pub fn gapFillRodata(
    allocator: std.mem.Allocator,
    sections: *const SectionScan,
    targets: *const LddwTargets,
    syms: *SymbolScan,
) !void {
    for (sections.ro_sections.items) |ro_entry| {
        const ro_sec = ro_entry.section;
        const section_size = ro_sec.data.len;

        // Collect this section's named entries, sorted by address.
        var named: std.ArrayList(RodataEntry) = .empty;
        defer named.deinit(allocator);
        for (syms.pending_rodata.items) |e| {
            if (e.section_index == ro_sec.index) {
                try named.append(allocator, e);
            }
        }
        std.mem.sort(RodataEntry, named.items, {}, struct {
            fn lt(_: void, a: RodataEntry, b: RodataEntry) bool {
                return a.address < b.address;
            }
        }.lt);

        // Build the anchor set. Use an ArrayList + sort-dedupe for
        // determinism. Could be done with a BTreeSet equivalent but N
        // is small (section_size + few named + few addends).
        var anchors: std.ArrayList(u64) = .empty;
        defer anchors.deinit(allocator);

        try anchors.append(allocator, 0);
        try anchors.append(allocator, @intCast(section_size));

        for (named.items) |e| {
            try anchors.append(allocator, e.address);
            try anchors.append(allocator, e.address + e.size);
        }

        if (targets.get(ro_sec.index)) |addends| {
            for (addends) |t| {
                if (t < section_size) {
                    try anchors.append(allocator, t);
                }
            }
        }

        // Sort + dedupe.
        std.mem.sort(u64, anchors.items, {}, std.sort.asc(u64));
        var unique_end: usize = 0;
        {
            var idx: usize = 0;
            while (idx < anchors.items.len) : (idx += 1) {
                if (unique_end == 0 or anchors.items[idx] != anchors.items[unique_end - 1]) {
                    anchors.items[unique_end] = anchors.items[idx];
                    unique_end += 1;
                }
            }
        }
        const sorted_anchors = anchors.items[0..unique_end];

        // Sanity check: no lddw target falls strictly inside a named entry.
        if (targets.get(ro_sec.index)) |addends| {
            for (named.items) |e| {
                for (addends) |t| {
                    if (t > e.address and t < e.address + e.size) {
                        return error.LddwTargetInsideNamedEntry;
                    }
                }
            }
        }

        // Walk consecutive anchor pairs; emit anon entries for gaps.
        var w: usize = 0;
        while (w + 1 < sorted_anchors.len) : (w += 1) {
            const start = sorted_anchors[w];
            const end = sorted_anchors[w + 1];
            if (start >= end) continue;

            // Skip if a named entry starts at `start` — it already owns
            // this window.
            var named_owns = false;
            for (named.items) |e| {
                if (e.address == start) {
                    named_owns = true;
                    break;
                }
            }
            if (named_owns) continue;

            const start_usize: usize = @intCast(start);
            const end_usize: usize = @intCast(end);
            const slice = ro_sec.data[start_usize..end_usize];

            // Format anon name: ".rodata.__anon_<hex>_<hex>"
            const name_owned = try std.fmt.allocPrint(
                allocator,
                ".rodata.__anon_{x}_{x}",
                .{ ro_sec.index, start },
            );
            errdefer allocator.free(name_owned);

            try syms.pending_rodata.append(allocator, .{
                .section_index = ro_sec.index,
                .address = start,
                .size = end - start,
                .name = name_owned,
                .name_owned = true,
                .bytes = slice,
            });
        }
    }

    // After appending anons, sort the whole pending_rodata list by
    // (section_index, address) — downstream consumers (D.5 rodata_table)
    // expect this.
    std.mem.sort(RodataEntry, syms.pending_rodata.items, {}, struct {
        fn lt(_: void, a: RodataEntry, b: RodataEntry) bool {
            if (a.section_index != b.section_index) {
                return a.section_index < b.section_index;
            }
            return a.address < b.address;
        }
    }.lt);
}

/// Key used to look up a rodata entry by its original ELF location.
/// D.7 builds a lddw's `imm` label from this: given a relocation's
/// target (section, addend), find the entry whose (section_index,
/// address) matches and swap the imm for the entry's name.
pub const RodataKey = struct {
    section_index: u16,
    address: u64,
};

/// A (section, address) → entry lookup table built from the
/// final sorted pending_rodata list. Index into `entries_sorted`
/// is the entry's stable position; `keys_sorted` and `offsets_sorted`
/// are parallel arrays to avoid a hash map for small N.
///
/// Also carries each entry's assigned offset into the merged rodata
/// image (starts at 0 for the first entry, accumulates sizes). This
/// offset is what Program::from_parse_result consumes — it does NOT
/// include the text-size / PHDR adjustment that buildProgram applies
/// for V0 lddw resolution.
pub const RodataTable = struct {
    allocator: std.mem.Allocator,
    /// Parallel arrays; `keys_sorted[i]` describes the entry emitted
    /// at merged offset `offsets_sorted[i]` with name
    /// `names_sorted[i]`. Sorted by `section_index` then `address`.
    keys: std.ArrayList(RodataKey),
    /// Byte offset into the merged rodata image.
    offsets: std.ArrayList(u64),
    /// Entry name, borrowed if it originated from a named symbol
    /// (syms owns the backing storage), owned if it was synthesized
    /// by gap-fill (SymbolScan.deinit frees them).
    names: std.ArrayList([]const u8),
    /// Total size in bytes of the merged rodata image (== sum of all
    /// entry sizes == final rodata_offset after assignment).
    total_size: u64,

    pub fn deinit(self: *RodataTable) void {
        self.keys.deinit(self.allocator);
        self.offsets.deinit(self.allocator);
        self.names.deinit(self.allocator);
    }

    /// Binary search for the (section_index, address) key. Returns the
    /// index into parallel arrays, or null if not found.
    pub fn find(self: *const RodataTable, key: RodataKey) ?usize {
        var lo: usize = 0;
        var hi: usize = self.keys.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const k = self.keys.items[mid];
            if (k.section_index < key.section_index or
                (k.section_index == key.section_index and k.address < key.address))
            {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo < self.keys.items.len) {
            const k = self.keys.items[lo];
            if (k.section_index == key.section_index and k.address == key.address) {
                return lo;
            }
        }
        return null;
    }

    pub fn nameAt(self: *const RodataTable, idx: usize) []const u8 {
        return self.names.items[idx];
    }

    pub fn offsetAt(self: *const RodataTable, idx: usize) u64 {
        return self.offsets.items[idx];
    }
};

/// Pass D.5: consume the final sorted `pending_rodata` (after D.2 + D.4)
/// and produce a RodataTable with each entry's assigned merged offset +
/// a binary-searchable key index.
///
/// Mirrors Rust byteparser.rs L170-186:
///   let mut rodata_offset = 0u64;
///   for entry in pending_rodata {
///       ast.rodata_nodes.push(ASTNode::ROData { ... offset: rodata_offset });
///       rodata_table.insert((Some(section_idx), address), name);
///       rodata_offset += size;
///   }
pub fn buildRodataTable(
    allocator: std.mem.Allocator,
    syms: *const SymbolScan,
) !RodataTable {
    var keys: std.ArrayList(RodataKey) = .empty;
    errdefer keys.deinit(allocator);
    var offsets: std.ArrayList(u64) = .empty;
    errdefer offsets.deinit(allocator);
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);

    var rodata_offset: u64 = 0;
    for (syms.pending_rodata.items) |e| {
        try keys.append(allocator, .{ .section_index = e.section_index, .address = e.address });
        try offsets.append(allocator, rodata_offset);
        try names.append(allocator, e.name);
        rodata_offset += e.size;
    }

    return RodataTable{
        .allocator = allocator,
        .keys = keys,
        .offsets = offsets,
        .names = names,
        .total_size = rodata_offset,
    };
}

/// Errors from text-stream decoding (D.6).
pub const DecodeTextError = error{
    /// .text section size isn't a multiple of instruction size; a
    /// trailing fragment smaller than 8 bytes would indicate a
    /// truncated lddw or misaligned section.
    TextSectionMisaligned,
    /// An instruction decode failed — wraps InstructionDecodeError
    /// from common/instruction.zig.
    InstructionDecodeFailed,
    OutOfMemory,
};

/// A single decoded text instruction tagged with its absolute position
/// in the merged text image. Mirrors the ASTNode::Instruction variant
/// Rust byteparser emits at byteparser.rs L209-213.
pub const DecodedInstruction = struct {
    /// Byte offset within the **merged** .text image:
    /// `section_base + offset_within_section`.
    offset: u64,
    /// The decoded instruction. Owns no heap memory — strings and
    /// Number payloads are inline or reference the input bytes.
    instruction: instruction_mod.Instruction,
    /// Which ELF section index this instruction came from — used by
    /// D.7 to resolve relocation targets back to a per-section offset.
    source_section: u16,
};

/// Output of the text-decode pass (D.6).
pub const TextScan = struct {
    allocator: std.mem.Allocator,
    /// All decoded instructions in merged order. Sorted by `offset`
    /// by construction (we walk sections in ELF order with a running
    /// offset accumulator).
    instructions: std.ArrayList(DecodedInstruction),

    pub fn deinit(self: *TextScan) void {
        self.instructions.deinit(self.allocator);
    }
};

/// Pass D.6: decode every .text* section into a flat
/// `TextScan.instructions` list. Each instruction carries its
/// absolute offset in the merged text image.
///
/// Step sizes:
///   - lddw (opcode 0x18) consumes 16 bytes
///   - every other opcode consumes 8 bytes
///
/// Failures:
///   - Unknown opcode → `InstructionDecodeFailed`
///   - A section whose remaining bytes < required step → `TextSectionMisaligned`
///
/// Mirrors Rust byteparser.rs L197-215.
pub fn decodeTextSections(
    allocator: std.mem.Allocator,
    sections: *const SectionScan,
) DecodeTextError!TextScan {
    var instructions: std.ArrayList(DecodedInstruction) = .empty;
    errdefer instructions.deinit(allocator);

    for (sections.text_bases.items) |tb| {
        const data = tb.section.data;
        var off: usize = 0;
        while (off < data.len) {
            const remaining = data[off..];
            if (remaining.len < 8) {
                return DecodeTextError.TextSectionMisaligned;
            }
            const op = opcode_mod.Opcode.fromByte(remaining[0]) orelse
                return DecodeTextError.InstructionDecodeFailed;
            if (op == .Lddw and remaining.len < 16) {
                return DecodeTextError.TextSectionMisaligned;
            }
            const inst = instruction_mod.Instruction.fromBytes(remaining) catch
                return DecodeTextError.InstructionDecodeFailed;
            const size: usize = @intCast(inst.getSize());

            // Guard: section must contain at least one full instruction
            // from this offset. If not (e.g. a truncated lddw), surface
            // it as a misalignment.
            if (off + size > data.len) {
                return DecodeTextError.TextSectionMisaligned;
            }

            try instructions.append(allocator, .{
                .offset = tb.base_offset + @as(u64, off),
                .instruction = inst,
                .source_section = tb.section.index,
            });

            off += size;
        }
    }

    return TextScan{
        .allocator = allocator,
        .instructions = instructions,
    };
}

/// A single `.debug_*` section preserved as-is. Epic F's emitter copies
/// these verbatim into the output `.so`. Mirrors the DebugSection in
/// Rust sbpf-assembler::section (sbpf/crates/assembler/src/section.rs).
pub const DebugSectionEntry = struct {
    /// Borrowed section name from ELF shstrtab.
    name: []const u8,
    /// Borrowed raw section bytes.
    data: []const u8,
};

/// Output of pass D.8 (debug preservation).
pub const DebugScan = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(DebugSectionEntry),

    pub fn deinit(self: *DebugScan) void {
        self.entries.deinit(self.allocator);
    }
};

/// Pass D.8: collect every section whose name begins with `.debug_`.
/// The emitter in Epic F copies these unchanged into the output so
/// DWARF toolchains (llvm-dwarfdump, gdb, etc.) can attribute SBPF
/// offsets back to source.
///
/// Mirrors Rust byteparser.rs L282-291.
pub fn scanDebugSections(
    allocator: std.mem.Allocator,
    file: *const elf_mod.ElfFile,
) !DebugScan {
    var entries: std.ArrayList(DebugSectionEntry) = .empty;
    errdefer entries.deinit(allocator);

    var sec_it = file.iterSections();
    while (try sec_it.next()) |sec| {
        if (!std.mem.startsWith(u8, sec.name, ".debug_")) continue;
        try entries.append(allocator, .{ .name = sec.name, .data = sec.data });
    }

    return DebugScan{
        .allocator = allocator,
        .entries = entries,
    };
}

/// Aggregate result of the byteparser pipeline (D.1–D.8). Handed off to
/// Epic E's AST.buildProgram which turns this into the final ParseResult.
///
/// Owns all allocator-allocated state (syms, rodata_table names, text
/// instructions, debug entries). Call `deinit()` to free.
pub const ByteParseResult = struct {
    allocator: std.mem.Allocator,
    sections: SectionScan,
    syms: SymbolScan,
    rodata_table: RodataTable,
    text: TextScan,
    debug: DebugScan,
    /// Names owned by the rewrite pass, if any. Usually empty in C1 —
    /// Rust `.to_owned()`s some names; we reuse ELF strtab slices.
    owned_names: std.ArrayList([]const u8),

    pub fn deinit(self: *ByteParseResult) void {
        self.sections.deinit();
        self.syms.deinit();
        self.rodata_table.deinit();
        self.text.deinit();
        self.debug.deinit();
        for (self.owned_names.items) |n| self.allocator.free(n);
        self.owned_names.deinit(self.allocator);
    }
};

/// Top-level byteparser entry point. Runs passes D.1–D.8 end-to-end and
/// returns a `ByteParseResult` ready for Epic E's AST.buildProgram.
///
/// This is the D.9 integration. Caller owns the result and must call
/// `deinit()` to release allocations (pending_rodata anon names, the
/// 3 parallel ArrayLists in rodata_table, text instructions, etc.).
pub fn byteParse(
    allocator: std.mem.Allocator,
    file: *const elf_mod.ElfFile,
) !ByteParseResult {
    var sections = try scanSections(allocator, file);
    errdefer sections.deinit();

    var syms = try scanSymbols(allocator, file, &sections);
    errdefer syms.deinit();

    var targets = try collectLddwTargets(allocator, file, &sections);
    defer targets.deinit(); // transient — only needed during gap-fill

    try gapFillRodata(allocator, &sections, &targets, &syms);

    var rodata_table = try buildRodataTable(allocator, &syms);
    errdefer rodata_table.deinit();

    var text = try decodeTextSections(allocator, &sections);
    errdefer text.deinit();

    var owned_names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned_names.items) |n| allocator.free(n);
        owned_names.deinit(allocator);
    }

    try rewriteRelocations(
        allocator,
        file,
        &sections,
        &rodata_table,
        &text,
        &owned_names,
    );

    var debug = try scanDebugSections(allocator, file);
    errdefer debug.deinit();

    return ByteParseResult{
        .allocator = allocator,
        .sections = sections,
        .syms = syms,
        .rodata_table = rodata_table,
        .text = text,
        .debug = debug,
        .owned_names = owned_names,
    };
}

/// Errors from the relocation-rewrite pass (D.7).
pub const RewriteError = error{
    /// A lddw relocation's (section, addend) key doesn't match any entry
    /// in rodata_table. Means the compiler produced a relocation into
    /// a non-rodata section (a bug we can't recover from).
    LddwTargetOutsideRodata,
    /// A non-STT_SECTION call target symbol had an empty name.
    CallTargetUnresolvable,
    OutOfMemory,
};

/// Find the `DecodedInstruction` in `text_scan` whose absolute offset
/// matches `target`. Returns a mutable pointer so callers can rewrite
/// the instruction in place. Null if no match (shouldn't happen for
/// well-formed input — every relocation offset must correspond to a
/// decoded instruction).
fn findInstructionAtOffset(text_scan: *TextScan, target: u64) ?*DecodedInstruction {
    // Linear scan is fine: hello.o has 7 items; even counter.o has ~180.
    // If this ever shows up in a profile, switch to binary search.
    for (text_scan.instructions.items) |*inst| {
        if (inst.offset == target) return inst;
    }
    return null;
}

/// Build a lookup table from the symbol table at the given section index.
/// This respects each relocation section's `sh_link` binding instead of
/// doing a global .symtab/.dynsym fallback.
fn buildSymbolLookupAt(
    allocator: std.mem.Allocator,
    file: *const elf_mod.ElfFile,
    symtab_idx: u16,
) !std.ArrayList(symbol_mod.Symbol) {
    var table: std.ArrayList(symbol_mod.Symbol) = .empty;
    errdefer table.deinit(allocator);

    var sym_iter = try file.iterSymbolsAt(symtab_idx);
    while (sym_iter.next() catch null) |s| {
        // Ensure the table is large enough to index by s.index
        while (table.items.len <= s.index) {
            try table.append(allocator, undefined);
        }
        table.items[s.index] = s;
    }
    return table;
}

/// Pass D.7: walk every text relocation and rewrite the targeted
/// instruction's `imm` field from a numeric addend to a symbolic
/// `Either.left(name)` label. Later passes (Epic E's AST.buildProgram)
/// will resolve those names to final offsets.
///
/// Three cases, matching Rust byteparser.rs L216-280:
///
/// 1. **lddw + rodata target** — look up (target_section, addend)
///    in rodata_table. If found, replace imm with the entry's name.
///    If not found, return LddwTargetOutsideRodata.
///
/// 2. **call + STT_SECTION target** — rewrite imm only if a named
///    symbol exists at (target_section, current_imm). If found,
///    swap imm for its name; otherwise leave alone.
///
/// 3. **call + non-STT_SECTION target** — take the symbol's name
///    directly; replace imm with it. Empty-name triggers
///    CallTargetUnresolvable.
///
/// The `owned_call_names` list holds any strings we allocate for case 3
/// (Rust uses `.to_owned()`; Zig needs explicit ownership). Caller
/// frees these via `TextScan.deinit` once the rewritten names are
/// replaced with final offsets.
pub fn rewriteRelocations(
    allocator: std.mem.Allocator,
    file: *const elf_mod.ElfFile,
    sections: *const SectionScan,
    rodata_table: *const RodataTable,
    text_scan: *TextScan,
    owned_names: *std.ArrayList([]const u8),
) RewriteError!void {
    var sec_it = file.iterSections();
    while (sec_it.next() catch null) |rel_sec| {
        const kind = rel_sec.kind();
        if (kind != std.elf.SHT_REL and kind != std.elf.SHT_RELA) continue;

        // sh_info tells us which section this relocation table applies
        // to. Only text sections matter here.
        const info_raw = rel_sec.header.sh_info;
        if (info_raw > std.math.maxInt(u16)) continue;
        const target_sec_idx: u16 = @intCast(info_raw);
        const text_base = sections.textBaseByIndex(target_sec_idx) orelse continue;

        // Bind to the symbol table referenced by this relocation section.
        const symtab_idx_raw = rel_sec.header.sh_link;
        if (symtab_idx_raw > std.math.maxInt(u16)) continue;
        const symtab_idx: u16 = @intCast(symtab_idx_raw);

        // Pre-build symbol lookup for this relocation section's symtab.
        var sym_lookup = buildSymbolLookupAt(allocator, file, symtab_idx) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer sym_lookup.deinit(allocator);

        var rel_it = file.iterRelocations(rel_sec) catch continue;
        while (rel_it.next()) |r| {
            // Resolve target symbol via O(1) lookup.
            if (r.symbol_index >= sym_lookup.items.len) continue;
            const sym = sym_lookup.items[r.symbol_index];

            // Find the instruction being relocated, in merged coordinates.
            const abs_offset = text_base + r.offset;
            const dec = findInstructionAtOffset(text_scan, abs_offset) orelse continue;
            var inst = &dec.instruction;

            switch (inst.opcode) {
                .Lddw => {
                    const addend: u64 = if (r.addend) |rela_addend|
                        blk: {
                            if (rela_addend < 0) return RewriteError.LddwTargetOutsideRodata;
                            break :blk @intCast(rela_addend);
                        }
                    else
                        blk: {
                            if (inst.imm) |imm| switch (imm) {
                                .right => |n| break :blk @bitCast(n.toI64()),
                                else => break :blk 0,
                            };
                            break :blk 0;
                        };
                    const sym_sec = sym.sectionIndex() orelse continue;
                    const key: RodataKey = .{ .section_index = sym_sec, .address = addend };
                    const slot = rodata_table.find(key) orelse {
                        return RewriteError.LddwTargetOutsideRodata;
                    };
                    inst.imm = .{ .left = rodata_table.nameAt(slot) };
                },
                .Call => {
                    if (sym.kind() == .Section) {
                        // STT_SECTION: look for a named symbol at
                        // (target_section, current_imm_as_u64). If found,
                        // swap imm for its name; otherwise leave alone.
                        const current_addend: u64 = blk: {
                            if (inst.imm) |imm| switch (imm) {
                                .right => |n| break :blk @bitCast(n.toI64()),
                                else => break :blk 0,
                            };
                            break :blk 0;
                        };
                        const sym_sec = sym.sectionIndex() orelse continue;

                        var named_iter = file.iterSymbolsAt(symtab_idx) catch continue;
                        var found: ?[]const u8 = null;
                        while (named_iter.next() catch null) |s| {
                            const s_sec = s.sectionIndex() orelse continue;
                            if (s_sec == sym_sec and s.address() == current_addend and s.name.len > 0) {
                                found = s.name;
                                break;
                            }
                        }
                        if (found) |name| {
                            inst.imm = .{ .left = name };
                        }
                        // No named match: imm stays as numeric; emitter
                        // treats it as direct pc-relative.
                    } else {
                        if (sym.name.len == 0) return RewriteError.CallTargetUnresolvable;
                        // Name lives in ELF strtab slice — already borrowed,
                        // no copy needed. But track for future ownership
                        // symmetry if we ever need to outlive the ELF buffer.
                        _ = owned_names; // currently unused
                        inst.imm = .{ .left = sym.name };
                    }
                },
                else => {},
            }
        }
    }
}

// --- tests ---

const testing = std.testing;

fn makeMultiTextElf() [544]u8 {
    var out: [544]u8 = @splat(0);

    const shstrtab_off: usize = 479;
    const shstrtab =
        "\x00.text\x00.text.foo\x00.text.bar\x00.rodata\x00.shstrtab\x00";
    @memcpy(out[shstrtab_off .. shstrtab_off + shstrtab.len], shstrtab);

    out[0] = 0x7f; out[1] = 'E'; out[2] = 'L'; out[3] = 'F';
    out[std.elf.EI.CLASS] = std.elf.ELFCLASS64;
    out[std.elf.EI.DATA] = std.elf.ELFDATA2LSB;
    out[std.elf.EI.VERSION] = 1;
    out[16] = 3; out[18] = 247; out[20] = 1;
    std.mem.writeInt(u64, out[40..48], 64, .little);
    out[52] = 64;
    out[58] = 64;
    out[60] = 6;
    out[62] = 5;

    std.mem.writeInt(u32, out[128..132], 1, .little);
    std.mem.writeInt(u32, out[132..136], std.elf.SHT_PROGBITS, .little);
    std.mem.writeInt(u64, out[136..144], 0x6, .little);
    std.mem.writeInt(u64, out[152..160], 448, .little);
    std.mem.writeInt(u64, out[160..168], 8, .little);

    std.mem.writeInt(u32, out[192..196], 7, .little);
    std.mem.writeInt(u32, out[196..200], std.elf.SHT_PROGBITS, .little);
    std.mem.writeInt(u64, out[200..208], 0x6, .little);
    std.mem.writeInt(u64, out[216..224], 456, .little);
    std.mem.writeInt(u64, out[224..232], 16, .little);

    std.mem.writeInt(u32, out[256..260], 17, .little);
    std.mem.writeInt(u32, out[260..264], std.elf.SHT_PROGBITS, .little);
    std.mem.writeInt(u64, out[264..272], 0x6, .little);
    std.mem.writeInt(u64, out[280..288], 472, .little);
    std.mem.writeInt(u64, out[288..296], 4, .little);

    std.mem.writeInt(u32, out[320..324], 27, .little);
    std.mem.writeInt(u32, out[324..328], std.elf.SHT_PROGBITS, .little);
    std.mem.writeInt(u64, out[328..336], 0x2, .little);
    std.mem.writeInt(u64, out[344..352], 476, .little);
    std.mem.writeInt(u64, out[352..360], 3, .little);

    std.mem.writeInt(u32, out[384..388], 35, .little);
    std.mem.writeInt(u32, out[388..392], std.elf.SHT_STRTAB, .little);
    std.mem.writeInt(u64, out[408..416], shstrtab_off, .little);
    std.mem.writeInt(u64, out[416..424], shstrtab.len, .little);

    return out;
}

fn makeRelDynsymElf() [704]u8 {
    var out: [704]u8 = @splat(0);

    const shstrtab_off: usize = 608;
    const shstrtab =
        "\x00.text\x00.rodata\x00.dynstr\x00.dynsym\x00.rel.text\x00.shstrtab\x00";
    @memcpy(out[shstrtab_off .. shstrtab_off + shstrtab.len], shstrtab);

    out[0] = 0x7f; out[1] = 'E'; out[2] = 'L'; out[3] = 'F';
    out[std.elf.EI.CLASS] = std.elf.ELFCLASS64;
    out[std.elf.EI.DATA] = std.elf.ELFDATA2LSB;
    out[std.elf.EI.VERSION] = 1;
    out[16] = 3; out[18] = 247; out[20] = 1;
    std.mem.writeInt(u64, out[40..48], 64, .little);
    out[52] = 64;
    out[58] = 64;
    out[60] = 7;
    out[62] = 6;

    std.mem.writeInt(u32, out[128..132], 1, .little);
    std.mem.writeInt(u32, out[132..136], std.elf.SHT_PROGBITS, .little);
    std.mem.writeInt(u64, out[136..144], 0x6, .little);
    std.mem.writeInt(u64, out[152..160], 512, .little);
    std.mem.writeInt(u64, out[160..168], 8, .little);

    std.mem.writeInt(u32, out[192..196], 7, .little);
    std.mem.writeInt(u32, out[196..200], std.elf.SHT_PROGBITS, .little);
    std.mem.writeInt(u64, out[200..208], 0x2, .little);
    std.mem.writeInt(u64, out[216..224], 520, .little);
    std.mem.writeInt(u64, out[224..232], 16, .little);

    std.mem.writeInt(u32, out[256..260], 15, .little);
    std.mem.writeInt(u32, out[260..264], std.elf.SHT_STRTAB, .little);
    std.mem.writeInt(u64, out[280..288], 536, .little);
    std.mem.writeInt(u64, out[288..296], 5, .little);

    std.mem.writeInt(u32, out[320..324], 23, .little);
    std.mem.writeInt(u32, out[324..328], std.elf.SHT_DYNSYM, .little);
    std.mem.writeInt(u64, out[344..352], 544, .little);
    std.mem.writeInt(u64, out[352..360], 48, .little);
    std.mem.writeInt(u32, out[360..364], 3, .little);
    std.mem.writeInt(u64, out[376..384], @sizeOf(std.elf.Elf64_Sym), .little);

    std.mem.writeInt(u32, out[384..388], 31, .little);
    std.mem.writeInt(u32, out[388..392], std.elf.SHT_REL, .little);
    std.mem.writeInt(u64, out[408..416], 592, .little);
    std.mem.writeInt(u64, out[416..424], @sizeOf(std.elf.Elf64_Rel), .little);
    std.mem.writeInt(u32, out[424..428], 4, .little);
    std.mem.writeInt(u32, out[428..432], 1, .little);
    std.mem.writeInt(u64, out[440..448], @sizeOf(std.elf.Elf64_Rel), .little);

    std.mem.writeInt(u32, out[448..452], 41, .little);
    std.mem.writeInt(u32, out[452..456], std.elf.SHT_STRTAB, .little);
    std.mem.writeInt(u64, out[472..480], shstrtab_off, .little);
    std.mem.writeInt(u64, out[480..488], shstrtab.len, .little);

    out[512] = 0x18;
    std.mem.writeInt(u32, out[516..520], 3, .little);

    @memcpy(out[536..541], "\x00msg\x00");

    std.mem.writeInt(u32, out[568..572], 1, .little);
    out[572] = 0x11;
    std.mem.writeInt(u16, out[574..576], 2, .little);
    std.mem.writeInt(u64, out[584..592], 16, .little);

    std.mem.writeInt(u64, out[592..600], 0, .little);
    std.mem.writeInt(u64, out[600..608], (@as(u64, 1) << 32) | 1, .little);

    return out;
}

fn makeRelaLddwElf() [704]u8 {
    var out: [704]u8 = @splat(0);

    const shstrtab_off: usize = 616;
    const shstrtab =
        "\x00.text\x00.rodata\x00.strtab\x00.symtab\x00.rela.text\x00.shstrtab\x00";
    @memcpy(out[shstrtab_off .. shstrtab_off + shstrtab.len], shstrtab);

    out[0] = 0x7f; out[1] = 'E'; out[2] = 'L'; out[3] = 'F';
    out[std.elf.EI.CLASS] = std.elf.ELFCLASS64;
    out[std.elf.EI.DATA] = std.elf.ELFDATA2LSB;
    out[std.elf.EI.VERSION] = 1;
    out[16] = 3; out[18] = 247; out[20] = 1;
    std.mem.writeInt(u64, out[40..48], 64, .little);
    out[52] = 64;
    out[58] = 64;
    out[60] = 7;
    out[62] = 6;

    std.mem.writeInt(u32, out[128..132], 1, .little);
    std.mem.writeInt(u32, out[132..136], std.elf.SHT_PROGBITS, .little);
    std.mem.writeInt(u64, out[136..144], 0x6, .little);
    std.mem.writeInt(u64, out[152..160], 512, .little);
    std.mem.writeInt(u64, out[160..168], 8, .little);

    std.mem.writeInt(u32, out[192..196], 7, .little);
    std.mem.writeInt(u32, out[196..200], std.elf.SHT_PROGBITS, .little);
    std.mem.writeInt(u64, out[200..208], 0x2, .little);
    std.mem.writeInt(u64, out[216..224], 520, .little);
    std.mem.writeInt(u64, out[224..232], 16, .little);

    std.mem.writeInt(u32, out[256..260], 15, .little);
    std.mem.writeInt(u32, out[260..264], std.elf.SHT_STRTAB, .little);
    std.mem.writeInt(u64, out[280..288], 536, .little);
    std.mem.writeInt(u64, out[288..296], 5, .little);

    std.mem.writeInt(u32, out[320..324], 23, .little);
    std.mem.writeInt(u32, out[324..328], std.elf.SHT_SYMTAB, .little);
    std.mem.writeInt(u64, out[344..352], 544, .little);
    std.mem.writeInt(u64, out[352..360], 48, .little);
    std.mem.writeInt(u32, out[360..364], 3, .little);
    std.mem.writeInt(u64, out[376..384], @sizeOf(std.elf.Elf64_Sym), .little);

    std.mem.writeInt(u32, out[384..388], 31, .little);
    std.mem.writeInt(u32, out[388..392], std.elf.SHT_RELA, .little);
    std.mem.writeInt(u64, out[408..416], 592, .little);
    std.mem.writeInt(u64, out[416..424], @sizeOf(std.elf.Elf64_Rela), .little);
    std.mem.writeInt(u32, out[424..428], 4, .little);
    std.mem.writeInt(u32, out[428..432], 1, .little);
    std.mem.writeInt(u64, out[440..448], @sizeOf(std.elf.Elf64_Rela), .little);

    std.mem.writeInt(u32, out[448..452], 42, .little);
    std.mem.writeInt(u32, out[452..456], std.elf.SHT_STRTAB, .little);
    std.mem.writeInt(u64, out[472..480], shstrtab_off, .little);
    std.mem.writeInt(u64, out[480..488], shstrtab.len, .little);

    out[512] = 0x18;
    std.mem.writeInt(u32, out[516..520], 4, .little);

    @memcpy(out[536..541], "\x00msg\x00");

    std.mem.writeInt(u32, out[568..572], 1, .little);
    out[572] = 0x11;
    std.mem.writeInt(u16, out[574..576], 2, .little);
    std.mem.writeInt(u64, out[584..592], 16, .little);

    std.mem.writeInt(u64, out[592..600], 0, .little);
    std.mem.writeInt(u64, out[600..608], (@as(u64, 1) << 32) | 1, .little);
    std.mem.writeInt(i64, out[608..616], 9, .little);

    return out;
}

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
    out[0] = 0x7f;
    out[1] = 'E';
    out[2] = 'L';
    out[3] = 'F';
    out[std.elf.EI.CLASS] = std.elf.ELFCLASS64;
    out[std.elf.EI.DATA] = std.elf.ELFDATA2LSB;
    out[std.elf.EI.VERSION] = 1;
    out[16] = 3;
    out[18] = 247;
    out[20] = 1;
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
    const bytes = makeMultiTextElf();
    const file = try elf_mod.ElfFile.parse(&bytes);

    var scan = try scanSections(testing.allocator, &file);
    defer scan.deinit();

    try testing.expectEqual(@as(usize, 3), scan.text_bases.items.len);
    try testing.expectEqual(@as(u64, 28), scan.total_text_size);
    try testing.expectEqual(@as(u64, 0), scan.text_bases.items[0].base_offset);
    try testing.expectEqual(@as(u64, 8), scan.text_bases.items[1].base_offset);
    try testing.expectEqual(@as(u64, 24), scan.text_bases.items[2].base_offset);
    try testing.expectEqualStrings(".text", scan.text_bases.items[0].section.name);
    try testing.expectEqualStrings(".text.foo", scan.text_bases.items[1].section.name);
    try testing.expectEqualStrings(".text.bar", scan.text_bases.items[2].section.name);
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
    const addends_opt = targets.get(rodata_idx);
    try testing.expect(addends_opt != null);
    if (addends_opt) |addends| {
        try testing.expectEqualSlices(u64, &.{0}, addends);
    }
}

test "collectLddwTargets: follows relocation-linked dynsym table" {
    const bytes = makeRelDynsymElf();
    const file = try elf_mod.ElfFile.parse(&bytes);

    var sections = try scanSections(testing.allocator, &file);
    defer sections.deinit();

    var targets = try collectLddwTargets(testing.allocator, &file, &sections);
    defer targets.deinit();

    const rodata_idx = sections.ro_sections.items[0].section.index;
    const addends_opt = targets.get(rodata_idx);
    try testing.expect(addends_opt != null);
    if (addends_opt) |addends| {
        try testing.expectEqualSlices(u64, &.{3}, addends);
    }
}

test "collectLddwTargets: uses explicit RELA addend for lddw targets" {
    const bytes = makeRelaLddwElf();
    const file = try elf_mod.ElfFile.parse(&bytes);

    var sections = try scanSections(testing.allocator, &file);
    defer sections.deinit();

    var targets = try collectLddwTargets(testing.allocator, &file, &sections);
    defer targets.deinit();

    const rodata_idx = sections.ro_sections.items[0].section.index;
    const addends_opt = targets.get(rodata_idx);
    try testing.expect(addends_opt != null);
    if (addends_opt) |addends| {
        try testing.expectEqualSlices(u64, &.{9}, addends);
    }
}

test "gapFillRodata: hello.o synthesizes 1 anon entry covering the whole rodata" {
    const hello_bytes = @embedFile("../testdata/hello.o");
    const file = try elf_mod.ElfFile.parse(hello_bytes);

    var sections = try scanSections(testing.allocator, &file);
    defer sections.deinit();
    var syms = try scanSymbols(testing.allocator, &file, &sections);
    defer syms.deinit();
    var targets = try collectLddwTargets(testing.allocator, &file, &sections);
    defer targets.deinit();

    try testing.expectEqual(@as(usize, 0), syms.pending_rodata.items.len);

    try gapFillRodata(testing.allocator, &sections, &targets, &syms);

    // After gap-fill: one anon entry for the [0, rodata_size) range.
    // hello.o's .rodata.str1.1 is 0x17 = 23 bytes ("Hello from Zignocchio!\0")
    try testing.expectEqual(@as(usize, 1), syms.pending_rodata.items.len);
    const e = syms.pending_rodata.items[0];
    try testing.expectEqual(@as(u64, 0), e.address);
    try testing.expectEqual(@as(u64, 23), e.size);
    try testing.expect(e.name_owned);
    try testing.expect(std.mem.startsWith(u8, e.name, ".rodata.__anon_"));
    try testing.expectEqual(@as(usize, 23), e.bytes.len);
    try testing.expectEqual(@as(u8, 'H'), e.bytes[0]);
}

test "gapFillRodata: anchor subdivision with multiple lddw targets" {
    // Synthesize a scenario without a real ELF: empty named set,
    // rodata of 30 bytes, lddw targets at offsets 0, 8, 16.
    // Expected: 3 anon entries covering [0,8), [8,16), [16,30).
    const fake_data = "Hello world! zignocchio rodata"; // 30 bytes
    try testing.expectEqual(@as(usize, 30), fake_data.len);

    // Build a minimal SectionScan with one fake rodata section.
    var scan: SectionScan = .{
        .allocator = testing.allocator,
        .ro_sections = .empty,
        .text_bases = .empty,
        .total_text_size = 0,
    };
    defer scan.deinit();

    // Fake Section — only `index`, `name`, `data`, and `header.sh_size` matter
    // to gap-fill. `header` is otherwise ignored.
    var fake_hdr: std.elf.Elf64_Shdr = undefined;
    @memset(std.mem.asBytes(&fake_hdr), 0);
    fake_hdr.sh_size = 30;

    try scan.ro_sections.append(testing.allocator, .{
        .section = .{
            .index = 5,
            .header = fake_hdr,
            .name = ".rodata",
            .data = fake_data,
        },
    });

    var targets = LddwTargets.init(testing.allocator);
    defer targets.deinit();
    try targets.insert(5, 0);
    try targets.insert(5, 8);
    try targets.insert(5, 16);

    var syms: SymbolScan = .{
        .allocator = testing.allocator,
        .pending_rodata = .empty,
        .text_labels = .empty,
        .entry_label = null,
    };
    defer syms.deinit();

    try gapFillRodata(testing.allocator, &scan, &targets, &syms);

    try testing.expectEqual(@as(usize, 3), syms.pending_rodata.items.len);
    try testing.expectEqual(@as(u64, 0), syms.pending_rodata.items[0].address);
    try testing.expectEqual(@as(u64, 8), syms.pending_rodata.items[0].size);
    try testing.expectEqual(@as(u64, 8), syms.pending_rodata.items[1].address);
    try testing.expectEqual(@as(u64, 8), syms.pending_rodata.items[1].size);
    try testing.expectEqual(@as(u64, 16), syms.pending_rodata.items[2].address);
    try testing.expectEqual(@as(u64, 14), syms.pending_rodata.items[2].size);
}

test "buildRodataTable: hello.o produces 1 entry at offset 0" {
    const hello_bytes = @embedFile("../testdata/hello.o");
    const file = try elf_mod.ElfFile.parse(hello_bytes);

    var sections = try scanSections(testing.allocator, &file);
    defer sections.deinit();
    var syms = try scanSymbols(testing.allocator, &file, &sections);
    defer syms.deinit();
    var targets = try collectLddwTargets(testing.allocator, &file, &sections);
    defer targets.deinit();
    try gapFillRodata(testing.allocator, &sections, &targets, &syms);

    var table = try buildRodataTable(testing.allocator, &syms);
    defer table.deinit();

    try testing.expectEqual(@as(usize, 1), table.keys.items.len);
    try testing.expectEqual(@as(u64, 0), table.offsets.items[0]);
    try testing.expectEqual(@as(u64, 23), table.total_size);

    const ro_idx = sections.ro_sections.items[0].section.index;
    const slot = table.find(.{ .section_index = ro_idx, .address = 0 }).?;
    try testing.expectEqual(@as(usize, 0), slot);
    try testing.expect(std.mem.startsWith(u8, table.nameAt(slot), ".rodata.__anon_"));
}

test "buildRodataTable: 3 split entries get offsets 0/8/16" {
    // Reuse D.4's 3-entry scenario to validate offset accumulation.
    const fake_data = "Hello world! zignocchio rodata"; // 30 bytes

    var scan: SectionScan = .{
        .allocator = testing.allocator,
        .ro_sections = .empty,
        .text_bases = .empty,
        .total_text_size = 0,
    };
    defer scan.deinit();

    var fake_hdr: std.elf.Elf64_Shdr = undefined;
    @memset(std.mem.asBytes(&fake_hdr), 0);
    fake_hdr.sh_size = 30;
    try scan.ro_sections.append(testing.allocator, .{
        .section = .{
            .index = 5,
            .header = fake_hdr,
            .name = ".rodata",
            .data = fake_data,
        },
    });

    var targets = LddwTargets.init(testing.allocator);
    defer targets.deinit();
    try targets.insert(5, 0);
    try targets.insert(5, 8);
    try targets.insert(5, 16);

    var syms: SymbolScan = .{
        .allocator = testing.allocator,
        .pending_rodata = .empty,
        .text_labels = .empty,
        .entry_label = null,
    };
    defer syms.deinit();

    try gapFillRodata(testing.allocator, &scan, &targets, &syms);
    try testing.expectEqual(@as(usize, 3), syms.pending_rodata.items.len);

    var table = try buildRodataTable(testing.allocator, &syms);
    defer table.deinit();

    try testing.expectEqual(@as(usize, 3), table.keys.items.len);
    // Offsets are cumulative: 0, then 0+8=8, then 8+8=16.
    try testing.expectEqual(@as(u64, 0), table.offsetAt(0));
    try testing.expectEqual(@as(u64, 8), table.offsetAt(1));
    try testing.expectEqual(@as(u64, 16), table.offsetAt(2));
    try testing.expectEqual(@as(u64, 30), table.total_size);

    // find() returns the right slot for each addend.
    try testing.expectEqual(@as(?usize, 0), table.find(.{ .section_index = 5, .address = 0 }));
    try testing.expectEqual(@as(?usize, 1), table.find(.{ .section_index = 5, .address = 8 }));
    try testing.expectEqual(@as(?usize, 2), table.find(.{ .section_index = 5, .address = 16 }));

    // Non-existent key returns null.
    try testing.expectEqual(@as(?usize, null), table.find(.{ .section_index = 5, .address = 4 }));
    try testing.expectEqual(@as(?usize, null), table.find(.{ .section_index = 99, .address = 0 }));
}

test "gapFillRodata: rejects lddw target inside a named entry" {
    var scan: SectionScan = .{
        .allocator = testing.allocator,
        .ro_sections = .empty,
        .text_bases = .empty,
        .total_text_size = 0,
    };
    defer scan.deinit();

    var fake_hdr: std.elf.Elf64_Shdr = undefined;
    @memset(std.mem.asBytes(&fake_hdr), 0);
    fake_hdr.sh_size = 20;

    const fake_data = "01234567890123456789";
    try scan.ro_sections.append(testing.allocator, .{
        .section = .{
            .index = 5,
            .header = fake_hdr,
            .name = ".rodata",
            .data = fake_data,
        },
    });

    var targets = LddwTargets.init(testing.allocator);
    defer targets.deinit();
    // A lddw target at offset 5 — falls strictly inside the named entry
    // at [0, 10).
    try targets.insert(5, 5);

    var syms: SymbolScan = .{
        .allocator = testing.allocator,
        .pending_rodata = .empty,
        .text_labels = .empty,
        .entry_label = null,
    };
    defer syms.deinit();

    try syms.pending_rodata.append(testing.allocator, .{
        .section_index = 5,
        .address = 0,
        .size = 10,
        .name = "EXPECTED",
        .name_owned = false,
        .bytes = fake_data[0..10],
    });

    try testing.expectError(
        error.LddwTargetInsideNamedEntry,
        gapFillRodata(testing.allocator, &scan, &targets, &syms),
    );
}

test "decodeTextSections: hello.o yields 7 instructions with correct offsets" {
    const hello_bytes = @embedFile("../testdata/hello.o");
    const file = try elf_mod.ElfFile.parse(hello_bytes);

    var sections = try scanSections(testing.allocator, &file);
    defer sections.deinit();

    var text_scan = try decodeTextSections(testing.allocator, &sections);
    defer text_scan.deinit();

    // hello.o has 7 instructions totaling 64 bytes (1 lddw + 6 regular).
    try testing.expectEqual(@as(usize, 7), text_scan.instructions.items.len);

    // First instruction: r1 = *(u64 *)(r1 + 0x0)  — Ldxdw
    const ins0 = text_scan.instructions.items[0];
    try testing.expectEqual(@as(u64, 0), ins0.offset);
    try testing.expectEqual(opcode_mod.Opcode.Ldxdw, ins0.instruction.opcode);

    // Third instruction: lddw r1, 0x0  (16-byte wide)
    const ins2 = text_scan.instructions.items[2];
    try testing.expectEqual(@as(u64, 16), ins2.offset);
    try testing.expectEqual(opcode_mod.Opcode.Lddw, ins2.instruction.opcode);
    try testing.expectEqual(@as(u64, 16), ins2.instruction.getSize());

    // Next instruction after lddw sits at offset 32 (16 + 16), not 24.
    const ins3 = text_scan.instructions.items[3];
    try testing.expectEqual(@as(u64, 32), ins3.offset);
    try testing.expectEqual(opcode_mod.Opcode.Mov64Imm, ins3.instruction.opcode);

    // Final instruction: exit at offset 56.
    const ins6 = text_scan.instructions.items[6];
    try testing.expectEqual(@as(u64, 56), ins6.offset);
    try testing.expectEqual(opcode_mod.Opcode.Exit, ins6.instruction.opcode);
}

test "scanDebugSections: hello.o has no .debug_* sections" {
    const hello_bytes = @embedFile("../testdata/hello.o");
    const file = try elf_mod.ElfFile.parse(hello_bytes);

    var debug = try scanDebugSections(testing.allocator, &file);
    defer debug.deinit();

    // hello.o was built with -O ReleaseSmall and no debug info.
    try testing.expectEqual(@as(usize, 0), debug.entries.items.len);
}

test "byteParse: hello.o end-to-end produces fully populated result" {
    const hello_bytes = @embedFile("../testdata/hello.o");
    const file = try elf_mod.ElfFile.parse(hello_bytes);

    var result = try byteParse(testing.allocator, &file);
    defer result.deinit();

    // Sections: 1 text, 1 rodata.
    try testing.expectEqual(@as(usize, 1), result.sections.text_bases.items.len);
    try testing.expectEqual(@as(usize, 1), result.sections.ro_sections.items.len);
    try testing.expectEqual(@as(u64, 64), result.sections.total_text_size);

    // Symbols: entrypoint label + gap-fill anon rodata.
    try testing.expectEqual(@as(usize, 1), result.syms.text_labels.items.len);
    try testing.expectEqualStrings("entrypoint", result.syms.text_labels.items[0].name);
    try testing.expect(result.syms.entry_label != null);

    try testing.expectEqual(@as(usize, 1), result.syms.pending_rodata.items.len);
    try testing.expect(result.syms.pending_rodata.items[0].name_owned);

    // Rodata table: 1 entry at offset 0.
    try testing.expectEqual(@as(usize, 1), result.rodata_table.keys.items.len);
    try testing.expectEqual(@as(u64, 23), result.rodata_table.total_size);

    // Text: 7 decoded instructions.
    try testing.expectEqual(@as(usize, 7), result.text.instructions.items.len);

    // Relocation rewrite applied: lddw at offset 16 has imm = .left(name).
    const lddw = result.text.instructions.items[2];
    try testing.expectEqual(opcode_mod.Opcode.Lddw, lddw.instruction.opcode);
    switch (lddw.instruction.imm.?) {
        .left => |name| try testing.expect(std.mem.startsWith(u8, name, ".rodata.__anon_")),
        .right => return error.TestExpectedLeftVariant,
    }

    // No debug sections (RELEASE_SMALL build strips them).
    try testing.expectEqual(@as(usize, 0), result.debug.entries.items.len);
}

test "rewriteRelocations: hello.o lddw gets rodata label" {
    const hello_bytes = @embedFile("../testdata/hello.o");
    const file = try elf_mod.ElfFile.parse(hello_bytes);

    var sections = try scanSections(testing.allocator, &file);
    defer sections.deinit();
    var syms = try scanSymbols(testing.allocator, &file, &sections);
    defer syms.deinit();
    var targets = try collectLddwTargets(testing.allocator, &file, &sections);
    defer targets.deinit();
    try gapFillRodata(testing.allocator, &sections, &targets, &syms);
    var table = try buildRodataTable(testing.allocator, &syms);
    defer table.deinit();
    var text_scan = try decodeTextSections(testing.allocator, &sections);
    defer text_scan.deinit();

    var owned_names: std.ArrayList([]const u8) = .empty;
    defer owned_names.deinit(testing.allocator);

    try rewriteRelocations(
        testing.allocator,
        &file,
        &sections,
        &table,
        &text_scan,
        &owned_names,
    );

    // The lddw at offset 16 should now carry a .left(name) imm pointing
    // at the rodata label.
    const lddw = text_scan.instructions.items[2];
    try testing.expectEqual(opcode_mod.Opcode.Lddw, lddw.instruction.opcode);
    const imm = lddw.instruction.imm orelse return error.TestExpectedImm;
    switch (imm) {
        .left => |name| {
            try testing.expect(std.mem.startsWith(u8, name, ".rodata.__anon_"));
        },
        .right => return error.TestExpectedLeftVariant,
    }
}

test "rewriteRelocations: RELA lddw uses explicit addend for rodata lookup" {
    const bytes = makeRelaLddwElf();
    const file = try elf_mod.ElfFile.parse(&bytes);

    var sections = try scanSections(testing.allocator, &file);
    defer sections.deinit();
    var table = RodataTable{
        .allocator = testing.allocator,
        .keys = .empty,
        .offsets = .empty,
        .names = .empty,
        .total_size = 16,
    };
    defer table.deinit();
    const rodata_idx = sections.ro_sections.items[0].section.index;
    try table.keys.append(testing.allocator, .{ .section_index = rodata_idx, .address = 9 });
    try table.offsets.append(testing.allocator, 0);
    try table.names.append(testing.allocator, "msg");
    var text_scan = try decodeTextSections(testing.allocator, &sections);
    defer text_scan.deinit();

    var owned_names: std.ArrayList([]const u8) = .empty;
    defer owned_names.deinit(testing.allocator);

    try rewriteRelocations(
        testing.allocator,
        &file,
        &sections,
        &table,
        &text_scan,
        &owned_names,
    );

    const lddw = text_scan.instructions.items[0];
    const imm = lddw.instruction.imm orelse return error.TestExpectedImm;
    switch (imm) {
        .left => |name| try testing.expect(std.mem.startsWith(u8, name, "msg")),
        .right => return error.TestExpectedLeftVariant,
    }
}

test "decodeTextSections: empty text section yields empty result" {
    // Minimal ELF with no sections — no text, no instructions.
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

    var text_scan = try decodeTextSections(testing.allocator, &sections);
    defer text_scan.deinit();

    try testing.expectEqual(@as(usize, 0), text_scan.instructions.items.len);
}

test "decodeTextSections: truncated lddw tail is misaligned" {
    var scan: SectionScan = .{
        .allocator = testing.allocator,
        .ro_sections = .empty,
        .text_bases = .empty,
        .total_text_size = 8,
    };
    defer scan.deinit();

    var fake_hdr: std.elf.Elf64_Shdr = undefined;
    @memset(std.mem.asBytes(&fake_hdr), 0);
    fake_hdr.sh_size = 8;

    const truncated_lddw = [_]u8{ 0x18, 0, 0, 0, 0, 0, 0, 0 };
    try scan.text_bases.append(testing.allocator, .{
        .section = .{
            .index = 1,
            .header = fake_hdr,
            .name = ".text",
            .data = &truncated_lddw,
        },
        .base_offset = 0,
    });

    try testing.expectError(
        DecodeTextError.TextSectionMisaligned,
        decodeTextSections(testing.allocator, &scan),
    );
}
