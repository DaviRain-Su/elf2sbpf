# D 阶段任务清单（功能扩展）

**目标**：按生态需求逐个补足 out-of-scope 功能。**不固定时间表**，
按用户反馈 / 上游 PR / 实际使用痛点驱动。

**在 dev-lifecycle 中的位置**：

- ⬅️ 前置输入：C1 + C2 全部完成，v0.1.0 已发
- ➡️ 每个 D.x 子任务**单独走一遍 Phase 3（技术规格）+ Phase 4（拆解）**；
  不像 C1/C2 一次性拉一个清单就开干

**原则**：
- 每个 D.x 独立（不要混在一起做）；完成后发 v0.2 / v0.3 /... release
- 保底：9/9 zignocchio golden 不能破；fuzz-lite 跑 100 轮 0 DIFFER
- 从小到大：先做 ergonomics / 结构性补齐，后做大工程（V3 / Windows）

---

## 当前状态（2026-04-18 审查快照）

**已交付** —— 4 个子里程碑 4 个 release：

| 子里程碑 | Release | 摘要 |
|----------|---------|------|
| D.2 Debug info 保留 | v0.2.0 | 8-name 白名单 pass-through；mini-debug golden |
| D.4 Zig 库 API | v0.3.0 | `@import("elf2sbpf")` + `docs/library.md` |
| D.3 Dynamic syscall | v0.4.0 | `linkProgramWithSyscalls` + thread_extra_syscalls |
| D.1 SbpfArch V3 | v0.5.0 | 9/9 V3 goldens byte-match oracle |

**未开始** —— 都在等生态触发：

- **D.5 Windows**：等 Windows 用户提需求
- **D.6 跨语言前端**：等"能不能让 C/Nim 程序也走这条"被问出来

---

## 做过的优先级排序（2026-04-18 初次规划时）

下表是当时给出的推荐顺序 + 估时；实际走下来 D.1-D.4 都远低于估时，
因为 C1 期就把"占位 if-else"打好了基础，D 阶段主要是接通 + 回归覆盖。

| 优先级 | 任务 | 估时 | 实际 | 备注 |
|--------|------|------|------|------|
| P0 | D.2 Debug info | 1-2 天 | ~1.5h | 基础设施在 F.11 已就位 |
| P1 | D.4 Zig 库 API | 1 天 | ~30min | `b.addModule` 在 C1-A 就打好；加文档 + verify |
| P2 | D.3 Custom syscalls | 1-2 天 | ~30min | threadlocal + 6 测试 |
| P3 | D.1 V3 arch | 1-2 周 | ~2h | 跟 4 个 V3-specific bug 斗智斗勇 |
| P4 | D.5 Windows | 3-5 天 | — | 未做 |
| 战略 | D.6 跨语言 | — | — | 未做 |

---

## D.2 — Debug info 保留

**动机**：目前 elf2sbpf 直接 drop 所有 `.debug_*` sections，导致
部署后的 `.so` 不能 gdb/lldb 调试。Rust sbpf-assembler 有
`reuse_debug_sections` 路径，`DebugSection` writer 在 F.11 已经
就位，只差把 Program.fromParseResult 的那条 dispatch 接上。

**预估**：1-2 天

**前置状态**（已就位）：
- ✅ `src/emit/section_types.zig` 的 `DebugSection` writer
- ✅ `src/emit/program.zig` 的 `SectionType.debug` union variant
- ✅ byteparser 的 `scanDebugSections` → `DebugScan`
- ✅ AST 的 `ParseResult.debug_sections` 字段
- ❌ Program.layoutV0Dynamic / layoutV3 / layoutV0Static 里对
  `pr.debug_sections` 的 reuse 逻辑（G.2 当时明确 defer 了）
- ❌ 带 debug_* 的测试 fixture

### 子任务

- [x] **D.2.1**：研究 Rust `reuse_debug_sections` ✅ 2026-04-18
  - 读了 `sbpf-assembler-0.1.8/src/debug.rs` + `section.rs` 的
    DebugSection 实现
  - 发现关键细节：Rust `DebugSection::size()` 返回 **padded** 大小；
    `bytecode()` 补 0 到 8 字节对齐；`sh_size` 保留 unpadded。port
    时需要对齐这三个语义

- [x] **D.2.2**：`layoutV0Dynamic` / `layoutV3` / `layoutV0Static`
  debug reuse ✅ 2026-04-18
  - 新增 `Program.appendDebugSections` 共享 helper
  - V0 Dynamic：把 dynamic/dynsym/dynstr/reldyn 的 push 从末尾提到
    appendDebugSections 之前（确保 section 表顺序跟 Rust 一致）
  - V3 / V0 Static：在 shstrtab 之前插入
  - `layoutV3` 签名加了 `pr *const ParseResult` 参数

- [x] **D.2.3**：测试 fixture ✅ 2026-04-18
  - 因为 `-O Debug` / `-O ReleaseSafe` 在 zignocchio SDK 下会超
    BPF 栈 budget，改用独立 C 源 fixture
  - `src/testdata/mini-debug.{c,o,shim.so}` ——
    clang+BPF+-g 产出，包含 `.debug_loc / .debug_abbrev /
    .debug_info / .debug_str / .debug_line`
  - `integration_test.zig` goldens 从 9 增到 10，`mini-debug` 一条
    byte-diff 专门验证 debug 保留路径

- [x] **D.2.4**：运行时烟测 ✅ 2026-04-18（跳过，per ADR-001）
  - 字节对等已传递覆盖运行时；mini-debug.shim.so 跟 elf2sbpf 产物
    byte-identical，即跟"reference-shim 能跑的一切"等价

- [x] **D.2.5**：v0.2.0 release ✅ 2026-04-18
  - `build.zig.zon` 0.1.0 → 0.2.0；CHANGELOG `[0.2.0]` 条目
  - Annotated tag `v0.2.0` + cross-compiled 3 artifact
    （macOS arm64 / Linux x86_64 / Linux arm64）+ SHA256SUMS
  - Download-verify：10/10 goldens MATCH release binary
  - **Release**：https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.2.0

### 验收

- ✅ 带 debug 的 mini-debug.o 跑管道后字节一致
- ✅ 10/10 原 golden（9 zignocchio + 1 mini-debug） MATCH
- ✅ 362/362 tests 全绿；`DebugSection.size()` 语义更新为 padded

---

## D.4 — Zig 库 API（draft）

**动机**：zignocchio 上游 PR 一合，Zig 框架作者会来用 elf2sbpf。
目前 CLI 的形式需要子进程调用（`b.addSystemCommand(...)`），这是
我在 zignocchio build.zig 草稿里的做法。更优雅的是：让
`build.zig.zon` 能直接 `zig fetch https://...elf2sbpf...`，然后
在 build.zig 里 import 成 module 调用。

**预估**：1 天

### 子任务

- [x] **D.4.1**：module 已在 build.zig 里通过 `b.addModule("elf2sbpf",
  ...)` 公开 ✅ 2026-04-18（infrastructure 早就就位）
  - `lib.zig` 里 `linkProgram / Program / LinkError / AST /
    ParseResult / SbpfArch / Instruction / byteparser` 等都 re-export
  - 实测：创建 `/tmp/elf2sbpf-import-test/` synthetic consumer →
    `zig fetch --save <path>` → `@import("elf2sbpf")` → 调用
    `linkProgram` → 对 hello.o 产出**跟 shim golden 字节一致**

- [x] **D.4.2**：`docs/library.md` ✅ 2026-04-18
  - `zig fetch --save` 指引；`build.zig` 接入代码；consumer `main.zig`
    示例；public API 稳定性表（✅ stable vs ⚠️ churn-eligible）；CLI
    vs library 对比

- [x] **D.4.3**：zignocchio `zig-import` 演示 ✅ 2026-04-18
  - `docs/integrations/zignocchio-build.zig` 原本加了 3 分支 dispatch；
    用户简化成 elf2sbpf-only 单路径（更干净的 PR 形态）
  - `zig-import` 的消费模式示例留在 `docs/library.md` + 本仓库的
    `tmp/elf2sbpf-import-test/` harness 里，非必须进 zignocchio PR

- [x] **D.4.4**：集成测试 ✅ 2026-04-18
  - 简化版 draft 对 9 个 example 实测 9/9 MATCH

### 验收

- ✅ 下游 Zig 项目能 `zig fetch --save` + `@import("elf2sbpf")` + 调用
  `linkProgram` 产出 byte-identical to CLI path
- ✅ 简化版 zignocchio build.zig 9/9 example MATCH

---

## D.1 — SbpfArch V3 ✅ 2026-04-18（v0.5.0）

**动机**：Solana runtime 正在推 V3 作为新默认（static relocation、
更快 loader、fixed vaddr）。C1 只做了 V0；V3 是扩展方向。

**实际耗时**：原估 1-2 周；**最终约 2 小时**（出乎意料地轻量，
因为 C1 期间已经把 V3 分支做成"占位 if-else"而不是 stub）。

### 做了什么

1. **reference-shim**：加 `--v3` flag（默认 V0）→ 生成 V3 对拍 golden
2. **linkProgramV3**：新公开 API，走 arch=.V3 的管道；CLI 加 `--v3`
3. **修 3 处 V3-specific bug**：
   - `layoutV3` 的 PH[0] 用 PADDED rodata size（off-by-1）
   - `fromParseResult` text_offset 也 PADDED rodata size
   - shstrtab name_offset 在 V3 分支用 `cumulativeNameLen`
     （**不加 +1**）—— V3 shstrtab 的 sh_name 指向空串而不是 ".s"
   - V3 with rodata 的 section_names 顺序为 [".text", ".rodata"]
     （即使 section 表里 rodata 在 code 之前）
4. **Phase C syscall hash bit-cast**（u32 → i32）—— 修
   ImmOutOfRange：hash 高位 set 时 `@intCast` 到 i64 会产出
   > i32.max 的值，encoder 拒绝。改成 `@bitCast` 通过 i32 保证
   round-trip

### 9/9 V3 sweep

| Example | V3 size | V0 size |
|---------|---------|---------|
| hello | 544 B | 1192 B |
| noop | 360 B | 304 B |
| logonly | 536 B | 1184 B |
| counter | 2272 B | 3344 B |
| vault | 10464 B | 12256 B |
| transfer-sol | 3448 B | 4384 B |
| pda-storage | 7544 B | 8728 B |
| escrow | 16824 B | 18616 B |
| token-vault | 18608 B | 20496 B |

V3 产物普遍比 V0 小 —— 少了 dynamic/dynsym/dynstr/rel.dyn 四个 section。

### 新增集成测试

`integration: 9 zignocchio examples byte-match reference-shim under V3`
—— V3 sweep loop，跟 V0 sweep 并列跑。V3 shim golden 入库作为
`src/testdata/<example>.v3.shim.so`（9 个新文件）。

---

## 其他 D 任务

- **D.3 Dynamic syscall relocation** ✅ 2026-04-18（v0.4.0）：
  - 新增 `linkProgramWithSyscalls(allocator, elf_bytes, extras)`，
    允许注入自定义 syscall 名字
  - 底层机制：`thread_extra_syscalls` threadlocal var；`nameForHash`
    先查内置 30 条再查 extras；save/restore 语义保证不跨调用泄漏
  - `linkProgram(a, b) ≡ linkProgramWithSyscalls(a, b, &.{})`，
    不破坏现有 API；built-in-only 程序产出字节不变
  - 文档：`docs/library.md` 加 "Custom syscalls (since v0.4.0)" 节
  - 测试：3 个 `nameForHash` 单测 + 1 个 integration test
    （extras 不动时 byte-identical to `linkProgram`；save/restore
    在连续调用间稳定）
- **D.5 Windows**：未验证；Zig 理论上跨平台。主要是 path
  separator + file I/O 的 regression
- **D.6 跨语言前端**：战略愿景，不排期

---

## D.7 — 字节码层优化路线图（未排期）

**背景**：sbpf-linker 在 **IR 层**做优化（依赖 libLLVM；掌握 SSA /
CFG / 类型 / alias 信息）。我们在 **字节码层**做优化（看得见最终
编码 / section 布局 / relocation 表）。两个层次不是替代关系，是
**叠加关系**：
  - LLVM 吃 ~95% 的传统优化（inline、DCE、vectorize、LICM、SROA、
    loop transform 等）—— 这些我们做不了（信息丢光）
  - 字节码层吃剩下的 ~5%，但**LLVM 看不到**，所以是**独占价值**

### 原则

1. **永远不链 libLLVM** —— 违反就倒退成 sbpf-linker
2. **永远保字节对等或主动声明破坏** —— 任何 opt 要加对应 golden +
   文档；默认关，`-Doptimize=Release*` 或 `--optimize` flag 才开
3. **保 V0/V3 byte-diff oracle** —— shim 做不到的优化不能 unconditionally
   启用（会破坏对拍）；应作为 opt-in 路径

### 候选子任务（按价值/成本粗排；无任何一个已开工）

| ID | 子任务 | 层级 | 预估收益 | 实现复杂度 | 备注 |
|----|--------|------|----------|-----------|------|
| **D.7.1** | Rodata 字符串去重 | emit | DeFi 类程序 ~5-15% 体积 | 低 | 同 bytes 的 ROData 节点合并到一个 entry；`.rodata` symbols 指向同 offset |
| **D.7.2** | Rodata section 合并 | emit | 2-5% 体积 | 低 | 多个 `.rodata.cst*` / `.rodata.str*` 合成一个 PROGBITS |
| **D.7.3** | Dead function elimination | AST | 取决于程序（2-20%）| 中 | 从 entrypoint 做可达性分析；未引用的 `.text` label 整块剥离 |
| **D.7.4** | Peephole（final encoding）| emit | 1-5% CU | 中 | `mov r0, r0` 消除、相邻 `lddw` 合并（如果 imm 可合）、冗余 `ja +0` 剥离 |
| **D.7.5** | Dynsym / dynstr 去重 | emit | 0-1% 体积 | 低 | 相同 name 的 dynsym 只保留一条；dynstr 字符串池紧凑化 |
| **D.7.6** | ELF padding 压缩 | emit | 0.5-2% 体积 | 低 | Section 之间的 align 空洞：能缩多少缩多少（不破坏 sh_addralign） |
| **D.7.7** | Syscall 批量优化 | AST | log 密集 5-10% CU | 高 | 相邻 `sol_log_` 合并成一次；相邻 `sol_log_64_` 参数打包 |
| **D.7.8** | Section 布局优化（hot-first）| emit | 微小（VM cache 局部性）| 低 | entry 附近的 `.text` 靠前；冷路径靠后 |
| **D.7.9** | `.text` jump relaxation | emit | 0-1% 体积 | 高 | 长跳转（`call`）如果目标在短范围内换成短形式；跟当前 SBPF encoding 是否允许相关 |
| **D.7.10** | Unaligned u64 load coalescing | AST | stock-zig pipeline ~12× CU（pubkey 187→~19）| 高 | 把 `bpfel -O2` 对 `load i64 align 1` 展开的 8×ldxb + shift/or 链重写成单条 `ldxdw`。详见下方 D.7.10 专节 |

### D.7.10 —— Unaligned u64 load coalescing（专节）

**触发场景**：用户走 `stock-zig → zig cc -target bpfel → elf2sbpf` 管
道。Solana LLVM fork 允许非对齐 64-bit load；stock LLVM 保守把它们
拆成 8 次 u8 load + shift/or 链（每 u64 load 耗 22 条指令，对比
solana-zig 的 1 条 `ldxdw`）。solana-program-rosetta 实测：Pubkey
compare 15 CU（solana-zig）vs 187 CU（stock-zig+elf2sbpf），12.5×
gap 基本都来自这里。

**V1 detector（已完成，2026-04-18）**：
- `src/ast/peephole.zig` + `linkProgram` 侧 `peepholeReport()` API
- CLI `elf2sbpf --peephole-report <input.o>` 列出候选 cluster
- 实测结果：
  - pubkey.o：8 个 cluster，168 条可省（gap 172）
  - transfer-lamports.o：1 个 cluster，21 条可省（gap 23）
  - 9 个 V0 goldens（solana-zig 编的）：hello/noop/logonly 0 cluster；
    vault 7 cluster（ReleaseSmall 下 solana-zig 也没全 inline）
- 关键 safety：locality guard（同 base、连续 offsets、但跨 40+ 条
  指令的 scatter 载入不算）防止跨 BB 误匹配

**V2.0 rewriter（已完成，2026-04-18）—— 严格非交织模式**：

- `src/ast/peephole.zig` 新增 `rewriteAll(allocator, *AST)`：扫出
  cluster → verifyCluster 安全检查 → applyRewrite 删 22 条换 1 条
- `lib.zig` 加 `linkProgramOptimized(allocator, elf_bytes)` 公开 API
- CLI `elf2sbpf --peephole <input.o> <output.so>` 默认 off，opt-in
- 全局 jump/call 偏移自适应：`anyJumpTargetsInside` 拒绝有 jump
  目标落在被删除区域内的 cluster；保留 jump 的 raw `off` 如果跨越
  删除区则按 `21 insns` 重新计算

**V2.0 安全约束**（conservative）：
- Span 动态收紧：从 last_ldxb 往后扫到第一条非 whitelist 指令就
  停（whitelist = Ldxb / Lsh64Imm / Or64Reg / Or32Reg）
- `instructions_in_span ∈ [18, 30]`：典型 pattern 22 条；区间外
  说明有异常指令塞进去
- 必须有 `Or64Reg` 确定最终目标 reg
- 跨越 del-range 的 jump target = unsafe，跳过
- **cluster 交织检查（`hasInterleavedCluster`）**：如果某 cluster
  的 span 里包含 *别的 cluster* 的 ldxb 节点，两个都不 rewrite
  —— 避免孤立掉其他 cluster 的 shift/or 链

**实测结果**：
- `rosetta-transfer.stock-zig.o`：1 cluster 非交织 → 720B → 552B
  （-168B / -21 insns），对应 gap 23 CU 完全收回
- `rosetta-pubkey.stock-zig.o`：8 cluster，6 交织 + 2 非交织 →
  1768B → 1432B（-336B / -42 insns），CU 估计 187 → 145
- 9 个 solana-zig 编的 V0 goldens：默认路径字节对等 100% 保留

**V2.1 super-cluster 重写（已完成，2026-04-18）**：

- `buildComponents`：union-find 把互相交织的 cluster 分成连通分量。
  两个 cluster 交织 iff 任一的 ldxb 节点落在另一的 `computeSpanEnd`
  范围内
- `taintPropagate`：对 super-span 里每条指令做 SSA-like 数据流，
  追踪每个 register 的 `(base_reg, base_min, u64 mask)` taint。
  `Ldxb rX, [base+off]` 把 taint 置位；`Or64Reg rX, rY` 合并 taint；
  shift 不影响 byte membership
- `matchClustersToRegs`：每个 cluster 的目标 reg = taint.mask 正好
  覆盖 `[base_offset, base_offset+7]` 8 个 bit 的 register。歧义时
  拒绝整个 super-cluster
- 拓扑排序 ldxdw 发射顺序："读 rX" 必须排在 "写 rX" 之前，防止
  `ldxdw r1, [r1+0x28]; ldxdw r2, [r1+0x48]` 这种 self-clobber base
- **Fallback 机制**：如果 super-cluster 安全检查（全 whitelist / 无
  jump target 落入 / taint match 成功）失败，回退到逐个 member 尝试
  V2.0 单独重写路径。保证 V2.1 行为永远 ≥ V2.0

**实测**：
- **pubkey.stock-zig.o**：1768 → **424 字节**（-1344 / **-168 insns**，
  8/8 cluster 全部重写）—— 完全闭合 187 CU → ~15 CU 的 12.5× gap
- transfer-lamports：552 字节（V2.0 水平，1 cluster 本来就非交织）
- vault：11872 字节（通过 fallback 保持 V2.0 的 48 insn 节省）

**仍然未做（V2.2 候选）**：
- register 活跃性分析：当前 taint 逻辑假设 shift/or 链里的中间
  寄存器都是死的（rewrite 后不会被外部读）。目前靠 `verifyCluster`
  的 whitelist-only 约束间接保证，但没做完整 liveness。对更大/更
  复杂的程序可能还有 false positives
- 多 pass / 迭代 rewrite：fallback 路径只尝试每个 super-cluster
  的第一个 member。理论上 rewriteAll 可以跑到 fixed-point（再跑一
  遍会有新的 cluster 变成非交织）。目前单 pass 就够处理 pubkey

**集成测试**（`integration_test.zig`）：
1. `linkProgramOptimized(rosetta-transfer.stock-zig.o)` = -168B ✓
2. `linkProgramOptimized(rosetta-pubkey.stock-zig.o)` = -336B ✓
3. `linkProgramOptimized(hello.o solana-zig)` = no-op, byte-identical
   到 `linkProgram` ✓

**不做的（明确）**：
- 如果 Zig 上游把 `.solana` feature 加到 `bpfel` target（patch
  LLVM，让 `load i64 align 1` 合法），V2.x 就可以砍掉——codegen 层
  免费拿回这个 gap

### 先做哪个？

**强烈推荐从 D.7.1 + D.7.3 开始**：
- D.7.1（rodata 字符串去重）：**绝对收益大 + 实现简单**。DeFi 程序
  重复的错误字符串 / 日志前缀很多；合并后可能一下省 10%+ 体积
- D.7.3（DCE）：**收益取决于程序但理论上限高**。Zig / Rust `no_std`
  用户常引入大量标准库辅助函数，只有一部分被 entrypoint 用到

两者都可以在 emit 层接前加一个 "optimizer pass" 阶段；中间态仍然
是 `ParseResult` / `Program`，不破坏架构。

### 先不做（明确）

- **D.7.7 syscall 合并**：需要语义分析（判断 syscall 参数是否独立），
  复杂度接近做一个小编译器后端。如果 Blueshift 的 JIT intrinsic 路径
  能替代（让 `sol_log_batch_` 变成 intrinsic），我们就不做
- **D.7.9 jump relaxation**：要先搞清 SBPF 对 `call` 短编码的支持
  情况；风险/收益比差

### 测量方法

所有优化项提 PR 前要有：
1. 对 9 个 zignocchio example `.so` 的 before/after 体积差
2. 对 litesvm 或 test validator 的 CU 消耗对比（如果 opt 相关）
3. byte-diff against oracle（如果不是 opt-in，必须 byte-identical）
4. fuzz-lite 100 轮跑绿

### 启动条件

**不急**。当前 v0.5.0 的产物跟 sbpf-linker/shim 字节一致，已经是
"性能 on par with Rust 管道"的基线。D.7 是"进一步 squeeze"，等
任意一个触发条件：

- 用户报：Solana program deploy 费用高，希望小一点
- 用户报：某合约 CU 吃光，希望 linker 层帮一把
- 有空做研究性 PR（不赶 release）

---

## 进度汇总

| 任务 | 状态 |
|------|------|
| D.1 V3 arch | ✅ 完成，v0.5.0 已发 |
| D.2 Debug info | ✅ 完成，v0.2.0 已发 |
| D.3 Dynamic syscall | ✅ 完成，v0.4.0 已发 |
| D.4 Zig 库 API | ✅ 完成，v0.3.0 已发 |
| D.5 Windows | 未开始（等用户报需求） |
| D.6 跨语言前端 | 战略愿景，不排期 |
| **D.7 字节码层优化** | 路线图就位，D.7.10 V1 detector + V2.0 rewriter（非交织）+ V2.1 super-cluster 交织重写 + V2.1a token miscompile 修复全部已落；V2.2 liveness / 多 pass 未排期 |

---

## 当前最有价值的一步

在我看来 **D.2 Debug info 保留** 是 P0：
- 投入最小（1-2 天），代码基础已经就位
- 对 gdb/lldb 用户立即有价值
- 不破坏任何已有 golden
- 推完 D.2 刚好有一个 v0.2.0 的小 release，延续 C1/C2 的节奏

如果用户倾向 D.4（DX / 上游集成深化）、D.1（V3 提前布局）或
D.3（syscall 扩展），告诉我即可切换。
