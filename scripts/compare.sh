#!/usr/bin/env bash
# C0 comparison: baseline (.bc path) vs candidate (.o path).
#
# We don't need byte-for-byte equality here — the two paths may legitimately
# differ (different optimization runs, different relocation ordering). What
# we need is:
#   1. Both .so files exist and are valid Solana programs.
#   2. The candidate .so is structurally similar enough that a Zig port of
#      stage 2 can produce it.
#
# Usage: ./scripts/compare.sh [example_name] [out-dir]

set -euo pipefail

EXAMPLE="${1:-hello}"
OUT_DIR="${2:-fixtures/helloworld/out}"
BC_SO="${OUT_DIR}/${EXAMPLE}.bc.so"
OBJ_SO="${OUT_DIR}/${EXAMPLE}.obj.so"

# Prefer brew's LLVM on macOS (ships llvm-readelf/llvm-objdump with BPF support).
LLVM_BIN="/opt/homebrew/opt/llvm/bin"
if [ -d "${LLVM_BIN}" ]; then
  export PATH="${LLVM_BIN}:${PATH}"
fi

READELF=""
for c in llvm-readelf llvm-readobj readelf greadelf; do
  if command -v "$c" >/dev/null 2>&1; then
    READELF="$c"
    break
  fi
done
if [ -z "${READELF}" ]; then
  echo "[compare] no readelf found. Install: brew install llvm" >&2
  exit 4
fi

OBJDUMP=""
for c in llvm-objdump objdump gobjdump; do
  if command -v "$c" >/dev/null 2>&1; then
    OBJDUMP="$c"
    break
  fi
done

echo "[compare] using readelf=${READELF} objdump=${OBJDUMP:-none}"

for f in "${BC_SO}" "${OBJ_SO}"; do
  if [ ! -f "${f}" ]; then
    echo "[compare] MISSING: ${f}" >&2
    echo "[compare] Run build-bc.sh and build-obj.sh first." >&2
    exit 1
  fi
done

dump() {
  local label="$1" flag="$2" file="$3"
  echo "--- ${label} ---"
  "${READELF}" "${flag}" "${file}" 2>&1 || echo "(readelf failed)"
}

echo "=== file sizes ==="
ls -la "${BC_SO}" "${OBJ_SO}"

echo
echo "=== byte diff ==="
if cmp -s "${BC_SO}" "${OBJ_SO}"; then
  echo "identical"
else
  SZ_BC=$(stat -f%z "${BC_SO}" 2>/dev/null || stat -c%s "${BC_SO}")
  SZ_OBJ=$(stat -f%z "${OBJ_SO}" 2>/dev/null || stat -c%s "${OBJ_SO}")
  echo "differ (bc=${SZ_BC}B obj=${SZ_OBJ}B)"
fi

echo
echo "=== ELF header (-h) ==="
dump "bitcode path" -h "${BC_SO}"
dump "obj path"     -h "${OBJ_SO}"

echo
echo "=== sections (-S) ==="
dump "bitcode path" -S "${BC_SO}"
dump "obj path"     -S "${OBJ_SO}"

echo
echo "=== relocations (-r) ==="
dump "bitcode path" -r "${BC_SO}"
dump "obj path"     -r "${OBJ_SO}"

echo
echo "=== dynamic symbols (-d) ==="
dump "bitcode path" -d "${BC_SO}"
dump "obj path"     -d "${OBJ_SO}"

echo
echo "=== all symbols (-s) ==="
dump "bitcode path" -s "${BC_SO}"
dump "obj path"     -s "${OBJ_SO}"
