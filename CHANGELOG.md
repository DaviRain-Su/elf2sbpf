# Changelog

[中文版本](CHANGELOG.zh.md)

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and [SemVer](https://semver.org/). Dates use the `YYYY-MM-DD` format.

## [Unreleased]

- D.1 V3 arch — prioritized when Solana runtime pushes V3 as default
- D.5 Windows support — prioritized if Windows users show up
- D.6 cross-language frontends — strategic, no schedule

## [0.4.0] — 2026-04-18

D.3 — Custom syscall registry.

### Added

- **`elf2sbpf.linkProgramWithSyscalls(allocator, elf_bytes, extras)`**
  — like `linkProgram`, but the caller can register additional
  syscall names whose murmur3-32 hashes get reverse-resolved during
  `call src=0, imm=<hash>` decoding. Useful for Solana runtime forks
  / experimental VMs / research programs with custom syscalls
- **Thread-local plumbing** (`thread_extra_syscalls` in
  `common/syscalls.zig`): lets `nameForHash` consult caller-provided
  extras without threading a parameter through every decode call
  site. Save/restore around the top-level call; no state leaks across
  nested or concurrent invocations
- **`docs/library.md`** new "Custom syscalls" section

### Changed

- `nameForHash` now checks `thread_extra_syscalls` as a fallback after
  `REGISTERED_SYSCALLS`. For callers that don't set the thread-local
  (the default — `linkProgram` itself), behavior is unchanged

### Compatibility

- Zero breaking changes: `linkProgram` keeps its v0.1 signature and
  output for programs using only built-in syscalls
- `linkProgram(a, b)` is exactly equivalent to
  `linkProgramWithSyscalls(a, b, &.{})`

## [0.3.0] — 2026-04-18

D.4 — Zig library API.

### Added

- **Documented public library API** (`docs/library.md`):
  `zig fetch --save`, dependency + module wiring in `build.zig`,
  full `linkProgram` usage example, stability-tier table (`✅ stable`
  vs `⚠️ churn-eligible`), and CLI-vs-library decision guide
- **Verified downstream consumer**: synthetic project depending on
  elf2sbpf via `build.zig.zon` + `@import("elf2sbpf")` → calling
  `linkProgram` → output byte-identical to CLI path (and to
  `reference-shim` golden)

### Changed

- Simplified the zignocchio integration draft
  (`docs/integrations/zignocchio-build.zig`) to a single
  elf2sbpf-only path — no more `-Dlinker` dispatch, just
  `zig build -Dexample=<name>`. Cleaner PR surface for upstream
  adoption. All 9 zignocchio examples still produce byte-identical
  `.so` through the draft

### Stable public API (v0.x SemVer contract)

```
elf2sbpf.linkProgram(allocator, elf_bytes) → LinkError![]u8
elf2sbpf.LinkError                          (error set)
elf2sbpf.Program                            (struct, read-only OK)
elf2sbpf.Program.fromParseResult(...)
elf2sbpf.Program.emitBytecode(allocator) → ![]u8
elf2sbpf.SbpfArch                           (enum V0 / V3)
```

Deeper internals (`byteparser.*`, `AST` / `ParseResult` shape,
`Instruction` field details) are re-exported for framework authors
but may evolve between minor versions — see `docs/library.md`.

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

[Unreleased]: https://github.com/DaviRain-Su/elf2sbpf/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.4.0
[0.3.0]: https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.3.0
[0.2.0]: https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.2.0
[0.1.0]: https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.1.0
