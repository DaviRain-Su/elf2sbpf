# Changelog

本仓库遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/) 风格，
版本号遵循 [SemVer](https://semver.org/)。日期格式 `YYYY-MM-DD`。

## [Unreleased]

- 视反馈而定。zignocchio PR 合并后可能带来后续迭代；V3 / debug info
  等 D 阶段功能继续按生态需求排优先级。

## [0.1.0] — 2026-04-18

首个对外发布。C1 MVP + C2 的内部收尾 / 回归防线 / 上游集成都到位。

### Added — C2 成果（继 C1 之上）

- **Fuzz-lite 回归防线**（`scripts/fuzz/`）：随机 zignocchio 风格
  example 生成器 + 字节对拍 harness；160/160 MATCH 实测
- **GitHub Actions CI**：push / PR 自动跑 `zig build test` + CLI
  smoke（ubuntu-latest + macos-latest）
- **zignocchio 集成 Draft PR**：Solana-ZH/zignocchio#1 ——
  `-Dlinker=elf2sbpf` 默认 / `-Dlinker=sbpf-linker` 回退
- **LICENSE**（MIT）、`docs/install.md`、`docs/decisions.md`
  （ADR-001/002）、完整 C2-tasks.md
- **运行时验证决策**（ADR-001）：不引入 litesvm / solana-sbpf
  桥接；字节对等传递覆盖 runtime，双 oracle failure 概率可忽略

### Added — C1 成果

- **Zig 0.16 原生实现**：完整 port Rust `sbpf-linker` stage 2 到 Zig，
  零 Rust / libLLVM 依赖
- **9/9 zignocchio example byte-identical to `reference-shim`**
  （hello / noop / logonly / counter / vault / transfer-sol /
  pda-storage / escrow / token-vault；304 B 到 20 KB 规模）
- **改进版 rodata gap-fill 算法**：正确处理 Zig/clang 默认产出的
  `.rodata.str1.1`（只有 STT_SECTION 符号、多字符串的情况）
- **CLI**：`elf2sbpf input.o output.so` 端到端可用
- **zignocchio 集成草稿**：`docs/integrations/zignocchio-build.zig`
- **Syscall 反查表**：30 个标准 Solana syscall 的 murmur3 hash →
  name 反查
- **完整 dev-lifecycle 文档**（全部中文）：PRD / Architecture /
  Technical Spec / Test Spec / Task Breakdown / Implementation
  Log / Decisions

### Supported

- Solana SBPF V0（dynamic + static）
- BPF ELF 目标文件输入（Zig / clang / 任何 LLVM BPF 前端产出）
- macOS arm64 + Linux x86_64（CI 验证）

### Not supported (deferred)

- SbpfArch V3（推到 D.1）
- Debug info（`.debug_*`）保留（推到 D.2）
- 动态 syscall relocation（推到 D.3）
- 作为 Zig 库被 import（推到 D.4）
- Windows（推到 D.5）

### Known issues

- `scripts/validate-zig.sh` 依赖 zignocchio 源码仓；CI 里跳过，
  只跑 committed golden 的 byte-diff
- `sbpf-linker` 作为 fallback 时在 macOS 上需要用户手动
  `export DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/opt/llvm/lib`
  （这是原 sbpf-linker 的平台限制，不属于 elf2sbpf 范围）

### Acknowledgments

port 自 [blueshift-gg/sbpf-linker](https://github.com/blueshift-gg/sbpf-linker)
（byteparser + CLI）和 [blueshift-gg/sbpf](https://github.com/blueshift-gg/sbpf)
（common + assembler crates）。`reference-shim/` 目录保留（ADR-002）
作为字节对等 oracle。

### Added
- **Zig 0.16 原生实现**：完整 port Rust `sbpf-linker` stage 2 到 Zig，
  零 Rust / libLLVM 依赖
- **9/9 zignocchio example byte-identical to `reference-shim`**
  （hello / noop / logonly / counter / vault / transfer-sol /
  pda-storage / escrow / token-vault；304 B 到 20 KB 规模）
- **GitHub Actions CI**：ubuntu-latest + macos-latest 矩阵，每 push / PR
  自动跑 `zig build test` + CLI smoke test
- **改进版 rodata gap-fill 算法**：正确处理 Zig/clang 默认产出的
  `.rodata.str1.1`（只有 STT_SECTION 符号、多字符串的情况），原
  `sbpf-linker` 在这个场景下会 regression 成单大块 anon entry
- **CLI**：`elf2sbpf input.o output.so` 端到端可用；LinkError 错误
  枚举覆盖所有失败路径
- **zignocchio 集成草稿**：`docs/integrations/zignocchio-build.zig` —
  drop-in build.zig，`-Dlinker=elf2sbpf` 默认 / `-Dlinker=sbpf-linker`
  legacy 回退
- **Syscall 反查表**：30 个标准 Solana syscall 的 murmur3 hash →
  name 反查，让 Zig BPF 编译器 bake-in 的 V3 hash 能正确转回 V0 形式
- **完整 dev-lifecycle 文档**：PRD / Architecture / Technical Spec /
  Test Spec / Task Breakdown / Implementation Log 全部到位
  （所有文档中文）

### Supported
- Solana SBPF V0（dynamic + static）
- BPF ELF 目标文件输入（Zig / clang / 任何 LLVM BPF 前端产出）
- macOS arm64 + Linux x86_64

### Not supported (deferred)
- SbpfArch V3（推到 C2+ / D.1）
- Debug info（`.debug_*`）保留（推到 D.2）
- 动态 syscall relocation（推到 D.3）
- 作为 Zig 库被 import（推到 D.4）
- Windows（推到 D.5）

### Known issues
- `scripts/validate-zig.sh` 依赖 zignocchio 源码仓；CI 里跳过，只跑
  committed golden 的 byte-diff

### Acknowledgments
port 自 [blueshift-gg/sbpf-linker](https://github.com/blueshift-gg/sbpf-linker)
（byteparser + CLI）和 [blueshift-gg/sbpf](https://github.com/blueshift-gg/sbpf)
（common + assembler crates）。`reference-shim/` 目录保留了 Rust
oracle 的最小实现，C1 阶段作为字节对等基准使用。

---

[Unreleased]: https://github.com/DaviRain-Su/elf2sbpf/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.1.0
