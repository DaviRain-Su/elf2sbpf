// zignocchio build.zig — elf2sbpf integration draft
//
// Drop-in replacement for the sbpf-linker-based build. The only hard
// dependency this adds is the `elf2sbpf` executable on PATH (or built
// alongside). No libLLVM, no Rust, no cargo, no rustup, no LD_LIBRARY_PATH
// jiggling — everything fits inside a single Zig 0.16 install.
//
// Pipeline:
//
//   1. `zig build-lib -femit-llvm-bc -fno-emit-bin`  → entrypoint.bc
//   2. `zig cc -c entrypoint.bc -mllvm -bpf-stack-size=4096`  → entrypoint.o
//   3. `elf2sbpf entrypoint.o program.so`  → Solana SBPF .so
//
// Why a separate `zig cc` step? `zig build-lib` reports "stack size
// exceeded" for any non-trivial Solana program (the LLVM BPF backend
// defaults to the 512-byte Linux kernel stack limit). `zig cc` forwards
// `-mllvm -bpf-stack-size=4096` to LLVM so codegen respects Solana's
// 4 KB stack. See docs/pipeline.md in the elf2sbpf repo for the full
// reasoning.
//
// To adopt in zignocchio:
//   1. Replace the current build.zig with this file.
//   2. Ensure `elf2sbpf` is on PATH OR set ELF2SBPF_BIN below to an
//      absolute path (e.g. `/path/to/elf2sbpf/zig-out/bin/elf2sbpf`).
//   3. `zig build -Dexample=hello && ls zig-out/lib/hello.so`
//
// The sbpf-linker path can coexist during migration: pass
// `-Dlinker=sbpf-linker` to keep the old behavior while this builds up
// confidence. Remove the flag + the old branch once CI is green.

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
        "Backend: elf2sbpf (default) or sbpf-linker (legacy)",
    ) orelse "elf2sbpf";

    const example_path = b.fmt("examples/{s}/lib.zig", .{example_name});

    // Step 1: Zig → LLVM bitcode. Same as the legacy build.
    const bitcode_path = "entrypoint.bc";
    const gen_bitcode = b.addSystemCommand(&.{
        "zig",                             "build-lib",
        "-target",                         "bpfel-freestanding",
        "-O",                              "ReleaseSmall",
        "-femit-llvm-bc=" ++ bitcode_path, "-fno-emit-bin",
        "--dep",                           "sdk",
        b.fmt("-Mroot={s}", .{example_path}),
        "-Msdk=sdk/zignocchio.zig",
    });

    const mkdir_step = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/lib" });

    const program_so_path = b.fmt("zig-out/lib/{s}.so", .{example_name});

    if (std.mem.eql(u8, linker_choice, "elf2sbpf")) {
        // Step 2: zig cc bridges bitcode → BPF ELF, forwarding
        // -bpf-stack-size to LLVM. This replaces sbpf-linker's implicit
        // LLVM codegen step.
        const obj_path = b.fmt("zig-out/lib/{s}.o", .{example_name});
        const zig_cc = b.addSystemCommand(&.{
            "zig",                 "cc",
            "-target",             "bpfel-freestanding",
            "-mcpu=v2",            "-O2",
            "-mllvm",              "-bpf-stack-size=4096",
            "-c",                  bitcode_path,
            "-o",                  obj_path,
        });
        zig_cc.step.dependOn(&gen_bitcode.step);
        zig_cc.step.dependOn(&mkdir_step.step);

        // Step 3: elf2sbpf ELF → Solana SBPF .so. Zero external deps.
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
    } else if (std.mem.eql(u8, linker_choice, "sbpf-linker")) {
        // Legacy path — kept behind `-Dlinker=sbpf-linker` for fallback.
        // Requires Rust, cargo, and libLLVM.so.20 (usually via
        // `cargo install sbpf-linker`).
        const link_program = b.addSystemCommand(&.{
            "sbpf-linker",
            "--cpu",               "v2",
            "--llvm-args=-bpf-stack-size=4096",
            "--export",            "entrypoint",
            "-o",                  program_so_path,
            bitcode_path,
        });
        link_program.step.dependOn(&gen_bitcode.step);
        link_program.step.dependOn(&mkdir_step.step);

        // On some distros libLLVM is only shipped as a versioned .so; the
        // sbpf-linker proxy loads plain `libLLVM.so`. Work around by
        // symlinking into a cache dir and setting LD_LIBRARY_PATH.
        const llvm_fix_dir = ".zig-cache/llvm_fix";
        const mkdir_llvm_fix = b.addSystemCommand(&.{ "mkdir", "-p", llvm_fix_dir });
        const llvm_symlink = b.addSystemCommand(&.{
            "ln",    "-sf",
            "/usr/lib/x86_64-linux-gnu/libLLVM.so.20.1",
            b.fmt("{s}/libLLVM.so", .{llvm_fix_dir}),
        });
        llvm_symlink.step.dependOn(&mkdir_llvm_fix.step);
        link_program.step.dependOn(&llvm_symlink.step);

        const prev_ld_path = b.graph.environ_map.get("LD_LIBRARY_PATH") orelse "";
        const ld_library_path = if (prev_ld_path.len > 0)
            b.fmt("{s}:{s}", .{ llvm_fix_dir, prev_ld_path })
        else
            llvm_fix_dir;
        link_program.setEnvironmentVariable("LD_LIBRARY_PATH", ld_library_path);

        b.getInstallStep().dependOn(&link_program.step);
    } else {
        @panic("unknown -Dlinker value; expected 'elf2sbpf' or 'sbpf-linker'");
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
