# elf2sbpf Build Pipeline

[中文版本](pipeline.zh.md)

A reference document focused on the actual build flow. For the full C0
validation process and the reasoning behind each decision, see
`C0-findings.md`.

## Pipeline at a glance

```text
┌─────────────────────────────────────────────────────────────────┐
│                  Everything below ships with Zig 0.16           │
│                                                                 │
│   Zig source       ┌──── zig build-lib ────┐                    │
│      │             │  -target bpfel-...    │                    │
│      ▼             │  -mcpu=v2             │                    │
│                    │  -femit-llvm-bc       │                    │
│   LLVM bitcode     │  -fno-emit-bin        │                    │
│      │             └───────────────────────┘                    │
│      ▼                                                          │
│                    ┌──── zig cc ───────────┐                    │
│                    │  -target bpfel-...    │                    │
│                    │  -mcpu=v2             │                    │
│   BPF ELF .o       │  -mllvm               │                    │
│      │             │  -bpf-stack-size=4096 │                    │
│      ▼             │  -c in.bc -o out.o    │                    │
│                    └───────────────────────┘                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
       │
       │  (this is where we leave the Zig-bundled part)
       ▼
 ┌────────────────────────────────────────┐
 │  elf2sbpf (Zig implementation, here)   │
 │                                        │
 │  - reads BPF ELF                       │
 │  - runs byteparser logic               │
 │  - emits Solana SBPF bytes             │
 │                                        │
 │  no libLLVM, no Rust, zero external deps │
 └────────────────────────────────────────┘
       │
       ▼
   Solana SBPF .so (deploy with `solana program deploy`)
```

## Why each stage exists

### Stage 1: `zig build-lib -femit-llvm-bc`

The Zig frontend compiles `.zig` source down to LLVM IR and writes it out as
LLVM bitcode. Because `-fno-emit-bin` is passed, Zig **skips final codegen**.
That means target-specific LLVM checks, including BPF stack-size limits,
**have not run yet**.

### Stage 2: `zig cc -mllvm -bpf-stack-size=4096 -c in.bc -o out.o`

`zig cc` is Zig's bundled drop-in clang. Unlike `zig build-*`, it **does**
forward `-mllvm` directly to LLVM. Feeding the stage-1 bitcode into it lets
LLVM perform BPF codegen with Solana's real 4096-byte stack limit, instead of
LLVM's default 512-byte limit for Linux kernel eBPF.

**This stage is the key reason the Zig-only pipeline can handle real Solana
programs.** Without the `zig cc` bridge, larger programs — anything touching
multiple accounts or SPL Token state — fail during codegen and force users back
onto `sbpf-linker`.

### Stage 3: `elf2sbpf`

This converts a BPF ELF object (`.o`) into the final Solana SBPF `.so` layout.
It performs tasks such as:

- rewriting `lddw` immediates to point at rodata labels
- rewriting `call` immediates to point at text labels, or to a `murmur3-32`
  hash for dynamic syscalls
- synthesizing `.rodata.__anon_<section>_<offset>` entries for unnamed rodata
  byte ranges (for example Zig/clang-generated `.rodata.str1.1`, which often
  contains only `STT_SECTION` symbols and no named string symbols)
- building the final SBPF ELF with Solana-specific program headers, dynamic
  section, and section layout

Stage 3 is pure Zig: no LLVM, no Rust. This is elf2sbpf's actual domain.

## Flag quick reference

### Zig source compilation stage

| Flag | Required | Why |
|------|------|------|
| `-target bpfel-freestanding` | Yes | Solana VM target: little-endian BPF with no OS |
| `-mcpu=v2` | Yes | Matches Solana SBPF features: `+alu32`, no `jmp32` (`jmp32` opcode `0x16` is rejected by Solana) |
| `-O ReleaseSmall` | Yes | Solana programs have tight size budgets |
| `-femit-llvm-bc=<path>` | Yes | Stage 2 consumes bitcode |
| `-fno-emit-bin` | Yes | Skips Zig's own codegen, avoiding stack checks at this stage |
| `--dep sdk`, `-Mroot=`, `-Msdk=` | Project-specific | zignocchio module wiring; adjust as needed in other projects |

### `zig cc` stage

| Flag | Required | Why |
|------|------|------|
| `-target bpfel-freestanding` | Yes | Same as stage 1 |
| `-mcpu=v2` | Yes | Same as stage 1 |
| `-O2` | Yes | Codegen optimization level |
| `-mllvm -bpf-stack-size=4096` | Yes | Raises BPF stack limit from LLVM's 512B Linux default to Solana's 4096B |
| `-c in.bc -o out.o` | Yes | Compiles bitcode into an ELF object |

### elf2sbpf stage

```
elf2sbpf [--v0 | --v3] <input.o> <output.so>
```

- Positional args: input BPF ELF, output Solana SBPF `.so`
- `--v0` (default) emits the V0 layout (dynamic linking, PT_DYNAMIC +
  dynsym/dynstr/rel.dyn)
- `--v3` (since v0.5.0) emits the V3 static layout (fixed vaddrs, no
  PT_DYNAMIC, static syscall resolution — smaller outputs)

For in-process use from Zig, `@import("elf2sbpf")` and call
`linkProgram` / `linkProgramV3` / `linkProgramWithSyscalls` — see
[`docs/library.md`](library.md).

## So where is LLVM?

A common question is: "Is this really LLVM-free?"

The honest answer is:

- **The elf2sbpf binary**: zero LLVM. It ships as a Zig static binary.
- **`zig cc`**: uses the libclang/libLLVM bundled with Zig. That is **not** a
  separate installation; it is already inside the Zig archive the user has installed.
- **The user system**: only needs one thing, Zig 0.16. No `brew install llvm`,
  no `cargo install sbpf-linker`, no `rustup`, no standalone libLLVM setup.

So if the question is "Do I, as a user, need to manage LLVM?", the answer is:
**No.**
If the question is "Does the pipeline literally contain no LLVM at all?", the
answer is: **It does** — LLVM still performs codegen, because that is how Zig
currently targets BPF. The `zig cc` bridge does not eliminate LLVM; it makes
LLVM stop being a user-visible dependency.

## Validation and scripts

Current validation entry points in this repository:

- `./scripts/validate-zig.sh`: batch or single-example shim-vs-zig validation
- `./scripts/validate-all.sh`: the main implementation of the same validation flow, accepting example arguments
- `./scripts/compare.sh`: compares ELF structure between reference outputs
- `scripts/README.md`: script notes and prerequisites

Common commands:

```bash
./scripts/validate-zig.sh
./scripts/validate-zig.sh hello
./scripts/validate-all.sh hello counter
```
