// zignocchio build.zig — elf2sbpf-only integration draft
//
// Drop-in replacement for the old sbpf-linker-based build.
//
// This version keeps exactly one linking path:
//
//   1. `zig build-lib -femit-llvm-bc -fno-emit-bin`  → entrypoint.bc
//   2. `zig cc -c entrypoint.bc -mllvm -bpf-stack-size=4096`  → entrypoint.o
//   3. `elf2sbpf entrypoint.o program.so`
//
// Requirements:
//   * Zig 0.16
//   * `elf2sbpf` on PATH, or pass `-Delf2sbpf-bin=/path/to/elf2sbpf`
//
// Why a separate `zig cc` step? `zig build-lib` reports "stack size
// exceeded" for non-trivial Solana programs because the LLVM BPF backend
// defaults to the 512-byte Linux kernel stack limit. `zig cc` forwards
// `-mllvm -bpf-stack-size=4096` to LLVM so codegen respects Solana's
// 4 KB stack. See docs/pipeline.md in the elf2sbpf repo for the full
// reasoning.

const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = .ReleaseSmall;

    const example_name = b.option(
        []const u8,
        "example",
        "Example to build (hello / counter / vault / transfer-sol / pda-storage / token-vault / escrow / noop / logonly)",
    ) orelse "counter";

    const elf2sbpf_bin = b.option(
        []const u8,
        "elf2sbpf-bin",
        "Path to the elf2sbpf executable (default: look up on PATH)",
    ) orelse "elf2sbpf";

    const example_path = b.fmt("examples/{s}/lib.zig", .{example_name});

    // Step 1: Zig → LLVM bitcode.
    const bitcode_path = "entrypoint.bc";
    const gen_bitcode = b.addSystemCommand(&.{
        "zig",                                "build-lib",
        "-target",                            "bpfel-freestanding",
        "-O",                                 "ReleaseSmall",
        "-femit-llvm-bc=" ++ bitcode_path,    "-fno-emit-bin",
        "--dep",                              "sdk",
        b.fmt("-Mroot={s}", .{example_path}), "-Msdk=sdk/zignocchio.zig",
    });

    const mkdir_step = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/lib" });

    const obj_path = b.fmt("zig-out/lib/{s}.o", .{example_name});
    const program_so_path = b.fmt("zig-out/lib/{s}.so", .{example_name});

    // Step 2: zig cc bridges bitcode → BPF ELF, forwarding the stack-size
    // override to LLVM.
    const zig_cc = b.addSystemCommand(&.{
        "zig",      "cc",
        "-target",  "bpfel-freestanding",
        "-mcpu=v2", "-O2",
        "-mllvm",   "-bpf-stack-size=4096",
        "-c",       bitcode_path,
        "-o",       obj_path,
    });
    zig_cc.step.dependOn(&gen_bitcode.step);
    zig_cc.step.dependOn(&mkdir_step.step);

    // Step 3: elf2sbpf ELF → Solana SBPF .so.
    const link_program = b.addSystemCommand(&.{
        elf2sbpf_bin, obj_path, program_so_path,
    });
    link_program.step.dependOn(&zig_cc.step);

    b.getInstallStep().dependOn(&link_program.step);

    // --- rest of the build graph is unchanged from the legacy zignocchio
    // build.zig: CLI binary + host-side unit tests. Included here so this
    // file is a drop-in replacement, not a patch.

    const cli_module = b.createModule(.{
        .root_source_file = b.path("cli/src/main.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    cli_module.link_libc = true;
    const cli_exe = b.addExecutable(.{
        .name = "zignocchio-cli",
        .root_module = cli_module,
    });
    b.installArtifact(cli_exe);

    const test_step = b.step("test", "Run unit tests");
    const sdk_module = b.createModule(.{
        .root_source_file = b.path("sdk/zignocchio.zig"),
    });
    const test_module = b.createModule(.{
        .root_source_file = b.path("examples/hello/lib.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    test_module.addImport("sdk", sdk_module);
    const lib_unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_unit_tests = b.addRunArtifact(lib_unit_tests);
    test_step.dependOn(&run_unit_tests.step);
}
