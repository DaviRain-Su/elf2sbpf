# scripts/

辅助脚本一览：

- `build-bc.sh [example]`：走 bitcode + `sbpf-linker` 基线路径，生成 `.bc.so`
- `build-obj.sh [example]`：走 `zig cc` + `reference-shim` 路径，生成 `.o` 和 `.shim.so`
- `compare.sh [example] [out-dir]`：对比两条参考路径的 `.so` 结构
- `validate-all.sh [examples...]`：批量跑 baseline / shim / zig 三路验证，并比较 shim vs zig
- `validate-zig.sh [examples...]`：`validate-all.sh` 的兼容别名，供文档和测试规格引用
- `fuzz/gen.py --seed N --name fuzz_XXXX`：生成随机 zignocchio-风格 example（fuzz-lite 用，v0.1.0 起）
- `fuzz/run.sh [N]`：fuzz-lite 回归 harness；gen + `validate-all.sh` 的循环；基线 160/160 MATCH

## 前置依赖

- `ZIGNOCCHIO_DIR`：默认 `/Users/davirian/dev/active/zignocchio`
- `reference-shim/target/release/elf2sbpf-shim`：不存在时脚本会尝试 `cargo build --release`
- `zig-out/bin/elf2sbpf`：不存在时脚本会尝试 `zig build`
- macOS 下如果需要 `llvm-readelf` / `llvm-objdump`，优先使用 Homebrew LLVM

## 常用命令

```bash
./scripts/validate-zig.sh
./scripts/validate-zig.sh hello
./scripts/validate-all.sh hello counter
./scripts/compare.sh hello fixtures/validate-all

# fuzz-lite（改 byteparser / emit 层前推荐跑一轮）
./scripts/fuzz/run.sh 100
```
