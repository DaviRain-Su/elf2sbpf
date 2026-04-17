# elf2sbpf 构建管道

面向实际构建操作的参考文档。完整的 C0 验证经过和每个决策背后的
推理，见 `C0-findings.md`。

## 一张图看懂管道

```
┌─────────────────────────────────────────────────────────────────┐
│                    全部随 Zig 0.16 一起安装                      │
│                                                                 │
│   Zig 源码        ┌──── zig build-lib ────┐                     │
│      │            │  -target bpfel-...    │                     │
│      ▼            │  -mcpu=v2             │                     │
│                   │  -femit-llvm-bc       │                     │
│   LLVM bitcode    │  -fno-emit-bin        │                     │
│      │            └───────────────────────┘                     │
│      ▼                                                          │
│                   ┌──── zig cc ───────────┐                     │
│                   │  -target bpfel-...    │                     │
│                   │  -mcpu=v2             │                     │
│   BPF ELF .o      │  -mllvm               │                     │
│      │            │  -bpf-stack-size=4096 │                     │
│      ▼            │  -c in.bc -o out.o    │                     │
│                   └───────────────────────┘                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
       │
       │  （在这里离开 Zig-bundled 的范围）
       ▼
 ┌────────────────────────────────────────┐
 │  elf2sbpf（Zig 实现，本项目）          │
 │                                        │
 │  - 读 BPF ELF                          │
 │  - 跑 byteparser 逻辑                  │
 │  - emit Solana SBPF 字节流             │
 │                                        │
 │  不依赖 libLLVM，不依赖 Rust，零外部依赖 │
 └────────────────────────────────────────┘
       │
       ▼
   Solana SBPF .so（用 `solana program deploy` 部署）
```

## 每个阶段为什么存在

### Stage 1：`zig build-lib -femit-llvm-bc`

Zig 前端编译 `.zig` 源码，降级到 LLVM IR，然后把 IR 以 LLVM 的
二进制 bitcode 格式写盘。因为加了 `-fno-emit-bin`，Zig **跳过
codegen**——所以 LLVM 的任何 target 特定检查（包括 BPF 栈大小限制）
**都还没跑**。

### Stage 2：`zig cc -mllvm -bpf-stack-size=4096 -c in.bc -o out.o`

`zig cc` 是 Zig 的 drop-in clang，藏在 Zig 安装包里。跟
`zig build-*` 不同，它**会**把 `-mllvm` 参数直接转发给 LLVM。
把 stage 1 产出的 bitcode 喂给它，LLVM 在跑 BPF codegen 时用的
栈限制就被提到 Solana 的 4096B——这是 Solana 运行时**真实给**每个
程序的额度，但 LLVM 的 BPF 后端默认是 512B（Linux 内核 eBPF 的
数值）。

**这个阶段是整条 Zig-only 管道能处理真实 Solana 程序的关键。**
没有 `zig cc` bridge 的话，栈大的程序（任何操作几个 account 或
SPL Token 状态的程序）都会在 codegen 阶段炸掉，用户只能回退去用
`sbpf-linker`。

### Stage 3：`elf2sbpf`

把 BPF ELF 目标文件（`.o`）转换成 Solana SBPF `.so` 布局。
具体做这些事：

- 重写 `lddw` 的立即数，让它指向 rodata label
- 重写 `call` 的立即数，让它指向 text label（或者对动态 syscall
  来说，指向 `murmur3-32` 哈希）
- 为 rodata 中没有具名符号的字节区域合成 `.rodata.__anon_<section>_<offset>`
  条目（Zig/clang 默认对 `.rodata.str1.1` 就只产出 STT_SECTION
  符号，没有具名字符串符号，得自己合成）
- 构建最终的 SBPF ELF，带上 Solana 特有的 program header、
  dynamic section、section 布局

Stage 3 纯 Zig，不碰 LLVM，不碰 Rust。这是 elf2sbpf 真正的领地。

## Flag 速查表

### Zig 源码编译阶段

| Flag                                 | 必须 | 原因                                                                 |
|--------------------------------------|------|----------------------------------------------------------------------|
| `-target bpfel-freestanding`         | 是   | Solana VM target：小端 BPF，无 OS                                     |
| `-mcpu=v2`                           | 是   | 匹配 Solana SBPF 特性：`+alu32`、无 `jmp32`（`jmp32` 是 opcode 0x16，Solana 拒绝） |
| `-O ReleaseSmall`                    | 是   | Solana 程序有严格的尺寸预算                                            |
| `-femit-llvm-bc=<path>`              | 是   | Stage 2 要用 bitcode                                                  |
| `-fno-emit-bin`                      | 是   | 跳过 Zig 自己的 codegen（栈检查会在这里触发，要避开）                    |
| `--dep sdk`、`-Mroot=`、`-Msdk=`     | 项目相关 | zignocchio 的模块配线；别的项目按需调整                             |

### `zig cc` 阶段

| Flag                                 | 必须 | 原因                                                                 |
|--------------------------------------|------|----------------------------------------------------------------------|
| `-target bpfel-freestanding`         | 是   | 同 stage 1                                                           |
| `-mcpu=v2`                           | 是   | 同 stage 1                                                           |
| `-O2`                                | 是   | codegen 优化级别                                                      |
| `-mllvm -bpf-stack-size=4096`        | 是   | 把 BPF 栈限制从 LLVM 的 Linux 内核默认值 512B 提到 4096B              |
| `-c in.bc -o out.o`                  | 是   | 把 bitcode 编译成 ELF 目标                                            |

### elf2sbpf 阶段

具体参数留给 C1 定义。`reference-shim/` 的 shim 接受
`input.o output.so` 两个位置参数——Zig 港会先匹配这个接口，需要
额外 flag 时再加。

## LLVM 到底在哪里

常被问的问题："这个真的 LLVM-free 吗？"

诚实的回答：

- **elf2sbpf 二进制**：零 LLVM。作为 Zig 静态二进制发布。
- **`zig cc`**：用的是 Zig 自带的 libclang/libLLVM。这**不是**
  一个独立的安装——它就在用户已经下载的 Zig tarball 里面。
- **用户系统**：只需装一样东西（Zig 0.16）。不用
  `brew install llvm`，不用 `cargo install sbpf-linker`，不用
  `rustup`，不用单独的 libLLVM。

所以对"我作为用户要不要操心 LLVM？"的回答是：**不用**。
对"管道里真的完全没有 LLVM 吗？"的回答是：**有**——LLVM 做
codegen 的工作，因为把 Zig 变成机器码本质上需要一个后端，而
Zig 今天在 BPF target 上用的就是 LLVM。`zig cc` bridge 改变
的不是消灭 LLVM，**是让 LLVM 不再是用户可见的依赖**。
