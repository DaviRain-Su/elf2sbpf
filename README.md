# elf2sbpf

[中文 README](README.zh.md)

A post-processing tool written in Zig that converts BPF ELF object files into
Solana SBPF `.so` programs. The goal is to let Zig developers build Solana
programs **without installing Rust, `sbpf-linker`, or a separate LLVM toolchain**.

## Status

**Latest release: [v0.5.0](https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.5.0) — SbpfArch V3 end-to-end (2026-04-18)**

All C1 / C2 / D-stage targets are shipped:

- `zig build` ✅
- `zig build test --summary all` ✅ (378/378 tests: unit + V0 9-example sweep + V3 9-example sweep + debug-info + fuzz-lite + adversarial-ELF)
- `./scripts/validate-zig.sh` ✅ (9 zignocchio examples MATCH `reference-shim`)
- GitHub Actions CI ✅ (`ubuntu-latest` + `macos-latest`)
- `linkProgram` / `linkProgramV3` / `linkProgramWithSyscalls` library API + CLI with `--v0` / `--v3` flags
- zignocchio upstream Draft PR: [Solana-ZH/zignocchio#1](https://github.com/Solana-ZH/zignocchio/pull/1)

**Supported targets**: SBPF **V0** (default) and **V3** (since v0.5.0). Byte-identical
to `reference-shim` on all 9 zignocchio examples for both arches (+ a
debug-info fixture under V0).

**Release history**: v0.1 (C1+C2 MVP) → v0.2 (debug info) → v0.3 (Zig library API)
→ v0.4 (custom syscall registry) → v0.5 (V3 arch).

For full background, see `docs/C0-findings.md`. For execution details, see
`docs/C1-tasks.md`, `docs/C2-tasks.md`, `docs/D-tasks.md`,
`docs/06-implementation-log.md`, and `docs/decisions.md` (ADRs).

## Install & Use

### Local install

```bash
# Requires Zig 0.16.0
git clone https://github.com/DaviRain-Su/elf2sbpf && cd elf2sbpf
zig build -p ~/.local           # installs to ~/.local/bin/elf2sbpf
export PATH="$HOME/.local/bin:$PATH"

# Verify
elf2sbpf --help
```

### CI / one-off use

Yes — `elf2sbpf` works in CI. The simplest pattern is to build it inside the
job and invoke the binary from `zig-out/bin/elf2sbpf`.

```bash
# inside CI
zig build
./zig-out/bin/elf2sbpf input.o output.so
```

Example GitHub Actions snippet:

```yaml
- uses: actions/checkout@v4

- uses: mlugg/setup-zig@v2
  with:
    version: 0.16.0

- name: Build elf2sbpf
  run: zig build

- name: Use elf2sbpf
  run: ./zig-out/bin/elf2sbpf input.o output.so
```

If another repository needs `elf2sbpf` during CI, either:

1. check out this repository and run `zig build`, then pass the absolute path to
   `zig-out/bin/elf2sbpf`, or
2. install it into a prefix with `zig build -p <prefix>` and add `<prefix>/bin`
   to `PATH`.

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

The `reference-shim/` directory contains a Rust reference shim that
implements the same stage-2 logic without depending on `sbpf-linker` or
libLLVM. It is the **byte-equivalence oracle**: every Zig golden under
`src/testdata/` was generated by the shim, and `scripts/validate-zig.sh`
compares fresh elf2sbpf output against it. The shim's `--v3` flag
(added in v0.5.0) gives us the V3 oracle too. Keeping it in-tree is
documented as [ADR-002](docs/decisions.md).

## Scope

**Supported (C1 + D stages, through v0.5.0):**

- ✅ SbpfArch **V0** (dynamic linking — PT_DYNAMIC, dynsym / dynstr / rel.dyn)
- ✅ SbpfArch **V3** (static layout, fixed vaddrs, no PT_DYNAMIC — since v0.5.0)
- ✅ `.text` + `.rodata` sections, including multi-string `.rodata.str1.1`
- ✅ `lddw` and `call` relocations
- ✅ Improved rodata gap-fill: split sections at each `lddw` target offset so
  Zig/clang-produced `.rodata.str1.1` works even without named string symbols
- ✅ `.debug_*` preservation (abbrev / info / line / line_str / str / frame / loc / ranges — whitelist matches Rust; since v0.2.0)
- ✅ Custom syscall registry via `linkProgramWithSyscalls` (thread-local extras on top of the 30 built-in Solana syscalls; since v0.4.0)
- ✅ Zig library API: `@import("elf2sbpf")` + `linkProgram` / `linkProgramV3` / `linkProgramWithSyscalls` (since v0.3.0)
- ✅ All 9 zignocchio examples byte-identical to `reference-shim` under **both V0 and V3**; plus a debug-info fixture

**Out of scope (not going to do):**

- ❌ Assembly text parser (`.sbpf` source → bytecode) — ELF input only
- ❌ DWARF synthesis from supplied `DebugData` — we only reuse existing `.debug_*`
- ❌ Multi translation-unit LTO — delegated to `zig cc` / upstream compilers
- ❌ BPF bytecode validator / VM executor — we are a linker, not a runtime
- ❌ LLVM version tracking / custom LLVM passes — we don't link libLLVM at all

**Pending ecosystem demand:**

- ⏭️ Windows support (D.5)
- ⏭️ Cross-language frontends beyond the ELF input surface (D.6 strategic vision)

## Validation

- `zig build test` — 378/378 unit + integration tests (runs on every CI push)
- `./scripts/validate-zig.sh` — 9/9 zignocchio examples (requires local
  zignocchio checkout); both V0 and V3 arches covered via the shim's
  `--v0` / `--v3` flag
- `./scripts/validate-zig.sh hello` — single example
- `./scripts/fuzz/run.sh 100` — randomized regression harness (160/160 MATCH
  baseline); recommended before any byteparser / emit PR
- Script notes: `scripts/README.md`

## License

MIT. See `LICENSE`.
