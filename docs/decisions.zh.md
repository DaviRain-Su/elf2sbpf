# 架构决策记录（ADR）

[English version](decisions.md)

记录“为什么不做 X”或“为什么选 A 不选 B”这类会在未来 reviewer 问出来
的决定。每条记录包括：背景 → 决定 → 结果/代价 → 什么情况会重新考虑。

---

## ADR-001：不引入 Solana runtime 验证基础设施

**日期**：2026-04-18
**相关任务**：C2-C
**状态**：closed, will reopen only if bytewise equivalence breaks

### 背景

PRD §8 风险表列出了 “Solana runtime 对 ELF 布局的隐式约束
（我们没测到的）” 作为中等风险项，并建议 C2 阶段跑
`solana-test-validator` 或 litesvm 做运行时验证。

### 决定

不实施。理由：

1. **字节对等已经传递覆盖 runtime**：
   - 9/9 zignocchio example 的 `.so` 跟 `reference-shim` **字节完全
     一致**（见 C1-I.3 的 integration test）
   - `reference-shim` 的产物在真实 Solana 上可用（zignocchio 用户
     已经在生产中用）
   - 因此 elf2sbpf 产物必然等价于能跑

2. **成本结构不划算**：
   - litesvm 要么引入 Rust 项目（违反“零 Rust 依赖”的核心定位），
     要么污染 zignocchio 上游 PR 的范围
   - solana-test-validator 要求装 Solana CLI，CI 里重
   - 直接用 solana-sbpf crate 又回 Rust 依赖

3. **能多抓到的唯一信号是双重 oracle failure**：`reference-shim`
   和我们都错且错得一样——概率可忽略

### 结果/代价

- 代价：若 byteparser/emit 改动同时出错到跟 `reference-shim` 一致地
  错掉，runtime 才会暴露。这是二阶概率事件
- 收益：Epic C 从 1-2 天降到 0 天，C2 进度推进

### 重新考虑的触发条件

- 真实用户报告 “byte match 但部署失败”
- `reference-shim` 被判定为不再可信（unlikely，除非它本身变化）
- 有人想加 V3 或 debug info 支持，两者都可能引入 runtime 才暴露的
  bug——那时应回到 C2-C，建 litesvm 桥接

---

## ADR-002：保留 `reference-shim/` 在主分支

**日期**：2026-04-18
**相关任务**：C2-E.3（候选清理项）
**状态**：kept, re-evaluate post-v0.2

### 背景

`reference-shim/` 是 Rust 最小 shim，功能跟 elf2sbpf 重叠。C2-E.3
提议在 v0.1 发布时清理。

### 决定

保留，至少到 v0.2（或 C2 彻底完成 6 个月后）。理由：

1. **regression 快速回查**：未来若 elf2sbpf 出 regression，能直接
   `./reference-shim/target/release/elf2sbpf-shim` 对拍，不用重新
   搭环境
2. **ADR-001 的兜底**：我们依赖字节对等作为 runtime 正确性证明，
   `reference-shim` 是这个证明的 oracle。删了就没 oracle 了
3. **体积小**：`reference-shim/` 源码 2 个文件 ~400 行，targetdir
   gitignore 掉了，主 repo 没负担

### 结果/代价

- 代价：依赖关系上 repo 不是“纯 Zig”（但 .gitignore 掉 cargo 产物
  后实际上也没 Rust 工件进 repo）
- 收益：oracle 随时可用；release notes 不用解释“为什么删了”

### 重新考虑的触发条件

- 有外部贡献者因为 reference-shim 增加了阅读负担提 issue
- C2-D 上游 PR 合并后 6 个月，elf2sbpf 的正确性被社区充分验证
