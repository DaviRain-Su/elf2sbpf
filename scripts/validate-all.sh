#!/usr/bin/env bash
# Extended C0 validation: run the bit-diff test across all zignocchio examples.
#
# For each example:
#   1. Produce baseline .so via bitcode + sbpf-linker
#   2. Produce candidate .so via Zig .o + reference-shim
#   3. cmp them
#
# Outputs a summary table: example | baseline ok | shim ok | bit-identical

set -uo pipefail

ZIGNOCCHIO_DIR="${ZIGNOCCHIO_DIR:-/Users/davirian/dev/active/zignocchio}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${REPO_DIR}/fixtures/validate-all"
SHIM="${REPO_DIR}/reference-shim/target/release/elf2sbpf-shim"

if [ ! -x "${SHIM}" ]; then
  echo "[validate] building shim..." >&2
  (cd "${REPO_DIR}/reference-shim" && cargo build --release 2>&1 | tail -3)
fi

if [ "$(uname)" = "Darwin" ]; then
  export DYLD_FALLBACK_LIBRARY_PATH="/opt/homebrew/opt/llvm/lib${DYLD_FALLBACK_LIBRARY_PATH:+:${DYLD_FALLBACK_LIBRARY_PATH}}"
fi

mkdir -p "${OUT_DIR}"

EXAMPLES=(hello noop logonly counter vault transfer-sol pda-storage escrow token-vault)

printf "\n%-16s  %-10s  %-10s  %-14s  %-10s  %s\n" "example" "baseline" "shim" "bit-identical" "bc-size" "obj-size"
printf "%-16s  %-10s  %-10s  %-14s  %-10s  %s\n" "-------" "--------" "----" "-------------" "-------" "--------"

for EX in "${EXAMPLES[@]}"; do
  BC="${OUT_DIR}/${EX}.bc"
  OBJ="${OUT_DIR}/${EX}.o"
  BC_SO="${OUT_DIR}/${EX}.bc.so"
  SHIM_SO="${OUT_DIR}/${EX}.shim.so"
  LOG="${OUT_DIR}/${EX}.log"

  rm -f "${BC}" "${OBJ}" "${BC_SO}" "${SHIM_SO}"

  BASELINE_OK="-"
  SHIM_OK="-"
  BIT_MATCH="-"
  BC_SIZE="-"
  OBJ_SIZE="-"

  # --- bitcode path ---
  if (cd "${ZIGNOCCHIO_DIR}" && zig build-lib \
        -target bpfel-freestanding -O ReleaseSmall \
        -femit-llvm-bc="${BC}" -fno-emit-bin \
        --dep sdk \
        "-Mroot=examples/${EX}/lib.zig" \
        "-Msdk=sdk/zignocchio.zig") >"${LOG}" 2>&1 \
     && sbpf-linker --cpu v2 --llvm-args=-bpf-stack-size=4096 \
        --export entrypoint -o "${BC_SO}" "${BC}" >>"${LOG}" 2>&1; then
    BASELINE_OK="ok"
    BC_SIZE=$(stat -f%z "${BC_SO}" 2>/dev/null || stat -c%s "${BC_SO}")
  else
    BASELINE_OK="FAIL"
  fi

  # --- bitcode + zig cc + shim path (pure Zig toolchain) ---
  # 1. Zig emits bitcode (same as baseline's step 1)
  # 2. zig cc compiles bitcode to ELF, passing -bpf-stack-size=4096 via
  #    -mllvm so LLVM's BPF codegen respects Solana's 4KB stack budget.
  # 3. shim does stage 2 (ELF -> SBPF .so).
  # This stays fully inside Zig 0.16: no Rust, no external sbpf-linker,
  # no separate LLVM install.
  ZCC_BC="${OUT_DIR}/${EX}.zcc.bc"
  if (cd "${ZIGNOCCHIO_DIR}" && zig build-lib \
        -target bpfel-freestanding -mcpu=v2 -O ReleaseSmall \
        -femit-llvm-bc="${ZCC_BC}" -fno-emit-bin \
        --dep sdk \
        "-Mroot=examples/${EX}/lib.zig" \
        "-Msdk=sdk/zignocchio.zig") >>"${LOG}" 2>&1 \
     && zig cc -target bpfel-freestanding -mcpu=v2 -O2 \
        -mllvm -bpf-stack-size=4096 \
        -c "${ZCC_BC}" -o "${OBJ}" >>"${LOG}" 2>&1 \
     && "${SHIM}" "${OBJ}" "${SHIM_SO}" >>"${LOG}" 2>&1; then
    SHIM_OK="ok"
    OBJ_SIZE=$(stat -f%z "${SHIM_SO}" 2>/dev/null || stat -c%s "${SHIM_SO}")
  else
    SHIM_OK="FAIL"
  fi

  if [ "${BASELINE_OK}" = "ok" ] && [ "${SHIM_OK}" = "ok" ]; then
    if cmp -s "${BC_SO}" "${SHIM_SO}"; then
      BIT_MATCH="MATCH"
    else
      BIT_MATCH="DIFFER"
    fi
  fi

  printf "%-16s  %-10s  %-10s  %-14s  %-10s  %s\n" \
    "${EX}" "${BASELINE_OK}" "${SHIM_OK}" "${BIT_MATCH}" "${BC_SIZE}" "${OBJ_SIZE}"
done

echo
echo "Logs in ${OUT_DIR}/<example>.log"
