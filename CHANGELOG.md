# Changelog

[中文版本](CHANGELOG.zh.md)

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and [SemVer](https://semver.org/). Dates use the `YYYY-MM-DD` format.

## [Unreleased]

- Pending feedback and follow-up work after the zignocchio PR lands.
- Further D-stage items (D.4 Zig library API, D.3 dynamic syscall registry,
  D.1 V3 arch) prioritized based on ecosystem demand.

## [0.2.0] — 2026-04-18

D.2 — Debug info preservation.

### Added

- **`.debug_*` section pass-through**: elf2sbpf now preserves
  `.debug_loc / .debug_abbrev / .debug_info / .debug_str / .debug_line`
  etc. from the input `.o`, inserted between the last image section and
  `.shstrtab`. Matches `reference-shim` output byte-for-byte.
- **`Program.appendDebugSections` helper**: port of Rust
  `sbpf-assembler::debug::reuse_debug_sections`. Invoked in all three
  layout branches (V0 dynamic / V0 static / V3).
- **Mini-debug test fixture** (`src/testdata/mini-debug.{c,o,shim.so}`):
  a C program built with `zig cc -g` to exercise the debug-preservation
  path. The 9 zignocchio examples use `-O ReleaseSmall` and have no
  DWARF, so this is the only byte-diff that exercises the new code path
  — now part of the `integration_test.zig` goldens loop (10/10 MATCH).

### Changed

- `DebugSection.size()` now returns the 8-byte-padded size (matches
  Rust `section.rs` L663-667); `bytecode()` zero-pads the data to the
  same boundary. `sectionHeaderBytecode` keeps the **unpadded** data
  length in `sh_size`.

### Known issues

- No change to supported architectures or CLI surface; V3 / dynamic
  syscall / Windows remain deferred per D-tasks.md

## [0.1.0] — 2026-04-18

First public release. C1 MVP is complete, and the main C2 hardening,
regression guardrails, and upstream integration work are already in place.

### Added — C2 deliverables on top of C1

- **Fuzz-lite regression guardrail** (`scripts/fuzz/`): randomized
  zignocchio-style example generator plus byte-diff harness; verified at
  160/160 MATCH
- **GitHub Actions CI**: automatic `zig build test` + CLI smoke tests on push / PR
  (`ubuntu-latest` + `macos-latest`)
- **zignocchio integration draft PR**: `Solana-ZH/zignocchio#1` with
  `-Dlinker=elf2sbpf` as default and `-Dlinker=sbpf-linker` as fallback
- **LICENSE** (MIT), `docs/install.md`, `docs/decisions.md` (ADR-001/002),
  and complete `docs/C2-tasks.md`
- **Runtime-validation decision (ADR-001)**: do not introduce litesvm /
  solana-sbpf bridging; bytewise equivalence already covers runtime behavior
  for this stage, and double-oracle failure is negligible

### Added — C1 deliverables

- **Native Zig 0.16 implementation**: a full port of Rust `sbpf-linker` stage 2
  to Zig, with zero Rust / libLLVM dependency in elf2sbpf itself
- **All 9 zignocchio examples byte-identical to `reference-shim`**
  (`hello`, `noop`, `logonly`, `counter`, `vault`, `transfer-sol`,
  `pda-storage`, `escrow`, `token-vault`; from 304 B to ~20 KB)
- **Improved rodata gap-fill algorithm**: correctly handles Zig/clang-generated
  `.rodata.str1.1` with only `STT_SECTION` symbols and multiple strings
- **CLI**: `elf2sbpf input.o output.so` works end to end
- **zignocchio integration draft**: `docs/integrations/zignocchio-build.zig`
- **Syscall reverse lookup table**: Murmur3 hash → name mapping for 30 standard
  Solana syscalls
- **Complete dev-lifecycle documentation set**: PRD / Architecture /
  Technical Spec / Test Spec / Task Breakdown / Implementation Log / Decisions

### Supported

- Solana SBPF V0 (dynamic + static)
- BPF ELF object input (from Zig / clang / any LLVM BPF frontend)
- macOS arm64 + Linux x86_64 (validated in CI)

### Not supported (deferred)

- SbpfArch V3 (deferred to D.1)
- Debug info (`.debug_*`) preservation (deferred to D.2)
- Dynamic syscall relocation (deferred to D.3)
- Importing elf2sbpf as a Zig library (deferred to D.4)
- Windows (deferred to D.5)

### Known issues

- `scripts/validate-zig.sh` depends on a zignocchio checkout; CI skips it and
  only runs the committed-golden byte-diff path
- When using `sbpf-linker` as fallback on macOS, users may still need:
  `export DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/opt/llvm/lib`
  This is a platform limitation of the original `sbpf-linker`, not elf2sbpf

### Acknowledgments

Ported from [blueshift-gg/sbpf-linker](https://github.com/blueshift-gg/sbpf-linker)
(byteparser + CLI) and [blueshift-gg/sbpf](https://github.com/blueshift-gg/sbpf)
(common + assembler crates). `reference-shim/` is intentionally kept in-tree
(ADR-002) as the byte-equivalence oracle.

---

[Unreleased]: https://github.com/DaviRain-Su/elf2sbpf/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.2.0
[0.1.0]: https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.1.0
