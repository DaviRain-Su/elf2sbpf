const std = @import("std");
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args_z = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args_z);

    var args = try allocator.alloc([]const u8, args_z.len);
    defer allocator.free(args);
    for (args_z, 0..) |arg, idx| args[idx] = std.mem.span(arg);

    const parsed = parseArgv(args) catch {
        try printUsage(std.io.getStdErr().writer());
        std.process.exit(1);
    };

    switch (parsed) {
        .help => {
            try printUsage(std.io.getStdOut().writer());
            std.process.exit(1);
        },
        .run => |run| {
            const elf_bytes = std.fs.cwd().readFileAlloc(allocator, run.input_path, std.math.maxInt(usize)) catch |err| {
                try std.io.getStdErr().writer().print("failed to read input '{s}': {s}\n", .{
                    run.input_path,
                    @errorName(err),
                });
                std.process.exit(2);
            };
            defer allocator.free(elf_bytes);

            const out = linker.linkProgram(allocator, elf_bytes) catch |err| {
                try std.io.getStdErr().writer().print("link failed: {s}\n", .{@errorName(err)});
                std.process.exit(linkErrorExitCode(err));
            };
            defer allocator.free(out);

            std.fs.cwd().writeFile(.{
                .sub_path = run.output_path,
                .data = out,
            }) catch |err| {
                try std.io.getStdErr().writer().print("failed to write output '{s}': {s}\n", .{
                    run.output_path,
                    @errorName(err),
                });
                std.process.exit(5);
            };
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
