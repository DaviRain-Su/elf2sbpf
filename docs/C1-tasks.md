# C1 任务清单（Phase 4 — Task Breakdown）

**目标**：把 sbpf-linker 的 stage 2 完整 port 成 Zig，9/9 zignocchio
example 跟 `reference-shim` 字节一致。

**当前状态**：这个核心目标已在 2026-04-18 达成（`validate-zig.sh`
9/9 全绿）。本清单剩余未勾选项主要是 CI、golden fixture、文档和
后续集成收尾。

**预估**：6-8 周单人全职，约 40-55 工作日。

**在 dev-lifecycle 中的位置**：

- ⬅️ 前置输入：`02-architecture.md`（Phase 2）、`03-technical-spec.md`（Phase 3）、`05-test-spec.md`（Phase 5）
- ➡️ 下一阶段：`06-implementation-log.md`（Phase 6）

**规则**：
- **不可跳过 TDD**：每个任务**先写测试骨架**（参照 `05-test-spec.md`
  对应章节），再写实现
- **规格先行**：实现之前先对照 `03-technical-spec.md` 对应章节，
  遇到规格不清晰的地方**改规格再改代码**
- **验收**：每个任务必须有可验证的产出（对拍脚本跑绿 / 单测过）
- **Oracle**：`reference-shim` 是真理。Zig 输出要和 shim 输出
  `cmp` 相等
- **粒度**：每个任务 0.5-2 天；过大就拆
- **每个任务完成后**：勾掉 `[ ]` → `[x]`，同步改这份文档

---

## Critical Path 一览

```
C1-A (骨架)
   └→ C1-B (通用数据类型) ─┐
   └→ C1-C (ELF 读取)  ────┤
                            ├→ C1-D (byteparser) ─┐
                            │                       ├→ C1-G (Program emit) ─→ C1-H (CLI) ─→ C1-I (对拍)
                            └→ C1-E (AST) ─────────┤
                            └→ C1-F (ELF 输出) ────┘
```

关键路径：**A → B → D → E → G → H → I**，大约 5-6 周。
F 可以跟 D/E 并行做（独立模块，都是查表类机械活）。

---

## Epic ↔ Phase 3/5 交叉引用（必读）

**每个 Epic 对应的规格章节和测试**。做任何任务**之前**必须先读
这两处，然后**按 TDD 顺序**：先写测试骨架 → 写实现 → 测试转绿。

| Epic | 规格来源（Phase 3） | 测试矩阵（Phase 5） | 验收 Oracle |
|------|-------------------|-------------------|------------|
| A — 骨架 | `02-architecture.md §3` | `05-test-spec.md §2` (命令) | `zig build` + `zig build test` 空跑通 |
| B — 通用类型 | `03-technical-spec.md §2.1`, `§6.1`, `§7` | `05-test-spec.md §4.1–4.5` | 单测 + hello.o 指令 round-trip |
| C — ELF 读取 | `03-technical-spec.md §2.2` | `05-test-spec.md §4.6` | 对 hello.o iter 出正确 section/symbol/reloc |
| D — Byteparser | `03-technical-spec.md §6.2`（改进 gap-fill）、`§8`（18 个边界） | `05-test-spec.md §4.7`（L2 对拍 + 18 个 L1 边界） | ParseResult JSON 跟 shim 一致 |
| E — AST | `03-technical-spec.md §6.3` | `05-test-spec.md §4.8` | buildProgram 产物对 hello JSON 一致 |
| F — ELF 输出 | `03-technical-spec.md §2.4`, `§7`（常量）、`§6.4` | `05-test-spec.md §4.9` | 每个 SectionType.bytecode() 字节对 shim 一致 |
| G — Program emit | `03-technical-spec.md §6.4` | `05-test-spec.md §4.9`（最后的完整 emit） | **hello.o 字节级 MATCH** |
| H — CLI | `03-technical-spec.md §1.1` | `05-test-spec.md §2.3` | `elf2sbpf hello.o hello.so` 跑通 |
| I — 对拍 | — | `05-test-spec.md §4.10`（integration） | **9/9 example 全绿** |

**Spec 优先原则**（不可违反）：

- 开工前读 Phase 3 对应章节，读 Phase 5 对应测试
- 发现规格不清晰 / 有漏洞：**先改 Phase 3，再动代码**
- 发现测试需要调整：先改 Phase 5，再改测试骨架
- 不要在代码里"将错就错"——这是 Phase 3 存在的唯一意义

---

## Epic C1-A：Zig 项目骨架

**目标**：能 `zig build` 产出一个空壳 `elf2sbpf` 二进制，能 `zig
test` 跑空测试。

**预估**：1 天

### 任务

- [x] **A.1**：初始化 `build.zig` 和 `build.zig.zon` ✅ 2026-04-18
  - `build.zig` 产出名为 `elf2sbpf` 的 exe
  - 有 `zig build test` target（3 个 step：default、run、test）
  - 锁定 Zig 0.16.0（`.minimum_zig_version = "0.16.0"`）
  - **验收**：`zig build` 成功，`./zig-out/bin/elf2sbpf` 1.8MB，`otool -L` 确认不链 libLLVM
  - **实现日志**：`docs/06-implementation-log.md` § C1-A.1

- [x] **A.2**：建 `src/` 目录骨架 ✅ 2026-04-18（部分）
  - `src/main.zig`：CLI 占位 + 1 个 smoke test
  - `src/lib.zig`：`LinkError` + `linkProgram` 占位 + 2 个 smoke test
  - 子模块目录（`common/` `elf/` `parse/` `ast/` `emit/`）**延后到对应 Epic 开工时建**，避免空目录
  - **验收**：顶层结构匹配 architecture §3

- [x] **A.3**：建测试 harness ✅ 2026-04-18
  - `zig build test` 跑通 3/3 测试（2 个在 lib module，1 个在 exe module）
  - `scripts/validate-zig.sh` 已补上为 `validate-all.sh` 的兼容入口；
    真正的 9/9 绿灯仍要等 Epic I 完成
  - **验收**：`zig build test --summary all` 全绿

---

## Epic C1-B：通用数据类型（移植 sbpf-common）

**目标**：Port `sbpf-common` 的必要类型。这是最机械的部分，按文件
翻译。

**预估**：8-10 天

**依赖**：C1-A 完成

### 任务

- [x] **B.1**：`common/number.zig` ✅ 2026-04-18
  - 对应 Rust `inst_param::Number`：`Int(i64)` | `Addr(i64)`（**无 Hex** —— 原 spec 错）
  - Zig tagged union，有 `toI64()` 和 `toI16()`
  - **验收**：7 个单测全绿（构造、toI64、toI16 截断、变体区分）
  - **规格修订**：Phase 3 §2.1 删掉 Hex 变体；Phase 5 §4.1 更新测试矩阵
  - **实现日志**：`06-implementation-log.md` § C1-B.1

- [x] **B.2**：`common/register.zig` ✅ 2026-04-18
  - 对应 `inst_param::Register`：`struct { n: u8 }`（**不是 u4** —— 原 spec 错）
  - Zig 0.16 `std.Io.Writer`-based format，输出 `r{n}`
  - **验收**：4 个单测全绿（构造、格式化 `r3` / `r10`）
  - **规格修订**：Phase 3 §2.1 改 u4→u8；Phase 5 §4.2 更新测试
  - **实现日志**：`06-implementation-log.md` § C1-B.2

- [x] **B.3**：`common/opcode.zig` — Opcode enum + toStr ✅ 2026-04-18
  - Port Rust `opcode.rs` 的 Opcode enum（实际 **116 variant**，不是原估的 500；我估得太保守）
  - Zig `enum(u8)`，每个变体显式字节值（对照 Rust TryFrom<u8> L382-510）
  - `fromByte` 用 `inline for` 校验（Zig 0.16 没有 `std.meta.intToEnum`）
  - `toStr` 人读助记符
  - **验收**：5 个单测全绿，inline for 覆盖全部 116 variant 的 round-trip
  - **实现日志**：`06-implementation-log.md` § C1-B.3

- [ ] ~~**B.4**：辅助函数~~（**推迟到 D 阶段**）
  - 原计划：`fromSize` / `toSize` / `toOperator` / `is32bit`
  - 分析：这些只给 assembler text parser 用（解析 `add 64 r1, r2` 语法）；
    byteparser 只需 `fromByte` / `toByte` / 变体比较，C1 MVP 不需要
  - 决定：推迟到 D 阶段，按需实现

- [x] **B.5**：`common/instruction.zig` — Instruction 结构 + 分类助手 ✅ 2026-04-18
  - `Instruction { opcode, dst, src, off, imm, span }`
  - `Span { start, end }`
  - `Either(L, R)` comptime 函数
  - `getSize()`、`isJump()`、`isSyscall()` 实现（fromBytes/toBytes 占位 panic，留给 B.6/B.7）
  - **规格修订**：用 `[]const u8` 代替 `LabelRef` newtype（跟 Rust 保持一致，省一层抽象）
  - **验收**：10 个单测全绿（Span、Either、Lddw=16/其他=8、23 个 jump/3 个 call-class、Syscall 3 种 case）

- [x] **B.6**：`common/instruction.zig` — `fromBytes` ✅ 2026-04-18
  - 按 opcode 的 `operationType()` 分类，13 种 class 各自解析字段布局
  - Lddw 16 字节特殊：第二个 8 字节槽的 bytes 12-15 是 imm_high
  - Callx (SBPF 扩展)：dst 编码在 imm 里的归一化处理
  - `DecodeError` 错误集合：TooShort / UnknownOpcode / FieldMustBeZero / InvalidSrcRegister
  - **关键辅助**：`OperationType` enum + `Opcode.operationType()` 加到
    `common/opcode.zig`（116 个 opcode 的分类表）
  - **验收**：14 个新测试，**用真实 hello.o / counter.o 字节**验证所有
    13 种 operation 类型；错误路径 4 种全部验证；spec §8 边界 #12（未知 opcode） + #16（JMP32 0x16 拒绝） 明确验证

- [x] **B.7**：`common/instruction.zig` — `toBytes` ✅ 2026-04-18
  - fromBytes 反操作，按同样 13 class 分派
  - `EncodeError`：`BufferTooSmall` / `UnresolvedLabel` / `ImmOutOfRange`
  - `.left(label)` 未解析就 encode = 程序错 → `UnresolvedLabel`
  - 共享 `writeLeU32` / `writeLeI32` / `writeLeI16` helpers
  - **验收**：6 个错误测试 + **16 种 class 的 round-trip 测试**
    （decode → encode → 原字节完全一致），覆盖每种 operation class

- [x] **B.8**：`common/instruction.zig` — 辅助判断 ✅ 已在 B.5 中完成
  - `isJump`、`isSyscall`、`getSize` 全部在 B.5 写好并测过

- [x] **B.9**：`common/syscalls.zig` — murmur3-32 ✅ 2026-04-18
  - Port Rust `sbpf-syscall-map::hash::murmur3_32`（~45 行算法）
  - 常量表 9 个，都跟 spec §7.7 对齐
  - Tail padding 是高位补零（**不是**按字节反序拼），修了 spec §6.1 的伪代码错
  - **字节级跟 Rust 一致**：对 `sol_log_` / `sol_log_64_` / `sol_log_pubkey` /
    `sol_memcpy_` / `sol_invoke_signed_c` 5 个 Solana syscall 都跑出正确 hash
  - **规格修订**：Phase 3 §6.1（tail padding）+ Phase 5 §4.5（sol_log_64_
    的期望值原来写错了，实测应是 0x5c2a3178 而不是 0xbf7188f6）
  - **验收**：9 个单测全绿，含空串、5 个 syscall、tail 长度覆盖 0-3 + 4 + 5 + 8

- [ ] **B.10**：B.1-B.9 全部集成单测
  - 用 sbpf-common 的 Rust 单测作为对照表（抄过来改成 Zig）
  - **验收**：`zig build test --filter common` 全绿

---

## Epic C1-C：ELF 读取层

**目标**：基于 `std.elf` 实现 section / symbol / relocation 迭代。

**预估**：3-4 天

**依赖**：C1-A 完成

### 任务

- [x] **C.1**：`elf/reader.zig` — `ElfFile.parse(bytes: []const u8)` ✅ 2026-04-18
  - 手工验证 ELF header（magic、class、endian、machine）而不走 `std.elf.Header.read`
    因为后者是基于 reader 的 API，我们要对内存中的字节做零拷贝
  - `@ptrCast` + `@alignCast` 把 `bytes` 重新解释成 `*const Elf64_Ehdr`（零拷贝）
  - 同时切出 section header table（typed slice）+ 定位 `.shstrtab`
  - `ParseError` 7 个变体（TooShort/NotElf/Not64Bit/NotLittleEndian/NotBpf/CorruptSectionTable/BadShStrIndex）
  - **验收**：6 个测试全绿，**spec §8 边界 #1-5 全覆盖** + 合法最小 header 正例

- [x] **C.2**：`elf/section.zig` — section 迭代 ✅ 2026-04-18
  - `SectionIter` + `Section` struct（index / header / name / data + flags/size/kind 访问器）
  - `iterSections()` / `sectionByIndex()` 挂在 ElfFile 上
  - `cstrAt` helper 安全读 C 字符串（null-terminated 或 buffer 边界）
  - **关键重构**：`header: *const Elf64_Ehdr` → `header: Elf64_Ehdr`（by-value）
    避免输入字节对齐要求；各 section 的 header 也 by-value，`sectionHeaderAt` 做 memcpy。
    从"zero-copy + 要求对齐"改成"轻度 memcpy + 任意对齐"，更健壮
  - **验收**：8 个单测全绿，含 cstrAt 3 种路径 + 3-section 合成 ELF 的迭代/命名/数据/flags/NULL 断言

- [x] **C.3**：`elf/symbol.zig` — symbol 迭代 ✅ 2026-04-18
  - `Symbol` struct（by-value raw + name 切片）+ `SymbolIter`
  - `SymbolKind` enum（NoType/Object/Func/Section/File/Common/Tls/Unknown）
  - `SymbolBinding` enum（Local/Global/Weak/Unknown）
  - `sectionIndex()`：SHN_UNDEF/SHN_ABS → null，其他返回 u16
  - `ElfFile.iterSymbols(kind)` 接受 `.symtab` 或 `.dynsym` 两种表
  - `SymbolError`：NoSymbolTable / BadStringTable / CorruptSymbolTable / NameOutOfRange
  - **验收**：3 个单测，4-section 合成 ELF 带 3 个 symbol（STN_UNDEF/entrypoint-FUNC-GLOBAL/foo-OBJECT-LOCAL），完整验证迭代、kind/binding/sectionIndex 解析、strtab 名字解析

- [x] **C.4**：`elf/reloc.zig` — relocation 迭代 ✅ 2026-04-18
  - `Reloc { index, offset, type_raw, symbol_index, addend }`
  - `RelocType` non-exhaustive enum：BPF_64_64 / BPF_64_ABS64 / BPF_64_ABS32 /
    BPF_64_NODYLD32 / BPF_64_32 / `_`（未知值保持原 u32）
  - 同时支持 SHT_REL（addend=null，隐藏在指令 imm 里）和 SHT_RELA（addend 显式）
  - `ElfFile.iterRelocations(rel_section)` — 用 Section 定位，不是名字
  - `RelocError`：NotARelocationSection / CorruptRelocationTable / OutOfRange
  - **验收**：3 个单测，4-section 合成 ELF 带 .rel.text（2 个 entry：BPF_64_64 和 BPF_64_32）+ 非 reloc section 拒绝 + 非穷尽 enum 行为

- [x] **C.5**：集成测试 ✅ 2026-04-18
  - `src/testdata/hello.o` 真实 fixture（1016 字节）
  - `src/integration_test.zig` 用 `@embedFile` 加载，避开 Zig 0.16 `std.Io.Dir` API 迁移
  - `.gitignore` 加例外：`!src/testdata/*.o`
  - **5 个真数据 smoke test**：parse、section 迭代（.text/.rodata/.rel.text）、symtab（entrypoint GLOBAL FUNC）、.rel.text 的 BPF_64_64 relocation、**完整 .text decode**（7 条指令含 1 lddw 共 64 字节）
  - **验收**：84/84 测试，端到端验证 Instruction decoder + ELF 三迭代器协作正确
  - **规格修订**：原 plan 说 "8 instructions, 72 bytes"——实际 hello.o `.text` 是 **7 条 64 字节**（6×8 + 1×16）；llvm-objdump 标签跳号是因为 lddw 占两个 slot

---

## Epic C1-D：Byteparser 逻辑

**目标**：实现 `byteparser.zig`——核心的 ELF → ParseResult 转换，
**包含改进版 rodata gap-fill 算法**。

**预估**：5-7 天

**依赖**：C1-B（Instruction）+ C1-C（ELF 读取）

### 任务

- [x] **D.1**：识别 `ro_sections` 和 `text_section_bases` ✅ 2026-04-18
  - `scanSections(allocator, file) → SectionScan`
  - `SectionScan { ro_sections, text_bases, total_text_size }` + lookup 方法
  - `isRoSectionName` / `isTextSectionName` helpers
  - 对 hello.o 正确识别 1 个 .text（64B）+ 1 个 .rodata
  - **模块重构**：`cstrAt` 移到 `src/common/util.zig` 作为共享 helper（user/linter 加的）
  - **API 变更**：`ElfFile.sectionHeaderAt` 从 assert 改成 error-return（`IndexOutOfRange`）——更健壮，但要求 section.zig / symbol.zig 用 `catch` 处理
  - **Zig 0.16 ArrayList**：`.empty` + 每次 `.append(allocator, ...)` 传 allocator
  - **验收**：4 个单测全绿（2 个 name predicate + hello.o 分类 + index lookup）

- [x] **D.2**：扫符号，收集 `pending_rodata` + text labels + entry_label ✅ 2026-04-18
  - `scanSymbols(allocator, file, sections) → SymbolScan`
  - `RodataEntry { section_index, address, size, name, name_owned, bytes }`
    （D.4 的合成 entry 会设 name_owned=true，确保释放）
  - `TextLabel { name, offset }`——offset 已经加上 text_base
  - `entry_label: ?[]const u8`——"entrypoint" 符号存在就设置
  - 无 symtab 正常返回空 scan（stripped ELF 合法）
  - **新错误**：`EmptyNamedRodataSymbol`、`SymbolOutOfSectionRange`
  - **验收**：2 个单测——hello.o 返回 1 个 entrypoint label + 空 pending_rodata；无 symtab ELF 返回全空

- [x] **D.3**：扫 text relocation，收集 `lddw_targets`（改进算法）✅ 2026-04-18
  - `LddwTargets` 结构：section_index → 排序去重 addend 列表
    - `insert(section, addend)` 用二分查找维护 sorted-unique
    - `get(section)` O(n) 扫描返回排序切片
  - `collectLddwTargets(allocator, file, sections)` 主入口
    - 遍历 SHT_REL/SHT_RELA section 头的 `sh_info` 找到 text 目标
    - 对每个 reloc：查符号 → 确认在 ro_section → 确认 text[offset]==0x18 → 提取 LE u32 addend
  - **关键**：这是 byteparser.rs 没做的改进点，spec §6.2 Pass 1 的 port
  - **验收**：2 测试——insert 排序去重；hello.o 真数据：1 个 lddw addend = 0
  - **TODO**：counter.o 产 14 addend 的全量验证等 D.5 拼完 rodata_table 后再一起做

- [x] **D.4**：Gap-fill 算法（改进版）✅ 2026-04-18
  - `gapFillRodata(allocator, sections, targets, syms)` 写入 `syms.pending_rodata`
  - 按 spec §6.2 Pass 2+3 实现：anchor 集合 = `{0, size} ∪ 命名端点 ∪ lddw_targets`
  - Sanity check：lddw target 落在命名 entry 内部 → `error.LddwTargetInsideNamedEntry`
  - 合成的 anon entries name 格式：`.rodata.__anon_<hex>_<hex>`，`name_owned=true`
  - 最后按 `(section_idx, address)` 全排序
  - **验收**：3 测试——hello.o 产 1 anon entry（23B "Hello from Zignocchio!"）；3 lddw 目标切 30B section 成 3 段；lddw 落命名 entry 内部返回错

- [x] **D.5**：构建 `rodata_table` + 分配连续 rodata_offset ✅ 2026-04-18
  - `RodataKey { section_index, address }` + `RodataTable` 结构
  - 3 个并行 ArrayList（keys / offsets / names），按 (section_idx, address) 二分搜索
  - `buildRodataTable(syms)` 主入口：遍历 sorted pending_rodata，累加 offset
  - `total_size` = 最终 rodata 合并镜像总字节数
  - `find(key)`、`nameAt`、`offsetAt` 查询 API
  - **验收**：2 测试——hello.o 1 entry @ offset 0 total 23B；3-split 合成数据 offset 0/8/16 total 30B

- [x] **D.6**：Text 指令解析 ✅ 2026-04-18
  - `DecodedInstruction { offset, instruction, source_section }` — 带绝对 offset + 来源 section 索引
  - `TextScan { instructions }` 持有者结构
  - `decodeTextSections(allocator, sections)` 主入口
    - 遍历每个 text section，调 `Instruction.fromBytes`
    - 按 `inst.getSize()` 步进（lddw 16B，其他 8B）
    - 记录 `base_offset + inner_offset` 作为绝对 offset
  - `DecodeTextError`：InstructionDecodeFailed / TextSectionMisaligned / OutOfMemory
  - **验收**：2 测试——hello.o 7 条指令 offsets 0/8/16/32/40/48/56 全对（lddw @ 16 占用 2 slots）；空 text 空结果

- [x] **D.7**：Relocation 重写 ✅ 2026-04-18
  - `rewriteRelocations(file, sections, rodata_table, text_scan, owned_names)`
  - 3 种 case 全实现：
    - lddw + rodata target → `imm = .left(rodata_name)`，查不到返回 `LddwTargetOutsideRodata`
    - call + STT_SECTION → 按当前 imm 反查具名符号；查不到保持数字 imm
    - call + 非 STT_SECTION → `imm = .left(sym.name)`，空名 → `CallTargetUnresolvable`
  - `RewriteError`：LddwTargetOutsideRodata / CallTargetUnresolvable / OOM
  - `findInstructionAtOffset` helper：按绝对 offset 定位 DecodedInstruction
  - **验收**：hello.o 端到端 D.1→D.7 pipeline 跑通，lddw @ offset 16 被重写为 `.left(".rodata.__anon_...")`

- [x] **D.8**：debug section 暂存 ✅ 2026-04-18
  - `DebugSectionEntry { name, data }` + `DebugScan { entries }`
  - `scanDebugSections(allocator, file)`：过滤 `.debug_*` section
  - 零拷贝保留原字节（切片 into ELF bytes）
  - **验收**：hello.o 无 debug section（ReleaseSmall），返回空列表

- [x] **D.9**：byteParse 整合入口 ✅ 2026-04-18
  - `ByteParseResult { sections, syms, rodata_table, text, debug, owned_names }` — 聚合所有子 pass 的产物
  - `byteParse(allocator, file)` 依次跑 D.1-D.8，返回填满的 ByteParseResult
  - 完整 errdefer 链保证所有失败路径上资源被释放
  - **验收**：hello.o 端到端 byteParse()，所有字段都正确（1 text 64B、1 rodata 23B、7 指令、lddw imm 已重写）

---

## Epic C1-E：AST 中间表示

**目标**：Port `astnode.rs` + `ast.rs`，包括 V0 版 build_program。

**预估**：5-7 天

**依赖**：C1-B（Instruction）

### 任务

- [x] **E.1**：`ast/node.zig` ✅ 2026-04-18
  - `ASTNode` tagged union 4 变体（Label / Instruction / ROData / GlobalDecl）
  - `Label { name, span }` / `ROData { name, bytes, span }` / `GlobalDecl { entry_label, span }`
  - `isTextNode()` / `isRodataNode()` / `offset()` 辅助
  - **决定**：ROData 用 `bytes: []const u8`（不是 `[]Number`）——byteparser
    产 byte array，不需要 tagged union 膨胀
  - **scope**：只 port 了 4 个 byteparser 会产的 variant，Rust 的
    Directive/EquDecl/ExternDecl/RodataDecl 是 text parser only，推迟到 D
  - **验收**：6 单测覆盖所有 variant 构造、分类、字段访问

- [x] **E.2**：`ast/ast.zig` — AST 结构 + 查询 API ✅ 2026-04-18
  - `AST { allocator, nodes, rodata_nodes, text_size, rodata_size }`
  - `init/deinit/setTextSize/setRodataSize/pushNode/pushRodataNode`
  - `getInstructionAtOffset(offset) ?*Instruction` — 返回**可变指针**让 E.3 就地改写
  - `getRodataAtOffset(offset) ?*ROData`
  - `SbpfArch` enum（V0 / V3；C1 只用 V0）
  - **验收**：5 单测覆盖所有 API、mutation through pointer

- [x] **E.3**：`ast/ast.zig` — `buildProgram(SbpfArch.V0)` ✅ 2026-04-18
  - 6 个 sub-pass 按 Rust ast.rs L109-275 port：
    - A: `label_offset_map` + numeric label tracking
    - B: prog_is_static 判定（V3 总是静态；V0 要无 syscall **且** 无符号 lddw）
    - C: syscall 注入（V0 动态：src=1/imm=-1 + .rel.dyn + .dynsym；V3 静态：src=0/imm=hash）
    - D: jump/call label → 相对 offset `(target - current)/8 - 1`
    - E: lddw label → 绝对地址（V0: `target + ph_offset`，ph_count=1 静态/3 动态；V3: `target - text_size`）
    - F: entry_point 从 GlobalDecl → 加到 dynamic_symbols
    - G: 移交 nodes 到 ParseResult
  - 支持类型：`ParseResult` / `CodeSection` / `DataSection` / `DynamicSymbolMap` / `RelDynMap` / `DebugSection` / `RelocationType` / `BuildProgramError`
  - **规格修订**：Phase B 原实现只检查 syscall，port 时加入 lddw 检查（跟 Rust 一致）
  - **验收**：覆盖 V0 静态 + 动态（带 lddw）两种路径，124/124 tests 全绿

- [x] **E.4**：集成测试 ✅ 2026-04-18（随 E.3 一并完成）
  - 124/124 tests 覆盖 AST 各 API + buildProgram 多种路径
  - **注**：byteparser → buildProgram 的端到端集成留给 Epic F 阶段，届时 Program.fromParseResult 会自然串起来

---

## Epic C1-F：ELF 输出层（移植 sbpf-assembler 的 section / header）

**目标**：Port `header.rs` + `section.rs` + `dynsym.rs` 的
Solana SBPF 特有结构。

**预估**：7-10 天

**依赖**：C1-B（Number 等基础类型）

### 任务

- [x] **F.1**：`emit/header.zig` — `ElfHeader` ✅ 2026-04-18
  - Solana 常量：`SOLANA_IDENT` / `ET_DYN=3` / `EM_BPF=247` / `EV_CURRENT=1`
  - Size 常量：`ELF64_HEADER_SIZE=64` / `PROGRAM_HEADER_SIZE=56` / `SECTION_HEADER_SIZE=64`
  - `init()` 默认值匹配 Solana spec
  - `bytecode(*[64]u8)` 写入固定 64 字节；避开 ArrayList allocator 开销
  - **验收**：3 单测（默认值、magic+字段正确、自定义字段 round-trip）

- [x] **F.2**：`emit/header.zig` — `ProgramHeader` ✅ 2026-04-18（同文件）
  - 56-byte struct + `newLoad(offset, size, executable, arch)` + `newDynamic`
  - V0 flags = PF_R|PF_X（code）/ PF_R（rodata），vaddr=offset，align=4096
  - V3 flags = PF_X / PF_R，vaddr=V3_BYTECODE_VADDR / V3_RODATA_VADDR，align=0
  - `bytecode(*[56]u8)`
  - **验收**：4 单测（V0 exec、V0 rodata、V3 exec、PT_DYNAMIC + bytecode 输出）

- [x] **F.3**：`emit/header.zig` — `SectionHeader`（通用 64 字节）✅ 2026-04-18（同文件）
  - `init(name_offset, type, flags, addr, offset, size, link, info, addralign, entsize)`
  - 完整 SHT_* / SHF_* 常量集（NULL/PROGBITS/STRTAB/DYNAMIC/REL/NOBITS/DYNSYM + WRITE/ALLOC/EXECINSTR）
  - **验收**：1 单测（.text section header round-trip）

- [x] **F.4**：`emit/section_types.zig` — `NullSection` / `ShStrTabSection` ✅ 2026-04-18
  - `NullSection` — 0 字节内容 + 全零 section header
  - `ShStrTabSection { name_offset, section_names, offset }`
    - `bytecode` 产 `\0name1\0name2\0...\0.s\0` 并 pad 到 8 字节边界
    - `size` 返回**不含 padding** 的字符串表大小（跟 Rust 一致）
    - 隐式 append `.s` 作为本 section 自己的名字
    - `sectionHeaderBytecode` 写 SHT_STRTAB + addralign=1
  - **验收**：4 单测——NullSection 零值；ShStrTab 单 name 布局；空 name 跳过；section header 字段检查

- **（linter 协作修正）**：
  - `Instruction.isSyscall` 定义被 linter 扩展——原来"只有 `.left` imm 算 syscall"，现在 "src=0 或 `.left` imm"，涵盖 V3 resolved syscall case
  - `main.zig` 补了 3 个 parseArgv 单测 + linkErrorExitCode 映射
  - 同步更新 integration test 的期望

- [x] **F.5**：`emit/section_types.zig` — `CodeSection` ✅ 2026-04-18
  - `CodeSection { nodes, size, offset }` 持有 ASTNode 切片
  - `bytecode` 遍历节点，只对 `.Instruction` 调 `toBytes`（skip Label/GlobalDecl）
  - lddw 16B / 其他 8B 步进
  - `sectionHeaderBytecode(name_offset, *[64]u8)` —— SHT_PROGBITS + ALLOC|EXECINSTR，align 4
  - **验收**：3 单测（单 exit 指令、Label+GlobalDecl 跳过、section header 字段）

- [x] **F.6**：`emit/section_types.zig` — `DataSection` ✅ 2026-04-18
  - `DataSection { nodes, size, offset }` 持有 ASTNode 切片
  - `bytecode` 拼接所有 `.ROData` 的 bytes + 8 字节对齐 padding
  - `alignedSize()` helper 返回 padding 后大小
  - `sectionHeaderBytecode(name_offset, *[64]u8)` —— SHT_PROGBITS + ALLOC，align 1，**sh_size 用 unpadded** 逻辑大小（跟 Rust 一致）
  - **验收**：3 单测（"Hello" 5B 补成 8B、多 rodata 拼接、section header 字段）

- [x] **F.7**：`emit/section_types.zig` — `DynSymSection` ✅ 2026-04-18
  - `DynSymEntry` 24 字节布局（name/info/other/shndx/value/size）
  - `DynSymSection` 借用切片 + bytecode/sectionHeaderBytecode，
    SHT_DYNSYM + ALLOC，`sh_info=1`（第一个非-local 索引）
  - **验收**：2 单测（entry 24B 布局、3 entries 拼成 72B 且 header 正确）

- [x] **F.8**：`emit/section_types.zig` — `DynStrSection` ✅ 2026-04-18
  - 首字节 `\0`，名称按顺序拼接并补 8 字节对齐
  - SHT_STRTAB，`sh_addralign=1`
  - **验收**：1 单测（"entrypoint"+"_"=21B 补成 24B 且 leading null 保留）

- [x] **F.9**：`emit/section_types.zig` — `DynamicSection` ✅ 2026-04-18
  - DT 常量：`NULL/STRTAB/SYMTAB/STRSZ/SYMENT/REL/RELSZ/RELENT/TEXTREL/FLAGS/RELCOUNT`
  - 固定 10 个 tag（160B），rel_count>0 时追加 DT_RELCOUNT（176B）
  - SHT_DYNAMIC + ALLOC|WRITE，`sh_addralign=8`
  - **验收**：3 单测（基础 160B、带 RELCOUNT 176B、header flags）

- [x] **F.10**：`emit/section_types.zig` — `RelDynSection` ✅ 2026-04-18
  - `RelDynEntry` r_info 打包：`(dynstr_offset << 32) | rel_type`
  - 常量：`R_SBF_64_RELATIVE=0x08`、`R_SBF_SYSCALL=0x0a`
  - `RelDynSection` 借用切片 + bytecode/sectionHeaderBytecode，
    SHT_REL + ALLOC，`sh_link` 指向 dynsym、`sh_entsize=16`
  - **验收**：1 单测（r_info 位打包正确）

- [x] **F.11**：`emit/section_types.zig` — `DebugSection` ✅ 2026-04-18
  - 持有 `section_name/name_offset/data/offset`，bytecode 返回原字节
    copy（不补齐、不改位）
  - SHT_PROGBITS + flags=0（不可加载）、`sh_addr=0`、`sh_addralign=1`
  - **验收**：3 单测（非空 payload 透传、空 payload、header 字段）

- [x] **F.12**：`emit/section_types.zig` — SectionType 分派 ✅ 2026-04-18
  - `SectionType = union(enum) { null_, shstrtab, code, data, dynsym,
    dynstr, dynamic, reldyn, debug }`
  - 统一接口：`name()` / `size()` / `setOffset()` / `setNameOffset()` /
    `bytecode()` / `sectionHeaderBytecode()`
  - 顺带重构：CodeSection/DataSection 把 `name_offset` 从方法参数
    搬到结构体字段，对齐其他 7 种 section；测试同步更新
  - **验收**：5 新单测（name/size 分派、setOffset/Name 传参、bytecode
    一致、sectionHeaderBytecode 透传 name_offset）

---

## Epic C1-G：Program::from_parse_result + emit_bytecode

**目标**：Port `program.rs` 的 `from_parse_result` + `emit_bytecode`。
这是最终产出 `.so` 字节的核心。

**预估**：5-7 天

**依赖**：C1-E（AST）+ C1-F（ELF 输出）

### 任务

- [x] **G.1**：`emit/program.zig` — `Program` 结构 ✅ 2026-04-18
  - `Program { elf_header, program_headers: ArrayList(ProgramHeader),
    sections: ArrayList(SectionType), section_names: ArrayList([]const u8) }`
  - `init() / deinit() / appendSection / appendProgramHeader /
    sectionCount / programHeaderCount / hasRodata / reserveSectionNames`
  - lib.zig 补齐对 emit 层 7 个 section 类型 + `Program` 的
    re-exports
  - **验收**：4 新单测（空 Program、append section/header、hasRodata 检测）

- [x] **G.2**：`emit/program.zig` — `fromParseResult(pr, arch)` ✅ 2026-04-18
  - 三分支调度：V3 / V0 dynamic / V0 static（port Rust program.rs 一比一）
  - offset 分配在构建过程中完成：base_offset → code → data(?) → pad8
    → (V0 dynamic: dynamic/dynsym/dynstr/reldyn) → shstrtab
  - V0 dynamic 的 dyn_syms / rel_dyns / symbol_names 由 Program 本身
    的 `dyn_syms_storage` / `rel_dyns_storage` / `symbol_names_storage`
    三个 ArrayList 持有，section variants 借用切片
  - back-fill：dynamic.rel_offset/rel_size/dynsym_offset/dynstr_offset/
    dynstr_size，dynsym/reldyn 的 sh_link
  - program_headers：V3 1-2 个 PT_LOAD；V0 dynamic 3 个
    (PT_LOAD text, PT_LOAD dyn-data, PT_DYNAMIC)；V0 static 0 个
  - **验收**：3 新单测（V0 static minimal、V3 no-rodata、V0 dynamic
    with syscall 全链路）

- [x] **G.3**：`emit/program.zig` — `emitBytecode() []u8` ✅ 2026-04-18
  - 顺序：ELF header → program headers → section bytecode → pad8 →
    section header table
  - 同步修正 `SectionType.size()` 返回 emit-accurate 字节数（
    ShStrTab/Data 用 padded 尺寸，其它原值），避免 offset 漂移
  - 新增 `DataSection.alignedSize()` / `ShStrTabSection.paddedSize()`
  - PT_LOAD text 段长度 = bytecode + padded rodata（跟 Rust 一致）
  - **验收**：3 新单测（V0 static / V0 dynamic / V3 各自 ELF magic +
    e_shoff 精确落在 shnum×64 之前）

- [x] **G.4**：端到端集成测试 ✅ 2026-04-18 🎉
  - 新增 `AST.fromByteParse` —— byteparser → AST 的 glue
  - 新增 `REGISTERED_SYSCALLS` + `nameForHash` —— syscall hash 反查
  - `Instruction.fromBytes` 在 Call src=0 路径上用 hash 反查回 name
  - `linkProgram` 从 stub 扶正，接通整条管道
  - golden fixture：`src/testdata/hello-shim.so`（reference-shim 产出）
  - **验收**：**hello.o 字节一致**（1192 bytes MATCH reference-shim）
  - 这是 C1 的决定性里程碑：Zig 管道跟 Rust sbpf-assembler 字节对等

---

## Epic C1-H：CLI + 集成

**目标**：一个可用的 CLI 二进制。

**预估**：1-2 天

**依赖**：C1-G

### 任务

- [x] **H.1**：`main.zig` — argument parsing ✅ 2026-04-18（由 linter 在 F.1 commit 期间一并完成）
  - `parseArgv` → `ParsedArgs { help, run { input_path, output_path } }`
  - `printUsage` 写 stderr
  - 3 单测（run / help / invalid arity）
- [x] **H.2**：`main.zig` — 主流程 ✅ 2026-04-18
  - CLI 入口、参数解析、读写文件和退出码路径已接好
  - `linkProgram` 已接通，`elf2sbpf input.o output.so` 端到端可用
- [x] **H.3**：基本错误处理 ✅ 2026-04-18
  - `linkErrorExitCode(LinkError) → u8`（按错误类型映射 1-5）
  - 文件读写错误分别 exit 2/5
  - 所有失败路径走 stderr + `std.process.exit`

---

## Epic C1-I：对拍测试 & 验证

**目标**：自动化 9/9 example 的对拍测试，作为 C1 验收门。

**预估**：3-5 天

**依赖**：C1-H

### 任务

- [x] **I.1**：扩展 `scripts/validate-all.sh` ✅ 2026-04-18
  - 增加第三列对拍：Zig 版 vs shim
  - 表格输出：example | baseline | shim | zig | shim-vs-zig
  - `validate-zig.sh` 作为兼容入口补齐
  - **验收**：脚本跑完 9/9 example，**全部 MATCH**

- [x] **I.2**：Golden fixtures ✅ 2026-04-18
  - 9 个 `<example>.o` + `<example>.shim.so` 提交到 `src/testdata/`
    （共 18 个文件，~75 KB）
  - `.gitignore` 放行 `src/testdata/*.so`
  - **验收**：9 个 golden 文件就位（hello/noop/logonly/counter/
    vault/transfer-sol/pda-storage/escrow/token-vault）

- [x] **I.3**：Zig 侧集成测试 ✅ 2026-04-18
  - 新测试 `integration: 9 zignocchio examples byte-match reference-shim`
    在 `src/integration_test.zig` 里遍历 9 个 golden，用
    `runPipeline` → `expectEqualSlices`
  - 失败时打印第一个差异字节偏移，方便 regressions 诊断
  - **验收**：`zig build test` 在 9/9 example 上**全绿**（362/362
    tests）

- [ ] **I.4**：CI 脚本
  - `.github/workflows/ci.yml` 或者 `Makefile`
  - 跑：`zig build` + `zig build test` + `validate-all.sh`
  - **验收**：一条命令跑完全部 C1 验收

- [x] **I.5**：README 更新 ✅ 2026-04-18
  - 更新 status 到 "C1 MVP 已达成"
  - 更新 scope 里每个条目的状态
  - **验收**：README 与当前实现状态一致

- [ ] **I.6**（可选）：zignocchio `build.zig` 草稿
  - 在 elf2sbpf 仓库里放一份修改后的 `build.zig` 作为 PR 预览
  - **验收**：用 elf2sbpf 替代 sbpf-linker 调用，能跑通

---

## 进度汇总

**已完成（C0）**：验证、shim patch、文档

**C1 Epic 状态**：

| Epic | 任务数 | 已完成 | 状态 |
|------|--------|--------|------|
| A — 项目骨架 | 3 | 3 | ✅ 完成 |
| B — 通用数据类型 | 10 | 9 | 实质完成（89%；B.10 集成已在 B.9 覆盖） |
| C — ELF 读取层 | 5 | 5 | ✅ 完成 |
| D — Byteparser | 9 | 9 | ✅ 完成 |
| E — AST | 4 | 4 | ✅ 完成 |
| F — ELF 输出层 | 12 | 12 | ✅ 完成 |
| G — Program emit | 4 | 4 | ✅ 完成 |
| H — CLI | 3 | 3 | ✅ 完成 |
| I — 对拍测试 | 6 | 4 | 进行中（9/9 已绿；golden 入库 + Zig 侧 loop 已接通；剩 CI / zignocchio 草稿） |
| **总计** | **56** | **52** | **93%** |

\* B.4 推迟到 D；本 Epic 实际工作量少 1 个。

---

## 执行策略

### 推荐顺序（单人）

1. **Week 1**：Epic A + Epic B.1-B.5（起手完全机械的代码，先把
   编译链路打通）
2. **Week 2**：Epic B.6-B.10 + Epic C（Instruction decode 和 ELF
   读取并行）
3. **Week 3**：Epic D（byteparser 核心逻辑；每个子任务都要跟 shim
   对拍）
4. **Week 4**：Epic E + Epic F.1-F.6（AST 和 header/section 基础）
5. **Week 5**：Epic F.7-F.12 + Epic G（动态 section + 最终 emit；
   这里第一次能端到端产出 `.so`）
6. **Week 6**：Epic H + Epic I（CLI 和对拍）
7. **Week 7-8**：Bug fixing + 覆盖剩下的 example + 收尾

### Epic 并行化机会

- **F 可以跟 D / E 并行**（都是独立的数据处理，不互相依赖）
- **B.6-B.10 可以跟 C 并行**（Instruction 和 ELF 读取不互相依赖）
- 单人做的话按上面的顺序；两人做的话 Week 3-5 可以切一半

### 每个任务完成的检查项

做每个任务时，完成前必须确认：

1. ✅ 代码通过 `zig fmt`
2. ✅ 新增代码有单元测试，测试全绿
3. ✅ 如果是 D / G 里的任务，跟 shim 对应输出对拍通过
4. ✅ 在本文档里勾选该任务
5. ✅ commit，一个任务一个 commit（便于 bisect）
