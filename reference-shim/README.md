# reference-shim

一个最小化的 Rust 二进制，只调用 sbpf-linker 的 **stage 2**——
`byteparser::parse_bytecode` + `sbpf_assembler::Program::emit_bytecode`——
不依赖 bpf-linker，也不依赖 libLLVM。

## 用途

这个**不是** elf2sbpf。elf2sbpf 会用 Zig 写。

这个 Rust 二进制存在的理由是：

1. **证据**（来自 C0 阶段）：stage 2 是自足的。Zig 产出的 `.o` 喂给这个
   shim 得到的 `.so`，跟走完整 Rust 管道产出的 `.so` **字节完全一致**。
   见 `../docs/C0-findings.md`。

2. **Oracle**（C1 阶段用）：每次把 stage 2 的一块逻辑 port 成 Zig，
   就把同一个输入同时喂进这个 shim 和 Zig 港，字节级对比。一致就是对的。

## 构建

```bash
cargo build --release
```

不需要 LLVM。大约 1.7 秒。

## 使用

```bash
./target/release/elf2sbpf-shim input.o output.so
```

## 什么时候可以删

当 elf2sbpf 对所有 zignocchio example 跟这个 shim 字节对等，
这个目录就可以移除了。
