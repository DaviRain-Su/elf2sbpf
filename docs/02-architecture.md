# 02 — 架构设计

**Phase**：2 — Architecture
**依赖**：`PRD.md`（Phase 1）
**下一步**：`03-technical-spec.md`（Phase 3）

---

## 1. 架构目标

elf2sbpf 的架构**必须**同时满足：

1. **零 LLVM 依赖**：elf2sbpf 本身不链接 libLLVM，不引 LLVM FFI
2. **语言无关的输入面**：输入是标准 BPF ELF，不绑定具体上游编译器
3. **与 Rust `sbpf-linker` 的 stage 2 字节级等价**：对合法输入，
   产物跟 `reference-shim` 按字节一致（3 个 zignocchio example
   保证；其余 6 个结构等价即可）
4. **Zig 0.16 单个二进制**：静态编译、跨 macOS/Linux 可运行

这 4 条是**架构的硬约束**，技术规格里的所有决策必须不违反这些约束。

---

## 2. 整体管道（外部视角）

```
┌──────────────────────────────────────────────────────┐
│ 随 Zig 0.16 发行版一起安装                              │
│                                                      │
│   Zig 源码                                           │
│     │                                                │
│     │  zig build-lib -target bpfel-freestanding      │
│     │    -mcpu=v2 -O ReleaseSmall                    │
│     │    -femit-llvm-bc=out.bc -fno-emit-bin         │
│     ▼                                                │
│   out.bc（LLVM bitcode）                             │
│     │                                                │
│     │  zig cc -target bpfel-freestanding             │
│     │    -mcpu=v2 -O2                                │
│     │    -mllvm -bpf-stack-size=4096                 │
│     │    -c out.bc -o out.o                          │
│     ▼                                                │
│   out.o（BPF ELF）                                   │
│                                                      │
└──────────────────────────────────────────────────────┘
              │
              │（从这里离开 Zig 自带工具链）
              ▼
┌──────────────────────────────────────────────────────┐
│  elf2sbpf（本项目）                                   │
│                                                      │
│    out.o  ──→  [ 读 ELF ]                            │
│                    │                                 │
│                    ▼                                 │
│                [ byteparser ]                        │
│                    │                                 │
│                    ▼                                 │
│                [ AST + build_program ]               │
│                    │                                 │
│                    ▼                                 │
│                [ Program::emit_bytecode ]            │
│                    │                                 │
│                    ▼                                 │
│                out.so                                │
│                                                      │
│  零 LLVM 依赖、静态 Zig 二进制                         │
└──────────────────────────────────────────────────────┘
```

---

## 3. elf2sbpf 内部模块分层

**4 层从下到上，数据单向流动**。严禁反向依赖或跨层调用。

```
           ┌─────────────────────────────────┐
Layer 4    │  main.zig（CLI 入口）            │
  入口      │  lib.zig（库根 / re-export）     │
           └───────────────┬─────────────────┘
                           │
           ┌───────────────┴─────────────────┐
Layer 3    │  emit/  ── ELF 输出层            │
  输出      │    header.zig, section_types,   │
           │    program.zig                  │
           └───────────────┬─────────────────┘
                           │
           ┌───────────────┴─────────────────┐
Layer 2    │  ast/   ── AST 中间表示           │
  中间      │    node.zig, ast.zig             │
           │                                  │
           │  parse/ ── ELF → AST             │
           │    byteparser.zig                │
           └───────────────┬─────────────────┘
                           │
           ┌───────────────┴─────────────────┐
Layer 1    │  common/ ── 通用数据类型         │
  基础      │    number.zig, register.zig,    │
           │    opcode.zig, instruction.zig, │
           │    syscalls.zig                 │
           │                                  │
           │  elf/    ── ELF 读取封装          │
           │    reader.zig, section.zig,     │
           │    symbol.zig, reloc.zig        │
           └──────────────────────────────────┘
```

### 3.1 Layer 1 — 基础层

**两个独立子模块**，互不依赖：

- **`common/`**：对应 Rust `sbpf-common` crate。纯数据类型 +
  解码/编码。没有 I/O，没有分配复杂度，不依赖任何其他模块
- **`elf/`**：对应 Rust `object` crate 的子集。封装 `std.elf`，
  提供按需迭代的 section / symbol / relocation 接口

### 3.2 Layer 2 — 中间表示层

两个子模块，部分依赖关系：

- **`parse/byteparser.zig`**：吃 `elf/` 的输出 + `common/` 的解
  码能力，产出 `ast/` 的节点
- **`ast/`**：节点定义 + `AST` 结构 + `buildProgram` 函数

parse 依赖 ast（写入）和 elf + common（读取）。

### 3.3 Layer 3 — 输出层

- **`emit/`**：吃 `ast/` 的 `ParseResult`，产出最终的 Solana SBPF
  `.so` 字节流

### 3.4 Layer 4 — 入口层

- **`main.zig`**：CLI 参数解析 + 文件 I/O + 错误打印
- **`lib.zig`**：re-export `main()` 流程中的公共库函数，方便未来
  被其他 Zig 项目作为 library import

---

## 4. 数据流（内部视角）

```
                             ┌────────────────┐
  input.o (bytes)   ────────▶│  elf/reader    │
                             │  .parse()      │
                             └────────┬───────┘
                                      │ ElfFile
                                      ▼
                             ┌────────────────┐
                             │  elf/section   │◀─── iter sections
                             │  elf/symbol    │◀─── iter symbols
                             │  elf/reloc     │◀─── iter relocs
                             └────────┬───────┘
                                      │ Section/Symbol/Reloc handles
                                      ▼
                             ┌────────────────────────────────┐
                             │  parse/byteparser              │
                             │                                │
                             │  1. 识别 ro_sections / text    │
                             │  2. 扫符号，收集 pending_rodata │
                             │  3. 扫 reloc，收集 lddw_targets│
                             │  4. 改进 gap-fill              │
                             │  5. 构建 rodata_table          │
                             │  6. 解析 text 指令             │
                             │  7. 重写 reloc（lddw/call）    │
                             │                                │
                             │  uses: common/instruction      │
                             │        common/opcode           │
                             │        common/number           │
                             │  writes: ast/node              │
                             └────────┬───────────────────────┘
                                      │ AST
                                      ▼
                             ┌────────────────────────┐
                             │  ast/ast.buildProgram  │
                             │                        │
                             │  - label 解析          │
                             │  - syscall 注入         │
                             │  - jump 相对 offset     │
                             │  - lddw 绝对地址        │
                             │  uses: common/syscalls  │
                             │        (murmur3-32)    │
                             └────────┬───────────────┘
                                      │ ParseResult
                                      ▼
                             ┌────────────────────────┐
                             │  emit/program          │
                             │  .fromParseResult()    │
                             │                        │
                             │  - 构建 ElfHeader      │
                             │  - 构建 ProgramHeader  │
                             │  - 分配 section 位置    │
                             │  - 计算 offset/padding │
                             └────────┬───────────────┘
                                      │ Program
                                      ▼
                             ┌────────────────────────┐
                             │  emit/program          │
                             │  .emitBytecode()       │
                             │                        │
                             │  - ELF header → bytes  │
                             │  - PHs → bytes         │
                             │  - sections → bytes    │
                             │  - section hdrs → bytes│
                             └────────┬───────────────┘
                                      │ bytes
                                      ▼
                         output.so (bytes)
```

---

## 5. 关键设计决策

### 5.1 显式 allocator 传递（Zig 风格）

所有可能分配的函数签名显式接收 `std.mem.Allocator`。
**不使用**全局 allocator 或 `std.heap.page_allocator`。

```zig
pub fn parseBytecode(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !ParseResult {
    ...
}
```

**理由**：
- Zig 社区强约定
- 便于测试（`std.testing.allocator` 自动检测 leak）
- 便于用户控制内存策略

### 5.2 错误集合（error set）而非 `panic`

Rust 版 byteparser.rs 用 `panic!` 和 `assert!` 做合约检查。
Zig 版**全部**改成 error return：

```zig
pub const ParseError = error{
    InvalidElf,
    UnsupportedArch,
    InstructionDecodeFailed,
    LddwTargetOutsideRodata,
    LddwTargetInsideNamedEntry,
    UnknownSyscall,
    OutOfMemory,
};
```

**理由**：库用户可以恢复，不能因为错误输入就 abort。

### 5.3 按需迭代，不预先 collect

Rust `object` crate 用 `iter` + `.collect::<Vec<_>>()` 模式。
Zig 版**优先用迭代器**，只在必须排序/随机访问时才物化成数组。

**理由**：
- Zig iterator 组合性比 Rust 弱，避免深嵌套
- 减少中间分配
- ELF section 数通常 < 100，性能差异可忽略

### 5.4 `common/opcode.zig` 用 `enum(u8)` 显式值

Rust 版 Opcode 是 derive 的 Debug/PartialEq enum，变体和字节值分开。
Zig 版直接用 `enum(u8) { Lddw = 0x18, ... }`，**字节值就是枚举值**。

**理由**：
- 编码时直接 `@intFromEnum(opcode)` 即字节值
- 解码时 `@enumFromInt(byte)` 即枚举
- 零转换开销，代码更直白

### 5.5 ASTNode 用 tagged union

对应 Rust 的 `enum ASTNode { Instruction { .. }, Label { .. }, ... }`：

```zig
pub const ASTNode = union(enum) {
    Instruction: struct { instruction: Instruction, offset: u64 },
    Label: struct { label: Label, offset: u64 },
    ROData: struct { rodata: ROData, offset: u64 },
    GlobalDecl: struct { global_decl: GlobalDecl },
};
```

**理由**：直接对应 Rust enum 语义，`switch(node)` 穷尽匹配。

### 5.6 复用 `std.elf` 而非自己写 ELF 解析器

Zig 标准库 `std.elf` 有完整的 ELF64 结构体定义和基本验证。
**使用它而不是自己定义**。

**理由**：
- ELF64 规范稳定，没必要重复造轮子
- `std.elf.Header.read` 已经做了 magic number、endian、class 校验
- 我们只需要包装成适合 byteparser 的迭代器

**不用的部分**：`std.elf` 里的 section/symbol 工具函数少，需要自己
写一层薄的包装。

### 5.7 没有全局状态

elf2sbpf 运行时不维护全局状态（没有 init/deinit 模式、没有
singleton）。每次 `parseBytecode` 调用都是纯函数式的：输入字节
进、输出 `ParseResult` 出。

**理由**：
- 便于并发/多实例（虽然 C1 是单线程）
- 便于测试
- 便于未来作为 library 被并发 embed

### 5.8 CLI 与 lib 同构

`main.zig` 只做：

1. 解析参数
2. 读文件
3. 调 `lib.linkProgram(allocator, input_bytes)`
4. 写文件
5. 处理错误、退出码

**不在** `main.zig` 里放任何业务逻辑。

**理由**：未来可以 `@import("elf2sbpf")` 当 library 用，不改代码。

---

## 6. 依赖管理

### 6.1 运行时依赖

| 依赖 | 版本 | 理由 |
|------|------|------|
| Zig stdlib | 0.16.0 | `std.elf`, `std.mem`, `std.fs`, `std.process` |
| （无其他） | — | 零外部依赖 |

### 6.2 构建依赖

| 依赖 | 版本 | 理由 |
|------|------|------|
| Zig 编译器 | 0.16.0 | 锁定版本，CI 固定 |
| （无其他） | — | 不用 build.zig.zon 拉任何包 |

### 6.3 开发期依赖（不跟随 binary）

| 依赖 | 用途 |
|------|------|
| `reference-shim`（Rust） | 对拍 oracle |
| `zignocchio`（本地 clone） | 提供测试样本 |
| `llvm-readelf`（brew 装的） | 手工结构对比 |
| `solana-test-validator` | C2 阶段 runtime 验证 |

**这些都不是 elf2sbpf 的依赖**——它们是**开发时测试用的**。
最终二进制不关心这些。

---

## 7. 部署与分发

### 7.1 binary 形态

静态链接的 Zig 二进制。可执行文件本身包含所有必需的代码。

### 7.2 跨平台

| 平台 | 支持 | 说明 |
|------|------|------|
| macOS arm64 | C1 ✅ | 主开发环境 |
| macOS x86_64 | C1 ✅ | Zig cross-compile 支持 |
| Linux x86_64 | C1 ✅ | CI 验证 |
| Linux arm64 | C1 ✅ | 同上 |
| Windows | D.5 | 推迟 |

Zig 本身支持跨平台编译，所以**只要源码不依赖平台 API**，一次构建
多平台产物是 Zig 的标准能力。

### 7.3 发布渠道

**C1 完成时**：GitHub Releases 上传 pre-built 二进制 + 源码 tarball。

**C2 完成后可选**：考虑发到 Zig package index（如果时机成熟）。

---

## 8. 性能与资源预算

### 8.1 时间预算

- 单个 zignocchio example 处理时间：**< 100ms**（shim 是 ~10ms，
  Zig 版不要求一样快但同数量级）
- 全套 9 个 example 对拍：**< 10 秒**

### 8.2 内存预算

- 单次 `parseBytecode` 调用峰值内存：**< 16MB**（最大的
  token-vault example 也只有 ~20KB，留 1000 倍余量）
- 不需要流式处理（ELF 文件一次性读入内存即可）

### 8.3 二进制体积

- ReleaseSmall 编译后 `elf2sbpf` 二进制：**< 2MB**（Zig 静态
  binary 通常 1-3MB）

---

## 9. 架构验收标准

C1 实现完成后，本架构的验收标准：

- [ ] Zig 二进制不链接 libLLVM（`ldd` / `otool -L` 确认）
- [ ] 二进制体积 < 2MB（ReleaseSmall）
- [ ] 不出现跨层调用（例如 `common/` 不应 import `parse/`）
- [ ] 9/9 zignocchio example 跟 shim 产物满足：
  - 3 个小 example 字节完全一致
  - 6 个大 example 结构等价（section 数量、dynsym 一致）
- [ ] 单次处理时间 < 100ms（最大 example）
- [ ] 无 memory leak（`std.testing.allocator` 验证）

---

## 10. 与 PRD 的一致性

本架构直接来源于 PRD §6，**不新增任何约束**。

如果本文档与 PRD 有冲突，以 PRD 为准——**改 PRD 才能改架构**。
