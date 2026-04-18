// elf2sbpf library root.
//
// Per 02-architecture.md §3.4, all linker logic lives under this module so it
// can be @import("elf2sbpf") by other Zig projects. main.zig will end up being
// a thin wrapper over linkProgram (03-technical-spec.md §1.2).
//
// A.1 scaffold: stubbed LinkError enum and a not-yet-implemented linkProgram.
// Individual layers (common / elf / parse / ast / emit) are added under their
// own Epics — they'll be re-exported from this file as they come online.

const std = @import("std");

// Sub-modules — re-exported so that external consumers can reach them
// via `@import("elf2sbpf").Number` etc.
pub const Number = @import("common/number.zig").Number;
pub const Register = @import("common/register.zig").Register;
pub const Opcode = @import("common/opcode.zig").Opcode;

const instruction = @import("common/instruction.zig");
pub const Instruction = instruction.Instruction;
pub const Span = instruction.Span;
pub const Either = instruction.Either;

pub const murmur3_32 = @import("common/syscalls.zig").murmur3_32;

pub const ElfFile = @import("elf/reader.zig").ElfFile;
pub const Section = @import("elf/section.zig").Section;

const symbol_mod = @import("elf/symbol.zig");
pub const Symbol = symbol_mod.Symbol;
pub const SymbolKind = symbol_mod.SymbolKind;
pub const SymbolBinding = symbol_mod.SymbolBinding;
pub const SymTableKind = symbol_mod.SymTableKind;

const reloc_mod = @import("elf/reloc.zig");
pub const Reloc = reloc_mod.Reloc;
pub const RelocType = reloc_mod.RelocType;

pub const byteparser = @import("parse/byteparser.zig");

const ast_node = @import("ast/node.zig");
pub const ASTNode = ast_node.ASTNode;
pub const Label = ast_node.Label;
pub const ROData = ast_node.ROData;
pub const GlobalDecl = ast_node.GlobalDecl;

pub const ast = @import("ast/ast.zig");
pub const AST = ast.AST;
pub const SbpfArch = ast.SbpfArch;
pub const ParseResult = ast.ParseResult;

const emit_header = @import("emit/header.zig");
pub const ElfHeader = emit_header.ElfHeader;
pub const ProgramHeader = emit_header.ProgramHeader;
pub const SectionHeader = emit_header.SectionHeader;

const emit_section_types = @import("emit/section_types.zig");
pub const NullSection = emit_section_types.NullSection;
pub const ShStrTabSection = emit_section_types.ShStrTabSection;
pub const CodeSection = emit_section_types.CodeSection;
pub const DataSection = emit_section_types.DataSection;
pub const DynSymSection = emit_section_types.DynSymSection;
pub const DynSymEntry = emit_section_types.DynSymEntry;
pub const DynStrSection = emit_section_types.DynStrSection;
pub const DynamicSection = emit_section_types.DynamicSection;
pub const RelDynSection = emit_section_types.RelDynSection;
pub const RelDynEntry = emit_section_types.RelDynEntry;
pub const DebugSection = emit_section_types.DebugSection;
pub const SectionType = emit_section_types.SectionType;

pub const Program = @import("emit/program.zig").Program;

// Make sub-module tests runnable via `zig build test`.
test {
    _ = @import("common/number.zig");
    _ = @import("common/register.zig");
    _ = @import("common/opcode.zig");
    _ = @import("common/instruction.zig");
    _ = @import("common/syscalls.zig");
    _ = @import("common/util.zig");
    _ = @import("elf/reader.zig");
    _ = @import("elf/section.zig");
    _ = @import("elf/symbol.zig");
    _ = @import("elf/reloc.zig");
    _ = @import("parse/byteparser.zig");
    _ = @import("ast/node.zig");
    _ = @import("ast/ast.zig");
    _ = @import("emit/header.zig");
    _ = @import("emit/section_types.zig");
    _ = @import("emit/program.zig");
    _ = @import("integration_test.zig");
}

/// Error set returned by any entry point that can fail because of input data
/// (as opposed to internal bugs). Mirrors 03-technical-spec.md §1.3.
pub const LinkError = error{
    // ELF parsing
    InvalidElf,
    UnsupportedMachine,
    UnsupportedClass,
    UnsupportedEndian,

    // byteparser
    InstructionDecodeFailed,
    TextSectionMisaligned,
    LddwTargetOutsideRodata,
    LddwTargetInsideNamedEntry,
    CallTargetUnresolvable,

    // AST buildProgram
    UndefinedLabel,
    RodataSectionOverflow,

    // emit
    RodataTooLarge,
    TextTooLarge,

    // allocation
    OutOfMemory,
};

/// Convert a BPF ELF object into a Solana SBPF program. Caller owns the
/// returned slice and must free it with the same allocator.
///
/// Contract (per 03-technical-spec.md §1.2):
///   - `elf_bytes` must be a valid little-endian ELF64 BPF object.
///   - Return value owned by caller; free with `allocator.free`.
///   - Pure function: same input produces the same output.
///   - Any failure returns a `LinkError` member; never panics on bad input.
/// Same as `linkProgram`, but allows the caller to register additional
/// syscall names (on top of the 30 built-in Solana syscalls) whose
/// murmur3-32 hashes should be reverse-resolved when decoding `call`
/// instructions with `src=0`. Useful for Solana runtime forks or
/// experimental programs that define custom syscalls.
///
/// `extra_syscalls` is a borrowed slice; the caller retains ownership
/// and must keep it alive for the duration of the call. Passing an
/// empty slice (or using `linkProgram` directly) is the same as no
/// extras.
///
/// Returns byte-identical output to `linkProgram` for any program that
/// only uses the built-in syscalls (D.3 is a purely additive API).
pub fn linkProgramWithSyscalls(
    allocator: std.mem.Allocator,
    elf_bytes: []const u8,
    extra_syscalls: []const []const u8,
) LinkError![]u8 {
    const syscalls_mod = @import("common/syscalls.zig");
    const saved = syscalls_mod.thread_extra_syscalls;
    syscalls_mod.thread_extra_syscalls = extra_syscalls;
    defer syscalls_mod.thread_extra_syscalls = saved;
    return linkProgram(allocator, elf_bytes);
}

pub fn linkProgram(
    allocator: std.mem.Allocator,
    elf_bytes: []const u8,
) LinkError![]u8 {
    const elf_file = ElfFile.parse(elf_bytes) catch return LinkError.InvalidElf;

    var bpr = byteparser.byteParse(allocator, &elf_file) catch |e| switch (e) {
        error.OutOfMemory => return LinkError.OutOfMemory,
        else => return LinkError.InvalidElf,
    };
    defer bpr.deinit();

    var ast_val = AST.fromByteParse(allocator, &bpr) catch |e| switch (e) {
        error.OutOfMemory => return LinkError.OutOfMemory,
    };

    // Convert ByteParseResult.debug (DebugScan) → []ast.DebugSection.
    // The slice is owned by ParseResult after buildProgram consumes it.
    const debug_slice = allocator.alloc(ast.DebugSection, bpr.debug.entries.items.len) catch
        return LinkError.OutOfMemory;
    for (bpr.debug.entries.items, 0..) |e, i| {
        debug_slice[i] = .{ .name = e.name, .data = e.data };
    }

    var parse_result = ast_val.buildProgram(.V0, debug_slice) catch |e| switch (e) {
        error.OutOfMemory => return LinkError.OutOfMemory,
        error.UndefinedLabel => return LinkError.UndefinedLabel,
    };
    ast_val.deinit();
    defer parse_result.deinit(allocator);

    var program = Program.fromParseResult(allocator, &parse_result) catch |e| switch (e) {
        error.OutOfMemory => return LinkError.OutOfMemory,
        error.SyscallSymbolNotFound => return LinkError.CallTargetUnresolvable,
    };
    defer program.deinit(allocator);

    return program.emitBytecode(allocator) catch |e| switch (e) {
        error.OutOfMemory => return LinkError.OutOfMemory,
        else => return LinkError.InvalidElf,
    };
}

test "linkProgram rejects non-ELF bytes with InvalidElf" {
    const allocator = std.testing.allocator;
    const result = linkProgram(allocator, &.{});
    try std.testing.expectError(LinkError.InvalidElf, result);
}

test "LinkError has all required variants" {
    // Spec compliance: every error listed in 03-technical-spec.md §1.3 must
    // exist in this enum. @errorName forces the compiler to resolve each
    // identifier — if you remove or rename one, this test stops compiling
    // and you must update the spec first.
    const names = [_][]const u8{
        @errorName(LinkError.InvalidElf),
        @errorName(LinkError.UnsupportedMachine),
        @errorName(LinkError.UnsupportedClass),
        @errorName(LinkError.UnsupportedEndian),
        @errorName(LinkError.InstructionDecodeFailed),
        @errorName(LinkError.TextSectionMisaligned),
        @errorName(LinkError.LddwTargetOutsideRodata),
        @errorName(LinkError.LddwTargetInsideNamedEntry),
        @errorName(LinkError.CallTargetUnresolvable),
        @errorName(LinkError.UndefinedLabel),
        @errorName(LinkError.RodataSectionOverflow),
        @errorName(LinkError.RodataTooLarge),
        @errorName(LinkError.TextTooLarge),
        @errorName(LinkError.OutOfMemory),
    };
    try std.testing.expectEqual(@as(usize, 14), names.len);
}
