// zignocchio build.zig — elf2sbpf integration draft (CLI + zig-import)
//
// Drop-in replacement for the old sbpf-linker-based build. Supports two
// back-ends via `-Dlinker=<name>`:
//
//   * elf2sbpf   (default) — CLI subprocess; needs `elf2sbpf` on PATH
//   * zig-import           — in-process via `@import("elf2sbpf")`; requires
//                            the elf2sbpf dependency in build.zig.zon
//                            (see notes below)
//
// No libLLVM, no Rust, no cargo, no rustup, no LD_LIBRARY_PATH jiggling —
// everything fits inside a single Zig 0.16 install.
//
// Pipeline (both back-ends):
//
//   1. `zig build-lib -femit-llvm-bc -fno-emit-bin`  → entrypoint.bc
//   2. `zig cc -c entrypoint.bc -mllvm -bpf-stack-size=4096`  → entrypoint.o
//   3. elf2sbpf linkProgram entrypoint.o → program.so
//      (either via CLI subprocess or in-process @import)
//
// Why a separate `zig cc` step? `zig build-lib` reports "stack size
// exceeded" for non-trivial Solana programs (the LLVM BPF backend defaults
// to the 512-byte Linux kernel stack limit). `zig cc` forwards
// `-mllvm -bpf-stack-size=4096` to LLVM so codegen respects Solana's
// 4 KB stack. See docs/pipeline.md in the elf2sbpf repo for the full
// reasoning.
//
// -------------------------------------------------------------------
// To adopt `-Dlinker=zig-import` (the in-process path):
// -------------------------------------------------------------------
//   1. Add elf2sbpf to build.zig.zon:
//        zig fetch --save git+https://github.com/DaviRain-Su/elf2sbpf
//   2. Add `tools/elf2sbpf-link.zig` to this repo (see the snippet at
//      the end of this file's comment block) — it's a tiny helper that
//      imports elf2sbpf and runs linkProgram.
//   3. `zig build -Dexample=hello -Dlinker=zig-import`
//
// Benefits: no subprocess, no PATH lookup, single build process tree.
// Downside: adds elf2sbpf as a build-time Zig dependency.
//
// To adopt `-Dlinker=elf2sbpf` (CLI subprocess, no dependency):
//   1. Replace the current build.zig with this file.
//   2. Ensure `elf2sbpf` is on PATH OR pass `-Delf2sbpf-bin=/path/to/it`.
//   3. `zig build -Dexample=hello && ls zig-out/lib/hello.so`
//
// -------------------------------------------------------------------
// tools/elf2sbpf-link.zig — required for `-Dlinker=zig-import`:
// -------------------------------------------------------------------
//     const std = @import("std");
//     const elf2sbpf = @import("elf2sbpf");
//
//     pub fn main() !void {
//         var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//         defer _ = gpa.deinit();
//         const allocator = gpa.allocator();
//
//         var args = try std.process.argsWithAllocator(allocator);
//         defer args.deinit();
//
//         _ = args.skip(); // argv[0]
//         const in_path = args.next() orelse return error.MissingInput;
//         const out_path = args.next() orelse return error.MissingOutput;
//
//         const cwd = std.fs.cwd();
//         const bytes = try cwd.readFileAlloc(allocator, in_path, std.math.maxInt(usize));
//         defer allocator.free(bytes);
//
//         const out = try elf2sbpf.linkProgram(allocator, bytes);
//         defer allocator.free(out);
//
//         try cwd.writeFile(out_path, out);
//     }

const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = .ReleaseSmall;

    const example_name = b.option(
        []const u8,
        "example",
        "Example to build (hello / counter / vault / transfer-sol / pda-storage / token-vault / escrow / noop / logonly)",
    ) orelse "counter";

    const linker_choice = b.option(
        []const u8,
        "linker",
        "Backend: elf2sbpf (default CLI) / zig-import (in-process, needs build.zig.zon dep)",
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

    // Step 2: zig cc bridges bitcode → BPF ELF, forwarding
    // -bpf-stack-size to LLVM.
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

    if (std.mem.eql(u8, linker_choice, "elf2sbpf")) {
        // Step 3a: CLI path.
        const elf2sbpf_bin = b.option(
            []const u8,
            "elf2sbpf-bin",
            "Path to the elf2sbpf executable (default: look up on PATH)",
        ) orelse "elf2sbpf";

        const link_program = b.addSystemCommand(&.{
            elf2sbpf_bin, obj_path, program_so_path,
        });
        link_program.step.dependOn(&zig_cc.step);
        b.getInstallStep().dependOn(&link_program.step);
    } else if (std.mem.eql(u8, linker_choice, "zig-import")) {
        // Step 3b: in-process helper that @imports elf2sbpf.
        const elf2sbpf_dep = b.dependency("elf2sbpf", .{
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        });
        const elf2sbpf_mod = elf2sbpf_dep.module("elf2sbpf");

        const linker_exe = b.addExecutable(.{
            .name = "elf2sbpf-link",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/elf2sbpf-link.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
                .imports = &.{
                    .{ .name = "elf2sbpf", .module = elf2sbpf_mod },
                },
            }),
        });

        const run_linker = b.addRunArtifact(linker_exe);
        run_linker.addArg(obj_path);
        run_linker.addArg(program_so_path);
        run_linker.step.dependOn(&zig_cc.step);
        b.getInstallStep().dependOn(&run_linker.step);
    } else {
        @panic("unknown -Dlinker value; expected 'elf2sbpf' or 'zig-import'");
    }

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
