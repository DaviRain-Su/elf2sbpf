# elf2sbpf

[中文 README](README.zh.md)

A post-processing tool written in Zig that converts BPF ELF object files into
Solana SBPF `.so` programs. The goal is to let Zig developers build Solana
programs **without installing Rust, `sbpf-linker`, or a separate LLVM toolchain**.

## Status

**Stage: C1 MVP completed (2026-04-18); C2 (integration & upstreaming) in progress**

Current repository status:

- `zig build` ✅
- `zig build test --summary all` ✅ (362/362 tests, including the 9-example byte-diff loop)
- `./scripts/validate-zig.sh` ✅ (all 9 zignocchio examples MATCH `reference-shim`)
- GitHub Actions CI ✅ (`ubuntu-latest` + `macos-latest`)
- `linkProgram()` and the CLI are fully wired; `elf2sbpf input.o output.so` works directly
- zignocchio integration draft: `docs/integrations/zignocchio-build.zig` (verified end-to-end MATCH)

**C2 roadmap**: fuzz-lite regression guardrail / litesvm runtime validation /
zignocchio upstream PR / v0.1.0 release. See `docs/C2-tasks.md`.

For full background, see `docs/C0-findings.md`. For execution details, see
`docs/C1-tasks.md`, `docs/C2-tasks.md`, and `docs/06-implementation-log.md`.

## Install & Use

```bash
# Clone and build (requires Zig 0.16.0)
git clone https://github.com/DaviRain-Su/elf2sbpf && cd elf2sbpf
zig build -p ~/.local           # installs to ~/.local/bin/elf2sbpf
export PATH="$HOME/.local/bin:$PATH"

# Use
elf2sbpf input.o output.so
```

Officially supported on macOS arm64 and Linux x86_64. Other platforms should
work in theory thanks to Zig's portability, but are untested.

Full installation guide: `docs/install.md`.

## Integrating into your Zig Solana project

If you are already using [zignocchio](https://github.com/Solana-ZH/zignocchio)
or a similar Zig-based Solana framework, you can copy
`docs/integrations/zignocchio-build.zig` into your repository root (replacing
your existing `build.zig`), then run:

```bash
zig build -Dexample=hello

# optional: in-process Zig dependency mode
zig build -Dexample=hello -Dlinker=zig-import
```

This removes the need for `cargo install sbpf-linker`, `LD_LIBRARY_PATH` hacks,
and `libLLVM.so.20` symlink workarounds. The default path uses the `elf2sbpf`
CLI; `-Dlinker=zig-import` is also available if you want to consume elf2sbpf as
an in-process Zig dependency.

## What it does — and what it does not do

elf2sbpf only handles **stage 2**: ELF object file → Solana SBPF `.so`.
Stage 1 (Zig source → ELF object) is handled by the Zig compiler itself,
including LLVM code generation via `zig cc`.

```text
Zig source
  │   zig build-lib -femit-llvm-bc
  ▼
LLVM bitcode (.bc)
  │   zig cc -mllvm -bpf-stack-size=4096 -c
  ▼
BPF ELF object (.o)             ← provided by Zig 0.16
  │   elf2sbpf                  ← this tool
  ▼
Solana SBPF .so (deployable)
```

elf2sbpf itself depends only on the Zig standard library. **It does not link
against libLLVM.** LLVM work happens in the earlier `zig cc` stage, and
`zig cc` already ships with the user's Zig compiler.

## Why this pipeline

Today, the common Solana + Zig workflow requires users to `cargo install
sbpf-linker` (which pulls in LLVM 20 and often fails on systems with LLVM 22),
plus Linux-specific `LD_LIBRARY_PATH` hacks. This 3-stage pipeline replaces all
of that with one thing the user already has: **Zig**.

C0 confirmed that this pipeline covers 100% of zignocchio's 9 examples —
including programs that need a 4KB stack budget, which previously looked like
they would require either Zig patches or embedding LLVM into elf2sbpf. For the
measurement details and the `zig cc` bridge discovery that enabled this, see
`docs/C0-findings.md`.

## Build commands (end-to-end, ready to copy)

```bash
# 1. Zig → LLVM bitcode (before final codegen)
zig build-lib \
  -target bpfel-freestanding -mcpu=v2 -O ReleaseSmall \
  -femit-llvm-bc=program.bc -fno-emit-bin \
  --dep sdk -Mroot=lib.zig -Msdk=sdk.zig

# 2. zig cc → BPF ELF (LLVM codegen with Solana's 4KB stack budget)
zig cc \
  -target bpfel-freestanding -mcpu=v2 -O2 \
  -mllvm -bpf-stack-size=4096 \
  -c program.bc -o program.o

# 3. elf2sbpf → Solana .so
elf2sbpf program.o program.so
```

Three important flags:

- `-mcpu=v2` — Solana SBPF feature set (`+alu32`, JMP32 disabled, no `v4`)
- `-mllvm -bpf-stack-size=4096` — Solana allows 4KB per stack frame; LLVM's
  default 512B is for Linux kernel eBPF and rejects real Solana programs
- `-femit-llvm-bc ... -fno-emit-bin` — stops Zig at bitcode emission; LLVM
  stack checks are triggered later when `zig cc` performs codegen with the flag above

## Positioning

elf2sbpf is **not** a drop-in replacement for Rust `sbpf-linker`.
It only covers stage 2. The pipeline breakdown is still:

| Stage | Input        | Output      | Responsible component            |
|------:|--------------|-------------|----------------------------------|
| 1     | `.bc` bitcode| ELF `.o`    | Zig compiler + `zig cc`          |
| 2     | ELF `.o`     | SBPF `.so`  | **elf2sbpf**                     |

Any LLVM frontend that can emit BPF ELF objects (Zig, clang, rustc with
`--emit=obj`) can feed `.o` files directly into elf2sbpf. The `zig cc` bridge
is specific to the Zig workflow; it is not a hard requirement of elf2sbpf
itself.

## Reference

This project ports logic from the following Rust implementations:

- `github.com/blueshift-gg/sbpf-linker` (byteparser + CLI)
- `github.com/blueshift-gg/sbpf` (common + assembler crates)

The `reference-shim/` directory contains a Rust reference shim that implements
the same stage-2 logic without depending on `sbpf-linker` or libLLVM. During
C1 it serves as the oracle: every Zig test case must produce output identical
to the shim under `cmp`.

## Scope (C1 MVP)

**Completed:**

- ✅ SbpfArch V0
- ✅ `.text` + `.rodata` sections, including multi-string `.rodata.str1.1`
- ✅ `lddw` and `call` relocations
- ✅ Improved rodata gap-fill: split sections at each `lddw` target offset so
  Zig/clang-produced `.rodata.str1.1` works even without named string symbols
- ✅ All 9 zignocchio examples, via the `zig cc` bridge, produce byte-identical
  output to `reference-shim`

**Explicitly deferred:**

- ⏭️ SbpfArch V3
- ⏭️ Debug info (`.debug_*`) preservation
- ⏭️ Dynamic syscall resolution

## Validation

- Full validation: `./scripts/validate-zig.sh`
- Single example: `./scripts/validate-zig.sh hello`
- Current result: all 9 examples are green in `validate-zig.sh`
- Script notes: `scripts/README.md`

## License

MIT. See `LICENSE`.
