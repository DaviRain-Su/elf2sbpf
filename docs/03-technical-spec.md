# 03 — 技术规格（核心版）

**Phase**：3 — Technical Spec
**依赖**：`02-architecture.md`（Phase 2）
**下一步**：`05-test-spec.md`（Phase 5）

---

## 本文档的 scope

这是**核心版**，不是完整的字段级规格。遵循以下取舍：

- **新设计决策**必须精确到字段、字节、算法（Zig 的错误模型、
  内存管理、改进版 gap-fill、ELF 布局常量）
- **直接 port Rust 实现**的部分**只列对应关系**，指向 Rust 源文件
  作为规格（那边的代码就是 spec）
- **常量表**集中在一处（Section 7），任何硬编码都在这里
- **边界条件**至少 12 个，包括 C0 已遇到的 3 种

---

## 1. 公共接口

### 1.1 CLI（`main.zig` 暴露）

```
elf2sbpf <input.o> <output.so>
```

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `<input.o>` | 路径 | 是 | BPF ELF 目标文件 |
| `<output.so>` | 路径 | 是 | 输出 Solana SBPF 程序 |

**退出码**：

| Code | 含义 |
|------|------|
| 0 | 成功 |
| 1 | 参数错误（数量不对、help） |
| 2 | 输入文件读取失败 |
| 3 | ELF 解析失败 |
| 4 | link 处理错误（byteparser / AST / emit 前置检查失败） |
| 5 | 输出写入失败 |

### 1.2 库入口（`lib.zig` 暴露）

```zig
pub const linker = @import("lib.zig");

pub fn linkProgram(
    allocator: std.mem.Allocator,
    elf_bytes: []const u8,
) LinkError![]u8;
```

**契约**：

- **输入前置**：`elf_bytes` 是有效的 BPF ELF64 little-endian（不满足返回 `InvalidElf`）
- **输出后置**：返回的 `[]u8` 所有权转给调用方，调用方负责 `allocator.free`
- **失败语义**：任何失败都返回 `LinkError` 成员，不 `panic`
- **纯函数**：同一输入多次调用产物相同

### 1.3 错误集合

```zig
pub const LinkError = error{
    // ELF 解析
    InvalidElf,
    UnsupportedMachine,          // e_machine != 247 (EM_BPF)
    UnsupportedClass,            // 非 ELF64
    UnsupportedEndian,           // 非 little-endian

    // byteparser
    InstructionDecodeFailed,     // 未知 opcode / lddw 长度不足
    TextSectionMisaligned,       // `.text` 尾部不是完整 8/16-byte 指令
    LddwTargetOutsideRodata,     // lddw relocation 目标不在 rodata
    LddwTargetInsideNamedEntry,  // addend 落在命名符号内部（compiler bug？）
    CallTargetUnresolvable,      // call relocation 目标找不到

    // AST buildProgram
    UndefinedLabel,
    RodataSectionOverflow,       // rodata addend ≥ section_size

    // emit
    RodataTooLarge,              // 超过 SBPF V0 容许的大小
    TextTooLarge,

    // 分配
    OutOfMemory,
};
```

`panic` 只在**内部不可能状态**（如枚举穷尽错过默认分支）时用。用户
输入错误**永远**走 error return。

---

## 2. 核心数据结构

### 2.1 Layer 1: `common/`

#### `Number`（tagged union）

```zig
pub const Number = union(enum) {
    Int: i64,
    Addr: i64,

    pub fn toI64(self: Number) i64;
    pub fn toI16(self: Number) i16;
};
```

对应 Rust `sbpf-common::inst_param::Number`
（源：`sbpf/crates/common/src/inst_param.rs` line 17-21）。

**只有两个变体**——Int 和 Addr。语义差别：Addr 参与算术时"吸收"
Int（Addr + Int = Addr），Int + Int 才产出 Int。C1 MVP 不需要
arithmetic ops（byteparser/emit 只做构造和值读取），所以 Zig 版**先
不实现** +/-/\*//，Epic D.x 按需再补。

#### `Register`

```zig
pub const Register = struct { n: u8 };
```

对应 Rust `sbpf-common::inst_param::Register`
（源：`sbpf/crates/common/src/inst_param.rs` line 7-9）。

- `n: u8`（**不是** u4——跟 Rust 保持一致）
- 合法值 0..10（BPF 有 11 个寄存器 r0..r10），但 Rust 没 runtime
  约束，我们也不加
- Display 格式为 `r{n}`，如 `r0`、`r10`

#### `Opcode`

`enum(u8)` 直接等于指令字节。**完整变体表直接从 Rust port**，约 500
个 variant。规范参考：

- **源规格**：`sbpf/crates/common/src/opcode.rs` lines 178-636
- **规范定义**：LLVM BPF target 的 instruction encoding
- **Solana 关心的子集**：V0 SbpfArch = 禁用 JMP32 class（0x06）

关键辅助函数（必须 port）：

| 函数 | 语义 | 对应 Rust |
|------|------|----------|
| `toStr(op)` | 返回助记符字符串 | `Opcode::to_str` |
| `fromSize(size, kind)` | 从 "b/h/w/dw" + Load/Store → Opcode | `Opcode::from_size` |
| `toSize(op)` | 反向 | `Opcode::to_size` |
| `toOperator(op)` | 返回 "+ / - / ..." 等符号 | `Opcode::to_operator` |
| `is32bit(op)` | 是否 32 位变体 | `Opcode::is_32bit` |

#### `Instruction`

```zig
pub const Instruction = struct {
    opcode: Opcode,
    dst: ?Register,
    src: ?Register,
    off: ?Either(LabelRef, i16),
    imm: ?Either(LabelRef, Number),
    span: Span,
};

pub const LabelRef = struct { name: []const u8 };
pub const Span = struct { start: usize, end: usize };

pub fn Either(comptime L: type, comptime R: type) type {
    return union(enum) {
        left: L,
        right: R,
    };
}
```

`Either` 对应 Rust `either::Either`。Zig stdlib 没有，我们自己实现。

**方法**（port 自 `sbpf-common::instruction::Instruction`）：

| 方法 | 说明 |
|------|------|
| `fromBytes(bytes) !Instruction` | 从 `[]const u8` 解码一条；lddw 吃 16 字节，其他吃 8 |
| `toBytes(inst, buf) !void` | 反向 |
| `isJump(inst) bool` | opcode 是跳转类 |
| `isSyscall(inst) bool` | 是 call + src=0 + imm 是具体 hash（或 label 待解析） |
| `getSize(inst) u64` | 8 或 16 |

**内部辅助**：

| 常量 | 值 | 用途 |
|------|---|------|
| `LDDW_OPCODE` | 0x18 | lddw 的第一字节 |
| `INSTRUCTION_SIZE` | 8 | 普通指令字节数 |
| `LDDW_SIZE` | 16 | lddw 指令字节数 |

#### `syscalls`

唯一函数：

```zig
pub fn murmur3_32(name: []const u8) u32;
```

**算法规格**见 Section 6.1。

---

### 2.2 Layer 1: `elf/`

#### `ElfFile`

```zig
pub const ElfFile = struct {
    bytes: []const u8,
    header: std.elf.Elf64_Ehdr,
    section_headers: []const std.elf.Elf64_Shdr,
    strtab: []const u8,  // section header string table

    pub fn parse(bytes: []const u8) !ElfFile;

    pub fn iterSections(self: *const ElfFile) SectionIter;
    pub fn sectionByIndex(self: *const ElfFile, idx: u16) !Section;

    pub fn iterSymbols(self: *const ElfFile, allocator) !SymbolIter;
    pub fn symbolByIndex(self: *const ElfFile, idx: u32) !Symbol;

    pub fn iterRelocations(self: *const ElfFile, section: Section) RelocIter;
};
```

**实现策略**：所有迭代器都是**零拷贝**（引用 `bytes` 切片）。只在
必须物化时才分配（例如需要排序的符号表）。

#### `Section`

```zig
pub const Section = struct {
    index: u16,
    header: *const std.elf.Elf64_Shdr,
    name: []const u8,        // 从 strtab 取
    data: []const u8,        // 从 bytes 切片

    pub fn flags(self: Section) u64 { return self.header.sh_flags; }
    pub fn size(self: Section) u64 { return self.header.sh_size; }
    pub fn kind(self: Section) u32 { return self.header.sh_type; }
};
```

#### `Symbol`

```zig
pub const Symbol = struct {
    index: u32,
    raw: *const std.elf.Elf64_Sym,
    name: []const u8,
    section_index: ?u16,  // null if SHN_UNDEF or SHN_ABS

    pub fn address(self: Symbol) u64 { return self.raw.st_value; }
    pub fn size(self: Symbol) u64 { return self.raw.st_size; }
    pub fn kind(self: Symbol) SymbolKind { ... }  // STT_FUNC / STT_OBJECT / STT_SECTION / ...
    pub fn binding(self: Symbol) SymbolBinding { ... }  // STB_LOCAL / GLOBAL / WEAK
};

pub const SymbolKind = enum { Unknown, Object, Func, Section, File, Common, Tls };
pub const SymbolBinding = enum { Local, Global, Weak };
```

#### `Reloc`

```zig
pub const Reloc = struct {
    offset: u64,          // 在目标 section 内的偏移
    type: RelocType,
    symbol_index: u32,
    addend: i64,          // 显式 addend；lddw 的 implicit addend 在 byteparser 里单独处理
};

pub const RelocType = enum(u32) {
    BPF_64_64       = 1,   // lddw target
    BPF_64_ABS64    = 2,
    BPF_64_ABS32    = 3,
    BPF_64_NODYLD32 = 4,
    BPF_64_32       = 10,  // call
    _,
};
```

---

### 2.3 Layer 2: `ast/`

直接对应 Rust `sbpf-assembler::ast` 和 `astnode`。

#### `ASTNode`

```zig
pub const ASTNode = union(enum) {
    Instruction: struct {
        instruction: Instruction,
        offset: u64,
    },
    Label: struct {
        label: Label,
        offset: u64,
    },
    ROData: struct {
        rodata: ROData,
        offset: u64,
    },
    GlobalDecl: struct {
        global_decl: GlobalDecl,
    },
};

pub const Label = struct { name: []const u8, span: Span };
pub const ROData = struct { name: []const u8, args: []const Token, span: Span };
pub const GlobalDecl = struct { entry_label: []const u8, span: Span };
pub const Token = union(enum) {
    Directive: struct { name: []const u8, span: Span },
    VectorLiteral: struct { items: []const Number, span: Span },
    // 其他 Token 变体（StringLiteral/Identifier/ImmediateValue）byteparser 不产生，C1 阶段不实现
};
```

#### `AST`

```zig
pub const AST = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(ASTNode),
    rodata_nodes: std.ArrayList(ASTNode),
    text_size: u64 = 0,
    rodata_size: u64 = 0,

    pub fn init(allocator) AST;
    pub fn deinit(self: *AST) void;

    pub fn setTextSize(self: *AST, size: u64) void;
    pub fn setRodataSize(self: *AST, size: u64) void;
    pub fn getInstructionAtOffset(self: *AST, offset: u64) ?*Instruction;

    pub fn buildProgram(
        self: *AST,
        arch: SbpfArch,
    ) LinkError!ParseResult;
};

pub const SbpfArch = enum { V0, V3 };  // C1 只实现 V0
```

`buildProgram` 的详细算法见 Section 6.3。

#### `ParseResult`

```zig
pub const ParseResult = struct {
    code_section: CodeSection,
    data_section: DataSection,
    dynamic_symbols: DynamicSymbolMap,
    relocation_data: RelDynMap,
    prog_is_static: bool,
    arch: SbpfArch,
    debug_sections: []const DebugSection,
};

pub const DynamicSymbolMap = struct { ... };  // 见 Section 2.4
pub const RelDynMap = struct { ... };         // 见 Section 2.4
pub const DebugSection = struct {
    name: []const u8,
    offset: u64,
    data: []const u8,
};
```

---

### 2.4 Layer 3: `emit/`

#### `ElfHeader`

64 字节，所有字段已知长度。Zig 可以直接 `extern struct`：

```zig
pub const ElfHeader = extern struct {
    e_ident: [16]u8,
    e_type: u16,       // = 3 (ET_DYN)
    e_machine: u16,    // = 247 (EM_BPF)
    e_version: u32,    // = 1
    e_entry: u64,
    e_phoff: u64,      // = 64
    e_shoff: u64,      // 动态计算
    e_flags: u32,      // V0 = 0, V3 = 3
    e_ehsize: u16,     // = 64
    e_phentsize: u16,  // = 56
    e_phnum: u16,      // 0 / 2 / 3
    e_shentsize: u16,  // = 64
    e_shnum: u16,
    e_shstrndx: u16,

    pub fn init() ElfHeader { ... }
    pub fn bytecode(self: ElfHeader) [64]u8 { ... }  // bit-cast 直接出
};
```

常量详见 Section 7。

#### `ProgramHeader`

```zig
pub const ProgramHeader = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};  // 56 bytes

pub const V3_BYTECODE_VADDR: u64 = 0x100000000;  // Solana V3 text 虚拟地址
```

#### `SectionType`（union）

```zig
pub const SectionType = union(enum) {
    Null: NullSection,
    Code: CodeSection,
    Data: DataSection,
    DynSym: DynSymSection,
    DynStr: DynStrSection,
    Dynamic: DynamicSection,
    RelDyn: RelDynSection,
    ShStrTab: ShStrTabSection,
    Debug: DebugSection,

    pub fn name(self: SectionType) []const u8;
    pub fn size(self: SectionType) u64;
    pub fn bytecode(self: SectionType, allocator) ![]u8;
    pub fn sectionHeaderBytecode(self: SectionType) [64]u8;
};
```

各 `*Section` 结构体字段布局和 Rust `sbpf-assembler::section` 一一对应。
**直接 port**，不在本 spec 里重复。参考 Rust 源：

- `sbpf/crates/assembler/src/section.rs`
- `sbpf/crates/assembler/src/header.rs`
- `sbpf/crates/assembler/src/dynsym.rs`

#### `Program`

```zig
pub const Program = struct {
    elf_header: ElfHeader,
    program_headers: ?[]ProgramHeader,
    sections: []SectionType,

    pub fn fromParseResult(
        allocator: std.mem.Allocator,
        pr: ParseResult,
    ) LinkError!Program;

    pub fn emitBytecode(
        self: *const Program,
        allocator: std.mem.Allocator,
    ) LinkError![]u8;
};
```

`emitBytecode` 的精确顺序见 Section 6.4。

---

## 3. 内存管理策略

### 3.1 Allocator 线程约定

每个分配型函数**显式接收** `std.mem.Allocator`。
**不使用**：`std.heap.page_allocator`、`std.heap.c_allocator` 作为默认。

```zig
// 正确
pub fn parseBytecode(allocator: Allocator, bytes: []const u8) !ParseResult;

// 错误（避免）
pub fn parseBytecode(bytes: []const u8) !ParseResult;  // 谁分配？
```

### 3.2 所有权传递

- 函数返回的 `[]T` 切片**所有权转给调用方**
- 调用方负责 `allocator.free(slice)`
- 切片内部如果还有子切片（递归所有权），deinit 函数负责递归释放

### 3.3 临时内存

`parseBytecode` 和 `buildProgram` 内部会分配大量临时数据
（HashMap、ArrayList、排序缓冲区）。策略：

**使用 arena allocator**。在顶层函数入口创建 arena，内部所有临时
分配走 arena，函数返回前 `arena.deinit()`。最终返回给用户的数据
**必须从外层 allocator 重新分配**一次。

```zig
pub fn linkProgram(allocator: Allocator, elf_bytes: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var parse_result = try parseBytecode(arena_alloc, elf_bytes);
    var program = try Program.fromParseResult(arena_alloc, parse_result);

    // 从 arena 复制到用户 allocator
    return program.emitBytecode(allocator);
}
```

**理由**：简化 errdefer 链，避免"半成品状态下有 X 片需要单独释放"。

### 3.4 errdefer 约定

**任何** `allocator.alloc` 之后必须有 `errdefer allocator.free`，
除非立刻转交给其他结构（由后者的 deinit 负责）。

---

## 4. 错误处理模型

### 4.1 错误返回，不 panic

Rust `byteparser.rs` 里的 `panic!("relocation in lddw is not in .rodata")`
对应 Zig 的 `return LinkError.LddwTargetOutsideRodata`。

**例外**：只有代表**程序 bug**（而非用户错误输入）的情况才 panic：

- 穷尽 switch 遗漏
- 内部不变式被破坏（例如 HashMap 的 key 明明刚 insert 立刻 get 却
  get 到 null）

### 4.2 错误信息

本 C1 阶段不追求富文本错误（如源位置、上下文）。`LinkError` 的
variant name 就是诊断信息。main.zig 把 error 翻译成 stderr 输出 +
非零退出码。

**D 阶段可能会扩展**：加 span / context，类似 Rust 版的
`compiletest_rs` 风格。

### 4.3 断言策略

| 场景 | 做法 |
|------|------|
| 用户输入错误 | `return LinkError.X` |
| 程序 bug / unreachable | `unreachable` / `std.debug.panic` |
| 类型级约束（如 u4） | 类型系统本身约束 |
| 运行时不变式 | `std.debug.assert` |

`std.debug.assert` 在 ReleaseFast/Small 模式会被编掉，ReleaseSafe
保留。**C1 用 ReleaseSafe 构建测试，用 ReleaseSmall 构建发布**。

---

## 5. 状态机（管道阶段）

```
输入字节
  │
  │ State A: Raw bytes
  │  action: ElfFile.parse()
  ▼
ElfFile object
  │
  │ State B: Parsed ELF
  │  action: 识别 ro_sections、text_section_bases
  ▼
Classified sections
  │
  │ State C: Section map built
  │  action: 扫符号 → pending_rodata; 扫 text label → AST labels
  ▼
Named rodata + text labels
  │
  │ State D: Pass 1 complete
  │  action: 扫 text relocation 解码 lddw imm → lddw_targets
  ▼
lddw_targets collected
  │
  │ State E: Pass 2 complete（新算法步骤）
  │  action: 改进版 gap-fill（Section 6.2）→ 合成 anon entries
  ▼
Full rodata layout
  │
  │ State F: Pass 3 complete
  │  action: 构建 rodata_table (section_idx, offset) → label
  ▼
rodata_table built
  │
  │ State G: Pass 4 complete
  │  action: 解码所有 text section 指令 → ASTNode::Instruction
  ▼
AST with all instructions
  │
  │ State H: Pass 5 complete
  │  action: 遍历每个 reloc → 重写 lddw/call
  ▼
Fully resolved ParseResult
  │
  │ action: buildProgram(V0) — label 解析、syscall 注入、jump offset
  ▼
ParseResult with resolved immediates
  │
  │ action: Program.fromParseResult — 分配 section offset
  ▼
Program with offsets
  │
  │ action: Program.emitBytecode — 按顺序 emit 字节
  ▼
输出字节
```

任何 State → 下一 State 的过渡**失败返回 LinkError**，不回溯（因为
输入已经错了，回溯没意义）。

---

## 6. 核心算法规格

### 6.1 Murmur3-32（syscall hash）

**输入**：`[]const u8` (syscall 名字)
**输出**：`u32`

**规格**：

```
seed = 0

body (per 4-byte chunk, little-endian):
  k = chunk as u32
  k *= 0xcc9e2d51
  k = rotate_left(k, 15)
  k *= 0x1b873593
  hash ^= k
  hash = rotate_left(hash, 13)
  hash = hash * 5 + 0xe6546b64

tail (remaining 1-3 bytes):
  # Pad on the HIGH end with zeros, then run through pre_mix (same as body's k).
  # Tail does NOT do the rotate+mul+add step that body does.
  padded = [buf[i], (buf[i+1] if n>=2 else 0), (buf[i+2] if n>=3 else 0), 0]
  k = u32.from_le_bytes(padded)
  k *= 0xcc9e2d51
  k = rotate_left(k, 15)
  k *= 0x1b873593
  hash ^= k

finalization:
  hash ^= len(input)
  hash ^= hash >> 16
  hash *= 0x85ebca6b
  hash ^= hash >> 13
  hash *= 0xc2b2ae35
  hash ^= hash >> 16
```

**验证向量**（测试规格必须覆盖）：

| 输入 | 期望 `u32`（十六进制） |
|------|----------------------|
| `""` | `0x00000000` |
| `sol_log_` | `0x207559bd` |
| `sol_log_64_` | `0x5c2a3178` |
| `sol_log_pubkey` | `0x7ef088ca` |
| `sol_memcpy_` | `0x717cc4a3` |
| `sol_invoke_signed_c` | `0xa22b9c85` |

（用 `/tmp/murmur-verify/` 对照 Rust `sbpf-syscall-map::murmur3_32`
跑出来的真值；如果 port 后有一位不对，先查 rotate_left 方向和
tail padding 是不是高位补零）

### 6.2 改进版 Rodata Gap-Fill（关键）

这是 C0 阶段发现并验证的**新算法**，比 Rust byteparser.rs 更广义。

**输入**：
- `ro_sections: HashMap<SectionIndex, Section>`
- `pending_rodata: []RodataEntry`（来自命名符号）
- `text_sections: []Section`

**输出**：
- 扩充后的 `pending_rodata`，使得对任何 lddw target addend `t`，
  `(section_idx, t)` 都能在后续 rodata_table 里查到对应 label

**算法**：

```
# Pass 1: 收集所有 lddw target offsets
lddw_targets: HashMap<SectionIndex, SortedSet<u64>> = empty

for each text_section:
    for each reloc in text_section:
        sym = reloc.target_symbol()
        if sym.section_index() not in ro_sections:
            continue

        # Check if the instruction at reloc.offset is lddw
        inst_bytes = text_section.data()[reloc.offset..reloc.offset+8]
        if inst_bytes[0] != 0x18:   # not lddw opcode
            continue

        # Addend is in bytes 4..8 of the first 8-byte half (little-endian u32)
        addend = u32_le(inst_bytes[4..8]) as u64
        lddw_targets[sym.section_index()].insert(addend)

# Pass 2: 构造 anchor 集合（每个 rodata section 独立处理）
for each (section_index, ro_section) in ro_sections:
    named_entries = [e for e in pending_rodata if e.section_index == section_index]
    named_entries.sort_by_key(lambda e: e.address)

    anchors: SortedSet<u64> = {0, ro_section.size()}
    for e in named_entries:
        anchors.insert(e.address)
        anchors.insert(e.address + e.size)
    for t in lddw_targets.get(section_index, empty):
        if t < ro_section.size():
            anchors.insert(t)

    # Sanity: no lddw target may fall strictly inside a named entry
    for e in named_entries:
        for t in lddw_targets.get(section_index, empty):
            if e.address < t < e.address + e.size:
                return Err(LddwTargetInsideNamedEntry)

    # Pass 3: 填 anchor 对之间的 gap
    anchor_list = sorted(anchors)
    for (start, end) in windows(anchor_list, 2):
        if start >= end:
            continue
        # 如果 start 处已有命名条目，跳过
        if any(e.address == start for e in named_entries):
            continue
        bytes_slice = ro_section.data()[start..end]
        synthetic_rodata.push(RodataEntry {
            section_index: section_index,
            address: start,
            size: end - start,
            name: format!(".rodata.__anon_{:#x}_{:#x}", section_index, start),
            bytes: bytes_slice.map(|b| Number::Int(b)),
        })

# Merge
pending_rodata.extend(synthetic_rodata)
pending_rodata.sort_by_key(lambda e: (e.section_index, e.address))
```

**关键不变式**（Zig 实现必须满足）：

1. **完整性**：sort 后，相邻 `pending_rodata` 条目的 `[address, address+size)`
   相接或重叠（不重叠，应该相接）
2. **覆盖性**：每个 lddw target addend `t`，存在条目 `e` 使得
   `e.address == t`（不是 `<= t < e.address + e.size`！必须**正好
   等于**——否则 rodata_table key 错）
3. **唯一性**：没有两个条目同一 address（去重由 anchor SortedSet
   保证）

**跟 Rust byteparser 的差别**：

| 场景 | byteparser.rs 行为 | elf2sbpf 行为 |
|------|-------------------|--------------|
| Section 只有 STT_SECTION 符号 | 合成一个 offset=0 的大 anon 条目 | 按 lddw targets 切分成多个小 anon 条目 |
| 命名符号完全覆盖 section | 不产生 anon | 同 |
| 部分覆盖（有 gap 且有多 lddw target） | 合成单个 gap 条目（**有 bug**） | 在每个 lddw target 处切分 |

### 6.3 `buildProgram` 算法（V0 路径）

**输入**：`AST`
**输出**：`ParseResult`

**步骤**：

```
# Phase A: 收集 label 偏移映射
label_offset_map: HashMap<String, u64> = empty
numeric_labels: []Tuple<String, u64, usize> = empty  # 用于 1f/2b 这种

for (idx, node) in ast.nodes.enumerate():
    if node is Label:
        label_offset_map[node.name] = node.offset
        numeric_labels.push((node.name, node.offset, idx))

for node in ast.rodata_nodes:
    if node is ROData:
        label_offset_map[node.name] = node.offset + ast.text_size

# Phase B: 判断 prog_is_static
program_is_static = (arch == V3) || not any(
    node is Instruction where inst.is_syscall()
                        or (inst.opcode == Lddw and inst.imm is Either.Left)
    for node in ast.nodes
)

# Phase C: Syscall 注入
for node in ast.nodes:
    if node is Instruction and inst.is_syscall() and inst.imm is Either.Left(name):
        if arch == V3:
            inst.src = Register { n: 0 }
            inst.imm = Either.Right(Number.Int(murmur3_32(name)))
        else:  # V0
            inst.src = Register { n: 1 }
            inst.imm = Either.Right(Number.Int(-1))
            relocations.add_rel_dyn(offset, RelocationType.RSbfSyscall, name)
            dynamic_symbols.add_call_target(name, offset)

# Phase D: jump/call label 解析
for (idx, node) in ast.nodes.enumerate():
    if node is not Instruction: continue

    if inst.is_jump() and inst.off is Either.Left(label):
        target_offset = label_offset_map[label] or resolve_numeric(label, idx)
        rel_offset = (target_offset as i64 - offset as i64) / 8 - 1
        inst.off = Either.Right(rel_offset as i16)

    else if inst.opcode == Call and inst.imm is Either.Left(label):
        if target_offset = label_offset_map[label]:
            rel_offset = (target_offset as i64 - offset as i64) / 8 - 1
            inst.src = Register { n: 1 }
            inst.imm = Either.Right(Number.Int(rel_offset))

# Phase E: lddw 绝对化
for node in ast.nodes:
    if inst.opcode == Lddw and inst.imm is Either.Left(name):
        if arch != V3:
            relocations.add_rel_dyn(offset, RelocationType.RSbf64Relative, name)

        if target_offset = label_offset_map[name]:
            if arch == V3:
                abs = target_offset - ast.text_size
            else:  # V0
                ph_count = 1 if program_is_static else 3
                ph_offset = 64 + ph_count * 56
                abs = target_offset + ph_offset
            inst.imm = Either.Right(Number.Addr(abs))
        else:
            return Err(UndefinedLabel)

# Phase F: 收集 entry_point
entry_label = first(n.entry_label for n in ast.nodes where n is GlobalDecl)
if entry_label and offset = label_offset_map[entry_label]:
    dynamic_symbols.add_entry_point(entry_label, offset)

# Phase G: 组装 ParseResult
return ParseResult {
    code_section: CodeSection.new(ast.nodes, ast.text_size),
    data_section: DataSection.new(ast.rodata_nodes, ast.rodata_size),
    dynamic_symbols: dynamic_symbols,
    relocation_data: relocations,
    prog_is_static: program_is_static,
    arch: arch,
    debug_sections: [],
}
```

此算法直接 port 自 `sbpf/crates/assembler/src/ast.rs::build_program`。
上面的伪代码等价于 Rust 源代码，**改 Zig 实现前读那份 Rust 代码**。

### 6.4 `emitBytecode` 字节输出顺序

**严格顺序**：

```
1. ELF Header（64 字节）
2. Program Headers（0 / 2 / 3 × 56 字节）
3. Each SectionType.bytecode():
   - NullSection（0 字节）
   - CodeSection
   - DataSection
   - DynamicSection
   - DynSymSection
   - DynStrSection
   - RelDynSection
   - DebugSection（若有）
   - ShStrTabSection
4. Padding 到 8 字节对齐（因为 section header 要求对齐）
5. Each SectionType.sectionHeaderBytecode()（64 字节每个）
```

**e_shoff** = `4. Padding` 的结束位置，也就是 `5.` 开始的位置。

Section offset（每个 section 在文件中的起始 offset）在
`fromParseResult` 阶段就已计算好，`emitBytecode` 只负责顺序写出。

---

## 7. 常量表（集中）

### 7.1 ELF 通用常量

| 名称 | 值 | 用途 |
|------|---|------|
| `EI_MAG0..3` | `0x7f, 'E', 'L', 'F'` | ELF magic |
| `ELFCLASS64` | 2 | 64-bit |
| `ELFDATA2LSB` | 1 | little-endian |
| `EV_CURRENT` | 1 | ELF version |
| `ET_DYN` | 3 | Solana 程序类型 |
| `EM_BPF` | 247 | BPF machine ID |

### 7.2 Section 类型和 flag

| 名称 | 值 | 语义 |
|------|---|------|
| `SHT_NULL` | 0 | 空 |
| `SHT_PROGBITS` | 1 | 程序数据 |
| `SHT_SYMTAB` | 2 | 符号表 |
| `SHT_STRTAB` | 3 | 字符串表 |
| `SHT_REL` | 9 | 无 addend 的 relocation |
| `SHT_DYNSYM` | 11 | 动态符号表 |
| `SHT_DYNAMIC` | 6 | 动态段 |
| `SHF_WRITE` | 0x1 | 可写 |
| `SHF_ALLOC` | 0x2 | 加载到内存 |
| `SHF_EXECINSTR` | 0x4 | 可执行 |

### 7.3 BPF relocation 类型

| 名称 | 值 | 语义 |
|------|---|------|
| `R_BPF_64_64` | 1 | 64-bit absolute (lddw 用) |
| `R_BPF_64_ABS64` | 2 | 同 1 的另一种命名 |
| `R_BPF_64_ABS32` | 3 | |
| `R_BPF_64_NODYLD32` | 4 | |
| `R_BPF_64_32` | 10 | call PC-relative |
| `R_SBF_SYSCALL` | 10 | Solana 特有 syscall reloc（跟 BPF_64_32 值冲突但语义不同，由上下文区分） |

### 7.4 Dynamic tags

| 名称 | 值 |
|------|---|
| `DT_NULL` | 0 |
| `DT_STRTAB` | 5 |
| `DT_SYMTAB` | 6 |
| `DT_STRSZ` | 10 |
| `DT_SYMENT` | 11 |
| `DT_REL` | 17 |
| `DT_RELSZ` | 18 |
| `DT_RELENT` | 19 |
| `DT_TEXTREL` | 22 |
| `DT_FLAGS` | 30 |
| `DT_RELCOUNT` | `0x6ffffffa` |
| `DF_TEXTREL` | 0x4 |

### 7.5 Solana-specific

| 名称 | 值 | 说明 |
|------|---|------|
| `SOLANA_IDENT` | `[0x7f,0x45,0x4c,0x46,0x02,0x01,0x01,0x00,0,0,0,0,0,0,0,0]` | ELF e_ident |
| `SOLANA_TYPE` | 3 (ET_DYN) | e_type |
| `SOLANA_MACHINE` | 247 (EM_BPF) | e_machine |
| `SOLANA_VERSION` | 1 | e_version |
| `ELF64_HEADER_SIZE` | 64 | sizeof(ElfHeader) |
| `PROGRAM_HEADER_SIZE` | 56 | sizeof(ProgramHeader) |
| `SECTION_HEADER_SIZE` | 64 | sizeof(SectionHeader) |
| `V3_BYTECODE_VADDR` | 0x100000000 | SBPF V3 text 虚拟地址 |
| `V0_STATIC_PH_COUNT` | 0 | 静态程序的 program header 数量 |
| `V0_DYNAMIC_PH_COUNT` | 3 | 动态程序的 program header 数量 |
| `V3_PH_COUNT_NO_RODATA` | 1 | V3 无 rodata |
| `V3_PH_COUNT_WITH_RODATA` | 2 | V3 有 rodata |

### 7.6 BPF 指令

| 名称 | 值 | 说明 |
|------|---|------|
| `OPCODE_LDDW` | 0x18 | `lddw` 第一字节（唯一的 16 字节指令） |
| `OPCODE_CALL` | 0x85 | `call imm` |
| `OPCODE_EXIT` | 0x95 | `exit` |
| `INSTRUCTION_SIZE` | 8 | 普通指令字节数 |
| `LDDW_SIZE` | 16 | lddw 指令字节数 |

### 7.7 Murmur3-32 魔数

| 名称 | 值 |
|------|---|
| `MURMUR3_SEED` | 0 |
| `MURMUR3_C1` | 0xcc9e2d51 |
| `MURMUR3_C2` | 0x1b873593 |
| `MURMUR3_R1` | 15 |
| `MURMUR3_R2` | 13 |
| `MURMUR3_M` | 5 |
| `MURMUR3_N` | 0xe6546b64 |
| `MURMUR3_F1` | 0x85ebca6b |
| `MURMUR3_F2` | 0xc2b2ae35 |

---

## 8. 边界条件（至少 12 个）

每个边界**必须**在测试规格里对应一个测试 case。

| # | 场景 | 预期行为 | 对应 ParseError |
|---|------|---------|----------------|
| 1 | 输入字节 < 64（小于 ELF header） | 拒绝 | InvalidElf |
| 2 | `e_machine != 247` | 拒绝 | UnsupportedMachine |
| 3 | `e_ident[0..4] != "\x7fELF"` | 拒绝 | InvalidElf |
| 4 | ELF 是大端（`EI_DATA != 1`） | 拒绝 | UnsupportedEndian |
| 5 | ELF 是 32-bit（`EI_CLASS != 2`） | 拒绝 | UnsupportedClass |
| 6 | 空 `.text`（section 存在但 size=0） | 产出最小 .so（只有 exit？—— 实际 zignocchio noop 就是） | ok |
| 7 | 多个 `.text` section（`.text.A` + `.text.B`） | 合并到一个 CodeSection，offset 累加 | ok |
| 8 | `.rodata.str1.1` 只有 STT_SECTION 符号 + 1 个 lddw 指 offset 0 | gap-fill 产 1 个 anon 条目 | ok |
| 9 | `.rodata.str1.1` 多 lddw 指不同 offset（counter 案例） | gap-fill 产多个 anon 条目 | ok |
| 10 | lddw target 落在命名符号内部（e.address < t < e.address + e.size） | 返回错 | LddwTargetInsideNamedEntry |
| 11 | lddw target addend ≥ ro_section.size | 返回错 | RodataSectionOverflow |
| 12 | 未知 opcode（BPF 扩展里没有的字节） | 返回错 | InstructionDecodeFailed |
| 13 | `.text` 字节数不是 8 的倍数 | 返回错（倒数第二条指令如果是 lddw，剩 8 字节不够） | TextSectionMisaligned |
| 14 | jump label 未定义 | 返回错 | UndefinedLabel |
| 15 | call syscall 但名字在 murmur 表里不存在 | 接受（murmur hash 是 fallback，任何名字都能算） | ok（不检查白名单）|
| 16 | `.text` 包含 JMP32 指令（opcode 0x16 等） | **返回错**（C1 不支持 V4 扩展） | InstructionDecodeFailed |
| 17 | 输入 ELF 没有 `.rodata` section | 合法（noop 例子就是） | ok |
| 18 | 输入 ELF 有 `.debug_*` section | C1 阶段原样保留，写入输出 | ok |

**每个 case** 在 Phase 5 测试规格里都有对应 `test "case N"` 骨架。

---

## 9. 非目标（本 spec 不覆盖）

**刻意留给**后续 phase 或 out-of-scope：

- `SbpfArch::V3` 的 emit 差异（→ D.1）
- Debug section 的 DWARF 重定位（→ D.2，只做原样保留）
- 动态 syscall relocation 的完整 emit（→ D.3）
- 多 translation unit LTO（→ zig cc 负责，不是 elf2sbpf）
- 任何 BPF VM / 执行功能（→ 用 solana-sbpf / solana-test-validator）

---

## 10. 验收标准

本规格完成且可开工 Phase 4 / Phase 6 的条件：

- [x] 公共接口定义（Section 1）
- [x] 核心数据结构（Section 2），每个类型有字段 + 方法签名 + 到
      Rust 源的引用
- [x] 内存管理策略（Section 3）
- [x] 错误处理模型（Section 4）
- [x] 状态机（Section 5）
- [x] 核心算法规格（Section 6），尤其是改进版 gap-fill（这是 Zig
      版新算法，不是 port）
- [x] 常量表集中在 Section 7
- [x] 至少 12 个边界条件（Section 8 有 18 个）
- [x] 非目标明确列出（Section 9）

本规格签收后，**代码必须与规格一致**。代码发现规格错误时，**先改
规格再改代码**。
