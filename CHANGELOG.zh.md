# Changelog

[English version](CHANGELOG.md)

本仓库遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/) 风格，
版本号遵循 [SemVer](https://semver.org/)。日期格式 `YYYY-MM-DD`。

## [Unreleased]

- 视反馈而定。zignocchio PR 合并后可能带来后续迭代。
- V3 / debug info 等 D 阶段功能继续按生态需求排优先级。

## [0.1.0] — 2026-04-18

首个对外发布。C1 MVP 已完成，C2 的主要收尾、回归防线和上游集成也已到位。

### Added — C2 成果（继 C1 之上）

- **Fuzz-lite 回归防线**（`scripts/fuzz/`）：随机 zignocchio 风格
  example 生成器 + 字节对拍 harness；160/160 MATCH 实测
- **GitHub Actions CI**：push / PR 自动跑 `zig build test` + CLI
  smoke（`ubuntu-latest` + `macos-latest`）
- **zignocchio 集成 Draft PR**：`Solana-ZH/zignocchio#1`，默认
  `-Dlinker=elf2sbpf`，可回退 `-Dlinker=sbpf-linker`
- **LICENSE**（MIT）、`docs/install.md`、`docs/decisions.md`
  （ADR-001/002）、完整 `docs/C2-tasks.md`
- **运行时验证决策（ADR-001）**：不引入 litesvm / solana-sbpf
  桥接；在当前阶段字节对等已足以传递覆盖 runtime，双 oracle failure
  概率可忽略

### Added — C1 成果

- **Zig 0.16 原生实现**：完整 port Rust `sbpf-linker` stage 2 到 Zig，
  elf2sbpf 本身零 Rust / libLLVM 依赖
- **9/9 zignocchio example 与 `reference-shim` 字节完全一致**
  （`hello` / `noop` / `logonly` / `counter` / `vault` /
  `transfer-sol` / `pda-storage` / `escrow` / `token-vault`；
  规模从 304 B 到约 20 KB）
- **改进版 rodata gap-fill 算法**：正确处理 Zig/clang 默认产出的
  仅含 `STT_SECTION` 符号且包含多字符串的 `.rodata.str1.1`
- **CLI**：`elf2sbpf input.o output.so` 端到端可用
- **zignocchio 集成草稿**：`docs/integrations/zignocchio-build.zig`
- **Syscall 反查表**：30 个标准 Solana syscall 的 Murmur3 hash → name
  反查
- **完整 dev-lifecycle 文档集**：PRD / Architecture / Technical Spec /
  Test Spec / Task Breakdown / Implementation Log / Decisions

### Supported

- Solana SBPF V0（dynamic + static）
- BPF ELF 目标文件输入（来自 Zig / clang / 任意 LLVM BPF 前端）
- macOS arm64 + Linux x86_64（CI 验证）

### Not supported (deferred)

- SbpfArch V3（推到 D.1）
- Debug info（`.debug_*`）保留（推到 D.2）
- 动态 syscall relocation（推到 D.3）
- 作为 Zig 库被 import（推到 D.4）
- Windows（推到 D.5）

### Known issues

- `scripts/validate-zig.sh` 依赖 zignocchio 源码仓；CI 里跳过，
  只跑 committed golden 的 byte-diff 路径
- macOS 上如果回退到 `sbpf-linker`，用户可能仍需手动：
  `export DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/opt/llvm/lib`
  这是原 `sbpf-linker` 的平台限制，不属于 elf2sbpf 本身

### Acknowledgments

port 自 [blueshift-gg/sbpf-linker](https://github.com/blueshift-gg/sbpf-linker)
（byteparser + CLI）和 [blueshift-gg/sbpf](https://github.com/blueshift-gg/sbpf)
（common + assembler crates）。`reference-shim/` 按 ADR-002 保留在仓库内，
作为字节对等 oracle。

---

[Unreleased]: https://github.com/DaviRain-Su/elf2sbpf/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.1.0
