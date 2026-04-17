# 06 — 实现日志

**Phase**：6 — Implementation
**依赖**：`03-technical-spec.md`（Phase 3）、`05-test-spec.md`（Phase 5）
**维护方式**：按任务追加条目。每个任务开工时写"开工"条目，完成时写"收尾"
条目（包括遇到的问题和规格修订）。

---

## 约定

每个条目包含：

- **任务 ID**：对应 `C1-tasks.md` 的任务编号
- **日期**：ISO 8601
- **开工 / 收尾**
- **读的规格章节**（开工时列）
- **做的事**（收尾时列）
- **遇到的问题 + 解决**（如有）
- **规格修订**（如有）
- **验收通过**（勾选项对照 Phase 2/3/5）

---

## C1-A.1 — 初始化 build.zig + zon + 源码骨架

**日期**：2026-04-18
**状态**：✅ 完成

### 开工读的规格

- `02-architecture.md §3.4`（Layer 4 入口模块）
- `02-architecture.md §9`（架构验收标准）
- `03-technical-spec.md §1`（公共接口 CLI + 库）
- `03-technical-spec.md §1.3`（LinkError 全部 13 个变体）
- `05-test-spec.md §2.1, §3`（测试命令 + 文件内 test 约定）

### 做的事

1. **TDD：先写测试骨架**
   - `src/main.zig`：`test "main module scaffold compiles"`
   - `src/lib.zig`：`test "linkProgram stub returns InvalidElf (scaffold)"`
     `test "LinkError has all required variants"`

2. **写 `build.zig`**（基于 `zig init` 0.16 模板调整）
   - 模块结构：`lib_mod` (`src/lib.zig`) + `exe` (`src/main.zig`)
   - 三个 step：默认 build、`run`、`test`
   - `exe` imports `lib_mod` 使得 main.zig 能 `@import("elf2sbpf")`

3. **写 `build.zig.zon`**
   - `.name = .elf2sbpf`
   - `.version = "0.1.0-pre"`
   - `.minimum_zig_version = "0.16.0"`
   - Fingerprint 由 Zig 首次 build 时生成并接受

4. **写源码骨架**
   - `src/main.zig`：占位 main 打印版本字符串
   - `src/lib.zig`：
     - `pub const LinkError = error{...}`（13 个变体对应 spec §1.3）
     - `pub fn linkProgram(...)` 占位实现返回 `InvalidElf`
     - 两个 smoke test

### 遇到的问题

**问题 1：Fingerprint 格式**

初次写 `build.zig.zon` 时用了任意数值 `0xe1f23bbfa0517170`，Zig 拒绝：

```
build.zig.zon:1:2: error: invalid fingerprint: 0xe1f23bbfa0517170;
if this is a new or forked package, use this value: 0xd44fd21a1daffd7
```

**解决**：Zig 0.16 的 fingerprint 编码 name hash 的低 32 位，所以不能
随便填。按 Zig 提示填入 `0xd44fd21a1daffd7`。以后**禁止**手工修改
fingerprint 字段。

**问题 2：`_ = ErrorValue` 在 Zig 0.16 里不合法**

最初的"覆盖所有 LinkError 变体"测试写成 `_ = LinkError.InvalidElf;`，
Zig 0.16 报错：

```
src/lib.zig:67:18: error: error set is discarded
```

**解决**：改用 `@errorName(LinkError.InvalidElf)`——内建函数返回
`[]const u8`，把 error 值转成字符串，可以合法地收集进数组。

教训：Zig 0.16 对 error 值的 discard 检查收紧了。以后写 error-use
的测试用 `@errorName` 或者 `return someError`。

### 规格修订

无。Phase 3 §1.3 的 LinkError 变体列表跟代码一致。

### 验收

对照 `02-architecture.md §9`：

- [x] Zig 二进制不链接 libLLVM（`otool -L`：只链 `/usr/lib/libSystem.B.dylib`）
- [x] 二进制体积 < 2MB（**1.8 MB**，ReleaseSmall 还会更小）
- [x] 不出现跨层调用（当前只有 Layer 4，尚无其他层）
- [ ] 9/9 zignocchio example——需要 C1 全部完成后才能验
- [x] 无 memory leak（测试跑通，`std.testing.allocator` 未报告 leak）

对照 `C1-tasks.md` A.1 验收：

- [x] A.1：`zig build` 成功，`./zig-out/bin/elf2sbpf` 存在
- [x] A.2：目录结构创建（`src/main.zig`、`src/lib.zig`，子模块目录
      留到对应 Epic 开工时创建）
- [x] A.3：测试 harness（`zig build test` 跑通，3/3 测试过）

### 构建输出摘要

```
$ zig build
(success, no output)

$ ./zig-out/bin/elf2sbpf
elf2sbpf v0.1.0 (C1 scaffold)

$ zig build test --summary all
Build Summary: 5/5 steps succeeded; 3/3 tests passed

$ otool -L zig-out/bin/elf2sbpf
zig-out/bin/elf2sbpf:
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)

$ ls -la zig-out/bin/elf2sbpf
-rwxr-xr-x 1 davirian staff 1873144  4月 18 06:35 zig-out/bin/elf2sbpf
```

### 下一任务

**A.2** 的子目录创建（`common/` `elf/` `parse/` `ast/` `emit/`）——
推迟到对应 Epic 开工时做，避免建空目录被 git 忽略。

**B.1** `common/number.zig`——下一个实质性 Epic 的第一个任务。

---

## C1-B.1 — Number 类型

**日期**：2026-04-18
**状态**：✅ 完成

### 开工读的规格

- `03-technical-spec.md §2.1`（Number 结构）
- `05-test-spec.md §4.1`（Number 测试矩阵）
- Rust 源：`/tmp/sbpf-probe/crates/common/src/inst_param.rs` L17-37

### 规格修订（先改规格再动代码）

**发现**：Phase 3 §2.1 和 Phase 5 §4.1 写的 `Number` 有 **3 个变体**
（Int/Addr/Hex）+ `asU64()` 方法。但真实 Rust 源**只有 2 个变体**
（Int/Addr）且方法是 `to_i64()` / `to_i16()`。

**原因**：起草 Phase 3 时是凭印象写的，没对着 Rust 源查。

**处理**：**先改 Phase 3 + Phase 5 规格**，再写 Zig 实现。保证代码
和 spec 一致。

- Phase 3 §2.1 → 删除 Hex 变体，方法改名 `toI64` / `toI16`
- Phase 5 §4.1 → 测试矩阵改掉 `.Hex` / `asU64` 相关 case，
  加 toI16 截断语义测试

### 做的事

1. 建目录 `src/common/`
2. **TDD：先写测试**（7 个）：
   - `Int.toI64` 正值
   - `Addr.toI64` 负值
   - `toI16` 上界 0x7fff
   - `toI16` 截断 0x10000 → 0
   - `toI16` 负数 wrap (-1 → 0xffff → -1)
   - Round-trip
   - 变体区分（Int(5) != Addr(5)）
3. **写实现**：
   - `Number = union(enum) { Int: i64, Addr: i64 }`
   - `toI64` 用 `switch` 穷尽匹配
   - `toI16` 用 `@bitCast(@truncate(@bitCast))` 链实现 Rust `as i16`
     语义（wrap 不 clamp）
4. 在 `lib.zig` re-export + `test {}` 聚合块

### 遇到的问题

**问题**：Zig 没有 Rust 的 `as` cast 语义。`@intCast` 溢出会 panic，
`@truncate` 只能 unsigned→smaller。

**解决**：三层组合
```zig
@bitCast(@as(u16, @truncate(@as(u64, @bitCast(i64_value)))))
```
i64 → u64（bitcast） → u16（truncate） → i16（bitcast）。
跟 Rust `val as i16` 字节级一致。

### 规格修订（已改）

- [x] Phase 3 §2.1 — Number 变体从 3 个改 2 个
- [x] Phase 5 §4.1 — 测试矩阵对齐

### 验收

- [x] 7/7 Number 测试通过
- [x] `zig build test --summary all` 全绿
- [x] 代码跟 Phase 3 §2.1 一致（含规格修订）

---

## C1-B.2 — Register 类型

**日期**：2026-04-18
**状态**：✅ 完成

### 开工读的规格

- `03-technical-spec.md §2.1`（Register 结构）
- `05-test-spec.md §4.2`（Register 测试矩阵）
- Rust 源：`/tmp/sbpf-probe/crates/common/src/inst_param.rs` L7-15

### 规格修订

**发现**：Phase 3 §2.1 写 `Register.n` 是 `u4`，Rust 源是 `u8`。

**处理**：**先改 Phase 3 + Phase 5**，让它们跟 Rust 保持一致。u8
更宽松，不依赖"runtime assert" 保护（跟 Rust 一样）。

### 做的事

1. **TDD：先写测试**（4 个）：
   - `n=0` 构造
   - `n=10` 构造
   - `format` 单数字 → `r3`
   - `format` 双数字 → `r10`
2. **写实现**：
   - `Register = struct { n: u8 }`
   - `format` 方法使用 Zig 0.16 新签名
     `pub fn format(self, writer: *std.Io.Writer) std.Io.Writer.Error!void`
   - Writer 的 `print("{f}", .{x})` 识别 `format` 方法
3. `lib.zig` re-export

### 遇到的问题

**问题**：Zig 0.16 的 writer API 跟 0.15 不同（"Writergate"）。
initial try 用了 `std.io.FixedBufferStream` / `writer()` 旧链，要
改成 `std.Io.Writer.fixed(&buf)`。

**解决**：按 0.16 的签名：
```zig
var buf: [8]u8 = undefined;
var fbs = std.Io.Writer.fixed(&buf);
try fbs.print("{f}", .{reg});
const output = fbs.buffered();  // 返回已写入的切片
```

教训：Zig 0.16 的 `std.Io.Writer` 需要全局留意，未来 `emit/` 阶段
写 ELF 字节时会大量用到。在别处出现类似问题先查 writer API。

### 规格修订（已改）

- [x] Phase 3 §2.1 — Register.n u4 → u8
- [x] Phase 5 §4.2 — 测试矩阵加 format 测试；删除"触发 assert"测试
  （Rust 没这个行为）

### 验收

- [x] 4/4 Register 测试通过
- [x] `zig build test --summary all`：15/15 全绿（含前面 11 个）

### 下一任务

**B.3** `common/opcode.zig` —— Opcode enum + 辅助函数（**大任务**，
约 500 个 variant，Rust 源 1120 行）。

---

## C1-B.3 — Opcode enum + toStr

**日期**：2026-04-18
**状态**：✅ 完成（B.4 helper 函数推迟）

### 开工读的规格

- `03-technical-spec.md §2.1`（Opcode 结构 + 辅助函数列表）
- `05-test-spec.md §4.3`（Opcode 测试矩阵）
- Rust 源：
  - 枚举定义 `opcode.rs` L178-295
  - byte 映射 `opcode.rs` L382-510（TryFrom<u8>）
  - toStr `opcode.rs` L636-710
  - **这 3 个块是 C1 Opcode 的全部规格来源**

### 范围调整（C1 scope 收紧）

`C1-tasks.md` 把 Opcode 拆成 B.3（enum）+ B.4（5 个 helper 函数）。
实际评估后发现：

- `fromSize` / `toSize` / `toOperator` / `is32bit` **只给 assembler
  text parser 用**（parse `add 64 r1, r2` 这种汇编语法）
- **byteparser** 只用 `fromByte` / `toByte` 加变体 `==` 比较
- **ast/emit** 同上

结论：B.4 这些 helper **C1 MVP 不需要**，移到 D 阶段按需实现。

原估 Opcode variant 数 500 也是错的——实际 **116 个**（枚举定义
从 L179 到 L294 共 116 行）。

### 做的事

1. **TDD：先写测试**（5 个）：
   - 重点 opcode byte 值对照表（Lddw=0x18、Call=0x85、Exit=0x95 等）
   - `fromByte(0xff)` 等非法字节返回 null（**含 `fromByte(0x16)` JMP32 必拒**——C0 发现）
   - `inline for` 全部 116 个 variant 的 round-trip
   - `inline for` 全部 116 个 variant 的 `toStr` 非空
   - Key mnemonic 字面值对照（"lddw"、"call"、"exit"、"jeq"、"add64"）

2. **写实现**：
   - `enum(u8) { Lddw = 0x18, Ldxb = 0x71, ... }` 共 116 个变体
   - **按 Rust 源的功能分组顺序**（loads → stores → 32-bit ALU → 64-bit ALU → jumps → call/exit），
     便于日后跟 Rust 源做 diff
   - `fromByte` 用 `inline for` 校验字节值再 `@enumFromInt`
   - `toByte = @intFromEnum`
   - `toStr` 分组 switch，Imm/Reg 共享同一助记符（如 `.Add64Imm, .Add64Reg => "add64"`）

3. 在 `lib.zig` re-export + `test {}` 聚合

### 遇到的问题

**问题**：`std.meta.intToEnum` 在 Zig 0.16 被移除。

**原因**：0.16 的 `std.meta` 精简了 API。intToEnum 要求对 exhaustive
enum 的非法值返回 error，这个语义改用内建机制表达。

**解决**：用 inline for + `@enumFromInt`：
```zig
inline for (@typeInfo(Opcode).@"enum".fields) |f| {
    if (byte == f.value) return @enumFromInt(f.value);
}
return null;
```
编译期展开成 116-way 跳转表，runtime 成本接近零；对非法字节安全返回 null。

**教训**：Zig 0.16 对 "exhaustive enum + 非法值" 的操作更严格，
要么自己校验、要么用 non-exhaustive enum（带 `_` 成员）。C1 选前者
因为我们**想**对非法 opcode 返回错。

### 规格修订

- [x] C1-tasks.md §B.3：variant 数 500 → 116（原估过保守）
- [x] C1-tasks.md §B.4：整块推迟到 D 阶段（标注"分析 & 决定"）
- [x] Epic B 进度表：10 个任务 → 实际 9 个（B.4 移出）

### 验收

- [x] 5/5 Opcode 测试全绿（**inline for 覆盖全部 116 variant 的
      fromByte/toByte round-trip**）
- [x] **fromByte(0x16)** 返回 null 验证——JMP32 opcode 被拒绝，
      跟 `03-technical-spec.md §8` 边界条件 #16 一致
- [x] `zig build test --summary all`：20/20 全绿

### 下一任务

**B.5** `common/instruction.zig` — Instruction 结构体 + Span + Either
helper（一半声明一半构造 API）。


