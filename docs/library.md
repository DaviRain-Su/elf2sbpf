# Using elf2sbpf as a Zig library

Since v0.3.0, elf2sbpf exposes its core as a Zig module that downstream
projects can `@import`. This is faster and cleaner than shelling out to
the CLI binary — the whole build graph stays in one process.

## Add it as a dependency

```bash
# In your project root
zig fetch --save git+https://github.com/DaviRain-Su/elf2sbpf#v0.3.0
```

This appends an entry to your `build.zig.zon`:

```zig
.dependencies = .{
    .elf2sbpf = .{
        .url = "git+https://github.com/DaviRain-Su/elf2sbpf#v0.3.0",
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

## Stable surface

The following are considered part of the public API and covered by
SemVer (no breaking changes within v0.x):

| Symbol | Shape | Stable? |
|---|---|---|
| `elf2sbpf.linkProgram(allocator, elf_bytes)` | `LinkError![]u8` | ✅ yes |
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
