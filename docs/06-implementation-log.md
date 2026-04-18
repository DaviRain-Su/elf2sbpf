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

---

## C1-B.5 — Instruction 类型 + 分类助手

**日期**：2026-04-18
**状态**：✅ 完成（fromBytes/toBytes 留给 B.6/B.7）

### 开工读的规格

- `03-technical-spec.md §2.1`（Instruction 结构）
- `05-test-spec.md §4.4`（Instruction 测试矩阵）
- Rust 源：
  - Instruction 结构 `instruction.rs` L21-29
  - get_size `instruction.rs` L32-37
  - is_jump `instruction.rs` L43-48
  - is_syscall `instruction.rs` L52-59
  - OperationType 分类 `opcode.rs` L16-30

### 规格修订

**决定**：Phase 3 §2.1 原本写了一个 `LabelRef { name: []const u8 }`
newtype。这次 port 发现 Rust 直接用 `String`，没有 newtype。我们对
应用 `[]const u8`——去掉一层不增加信息的抽象。

**用 `Either([]const u8, T)` 代替 `Either(LabelRef, T)`**。

### 做的事

1. **TDD：先写 10 个测试**
   - `Span` 构造
   - `Either.left` / `Either.right` 构造和字段访问
   - `getSize`：Lddw=16，其他=8
   - `isJump`：枚举全部 23 个 jump opcode（Ja + 11 条件对 Imm/Reg 各一）
   - `isJump`：Call/Callx/Exit 不算 jump（匹配 Rust OperationType）
   - `isJump`：ALU/load/store 不算 jump
   - `isSyscall`：Call + `.left(label)` → true
   - `isSyscall`：Call + `.right(resolved)` → false
   - `isSyscall`：非 Call → false

2. **写类型 + 实现**
   - `Span = struct { start: usize, end: usize }`
   - `Either(L, R)` comptime 函数，返回 `union(enum) { left, right }`
   - `Instruction` struct 全 optional 字段（opcode 必有，其他可空）
   - `INSTRUCTION_SIZE = 8` / `LDDW_SIZE = 16` 常量
   - `getSize` switch Lddw vs else
   - `isJump` 穷尽 switch 23 个 jump opcode
   - `isSyscall` 简化版：opcode == Call 且 imm 是 .left →  true
   - `fromBytes` / `toBytes` stub `@panic("not implemented yet")`

3. `lib.zig` re-export Instruction / Span / Either

### 遇到的问题

**问题**：`isSyscall` Rust 版用一个全局 `REGISTERED_SYSCALLS` 白名单
来区分"本地函数 call" vs "syscall call"。我们还没 port syscalls.zig
（B.9）。

**暂时的处理**：简化为"所有 `Call` + `.left` label = syscall 候选"。
加了一个 TODO 注释等 B.9 完成后切到真正的白名单。

**对 C1 MVP 的影响评估**：byteparser 只在处理 Call relocation 的
path 上调 isSyscall，此时 imm 刚被 relocation 处理器设成 `.left(name)`。
对 zignocchio 的例子，所有这类 name 都是 Solana syscall（因为
byteparser 不处理用户定义的 local function call 到 lddw 的 path）。
**短期不会错**，长期要换白名单。

### 规格修订（已改）

- [x] Phase 3 §2.1：用 `[]const u8` 代替 `LabelRef`（Instruction 字段）
- [x] `C1-tasks.md` §B.5：加 Either 到任务描述、加 `isJump` / `isSyscall` 到验收

### 验收

- [x] 10/10 Instruction 测试全绿
- [x] `zig build test --summary all`：**30/30** 全绿（累计）
- [x] 代码跟 Phase 3 §2.1 修订版一致

### 下一任务

**B.6** `common/instruction.zig::fromBytes` — BPF 指令**解码**，
吃 8 或 16 字节，产 `Instruction`。这是 byteparser 的基石，要非常准。

---

## C1-B.6 — `Instruction.fromBytes` 解码

**日期**：2026-04-18
**状态**：✅ 完成

### 开工读的规格

- `03-technical-spec.md §2.1`（Instruction fromBytes 签名）
- `05-test-spec.md §4.4`（Instruction 测试矩阵）
- Rust 源：
  - 入口 `instruction.rs::from_bytes` L85-96
  - 13 个 decode_* 子函数 `decode.rs` L1-353
  - 分类常量表 `opcode.rs` L32-175
  - OperationType enum `opcode.rs` L16-30

### 做的事

1. **先补 opcode.zig**
   - 新增 `OperationType` enum（13 个变体）
   - 新增 `Opcode.operationType()` 方法：穷尽 switch 116 个 opcode
     归类到 13 个 class，跟 Rust 常量表一一对应（关键：Le/Be/Hor64Imm
     归入 BinaryImmediate）

2. **TDD：先写 14 个测试**，再写实现
   - 错误路径：TooShort（<8）、UnknownOpcode（0xff）、JMP32 拒绝（0x16）
   - 所有 13 种 operation class 至少一个正 case（用真实 hello.o /
     counter.o 字节）
   - Callx 归一化 case（dst=0 + imm!=0）
   - Call src 范围检查（src=2 → InvalidSrcRegister）
   - Lddw < 16 字节 → TooShort

3. **写 `fromBytes`**
   - 公共前缀：parse_bytes 解出 (opcode, dst_raw, src_raw, off_raw, imm_raw)
   - 按 `operationType()` 的 13 种 class switch
   - 每个 class 决定哪些字段 populate、哪些必须是 0
   - Lddw 特殊：额外读 bytes 12..15 取 imm_high，组合成 i64
   - Callx 特殊：SBPF 扩展的 dst-in-imm 归一化
   - 所有 "must be zero" 检查都返回 `DecodeError.FieldMustBeZero`

4. **新增 DecodeError 错误集合**
   - TooShort / UnknownOpcode / FieldMustBeZero / InvalidSrcRegister

### 遇到的问题 & 学习

**问题 1：Zig 0.16 std.mem.readInt 要求 `*const [N]u8` 而不是 slice**

初写用的是 `std.mem.readInt(u16, bytes[2..4], .little)` —— 传切片。
其实要 `bytes[2..4]` 作为 array pointer，Zig 0.16 通过 comptime 知
道切片长度正好是 2 就接受。这次正好工作。

**问题 2：Lddw imm 拼接要走 u64 中转**

```zig
const imm_u64: u64 = (@as(u64, @as(u32, @bitCast(imm_high))) << 32)
                    | @as(u32, @bitCast(imm_raw));
const imm_i64: i64 = @bitCast(imm_u64);
```

两层 bitcast：
- imm_high (i32) → @bitCast → u32 (保留符号位模式)
- 低 32 bit: @as(u32, @bitCast(imm_raw))（同样 i32 → u32 位模式）
- 拼接为 u64，再 bitcast 成 i64

直接 `(imm_high << 32) | imm_raw` 会因为 i32 符号扩展坏掉低 32 位。

### 规格符合性检查

Phase 3 §8 边界条件验证：

- [x] #12（未知 opcode）→ UnknownOpcode error
- [x] #13（`.text` 不是 8 倍数 —— 但 fromBytes 只处理单条，由
      byteparser 循环承担这个检查）
- [x] #16（JMP32 opcode 0x16 拒绝）→ UnknownOpcode（Opcode enum 里
      根本没有 0x16 → 0x1e 这些 JMP32 变体）

### 验收

- [x] 14 个 fromBytes 测试全部通过
- [x] `zig build test --summary all`：**44/44** 全绿（累计）
- [x] 真实 hello.o 的 4 种指令字节（Ldxdw, Call, Mov64Imm, Exit）
      和 counter.o 的 Mov64Reg 都通过 decode

### 下一任务

**B.7** `common/instruction.zig::toBytes` — 编码，`fromBytes` 的反
操作。要做 round-trip 测试（decode → encode → decode 字节级一致）。

---

## C1-B.7 — `Instruction.toBytes` 编码 + round-trip

**日期**：2026-04-18
**状态**：✅ 完成；同时关闭 B.8（isJump/isSyscall/getSize 已在 B.5 完成）

### 开工读的规格

- `03-technical-spec.md §2.1`（toBytes 签名 + 契约）
- B.6 implementation log（fromBytes 反过来就是这个的规格）

### 设计决策

**新错误集合 `EncodeError`**：跟 `DecodeError` 分开，因为编码阶段的错跟解码完全不同（分配/上下文错，不是输入错）。

- `BufferTooSmall` — 输出 buffer 不够 8/16 字节
- `UnresolvedLabel` — `imm` 或 `off` 还带 `.left(label)`；调用方
  忘了跑 `buildProgram` / relocation 解析
- `ImmOutOfRange` — Number 值超过 i32（非 Lddw 的 imm 只有 32 位）

**跟 Rust 实现比**：Rust 的 sbpf-assembler 里有对应的 emit_bytecode
链条，但它是直接按 AST 走的，不是对 Instruction 调一个 toBytes
方法。我们这里的 toBytes 是 Zig 独有的设计——为了让 decode 和
encode 对称，方便做 round-trip 测试。

**字节零填充**：函数开头 `@memset(out[0..need], 0)`，之后只写需
要的字段。所以"必须为零"的字段天然保持为零，不需要每个 class 显
式清零。

### 做的事

1. **写 `EncodeError` 错误集**
2. **写 3 个 LE 写 helper**：writeLeU32 / writeLeI32 / writeLeI16，
   每个都是对 `std.mem.writeInt` 的 `inline` 薄封装
3. **写 `toBytes`**：
   - 按 `operationType()` switch，13 种 class 各自 pack 字段
   - 用两个本地 extractor struct 抽取 Either 里的 .right 值，
     .left 返回 `UnresolvedLabel`
   - Lddw 分两半写：`writeLeU32(out[4..8], truncate(imm_u64))` +
     `writeLeU32(out[12..16], truncate(imm_u64 >> 32))`
4. **写测试**：
   - 5 个错误路径测试（BufferTooSmall × 2、UnresolvedLabel × 2、
     ImmOutOfRange × 1）
   - **1 个巨型 round-trip 测试**，用 16 个不同 class 的字节输入，
     decode → encode 后字节完全一致

### 遇到的问题

**问题**：Zig `@memset` 在 0.16 要求 slice 或 array，传
`out[0..need]` 正好满足。

**另一个细节**：Callx (CallRegister) 的 encode —— Rust decode 里
会把 `dst==0 && imm!=0` 的旧 SBPF 形式归一化为 `dst=imm; imm=0`。
Encode 时要反过来吗？经过读 Rust assembler 源，我发现它**只写
归一化后**的形式（dst=X; imm=0），不重建旧的 imm 编码。我们跟一致。

### 验收

- [x] 5 个 error 路径测试通过
- [x] **16 种 operation class 的 round-trip 测试通过**（每种 class
      至少 1 个真实 / 合成字节）
- [x] `zig build test --summary all`：**50/50** 全绿（累计）
- [x] 实质上把 B.8 也关闭了（原 B.8 的 3 个助手在 B.5 已完成）

### 关闭 B.8 的说明

C1-tasks 原来把 B.5（类型） / B.8（isJump/isSyscall/getSize）分成
两个任务。实际上这 3 个助手只用 Opcode 就能判，天然属于 Instruction
文件，写在一块更自然。B.5 开工时一并完成并测过，所以 B.8 只是
"标记完成"。

### Epic B 剩余任务

- **B.9** — `common/syscalls.zig` — murmur3-32（验证向量见 Phase 3 §6.1）
- **B.10** — Epic B 集成测试（先整合跑一次，再开 Epic C）

### 下一任务

**B.9** `common/syscalls.zig` — murmur3-32 哈希 + syscall 白名单。
syscall 名 → u32 哈希，hello.o `call 0x207559bd` 就是这个来的。

---

## C1-B.9 — `syscalls.zig` murmur3-32

**日期**：2026-04-18
**状态**：✅ 完成（白名单等到 byteparser 阶段再说）

### 开工读的规格

- `03-technical-spec.md §6.1` — murmur3-32 伪代码
- `03-technical-spec.md §7.7` — 常量表
- `05-test-spec.md §4.5` — 验证向量
- Rust 源：`sbpf/crates/sbpf-syscall-map/src/hash.rs`（45 行）

### 规格修订 1：Tail padding 方向

**发现**：Phase 3 §6.1 的伪代码写的是"tail: for each byte in reverse: k <<= 8; k |= byte"
这个是大端序拼字节。

**Rust 实际**：用 zero-pad 高位 + 同一个 pre_mix（从 4 字节小端读 u32）：
```rust
1 => pre_mix([buf[i * 4], 0, 0, 0]);
2 => pre_mix([buf[i * 4], buf[i * 4 + 1], 0, 0]);
3 => pre_mix([buf[i * 4], buf[i * 4 + 1], buf[i * 4 + 2], 0]);
```

**修规格**：Phase 3 §6.1 tail 部分重写，明确"高位补零 + 同 pre_mix"。

### 规格修订 2：验证向量的预期值

**发现**：Phase 5 §4.5 里 `sol_log_64_` 的预期 hash `0xbf7188f6` 是
错的。实际应该是 `0x5c2a3178`。我最初起草 Phase 5 时这个值不是实测
来的，是想当然写的。

**修规格**：
- 用 `/tmp/murmur-verify/`（调 Rust `sbpf-syscall-map` 作依赖）跑
  出真实 hash 值
- Phase 3 §6.1 / Phase 5 §4.5 都更新
- 注意还加了 `""` → `0x00000000` 作为边界 case

### 做的事

1. **常量集中在文件顶部**：C1/C2/R1/R2/M/N/F1/F2 + 一个 `preMix` inline helper

2. **TDD：先写 9 个测试**：
   - 确定性（同一输入多次调用一致）
   - 区分不同输入（abort vs sol_log_）
   - **5 个 Solana syscall 验证向量**（每个都写 expected u32）
   - 空串 → 0
   - Tail 长度 0/1/2/3 + 4 + 5 + 8（覆盖所有 tail path）

3. **写 murmur3_32**：
   - Body：每 4 字节做 preMix → XOR hash → rotl 13 → \*5 +% N
   - Tail：`[4]u8` 初始化为 0，copy 剩下 1-3 字节到前面，调 preMix → XOR hash
   - Finalization：`hash ^= len`，然后 avalanche：`hash ^= hash>>16; hash *%= F1; ...`

### 遇到的问题

**问题 1：Zig shift 要求无符号指数**

```zig
hash = std.math.rotl(u32, hash, 15);  // 15 is comptime_int, auto-coerces to u5
```

常量 `R1 = 15` 要声明成 `u5`（因为 u32 shift 的合法 shift amount 是 0-31）。

**问题 2：看错了 Zig 测试输出**

第一次跑测试失败时，我以为 Zig 给的 `1546269048` 跟 Rust 的
`0x5c2a3178` 不同。实际上 `1546269048 decimal == 0x5c2a3178 hex`，
是同一个数。Zig 报错时给的是十进制，我没换算就以为算法错。
教训：expectEqual 失败先拿 Python 把 expected/actual 都转到同一进制
再比。

### 验收

- [x] 9 个测试全部通过
- [x] `sol_log_` 真实 hello.o call 指令里的 hash `0x207559bd` 被正确产出
- [x] 其余 4 个 Solana syscall hash 跟 Rust 参考对齐
- [x] `zig build test --summary all`：**59/59** 全绿（累计）

### Epic B 状态

- B.1 Number ✅
- B.2 Register ✅
- B.3 Opcode（enum + toStr）✅
- B.4 原辅助函数（fromSize/toSize/toOperator/is32bit）→ 推迟到 D
- B.5 Instruction 类型 + 3 个 classifier ✅
- B.6 fromBytes ✅
- B.7 toBytes + round-trip ✅
- B.8 折进 B.5 ✅
- B.9 murmur3_32 ✅
- B.10 Epic B 集成 — 下一步

### 下一任务

**B.10** 是 Epic B 的收尾集成 —— 把所有 common/ 模块一起跑一遍，
确认模块间协作没问题。然后进入 **Epic C（ELF 读取层）**。

---

## C1-C.1 — `ElfFile.parse()`

**日期**：2026-04-18
**状态**：✅ 完成

### 开工读的规格

- `03-technical-spec.md §2.2`（ElfFile 结构 + parse 契约）
- `03-technical-spec.md §8`（边界 #1-5，都是 ELF header 验证）
- `05-test-spec.md §4.6`（elf reader 测试矩阵）

### 设计决策

**不用 `std.elf.Header.read`**——那是基于 `Io.Reader` 的 API，要从
流里 takeStruct。我们有内存里的字节，要**零拷贝**地 reinterpret。

**直接 `@ptrCast` + `@alignCast`**：把 `bytes.ptr` 当成
`*const Elf64_Ehdr`。因为 Elf64_Ehdr 是 extern struct（C layout、
无对齐 padding），这是安全的。

**section header table 也是零拷贝切片**：`bytes.ptr + sh_off` 指针
转 `[*]const Elf64_Shdr`，再 `[0..sh_count]` 变成切片。

### 做的事

1. 建 `src/elf/` 目录
2. **TDD：先写 6 个测试**（5 个边界错 + 1 个最小合法 header 正例）
3. 写 `ParseError` 错误集 + `ElfFile` struct + `parse()` 函数
4. `lib.zig` re-export ElfFile

### 遇到的问题

**问题 1：`elf.EI.CLASS` 不是 enum**

首写用了 `@intFromEnum(elf.EI.CLASS)`，编译器报"expected enum or
tagged union, found 'comptime_int'"。

**根因**：`std.elf.EI` 是一个 `struct { pub const CLASS = 4; ... }`
——不是 enum 而是 namespace。值本身就是 usize。

**解决**：直接用 `elf.EI.CLASS` 做数组下标，不走 `@intFromEnum`。

**问题 2：`@embedFile` 不能跨 package boundary**

想在测试里用 `@embedFile("../../fixtures/.../hello.o")` 做真实正例
测试，Zig 报错"embed of file outside package path"。

**根因**：Zig 0.16 限制了 `@embedFile` 只能读 src/ 内的东西，防止
意外打包项目外文件到 binary。

**解决**：挪走真实文件的集成测试到 `tests/integration.zig`（Epic
C.5 会建），那里用 `std.fs.cwd().readFileAlloc` 运行时加载，不受
embed 限制。reader.zig 的单测只用手工合成的合法/非法 header。

### 验收

- [x] 6 个测试全绿
  - spec §8 #1：< 64 bytes → `TooShort`
  - spec §8 #3：magic 非 ELF → `NotElf`
  - spec §8 #5：32-bit → `Not64Bit`
  - spec §8 #4：big-endian → `NotLittleEndian`
  - spec §8 #2：e_machine != EM_BPF → `NotBpf`
  - 正例：minimal ET_DYN/EM_BPF/ELFCLASS64/LE header 能 parse
- [x] `zig build test --summary all`：**65/65** 全绿

### 下一任务

**C.2** `elf/section.zig` — section 迭代器：`iterSections()` 给每
个 section 的 name / data / flags / size 等字段访问。

---

## C1-C.2 — Section 迭代器

**日期**：2026-04-18
**状态**：✅ 完成（集成测试推迟到 C.5）

### 开工读的规格

- `03-technical-spec.md §2.2`（Section 结构）
- `05-test-spec.md §4.6`（elf reader 测试矩阵）

### 做的事

1. **建 `src/elf/section.zig`**
   - `Section` struct：`index / header / name / data` + `flags/size/kind` 方法
   - `SectionIter` struct：index 自增迭代
   - `buildSection(file, idx)`：核心构造——从 shstrtab 读 name，切 data
   - `cstrAt` helper：安全读 null-terminated C 字符串（buffer 边界处理）

2. **在 `reader.zig` 加 3 个方法**
   - `iterSections()` 返回 `SectionIter`
   - `sectionByIndex(idx)` 直接返回 `Section`
   - `sectionHeaderAt(idx)` 返回 `Elf64_Shdr` by value

3. **TDD：11 个测试**
   - `cstrAt` 3 种路径（正常、越界、无终止符）
   - 3-section 合成 ELF（NULL + .text + .shstrtab）的迭代、命名、数据、flags、kind、NULL section

### 遇到的大问题：对齐 panic

**问题**：测试里 `const bytes: [276]u8 = makeThreeSectionElf();` 栈
数组不保证 8 字节对齐。`parse()` 里 `@alignCast(bytes.ptr)` 到
`*const Elf64_Ehdr`（要求 align 8）在 safe mode 触发 panic。

**根因**：Zig 的 `@alignCast` 从小对齐指针升到大对齐指针，runtime
会 assert 对齐正确。栈 `[N]u8` 只保证 align(1)，无法保证 align(8)。

**两种 fix 路线**：
1. 强制输入对齐：`parse(bytes: []align(8) const u8)`，让类型系统
   push 对齐责任给调用方。caller 需要 `var buf align(8) = ...`。
2. 内部复制：`@memcpy(std.mem.asBytes(&hdr), bytes[0..64])` 把
   header 复制到本地值。不再持有指向 bytes 的指针。

**选路线 2（更健壮）**：
- 用户 API 更自由（`[]const u8` 接任意对齐的字节）
- header 由值存储（64 字节）
- section_headers 不再持有 typed slice——改成 `sh_offset` + `sh_count`
  + `sectionHeaderAt(idx)` 方法按需 memcpy
- `Section.header` 也改成 by-value
- 成本：每访问一个 section header 多一次 64 字节 memcpy。对我们
  场景（section 数 < 20，每个读 1-2 次）可忽略

**教训**：zero-copy 是诱人的但对齐假设很脆。memcpy 的成本几乎总是
值得的。

### 集成测试推迟到 C.5

原本想在 `tests/integration.zig` 用 `std.fs.cwd().openFile(...)`
加载真实 hello.o 做集成。发现 Zig 0.16 把 `std.fs.cwd()` 迁到
`std.Io.Dir.cwd()`，而且所有文件操作都要 `Io` 上下文参数
（Writergate 的延续）。

决定：**C.2 的单测足够证明 section 逻辑正确**（合成 ELF 覆盖所有
路径）。真实 ELF 集成测试作为 C.5 专项解决，届时统一处理 Io API
迁移 + 所有 elf 层集成。

### 验收

- [x] 11 个新单测全绿
- [x] `zig build test`：**73/73** 全绿（累计）
- [x] 类型安全：任意对齐的输入字节都能 parse

### 下一任务

**C.3** `elf/symbol.zig` — symbol 迭代器。符号表读取同样有对齐问题，
用跟 C.2 一样的 "by-value + memcpy" 模式处理。

---

## C1-C.3 — Symbol 迭代器

**日期**：2026-04-18
**状态**：✅ 完成

### 做的事

1. **新增 `src/elf/symbol.zig`**（~260 行）
   - `Symbol` struct（index / raw Elf64_Sym by-value / name 切片）
   - `SymbolKind` 7-variant enum + Unknown fallback
   - `SymbolBinding` 3-variant enum + Unknown fallback
   - `SymTableKind` { symtab, dynsym } —— 选表
   - `SymbolIter` 按 index 自增，每次 memcpy 24 字节 Elf64_Sym
   - `makeIter(file, kind)` 定位表：扫 section，匹配 SHT_SYMTAB/SHT_DYNSYM，
     sh_link 找关联 strtab，验证 entsize + 边界

2. **ElfFile 加一个方法 `iterSymbols(kind)`**

3. **TDD：3 个测试**
   - 正例：4-section 合成 ELF（NULL + .symtab + .strtab + .shstrtab）
     带 3 个 symbol，完整解码 kind/binding/sectionIndex/address/size/name
   - 无符号表：minimal ELF → `NoSymbolTable`
   - 错类型请求：.symtab-only ELF 请求 `.dynsym` → `NoSymbolTable`

### 遇到的问题

**问题**：`elf.STB_GLOBAL` 在 Zig 0.16 被声明成 `u2`（刚好容下 0/1/2/3），
直接 `<< 4` 会类型溢出编译失败。

**解决**：先 `@as(u8, STB_GLOBAL)` 转宽再移位：
```zig
(@as(u8, elf.STB_GLOBAL) << 4) | @as(u8, elf.STT_FUNC)
```

教训：Zig 对枚举背后的底层类型严格，不会自动扩宽用于位运算。

### 复用 C.2 的 by-value 模式

符号迭代跟 section 同样的对齐隐患——Elf64_Sym 需要 8 字节对齐，输入
bytes 可能任意对齐。沿用 C.2 的处理：`@memcpy(asBytes(&sym), bytes[off..off+24])`
每 entry 一次，24 字节 memcpy 在 2026 年的硬件上约等于零。

### 验收

- [x] 3/3 Symbol 测试通过
- [x] `zig build test`：**76/76** 全绿（累计）
- [x] 所有 SymbolKind / Binding 变体正确映射

### 下一任务

**C.4** `elf/reloc.zig` — Relocation 迭代器（同样的 memcpy 模式）。
R_BPF_64_64 / R_BPF_64_32 / R_SBF_SYSCALL 等类型常量集中在 spec §7.3。

---

## C1-C.4 — Relocation 迭代器

**日期**：2026-04-18
**状态**：✅ 完成

### 做的事

1. **新增 `src/elf/reloc.zig`**（~220 行）
   - `Reloc` struct: index / offset / type_raw / symbol_index / addend(?)
   - `RelocType` **non-exhaustive** enum：`_` 分支处理 Solana 特有或未来的 type
   - `RelocIter`：同时支持 SHT_REL（16B/entry）和 SHT_RELA（24B/entry）
   - 按需 memcpy 成 `Elf64_Rel` 或 `Elf64_Rela`，走 `r_type()` 和 `r_sym()` 方法
     （这俩方法从 r_info u64 里抽出 low 32 / high 32）

2. **ElfFile 加 `iterRelocations(rel_section)`**
   - 接受 `Section`，而不是索引或名字——调用方要么遍历时筛，要么按 sh_info 找
   - 为啥不是名字？byteparser 会这样用：遍历每个 text section 后，再找对应 `.rel.<name>`，直接通过 Section 更灵活

3. **TDD：3 个测试**
   - 正例：4-section 合成 ELF，`.rel.text` 带 2 条 entry（BPF_64_64 @0x10 / BPF_64_32 @0x20）
   - `.text`（SHT_PROGBITS）请求 reloc → NotARelocationSection
   - Non-exhaustive 枚举：手构 type_raw=999 能穿透 kind()

### 关键选择：non-exhaustive RelocType

```zig
pub const RelocType = enum(u32) {
    BPF_64_64 = 1,
    BPF_64_ABS64 = 2,
    BPF_64_ABS32 = 3,
    BPF_64_NODYLD32 = 4,
    BPF_64_32 = 10,
    _,  // <-- 关键
};
```

`_` 让 `@enumFromInt(999)` 合法（不 panic），`switch (kind) { ... else => ... }` 工作。
rationale：

- Solana 特有的 `R_SBF_SYSCALL`（=10，跟 BPF_64_32 撞值）语义要靠**上下文**分辨
- byteparser 要处理的 reloc 类型有限，但拒绝未知 type 不如"让它穿透、上层不认识就忽略"

byteparser 阶段（D.1-D.5）用 switch 对已知 type 分派，未知的直接 continue，
跟 Rust byteparser.rs L219 的 `_ => continue` 行为一致。

### 验收

- [x] 3/3 Reloc 测试通过
- [x] `zig build test`：**79/79** 全绿（累计）

### Epic C 还剩

C.5 是整合测试——等整个 Epic C 都做完后，用 zignocchio hello.o 真实字节
跑一轮，确认 section/symbol/reloc 三个迭代器协作正确。同时 Zig 0.16 的
`std.Io.Dir` 集成也要解决。

### 下一任务

**C.5** `tests/integration.zig`（新建）+ 解决 0.16 Io.Dir API。
单元测试已经证明逻辑正确；这一步是 smoke test 用真实 ELF 确认没有
合成 ELF 没覆盖的 corner case。

---

## C1-C.5 — 集成测试 + fixtures 管理

**日期**：2026-04-18
**状态**：✅ 完成（Epic C 全部收尾）

### 设计选择：fixtures 存放位置

`@embedFile` 只能引 src/ 内部路径，Zig 0.16 的 `std.Io.Dir` 读文件
API 对一次性测试来说太侵入。**选择**：

- 把 `fixtures/helloworld/out/hello.o` 复制到 `src/testdata/hello.o`
- 用 `@embedFile("testdata/hello.o")` 加载
- 1016 字节，deterministic（zig-cc bridge 产物），值得 commit
- `.gitignore` 加 `!src/testdata/*.o` 例外，让这些 fixture 可以 push

### 做的事

1. 复制 hello.o 到 `src/testdata/`
2. 更新 .gitignore（加 testdata 例外）
3. 新建 `src/integration_test.zig`：5 个集成 smoke test
   - parse → 验证 e_machine=BPF、e_type=ET_REL、section 数
   - 迭代 sections 验证 .text / .rodata / .rel.text 都在
   - 迭代 symtab 验证 entrypoint 是 GLOBAL FUNC
   - .rel.text 第一个 reloc 是 BPF_64_64
   - .text 7 条指令 decode（6 条 8B + 1 条 lddw 16B = 64B）
4. `lib.zig` 的 `test {}` 聚合加入 integration_test

### 规格修订

**修 1：hello.o 是 ET_REL (1)，不是 ET_DYN (3)**
`.o` 是 relocatable object。ET_DYN 是 `.so`（linked shared object）。
我第一次写测试时想当然写 3。集成测试立刻把这个错误暴露出来——**这
就是集成测试存在的价值**。

**修 2：hello.o .text 是 7 条指令 64 字节，不是 8 条 72 字节**

llvm-objdump 输出里能看到：
```
0: 79 ...  1: 15 ...  2: 18 00 00 00 ...（lddw 16B，占用 slot 2+3）
4: b7 ...  5: 85 ...  6: b7 ...  7: 95 ...
```

标签从 0 跳到 4 是因为 lddw 占 2 个 8 字节 slot。真实**指令计数
是 7**，**总字节是 64**。这也是 `.text` section header 的 sh_size
（0x40 = 64）。

两个修订都记录到 C1-tasks.md。

### 用户改动合并（symbol.zig hardening）

测试跑之前，用户或 linter 给 symbol.zig 加了两个小检查：
- `name_off >= strtab.len` → NameOutOfRange（原来是 `>`，但等号情况
  cstrAt 会返回空串——安全但返回数据不清晰，改严格）
- `sh_link > u16 max` → BadStringTable（防止 `@intCast` panic）

合理 hardening，保留。

### Epic C 验收

| 任务 | 状态 |
|------|------|
| C.1 ElfFile.parse | ✅ |
| C.2 Section iterator | ✅ |
| C.3 Symbol iterator | ✅ |
| C.4 Reloc iterator | ✅ |
| C.5 Integration | ✅ |
| **Epic C 总计** | **5/5** |

**84/84** 测试全绿（72 unit + 5 integration + 4 encode/decode round-trip
+ 3 syscall vector + 等等）。

### 下一任务

**Epic D — Byteparser**。这是 C1 的核心 Epic，把 ELF → ParseResult
转换的全部逻辑（算法见 Phase 3 §6.2 改进版 gap-fill + §6.3 指令处理）
port 成 Zig。D.1-D.9 共 9 个任务。

从 D.1 起手：识别 `ro_sections` 和 `text_section_bases`。

---

## C1-D.1 — Byteparser section scan

**日期**：2026-04-18
**状态**：✅ 完成（Epic D 起手）

### 做的事

1. 新建 `src/parse/byteparser.zig`（现 ~200 行，会随 D.2-D.9 增长到 ~500 行）
2. **SectionScan** 结构：owner-managed `ArrayList` 存 ro_sections + text_bases
3. `scanSections(allocator, file)` 主入口
4. `isRoSectionName` / `isTextSectionName` 公共 predicate（spec §6.2 引用）
5. `roSectionByIndex()` / `textBaseByIndex()` 线性查表

### 与 C.2/C.3 的 API 变更（由 linter 触发的改进）

在 D.1 过程中，代码审查 / linter 推了三处改进：

1. **`cstrAt` 提取到 `common/util.zig`**（去重：section.zig 和 symbol.zig 都用）
2. **`ElfFile.sectionHeaderAt` 改成 error-return**（原来是 assert）——更防御式，要求 caller 用 `catch`
3. **`ParseError` 加 `IndexOutOfRange`**

这些变更让 section/symbol/byteparser 层的错误传播更统一。**验收**：84 → 91 测试都过。

### Zig 0.16 ArrayList API 教训

我第一次写了 `std.ArrayList(T) = .{}`，编译失败说"missing field items/capacity"。
Linter 改成 `.init(allocator)`，编译失败说"no member named 'init'"。
最终正确：

```zig
var list: std.ArrayList(T) = .empty;          // 构造
errdefer list.deinit(allocator);              // cleanup，per-call 传 allocator
try list.append(allocator, item);             // append，per-call 传 allocator
```

**Zig 0.16 不再保存 allocator 在 ArrayList 里** —— 调用方每次操作都要传。
这跟 0.15 的 `.init(allocator)` / `.deinit()` API 不兼容。以后 C 开头的 Epic 全部用这种模式。

### 验收

- [x] 4 个单测全绿（2 个 name predicate + hello.o 分类 + index lookup）
- [x] `zig build test --summary all`：**91/91** 全绿（累计）
- [x] hello.o 正确识别 1 text + 1 rodata，total_text_size = 64

### 下一任务

**D.2** 扫 symtab，收集 `pending_rodata` —— 把命名符号（不是 STT_SECTION）
归类到它们所在的 rodata section，记下 address/size/name/bytes。这对 hello.o
没实质效果（字符串常量都是匿名）但对 counter/vault 这些多命名 rodata 的
example 关键。

---

## C1-D.2 — 收集 pending_rodata + text labels

**日期**：2026-04-18
**状态**：✅ 完成

### 做的事

1. 新增 3 个类型：
   - `RodataEntry`：name/address/size/bytes + **name_owned** flag
     （D.4 合成的 anon entry 会设 true；D.2 的命名符号设 false）
   - `TextLabel`：name + 合并后 offset（section_base + symbol.address）
   - `SymbolScan`：owner，带 deinit 释放 owned names
2. `scanSymbols(allocator, file, sections)` 主入口
3. 两个错误：`EmptyNamedRodataSymbol` / `SymbolOutOfSectionRange`
4. 2 个单测：hello.o（1 entrypoint + 空 pending_rodata）+ 无 symtab（全空）

### 关键设计点：name_owned

Rust byteparser 对 name 一律 `.to_owned()`（String allocation）。Zig 我们
希望尽量 borrow ELF strtab 切片，但 D.4 的 anon entries 名字是动态
合成的（`std.fmt.allocPrint`），必须 owned。

**解决**：`RodataEntry.name_owned: bool` 字段，`SymbolScan.deinit` 根据
flag 决定是否 `allocator.free(e.name)`。这是 Rust 版没有的细节，
但 Zig 无 GC 必须显式管理。

### 验收

- [x] 2 测试全绿（+0 incidental）
- [x] `zig build test --summary all`：**93/93** 全绿
- [x] hello.o 的 symbol scan 行为跟 shim 一致（无 named rodata，
      entrypoint 在 offset 0）

### 下一任务

**D.3** 扫 text relocations 收集 `lddw_targets` —— **这是改进版 gap-fill
算法的核心**，spec §6.2 的 Pass 1。对每条 text relocation，如果目标是
ro_section 且被 relocation 的指令是 lddw（opcode 0x18），从指令的 imm
字段提取 addend，插入 `lddw_targets[target_section_idx]`。

---

## C1-D.3 — 收集 lddw_targets（改进版 gap-fill Pass 1）

**日期**：2026-04-18
**状态**：✅ 完成

### 做的事

1. `LddwTargets` 数据结构
   - 按 section_idx 分桶，每桶是排序去重的 `ArrayList(u64)`
   - `insert` 用二分找位置 + 检查重复后插入
   - 用 ArrayList 不用 HashMap：bucket 数（rodata sections）通常 1-3 个，
     线性扫描更 cache-friendly

2. `collectLddwTargets(allocator, file, sections)` 主入口
   - 遍历所有 SHT_REL/SHT_RELA section
   - 通过 `sh_info` 定位它们 relocate 的是哪个 section（必须是 text）
   - 对每 reloc entry：
     - 从 symtab 查 target symbol（by index）
     - 确认 target symbol 的 section 是 ro_section
     - 读 text[offset] 确认是 lddw（opcode 0x18）
     - 从 `text[offset+4..offset+8]` 读 LE u32 作为 addend
     - insert 到 `targets[sym_sec]`

### 关键细节：addend 从指令 imm 字段取，不是 r_addend

SHT_REL 没有 r_addend（r_info + r_offset 两个字段）。BPF ABI 规定
R_BPF_64_64 的 addend 隐式编码在 lddw 指令的 imm 字段里——这是
byteparser.rs 的关键知识点，D.3 必须搬过来。

对应 Rust byteparser.rs L231-234：
```rust
let addend = match node.imm {
    Some(Either::Right(Number::Int(val))) => val,
    _ => 0,
};
```
但 Rust 版是在**已经 decode 过指令**之后从 Instruction.imm 取。我
们这里直接读原始字节 4..8，因为 D.3 发生在 decode 之前——逻辑等价，
实现更直。

### 验收

- [x] 2 测试全绿
- [x] `zig build test --summary all`：**95/95** 全绿（累计）
- [x] hello.o 真数据：1 个 lddw addend = 0，符合预期（只有一个字符串常量）

### 下一任务

**D.4** 改进版 gap-fill（spec §6.2 Pass 2+3）—— Epic D 最核心的一步。
用 D.2 的 pending_rodata + D.3 的 lddw_targets，按 anchor 集合切分
每个 ro_section，合成命名的 anon entries 填满所有 gap。

---

## C1-D.4 — 改进版 rodata gap-fill

**日期**：2026-04-18
**状态**：✅ 完成

### 做的事

1. 主函数 `gapFillRodata(allocator, sections, targets, syms)`
   - **写入**：扩展 `syms.pending_rodata`，不返回新结构
   - 对每个 ro_section 独立处理：
     1. 从 pending_rodata 过滤出本 section 的命名 entries，按 address 排序
     2. 构造 anchor 集合：`{0, size} ∪ 命名 start/end ∪ lddw_targets`
     3. 排序 + 去重
     4. Sanity check：lddw target 不能 strictly inside 命名 entry → 否则 `LddwTargetInsideNamedEntry`
     5. 对每对相邻 anchor `[start, end)`，如果该 start 未被命名 entry 覆盖，就合成 anon entry
   - 合成名字：`.rodata.__anon_<sec_idx_hex>_<start_hex>`
   - 最后 `pending_rodata` 按 `(section_idx, address)` 全排序

2. 3 个测试：
   - hello.o 真数据：0 命名 + 1 lddw target @ 0 → 1 个 23B anon 覆盖全 section
   - 合成：0 命名 + 3 lddw targets (0/8/16) + 30B section → 3 段 anon
   - 反面：lddw target 落在命名 entry 内部 → 返回错

### Zig ArrayList 细节

`std.mem.sort` 就地排序 ArrayList.items：

```zig
std.mem.sort(RodataEntry, named.items, {}, struct {
    fn lt(_: void, a: RodataEntry, b: RodataEntry) bool {
        return a.address < b.address;
    }
}.lt);
```

内联 struct 是 Zig 0.16 标准 lambda 模式——`std.sort.asc(T)` 内建只给
基础数值类型用，struct 排序要这样写。

### "anchor 去重" 算法

因为 `std.ArrayList` 0.16 没有 `dedup`，手写了 in-place dedupe：

```zig
var unique_end: usize = 0;
{
    var idx: usize = 0;
    while (idx < anchors.items.len) : (idx += 1) {
        if (unique_end == 0 or anchors.items[idx] != anchors.items[unique_end - 1]) {
            anchors.items[unique_end] = anchors.items[idx];
            unique_end += 1;
        }
    }
}
const sorted_anchors = anchors.items[0..unique_end];
```

O(n) 单趟扫描。

### 关键改进点的验证

这是 C0-findings 里承诺要修的 byteparser.rs bug——**原版对单 STT_SECTION 符号的
rodata 只产一个 anchor=0 的 anon entry**，导致多字符串 rodata 的 lddw 查表失败。

我们的版本：对每个 lddw target 都加 anchor，切分 section，所以每个 addend
都有对应 entry。对 counter.o 这种场景就是解锁点——**D.5 rodata_table 构建完后，
就能验证 lddw→label 映射**。

### 验收

- [x] 3 测试全绿
- [x] `zig build test --summary all`：**98/98** 全绿（累计）
- [x] spec §6.2 Pass 2+3 完整实现

### Epic D 进度

- D.1 ✅ scanSections
- D.2 ✅ scanSymbols (pending_rodata + text_labels)
- D.3 ✅ collectLddwTargets
- D.4 ✅ gapFillRodata
- D.5 构建 rodata_table（下一步）
- D.6 decode text instructions
- D.7 relocation rewrite
- D.8 debug section stash
- D.9 AST.buildProgram wrapper

### 下一任务

**D.5** 构建 `rodata_table: HashMap<(section_idx, address), name>`。设 rodata_offset
起始为 0；遍历排序后的 pending_rodata，分配连续 offset；emit 成 `ASTNode::ROData`
形式（节点类型先占位，Epic E 实现）。

---

## C1-D.5 — rodata_table 构建

**日期**：2026-04-18
**状态**：✅ 完成

### 做的事

1. `RodataKey { section_index, address }` 查表 key
2. `RodataTable` 结构：3 个并行 ArrayList（keys / offsets / names）+ total_size
   - 不用 HashMap：N 通常很小（counter.o 最多 14 条），二分搜索 cache-friendly
3. `buildRodataTable(syms)` 主入口
   - 遍历 sorted pending_rodata，累加 rodata_offset
   - 每 entry 对应 (key, offset, name) 三元组入表
4. 查询 API：`find(key) → ?usize`（二分）/ `nameAt(idx)` / `offsetAt(idx)`

### 设计：为什么 3 个并行 ArrayList 而非 struct of 3-fields?

**Option A（我选的）**：`keys: ArrayList<Key>` / `offsets: ArrayList<u64>` / `names: ArrayList<[]const u8>` 三个独立 ArrayList

**Option B**：`ArrayList(struct { key, offset, name })` 一个 ArrayList

选 A 的原因：
- 二分搜索只读 `keys.items`——更 cache 连续
- `names` 单独持有，Epic E 构建 AST 时直接借切片；Epic F emit 时直接 slice 拷贝
- SoA 比 AoS 对线性查询更友好

这是 Zig 相对 Rust 的一个小优势——Rust 会 derive `PartialOrd` 让你一步到位，Zig 鼓励你想清楚 access pattern。

### 验收

- [x] 2 测试全绿
- [x] `zig build test --summary all`：**100/100** 全绿（跨过一百！）
- [x] hello.o 真数据产出 1 entry @ offset 0 size 23B
- [x] 合成 3-split 数据验证 offset 累加：0/8/16

### Epic D 进度

- D.1 ✅ scanSections
- D.2 ✅ scanSymbols
- D.3 ✅ collectLddwTargets
- D.4 ✅ gapFillRodata
- D.5 ✅ buildRodataTable
- D.6 decode text instructions（下一步）
- D.7 relocation rewrite
- D.8 debug section stash
- D.9 AST.buildProgram wrapper

### 下一任务

**D.6** 解码每个 text section 的指令流，生成 Instruction 数组，每条带
绝对 offset（section_base + 节内偏移）。用 D.1 的 text_bases + B.6 的
`Instruction.fromBytes`——这两件事 Epic B/C 已经做过，D.6 只是调用。

---

## C1-D.6 — text 指令流解码

**日期**：2026-04-18
**状态**：✅ 完成

### 做的事

1. 新增 3 个类型：
   - `DecodeTextError` —— 3 个变体（InstructionDecodeFailed / TextSectionMisaligned / OutOfMemory）
   - `DecodedInstruction { offset, instruction, source_section }` —— 带绝对 offset + 来源 section 索引（D.7 会用 source_section 反查 per-section 偏移）
   - `TextScan { instructions }` —— owner 结构

2. `decodeTextSections(allocator, sections)` 主入口：
   - 遍历每个 text_bases entry
   - 调 `Instruction.fromBytes` 解码
   - 按 `inst.getSize()` 步进（lddw 16、其他 8）
   - 记录 `base_offset + inner_offset`

3. 2 个测试：
   - hello.o 真数据：7 条指令，offset 0/8/16/32/40/48/56 全对
     （第 2 条是 lddw @ 16，占 16B，下条 @ 32 不是 24）
   - 空 text 产出空结果

### 踩两个坑

**坑 1：`i0` 是 Zig 0.16 保留的原语类型名**

写测试的时候用了 `const i0 = ...`，Zig 报 `name shadows primitive 'i0'`。
0.16 里任意 `i<N>` / `u<N>` 都会占用变量命名空间。Rename 成 `ins0` 解决。

**坑 2：Opcode 引用路径**

测试里写 `instruction_mod.Opcode.Ldxdw` 失败——`instruction.zig` 里
把 `Opcode` 作为**私有** `const` 导入，没 re-export。正确路径是直接
引 `opcode_mod.Opcode`。

**启示**：之前 re-export 惯例是"所有类型都 pub"，但 instruction.zig 把
Opcode 作为 internal 依赖没再 re-export。保持当前设计（模块只 pub
自己声明的类型），用户要 Opcode 就从 `common/opcode.zig` 直接引。

### 验收

- [x] 2 D.6 测试 + 2 linter 补的测试全绿
- [x] `zig build test --summary all`：**104/104** 全绿
- [x] hello.o 的 7 条指令 offset 完全跟 llvm-objdump 对得上

### Epic D 进度

- D.1-D.6 ✅
- D.7 relocation 重写（下一步）
- D.8 debug section
- D.9 AST.buildProgram wrapper

### 下一任务

**D.7** — 遍历所有 text relocations，重写 lddw.imm / call.imm 字段：
- lddw + rodata target → `imm = Either.left(rodata_table[key].name)`
- call + text target → `imm = Either.left(text_label_name)`
- call + rodata target（STT_SECTION）→ 通过 addend 查命名符号

这一步需要用 **D.5 rodata_table** + **D.2 text_labels**。核心算法
复杂度在：按 relocation offset 找 TextScan 里的那条 Instruction，
然后改它。

---

## C1-D.7 — relocation 重写

**日期**：2026-04-18
**状态**：✅ 完成

### 做的事

1. `RewriteError`：LddwTargetOutsideRodata / CallTargetUnresolvable / OOM
2. `findInstructionAtOffset(text_scan, offset) → ?*DecodedInstruction`
   - 线性扫（counter.o 最大 ~180 entries，可接受）
3. `rewriteRelocations(file, sections, rodata_table, text_scan, owned_names)` 主入口
   - 遍历 SHT_REL/SHT_RELA，按 sh_info 找 text target
   - 对每 reloc entry：
     - 找 target symbol
     - 按 text_base + r.offset 找 DecodedInstruction
     - 按 opcode 分 3 case：
       - **Lddw**：取 imm 当前 addend，rodata_table 查 → `.left(name)`
       - **Call STT_SECTION**：反查命名符号 (sym_sec, current_imm) → `.left` 或保留
       - **Call 非 STT_SECTION**：直接 `.left(sym.name)`
     - 其他 opcode 忽略

### 设计选择：owned_names 参数

Rust 版是 `.to_owned()` 把符号名拷贝。Zig 里这些 name 都是从 ELF
strtab 借用，生命周期跟 `file.bytes` 绑定——足够 OK，只要 ELF 不释放。
`owned_names` 参数当前没实际用途，但签名里保留——未来若 D.7 之后
还有步骤要把名字改掉或复制，调用方可以 push 进来统一 deinit。

### 端到端 smoke test

测试集成了 D.1→D.7 完整 pipeline：
```
scanSections → scanSymbols → collectLddwTargets → gapFillRodata
  → buildRodataTable → decodeTextSections → rewriteRelocations
```
对 hello.o：lddw @ offset 16 的 imm 从原 `.right(Number.Int(0))`
被改写成 `.left(".rodata.__anon_...")`——**byteparser 核心职责 100%
达成**。

### 验收

- [x] 1 端到端 D.1→D.7 测试
- [x] `zig build test --summary all`：**105/105** 全绿
- [x] hello.o 的 lddw imm 成功重写成 rodata label

### Epic D 进度

- D.1-D.7 ✅
- D.8 debug section 保留（下一步，简单）
- D.9 byteParse 主入口（把前 8 步包成一个 public 函数）

### 下一任务

**D.8** — 遍历所有 `.debug_*` section，原样保留到 `DebugSection` 列表。
这是给 Epic F 输出层（`.debug_*` 直接复制到输出 .so）用的。实现简单：
扫 section 名字过滤，存起来。

---

## C1-D.8 + D.9 — debug section + byteParse 整合入口

**日期**：2026-04-18
**状态**：✅ 完成 —— **Epic D 全部收尾**

### D.8：debug section 保留

- `DebugSectionEntry { name, data }` + `DebugScan { entries }`
- `scanDebugSections(allocator, file)` 过滤 `.debug_*` 前缀
- 零拷贝（切片 into ELF bytes）
- hello.o 用 ReleaseSmall 构建，没有 debug info，返回空列表

### D.9：byteParse 整合

- `ByteParseResult` 聚合所有 8 个 pass 的产物（+ owned_names for 未来）
- `byteParse(allocator, file)` 依次跑 D.1→D.8：
  ```
  scanSections → scanSymbols → collectLddwTargets → gapFillRodata
    → buildRodataTable → decodeTextSections → rewriteRelocations
    → scanDebugSections
  ```
- 完整 `errdefer` 链保护每个失败路径
- `ByteParseResult.deinit` 清理所有 owned 内存

### 端到端 smoke test

1 个测试验证 hello.o 走完 byteParse 后所有字段：

- `sections.text_bases.items.len == 1, total_text_size == 64`
- `sections.ro_sections.items.len == 1`
- `syms.text_labels == 1 个 "entrypoint"`, `entry_label != null`
- `syms.pending_rodata == 1 个匿名 entry，name_owned`
- `rodata_table.total_size == 23`（"Hello from Zignocchio!\0"）
- `text.instructions.len == 7`
- Lddw @ offset 16 的 imm 已重写为 `.left(".rodata.__anon_*")`
- `debug.entries == 0`

### Epic D 完整进度

| 任务 | 状态 |
|------|------|
| D.1 scanSections | ✅ |
| D.2 scanSymbols | ✅ |
| D.3 collectLddwTargets | ✅ |
| D.4 gapFillRodata | ✅ |
| D.5 buildRodataTable | ✅ |
| D.6 decodeTextSections | ✅ |
| D.7 rewriteRelocations | ✅ |
| D.8 scanDebugSections | ✅ |
| D.9 byteParse 整合 | ✅ |
| **Epic D** | **9/9 ✅** |

### 验收

- [x] 2 新测试（scanDebugSections + byteParse 端到端）
- [x] `zig build test --summary all`：**107/107** 全绿（累计）
- [x] 改进版 gap-fill 算法完整实现并验证
- [x] 相对 sbpf-linker byteparser.rs 的核心 bug fix 完成

### Epic D 的意义

这是 elf2sbpf 相对原 sbpf-linker 的**核心差异点全部 port 完成**。
具体来说：

1. **改进版 gap-fill（spec §6.2）** 已实现，并带 sanity check
2. byteparser 的 7 个 pass 每个都有 unit test + 至少 1 个真数据 case
3. byteparser 总共 ~1200 行 Zig，跟 Rust 版（302 行）相比的膨胀
   主要来自显式错误处理 + allocator 传递——Zig 惯例就是这样
4. **105/105 全绿**（包括 D.1-D.7 的步骤测试 + D.9 的端到端）

### Epic E/F/G 还要干什么

byteParse 返回的 `ByteParseResult` 是个**中间表示**。Rust 版接着会：

- **Epic E（AST.buildProgram）**：把 `ByteParseResult` 变成
  `ParseResult`——Solana SBPF V0 的 label 解析、relocation 登记、
  syscall 注入（murmur3 哈希）都在这里
- **Epic F（ELF 输出结构）**：Solana-specific header/ProgramHeader、
  各种 Section 类型（Code/Data/DynSym/DynStr/Dynamic/RelDyn）
- **Epic G（Program.emit_bytecode）**：最终的字节序列化

Epic D 的产物已经把所有**输入端信息**整理好，E/F/G 不再碰 ELF 字节。

### 下一任务

**Epic E — AST 中间表示**。第一个任务 E.1：`ASTNode` tagged union
（Label / Instruction / ROData / GlobalDecl）+ Label/ROData/GlobalDecl
子结构体。比 D 的逻辑简单——主要是类型建模工作。



















