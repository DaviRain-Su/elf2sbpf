// Build script for elf2sbpf.
//
// Layout (02-architecture.md §3):
//   - src/lib.zig is the library root — exposes linkProgram.
//   - src/main.zig is the CLI — thin wrapper over linkProgram.
//
// Steps exposed:
//   - `zig build`      → builds the elf2sbpf executable into zig-out/bin
//   - `zig build run`  → builds then runs the executable (pass args via `--`)
//   - `zig build test` → runs unit tests from both lib and exe modules

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module — re-exported so future Zig projects can @import("elf2sbpf").
    const lib_mod = b.addModule("elf2sbpf", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Executable module — the CLI. Imports the library module so main.zig can
    // call linkProgram without path-qualified @import.
    const exe = b.addExecutable(.{
        .name = "elf2sbpf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elf2sbpf", .module = lib_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // `zig build run` — useful during development.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run elf2sbpf");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — runs tests from both lib and exe modules.
    // Per Phase 5 §3, each src/*.zig keeps its tests at file bottom.
    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // TODO(C.5): add integration tests here once Zig 0.16's new Io.Dir
    // API is wired in. We'll either use @embedFile against a fixture
    // copied under tests/fixtures/, or set up a std.Io.Threaded context.

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
