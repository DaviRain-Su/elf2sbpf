const std = @import("std");
const builtin = @import("builtin");
const linker = @import("lib.zig");

const UsageError = error{ InvalidArgs };

const ParsedArgs = union(enum) {
    help,
    run: struct {
        input_path: []const u8,
        output_path: []const u8,
    },
};

fn parseArgv(args: []const []const u8) UsageError!ParsedArgs {
    if (args.len == 2 and
        (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")))
    {
        return .help;
    }
    if (args.len == 3) {
        return .{ .run = .{
            .input_path = args[1],
            .output_path = args[2],
        } };
    }
    return UsageError.InvalidArgs;
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll("Usage: elf2sbpf <input.o> <output.so>\n");
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
    allocator: std.mem.Allocator,
    args: []const []const u8,
) CliExit {
    const io = if (builtin.is_test) std.testing.io else std.options.debug_io;
    const cwd = std.Io.Dir.cwd();
    const parsed = parseArgv(args) catch return .usage;

    switch (parsed) {
        .help => return .usage,
        .run => |run| {
            const elf_bytes = cwd.readFileAlloc(io, run.input_path, allocator, .unlimited) catch return .read_error;
            defer allocator.free(elf_bytes);

            const out = linker.linkProgram(allocator, elf_bytes) catch |err| return .{ .link_error = err };
            defer allocator.free(out);

            cwd.writeFile(io, .{
                .sub_path = run.output_path,
                .data = out,
            }) catch return .write_error;

            return .ok;
        },
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args_z = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args_z);

    var args = try allocator.alloc([]const u8, args_z.len);
    defer allocator.free(args);
    for (args_z, 0..) |arg, idx| args[idx] = std.mem.span(arg);

    switch (runCli(allocator, args)) {
        .ok => return,
        .usage => {
            try printUsage(std.io.getStdErr().writer());
            std.process.exit(1);
        },
        .read_error => {
            try std.io.getStdErr().writer().writeAll("failed to read input file\n");
            std.process.exit(2);
        },
        .link_error => |err| {
            try std.io.getStdErr().writer().print("link failed: {s}\n", .{@errorName(err)});
            std.process.exit(linkErrorExitCode(err));
        },
        .write_error => {
            try std.io.getStdErr().writer().writeAll("failed to write output file\n");
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
    try std.testing.expectEqual(CliExit.usage, runCli(alloc, &args));
}

test "runCli returns usage for invalid args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_][]const u8{ "elf2sbpf" };
    try std.testing.expectEqual(CliExit.usage, runCli(alloc, &args));
}

test "runCli returns read_error for missing input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_][]const u8{ "elf2sbpf", "missing-input.o", "/tmp/out.so" };
    try std.testing.expectEqual(CliExit.read_error, runCli(alloc, &args));
}
