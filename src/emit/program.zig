// Program — the final assembler between ParseResult and the raw .so bytes.
//
// Port of Rust sbpf-assembler::program. Layout matches the Rust impl one-for-one:
//
//   Epic G.1 — Program struct + allocator-owned sections/names storage (done)
//   Epic G.2 — `fromParseResult` builder (this file): walk the ParseResult and
//               append section instances in the correct order for V3 / V0
//               dynamic / V0 static; also lay out offsets as we go
//   Epic G.3 — finalize e_shoff padding + sh_link fixups + program_headers
//   Epic G.4 — `emitBytecode`: serialize ELF header + program headers +
//               section contents + section header table, byte-for-byte
//               matching the reference-shim output
//
// Spec: 03-technical-spec.md §6 (ELF output contract)
// Tests: 05-test-spec.md §4.10

const std = @import("std");
const ast_mod = @import("../ast/ast.zig");
const header_mod = @import("header.zig");
const section_mod = @import("section_types.zig");

pub const ElfHeader = header_mod.ElfHeader;
pub const ProgramHeader = header_mod.ProgramHeader;
pub const SectionType = section_mod.SectionType;

pub const ParseResult = ast_mod.ParseResult;
pub const SbpfArch = ast_mod.SbpfArch;
pub const RelocationType = ast_mod.RelocationType;

/// Assembled .so image, not yet serialized.
///
/// Ownership:
///   - `sections` / `program_headers` / `section_names` are owned
///     (ArrayList) and freed by `deinit`.
///   - `dyn_syms_storage` / `rel_dyns_storage` / `symbol_names_storage`
///     are builder-side arenas backing the `.dynsym` / `.rel.dyn` /
///     `.dynstr` section entries. Owned by Program, freed by `deinit`.
///   - Individual SectionType variants may borrow:
///       * CodeSection.nodes / DataSection.nodes ← ParseResult ASTNode lists
///       * DebugSection.data / name ← ParseResult.debug_sections slice
///       * DynSymSection.entries ← self.dyn_syms_storage.items
///       * RelDynSection.entries ← self.rel_dyns_storage.items
///       * DynStrSection.symbol_names ← self.symbol_names_storage.items
///     Callers MUST keep the ParseResult alive as long as the Program is
///     live. `fromParseResult` takes a pointer to ParseResult (not an owned
///     value) to make this contract explicit.
pub const Program = struct {
    elf_header: ElfHeader,
    program_headers: std.ArrayList(ProgramHeader),
    sections: std.ArrayList(SectionType),
    section_names: std.ArrayList([]const u8),

    dyn_syms_storage: std.ArrayList(section_mod.DynSymEntry),
    rel_dyns_storage: std.ArrayList(section_mod.RelDynEntry),
    symbol_names_storage: std.ArrayList([]const u8),

    pub fn init() Program {
        return .{
            .elf_header = ElfHeader.init(),
            .program_headers = .empty,
            .sections = .empty,
            .section_names = .empty,
            .dyn_syms_storage = .empty,
            .rel_dyns_storage = .empty,
            .symbol_names_storage = .empty,
        };
    }

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        self.program_headers.deinit(allocator);
        self.sections.deinit(allocator);
        self.section_names.deinit(allocator);
        self.dyn_syms_storage.deinit(allocator);
        self.rel_dyns_storage.deinit(allocator);
        self.symbol_names_storage.deinit(allocator);
    }

    pub fn sectionCount(self: Program) u16 {
        return @intCast(self.sections.items.len);
    }

    pub fn programHeaderCount(self: Program) u16 {
        return @intCast(self.program_headers.items.len);
    }

    pub fn hasRodata(self: Program) bool {
        for (self.sections.items) |s| {
            if (s == .data) return true;
        }
        return false;
    }

    pub fn appendSection(
        self: *Program,
        allocator: std.mem.Allocator,
        section: SectionType,
    ) !void {
        try self.sections.append(allocator, section);
    }

    pub fn appendProgramHeader(
        self: *Program,
        allocator: std.mem.Allocator,
        ph: ProgramHeader,
    ) !void {
        try self.program_headers.append(allocator, ph);
    }

    pub fn reserveSectionNames(
        self: *Program,
        allocator: std.mem.Allocator,
        n: usize,
    ) !void {
        try self.section_names.ensureTotalCapacity(allocator, n);
    }

    // -----------------------------------------------------------------------
    // fromParseResult — main builder
    // -----------------------------------------------------------------------

    pub const BuildError = std.mem.Allocator.Error || error{
        SyscallSymbolNotFound,
    };

    /// Build a fully-laid-out Program from a ParseResult.
    ///
    /// `pr` is borrowed — the returned Program references:
    ///   - `pr.code_section.nodes` / `pr.data_section.nodes`
    ///   - `pr.dynamic_symbols.entries[i].name`
    ///   - `pr.debug_sections[i].name` / `.data`
    ///
    /// ...so the caller must keep `pr` alive for the lifetime of the
    /// returned Program (or until emitBytecode has completed).
    pub fn fromParseResult(
        allocator: std.mem.Allocator,
        pr: *const ParseResult,
    ) BuildError!Program {
        var self = Program.init();
        errdefer self.deinit(allocator);

        const arch = pr.arch;
        const bytecode_size = pr.code_section.size;
        const rodata_size = pr.data_section.size;
        const has_rodata = rodata_size > 0;

        const ph_count: u16 = blk: {
            if (arch == .V3) {
                break :blk if (has_rodata) 2 else 1;
            } else if (pr.prog_is_static) {
                break :blk 0;
            } else {
                break :blk 3;
            }
        };

        self.elf_header.e_flags = eFlagsFor(arch);
        self.elf_header.e_phnum = ph_count;

        const base_offset: u64 = @as(u64, header_mod.ELF64_HEADER_SIZE) +
            @as(u64, ph_count) * @as(u64, header_mod.PROGRAM_HEADER_SIZE);
        var current_offset: u64 = base_offset;

        const text_offset: u64 = if (arch == .V3 and has_rodata)
            rodata_size + base_offset
        else
            base_offset;

        const entry_point_offset: u64 = firstEntryPointOffset(pr);

        self.elf_header.e_entry = if (arch == .V3)
            header_mod.V3_BYTECODE_VADDR + entry_point_offset
        else
            text_offset + entry_point_offset;

        // --- section list: [Null, Code, (Data?), ...]
        try self.appendSection(allocator, .{ .null_ = section_mod.NullSection.init() });

        if (arch == .V3 and has_rodata) {
            // V3 with rodata: rodata FIRST (vaddr 0), then code (vaddr 1<<32).
            var data_section = section_mod.DataSection{
                .nodes = pr.data_section.nodes.items,
                .size = rodata_size,
            };
            data_section.setNameOffset(@as(u32, @intCast(1 + cumulativeNameLen(self.section_names.items))));
            try self.section_names.append(allocator, ".rodata");
            data_section.setOffset(current_offset);
            current_offset += data_section.alignedSize();
            try self.appendSection(allocator, .{ .data = data_section });

            var code_section = section_mod.CodeSection{
                .nodes = pr.code_section.nodes.items,
                .size = bytecode_size,
            };
            code_section.setNameOffset(@as(u32, @intCast(1 + cumulativeNameLen(self.section_names.items))));
            try self.section_names.append(allocator, ".text");
            code_section.setOffset(current_offset);
            current_offset += code_section.size;
            try self.appendSection(allocator, .{ .code = code_section });
        } else {
            var code_section = section_mod.CodeSection{
                .nodes = pr.code_section.nodes.items,
                .size = bytecode_size,
            };
            code_section.setNameOffset(@as(u32, @intCast(1 + cumulativeNameLen(self.section_names.items))));
            try self.section_names.append(allocator, ".text");
            code_section.setOffset(current_offset);
            current_offset += code_section.size;
            try self.appendSection(allocator, .{ .code = code_section });

            if (has_rodata) {
                var data_section = section_mod.DataSection{
                    .nodes = pr.data_section.nodes.items,
                    .size = rodata_size,
                };
                data_section.setNameOffset(@as(u32, @intCast(1 + cumulativeNameLen(self.section_names.items))));
                try self.section_names.append(allocator, ".rodata");
                data_section.setOffset(current_offset);
                current_offset += data_section.alignedSize();
                try self.appendSection(allocator, .{ .data = data_section });
            }
        }

        // Align the next section on an 8-byte boundary.
        current_offset += padTo8(current_offset);

        // --- dispatch by arch flavor ---
        if (arch == .V3) {
            try self.layoutV3(allocator, pr, &current_offset, base_offset, bytecode_size, rodata_size, has_rodata);
        } else if (!pr.prog_is_static) {
            try self.layoutV0Dynamic(
                allocator,
                pr,
                &current_offset,
                text_offset,
                bytecode_size,
                rodata_size,
            );
        } else {
            try self.layoutV0Static(allocator, pr, &current_offset, text_offset);
        }

        // Finalize: section header table starts right after last section,
        // padded to 8 bytes (matches Rust program.rs L380-383).
        current_offset += padTo8(current_offset);
        self.elf_header.e_shoff = current_offset;
        self.elf_header.e_shnum = self.sectionCount();
        self.elf_header.e_shstrndx = self.sectionCount() - 1;

        return self;
    }

    // -----------------------------------------------------------------------
    // Per-arch layout helpers
    // -----------------------------------------------------------------------

    fn layoutV3(
        self: *Program,
        allocator: std.mem.Allocator,
        pr: *const ParseResult,
        current_offset: *u64,
        base_offset: u64,
        bytecode_size: u64,
        rodata_size: u64,
        has_rodata: bool,
    ) !void {
        // D.2: reuse `.debug_*` sections between the code/data image and
        // shstrtab. Port of Rust sbpf-assembler::debug::reuse_debug_sections
        // (debug.rs L197-234). No-op if pr.debug_sections is empty.
        try self.appendDebugSections(allocator, pr, current_offset);

        // shstrtab sits at the end.
        const shstrtab_name_offset = @as(u32, @intCast(shstrtabNameOffset(self.section_names.items)));
        var shstrtab = section_mod.ShStrTabSection{
            .name_offset = shstrtab_name_offset,
            .section_names = self.section_names.items,
        };
        shstrtab.setOffset(current_offset.*);
        current_offset.* += shstrtab.paddedSize();
        try self.appendSection(allocator, .{ .shstrtab = shstrtab });

        // Program headers — V3 uses fixed virtual addresses.
        if (has_rodata) {
            const rodata_offset = base_offset;
            const bytecode_offset = base_offset + rodata_size;
            try self.appendProgramHeader(
                allocator,
                ProgramHeader.newLoad(rodata_offset, rodata_size, false, .V3),
            );
            try self.appendProgramHeader(
                allocator,
                ProgramHeader.newLoad(bytecode_offset, bytecode_size, true, .V3),
            );
        } else {
            try self.appendProgramHeader(
                allocator,
                ProgramHeader.newLoad(base_offset, bytecode_size, true, .V3),
            );
        }
    }

    /// D.2: port of Rust `reuse_debug_sections` (debug.rs L197-234).
    /// For each parsed debug section:
    ///   - assign name_offset = 1 + Σ(section_names[i].len+1)
    ///   - push its name into section_names (so future sections' name
    ///     offsets are correct)
    ///   - assign its file offset = current_offset
    ///   - bump current_offset by its size
    ///   - append as `SectionType.debug` to self.sections
    ///
    /// No-op if pr.debug_sections is empty (the common case for
    /// ReleaseSmall builds).
    fn appendDebugSections(
        self: *Program,
        allocator: std.mem.Allocator,
        pr: *const ParseResult,
        current_offset: *u64,
    ) !void {
        for (pr.debug_sections) |ds| {
            const name_offset = @as(u32, @intCast(1 + cumulativeNameLen(self.section_names.items)));
            var section = section_mod.DebugSection{
                .section_name = ds.name,
                .name_offset = name_offset,
                .data = ds.data,
            };
            try self.section_names.append(allocator, ds.name);
            section.setOffset(current_offset.*);
            current_offset.* += section.size();
            try self.appendSection(allocator, .{ .debug = section });
        }
    }

    fn layoutV0Dynamic(
        self: *Program,
        allocator: std.mem.Allocator,
        pr: *const ParseResult,
        current_offset: *u64,
        text_offset: u64,
        bytecode_size: u64,
        rodata_size: u64,
    ) !void {
        // --- build dyn_syms + symbol_names from ParseResult.dynamic_symbols.
        try self.dyn_syms_storage.append(allocator, .{
            .name = 0,
            .info = 0,
            .other = 0,
            .shndx = 0,
            .value = 0,
            .size = 0,
        });

        var dyn_str_offset: u32 = 1; // 1 = after leading null byte
        // entry points first
        for (pr.dynamic_symbols.entries.items) |e| {
            if (!e.is_entry_point) continue;
            try self.symbol_names_storage.append(allocator, e.name);
            try self.dyn_syms_storage.append(allocator, .{
                .name = dyn_str_offset,
                .info = section_mod.STB_GLOBAL_STT_NOTYPE,
                .other = 0,
                .shndx = 1, // points at .text (section index 1)
                .value = self.elf_header.e_entry,
                .size = 0,
            });
            dyn_str_offset += @as(u32, @intCast(e.name.len + 1));
        }
        // Call targets (syscalls): one dynsym entry per unique name, sorted
        // lexicographically to match the reference-shim / Rust output.
        var syscall_names: std.ArrayList([]const u8) = .empty;
        defer syscall_names.deinit(allocator);
        for (pr.dynamic_symbols.entries.items) |e| {
            if (e.is_entry_point) continue;
            if (findSymbolIndex(syscall_names.items, e.name) != null) continue;
            try syscall_names.append(allocator, e.name);
        }
        std.mem.sort([]const u8, syscall_names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        for (syscall_names.items) |name| {
            try self.symbol_names_storage.append(allocator, name);
            try self.dyn_syms_storage.append(allocator, .{
                .name = dyn_str_offset,
                .info = section_mod.STB_GLOBAL_STT_NOTYPE,
                .other = 0,
                .shndx = 0,
                .value = 0,
                .size = 0,
            });
            dyn_str_offset += @as(u32, @intCast(name.len + 1));
        }

        // --- build rel_dyns from ParseResult.relocation_data.
        var rel_count: u64 = 0;
        for (pr.relocation_data.entries.items) |r| {
            switch (r.type) {
                .RSbfSyscall => {
                    // dynsym index = position in symbol_names + 1 (dynsym[0] is STN_UNDEF)
                    const idx = findSymbolIndex(self.symbol_names_storage.items, r.symbol_name) orelse
                        return BuildError.SyscallSymbolNotFound;
                    try self.rel_dyns_storage.append(allocator, .{
                        .offset = r.offset + text_offset,
                        .rel_type = section_mod.R_SBF_SYSCALL,
                        .dynstr_offset = @as(u64, idx) + 1,
                    });
                },
                .RSbf64Relative => {
                    rel_count += 1;
                    try self.rel_dyns_storage.append(allocator, .{
                        .offset = r.offset + text_offset,
                        .rel_type = section_mod.R_SBF_64_RELATIVE,
                        .dynstr_offset = 0,
                    });
                },
            }
        }

        // Match Rust output: .rel.dyn entries are serialized in ascending
        // offset order.
        std.mem.sort(section_mod.RelDynEntry, self.rel_dyns_storage.items, {}, struct {
            fn lt(_: void, a: section_mod.RelDynEntry, b: section_mod.RelDynEntry) bool {
                if (a.offset != b.offset) return a.offset < b.offset;
                return a.rel_type < b.rel_type;
            }
        }.lt);

        // --- allocate name_offsets in the order: .dynamic, .dynsym,
        // .dynstr, .rel.dyn. Each name_offset = leading-null (1) +
        // cumulative (name.len+1) of section_names so far.
        const dynamic_name_offset = @as(u32, @intCast(1 + cumulativeNameLen(self.section_names.items)));
        try self.section_names.append(allocator, ".dynamic");

        const dynsym_name_offset = @as(u32, @intCast(1 + cumulativeNameLen(self.section_names.items)));
        try self.section_names.append(allocator, ".dynsym");

        const dynstr_name_offset = @as(u32, @intCast(1 + cumulativeNameLen(self.section_names.items)));
        try self.section_names.append(allocator, ".dynstr");

        const reldyn_name_offset = @as(u32, @intCast(1 + cumulativeNameLen(self.section_names.items)));
        try self.section_names.append(allocator, ".rel.dyn");

        // The section_names.position(.dynstr) + 1 = section index in final layout
        // (the +1 accounts for the NullSection at index 0, which doesn't
        // contribute to section_names).
        const dynstr_section_index: u32 = findNameIndex(self.section_names.items, ".dynstr").? + 1;
        const dynsym_section_index: u32 = findNameIndex(self.section_names.items, ".dynsym").? + 1;

        // --- instantiate & lay out the four sections in order.
        var dynamic_section = section_mod.DynamicSection{
            .name_offset = dynamic_name_offset,
            .link = dynstr_section_index,
            .rel_count = rel_count,
        };
        dynamic_section.setOffset(current_offset.*);
        current_offset.* += dynamic_section.size();

        var dynsym_section = section_mod.DynSymSection{
            .name_offset = dynsym_name_offset,
            .entries = self.dyn_syms_storage.items,
            .link = dynstr_section_index,
        };
        dynsym_section.setOffset(current_offset.*);
        current_offset.* += dynsym_section.size();

        var dynstr_section = section_mod.DynStrSection{
            .name_offset = dynstr_name_offset,
            .symbol_names = self.symbol_names_storage.items,
        };
        dynstr_section.setOffset(current_offset.*);
        current_offset.* += dynstr_section.size();

        var rel_dyn_section = section_mod.RelDynSection{
            .name_offset = reldyn_name_offset,
            .entries = self.rel_dyns_storage.items,
            .link = dynsym_section_index,
        };
        rel_dyn_section.setOffset(current_offset.*);
        current_offset.* += rel_dyn_section.size();

        // Back-fill cross-references into Dynamic.
        dynamic_section.rel_offset = rel_dyn_section.offset;
        dynamic_section.rel_size = rel_dyn_section.size();
        dynamic_section.dynsym_offset = dynsym_section.offset;
        dynamic_section.dynstr_offset = dynstr_section.offset;
        dynamic_section.dynstr_size = dynstr_section.size();

        // Push the 4 dynamic sections now (after back-fills, before debug).
        // This keeps the section-table order Rust expects:
        //   [Null, Code, (Data?), Dynamic, DynSym, DynStr, RelDyn, Debug*, ShStrTab]
        try self.appendSection(allocator, .{ .dynamic = dynamic_section });
        try self.appendSection(allocator, .{ .dynsym = dynsym_section });
        try self.appendSection(allocator, .{ .dynstr = dynstr_section });
        try self.appendSection(allocator, .{ .reldyn = rel_dyn_section });

        // D.2: reuse parsed `.debug_*` sections (if any) between reldyn
        // and shstrtab. Bumps current_offset + adds debug names to
        // section_names so shstrtab's name_offset is correct.
        try self.appendDebugSections(allocator, pr, current_offset);

        // --- shstrtab at the end (after all debug names are in).
        const shstrtab_name_offset = @as(u32, @intCast(1 + cumulativeNameLen(self.section_names.items)));
        var shstrtab = section_mod.ShStrTabSection{
            .name_offset = shstrtab_name_offset,
            .section_names = self.section_names.items,
        };
        shstrtab.setOffset(current_offset.*);
        current_offset.* += shstrtab.paddedSize();

        // --- program headers: text PT_LOAD, (dynsym+dynstr+reldyn) PT_LOAD,
        // dynamic PT_DYNAMIC.
        // Rodata contributes its PADDED size to the PT_LOAD (matches Rust
        // DataSection::size() which returns `(size + 7) & ~7`). The section
        // header itself still records the logical unpadded size.
        const padded_rodata_size = (rodata_size + 7) & ~@as(u64, 7);
        const text_size = bytecode_size + padded_rodata_size;
        try self.appendProgramHeader(
            allocator,
            ProgramHeader.newLoad(text_offset, text_size, true, .V0),
        );
        try self.appendProgramHeader(
            allocator,
            ProgramHeader.newLoad(
                dynsym_section.offset,
                dynsym_section.size() + dynstr_section.size() + rel_dyn_section.size(),
                false,
                .V0,
            ),
        );
        try self.appendProgramHeader(
            allocator,
            ProgramHeader.newDynamic(dynamic_section.offset, dynamic_section.size()),
        );

        // --- push shstrtab last (dynamic/dynsym/dynstr/reldyn were pushed
        // earlier, before appendDebugSections).
        try self.appendSection(allocator, .{ .shstrtab = shstrtab });
    }

    // -----------------------------------------------------------------------
    // emitBytecode — serialize the assembled Program to the output .so bytes.
    //
    // Layout (mirrors Rust program.rs::emit_bytecode at L392-416):
    //   1. ELF header (64 bytes)
    //   2. Program headers (phnum × 56)
    //   3. Section bytecode, concatenated in push order
    //   4. Padding to 8-byte boundary (lands at e_shoff)
    //   5. Section headers (shnum × 64)
    //
    // Caller owns the returned slice; free with the same allocator.
    // -----------------------------------------------------------------------

    pub fn emitBytecode(self: *const Program, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        // 1. ELF header.
        var ehdr: [header_mod.ELF64_HEADER_SIZE]u8 = undefined;
        self.elf_header.bytecode(&ehdr);
        try out.appendSlice(allocator, &ehdr);

        // 2. Program headers.
        for (self.program_headers.items) |ph| {
            var phbytes: [header_mod.PROGRAM_HEADER_SIZE]u8 = undefined;
            ph.bytecode(&phbytes);
            try out.appendSlice(allocator, &phbytes);
        }

        // 3. Section bytecode.
        for (self.sections.items) |s| {
            const bytes = try s.bytecode(allocator);
            defer allocator.free(bytes);
            try out.appendSlice(allocator, bytes);
        }

        // 4. Pad to section-header boundary. We track the current byte
        // position ourselves and pad to match e_shoff (which was set in
        // fromParseResult to `last_section_end + padTo8`).
        while (out.items.len < self.elf_header.e_shoff) {
            try out.append(allocator, 0);
        }

        // 5. Section headers (64 bytes each).
        for (self.sections.items) |s| {
            var shbytes: [header_mod.SECTION_HEADER_SIZE]u8 = undefined;
            s.sectionHeaderBytecode(&shbytes);
            try out.appendSlice(allocator, &shbytes);
        }

        return out.toOwnedSlice(allocator);
    }

    fn layoutV0Static(
        self: *Program,
        allocator: std.mem.Allocator,
        pr: *const ParseResult,
        current_offset: *u64,
        text_offset: u64,
    ) !void {
        _ = text_offset;

        // D.2: reuse parsed `.debug_*` sections (if any) before shstrtab.
        try self.appendDebugSections(allocator, pr, current_offset);

        // V0 static: no dynamic sections, no program headers. Shstrtab
        // is the last section.
        const shstrtab_name_offset = @as(u32, @intCast(1 + cumulativeNameLen(self.section_names.items)));
        var shstrtab = section_mod.ShStrTabSection{
            .name_offset = shstrtab_name_offset,
            .section_names = self.section_names.items,
        };
        shstrtab.setOffset(current_offset.*);
        current_offset.* += shstrtab.paddedSize();
        try self.appendSection(allocator, .{ .shstrtab = shstrtab });
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn padTo8(offset: u64) u64 {
    return (8 - (offset % 8)) % 8;
}

fn eFlagsFor(arch: SbpfArch) u32 {
    return switch (arch) {
        .V0 => 0,
        .V3 => 3,
    };
}

fn firstEntryPointOffset(pr: *const ParseResult) u64 {
    for (pr.dynamic_symbols.entries.items) |e| {
        if (e.is_entry_point) return e.offset;
    }
    return 0;
}

fn cumulativeNameLen(names: []const []const u8) u64 {
    var total: u64 = 0;
    for (names) |n| total += @as(u64, n.len + 1);
    return total;
}

fn shstrtabNameOffset(names: []const []const u8) u64 {
    // Leading null byte counts as offset 0; names start at offset 1.
    return 1 + cumulativeNameLen(names);
}

fn findSymbolIndex(names: []const []const u8, target: []const u8) ?usize {
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, target)) return i;
    }
    return null;
}

fn findNameIndex(names: []const []const u8, target: []const u8) ?u32 {
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, target)) return @intCast(i);
    }
    return null;
}

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

test "fromParseResult: V0 static exit-only produces Null+Code+ShStrTab" {
    // Minimal ParseResult: one exit instruction, no rodata, no dynamic
    // symbols, no relocations, no debug. V0 static.
    var code_nodes: std.ArrayList(ast_mod.ASTNode) = .empty;
    defer code_nodes.deinit(testing.allocator);

    var data_nodes: std.ArrayList(ast_mod.ASTNode) = .empty;
    defer data_nodes.deinit(testing.allocator);

    var pr = ParseResult{
        .code_section = ast_mod.CodeSection.new(code_nodes, 8),
        .data_section = ast_mod.DataSection.new(data_nodes, 0),
        .dynamic_symbols = ast_mod.DynamicSymbolMap.init(testing.allocator),
        .relocation_data = ast_mod.RelDynMap.init(testing.allocator),
        .prog_is_static = true,
        .arch = .V0,
        .debug_sections = &.{},
    };
    defer pr.dynamic_symbols.deinit(testing.allocator);
    defer pr.relocation_data.deinit(testing.allocator);

    var prog = try Program.fromParseResult(testing.allocator, &pr);
    defer prog.deinit(testing.allocator);

    // Sections: Null, Code, ShStrTab → 3
    try testing.expectEqual(@as(u16, 3), prog.sectionCount());
    try testing.expectEqual(@as(u16, 0), prog.programHeaderCount());
    try testing.expect(std.meta.activeTag(prog.sections.items[0]) == .null_);
    try testing.expect(std.meta.activeTag(prog.sections.items[1]) == .code);
    try testing.expect(std.meta.activeTag(prog.sections.items[2]) == .shstrtab);

    // Entry point = text_offset + 0 = base_offset + 0 = 64 (no PH).
    try testing.expectEqual(@as(u64, 64), prog.elf_header.e_entry);
    try testing.expectEqual(@as(u16, 3), prog.elf_header.e_shnum);
    try testing.expectEqual(@as(u16, 2), prog.elf_header.e_shstrndx);
}

test "fromParseResult: V3 no-rodata single PT_LOAD" {
    var code_nodes: std.ArrayList(ast_mod.ASTNode) = .empty;
    defer code_nodes.deinit(testing.allocator);

    var data_nodes: std.ArrayList(ast_mod.ASTNode) = .empty;
    defer data_nodes.deinit(testing.allocator);

    var pr = ParseResult{
        .code_section = ast_mod.CodeSection.new(code_nodes, 8),
        .data_section = ast_mod.DataSection.new(data_nodes, 0),
        .dynamic_symbols = ast_mod.DynamicSymbolMap.init(testing.allocator),
        .relocation_data = ast_mod.RelDynMap.init(testing.allocator),
        .prog_is_static = true, // ignored for V3
        .arch = .V3,
        .debug_sections = &.{},
    };
    defer pr.dynamic_symbols.deinit(testing.allocator);
    defer pr.relocation_data.deinit(testing.allocator);

    var prog = try Program.fromParseResult(testing.allocator, &pr);
    defer prog.deinit(testing.allocator);

    // Sections: Null, Code, ShStrTab → 3
    try testing.expectEqual(@as(u16, 3), prog.sectionCount());
    try testing.expectEqual(@as(u16, 1), prog.programHeaderCount());
    try testing.expectEqual(@as(u32, 3), prog.elf_header.e_flags); // V3 e_flags=3

    // V3 entry point = V3_BYTECODE_VADDR + 0.
    try testing.expectEqual(header_mod.V3_BYTECODE_VADDR, prog.elf_header.e_entry);

    // Single PT_LOAD with PF_X.
    try testing.expectEqual(@as(u32, header_mod.PT_LOAD), prog.program_headers.items[0].p_type);
    try testing.expectEqual(@as(u32, header_mod.PF_X), prog.program_headers.items[0].p_flags);
}

test "fromParseResult: V0 dynamic with syscall produces full section list + 3 PH" {
    // Two dynamic symbols: one entry_point "entrypoint", one syscall
    // call-target "sol_log_". One RSbfSyscall relocation targeting the
    // latter.
    var code_nodes: std.ArrayList(ast_mod.ASTNode) = .empty;
    defer code_nodes.deinit(testing.allocator);
    var data_nodes: std.ArrayList(ast_mod.ASTNode) = .empty;
    defer data_nodes.deinit(testing.allocator);

    var pr = ParseResult{
        .code_section = ast_mod.CodeSection.new(code_nodes, 0x18),
        .data_section = ast_mod.DataSection.new(data_nodes, 0),
        .dynamic_symbols = ast_mod.DynamicSymbolMap.init(testing.allocator),
        .relocation_data = ast_mod.RelDynMap.init(testing.allocator),
        .prog_is_static = false,
        .arch = .V0,
        .debug_sections = &.{},
    };
    defer pr.dynamic_symbols.deinit(testing.allocator);
    defer pr.relocation_data.deinit(testing.allocator);

    try pr.dynamic_symbols.addEntryPoint(testing.allocator, "entrypoint", 0);
    try pr.dynamic_symbols.addCallTarget(testing.allocator, "sol_log_", 0);
    try pr.relocation_data.addRelDyn(testing.allocator, 0x10, .RSbfSyscall, "sol_log_");

    var prog = try Program.fromParseResult(testing.allocator, &pr);
    defer prog.deinit(testing.allocator);

    // Sections: Null, Code, Dynamic, DynSym, DynStr, RelDyn, ShStrTab → 7
    try testing.expectEqual(@as(u16, 7), prog.sectionCount());
    try testing.expect(std.meta.activeTag(prog.sections.items[0]) == .null_);
    try testing.expect(std.meta.activeTag(prog.sections.items[1]) == .code);
    try testing.expect(std.meta.activeTag(prog.sections.items[2]) == .dynamic);
    try testing.expect(std.meta.activeTag(prog.sections.items[3]) == .dynsym);
    try testing.expect(std.meta.activeTag(prog.sections.items[4]) == .dynstr);
    try testing.expect(std.meta.activeTag(prog.sections.items[5]) == .reldyn);
    try testing.expect(std.meta.activeTag(prog.sections.items[6]) == .shstrtab);

    // 3 program headers: PT_LOAD (text), PT_LOAD (dyn data), PT_DYNAMIC.
    try testing.expectEqual(@as(u16, 3), prog.programHeaderCount());
    try testing.expectEqual(@as(u32, header_mod.PT_LOAD), prog.program_headers.items[0].p_type);
    try testing.expectEqual(@as(u32, header_mod.PT_LOAD), prog.program_headers.items[1].p_type);
    try testing.expectEqual(@as(u32, header_mod.PT_DYNAMIC), prog.program_headers.items[2].p_type);

    // dyn_syms_storage: STN_UNDEF + entrypoint + sol_log_ = 3 entries.
    try testing.expectEqual(@as(usize, 3), prog.dyn_syms_storage.items.len);
    // symbol_names_storage: entrypoint + sol_log_ = 2.
    try testing.expectEqual(@as(usize, 2), prog.symbol_names_storage.items.len);
    // rel_dyns_storage: 1 syscall relocation.
    try testing.expectEqual(@as(usize, 1), prog.rel_dyns_storage.items.len);

    // Dynamic section's rel_count = 0 (no RELATIVE relocs in this input).
    const dyn = prog.sections.items[2].dynamic;
    try testing.expectEqual(@as(u64, 0), dyn.rel_count);
    // Dynamic section is back-linked to .dynstr (section index 4 in final
    // layout: Null/Code/Dynamic/DynSym/DynStr/RelDyn/ShStrTab).
    try testing.expectEqual(@as(u32, 4), dyn.link);
}

test "emitBytecode: V0 static starts with \\x7fELF and ends at e_shoff + shnum*64" {
    var code_nodes: std.ArrayList(ast_mod.ASTNode) = .empty;
    defer code_nodes.deinit(testing.allocator);
    var data_nodes: std.ArrayList(ast_mod.ASTNode) = .empty;
    defer data_nodes.deinit(testing.allocator);

    var pr = ParseResult{
        .code_section = ast_mod.CodeSection.new(code_nodes, 0),
        .data_section = ast_mod.DataSection.new(data_nodes, 0),
        .dynamic_symbols = ast_mod.DynamicSymbolMap.init(testing.allocator),
        .relocation_data = ast_mod.RelDynMap.init(testing.allocator),
        .prog_is_static = true,
        .arch = .V0,
        .debug_sections = &.{},
    };
    defer pr.dynamic_symbols.deinit(testing.allocator);
    defer pr.relocation_data.deinit(testing.allocator);

    var prog = try Program.fromParseResult(testing.allocator, &pr);
    defer prog.deinit(testing.allocator);

    const bytes = try prog.emitBytecode(testing.allocator);
    defer testing.allocator.free(bytes);

    // ELF magic.
    try testing.expectEqualSlices(u8, "\x7fELF", bytes[0..4]);
    // Reads back the sh_num and sh_off recorded in the header.
    const e_shoff = std.mem.readInt(u64, bytes[40..48], .little);
    const e_shnum = std.mem.readInt(u16, bytes[60..62], .little);
    try testing.expectEqual(@as(usize, e_shoff + @as(u64, e_shnum) * 64), bytes.len);
    // shnum == 3 (Null + Code + ShStrTab).
    try testing.expectEqual(@as(u16, 3), e_shnum);
}

test "emitBytecode: V0 dynamic embeds 3 program headers and full section table" {
    var code_nodes: std.ArrayList(ast_mod.ASTNode) = .empty;
    defer code_nodes.deinit(testing.allocator);
    var data_nodes: std.ArrayList(ast_mod.ASTNode) = .empty;
    defer data_nodes.deinit(testing.allocator);

    var pr = ParseResult{
        .code_section = ast_mod.CodeSection.new(code_nodes, 0x18),
        .data_section = ast_mod.DataSection.new(data_nodes, 0),
        .dynamic_symbols = ast_mod.DynamicSymbolMap.init(testing.allocator),
        .relocation_data = ast_mod.RelDynMap.init(testing.allocator),
        .prog_is_static = false,
        .arch = .V0,
        .debug_sections = &.{},
    };
    defer pr.dynamic_symbols.deinit(testing.allocator);
    defer pr.relocation_data.deinit(testing.allocator);

    try pr.dynamic_symbols.addEntryPoint(testing.allocator, "entrypoint", 0);
    try pr.dynamic_symbols.addCallTarget(testing.allocator, "sol_log_", 0);
    try pr.relocation_data.addRelDyn(testing.allocator, 0x10, .RSbfSyscall, "sol_log_");

    var prog = try Program.fromParseResult(testing.allocator, &pr);
    defer prog.deinit(testing.allocator);

    const bytes = try prog.emitBytecode(testing.allocator);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x7fELF", bytes[0..4]);
    const e_phnum = std.mem.readInt(u16, bytes[56..58], .little);
    try testing.expectEqual(@as(u16, 3), e_phnum);
    const e_shnum = std.mem.readInt(u16, bytes[60..62], .little);
    try testing.expectEqual(@as(u16, 7), e_shnum);

    // Output must be at least ELF header (64) + 3×PH (168) + 7×SH (448)
    // = 680 bytes, plus whatever the section contents take.
    try testing.expect(bytes.len >= 680);
}

test "emitBytecode: ends at exactly (e_shoff + shnum * 64)" {
    // Any valid Program should satisfy this invariant — no trailing bytes
    // after the section header table.
    var code_nodes: std.ArrayList(ast_mod.ASTNode) = .empty;
    defer code_nodes.deinit(testing.allocator);
    var data_nodes: std.ArrayList(ast_mod.ASTNode) = .empty;
    defer data_nodes.deinit(testing.allocator);

    var pr = ParseResult{
        .code_section = ast_mod.CodeSection.new(code_nodes, 8),
        .data_section = ast_mod.DataSection.new(data_nodes, 0),
        .dynamic_symbols = ast_mod.DynamicSymbolMap.init(testing.allocator),
        .relocation_data = ast_mod.RelDynMap.init(testing.allocator),
        .prog_is_static = true,
        .arch = .V3,
        .debug_sections = &.{},
    };
    defer pr.dynamic_symbols.deinit(testing.allocator);
    defer pr.relocation_data.deinit(testing.allocator);

    var prog = try Program.fromParseResult(testing.allocator, &pr);
    defer prog.deinit(testing.allocator);

    const bytes = try prog.emitBytecode(testing.allocator);
    defer testing.allocator.free(bytes);

    const e_shoff = std.mem.readInt(u64, bytes[40..48], .little);
    const e_shnum = std.mem.readInt(u16, bytes[60..62], .little);
    try testing.expectEqual(@as(usize, e_shoff + @as(u64, e_shnum) * 64), bytes.len);
}
