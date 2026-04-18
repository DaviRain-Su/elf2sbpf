const std = @import("std");
const linker = @import("lib.zig");

const UsageError = error{InvalidArgs};

const ParsedArgs = union(enum) {
    help,
    run: struct {
        input_path: []const u8,
        output_path: []const u8,
        arch: linker.SbpfArch,
    },
};

fn parseArgv(args: []const []const u8) UsageError!ParsedArgs {
    if (args.len == 2 and
        (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")))
    {
        return .help;
    }
    // Accept [--v0|--v3] anywhere among the positional args. Defaults to V0.
    var arch: linker.SbpfArch = .V0;
    var positional: [2][]const u8 = .{ "", "" };
    var pos_idx: usize = 0;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--v0")) {
            arch = .V0;
        } else if (std.mem.eql(u8, arg, "--v3")) {
            arch = .V3;
        } else if (pos_idx < 2) {
            positional[pos_idx] = arg;
            pos_idx += 1;
        } else {
            return UsageError.InvalidArgs;
        }
    }
    if (pos_idx != 2) return UsageError.InvalidArgs;
    return .{ .run = .{
        .input_path = positional[0],
        .output_path = positional[1],
        .arch = arch,
    } };
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll("Usage: elf2sbpf [--v0|--v3] <input.o> <output.so>\n");
}

fn linkErrorExitCode(err: linker.LinkError) u8 {
    return switch (err) {
        error.InvalidElf,
        error.UnsupportedMachine,
        error.UnsupportedClass,
        error.UnsupportedEndian,
        => 3,
        error.InstructionDecodeFailed,
        error.TextSectionMisaligned,
        error.LddwTargetOutsideRodata,
        error.LddwTargetInsideNamedEntry,
        error.CallTargetUnresolvable,
        => 4,
        error.UndefinedLabel,
        error.RodataSectionOverflow,
        error.RodataTooLarge,
        error.TextTooLarge,
        error.OutOfMemory,
        => 4,
    };
}

const CliExit = union(enum) {
    ok,
    usage,
    read_error,
    link_error: linker.LinkError,
    write_error,
};

fn runCli(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) CliExit {
    const cwd = std.Io.Dir.cwd();
    const parsed = parseArgv(args) catch return .usage;

    switch (parsed) {
        .help => return .usage,
        .run => |run| {
            const elf_bytes = cwd.readFileAlloc(io, run.input_path, allocator, .limited(std.math.maxInt(usize))) catch return .read_error;
            defer allocator.free(elf_bytes);

            const out = switch (run.arch) {
                .V0 => linker.linkProgram(allocator, elf_bytes),
                .V3 => linker.linkProgramV3(allocator, elf_bytes),
            } catch |err| return .{ .link_error = err };
            defer allocator.free(out);

            cwd.writeFile(io, .{
                .sub_path = run.output_path,
                .data = out,
            }) catch return .write_error;

            return .ok;
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const args_z = try init.minimal.args.toSlice(init.arena.allocator());
    const args = try allocator.alloc([]const u8, args_z.len);
    defer allocator.free(args);
    for (args_z, 0..) |arg, idx| args[idx] = arg;

    switch (runCli(io, allocator, args)) {
        .ok => return,
        .usage => {
            var stderr_buffer: [256]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
            try printUsage(&stderr_writer.interface);
            try stderr_writer.flush();
            std.process.exit(1);
        },
        .read_error => {
            var stderr_buffer: [256]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
            try stderr_writer.interface.writeAll("failed to read input file\n");
            try stderr_writer.flush();
            std.process.exit(2);
        },
        .link_error => |err| {
            var stderr_buffer: [256]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
            try stderr_writer.interface.print("link failed: {s}\n", .{@errorName(err)});
            try stderr_writer.flush();
            std.process.exit(linkErrorExitCode(err));
        },
        .write_error => {
            var stderr_buffer: [256]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
            try stderr_writer.interface.writeAll("failed to write output file\n");
            try stderr_writer.flush();
            std.process.exit(5);
        },
    }
}

test "parseArgv parses run mode" {
    const args = [_][]const u8{
        "elf2sbpf",
        "in.o",
        "out.so",
    };
    const parsed = try parseArgv(&args);
    switch (parsed) {
        .run => |run| {
            try std.testing.expectEqualStrings("in.o", run.input_path);
            try std.testing.expectEqualStrings("out.so", run.output_path);
        },
        else => return error.UnexpectedTestResult,
    }
}

test "parseArgv parses help mode" {
    const args = [_][]const u8{
        "elf2sbpf",
        "--help",
    };
    const parsed = try parseArgv(&args);
    switch (parsed) {
        .help => {},
        else => return error.UnexpectedTestResult,
    }
}

test "parseArgv rejects invalid arity" {
    const args = [_][]const u8{
        "elf2sbpf",
    };
    try std.testing.expectError(UsageError.InvalidArgs, parseArgv(&args));
}

test "runCli returns usage for --help" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_][]const u8{ "elf2sbpf", "--help" };
    try std.testing.expectEqual(CliExit.usage, runCli(std.testing.io, alloc, &args));
}

test "runCli returns usage for invalid args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_][]const u8{"elf2sbpf"};
    try std.testing.expectEqual(CliExit.usage, runCli(std.testing.io, alloc, &args));
}

test "runCli returns read_error for missing input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_][]const u8{ "elf2sbpf", "missing-input.o", "/tmp/out.so" };
    try std.testing.expectEqual(CliExit.read_error, runCli(std.testing.io, alloc, &args));
}
