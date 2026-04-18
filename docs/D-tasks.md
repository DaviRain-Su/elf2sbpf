# D 阶段任务清单（功能扩展）

**目标**：按生态需求逐个补足 out-of-scope 功能。**不固定时间表**，
按用户反馈 / 上游 PR / 实际使用痛点驱动。

**在 dev-lifecycle 中的位置**：

- ⬅️ 前置输入：C1 + C2 全部完成，v0.1.0 已发
- ➡️ 每个 D.x 子任务**单独走一遍 Phase 3（技术规格）+ Phase 4（拆解）**；
  不像 C1/C2 一次性拉一个清单就开干

**原则**：
- 每个 D.x 独立（不要混在一起做）；完成后发 v0.2 / v0.3 /... release
- 保底：9/9 zignocchio golden 不能破；fuzz-lite 跑 100 轮 0 DIFFER
- 从小到大：先做 ergonomics / 结构性补齐，后做大工程（V3 / Windows）

---

## 优先级排序（我的推荐）

| 优先级 | 任务 | 估时 | 理由 |
|--------|------|------|------|
| **P0** | **D.2 Debug info 保留** | 1-2 天 | 最小投入；`DebugSection` writer 已在 F.11 就位；只需接通 `Program::fromParseResult` 的 reuse 路径 + 一个带 debug 的测试 fixture。对 gdb/lldb 用户立即有价值 |
| **P1** | **D.4 Zig 库 API** | 1 天 | 低风险、高 DX 价值；zignocchio PR 合并后会吸引 Zig 框架作者来用 elf2sbpf；把 `linkProgram` / `Program.fromParseResult` 等作为公开 API 抛出来 + build.zig.zon 支持 `zig fetch` |
| **P2** | **D.3 Dynamic syscall relocation** | 1-2 天 | 把 `REGISTERED_SYSCALLS` 那个静态表换成 runtime-extensible；允许 zignocchio 框架 register 自己的 syscall |
| **P3** | **D.1 SbpfArch V3 路径** | 1-2 周 | 最大投入；Solana runtime 主推 V3 时必须做；但 V0 短期不会被淘汰 |
| **P4** | **D.5 Windows 支持** | 3-5 天 | Zig 本身跨平台；主要踩 path / file I/O 的坑；受众小 |
| **战略** | **D.6 跨语言前端** | — | 等社区有人问再做（PRD 说"扩展自然发生，不是先做好等人来用"） |

---

## D.2 — Debug info 保留

**动机**：目前 elf2sbpf 直接 drop 所有 `.debug_*` sections，导致
部署后的 `.so` 不能 gdb/lldb 调试。Rust sbpf-assembler 有
`reuse_debug_sections` 路径，`DebugSection` writer 在 F.11 已经
就位，只差把 Program.fromParseResult 的那条 dispatch 接上。

**预估**：1-2 天

**前置状态**（已就位）：
- ✅ `src/emit/section_types.zig` 的 `DebugSection` writer
- ✅ `src/emit/program.zig` 的 `SectionType.debug` union variant
- ✅ byteparser 的 `scanDebugSections` → `DebugScan`
- ✅ AST 的 `ParseResult.debug_sections` 字段
- ❌ Program.layoutV0Dynamic / layoutV3 / layoutV0Static 里对
  `pr.debug_sections` 的 reuse 逻辑（G.2 当时明确 defer 了）
- ❌ 带 debug_* 的测试 fixture

### 子任务

- [x] **D.2.1**：研究 Rust `reuse_debug_sections` ✅ 2026-04-18
  - 读了 `sbpf-assembler-0.1.8/src/debug.rs` + `section.rs` 的
    DebugSection 实现
  - 发现关键细节：Rust `DebugSection::size()` 返回 **padded** 大小；
    `bytecode()` 补 0 到 8 字节对齐；`sh_size` 保留 unpadded。port
    时需要对齐这三个语义

- [x] **D.2.2**：`layoutV0Dynamic` / `layoutV3` / `layoutV0Static`
  debug reuse ✅ 2026-04-18
  - 新增 `Program.appendDebugSections` 共享 helper
  - V0 Dynamic：把 dynamic/dynsym/dynstr/reldyn 的 push 从末尾提到
    appendDebugSections 之前（确保 section 表顺序跟 Rust 一致）
  - V3 / V0 Static：在 shstrtab 之前插入
  - `layoutV3` 签名加了 `pr *const ParseResult` 参数

- [x] **D.2.3**：测试 fixture ✅ 2026-04-18
  - 因为 `-O Debug` / `-O ReleaseSafe` 在 zignocchio SDK 下会超
    BPF 栈 budget，改用独立 C 源 fixture
  - `src/testdata/mini-debug.{c,o,shim.so}` ——
    clang+BPF+-g 产出，包含 `.debug_loc / .debug_abbrev /
    .debug_info / .debug_str / .debug_line`
  - `integration_test.zig` goldens 从 9 增到 10，`mini-debug` 一条
    byte-diff 专门验证 debug 保留路径

- [x] **D.2.4**：运行时烟测 ✅ 2026-04-18（跳过，per ADR-001）
  - 字节对等已传递覆盖运行时；mini-debug.shim.so 跟 elf2sbpf 产物
    byte-identical，即跟"reference-shim 能跑的一切"等价

- [x] **D.2.5**：v0.2.0 release ✅ 2026-04-18
  - `build.zig.zon` 0.1.0 → 0.2.0；CHANGELOG `[0.2.0]` 条目
  - Annotated tag `v0.2.0` + cross-compiled 3 artifact
    （macOS arm64 / Linux x86_64 / Linux arm64）+ SHA256SUMS
  - Download-verify：10/10 goldens MATCH release binary
  - **Release**：https://github.com/DaviRain-Su/elf2sbpf/releases/tag/v0.2.0

### 验收

- ✅ 带 debug 的 mini-debug.o 跑管道后字节一致
- ✅ 10/10 原 golden（9 zignocchio + 1 mini-debug） MATCH
- ✅ 362/362 tests 全绿；`DebugSection.size()` 语义更新为 padded

---

## D.4 — Zig 库 API（draft）

**动机**：zignocchio 上游 PR 一合，Zig 框架作者会来用 elf2sbpf。
目前 CLI 的形式需要子进程调用（`b.addSystemCommand(...)`），这是
我在 zignocchio build.zig 草稿里的做法。更优雅的是：让
`build.zig.zon` 能直接 `zig fetch https://...elf2sbpf...`，然后
在 build.zig 里 import 成 module 调用。

**预估**：1 天

### 子任务

- [x] **D.4.1**：module 已在 build.zig 里通过 `b.addModule("elf2sbpf",
  ...)` 公开 ✅ 2026-04-18（infrastructure 早就就位）
  - `lib.zig` 里 `linkProgram / Program / LinkError / AST /
    ParseResult / SbpfArch / Instruction / byteparser` 等都 re-export
  - 实测：创建 `/tmp/elf2sbpf-import-test/` synthetic consumer →
    `zig fetch --save <path>` → `@import("elf2sbpf")` → 调用
    `linkProgram` → 对 hello.o 产出**跟 shim golden 字节一致**

- [x] **D.4.2**：`docs/library.md` ✅ 2026-04-18
  - `zig fetch --save` 指引；`build.zig` 接入代码；consumer `main.zig`
    示例；public API 稳定性表（✅ stable vs ⚠️ churn-eligible）；CLI
    vs library 对比

- [x] **D.4.3**：zignocchio `zig-import` 演示 ✅ 2026-04-18
  - `docs/integrations/zignocchio-build.zig` 原本加了 3 分支 dispatch；
    用户简化成 elf2sbpf-only 单路径（更干净的 PR 形态）
  - `zig-import` 的消费模式示例留在 `docs/library.md` + 本仓库的
    `tmp/elf2sbpf-import-test/` harness 里，非必须进 zignocchio PR

- [x] **D.4.4**：集成测试 ✅ 2026-04-18
  - 简化版 draft 对 9 个 example 实测 9/9 MATCH

### 验收

- ✅ 下游 Zig 项目能 `zig fetch --save` + `@import("elf2sbpf")` + 调用
  `linkProgram` 产出 byte-identical to CLI path
- ✅ 简化版 zignocchio build.zig 9/9 example MATCH

---

## D.1 — SbpfArch V3 ✅ 2026-04-18（v0.5.0）

**动机**：Solana runtime 正在推 V3 作为新默认（static relocation、
更快 loader、fixed vaddr）。C1 只做了 V0；V3 是扩展方向。

**实际耗时**：原估 1-2 周；**最终约 2 小时**（出乎意料地轻量，
因为 C1 期间已经把 V3 分支做成"占位 if-else"而不是 stub）。

### 做了什么

1. **reference-shim**：加 `--v3` flag（默认 V0）→ 生成 V3 对拍 golden
2. **linkProgramV3**：新公开 API，走 arch=.V3 的管道；CLI 加 `--v3`
3. **修 3 处 V3-specific bug**：
   - `layoutV3` 的 PH[0] 用 PADDED rodata size（off-by-1）
   - `fromParseResult` text_offset 也 PADDED rodata size
   - shstrtab name_offset 在 V3 分支用 `cumulativeNameLen`
     （**不加 +1**）—— V3 shstrtab 的 sh_name 指向空串而不是 ".s"
   - V3 with rodata 的 section_names 顺序为 [".text", ".rodata"]
     （即使 section 表里 rodata 在 code 之前）
4. **Phase C syscall hash bit-cast**（u32 → i32）—— 修
   ImmOutOfRange：hash 高位 set 时 `@intCast` 到 i64 会产出
   > i32.max 的值，encoder 拒绝。改成 `@bitCast` 通过 i32 保证
   round-trip

### 9/9 V3 sweep

| Example | V3 size | V0 size |
|---------|---------|---------|
| hello | 544 B | 1192 B |
| noop | 360 B | 304 B |
| logonly | 536 B | 1184 B |
| counter | 2272 B | 3344 B |
| vault | 10464 B | 12256 B |
| transfer-sol | 3448 B | 4384 B |
| pda-storage | 7544 B | 8728 B |
| escrow | 16824 B | 18616 B |
| token-vault | 18608 B | 20496 B |

V3 产物普遍比 V0 小 —— 少了 dynamic/dynsym/dynstr/rel.dyn 四个 section。

### 新增集成测试

`integration: 9 zignocchio examples byte-match reference-shim under V3`
—— V3 sweep loop，跟 V0 sweep 并列跑。V3 shim golden 入库作为
`src/testdata/<example>.v3.shim.so`（9 个新文件）。

---

## 其他 D 任务

- **D.3 Dynamic syscall relocation** ✅ 2026-04-18（v0.4.0）：
  - 新增 `linkProgramWithSyscalls(allocator, elf_bytes, extras)`，
    允许注入自定义 syscall 名字
  - 底层机制：`thread_extra_syscalls` threadlocal var；`nameForHash`
    先查内置 30 条再查 extras；save/restore 语义保证不跨调用泄漏
  - `linkProgram(a, b) ≡ linkProgramWithSyscalls(a, b, &.{})`，
    不破坏现有 API；built-in-only 程序产出字节不变
  - 文档：`docs/library.md` 加 "Custom syscalls (since v0.4.0)" 节
  - 测试：3 个 `nameForHash` 单测 + 1 个 integration test
    （extras 不动时 byte-identical to `linkProgram`；save/restore
    在连续调用间稳定）
- **D.5 Windows**：未验证；Zig 理论上跨平台。主要是 path
  separator + file I/O 的 regression
- **D.6 跨语言前端**：战略愿景，不排期

---

## 进度汇总

| 任务 | 状态 |
|------|------|
| D.1 V3 arch | ✅ 完成，v0.5.0 已发 |
| D.2 Debug info | ✅ 完成，v0.2.0 已发 |
| D.3 Dynamic syscall | ✅ 完成，v0.4.0 已发 |
| D.4 Zig 库 API | ✅ 完成，v0.3.0 已发 |
| D.5 Windows | 未开始（等用户报需求） |
| D.6 跨语言 | 战略愿景，不排期 |

---

## 当前最有价值的一步

在我看来 **D.2 Debug info 保留** 是 P0：
- 投入最小（1-2 天），代码基础已经就位
- 对 gdb/lldb 用户立即有价值
- 不破坏任何已有 golden
- 推完 D.2 刚好有一个 v0.2.0 的小 release，延续 C1/C2 的节奏

如果用户倾向 D.4（DX / 上游集成深化）、D.1（V3 提前布局）或
D.3（syscall 扩展），告诉我即可切换。
