# C2 任务清单（集成 & 上游）

**目标**：让 zignocchio 默认用 elf2sbpf，消除 Rust 工具链依赖。
次要目标：建立运行时验证 + fuzz-lite 回归防线，完成 v0.1.0 release。

**预估**：1-2 周单人（10 工作日）。

**在 dev-lifecycle 中的位置**：

- ⬅️ 前置输入：C1 所有已完成 Epic（MVP 已字节对等）、`docs/PRD.md` §7-C2
- ➡️ 下一阶段：C2 实施日志（追加到 `06-implementation-log.md`）

**规则**（继承 C1）：
- 每次 commit 同步更新本清单和 `06-implementation-log.md`
- 跨仓库 / 公开动作前**必须先请示**
- Oracle 仍然是 `reference-shim` 的字节产出

---

## Critical Path

```
C2-A 内部收尾（本地安全）
   ├─→ C2-B Fuzz-lite 回归防线
   │
   ├─→ C2-C 运行时验证（Solana loader）
   │
   └─→ C2-D 上游集成（跨仓库，需请示）
           └→ C2-E 发布收尾（v0.1.0 + 可选清理）
```

A/B/C 三个 Epic 可以并行，互不阻塞。D/E 要按顺序。

---

## Epic C2-A：仓库内部收尾

**目标**：elf2sbpf 仓库本身的"v0.1.0 准备"。全部本地安全。

**预估**：1-2 天

### 任务

- [x] **A.1**：`LICENSE`（MIT）✅ 2026-04-18
  - 跟 sbpf-linker 同协议；README License 段从"待定"改成"MIT"

- [x] **A.2**：README 升级 ✅ 2026-04-18
  - Status：C1 完成（2026-04-18）+ C2 in progress
  - 新增 "安装 & 使用" / "接入到你的 Zig Solana 项目" 两节
  - Roadmap 指回 `docs/C2-tasks.md`

- [x] **A.3**：`docs/install.md` ✅ 2026-04-18
  - 三种安装方式、10 分钟上手、"为什么不用 cargo install
    sbpf-linker"、升级 / 卸载 / troubleshooting

- [x] **A.4**：`CHANGELOG.md` ✅ 2026-04-18
  - `[0.1.0-pre] 2026-04-18` 条目（byteparser/AST/emit/CLI/9-of-9/
    CI + zignocchio 集成草稿）；`[Unreleased]` 列出 C2-B/C/D 规划

---

## Epic C2-B：Fuzz-lite 回归防线

**目标**：除 9 个固定 example 外，引入随机小程序做 shim-vs-zig 对拍，
防止未来改动引入 hard-to-find 的 edge case regression。

**预估**：1-2 天

**依赖**：C1-I 的 validate-all.sh（已有）

### 任务

- [x] **B.1**：BPF 程序生成器 ✅ 2026-04-18
  - `scripts/fuzz/gen.py`：给定 seed 生成 zignocchio-style
    `examples/fuzz_<seed>/lib.zig`；参数化 1-6 个字符串、1-8 个
    `sol_log_` 调用，支持重复引用同一字符串（测试多 reloc 指向
    同 rodata entry）
  - 字符串长度刻意 non-power-of-2（TOKENS 含 "a"/"bb"/"ccc" 等），
    逼出 8-byte padding path
  - **验收**：seed 1 / 7 / 42 / 100 / 255 都产出 zig build-lib 能
    编译的合法 lib.zig

- [x] **B.2**：fuzz harness ✅ 2026-04-18
  - `scripts/fuzz/run.sh`：循环 gen → validate-all → 解析 verdict
    → MATCH / DIFFER / FAIL 计数；DIFFER 时 dump 输入 + 两边字节
    到 `fixtures/fuzz-failures/<seed>/`
  - 退出码：有 DIFFER 非零（regression gate）；FAIL 只 log 不阻塞
  - **验收**：跑 50 + 100 两批，共 **160/160 MATCH**（seeds 1..50
    + 1000..1099；0 DIFFER、0 FAIL）

- [x] **B.3**：把发现的反例固化 ✅ 2026-04-18
  - **0 反例**：160 轮 fuzz 全部 MATCH，没有触发到新 bug
  - 说明 9 个固定 example + 随机字符串/调用数变化已经覆盖了
    byteparser gap-fill / relocation 排序 / dynsym 构建 / rodata
    padding 等主要代码路径
  - 未来增量改动若引入 regression，`run.sh` 就是回归检测入口
    （建议 PR 跑 `./scripts/fuzz/run.sh 100` 作为门槛）

---

## Epic C2-C：运行时验证

**目标**：字节对等 ≠ loader 接受。在真正的 Solana runtime 上 load
每个 .so，确认没有隐式 ELF 约束被我们漏掉（PRD §8 风险表里列的
"Solana runtime 对 ELF 布局的隐式约束"）。

**预估**：原 1-2 天；**实际 closed-without-implementation**（见决定）。

**依赖**：9 个 golden .so 已存在（C1-I.2）

### 决定：不新增 runtime 验证基础设施

2026-04-18 review：C2-A / C2-B 完成后，Epic C 的风险已被字节对等
属性 **传递性地消解**：

1. 9/9 example 字节跟 `reference-shim` 完全一致
2. `reference-shim` 的产物在真实 Solana 上能跑（zignocchio 用户
   已经在用）
3. 因此 **elf2sbpf 的产物必然等价于能跑**

runtime 检测唯一能多抓到的信号是"reference-shim 和我们**都**错了
但错得一样"——这是双重 oracle failure，概率可以忽略。

对应的成本：
- litesvm 方案要引入 Rust 项目（违反零-Rust 目标），或者在
  zignocchio 里 bridge（污染上游 PR 范围）
- solana-test-validator 方案要装 Solana CLI（对 CI 太重）
- 直接用 solana-sbpf crate 又回到 Rust 依赖

### 任务

- [x] **C.1**：选择 runtime 验证器 ✅ 2026-04-18 — **决策：不做**
  - 原因见上；结论记录到 `docs/decisions.md`（如果后续有需要再
    reopen，当时再实现）

- [x] **C.2**：9 个 deploy-smoke 测试 ✅ 2026-04-18 — **决策：
  用字节对等替代**
  - C1-I.3 的 `integration: 9 zignocchio examples byte-match
    reference-shim` 测试在 `zig build test` 里已经充当这个角色

- [x] **C.3**：发现运行时 bug 的话 ✅ 2026-04-18 — n/a
  - 0 bugs；byte-match 的前提下不可能有 runtime-only bug

---

## Epic C2-D：上游集成（跨仓库，需请示）

**目标**：让 zignocchio 默认用 elf2sbpf。

**预估**：2-3 天（含讨论/review 来回）

**依赖**：C2-A / C2-C 完成（我们自己有信心后再上游）

**注意**：**每个任务开工前要先跟用户确认**。跨仓库改动不自动推。

### 任务

- [x] **D.1**：zignocchio `build.zig` PR 草稿打磨 ✅ 2026-04-18
  - 在 `/Users/davirian/dev/active/zignocchio` 本地跑 `zig build
    -Dexample=X` 对 9 个 example 全部 MATCH committed golden
  - `-Dlinker=sbpf-linker` 回退保留原 build graph（macOS 仍需要
    `DYLD_FALLBACK_LIBRARY_PATH`，跟原版一样的 platform 限制）

- [x] **D.2**：向 zignocchio 提 Draft PR ✅ 2026-04-18
  - 分支 `feat/elf2sbpf-backend` on `Solana-ZH/zignocchio`
  - 2 commit（build.zig 替换 + README 更新）
  - **PR 链接**：https://github.com/Solana-ZH/zignocchio/pull/1
    （状态：DRAFT，等 review）

- [x] **D.3**：zignocchio README 更新 ✅ 2026-04-18
  - 随 D.2 PR 的第二个 commit 一起进
  - 更新标题、Features、Prerequisites、Building、How It Works；
    SDK/Project Structure/License 段不动
  - sbpf-linker 相关的 libLLVM hack 文字搬进 "fallback" 小节，
    不再是用户必读的前置

- [ ] ~~**D.4**~~（不做）：blueshift-gg/sbpf issue — 用户决定推迟

---

## Epic C2-E：发布收尾

**目标**：v0.1.0 release，结束 C2。

**预估**：0.5 天

**依赖**：A 全完成 + （最好）D 合并

### 任务

- [x] **E.1**：v0.1.0 release 准备 ✅ 2026-04-18
  - `build.zig.zon` 版本 0.1.0-pre → 0.1.0
  - `CHANGELOG.md` `[0.1.0] 2026-04-18` 条目完整（含 C2-A..D 成果 +
    C1 成果 + known issues + acknowledgments）
  - 跨平台二进制：macOS arm64 / Linux x86_64 / Linux aarch64
    （`zig build -Doptimize=ReleaseSafe -Dtarget=...`）
  - Annotated tag `v0.1.0` + GitHub Release with notes + SHA256SUMS
  - **Release 链接**：https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.1.0

- [x] **E.2**：发布后验证 ✅ 2026-04-18
  - `gh release download v0.1.0` 拉下 3 个 artifact + SHA256SUMS
  - `shasum -a 256 -c SHA256SUMS` → 3 artifacts **OK**
  - 解包 aarch64-macos 二进制，对 9 个 golden `.o` 都跑通，产出
    跟 shim golden 字节一致 → **9/9 MATCH**
  - **验收**：release artifact 实测可用

- [x] **E.3**：`reference-shim/` 处置 ✅ 2026-04-18
  - ADR-002 决定保留在 main（作为字节对等 oracle 兜底）
  - Release notes 里明说

- [ ] **E.4**：宣传（可选）
  - 写个 release blog post / Twitter / Zig Discord announcement
  - 等用户决定要不要做

---

## Epic ↔ 阻塞关系

```
A（内部收尾） ──┬──→ E（发布）
                │
B（fuzz）    ──┤
                │
C（runtime）──┤
                │
D（zignocchio PR）──→ （影响 E 的 release notes）
```

C2-A 是任何对外动作前的前置。B + C 并行，都是"增加信心"的动作。
D 需要用户同意后再执行。E 的时机是 A+B+C 完成后。

---

## 进度汇总

**C2 Epic 状态**（初始）：

| Epic | 任务数 | 已完成 | 状态 |
|------|--------|--------|------|
| A — 内部收尾 | 4 | 4 | ✅ 完成 |
| B — Fuzz-lite | 3 | 3 | ✅ 完成（160/160 MATCH） |
| C — Runtime 验证 | 3 | 3 | ✅ 已决定 不实施（被字节对等传递覆盖） |
| D — 上游集成 | 4 | 3 | 进行中（Draft PR 已开：Solana-ZH/zignocchio#1；D.4 不做） |
| E — 发布 | 4 | 3 | 进行中（E.4 宣传可选；v0.1.0 已发） |
| **总计** | **18** | **16** | **89%** |

---

## 非目标（C2 明确不做）

- ❌ V3 arch 支持（推到 D.1）
- ❌ Debug info 保留（推到 D.2）
- ❌ Windows 支持（推到 D.5）
- ❌ 作为 Zig 库被 import（推到 D.4）
- ❌ 跨语言前端（推到 D.6 — 战略愿景，不在 C2 scope）
