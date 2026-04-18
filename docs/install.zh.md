# 安装 elf2sbpf

[English version](install.md)

三种方式，按你的场景选：

| 场景 | 方法 | 命令 |
|------|------|------|
| 开发 / 日常使用 | 从源码构建到 `~/.local` | `zig build -p ~/.local` |
| CI / 一次性 | 就地构建不装 | `zig build && ./zig-out/bin/elf2sbpf ...` |
| 全局（/usr/local） | sudo 安装 | `sudo zig build -p /usr/local` |

## 前置条件

**只要一样东西**：[Zig 0.16.0](https://ziglang.org/download/)

这里列一下 elf2sbpf **不需要** 什么：

- ❌ Rust / cargo / rustup
- ❌ `cargo install sbpf-linker`
- ❌ 单独安装的 LLVM（`brew install llvm` / `apt install llvm-20`）
- ❌ `LD_LIBRARY_PATH` 或 libLLVM.so 符号链接 hack

Zig 编译器里自带 `zig cc`（drop-in clang）和 libLLVM，所以当你装好
Zig 的时候，所需的 LLVM codegen 能力就已经在了。

## 从源码构建（推荐）

```bash
git clone https://github.com/DaviRain-Su/elf2sbpf
cd elf2sbpf

# 构建 + 安装到 ~/.local/bin/elf2sbpf
zig build -p ~/.local

# 确认 PATH 里有 ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc   # 或 ~/.bashrc
source ~/.zshrc

# 验证
elf2sbpf --help 2>&1 | head -3
```

macOS arm64 产物 ~1.8 MB，静态二进制。`otool -L` 会确认它不链
libLLVM（因为 elf2sbpf 本身不做 codegen）。

## 上手 10 分钟

假设你已经有一个 BPF ELF `.o`（从 `zig cc` / `clang` / `rustc --emit=obj`
出来）：

```bash
# 用仓库里的 hello.o 做示例
elf2sbpf src/testdata/hello.o /tmp/hello.so

# 产物跟 reference-shim 字节一致
cmp /tmp/hello.so src/testdata/hello.shim.so
echo $?   # 0 = MATCH
```

把 `.so` 部署到 Solana 用 `solana program deploy /tmp/hello.so`。

## 从零起步（Zig 源码 → .so）

```bash
# Stage 1: Zig 源码 → LLVM bitcode
zig build-lib \
  -target bpfel-freestanding -mcpu=v2 -O ReleaseSmall \
  -femit-llvm-bc=program.bc -fno-emit-bin \
  -Mroot=program.zig

# Stage 2: bitcode → BPF ELF（用 Solana 的 4KB 栈预算）
zig cc \
  -target bpfel-freestanding -mcpu=v2 -O2 \
  -mllvm -bpf-stack-size=4096 \
  -c program.bc -o program.o

# Stage 3: BPF ELF → Solana SBPF .so（elf2sbpf 只管这一步）
elf2sbpf program.o program.so
```

整个管道：3 步，零外部依赖。之前用 `sbpf-linker` 走的是 2 步，但
需要 Rust + cargo + libLLVM.so.20。

## 为什么不用 cargo install sbpf-linker？

简答：`sbpf-linker` 把 LLVM 打到 Rust 二进制里，用 `aya-rustc-llvm-proxy`
在运行时动态加载 libLLVM。这带来三个问题：

1. **LLVM 版本锁死**：sbpf-linker pin 的是 LLVM 20；但 Zig 0.16 已经
   跟 LLVM 21+ 出来了。系统 LLVM 一升级，sbpf-linker 就坏
2. **Linux 特定 hack**：许多发行版的 `libLLVM.so` 只有版本号后缀的
   文件（`libLLVM.so.20.1`），sbpf-linker 的 proxy 找不到。得
   `ln -sf .../libLLVM.so.20.1 .zig-cache/llvm_fix/libLLVM.so`
3. **双工具链**：用户得先装 Rust 才能“给 Zig 构建 Solana 程序”，
   这从 DX 看很别扭

`zig cc` bridge（`zig build-lib -femit-llvm-bc` 然后 `zig cc -mllvm
-bpf-stack-size=4096 -c`）完全规避了这三件事——LLVM 被藏在 Zig
里面，version drift 自然跟着 Zig 走，没有 `libLLVM.so` 查找问题。

## 作为 Zig 项目依赖

elf2sbpf 目前以 CLI 形式发布。如果你想把它作为 Zig 库 import
（Epic D.4），暂时需要手工 vendor：

```bash
mkdir -p vendor/elf2sbpf
cp -r /path/to/elf2sbpf/src vendor/elf2sbpf/
# 在 build.zig 里加 module
```

API 是否稳定到可以作为公开 Zig 库依赖，C2 阶段结束后再评估。

## 升级 / 卸载

```bash
# 升级（拉最新代码 + 重装）
cd elf2sbpf && git pull && zig build -p ~/.local

# 卸载
rm ~/.local/bin/elf2sbpf
```

## 遇到问题

- **`zig: command not found`**：先装 Zig 0.16.0
- **版本不匹配**：`zig version` 必须是 0.16.x；0.15 / 0.17 不支持
- **`Illegal instruction` 部署时**：八成是 ELF 布局问题；跑
  `./scripts/validate-zig.sh <example>` 跟 shim 比一下看看是不是
  regression
- **zignocchio build.zig 里的 `libLLVM.so` 符号链接**：切到
  基于 elf2sbpf 的 build 草稿后就不用了，可以删

深层问题请开 issue。
