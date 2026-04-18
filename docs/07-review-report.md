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
