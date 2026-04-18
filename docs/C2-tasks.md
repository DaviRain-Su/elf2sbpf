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

**预估**：1-2 天

**依赖**：9 个 golden .so 已存在（C1-I.2）

### 任务

- [ ] **C.1**：选择 runtime 验证器
  - 候选：`solana-test-validator`（sdk 提供）、`litesvm`
    （zignocchio 已用）、直接跑 solana-sbpf crate 的 VM
  - 选 litesvm（zignocchio 已经引入，零新依赖）
  - **验收**：本地能 `zig build` litesvm 并 load 一个 .so

- [ ] **C.2**：写 9 个 deploy-smoke 测试
  - 每个 example 的 .so 用 litesvm 加载；call entrypoint；断言
    ProgramResult::Success（或 logs 出现预期字符串）
  - 放到 `tests_litesvm/` 或类似目录（本地测试，不进 CI
    除非 litesvm 能跑在 GH Actions）
  - **验收**：9/9 example deploy + invoke 都绿

- [ ] **C.3**：发现运行时 bug 的话
  - dump .so 布局 + 失败原因；研究 Solana loader 逻辑
  - 补丁通常落在 emit 层（某个 header/section 字段）
  - **验收**：若有 bug 修复 + regression test；若无则在日志里记录
    "0 runtime issues found"

---

## Epic C2-D：上游集成（跨仓库，需请示）

**目标**：让 zignocchio 默认用 elf2sbpf。

**预估**：2-3 天（含讨论/review 来回）

**依赖**：C2-A / C2-C 完成（我们自己有信心后再上游）

**注意**：**每个任务开工前要先跟用户确认**。跨仓库改动不自动推。

### 任务

- [ ] **D.1**：zignocchio `build.zig` PR 草稿打磨
  - 基于 `docs/integrations/zignocchio-build.zig` 做最后调整
  - 过一遍 zignocchio 的 CI 流程，确保 `-Dlinker=elf2sbpf` 默认 +
    `-Dlinker=sbpf-linker` 回退都能跑
  - **验收**：在 zignocchio fork 上 push 分支，本地 `zig build
    -Dexample=X` 9/9 都跑通

- [ ] **D.2**：向 zignocchio 提 PR
  - PR 描述要说清楚：动机（消除 Rust 依赖）、变更范围、回退方法、
    风险、验收方式
  - 先提 Draft PR，让维护者 review
  - **验收**：PR 链接记录到 log

- [ ] **D.3**：zignocchio README + 安装文档更新（随 PR 或单独 PR）
  - 删除 "cargo install sbpf-linker" 前置
  - 加 "install elf2sbpf" 步骤
  - 更新 troubleshooting 小节（libLLVM symlink hack 不再需要）
  - **验收**：跟 D.2 的 PR 同步合并

- [ ] **D.4**（可选）：blueshift-gg/sbpf issue
  - 写 byteparser rodata gap-fill 的 multi-string STT_SECTION 限制
    现象 + 我们的改进方案
  - 附 reproducer（随便一个带 `.rodata.str1.1` 的样本）
  - **验收**：issue 链接记录；不要求一定要上游接受

---

## Epic C2-E：发布收尾

**目标**：v0.1.0 release，结束 C2。

**预估**：0.5 天

**依赖**：A 全完成 + （最好）D 合并

### 任务

- [ ] **E.1**：v0.1.0 release 准备
  - CHANGELOG [0.1.0] 条目定稿
  - `build.zig.zon` version 从 "0.1.0-pre" 改成 "0.1.0"
  - Git tag `v0.1.0` + GitHub Release（用 `gh release create`）
  - Release notes 基于 CHANGELOG + 一行 headline
  - **验收**：release 页面展示二进制 + changelog

- [ ] **E.2**：发布后验证
  - `gh release download v0.1.0` → 本地跑 hello → cmp golden
  - **验收**：release artifact 能用

- [ ] **E.3**（可选）：归档 / 删除 `reference-shim/`
  - 选项：移到 `reference-shim/`（保留 oracle 功能）、归档到
    `archive/` 分支、完全删除
  - 建议：**保留**在 main 一段时间（未来 regression 时方便回查），
    release notes 里说明
  - **验收**：决定写进 `docs/decisions.md` 或 ADR

- [ ] **E.4**：宣传（可选）
  - 写个 release blog post / Twitter / Zig Discord announcement
  - 不是必须；跟用户确认要不要做

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
| C — Runtime 验证 | 3 | 0 | 未开始 |
| D — 上游集成 | 4 | 0 | 未开始（需请示） |
| E — 发布 | 4 | 0 | 未开始 |
| **总计** | **18** | **7** | **39%** |

---

## 非目标（C2 明确不做）

- ❌ V3 arch 支持（推到 D.1）
- ❌ Debug info 保留（推到 D.2）
- ❌ Windows 支持（推到 D.5）
- ❌ 作为 Zig 库被 import（推到 D.4）
- ❌ 跨语言前端（推到 D.6 — 战略愿景，不在 C2 scope）
