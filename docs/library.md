# Using elf2sbpf as a Zig library

Since v0.3.0, elf2sbpf exposes its core as a Zig module that downstream
projects can `@import`. This is faster and cleaner than shelling out to
the CLI binary — the whole build graph stays in one process.

## Add it as a dependency

```bash
# In your project root (pin to whichever release you want;
# v0.5.0 is the latest as of this document).
zig fetch --save git+https://github.com/DaviRain-Su/elf2sbpf#v0.5.0
```

This appends an entry to your `build.zig.zon`:

```zig
.dependencies = .{
    .elf2sbpf = .{
        .url = "git+https://github.com/DaviRain-Su/elf2sbpf#v0.5.0",
        .hash = "...",  // filled in by `zig fetch --save`
    },
},
```

## Wire it into your build.zig

```zig
const elf2sbpf_dep = b.dependency("elf2sbpf", .{
    .target = target,
    .optimize = optimize,
});
const elf2sbpf_mod = elf2sbpf_dep.module("elf2sbpf");

const exe = b.addExecutable(.{
    .name = "my-tool",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "elf2sbpf", .module = elf2sbpf_mod },
        },
    }),
});
```

## Call the API

```zig
const std = @import("std");
const elf2sbpf = @import("elf2sbpf");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Read a BPF ELF .o into memory.
    const io = init.io;
    const elf_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io, "input.o", gpa, .limited(std.math.maxInt(usize))
    );
    defer gpa.free(elf_bytes);

    // Convert to Solana SBPF .so bytes.
    const so_bytes = try elf2sbpf.linkProgram(gpa, elf_bytes);
    defer gpa.free(so_bytes);

    // Write out.
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "output.so",
        .data = so_bytes,
    });
}
```

`linkProgram` returns a `LinkError` variant on failure. Every member of
that error set is stable across v0.x — see
[`src/lib.zig`](https://github.com/DaviRain-Su/elf2sbpf/blob/main/src/lib.zig)
for the full list.

## Custom syscalls (since v0.4.0)

By default, elf2sbpf knows about the 30 built-in Solana syscalls (see
`REGISTERED_SYSCALLS` in `src/common/syscalls.zig`). If your program
uses a custom syscall — e.g. a Solana runtime fork, a research VM, or
an experimental sBPF opcode — register the extra names via
`linkProgramWithSyscalls`:

```zig
const extras = [_][]const u8{
    "my_custom_cpi",
    "my_experimental_hash",
};
const so_bytes = try elf2sbpf.linkProgramWithSyscalls(gpa, elf_bytes, &extras);
```

Behavior:

- Matching is by murmur3_32 hash (same algorithm Solana uses)
- Built-ins are always checked first; extras are consulted after
- For programs that only call built-ins, output is byte-identical to
  `linkProgram` (the extras are simply unused)
- The extras slice is borrowed for the call — caller retains ownership
  and can free immediately after `linkProgramWithSyscalls` returns

Internally this sets a thread-local that `Instruction.fromBytes`
consults when resolving `call src=0, imm=<hash>` instructions. The
thread-local is saved/restored around the call, so concurrent or
nested `linkProgram*` invocations don't leak state.

## Stable surface

The following are considered part of the public API and covered by
SemVer (no breaking changes within v0.x):

| Symbol | Shape | Stable? |
|---|---|---|
| `elf2sbpf.linkProgram(allocator, elf_bytes)` | `LinkError![]u8` | ✅ yes |
| `elf2sbpf.linkProgramV3(allocator, elf_bytes)` | `LinkError![]u8` | ✅ yes (since v0.5.0) |
| `elf2sbpf.linkProgramWithSyscalls(allocator, elf_bytes, extras)` | `LinkError![]u8` | ✅ yes (since v0.4.0) |
| `elf2sbpf.LinkError` | error set | ✅ yes |
| `elf2sbpf.Program` | struct (read-only) | ✅ for inspection |
| `elf2sbpf.Program.fromParseResult` | constructor | ✅ yes |
| `elf2sbpf.Program.emitBytecode` | method | ✅ yes |
| `elf2sbpf.ParseResult` / `elf2sbpf.AST` | sub-structures | ⚠️ shape may evolve |
| `elf2sbpf.SbpfArch` | enum (V0 / V3) | ✅ yes |
| `elf2sbpf.Instruction` | struct | ⚠️ field-level details churny; only treat as opaque |
| `elf2sbpf.byteparser.*` | internal layer | ⚠️ surface may reshape across v0.x |

**Rule of thumb**: `linkProgram` is the intended public entry point.
Deeper types are re-exported for framework authors who want custom
post-processing (e.g. debug-info stripping, symbol filtering, custom
section reordering), but those pieces can move between minor versions.

## Why use the library over the CLI?

- **No subprocess overhead**: `linkProgram` runs in-process; no
  `argv` marshalling, no `fork` / `exec`, no file I/O for the
  intermediate bytes
- **Better error handling**: you catch typed `LinkError` values
  instead of parsing CLI exit codes
- **Introspection**: you can hold onto the `Program` after
  `fromParseResult` and inspect sections, symbols, program headers
  before calling `emitBytecode`
- **Build graph composition**: in a `build.zig`, calling
  `linkProgram` inside a `b.addWriteFiles` / custom step lets you
  chain further transformations without temp-file dances

## Why use the CLI over the library?

- **Cross-language projects**: if your build driver is Make / Bazel
  / shell, `elf2sbpf in.o out.so` is one line
- **Opaque oracle**: release-channel binaries are checksum-verified;
  the Zig module tracks HEAD-like semantics
- **Non-Zig downstream**: you can't `@import` from Python / Rust /
  Go, so the CLI is the only option

Both paths produce byte-identical output.
