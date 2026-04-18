# elf2sbpf — 产品需求文档（PRD）

**状态**：C1 进行中
**最后更新**：2026-04-18

---

## 1. 概述

elf2sbpf 是一个用 Zig 写的后处理工具，把 BPF ELF 目标文件转换成
Solana SBPF `.so` 程序。

它是 Rust `sbpf-linker` 两段式管道中 **stage 2** 的纯 Zig 实现。
配合 `zig cc` 作为 stage 1（LLVM codegen），它让 Zig 开发者写
Solana 程序时**只需要安装 Zig**，不再需要 Rust 工具链、
`sbpf-linker`、独立 LLVM 等依赖。

---

## 2. 背景与动机

### 问题

zignocchio（Zig 写 Solana 程序的框架）目前构建流程是：

```
Zig 源码 → bitcode → sbpf-linker (Rust) → .so
```

`sbpf-linker` 需要用户 `cargo install`，它内部依赖 `bpf-linker 0.10.3`，
对 LLVM 版本敏感（只能在 LLVM 20 下编译，LLVM 22 系统编不过）。
Linux 上还需要 `LD_LIBRARY_PATH` 的 hack 才能找到 libLLVM。

这个依赖链让 Zig 开发者使用 Solana 的门槛明显高于应有：
- 装 Zig
- 装 Rust 工具链（rustup、cargo）
- `cargo install sbpf-linker`（可能因 LLVM 版本不匹配失败）
- 配置 `LD_LIBRARY_PATH` / 符号链接（Linux 特有）

### C0 发现

C0 阶段的验证结论（详见 `C0-findings.md`）：

1. **Zig 自己能通过 `zig cc` 调用自带的 LLVM**，把 bitcode 转成
   BPF ELF，并且接受 `-mllvm -bpf-stack-size=4096` 来设置 Solana
   需要的 4KB 栈
2. **sbpf-linker 的 stage 2 逻辑独立于 LLVM**，可以纯 Rust 单独
   跑通（已经在 `reference-shim/` 验证）
3. **Stage 2 完全可以 port 成 Zig**，不增加任何新依赖
4. 这条新管道在 zignocchio **9/9 个 example 上端到端跑通**

### 机会

把 stage 2 port 成 Zig，配合 `zig cc` bridge，可以把整条管道变成：

```
Zig 源码 → bitcode（zig）→ ELF（zig cc）→ .so（elf2sbpf）
```

**整条链条全部用 Zig 工具链**。用户只需要装 Zig。

### 更大的机会：跨语言汇合点

一个值得记录的战略观察：**BPF ELF 目标文件是天然的跨语言汇合点**。
任何 LLVM 前端（rustc、zig、clang、nim、TinyGo 等）都能产出同一种
BPF ELF，格式由 LLVM 统一定义。elf2sbpf 作为 ELF → SBPF 的后处理器，
**它的输入不关心源语言是什么**——只要能拿到 BPF ELF，后面的路径完全
共用。

sbpf-linker 其实也在朝这个方向走（README 里的 "upstream BPF" 定位），
但它处在**更上游的 bitcode 层**，这带来几个结构性劣势：

| 维度 | sbpf-linker（bitcode 层） | elf2sbpf（ELF 层） |
|------|-------------------------|------------------|
| 依赖 | 链 libLLVM（~100MB） | 零 LLVM 依赖 |
| 兼容性 | 必须跟特定 LLVM 版本（21/22 gallery 分支） | 只依赖 ELF 格式标准 |
| 前端范围 | 只能吃**bitcode**（要求前端开放 bitcode 输出） | 能吃**任何 LLVM 前端的 ELF** |
| 部署 | 分发带 LLVM 的大二进制 | 分发独立静态二进制 |
| 维护 | 追踪 LLVM API 变化 | BPF ELF 格式稳定，几乎零维护 |
| **版本维护成本** | **持续追 LLVM major（6 个月一个）** | **零**——不追任何版本 |

**结论**：bitcode 层试图做跨语言，但付出的代价是依赖 LLVM；ELF 层
做跨语言更轻量，前端范围更广。elf2sbpf 恰好占住了 ELF 层这个位置。

这不是 C1 的目标——C1 只做 Zig 管道走通。但 elf2sbpf 的架构决策
（CLI 就是 `input.o output.so`、纯 ELF 输入、零 LLVM 依赖）**本来
就预留了通用的未来**。详见里程碑 D.6。

### 关于 "`zig cc` 内部还有 LLVM" 的澄清

**一个容易误解的点**：我们说 elf2sbpf 是 "LLVM-free" 的，指的是
**elf2sbpf 这个工具不链接 libLLVM、不调 LLVM API**。但**整条构建
管道依然用了 LLVM**——它在 `zig cc` 里面。`zig cc` 字面上就是
clang + libclang + libLLVM，Zig 把它们打包在发行包里。

所以更精确的措辞是：

- **elf2sbpf 这一段**：无 LLVM，静态 Zig 二进制
- **`zig cc` 这一段**：有 LLVM，但随 Zig bundle，不是我们的依赖
- **对用户**：只装 Zig 一个东西，不用单独装 LLVM

这个区分看似迂腐，但**它是 elf2sbpf 相对 sbpf-linker 的关键战略
优势**——见下节。

### 为什么 elf2sbpf 不追 LLVM 版本（关键优势）

sbpf-linker 维护团队的一个持续痛点：**LLVM 版本追踪**。这不是他们
做得不好，是**架构决定的必然结果**。

#### sbpf-linker 的架构决定它必须追

```
sbpf-linker
  └─ bpf-linker 0.10.3
      └─ llvm-sys / inkwell（Rust ↔ libLLVM FFI 绑定）
          └─ libLLVM.so.X（X 必须精确匹配编译时选的版本）
```

FFI 绑定是**脆**的：

1. **LLVM 每 6 个月一个 major**（21、22、23...）每次都有 API 变动
2. **bpf-linker 每次都要改**来适配新版 LLVM 的 FFI 签名
3. **Blueshift 同时维护两个 gallery 分支**（upstream-gallery-21、
   upstream-gallery-22）来支持两个 LLVM 版本——**双倍工作量**
4. **用户层也会崩**——C0 实验时亲眼见过：LLVM 22 装在系统里，
   `bpf-linker 0.10.3`（针对 LLVM 20 写的）直接编译失败

这不是 bug，是"用 FFI 链 libLLVM"这个架构选择的**结构性成本**。

#### elf2sbpf 的架构让我们完全不用追

```
elf2sbpf
  └─（没有 LLVM 依赖，纯 Zig stdlib）

zig cc（被调用，不是被链接）
  └─ 随 Zig 发行版，LLVM 版本由 Zig 团队决定
```

我们**对 LLVM 版本无感知**。LLVM 22 → 23 → 24 → 30，elf2sbpf
不改一行代码。

**版本维护责任在哪儿？**

| 责任方 | 为什么 |
|--------|-------|
| ~~elf2sbpf 维护者~~ | **不在我们**——不链 LLVM |
| ~~zignocchio 用户~~ | **不在用户**——只装 Zig |
| **Zig 团队** | Zig 每次发版时同步升级 bundled LLVM，这是他们的日常工作 |

这是**责任外包**到一个有充足工程能力、有固定发版节奏的上游团队。
我们把"LLVM 版本追踪"这个持续维护工作**完全从 Solana 生态里
剥离**，交给 Zig 去负担（而 Zig 团队本来就要做）。

#### 代价：我们锁在 Zig 选的 LLVM 版本上

诚实讲这不是零代价：

- Zig 0.16 绑定的是某个 LLVM 版本，我们就是那个版本
- 想用更新版 LLVM 的新特性？**等 Zig 下一版**
- 某个 LLVM BPF codegen bug 在 Zig 0.16 上触发？**等 Zig 修复或
  升级**（不能自己抢先改）

但这些都是**外部依赖稳定的代价**，不是**持续的维护成本**。两者
质地完全不同。

#### 战略上的权衡

| 策略 | sbpf-linker | elf2sbpf |
|------|-------------|----------|
| LLVM 控制权 | **极度灵活**（可以自己加 pass、改 ABI） | **几乎没有**（用 Zig 给的） |
| 维护负担 | **持续且高**（6 个月一个 major，每次都改） | **几乎零** |
| 响应 LLVM bug 的速度 | 快（可以立刻改） | 慢（等 Zig） |
| 新 LLVM 特性采纳速度 | 快 | 慢 |
| 适合什么场景 | 需要精确控制 LLVM pass 的重型工具链（如 cargo-build-sbf） | 轻量级、面向终端用户的工具 |

**两条路各有合理性**。sbpf-linker 的定位决定了它必须链 LLVM（它要
跑 bpf-expand-memcpy、allow-bpf-trap 等自定义 pass）。elf2sbpf 的
定位决定了我们**不需要也不应该**链 LLVM——我们只做 stage 2，不
参与 LLVM 级别的处理。

**对 Solana 生态的净效应**：elf2sbpf 给 zignocchio 及未来其他
语言用户**隔离掉了 LLVM 版本追踪这个长期维护成本**。用户升 Zig
就是升 LLVM，不用关心 LLVM 版本号存在与否。

---

## 3. 目标用户 & 使用场景

### 主要用户

- **zignocchio 用户**：想用 Zig 写 Solana 程序，不想折腾 Rust 工具链
- **Zig → Solana 初学者**：装了 Zig 就能立刻开始尝试，零摩擦入门
- **CI / 容器化构建**：需要精简镜像，不想引入 Rust + LLVM 的体积

### 次要用户

- **其他 LLVM 前端**（C/C++ via clang、Rust via `rustc --emit=obj`）：
  只要能产出 BPF ELF，都能用 elf2sbpf 做 stage 2
- **教学 / hackathon**：快速起手、无环境问题的 Solana 演示

### 不针对的用户

- 已经深度使用 Rust Solana 工具链的团队——他们用现成的
  `sbpf-linker` 即可，elf2sbpf 对他们无增量价值
- 需要 Debug info、V3 特性、自定义 LLVM pass 的高级用户——
  这些特性在 C1 范围外

---

## 4. 产品定位

### In Scope（C1 MVP）

下面列的是 **C1 目标范围**，不是当前完成度勾选：

- 把 sbpf-linker 的 stage 2 逻辑完整 port 到 Zig
- SbpfArch V0 支持
- `.text` + `.rodata` section（包括 Zig / clang 产出的多字符串
  `.rodata.str1.1`）
- `lddw` + `call` relocation 的重写
- 改进版 rodata gap-fill 算法（已在 shim 验证设计）
- Syscall murmur3-32 哈希注入
- CLI 工具（`elf2sbpf input.o output.so`）
- zignocchio 9/9 example 跟 shim 字节一致（作为 C1 验收标准）

### Out of Scope（推迟到 C2 或 D 阶段）

- ❌ SbpfArch V3 路径
- ❌ Debug info（`.debug_*`）保留
- ❌ 动态 syscall relocation（目前只做静态 murmur3 注入）
- ❌ 多 translation unit LTO（委托给 `zig cc` / 上游编译器）
- ❌ 作为库被其他 Zig 程序 import（先做 CLI）
- ❌ 写方（emit 的 rodata 字节）的优化（如字符串去重、合并）

### 非目标（明确不做）

- ❌ **不做**替代 `sbpf-linker` 的完整功能。我们不嵌 LLVM，不做
  LLVM pass，不做 bitcode 链接。
- ❌ **不做**对 LLVM 版本的追踪和适配
- ❌ **不做**跨平台 / Windows 支持（先 macOS / Linux）

---

## 5. 成功标准

### C1 MVP 通过标准

**必须（MUST）**：

1. 构建：`zig build` 在 macOS aarch64 和 Linux x86_64 上成功产出
   `elf2sbpf` 静态二进制
2. 功能：对 zignocchio 9 个 example 走 `zig cc` bridge 管道产出
   的 `.o`，elf2sbpf 产出的 `.so` 与 Rust `reference-shim` 产出
   的 `.so` **字节完全一致**
3. 性能：单个 example 处理 < 100ms（shim 是 ~10ms，不求一样快
   但同数量级）
4. 代码质量：
   - 通过 `zig fmt` 检查
   - 无 memory leak（GPA 跑测试时报告）
   - 无 runtime panic（对合法 BPF ELF 输入）
   - 覆盖率：所有 public API 都有单元测试

**不要求（NICE TO HAVE）**：

- 跟现有 `sbpf-linker` 的 bitcode 管道产物字节一致（因为它多跑一
  次 LLVM 优化，不可能字节完全一样，也不需要）

### C1 完成的交付物

1. `/Users/davirian/dev/active/elf2sbpf/` 下的 Zig 项目
2. `elf2sbpf` 二进制能直接跑
3. 所有 9 个 zignocchio example 的对拍脚本跑绿
4. 项目 README 更新到 C1 完成状态
5. zignocchio 的 `build.zig` 草稿（展示如何接入 elf2sbpf）

---

## 6. 技术架构

### 管道（最终形态）

```
Zig 源码
  │   zig build-lib -target bpfel-freestanding -mcpu=v2 -O ReleaseSmall
  │          -femit-llvm-bc=program.bc -fno-emit-bin
  ▼
program.bc（LLVM bitcode）
  │   zig cc -target bpfel-freestanding -mcpu=v2 -O2
  │          -mllvm -bpf-stack-size=4096
  │          -c program.bc -o program.o
  ▼
program.o（BPF ELF 目标文件）
  │   elf2sbpf program.o program.so
  ▼
program.so（Solana SBPF 可部署文件）
```

### elf2sbpf 内部模块（C1 目标）

```
elf2sbpf/
├── build.zig               Zig 构建配置
├── build.zig.zon           依赖（无外部依赖）
├── src/
│   ├── main.zig            CLI 入口
│   ├── lib.zig             库根，re-export
│   ├── common/             （对应 Rust sbpf-common）
│   │   ├── number.zig      Number 类型
│   │   ├── register.zig    Register 类型
│   │   ├── opcode.zig      Opcode enum + 辅助
│   │   ├── instruction.zig Instruction 结构 + encode/decode
│   │   └── syscalls.zig    murmur3-32
│   ├── elf/                ELF 读取层
│   │   ├── reader.zig      基于 std.elf
│   │   ├── section.zig
│   │   ├── symbol.zig
│   │   └── reloc.zig
│   ├── parse/              Byteparser 逻辑
│   │   └── byteparser.zig  ro_sections + lddw_targets + gap-fill + relocation 重写
│   ├── ast/                AST 中间表示
│   │   ├── node.zig        ASTNode
│   │   └── ast.zig         AST + build_program
│   ├── emit/               ELF 输出层（对应 Rust sbpf-assembler）
│   │   ├── header.zig      ElfHeader, ProgramHeader
│   │   ├── section_types.zig
│   │   └── program.zig     Program::from_parse_result + emit_bytecode
│   └── tests/              端到端 + 单元测试
│       ├── unit/
│       └── integration/
├── fixtures/               （保留）共享测试样本
├── docs/                   （保留）本 PRD + 相关文档
├── reference-shim/         （保留）Rust oracle，C1 完成后保留，C2 可选删除
└── scripts/                （保留）对拍脚本 + 自动化
```

### 关键设计决策

1. **使用 `std.mem.Allocator` 显式传递**：Zig 传统，不用全局 allocator
2. **错误用 `error` set + errdefer**：不用 `@panic`
3. **模块边界按数据流切**：common → elf → parse → ast → emit
4. **每层有独立单元测试**：不依赖其他层，可独立运行
5. **CLI 和库同构**：`main.zig` 只是薄包装，所有逻辑在 `lib.zig`
   路径下，方便未来作为库被 import

---

## 7. 里程碑总览

### C0 — 验证阶段 ✅ 已完成

- 验证 Zig 能产出合法 BPF ELF
- 验证 stage 2 逻辑可独立跑
- 验证 `zig cc` bridge 能解栈大小问题
- 产物：`reference-shim`（Rust）+ 验证脚本 + 本 PRD

### C1 — Zig MVP 移植

**目标**：把 stage 2 完整 port 成 Zig，9/9 zignocchio example 字节
一致。

**预估**：6-8 周单人全职（按任务清单拆解）

**交付**：
- 可工作的 `elf2sbpf` Zig 二进制
- 对拍测试 9/9 通过
- zignocchio 改造 PR 草稿

### C2 — 集成 & 上游

**目标**：让 zignocchio 默认用 elf2sbpf，消除 Rust 工具链依赖。

**预估**：1-2 周

**交付**：
- 合并 zignocchio `build.zig` 改造
- 更新 zignocchio README 和安装文档
- （可选）删除 `reference-shim/` 目录
- （可选）给 blueshift-gg/sbpf 提 issue 报 byteparser rodata 限制

### D — 功能扩展（按需）

**目标**：补足 out-of-scope 的功能 + 长期战略愿景。

**可能的子里程碑**：

- D.1：SbpfArch V3 支持（当 Solana runtime 主推 V3 时再做）
- D.2：Debug info 保留
- D.3：Dynamic syscall relocation
- D.4：elf2sbpf 作为 Zig 库 import
- D.5：Windows 支持
- **D.6：跨语言 Solana 构建工具（战略愿景）** —— 详见下节

无固定时间表，按生态需求驱动。

### D.6 — 跨语言 Solana 构建工具（战略愿景）

**背景**

在 C0 验证过程中发现一个结构性事实：**BPF ELF 目标文件是天然的
跨语言汇合点**。任何 LLVM 前端都能产出它。elf2sbpf 占住的这个
"ELF → SBPF 后处理"位置，**对所有 LLVM 前端都是通用的**——
不依赖具体语言。

目前 Solana 生态的构建工具按语言切分：

| 语言 | 构建工具 | 后端 |
|------|---------|------|
| Rust | `cargo-build-sbf`（Anza） | sbpf-linker |
| Zig  | zignocchio + elf2sbpf（本项目 C1 完成后） | elf2sbpf |
| C / C++ | **没有官方方案** | — |
| Nim / Crystal / TinyGo | **没有官方方案** | — |

Rust 的 sbpf-linker 其实也在尝试做"upstream BPF"的跨语言位置
（README 明说了），但它处在 **bitcode 层**——必须链 libLLVM、
必须跟 LLVM 版本。ELF 层（elf2sbpf）在这件事上**结构性更轻**。

**愿景**

做一个叫 `solana-build-any`（或类似名字）的工具，统一驱动多语言
前端到 `.so`：

```
   ┌── Rust    ──→ rustc --emit=obj ─┐
   ├── Zig     ──→ zig + zig cc     │
源码├── C/C++   ──→ clang            ├──→ BPF ELF ──→ elf2sbpf ──→ .so
   ├── Nim     ──→ nim + clang      │
   └── TinyGo  ──→ tinygo -target=bpf┘
```

这不是"替代 cargo-build-sbf"——Rust 用户**想继续用** cargo-build-sbf
就继续用。新工具是**给那些想要**"跨语言 / 零 Rust 工具链 / 轻量级"
体验的用户提供选择。

**成立的前提**

1. ✅ **elf2sbpf 已经是语言无关的**（`input.o output.so` 的 CLI 形态）
2. ✅ **Zig 走通了**（C1 完成后就是既成事实）
3. ⏳ **至少一个非 Zig 前端能用**——C / C++ 用 clang 直接能接入，是
   最容易的下一个目标
4. ⏳ **Solana 上游 LLVM 补丁推完**——让 Rust 可以不依赖 platform-tools
   就编出 Solana 程序（这是 Blueshift 上游 gallery 工作的方向，**不是
   我们的工作**）

### 为什么**现在不做** D.6

1. **C1 还没完成**——没有可工作的 elf2sbpf，谈什么"通用工具"都
   是空中楼阁。先把元件做出来。
2. **需求还没形成**——目前只有 zignocchio 这一个调用方。等 Zig
   管道做完、有 Zig 用户产生真实反馈，再谈扩展。
3. **前端适配成本按需评估**——加一种语言要写一段 build-wrapper
   逻辑，每种语言大约 100-300 行。单独为"通用"先写 5 种是过度
   投入，等用户来问再加。
4. **Rust 暂时不接**——Rust 社区有 cargo-build-sbf，迁移动力低；
   强行接入会踩 platform-tools 的坑，投入产出比差。

**做 D.6 的自然时机**：C1 + C2 跑稳之后，如果 Zig 社区有人问
"能不能让 C 程序也走这条管道"，那时候加个 `--lang=c` 前端。扩展
自然发生，不是先做好等人来用。

---

## 8. 风险与已知问题

### 技术风险

| 风险 | 严重度 | 缓解措施 |
|------|--------|---------|
| Zig 0.16 API 变动 | 低 | 锁定 Zig 0.16.0，CI 固定版本；0.17 出来再升 |
| shim 对拍不够严格（漏掉 case） | 中 | C1-I 阶段加 fuzzing-lite（随机小程序做 diff） |
| Solana runtime 对 ELF 布局的隐式约束（我们没测到的） | 中 | C2 阶段跑 solana-test-validator 做运行时验证 |
| LLVM 版本升级后 `zig cc` 的 `-mllvm` 行为变化 | 低 | 管道由 `-mllvm -bpf-stack-size` 驱动，这个 flag 在 LLVM 里稳定多年 |

### 产品风险

| 风险 | 严重度 | 缓解措施 |
|------|--------|---------|
| zignocchio 用户不接受工具链变更 | 中 | 在 zignocchio `build.zig` 里保留两条路径并存，feature flag 切换 |
| elf2sbpf 的轻量定位被误解为"完整 sbpf-linker 替代品" | 中 | 在 README 和 PRD 明确 scope；遇到 bug report 先确认是不是 out-of-scope |
| Solana SBPF V3 推广导致 V0 被淘汰 | 低 | V0 向后兼容，短期不会废；长期 D.1 补 V3 |

### 已知开放问题

1. zignocchio 的 `build.zig` 里那段 Linux libLLVM 符号链接 hack
   我们不需要了——是否顺手给 zignocchio 提 PR 删掉它？→ C2 决定
2. byteparser 的 rodata gap-fill 限制是上游 bug，要不要给
   blueshift-gg/sbpf 提 issue？→ C2 可选
3. elf2sbpf 的 License？→ 建议 MIT，跟 sbpf-linker 保持一致
4. 是否需要支持 `.so` 作为输入（already-linked 的 Solana 程序
   重签名/转换）？→ 目前不做，等有需求再说

---

## 9. 非目标声明（严格）

为了保持 scope 清晰，明确列出**我们不做的事**（C1 阶段尤其要
守住）：

1. ❌ 不做 bitcode → ELF 的 LLVM codegen（`zig cc` 做）
2. ❌ 不做 LLVM pass / 优化（`zig cc` 做）
3. ❌ 不做多 object 文件 LTO 链接（`zig cc` / `zig ar` 做）
4. ❌ **C1 不做 Rust 前端支持**。Rust 用户继续用 cargo-build-sbf。
   Rust 接入留给 D.6 阶段，而且**即使到了 D.6 也优先级最低**——
   Solana Rust 生态的 platform-tools 依赖决定了这是最难啃的骨头，
   不是最先该啃的。
5. ❌ **C1 不做多语言前端**。虽然架构天然支持（elf2sbpf 输入
   就是 ELF），但 C1 明确只做 Zig 一条路径跑通。多语言扩展留给
   D.6，按需扩展。
6. ❌ 不做 cargo-build-sbf 的替代品。两套工具服务不同人群。
7. ❌ 不嵌 libLLVM（任何形式）
8. ❌ 不做 BPF VM / 运行 / 调试（用 `solana-test-validator`、
   `solana-sbpf` 等）
9. ❌ 不做 Solana 程序部署（用 `solana program deploy`）
10. ❌ 不兼容 Rust `sbpf-linker` 的 CLI flag（不求 drop-in
    替代，只求能被 zignocchio 调用）

---

## 10. 参考

- 验证报告：`docs/C0-findings.md`
- 构建管道详解：`docs/pipeline.md`
- C1 任务清单：`docs/C1-tasks.md`
- Rust 实现参考：
  - https://github.com/blueshift-gg/sbpf-linker
  - https://github.com/blueshift-gg/sbpf
- zignocchio：https://github.com/Solana-ZH/zignocchio
- Solana SBPF 规范：https://github.com/solana-foundation/solana-improvement-documents
