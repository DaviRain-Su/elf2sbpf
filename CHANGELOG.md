# Changelog

本仓库遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/) 风格，
版本号遵循 [SemVer](https://semver.org/)。日期格式 `YYYY-MM-DD`。

## [Unreleased]

- (planned) fuzz-lite 回归防线（C2-B）
- (planned) litesvm 运行时验证（C2-C）
- (planned) zignocchio 上游 PR（C2-D）

## [0.1.0-pre] — 2026-04-18

首个对外可用版本。C1 MVP 全部验收点达成。

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

[Unreleased]: https://github.com/DaviRain-Su/elf2sbpf/compare/v0.1.0-pre...HEAD
[0.1.0-pre]: https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.1.0-pre
