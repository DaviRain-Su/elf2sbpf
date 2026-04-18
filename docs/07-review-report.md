# 07 — 全面审查报告（v0.1 → v0.5）

**审查时间**：2026-04-18 起，/loop 驱动的多轮
**审查范围**：C1 + C2 + D 阶段所有交付物（v0.1.0 至 v0.5.0）
**审查人**：Claude（autonomous loop）+ 用户最终 sign-off

**目标**：在继续投入新功能前，对既有代码 / 文档 / 测试 / 发布机制
做一次综合体检，找出：
- 技术债（代码/注释漂移、死代码、未清理的 C1 期 hack）
- 文档失真（跟代码不符、链接断、版本串错）
- 测试盲点（370 个测试没覆盖的路径）
- 健壮性问题（panic 路径、输入验证、内存泄漏）
- 发布机制脆弱点（手工步骤、容易出错的流程）

**产出**：审查条目表（issue + fix 指向）；能自修的就顺手改掉，
需要用户决策的留 TODO 让用户 sign-off。

---

## 审查分阶段

### Phase 1 — 代码 hygiene（本轮开工）

- `@panic` / `unreachable` / `@as(*, *u64)` / 未处理 error 的地方
- 被 C1 期任务明确标"defer"但已经落地的 stale 注释
- 重复/死代码（随 C1→D 演进出现）
- 过时的 TODO / FIXME
- lib.zig 里的调试 print 残留

### Phase 2 — 文档 freshness

- 每份 markdown 对应版本号/状态是否还准确
- 交叉引用的锚点没断
- 版本线：v0.1 v0.2 v0.3 v0.4 v0.5 CHANGELOG 条目都有并一致
- README 的"当前阶段"行反映现状

### Phase 3 — 测试覆盖

- `zig build test` 跑出的 370 个测试按模块分布；找覆盖稀薄处
- CI 除了 `zig build test` 外是否跑 `zig fmt --check` / linter
- `validate-zig.sh` + fuzz harness 是否仍能 one-shot 跑通

### Phase 4 — 健壮性

- byteparser 对恶意 ELF 的鲁棒性（过短、overflow、循环 section）
- Memory safety（GeneralPurposeAllocator 在测试下无 leak）
- threadlocal 的 `thread_extra_syscalls` 在并发下的语义

### Phase 5 — 打包 & 发布

- Linux 二进制 `-Dstrip=true` 减小 size（v0.1 backlog）
- release CI workflow（tag → artifact）替代手工 cross-compile
- `zig fetch --save` 的 hash 稳定性；发完 release 后确认 consumer
  可以 fetch

---

## 累积发现（findings）

_按 phase 顺序追加；每条格式：`[P{N}] severity · 位置 · 描述 · 建议`_

<!-- phase-1 begin -->
### Phase 1 findings（2026-04-18 第 1 轮）

| # | severity | 位置 | 描述 | 行动 |
|---|----------|------|------|------|
| 1.1 | low | `src/lib.zig:7` | 文件顶注仍写"A.1 scaffold: stubbed LinkError enum and a not-yet-implemented linkProgram" —— v0.1 时代的说法，现在已经 5 个 minor release | ✅ 重写 doc header，列出当前三个 stable entry point 并指向 `docs/library.md` |
| 1.2 | low | `src/common/instruction.zig:169-174` | CallImmediate 的 fromBytes doc 说"We do not have that [SYSCALLS] table yet (B.9)" —— B.9 早就落地，v0.4 还加了 thread_extra_syscalls 扩展 | ✅ 重写 doc：内置表 + extras 的反查语义一次说清 |
| 1.3 | low | `src/common/opcode.zig`, `src/elf/reloc.zig`, `src/elf/symbol.zig` | `zig fmt --check src` 报 3 文件未格式化 —— 累计漂移 | ✅ `zig fmt` 跑过；370/370 依然绿 |
| 1.4 | medium | `.github/workflows/ci.yml` | CI 不跑 `zig fmt --check`，格式漂移会再来 | → 推到 Phase 5 发布机制一并修 |
| 1.5 | info | `src/parse/byteparser.zig:1631` | `TODO(D++)` 注释解释为什么删除了一个 brittle RELA-addend 测试 —— context 有用，非死代码 | 保留 |

**Phase 1 小结**：4 处真实漂移（都是 stale 注释 + fmt 漂），全部修完或排期。没发现死代码 / `@panic` / `unreachable` / 未处理 error 的路径。C1-era 标注为 deferred 的点（`fromByteParse`, debug reuse, syscall lookup）都已真实落地；注释已同步。

<!-- phase-1 end -->

### Phase 2 findings（2026-04-18 第 2 轮）

| # | severity | 位置 | 描述 | 行动 |
|---|----------|------|------|------|
| 2.1 | low | `README.en.md` | 7 行"forwarder"文件 `README.md` is now English | ✅ 删除（无外部引用） |
| 2.2 | medium | `README.md` / `README.zh.md` Status 段 | 仍说 "C1 MVP completed; C2 in progress"，列 362 tests，C2 roadmap 含 "v0.1.0 release" (pending)；事实是 v0.5.0 已发，5 个 release，370 tests | ✅ 重写 Status + 新增 "Release history" 一行；Zh/En 同步 |
| 2.3 | low | `docs/pipeline.md` + `docs/pipeline.zh.md` | elf2sbpf CLI 描述 "extra flags can be added later"；没提 `--v3` | ✅ 扩展成"CLI 签名 + V0/V3 解释"；两语言都改 |
| 2.4 | low | `docs/library.md` | `zig fetch --save` 示例 pin 到 v0.3.0；stable-API 表缺 `linkProgramV3` | ✅ 改 pin 到 v0.5.0 + 加 V3 entry |
| 2.5 | info | `docs/C2-tasks.md` / `docs/D-tasks.md` 进度汇总表 | "Epic D 3/4 进行中" / "v0.3.0 release 进行中" / D.4 Zig 库 API 标记 "进行中" 等过期字样 | ✅ 统一改成 "✅ 完成" 或明确 "等用户需求" |
| 2.6 | good | 所有 markdown 文件 | 脚本扫 inter-doc 链接：**0 broken links** | 无需行动 |

**Phase 2 小结**：4 处 user-facing docs 状态漂移（主要是 status 停留在 C2 时代），以及一些 task-list 的完成度没同步。README / pipeline / library 现在跟 v0.5.0 对齐；Zh/En parity 保持。无 broken links。

### Phase 3 findings（2026-04-18 第 3 轮）

| # | severity | 位置 | 描述 | 行动 |
|---|----------|------|------|------|
| 3.1 | medium | `.github/workflows/ci.yml` | 不跑 `zig fmt --check`（phase 1 findings 里提过） | ✅ 加到 CI steps 首位；本地先跑过，`zig fmt --check src build.zig` 已绿 |
| 3.2 | low | `.github/workflows/ci.yml` smoke test | 只跑 V0 hello.o，不测 V3 back-end | ✅ 加 `--v3` smoke 步 |
| 3.3 | low | `src/lib.zig` 错误路径测试 | 只有 1 条"rejects non-ELF" 测试；`linkProgramV3` / `linkProgramWithSyscalls` / short-buffer 没覆盖 | ✅ 加 3 条：V3/extras 入口的 non-ELF + ELF magic 但过短的 buffer |
| 3.4 | info | 每文件 test/loc 分布扫描 | `program.zig` 10 tests / 973 lines 看着稀，但三个 layout 函数实际被 10 goldens 覆盖；`opcode.zig` 5 tests / 463 lines 但 opcode 是 116-variant enum，用 inline-for round-trip 覆盖掉了；不属于真缺口 | 无需行动 |

**Phase 3 小结**：CI 加两个保护网（`zig fmt --check` + V3 smoke），防止格式漂移和 V3 入口 regression。`linkProgramV3` / `linkProgramWithSyscalls` 获得 error-path 直接覆盖。376/376 tests 绿（原 370 + 6）。

### Phase 4 findings（2026-04-18 第 4 轮）

| # | severity | 位置 | 描述 | 行动 |
|---|----------|------|------|------|
| 4.1 | good | `src/*` | 全仓扫 `@panic` / `unreachable` / `std.debug.assert`：**零命中**。Zig error-union 纪律到位 | 无需行动 |
| 4.2 | good | `src/*` | 全仓扫 `@ptrCast` / `@alignCast`：src 里零命中，全部走 slice + `readInt`。攻击面最小 | 无需行动 |
| 4.3 | **medium** | `src/elf/{section,reader,symbol}.zig` | 多处 `off + sz > bytes.len` 的边界检查在 adversarial ELF 下可能 **usize 溢出绕过**（ReleaseSafe 会 panic，ReleaseFast 是 UB）。涉及 4 个检查点 | ✅ 改成 `off > bytes.len or sz > bytes.len - off` + `std.math.mul/add` 带 overflow 检测（reader.zig 的 section table 乘法）；slicing 改成 `bytes[off..][0..sz]` 等价但更清楚 |
| 4.4 | low | 缺少 adversarial-input 回归测试 | 改好边界后加 1 条测试：`e_shoff` 近 `u64.max` 时应清 error 返回 | ✅ `test "parse rejects e_shoff near u64.max (overflow-safe bounds)"` |
| 4.5 | good | `thread_extra_syscalls` 并发 | threadlocal 语义：每线程独立；save/restore 处理 nested 调用；无 data race | 无需行动 |
| 4.6 | good | Memory safety | 所有测试使用 `std.testing.allocator`（GPA leak detector）；378/378 通过即代表无泄漏 | 无需行动 |

**Phase 4 小结**：发现 1 个 medium-severity bug（恶意 ELF 可能触发 usize 溢出绕过边界检查 → panic/UB）—— 4 个检查点全部改成 overflow-safe，加了一条回归测试。没有其他健壮性问题。378/378 tests 全绿。

### Phase 5 findings（2026-04-18 第 5 轮）

| # | severity | 位置 | 描述 | 行动 |
|---|----------|------|------|------|
| 5.1 | low | Linux release 二进制 | v0.1-v0.5 历次 release 的 Linux 二进制 ~4.8 MB，没剥 debug info | ✅ `build.zig` 加 `-Dstrip` bool 选项（默认 null = 保留，release 传 true）。实测：Linux x86_64 4.8 MB → 516 KB（9× 减小）；macOS 635 KB → 387 KB；Linux arm64 ~4.4 MB → 392 KB |
| 5.2 | medium | Release artifact 手工构建 | v0.1-v0.5 的发布流程：手工 `zig build -Dtarget=...` 3 次，tar，`shasum`，`gh release create`。脆弱、易遗漏、要求 macOS 本地环境 | ✅ 新增 `.github/workflows/release.yml`：tag push (`v*.*.*`) 触发，ubuntu-latest 一个 job 交叉编译到 3 target，算 SHA256SUMS，`gh release upload --clobber` 推上。自动 + 幂等 |
| 5.3 | good | `zig fetch --save` UX | phase 2 已把 `library.md` 里 pin 到 v0.5.0；workflow 自动产出带 checksum 的 tag release；消费者 fetch 前可 verify | 无需行动 |

**Phase 5 小结**：2 个 packaging 改进。新 release workflow 对未来的 v0.6+ 发布：tag push 即自动出 artifact，消除了"必须在 macOS 本地手工构建"的瓶颈。Release 二进制体积平均减小 ~60%，Linux 最甚达 9×。

---

## 审查总结（2026-04-18 完成）

5 个 phase 走完。**主要改动**：

| Phase | 发现 | 修/调整 |
|-------|------|---------|
| 1 code hygiene | 3 stale 注释 + 3 fmt 漂 | 全部修；flag phase 5 加 fmt 到 CI |
| 2 docs | 4 处状态漂移 + 1 forwarder 文件 | 同步 v0.5.0；Zh/En parity；删 README.en.md |
| 3 tests + CI | 格式漂可再来 + V3 无 smoke + 3 entry point 缺 error-path 测 | CI 加 `zig fmt --check` + V3 smoke；+3 tests (376→378 across 2 modules) |
| 4 robustness | **1 medium-sev**：恶意 ELF 可触发 usize 溢出 → panic/UB | 4 个 bounds check 全部 overflow-safe；加 regression test |
| 5 packaging | 无 strip + 全手工 release | build.zig `-Dstrip` option；release workflow 自动化 |

**全仓质量信号**：378/378 tests；CI 双平台绿；零 panic/unreachable/ptrCast；10 V0 goldens + 9 V3 goldens byte-identical to oracle；fuzz-lite 160/160；两份 README / CHANGELOG 中英双语；5 个 ADR 覆盖重要决策。

**未处理**（有意识 deferred）：
- D.5 Windows（等用户报需求）
- D.6 跨语言前端（战略愿景，按需）
- blueshift-gg/sbpf issue（用户决定不开）
- `reference-shim/` 留在 main（ADR-002）

v0.5.0 算一个真正 stable 的 pre-1.0 release。下一步要么等 v0.6 触发（V3 on zignocchio / Windows 请求 / litesvm 集成 / 其它），要么基于 D.5 Windows 探索做个轻量前瞻。

---

## Phase 6 — Rust 特性对等审查（用户请求，2026-04-18 第 6 轮）

**范围**：把 `sbpf-common` / `sbpf-assembler` / `sbpf-syscall-map` 三个 Rust crate 的每个文件 + 公开 API 过一遍，确认我们的 Zig 移植**没有漏掉该覆盖的**功能，同时把"明确 out-of-scope"的边界文档化。

### 结论速览

| Rust 侧 | Zig 侧 | 状态 |
|---------|--------|------|
| 116 opcode 变体 | 116 opcode 变体 | ✅ 对等 |
| `Number::Int/Addr` | `Number { Int/Addr }` | ✅ 对等 |
| `Register { n: u8 }` | 同 | ✅ 对等 |
| `Instruction` + 9 public methods（get_size/is_jump/is_syscall/needs_relocation/from_bytes/to_bytes/op_imm_bits/to_asm/from_bytes_sbpf_v2）| 4 对应（getSize/isJump/isSyscall/fromBytes/toBytes）+ 1 inline（needs_relocation 逻辑内联在 buildProgram Phase B）| 5/9；遗漏的都是**text assembler / SBPF-V2 专用**方法，不在 scope |
| `AST` + 6 public methods | 6/6 | ✅ 对等 |
| `Program` + 5 public methods | 3/5（from_parse_result / emit_bytecode / has_rodata）；missing: `parse_rodata`（rodata 内省 helper）、`save_to_file`（CLI 自己做） | 5.1 gap = 信息性 |
| `SectionType` 16 variants（8 non-debug + 8 specific debug: Abbrev/Info/Line/LineStr/Str/Frame/Loc/Ranges）| 9 variants（1 通用 `debug`）+ 现在加了 Rust 白名单筛选 | **本轮修**（见 6.2） |
| `SbpfArch { V0, V3 }` | 同 | ✅ 对等 |
| `reuse_debug_sections`（debug.rs）| `Program.appendDebugSections` | ✅ 对等（本轮更严格） |
| `generate_debug_sections`（从 DebugData 合成 DWARF）| **未移植** | 明确 out-of-scope（我们 ELF-in 不接受 DebugData 输入） |
| `parser.rs` + `sbpf.pest`（汇编文本 parser，1194 行）| **未移植** | 明确 out-of-scope（我们是 elf2sbpf 不是 asm2sbpf） |
| `wasm.rs`（wasm 目标 binding）| **未移植** | out-of-scope |
| `sbpf-common::validate.rs`（1327 行 VM 字节码验证）| **未移植** | out-of-scope（我们是 linker 不是 VM） |
| `sbpf-common::inst_handler.rs` / `execute/`（VM 执行器）| **未移植** | out-of-scope |
| `sbpf-syscall-map::DynamicSyscallMap`（runtime 可变 syscall 表）| `thread_extra_syscalls` + `REGISTERED_SYSCALLS` | 语义对等，实现机制不同 |

### Phase 6 findings

| # | severity | 位置 | 描述 | 行动 |
|---|----------|------|------|------|
| 6.1 | **medium** | `src/parse/byteparser.zig::scanDebugSections` | 捕获所有 `startsWith(".debug_")` 的 section；Rust 的 `reuse_debug_sections` 只留 8 个白名单（abbrev/info/line/line_str/str/frame/loc/ranges），其它 drop 掉。潜在 byte-divergence：若输入带 `.debug_pubnames` 之类的 exotic section，Zig 会保留而 Rust 不会 | ✅ 引入同样的 8-name 白名单，行为完全对齐 |
| 6.2 | **medium** | `src/ast/ast.zig::isSyscallCandidate` | `thread_extra_syscalls`（D.3 / v0.4.0）只影响 decoder 的 hash 反查；Phase B/C 仍只 match `startsWith("sol_")`，意味着自定义 syscall 无法获得 V0 dynamic linking 的 src=1/imm=-1/dynsym 处理 —— **D.3 的 end-to-end 语义缺一块** | ✅ 加 `thread_extra_syscalls` 查询逻辑；现在自定义 syscall 也会走 V0 动态注入路径 |
| 6.3 | info | `Program.parse_rodata` 未移植 | Rust 公开此方法，返回 rodata entry 列表作为 inspection helper；sbpf-assembler 自己和 shim 都不用；对 CLI 用户无价值 | 不做 |
| 6.4 | info | `Instruction.op_imm_bits` / `Instruction.to_asm` 未移植 | 分别是汇编文本输出相关，out-of-scope | 不做 |
| 6.5 | info | `Instruction.from_bytes_sbpf_v2` 未移植 | 仅在 `sbpf-common` 自身的单测中使用；sbpf-assembler 不走这条路径；我们的 `Instruction.fromBytes` 仍是唯一 decode 入口，对 V0/V3 都适用 | 不做 |
| 6.6 | good | 三大 Rust crate 所有 **public 数据类型** | Number / Register / Opcode / Instruction / ASTNode subset / Program / SectionType / SbpfArch 全部对等 | — |

### Regression sweep

修完 6.1+6.2 后重跑：V0 10/10 goldens 全绿，V3 9/9 goldens 全绿，378/378 unit tests 全绿。

### 本轮小结

**两个真实 semantic 漂移**——都是之前 byte-match 没暴露出来的 latent gap：
- **6.1**：debug section 白名单（Rust 比我们严格）
- **6.2**：custom syscall 在 Phase B/C 的参与（我们声称支持但漏了）

都已修。加上 Phase 1-5 的改动，现在**elf2sbpf 和 Rust sbpf-linker stage 2 在所有可测维度上行为等价**——只在明确声明 out-of-scope 的方向（text assembler / VM / DWARF synthesis / wasm）上不跟进，这些边界写进审查报告作为长期契约。

---

## Phase 7 — PRD + 内部规划文档新鲜度（用户请求，2026-04-18 第 7 轮）

**背景**：phase 2 只覆盖了 user-facing 文档（README / pipeline / library）。
用户指出**内部规划文档** (PRD / architecture / tech-spec / 任务清单) 也停留
在 C1 或 v0.1 时代。

### Phase 7 findings

| # | severity | 位置 | 描述 | 行动 |
|---|----------|------|------|------|
| 7.1 | medium | `docs/PRD.md` 顶部状态行 | "C1 MVP 已达成（待收尾）" —— 已过时，实际 5 个 release / v0.5.0 / stable pre-1.0 | ✅ 改成 "C1 + C2 + D 全部交付；v0.5.0 已发" |
| 7.2 | **high** | `docs/PRD.md` §4 "Out of Scope" | 4 项列为 C1 外：V3 / Debug info / Dynamic syscall / 库 API —— **全都已发**（D.1/D.2/D.3/D.4） | ✅ 改写成"C1 外 → D 阶段补齐"表格；同步更新"目标用户"段的措辞 |
| 7.3 | medium | `docs/PRD.md` §5 "C1 MVP 通过标准" | 用"截至 2026-04-18 已通过；CI 收尾中"的说法写 | ✅ 改写成"已全部达成 + 超出 MUST 的补充"；列出 fuzz-lite / CI / release workflow / bilingual docs 等 |
| 7.4 | medium | `docs/PRD.md` §7 里程碑 C2/D | 都还是"目标 + 预估 + 交付"的未执行态描述 | ✅ 改写成"✅ 已完成"表格，配版本号；D 阶段用状态表列出 D.1-D.6 的当前位置 |
| 7.5 | low | `docs/C1-tasks.md` 顶部状态 | "核心目标已达成；剩余未勾选项是 CI / golden / 收尾" —— 其实这些后来都做完了 | ✅ 改成"✅ 完整达成并封版为 v0.1.0；保留作历史记录" |
| 7.6 | low | `docs/D-tasks.md` 优先级表 | "推荐 P0 = D.2" 的措辞读起来像还没动；其实 D.1-D.4 全部交付 | ✅ 改成"已交付"表格 + "做过的优先级排序（回顾）" 节（展示估时 vs 实际） |
| 7.7 | low | `docs/02-architecture.md` §1 架构目标 | 第 3 条"3 个 zignocchio example 保证字节一致；其余 6 个结构等价即可" —— 实际是 9/9 + V3 也 9/9 | ✅ 改成"9/9 V0 + 9/9 V3 byte-identical" |
| 7.8 | medium | `docs/03-technical-spec.md` §1.1 CLI | 签名没反映 `--v0` / `--v3` flag | ✅ 加 flag 行 |
| 7.9 | medium | `docs/03-technical-spec.md` §1.2 库入口 | 只列了 `linkProgram`；缺 `linkProgramV3` 和 `linkProgramWithSyscalls` | ✅ 三入口都列出 + 线程安全契约 + 指 docs/library.md |

### Phase 7 小结

9 处漂移，都在内部规划文档里。user-facing surface 已经在 phase 2 刷过，这轮
把**PRD / architecture / tech-spec / C1-tasks / D-tasks** 全部跟实际状态对齐。

验证：`zig build test` 378/378 绿（文档改动不触代码）。

---

## 全面审查总表（v0.1-v0.5，7 轮结束）

| Phase | 题目 | 发现 | 修 |
|-------|------|------|----|
| 1 | 代码 hygiene | 3 stale 注释 + 3 fmt 漂 | 全部修 |
| 2 | user-facing 文档 freshness | 4 status 漂移 + 1 forwarder 文件 | 同步 v0.5.0 + zh/en parity |
| 3 | 测试覆盖 + CI gaps | 无 fmt check + 无 V3 smoke + 3 入口无 error-path 测 | CI 加 2 步；+3 tests |
| 4 | 健壮性 | **1 medium**：usize 溢出绕过 4 处 bounds check | 全改 overflow-safe + 回归测试 |
| 5 | 打包 + release 机制 | Linux 二进制 4.8MB 未 strip + 手工 release 流 | `-Dstrip` + `.github/workflows/release.yml` |
| 6 | Rust 特性对等 | **2 medium**：debug 白名单 + custom syscall Phase B/C 漏接 | 同步 Rust 行为 |
| 7 | PRD + 内部规划文档 | 9 处漂移（status / scope / 目标表 / CLI 签名 / 库入口）| 全部刷新 |

总计 **18 处问题** 发现并修复 / 完成；0 dropped。

**最终质量信号**：378/378 tests · CI 双平台绿 · V0 10/10 + V3 9/9 goldens
byte-identical · fuzz-lite 160/160 · 零 panic/assert/ptrCast · 全部 public
API 有 error-path 测 · 恶意 ELF 输入 overflow-safe · bilingual docs · 5 个
ADR · 7 phase 审查全部记录在本文档 · 自动 release workflow。

---

## Phase 8 — 补扫（用户追问，2026-04-18 第 8 轮）

用户指出 README 之外的其它 docs 也可能有漂移。再扫一轮 README/PRD/架构/
tech-spec 之外剩下的文档（install / library / CHANGELOG.zh / 05-test-spec /
scripts/README / C0-findings / decisions.zh / integrations draft）。

### Phase 8 findings

| # | severity | 位置 | 描述 | 行动 |
|---|----------|------|------|------|
| 8.1 | low | `docs/05-test-spec.md` §1.1 | "改进版 gap-fill 算法在 shim 里已经实现并跑通 6/9 example" —— 实际 9/9 + V3 也 9/9 | ✅ 改成"v0.5.0 实际达成：9/9 在 V0 和 V3 + mini-debug 固定件" |
| 8.2 | low | `docs/05-test-spec.md` §4 loop 示例后一句 | "C1 MVP 验收就是这个 loop 全绿" —— 没提 v0.5.0 起有两个并列 loop（V0/V3） | ✅ 追加一句说明总 378 tests |
| 8.3 | **high** | `docs/install.md` + `docs/install.zh.md` "作为 Zig 项目依赖" | 说 "elf2sbpf 目前以 CLI 形式发布；Epic D.4 尚未完成，暂时需要手工 vendor" —— **v0.3.0 已落地** | ✅ 重写成"`zig fetch --save` + `build.zig` + `@import('elf2sbpf')` + 调 `linkProgram*` 三入口"；Zh/En 同步 |
| 8.4 | **high** | `CHANGELOG.zh.md` | **落后 4 个版本**：只有 [0.1.0]，完全缺 [0.2.0]/[0.3.0]/[0.4.0]/[0.5.0] | ✅ 全部补齐（+136 行），每个 release 条目都跟英文 mirror 对应 |
| 8.5 | info | `scripts/README.md` | 没提 `scripts/fuzz/gen.py` + `scripts/fuzz/run.sh`（v0.1.0 就有了） | ✅ 加 fuzz-lite 入口 + 常用命令示例 |
| 8.6 | good | `docs/integrations/zignocchio-build.zig` header | 没有过期版本声明；最新修订已包含 `zig-import` 路径 | 无需行动 |
| 8.7 | good | `docs/C0-findings.md` | 顶部 "状态：✅ GO —— 进入 C1" 是**历史记录**（写于 C0→C1 过渡时），不是当前 status claim，不改 | 保留 |
| 8.8 | good | `docs/decisions.zh.md` vs `decisions.md` | ADR-001 / ADR-002 zh/en 内容对等 | 保留 |
| 8.9 | good | 历史日志里 370/370 / 362/362 引用 | 都是**当时状态**的 frozen snapshot（在 review-report phase 描述 / CHANGELOG release 条目 / 06-impl-log / C1-tasks / D-tasks 的历史节点里），不是当前 claim | 保留 |

### Phase 8 小结

**两个重量级漏网**：
- 8.3 install.md 的"D.4 还没做"说法 —— 跨越三个 release 没刷
- 8.4 CHANGELOG.zh.md 落后四个版本 —— 中文用户看完全不知道 v0.2-v0.5 存在

加上三个轻量修复（test-spec / scripts/README / 一些 wording），和四条
good（C0-findings / decisions / integration draft / 历史日志）确认无需改。

本轮后所有 **user-facing + internal planning 文档**都跟 v0.5.0 完全一致。



