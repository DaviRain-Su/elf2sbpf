# elf2sbpf

[English README](README.md)

一个用 Zig 写的后处理工具，把 BPF ELF 目标文件转换成 Solana SBPF `.so`
程序。目的是让 Zig 开发者构建 Solana 程序时**不需要装 Rust、
`sbpf-linker`，也不需要单独装 LLVM 工具链**。

## 状态

**最新 release：[v0.5.0](https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.5.0) —— SbpfArch V3 端到端（2026-04-18）**

C1 / C2 / D 阶段所有目标已交付：

- `zig build` ✅
- `zig build test --summary all` ✅（378/378 tests：单元 + V0 9-example sweep + V3 9-example sweep + debug-info + fuzz-lite + adversarial-ELF）
- `./scripts/validate-zig.sh` ✅（zignocchio 9/9 example 和 `reference-shim` MATCH）
- GitHub Actions CI ✅（ubuntu-latest + macos-latest）
- 库 API：`linkProgram` / `linkProgramV3` / `linkProgramWithSyscalls`；CLI 带
  `--v0` / `--v3` flag
- zignocchio 上游 Draft PR：[Solana-ZH/zignocchio#1](https://github.com/Solana-ZH/zignocchio/pull/1)

**支持 target**：SBPF **V0**（默认）和 **V3**（自 v0.5.0）。对 9 个 zignocchio
example 两种 arch 下的产物都跟 `reference-shim` 字节一致（+ V0 下一个 debug-info
fixture）。

**版本脉络**：v0.1（C1+C2 MVP）→ v0.2（debug info）→ v0.3（Zig 库 API）→
v0.4（自定义 syscall registry）→ v0.5（V3 arch）。

完整背景见 `docs/C0-findings.md`；执行细节见 `docs/C1-tasks.md` /
`docs/C2-tasks.md` / `docs/D-tasks.md` / `docs/06-implementation-log.md` /
`docs/decisions.md`（ADR）。

## 安装 & 使用

### 本地安装

```bash
# 需要 Zig 0.16.0
git clone https://github.com/DaviRain-Su/elf2sbpf && cd elf2sbpf
zig build -p ~/.local           # 装到 ~/.local/bin/elf2sbpf
export PATH="$HOME/.local/bin:$PATH"

# 验证
elf2sbpf --help
```

### CI / 一次性使用

可以，`elf2sbpf` 在 CI 里可以正常用。最简单的方式就是在 job 里现编，
然后直接调用 `zig-out/bin/elf2sbpf`：

```bash
# 在 CI 里
zig build
./zig-out/bin/elf2sbpf input.o output.so
```

GitHub Actions 示例：

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

如果别的仓库在 CI 里要用 `elf2sbpf`，有两种常见方式：

1. checkout 本仓库后 `zig build`，再把 `zig-out/bin/elf2sbpf` 的绝对路径
   传给调用方；或
2. 用 `zig build -p <prefix>` 安装到某个前缀，再把 `<prefix>/bin` 加到
   `PATH`。

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

# 可选：以 Zig 依赖方式在进程内调用
zig build -Dexample=hello -Dlinker=zig-import
```

**不再需要** `cargo install sbpf-linker`、`LD_LIBRARY_PATH` hack、
libLLVM.so.20 符号链接 等前置配置。默认路径使用 `elf2sbpf` CLI；如果你
想把 elf2sbpf 作为 Zig 依赖在进程内调用，也可以用
`-Dlinker=zig-import`。

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

`reference-shim/` 目录下有一个 Rust 参考 shim —— 实现了同样的
stage 2 逻辑，但不依赖 `sbpf-linker` 也不依赖 libLLVM。它是
**字节对等 oracle**：`src/testdata/` 下的所有 golden 都由 shim 产出，
`scripts/validate-zig.sh` 把 elf2sbpf 新产物跟它做 `cmp`。shim 在
v0.5.0 加了 `--v3` flag，给我们 V3 oracle 也有了。保留它在主干上
的决定记录在 [ADR-002](docs/decisions.md)。

## Scope

**已支持（C1 + D 阶段，截至 v0.5.0）：**

- ✅ SbpfArch **V0**（动态链接 —— PT_DYNAMIC + dynsym / dynstr / rel.dyn）
- ✅ SbpfArch **V3**（静态布局、固定 vaddr、无 PT_DYNAMIC —— 自 v0.5.0）
- ✅ `.text` + `.rodata` sections，包括多字符串的 `.rodata.str1.1`
- ✅ `lddw` 和 `call` relocation
- ✅ 改进版 rodata gap-fill：在每个 `lddw` 目标偏移处切分 section，
  让 Zig/clang 默认产出的 `.rodata.str1.1` 在**没有具名字符串符号**时也能工作
- ✅ `.debug_*` 保留（abbrev / info / line / line_str / str / frame / loc / ranges 白名单，跟 Rust 对齐 —— 自 v0.2.0）
- ✅ 自定义 syscall 注册：`linkProgramWithSyscalls` 在 30 个内置 Solana
  syscall 之外 threadlocal 叠加用户扩展表（自 v0.4.0）
- ✅ Zig 库 API：`@import("elf2sbpf")` + `linkProgram` / `linkProgramV3` /
  `linkProgramWithSyscalls`（自 v0.3.0）
- ✅ 9 个 zignocchio example 在 **V0 和 V3** 两种 arch 下产物都跟
  `reference-shim` byte-identical；另有一个 debug-info 固定件

**明确不做**：

- ❌ 汇编文本 parser（`.sbpf` 源 → bytecode）—— 我们只接 ELF 输入
- ❌ DWARF synthesis（从 `DebugData` 合成 debug section）—— 只做 reuse
- ❌ 多 translation-unit LTO —— 委托给 `zig cc` / 上游编译器
- ❌ BPF 字节码验证器 / VM 执行器 —— 我们是 linker 不是 runtime
- ❌ LLVM 版本追踪 / 自定义 LLVM pass —— elf2sbpf 不链 libLLVM

**等生态触发**：

- ⏭️ Windows 支持（D.5）
- ⏭️ 跨语言前端（D.6 战略愿景）

## 验证

- `zig build test` — 378/378 单元 + 集成测试（每次 CI push 跑）
- `./scripts/validate-zig.sh` — 9/9 zignocchio example（需要本地
  zignocchio checkout）；通过 shim 的 `--v0` / `--v3` flag 双 arch 覆盖
- `./scripts/validate-zig.sh hello` — 单 example
- `./scripts/fuzz/run.sh 100` — 随机回归 harness（基线 160/160 MATCH）；
  改动 byteparser / emit 层的 PR 建议先跑一轮
- 脚本说明：`scripts/README.md`

## License

MIT。见 `LICENSE`。
