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
