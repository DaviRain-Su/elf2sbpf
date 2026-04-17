# 05 — 测试规格

**Phase**：5 — Test Spec
**依赖**：`03-technical-spec.md`（Phase 3）
**下一步**：`06-implementation-log.md`（Phase 6，实现时动态维护）

---

## 1. 测试哲学

### 1.1 Oracle 优先

elf2sbpf 的**首要 oracle 是 reference-shim 的产物**。任何模块的
输出对得上 shim 对应阶段的产物即为正确。理由：

- shim 是已经验证过的 Rust 实现（跟 Rust sbpf-linker 管道字节
  一致，见 C0-findings.md）
- 改进版 gap-fill 算法在 shim 里已经实现并跑通 6/9 example
- 字节级对拍比写"功能测试断言"更严格、更客观

### 1.2 TDD 严守

**每个任务的测试骨架必须在实现代码之前写**。顺序：

1. 读 Phase 3 对应章节
2. 写测试骨架（失败的）
3. 写实现
4. 测试转绿
5. commit

**禁止**："先写实现，看看测试要怎么写"。

### 1.3 分层测试

三层，从下到上：

```
┌─────────────────────────────────┐
│  L3: 端到端对拍（integration）   │  9/9 zignocchio example
│      输入 .o  → 输出 .so         │  对 shim 的 .so cmp
│      耗时：秒级                  │
└─────────────────────────────────┘
┌─────────────────────────────────┐
│  L2: 阶段对拍（semi-integration） │  byteparser、buildProgram、
│      输入 .o → ParseResult       │  from_parse_result 各自的
│      对 shim 中间产物比对         │  中间产物
│      耗时：毫秒级                │
└─────────────────────────────────┘
┌─────────────────────────────────┐
│  L1: 单元测试（unit）            │  每个纯函数、每个数据结构的
│      构造 → 操作 → 断言          │  编解码对称性、边界
│      耗时：微秒级                │
└─────────────────────────────────┘
```

**覆盖率分布**：L1 占 70%、L2 占 20%、L3 占 10%（个数比例；时间
占比刚好反过来，因为单元测试快但多）。

---

## 2. 测试命令

### 2.1 Zig 自带 test runner

```bash
zig build test           # 全部 L1 + L2
zig build test -Dfilter=common    # 仅 common/ 子模块
zig build test -Dfilter=parse     # 仅 parse/
zig build test -Dfilter=emit      # 仅 emit/
```

### 2.2 Integration（L3）对拍

```bash
./scripts/validate-zig.sh          # 9/9 example 全跑
./scripts/validate-zig.sh hello    # 单个 example
```

### 2.3 Memory leak

```bash
zig build test -Doptimize=Debug    # 默认 testing allocator 检漏
```

`std.testing.allocator` 在测试结束时自动 assert "no leaks"。

---

## 3. 目录结构

```
src/
├── common/
│   ├── number.zig          ← 单测在文件底部
│   ├── register.zig        ← 单测在文件底部
│   ├── opcode.zig          ← 单测在文件底部
│   ├── instruction.zig     ← 单测在文件底部
│   └── syscalls.zig        ← 单测在文件底部
├── elf/...
├── parse/...
├── ast/...
├── emit/...
└── tests/
    ├── integration.zig     ← L3 端到端
    ├── fixtures.zig        ← 辅助：加载 fixture
    └── golden/             ← shim 产物 golden file
        ├── hello.shim.so
        ├── noop.shim.so
        ├── logonly.shim.so
        ├── counter.shim.so
        ├── vault.shim.so
        ├── transfer-sol.shim.so
        ├── pda-storage.shim.so
        ├── escrow.shim.so
        └── token-vault.shim.so
```

**Zig 约定**：单元测试用 `test "name" { ... }` 块，写在同文件底部。
跨文件的集成测试放 `tests/` 目录。

---

## 4. 测试矩阵（按模块）

### 4.1 `common/number.zig`

| 测试 | 类型 | 说明 |
|------|------|------|
| `Number.Int(5).asI64()` 返回 5 | L1 | 基础访问 |
| `Number.Addr(-1).asI64()` 返回 -1 | L1 | 负数 |
| `Number.Hex(0xff).asU64()` 返回 255 | L1 | Hex 变体 |
| Round-trip：Int → asI64 → Int 相等 | L1 | |

### 4.2 `common/register.zig`

| 测试 | 类型 | 说明 |
|------|------|------|
| `Register { n: 0 }` 构造 | L1 | |
| `Register { n: 10 }` 构造 | L1 | r10 合法 |
| `Register { n: 11 }` 触发 assert | L1 | runtime 约束 |

### 4.3 `common/opcode.zig`

**关键要求**：每个 V0 opcode 都必须**往返测试**。

| 测试 | 类型 | 说明 |
|------|------|------|
| 所有 Opcode 的 `@intFromEnum` 值 匹配 LLVM BPF 规范 | L1 | 查表逐一比对 |
| 所有 Opcode 的 `toStr` 返回正确助记符 | L1 | 对照 Rust 源 |
| `fromSize("b", Load)` 返回 `Ldxb` 等 | L1 | 对称性 |
| 每个 opcode 的 `is32bit` 标志正确 | L1 | 跟 Rust 实现对照 |
| **禁用的 JMP32 opcodes**（0x16, 0x1e 等）**不在**枚举中 | L1 | SBPF V0 不支持 |

### 4.4 `common/instruction.zig`

**核心**：`fromBytes` / `toBytes` 字节级往返。

| 测试 | 类型 | 说明 |
|------|------|------|
| `fromBytes` 解析 `b7 00 00 00 00 00 00 00` = `r0 = 0` | L1 | 典型 |
| `fromBytes` 解析 `18 01 ... ...（16 字节）` = lddw | L1 | lddw 特殊长度 |
| `fromBytes` 不足 16 字节的 lddw 返回错 | L1 | 边界 |
| `fromBytes` opcode=0xff 返回错 | L1 | 未知 opcode |
| **fromBytes → toBytes → fromBytes** 对所有 V0 指令 round-trip 字节一致 | L1 | 关键 |
| `isJump` 对 jmp/jeq/jne 等返回 true | L1 | 分类正确 |
| `isSyscall` 对 `call 0` (src=0, opcode=0x85) 返回 true | L1 | Syscall 检测 |

**Golden 测试**：从 hello.o 的 `.text` 取每一条指令的 8/16 字节，
逐条 decode 并断言 opcode/dst/src/off/imm 字段正确。

### 4.5 `common/syscalls.zig`

**验证向量**（见 Phase 3 §6.1）：

| 输入 | 期望输出 |
|------|---------|
| `""` | （算出来多少就是多少，记录） |
| `"sol_log_"` | `0x207559bd` |
| `"sol_log_64_"` | `0xbf7188f6` |
| `"sol_log_pubkey"` | `0x7ef088ca` |
| `"sol_memcpy_"` | `0x717cc4a3` |
| `"sol_invoke_signed_c"` | `0xa22b9c85` |
| 1 字节输入 `"a"` | 验证 tail path |
| 2 字节输入 `"ab"` | 验证 tail path |
| 3 字节输入 `"abc"` | 验证 tail path |
| 5 字节输入 `"abcde"` | 验证 body+tail 组合 |

**失败诊断**：如果有一位不对，先查 `rotate_left` 方向和 tail 处理
顺序（MSB-first vs LSB-first）。

### 4.6 `elf/reader.zig` / `section.zig` / `symbol.zig` / `reloc.zig`

| 测试 | 类型 | 说明 |
|------|------|------|
| `ElfFile.parse(< 64 bytes)` 返回 InvalidElf | L1 | 边界 1 |
| `ElfFile.parse(bytes with e_machine=0)` 返回 UnsupportedMachine | L1 | 边界 2 |
| `ElfFile.parse(big-endian ELF)` 返回 UnsupportedEndian | L1 | 边界 4 |
| 对 hello.o 调 `iterSections()`：返回 8 个 section | L2 | 真实数据 |
| 对 hello.o 调 `iterSymbols()`：包含 `entrypoint` 符号 | L2 | |
| 对 hello.o 调 `iterRelocations(.text)`：1 个 R_BPF_64_64 | L2 | |

**Fixtures**：测试需要的 .o 文件**不是**直接从 shim 生成——而是
通过 `fixtures.zig` 调用 zignocchio 的 build 管道生成。首次运行 CI
时会构建 fixtures 目录并缓存。

### 4.7 `parse/byteparser.zig`（关键）

**这是整个项目最复杂的测试**。

#### L2 对拍测试

每个 zignocchio example 都有：

```zig
test "byteparser matches shim output for hello.o" {
    const input = @embedFile("fixtures/hello.o");
    const expected = @embedFile("fixtures/hello.parse_result.json");

    var parse_result = try parseBytecode(testing.allocator, input);
    defer parse_result.deinit();

    const actual_json = try serializeToJson(testing.allocator, parse_result);
    defer testing.allocator.free(actual_json);

    try testing.expectEqualStrings(expected, actual_json);
}
```

**需要产出**：shim 里加一个 `--dump-parse-result` flag，把
ParseResult 序列化成 JSON（跟 Zig 的 JSON 序列化兼容格式）。这是
**Phase 6 动手前**要先做的辅助工具。

#### L1 边界条件测试

Phase 3 §8 列的 18 个边界条件**每个**都要有测试：

| # | 测试名 |
|---|--------|
| 1 | `test "rejects bytes smaller than ELF header"` |
| 2 | `test "rejects e_machine != 247"` |
| 3 | `test "rejects non-ELF magic"` |
| 4 | `test "rejects big-endian ELF"` |
| 5 | `test "rejects 32-bit ELF"` |
| 6 | `test "handles empty .text section"` |
| 7 | `test "merges multiple .text sections"` |
| 8 | `test "handles STT_SECTION-only rodata with single lddw target"` |
| 9 | `test "subdivides rodata at multiple lddw targets (counter case)"` |
| 10 | `test "rejects lddw target inside named entry"` |
| 11 | `test "rejects lddw addend >= section size"` |
| 12 | `test "rejects unknown opcode"` |
| 13 | `test "rejects .text size not multiple of 8"` |
| 14 | `test "rejects undefined jump label"` |
| 15 | `test "accepts call to syscall with arbitrary name"` |
| 16 | `test "rejects JMP32 opcodes (0x16, 0x1e, ...)"` |
| 17 | `test "handles ELF without .rodata"` |
| 18 | `test "preserves .debug_* sections"` |

每个测试**独立构造最小输入**（手工 hex）而不是依赖 zignocchio
example，这样失败时定位清晰。

### 4.8 `ast/ast.zig::buildProgram`

| 测试 | 类型 | 说明 |
|------|------|------|
| 空 AST + V0 → 空 ParseResult | L1 | 平凡 |
| 单个 label `entrypoint` @offset 0 → `label_offset_map` 有 1 项 | L1 | |
| Syscall 注入（V0）：src=1, imm=-1, 加 reloc + dynamic_symbol | L1 | Phase 3 §6.3 Phase C |
| Jump label 解析：相对 offset 计算 | L1 | Phase 3 §6.3 Phase D |
| Lddw 绝对化（V0 static）：`addr = target + 64 + 56` | L1 | |
| Lddw 绝对化（V0 dynamic）：`addr = target + 64 + 3*56` | L1 | |
| **完整对 hello 的 AST → ParseResult**：跟 shim JSON 对拍 | L2 | |

### 4.9 `emit/` 全部模块

| 测试 | 类型 | 说明 |
|------|------|------|
| `ElfHeader.init()` 产出的 `bytecode()` 跟预期 16 字节 magic 一致 | L1 | |
| `ProgramHeader.bytecode()` 56 字节 | L1 | 长度检查 |
| Every SectionHeader 产出 64 字节 | L1 | |
| `CodeSection.bytecode()` 对空输入返回空 | L1 | 边界 |
| `CodeSection.bytecode()` 序列化一条 exit 指令 = `b7 00 00 00 00 00 00 00` + `95 00 00 00 00 00 00 00` | L1 | round-trip |
| `DataSection.bytecode()` 对 3-byte 字符串产出 3 字节 | L1 | |
| `DynSymSection.bytecode()` 字节顺序对照 shim | L2 | |
| **完整 emit**：对 hello 的 ParseResult → bytes，跟 shim `.so` cmp | L2 | 关键 |

### 4.10 L3 端到端（`tests/integration.zig`）

```zig
const examples = [_][]const u8{
    "hello", "noop", "logonly",
    "counter", "vault", "transfer-sol",
    "pda-storage", "escrow", "token-vault",
};

test "zig elf2sbpf matches shim output for all zignocchio examples" {
    inline for (examples) |ex| {
        const input_path = "tests/golden/" ++ ex ++ ".o";
        const expected_path = "tests/golden/" ++ ex ++ ".shim.so";

        const input = try std.fs.cwd().readFileAlloc(testing.allocator, input_path, 10 * 1024 * 1024);
        defer testing.allocator.free(input);

        const actual = try linker.linkProgram(testing.allocator, input);
        defer testing.allocator.free(actual);

        const expected = try std.fs.cwd().readFileAlloc(testing.allocator, expected_path, 10 * 1024 * 1024);
        defer testing.allocator.free(expected);

        try testing.expectEqualSlices(u8, expected, actual);
    }
}
```

**C1 MVP 验收就是这个测试全绿**。

---

## 5. Fixtures 生成

### 5.1 `tests/golden/*.o`（输入）

**生成方式**（来自 `scripts/validate-all.sh` 的现有逻辑）：

```bash
# 对每个 example：
zig build-lib -target bpfel-freestanding -mcpu=v2 -O ReleaseSmall \
  -femit-llvm-bc=<example>.bc -fno-emit-bin \
  --dep sdk -Mroot=<example>/lib.zig -Msdk=sdk/zignocchio.zig

zig cc -target bpfel-freestanding -mcpu=v2 -O2 \
  -mllvm -bpf-stack-size=4096 \
  -c <example>.bc -o <example>.o
```

**脚本**：`scripts/make-golden.sh`（Phase 6 加）自动跑上面的命令，
把 `.o` 拷到 `tests/golden/`。

### 5.2 `tests/golden/*.shim.so`（期望输出）

```bash
reference-shim/target/release/elf2sbpf-shim tests/golden/<name>.o tests/golden/<name>.shim.so
```

### 5.3 `tests/golden/*.parse_result.json`（中间产物）

**需要修改 shim**：给 `reference-shim` 加 `--dump-parse-result`
flag，序列化 ParseResult 为 JSON（format 要跟 Zig 的 JSON
serializer 兼容）。

**JSON schema**（简要）：

```json
{
  "code_section": {
    "name": ".text",
    "size": 64,
    "offset": 232,
    "nodes": [...]
  },
  "data_section": { ... },
  "dynamic_symbols": {
    "entry_points": [...],
    "call_targets": [...]
  },
  "relocation_data": {
    "entries": [...]
  },
  "prog_is_static": false,
  "arch": "V0",
  "debug_sections": []
}
```

---

## 6. CI 配置

### 6.1 本地 (`scripts/validate-zig.sh`)

```bash
set -e
zig build
zig build test -Doptimize=ReleaseSafe
./scripts/make-golden.sh     # 重建 fixtures（若缺）
./scripts/validate-all.sh    # 对拍 shim vs zig
```

### 6.2 GitHub Actions（C2 加）

- macOS arm64 + Linux x86_64 两个 runner
- 装 Zig 0.16（用 mlugg/setup-zig action）
- 装 Rust（编 reference-shim）
- 跑 `validate-zig.sh`
- PR 和 main push 都触发

---

## 7. 性能基准

### 7.1 基线

shim 的端到端 9/9 example 总时间：**~150ms**（基本都是进程启动）。

### 7.2 目标

elf2sbpf 对同样 9 个 example 总时间：**< 1 秒**（包括进程启动）。

单个 example 处理时间：**< 100ms**（最大的 token-vault 约 20KB
ELF）。

### 7.3 基准测试工具

**不需要**。`std.time.Timer` 简单测量即可，CI 里打印，无阈值
failure（C1 不要求精确基准）。

D 阶段如果需要，考虑接 [zBench](https://github.com/hendriknielaender/zBench)。

---

## 8. 调试策略

### 8.1 字节对比失败时

当 `expectEqualSlices` 报错，按顺序查：

1. **ELF header**：用 `llvm-readelf -h` 比较两个 `.so`
2. **Section 列表**：`llvm-readelf -S`
3. **Section 内容**：`dd` 提取对应字节范围 diff
4. **最常见的错误来源**：offset / padding 计算错（emit 阶段）

### 8.2 ParseResult JSON 对比失败时

用 `jq` diff 两个 JSON 文件：

```bash
diff <(jq -S . actual.json) <(jq -S . expected.json)
```

常见错误：
- `dynamic_symbols` 顺序不同（应该是 insertion order，不是排序）
- `relocation_data.entries` 的 addend 计算错
- Label 解析后的 imm 值错

### 8.3 Memory leak 失败时

Zig `std.testing.allocator` 会打印未释放的块。定位：

1. 查 stack trace
2. 最常见：`errdefer` 漏了
3. 第二常见：Arena 没包住的"持久化"分配

---

## 9. 测试命名约定

```
test "what it does (expected result)" { ... }

test "parseBytecode rejects ELF with e_machine != 247" { ... }
test "CodeSection.bytecode emits exit instruction correctly" { ... }
test "murmur3_32 matches sol_log_ hash" { ... }
```

禁止：`test "1"`、`test "hello"`、`test "test"`。

---

## 10. 验收标准

本测试规格**完整**且**可执行**的条件：

- [x] 三层测试模型（L1 / L2 / L3）清楚
- [x] 每个 Phase 3 的类型都有对应测试（Section 4）
- [x] 每个 Phase 3 的边界条件都有对应测试（§4.7）
- [x] 最终验收测试定义明确（§4.10 端到端）
- [x] Fixture 生成脚本可复现（§5）
- [x] Oracle 明确（shim 的 `.so` 和 JSON）

测试规格完成后，**写任何实现代码前**必须先写对应的测试骨架。
