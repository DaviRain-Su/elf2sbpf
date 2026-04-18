# Changelog

[English version](CHANGELOG.md)

本仓库遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/) 风格，
版本号遵循 [SemVer](https://semver.org/)。日期格式 `YYYY-MM-DD`。

## [Unreleased]

- D.5 Windows 支持 —— 等 Windows 用户提需求
- D.6 跨语言前端 —— 等生态触发
- v0.1–v0.5 各版本的综合审查已完成（见 `docs/07-review-report.md`）

## [0.5.0] — 2026-04-18

D.1 —— SbpfArch V3 端到端。

### Added

- **`elf2sbpf.linkProgramV3(allocator, elf_bytes)`** —— V3 后端的库
  入口。对 9 个 zignocchio example 产物都跟 `reference-shim --v3`
  byte-identical
- **CLI 加 `--v3` / `--v0` flag**：`elf2sbpf --v3 in.o out.so`；
  `--v0` 是默认（兼容 v0.1）
- **9 个 V3 goldens** 入库 `src/testdata/<example>.v3.shim.so`；
  新集成 loop `9 zignocchio examples byte-match reference-shim under V3`
- **reference-shim `--v3` / `--v0` flag**：让 oracle 能产出 V0 或 V3，
  新增 `parse_bytecode_ex(bytes, arch)`

### Fixed

- **V3 `layoutV3`**：rodata PH 用 padded rodata size（原本对 shim
  off-by-one）
- **V3 shstrtab name_offset**：V3 里 shstrtab 自己的 `sh_name` 指向
  `.rodata` 和 `.s` 之间的空字符串，而不是 `.s` 本身（跟 Rust
  program.rs L137-141 一致）
- **V3 section_names canonical 顺序**：`[".text", ".rodata"]`，即使
  section table 里 rodata 在前；shstrtab 按 canonical 顺序布字
- **V3 syscall hash encoding**：AST Phase C 把 u32 murmur3 hash 通过
  i32 bit-cast 处理，避免高位 set 的 hash 触发 `resolvedI32` 的
  i32.max 检查

### Supported

- SBPF V0（默认不变）
- **SBPF V3**（新）：固定 vaddr（rodata @ 0，code @ 1<<32）、无
  PT_DYNAMIC、无动态 relocation、静态 syscall 解析

### Test counts

370/370（原 368；V3 sweep +2）；10 V0 byte-diff goldens + 9 V3
byte-diff goldens 全部 MATCH。

## [0.4.0] — 2026-04-18

D.3 —— 自定义 syscall registry。

### Added

- **`elf2sbpf.linkProgramWithSyscalls(allocator, elf_bytes, extras)`**
  —— 跟 `linkProgram` 一样，但调用方可以注册额外的 syscall 名，解码
  `call src=0, imm=<hash>` 时它们的 murmur3-32 hash 会被反查。适合
  Solana runtime fork / 研究 VM / 带自定义 syscall 的实验程序
- **threadlocal 机制**（`common/syscalls.zig` 的
  `thread_extra_syscalls`）：`nameForHash` 除了查内置
  `REGISTERED_SYSCALLS`，还会 fallback 到 caller 注册的 extras。用
  threadlocal 而不是参数穿透，避免 `Instruction.fromBytes` 每条
  decode 路径都改 API；顶层调用 save/restore，嵌套和并发不会漏
- **`docs/library.md`** 新增 "Custom syscalls" 一节

### Changed

- `nameForHash` 先查 `REGISTERED_SYSCALLS`，找不到再看
  `thread_extra_syscalls`。对不用 threadlocal 的调用方
  （`linkProgram` 默认）行为不变

### Compatibility

- 零破坏变更：`linkProgram` 保留 v0.1 签名和语义；只用内置 syscall
  的程序产物字节不变
- `linkProgram(a, b)` 恰好等价于 `linkProgramWithSyscalls(a, b, &.{})`

## [0.3.0] — 2026-04-18

D.4 —— Zig 库 API。

### Added

- **公开的库 API 契约**（`docs/library.md`）：`zig fetch --save` 指引；
  下游 `build.zig` 接入代码；`linkProgram` 完整调用示例；稳定性分级
  表（`✅ stable` vs `⚠️ churn-eligible`）；CLI-vs-library 选型指南
- **下游 consumer 实测**：合成项目通过 `build.zig.zon` 依赖 elf2sbpf
  + `@import("elf2sbpf")` 调 `linkProgram` → 产物跟 CLI 字节一致
  （也就是跟 `reference-shim` golden 一致）

### Changed

- zignocchio 集成草稿（`docs/integrations/zignocchio-build.zig`）
  简化为 elf2sbpf-only 单路径 —— 不再有 `-Dlinker` 分派，就一句
  `zig build -Dexample=<name>`。上游 PR 更干净。9 个 example 依旧
  byte-identical

### Stable public API（v0.x SemVer 契约）

```
elf2sbpf.linkProgram(allocator, elf_bytes) → LinkError![]u8
elf2sbpf.LinkError                          (error set)
elf2sbpf.Program                            (struct, read-only OK)
elf2sbpf.Program.fromParseResult(...)
elf2sbpf.Program.emitBytecode(allocator) → ![]u8
elf2sbpf.SbpfArch                           (enum V0 / V3)
```

更深的内部层（`byteparser.*` / `AST` / `ParseResult` 形状 /
`Instruction` 字段细节）作为给框架作者的 re-export，可能在 minor
版本间演进——见 `docs/library.md`。

## [0.2.0] — 2026-04-18

D.2 —— Debug info 保留。

### Added

- **`.debug_*` section pass-through**：elf2sbpf 现在把 `.debug_loc /
  .debug_abbrev / .debug_info / .debug_str / .debug_line` 等从输入
  `.o` 保留到输出 `.so`，插在最后一个 image section 和 `.shstrtab`
  之间。产物跟 `reference-shim` byte-identical
- **`Program.appendDebugSections`** helper：port 自 Rust
  `sbpf-assembler::debug::reuse_debug_sections`。在三个 layout 分支
  （V0 dynamic / V0 static / V3）里都调
- **mini-debug 测试 fixture**（`src/testdata/mini-debug.{c,o,shim.so}`）：
  一个用 `zig cc -g` 编的 C 程序，包含 5 个不同的 `.debug_*`
  section。9 个 zignocchio example 用 `-O ReleaseSmall` 没带 DWARF，
  所以 mini-debug 是唯一实际走这条代码路径的 byte-diff —— 现在是
  `integration_test.zig` goldens 的一员（10/10 MATCH）

### Changed

- `DebugSection.size()` 返回 8-byte padded 尺寸（跟 Rust section.rs
  L663-667 对齐）；`bytecode()` 用 0 补到同一边界；
  `sectionHeaderBytecode` 里 `sh_size` 保留**未 padded** 的 data
  长度

### Known issues

- 支持的 arch 或 CLI 表面没变；V3 / 动态 syscall / Windows 仍按
  `docs/D-tasks.md` 的排期延后

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

[Unreleased]: https://github.com/DaviRain-Su/elf2sbpf/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.5.0
[0.4.0]: https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.4.0
[0.3.0]: https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.3.0
[0.2.0]: https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.2.0
[0.1.0]: https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.1.0
