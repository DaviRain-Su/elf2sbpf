# elf2sbpf

[English README](README.md)

一个用 Zig 写的后处理工具，把 BPF ELF 目标文件转换成 Solana SBPF `.so`
程序。目的是让 Zig 开发者构建 Solana 程序时**不需要装 Rust、
`sbpf-linker`，也不需要单独装 LLVM 工具链**。

## 状态

**阶段：C1 MVP 已达成（2026-04-18）；C2（集成 & 上游）进行中**

当前仓库状态：

- `zig build` ✅
- `zig build test --summary all` ✅（362/362 tests，含 9 example byte-diff loop）
- `./scripts/validate-zig.sh` ✅（zignocchio 9/9 example 和 `reference-shim` MATCH）
- GitHub Actions CI ✅（ubuntu-latest + macos-latest）
- `linkProgram()` / CLI 已接通，`elf2sbpf input.o output.so` 可直接使用
- zignocchio 集成草稿：`docs/integrations/zignocchio-build.zig`（实测端到端 MATCH）

**C2 路线图**：fuzz-lite 回归防线 / litesvm 运行时验证 / zignocchio 上游 PR
/ v0.1.0 release。详见 `docs/C2-tasks.md`。

完整背景见 `docs/C0-findings.md`；执行细节见 `docs/C1-tasks.md` /
`docs/C2-tasks.md` / `docs/06-implementation-log.md`。

## 安装 & 使用

```bash
# 拉代码 & 构建（需要 Zig 0.16.0）
git clone https://github.com/DaviRain-Su/elf2sbpf && cd elf2sbpf
zig build -p ~/.local           # 装到 ~/.local/bin/elf2sbpf
export PATH="$HOME/.local/bin:$PATH"

# 用
elf2sbpf input.o output.so
```

macOS arm64 + Linux x86_64 官方支持；其它平台理论可用（Zig 本身跨平台）
但未测试。

完整安装指南：`docs/install.zh.md`。

## 接入到你的 Zig Solana 项目

如果你已经在用 [zignocchio](https://github.com/Solana-ZH/zignocchio)
或类似 Zig-based Solana 框架，可以直接拷
`docs/integrations/zignocchio-build.zig` 到你仓库根目录（替换现有
`build.zig`），然后：

```bash
zig build -Dexample=hello
```

**不再需要** `cargo install sbpf-linker`、`LD_LIBRARY_PATH` hack、
libLLVM.so.20 符号链接 等前置配置。

## 它做什么（和它不做什么）

elf2sbpf 只负责 **stage 2**：ELF 目标文件 → Solana SBPF `.so`。
Stage 1（Zig 源码 → ELF 目标）由 Zig 编译器自己完成，包括通过
`zig cc` 做 LLVM 代码生成。

```text
Zig 源码
  │   zig build-lib -femit-llvm-bc
  ▼
LLVM bitcode (.bc)
  │   zig cc -mllvm -bpf-stack-size=4096 -c
  ▼
BPF ELF 目标文件 (.o)         ← 以上阶段都随 Zig 0.16 一起安装
  │   elf2sbpf                 ← 本工具
  ▼
Solana SBPF .so（可直接部署）
```

elf2sbpf 本身只依赖 Zig 标准库。**它不链接 libLLVM。**
LLVM 的工作在上一阶段的 `zig cc` 里完成，而 `zig cc` 是用户已经
装好的 Zig 编译器自带的。

## 为什么选这条管道

目前 Solana + Zig 的方案要求用户 `cargo install sbpf-linker`
（会拉 LLVM 20 进来，在 LLVM 22 的系统上压根编不过），外加
Linux 特定的 `LD_LIBRARY_PATH` hack。上面这条三阶段管道把这些
都替换成一个用户已经有的东西：**Zig**。

C0 证实了这条管道覆盖 zignocchio 9 个 example 的 100%——包括那些
需要 4KB 栈的（原本以为必须给 Zig 打 patch 或在 elf2sbpf 里嵌
LLVM 才能解决）。具体测量数据和促成这个结论的 `zig cc` bridge
发现，见 `docs/C0-findings.md`。

## 构建命令（端到端，可直接拷贝使用）

```bash
# 1. Zig → LLVM bitcode（还没跑 codegen）
zig build-lib \
  -target bpfel-freestanding -mcpu=v2 -O ReleaseSmall \
  -femit-llvm-bc=program.bc -fno-emit-bin \
  --dep sdk -Mroot=lib.zig -Msdk=sdk.zig

# 2. zig cc → BPF ELF（LLVM 用 Solana 的 4KB 栈预算做 codegen）
zig cc \
  -target bpfel-freestanding -mcpu=v2 -O2 \
  -mllvm -bpf-stack-size=4096 \
  -c program.bc -o program.o

# 3. elf2sbpf → Solana .so
elf2sbpf program.o program.so
```

三个关键 flag：

- `-mcpu=v2` —— Solana SBPF 的特性集（`+alu32`、禁用 `jmp32`、
  禁用 `v4`）
- `-mllvm -bpf-stack-size=4096` —— Solana 给每个栈帧 4KB；LLVM
  默认的 512B 是给 Linux 内核 eBPF 用的，会拒绝真实的 Solana 程序
- `-femit-llvm-bc ... -fno-emit-bin` —— 让 Zig 停在 bitcode，
  LLVM 的栈检查不会在这里触发，要等到 `zig cc` 用上面那个 flag
  跑 codegen 时才跑

## 定位

elf2sbpf **不是** Rust `sbpf-linker` 的 drop-in 替代品。
它只覆盖 stage 2。前面的对照表仍然有效：

| 阶段 | 输入           | 输出       | 负责方                           |
|------|----------------|------------|----------------------------------|
| 1    | `.bc` bitcode  | ELF `.o`   | Zig 编译器 + `zig cc`            |
| 2    | ELF `.o`       | SBPF `.so` | **elf2sbpf**                     |

任何能产出 BPF ELF 的 LLVM 前端（Zig、clang、rustc 加
`--emit=obj`）都能把 `.o` 直接喂给 elf2sbpf。`zig cc` bridge
是 Zig 管道的特定做法，不是 elf2sbpf 本身的硬性要求。

## 参考

从下面这两个 Rust 实现港过来：

- `github.com/blueshift-gg/sbpf-linker`（byteparser + CLI）
- `github.com/blueshift-gg/sbpf`（common + assembler crates）

`reference-shim/` 目录下有一个 Rust 参考 shim——它实现了同样的
stage 2 逻辑，但不依赖 bpf-linker 也不依赖 libLLVM，在 C1 阶段
作为 oracle 使用（Zig 港每个测试 case 的输出都必须跟 shim 输出
`cmp` 相等）。

## Scope（C1 MVP）

**已完成：**

- ✅ SbpfArch V0
- ✅ `.text` + `.rodata` sections，包括多字符串的 `.rodata.str1.1`
- ✅ `lddw` 和 `call` relocation
- ✅ 改进版 rodata gap-fill：在每个 `lddw` 目标偏移处切分 section，
  让 Zig/clang 默认产出的 `.rodata.str1.1` 在**没有具名字符串符号**时也能工作
- ✅ zignocchio 9/9 example 经过 `zig cc` bridge 后，Zig 产物与
  `reference-shim` 字节一致

**明确推迟到后续：**

- ⏭️ SbpfArch V3
- ⏭️ Debug info（`.debug_*`）保留
- ⏭️ 动态 syscall 解析

## 验证

- 全量验证：`./scripts/validate-zig.sh`
- 单个 example：`./scripts/validate-zig.sh hello`
- 当前结果：`validate-zig.sh` 对 9/9 example 全绿
- 脚本说明：`scripts/README.md`

## License

MIT。见 `LICENSE`。
