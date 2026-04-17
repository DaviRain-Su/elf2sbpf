# C1 任务清单（Phase 4 — Task Breakdown）

**目标**：把 sbpf-linker 的 stage 2 完整 port 成 Zig，9/9 zignocchio
example 跟 `reference-shim` 字节一致。

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
  - `scripts/validate-zig.sh` 推迟到 Epic C1-I（实际端到端对拍时才需要）
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

- [ ] **C.4**：`elf/reloc.zig` — relocation 迭代
  - `iterRelocations(section)` 返回某 section 里的所有 relocation
  - 每个有 `offset()` `type()` `target_symbol()`
  - **验收**：能读 hello.o 的 `.rel.text`，1 个
    `R_BPF_64_64`，指向 `.rodata.str1.1`

- [ ] **C.5**：集成测试
  - 写一个简单的 `elf-dump.zig` 命令，用上面几个 API 把 hello.o
    的结构打印出来
  - **验收**：输出跟 `llvm-readelf -a` 在关键字段上一致

---

## Epic C1-D：Byteparser 逻辑

**目标**：实现 `byteparser.zig`——核心的 ELF → ParseResult 转换，
**包含改进版 rodata gap-fill 算法**。

**预估**：5-7 天

**依赖**：C1-B（Instruction）+ C1-C（ELF 读取）

### 任务

- [ ] **D.1**：识别 `ro_sections` 和 `text_section_bases`
  - 扫 section，过滤以 `.rodata` 或 `.data.rel.ro` 开头的
  - 扫 section，过滤以 `.text` 开头的，计算每个 section 在合并后
    的 base offset
  - **验收**：对 hello.o 能正确识别 1 个 rodata、1 个 text
    section

- [ ] **D.2**：扫符号，收集 `pending_rodata`
  - 对每个符号，若它属于 rodata section 且不是 `STT_SECTION` 且
    `size > 0`，收集成 `RodataEntry`
  - 同时：text 符号 push 成 `ASTNode::Label`
  - 同时：名字为 `entrypoint` 的符号 push 成
    `ASTNode::GlobalDecl`
  - **验收**：对 hello.o，pending_rodata 初始为空（Zig 产的 rodata
    没具名符号），text label 包含 `entrypoint`

- [ ] **D.3**：扫 text relocation，收集 `lddw_targets`（改进算法）
  - 对每个 text section 的 relocation，检查对应 offset 是不是
    lddw（opcode == 0x18）
  - 若是且目标在 rodata section，从指令 imm 字段取 addend
  - 按 section 索引放入 `lddw_targets: HashMap<SectionIndex,
    SortedSet<u64>>`
  - **关键**：**这是改进点，byteparser.rs 没做这步**
  - **验收**：对 counter.o，lddw_targets 对 `.rodata.str1.1`
    section 收集到 14 个不同的 addend（跟 Rust shim 一致）

- [ ] **D.4**：Gap-fill 算法（改进版）
  - 计算每个 rodata section 的 anchor 集合：
    `{0, section_size} ∪ {e.address, e.address+e.size for e in
    named_entries} ∪ {t for t in lddw_targets if t < section_size}`
  - 排序、去重
  - 对每对相邻 anchor `[start, end)`，若此 start 没被已有 named
    entry 占，合成一个 `.rodata.__anon_<section>_<start>` 条目
  - **Sanity check**：lddw target 不能落在 named entry 内部（panic）
  - **验收**：对 counter.o，产出 14 个匿名条目；对 hello.o 产出
    1 个匿名条目；字节内容跟 Rust shim 一致

- [ ] **D.5**：合并并排序 `pending_rodata`，构建 `rodata_table`
  - `HashMap<(SectionIndex, u64), String>`
  - 设 `rodata_offset`，逐个 emit 成 `ASTNode::ROData`
  - **验收**：rodata_table 的 key 集合跟 shim 一致

- [ ] **D.6**：Text 指令解析
  - 对每个 text section 的 data，逐字节 decode 成 `Instruction`
  - lddw 16 字节，其他 8 字节
  - emit 成 `ASTNode::Instruction { offset: section_base + offset, ... }`
  - **验收**：hello.o 的 8 条指令全部 decode 成功，跟
    llvm-objdump 对比

- [ ] **D.7**：Relocation 重写
  - lddw：rodata_table 查找 → `node.imm = Either.left(ro_label)`
  - call：若目标是 STT_SECTION，扫符号找具名目标；否则直接用符号名
    - 若找不到（无具名目标），保持原 imm（是个 PC-relative offset）
  - **验收**：hello.o 的 `call sol_log_` relocation 正确重写

- [ ] **D.8**：debug section 暂存（最小实现）
  - 对 `.debug_*` section，保留原始字节到 `debug_sections`
  - C1 阶段只保留，不做重定位
  - **验收**：不崩即可；zignocchio example 通常不带 debug

- [ ] **D.9**：输出 `ParseResult`
  - 调 `AST.buildProgram(SbpfArch.V0)` 得到 ParseResult
  - 塞入 debug_sections
  - **验收**：对 hello.o 返回的 ParseResult 能被 emit 阶段消化

---

## Epic C1-E：AST 中间表示

**目标**：Port `astnode.rs` + `ast.rs`，包括 V0 版 build_program。

**预估**：5-7 天

**依赖**：C1-B（Instruction）

### 任务

- [ ] **E.1**：`ast/node.zig`
  - `ASTNode` tagged union：`Label` | `Instruction` | `ROData`
    | `GlobalDecl`
  - `Label`、`ROData`、`GlobalDecl` 子结构
  - **验收**：能构造每种 node 并格式化打印

- [ ] **E.2**：`ast/ast.zig` — AST 结构
  - `struct { nodes, rodata_nodes, text_size, rodata_size }`
  - `init`、`setTextSize`、`setRodataSize`
  - `getInstructionAtOffset(offset) ?*Instruction`
  - **验收**：构造一个 AST，塞入指令节点，用 offset 查到

- [ ] **E.3**：`ast/ast.zig` — `buildProgram(SbpfArch.V0)`
  - 第一遍：扫描所有 label 节点，建 `label_offset_map`
  - 第一遍：扫描 rodata 节点，建 `rodata label_offset_map`
  - 第二遍：对每个 instruction 节点：
    - syscall 注入：若是 syscall，设 src=1, imm=-1，push relocation
      和 dynamic symbol
    - jump 解析：label 引用 → 相对 offset
    - call 解析：label 引用 → 相对 offset
    - lddw 解析：label 引用 → 绝对地址（V0：`target + ph_offset`）
  - 最后：收集 entry_point 到 `dynamic_symbols`
  - **验收**：对 hello.o 的 ParseResult，buildProgram 产出的
    ParseResult 跟 shim 的结构等价（字段逐一对比）

- [ ] **E.4**：E.1-E.3 集成测试
  - 用 D.9 的输出喂进来，检查 buildProgram 跟 shim 的字节等价
  - **验收**：hello.o 的 parse_result → build_program 之后，关键
    字段（code_section 大小、data_section 大小、dynamic_symbols
    entries）跟 shim 一致

---

## Epic C1-F：ELF 输出层（移植 sbpf-assembler 的 section / header）

**目标**：Port `header.rs` + `section.rs` + `dynsym.rs` 的
Solana SBPF 特有结构。

**预估**：7-10 天

**依赖**：C1-B（Number 等基础类型）

### 任务

- [ ] **F.1**：`emit/header.zig` — `ElfHeader`
  - Solana 特有常量：ident = `\x7fELF\x02\x01\x01\0...`,
    e_type=ET_DYN(3), e_machine=EM_BPF(247)
  - `bytecode() []u8`：emit 64 字节
  - **验收**：跟 Rust 版 emit 相同字节

- [ ] **F.2**：`emit/header.zig` — `ProgramHeader`
  - 56 字节布局
  - Solana 常量：`V3_BYTECODE_VADDR` 等
  - `bytecode() []u8`
  - **验收**：跟 Rust 版 emit 相同字节

- [ ] **F.3**：`emit/section_types.zig` — `SectionHeader`（通用 64 字节）
  - Section header 工厂函数
  - 常量：`SHT_PROGBITS`, `SHT_DYNAMIC`, `SHT_DYNSYM`, `SHT_STRTAB`,
    `SHT_REL`, `SHT_NULL`, `SHF_ALLOC`, `SHF_EXECINSTR`, `SHF_WRITE` 等
  - **验收**：给定参数能 emit 正确的 64 字节

- [ ] **F.4**：`emit/section_types.zig` — `NullSection` / `ShStrTabSection`
  - NullSection：全零 64 字节 section header
  - ShStrTabSection：section 名字的字符串表
  - **验收**：emit 跟 Rust 版一致

- [ ] **F.5**：`emit/section_types.zig` — `CodeSection`
  - 持有 Instruction 节点列表
  - `bytecode()`：序列化所有指令的二进制
  - `sectionHeaderBytecode()`：emit 64 字节 section header
  - **验收**：对 hello 的 text 节点，emit 的字节跟 shim 一致

- [ ] **F.6**：`emit/section_types.zig` — `DataSection`
  - 持有 ROData 节点列表
  - `bytecode()`：序列化所有 rodata 字节
  - **验收**：对 counter 的 rodata 节点，emit 字节跟 shim 一致

- [ ] **F.7**：`emit/section_types.zig` — `DynSymSection`
  - 24 字节每 entry
  - `emit`：遍历 dynamic_symbols，emit 符号表
  - **验收**：对 hello，dynsym 内容跟 baseline 一致

- [ ] **F.8**：`emit/section_types.zig` — `DynStrSection`
  - 字符串表（跟 symbol names 对应）
  - **验收**：内容跟 shim 一致

- [ ] **F.9**：`emit/section_types.zig` — `DynamicSection`
  - 16 字节每 entry，标准 ELF dynamic 条目
  - Tags: `FLAGS`、`REL`、`RELSZ`、`RELENT`、`RELCOUNT`、`SYMTAB`、
    `SYMENT`、`STRTAB`、`STRSZ`、`TEXTREL`、`NULL`
  - **验收**：hello.so 的 dynamic section 字节一致

- [ ] **F.10**：`emit/section_types.zig` — `RelDynSection`
  - 16 字节每 entry（R_BPF_64_RELATIVE / R_BPF_64_32 / R_SBF_SYSCALL）
  - **验收**：跟 baseline rel.dyn 一致

- [ ] **F.11**：`emit/section_types.zig` — `DebugSection`
  - 原样保留传入的字节（debug info reuse）
  - **验收**：对有 debug 的输入（手构的），字节透传

- [ ] **F.12**：`emit/section_types.zig` — SectionType 分派
  - `union(enum) SectionType { Null, Code, Data, ... }`
  - 每个变体有 `name()` / `bytecode()` / `sectionHeaderBytecode()`
    / `size()` 方法
  - **验收**：对 hello 的全部 section 能统一迭代

---

## Epic C1-G：Program::from_parse_result + emit_bytecode

**目标**：Port `program.rs` 的 `from_parse_result` + `emit_bytecode`。
这是最终产出 `.so` 字节的核心。

**预估**：5-7 天

**依赖**：C1-E（AST）+ C1-F（ELF 输出）

### 任务

- [ ] **G.1**：`emit/program.zig` — `Program` 结构
  - `struct { elf_header, program_headers, sections }`

- [ ] **G.2**：`emit/program.zig` — `fromParseResult(pr: ParseResult, arch: V0)`
  - 从 ParseResult 构建 sections 列表
  - 计算 `e_entry`、`e_phoff`、`e_shoff`、`e_shnum`、`e_shstrndx`
  - V0 特有：program_headers 数量（static=0 / dynamic=3）
  - 遍历 sections，分配 offset
  - **验收**：对 hello 的 ParseResult，Program 的字段（section 数
    量、每个 section 的 offset）跟 shim 一致

- [ ] **G.3**：`emit/program.zig` — `emitBytecode() []u8`
  - 按顺序 emit：ELF header → program headers → section 内容 →
    section headers
  - **关键**：padding（shoff 要 8 字节对齐）
  - **验收**：`zig-version.so` 跟 `shim-version.so` 字节完全一致

- [ ] **G.4**：端到端集成测试
  - 用 D.9 的输出 → E.3 → G.3，把 hello.o 跑到底产出 `.so`
  - 跟 shim 产物 `cmp` 对拍
  - **验收**：**hello.o 字节一致**（MATCH）

---

## Epic C1-H：CLI + 集成

**目标**：一个可用的 CLI 二进制。

**预估**：1-2 天

**依赖**：C1-G

### 任务

- [ ] **H.1**：`main.zig` — argument parsing
  - 用 `std.process.argsAlloc`
  - `elf2sbpf input.o output.so`
  - **验收**：`./elf2sbpf --help` 打印用法

- [ ] **H.2**：`main.zig` — 主流程
  - 读 input.o → parse → build_program → from_parse_result →
    emit_bytecode → 写 output.so
  - 错误处理：用 Zig `error` set
  - **验收**：`./elf2sbpf fixtures/helloworld/out/hello.o /tmp/hello.zig.so`
    产出的文件跟 shim 一致

- [ ] **H.3**：基本错误处理
  - 文件不存在、ELF 格式非法、parse 失败等
  - 错误用 stderr 输出，返回非零 exit code
  - **验收**：各种错误路径有友好输出

---

## Epic C1-I：对拍测试 & 验证

**目标**：自动化 9/9 example 的对拍测试，作为 C1 验收门。

**预估**：3-5 天

**依赖**：C1-H

### 任务

- [ ] **I.1**：扩展 `scripts/validate-all.sh`
  - 增加第三列对拍：Zig 版 vs shim
  - 表格输出：example | baseline | shim | zig | shim-vs-zig
  - **验收**：脚本跑完 9/9 example

- [ ] **I.2**：Golden fixtures
  - 把 shim 对每个 example 产出的 `.so` 保存到
    `tests/golden/<example>.so`
  - 加一个 `make-golden.sh` 脚本重新生成
  - **验收**：9 个 golden 文件存在

- [ ] **I.3**：Zig 侧集成测试
  - `zig build test` 能对每个 golden 做 cmp
  - 用 `build.zig` 的 `test_step`
  - **验收**：`zig build test` 在 9/9 example 上全绿

- [ ] **I.4**：CI 脚本
  - `.github/workflows/ci.yml` 或者 `Makefile`
  - 跑：`zig build` + `zig build test` + `validate-all.sh`
  - **验收**：一条命令跑完全部 C1 验收

- [ ] **I.5**：README 更新
  - 更新 status 到 "C1 complete"
  - 更新 scope 里每个条目的 checkmark
  - **验收**：`docs/C1-tasks.md` 全部勾选 + README 状态更新

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
| C — ELF 读取层 | 5 | 3 | 进行中 (60%) |
| D — Byteparser | 9 | 0 | 未开始 |
| E — AST | 4 | 0 | 未开始 |
| F — ELF 输出层 | 12 | 0 | 未开始 |
| G — Program emit | 4 | 0 | 未开始 |
| H — CLI | 3 | 0 | 未开始 |
| I — 对拍测试 | 6 | 0 | 未开始 |
| **总计** | **56** | **14** | **25%** |

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
