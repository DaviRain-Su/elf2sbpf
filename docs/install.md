# Installing elf2sbpf

[中文版本](install.zh.md)

Choose one of these three approaches depending on your workflow:

| Scenario | Method | Command |
|------|------|------|
| Development / daily use | Build from source into `~/.local` | `zig build -p ~/.local` |
| CI / one-off use | Build in place without installing | `zig build && ./zig-out/bin/elf2sbpf ...` |
| System-wide (`/usr/local`) | Install with sudo | `sudo zig build -p /usr/local` |

## Prerequisite

You only need **one thing**: [Zig 0.16.0](https://ziglang.org/download/)

Here is what elf2sbpf does **not** require:

- ❌ Rust / cargo / rustup
- ❌ `cargo install sbpf-linker`
- ❌ A separately installed LLVM (`brew install llvm` / `apt install llvm-20`)
- ❌ `LD_LIBRARY_PATH` or `libLLVM.so` symlink hacks

The Zig compiler already bundles `zig cc` (a drop-in clang) and libLLVM, so
once Zig is installed, the LLVM codegen capability you need is already there.

## Build from source (recommended)

```bash
git clone https://github.com/DaviRain-Su/elf2sbpf
cd elf2sbpf

# Build + install to ~/.local/bin/elf2sbpf
zig build -p ~/.local

# Make sure ~/.local/bin is on PATH
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc   # or ~/.bashrc
source ~/.zshrc

# Verify
elf2sbpf --help 2>&1 | head -3
```

On macOS arm64 the binary is roughly ~1.8 MB and statically linked. `otool -L`
will confirm that it does not link against libLLVM, because elf2sbpf itself
never performs codegen.

## Ten-minute quick start

Assume you already have a BPF ELF `.o` file produced by `zig cc`, `clang`, or
`rustc --emit=obj`:

```bash
# Use the repository's hello.o as an example
elf2sbpf src/testdata/hello.o /tmp/hello.so

# Output is byte-identical to reference-shim
cmp /tmp/hello.so src/testdata/hello.shim.so
echo $?   # 0 = MATCH
```

You can then deploy the `.so` to Solana with:

```bash
solana program deploy /tmp/hello.so
```

## From scratch (Zig source → .so)

```bash
# Stage 1: Zig source → LLVM bitcode
zig build-lib \
  -target bpfel-freestanding -mcpu=v2 -O ReleaseSmall \
  -femit-llvm-bc=program.bc -fno-emit-bin \
  -Mroot=program.zig

# Stage 2: bitcode → BPF ELF (using Solana's 4KB stack budget)
zig cc \
  -target bpfel-freestanding -mcpu=v2 -O2 \
  -mllvm -bpf-stack-size=4096 \
  -c program.bc -o program.o

# Stage 3: BPF ELF → Solana SBPF .so (this is the only step elf2sbpf handles)
elf2sbpf program.o program.so
```

This is a 3-stage pipeline with zero external dependencies. The older
`sbpf-linker` workflow used 2 stages, but required Rust + cargo + libLLVM.so.20.

## Why not `cargo install sbpf-linker`?

Short version: `sbpf-linker` embeds LLVM logic into a Rust binary and uses
`aya-rustc-llvm-proxy` to dynamically load libLLVM at runtime. That creates
three problems:

1. **LLVM version lock-in**:
   sbpf-linker is pinned to LLVM 20, while Zig 0.16 already tracks LLVM 21+.
   Once the system LLVM moves, sbpf-linker tends to break.
2. **Linux-specific hacks**:
   many distros only expose version-suffixed `libLLVM.so` files such as
   `libLLVM.so.20.1`, which the proxy cannot find. Users end up creating manual
   symlinks like:
   `ln -sf .../libLLVM.so.20.1 .zig-cache/llvm_fix/libLLVM.so`
3. **Two toolchains instead of one**:
   users must install Rust just to build Solana programs from Zig, which is a
   poor developer experience.

The `zig cc` bridge (`zig build-lib -femit-llvm-bc` followed by
`zig cc -mllvm -bpf-stack-size=4096 -c`) avoids all three issues. LLVM stays
hidden inside Zig, version drift follows Zig naturally, and there is no
standalone `libLLVM.so` lookup problem.

## Using it as a Zig project dependency

elf2sbpf is currently published as a CLI. If you want to import it as a Zig
library (Epic D.4), you currently need to vendor it manually:

```bash
mkdir -p vendor/elf2sbpf
cp -r /path/to/elf2sbpf/src vendor/elf2sbpf/
# then add a module in build.zig
```

Whether the API is stable enough to be used as a public Zig library dependency
will be evaluated after C2 is complete.

## Upgrade / uninstall

```bash
# Upgrade (pull latest code + reinstall)
cd elf2sbpf && git pull && zig build -p ~/.local

# Uninstall
rm ~/.local/bin/elf2sbpf
```

## Troubleshooting

- **`zig: command not found`**: install Zig 0.16.0 first
- **Version mismatch**: `zig version` must be 0.16.x; 0.15 / 0.17 are unsupported
- **`Illegal instruction` at deployment time**: this is likely an ELF layout
  issue; run `./scripts/validate-zig.sh <example>` against the shim to check
  whether you hit a regression
- **`libLLVM.so` symlink hacks in zignocchio `build.zig`**: if you switch to
  the elf2sbpf-based build draft, you no longer need them and can remove them

For deeper issues, please open an issue.
