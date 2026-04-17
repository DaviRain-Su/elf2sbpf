#!/usr/bin/env bash
# C0 candidate path — what elf2sbpf wants to enable:
#   zig -> ELF .o (directly)  -> sbpf-linker -> .so
#
# This mirrors zignocchio's build command but swaps:
#   - `zig build-lib`       -> `zig build-obj`
#   - `-femit-llvm-bc=...`  -> `-femit-bin=...`
#   - drops `-fno-emit-bin`
#
# Everything else (target, module wiring, optimization) is kept identical so
# any behavioral gap is attributable to the bitcode-vs-ELF difference alone,
# not to flag drift.
#
# Usage:
#   ZIGNOCCHIO_DIR=/path/to/zignocchio ./scripts/build-obj.sh [example_name]
# Default example: hello

set -euo pipefail

ZIGNOCCHIO_DIR="${ZIGNOCCHIO_DIR:-/Users/davirian/dev/active/zignocchio}"
EXAMPLE="${1:-hello}"

if [ ! -d "${ZIGNOCCHIO_DIR}" ]; then
  echo "[build-obj] zignocchio not found at ${ZIGNOCCHIO_DIR}" >&2
  exit 1
fi

OUT_DIR="$(pwd)/fixtures/helloworld/out"
mkdir -p "${OUT_DIR}"

OBJ="${OUT_DIR}/${EXAMPLE}.o"
SO="${OUT_DIR}/${EXAMPLE}.obj.so"

EXAMPLE_PATH="examples/${EXAMPLE}/lib.zig"
SDK_PATH="sdk/zignocchio.zig"

echo "[build-obj] zig build-obj (direct ELF emission)"
(
  cd "${ZIGNOCCHIO_DIR}"
  zig build-obj \
    -target bpfel-freestanding \
    -O ReleaseSmall \
    -femit-bin="${OBJ}" \
    --dep sdk \
    "-Mroot=${EXAMPLE_PATH}" \
    "-Msdk=${SDK_PATH}"
)

if [ ! -f "${OBJ}" ]; then
  echo "[build-obj] zig did not produce ${OBJ}" >&2
  exit 2
fi

echo "[build-obj] produced: ${OBJ}"
file "${OBJ}" || true

echo
echo "[build-obj] feeding ${OBJ} into sbpf-linker"
# macOS needs DYLD_FALLBACK_LIBRARY_PATH for aya-rustc-llvm-proxy.
if [ "$(uname)" = "Darwin" ]; then
  export DYLD_FALLBACK_LIBRARY_PATH="/opt/homebrew/opt/llvm/lib${DYLD_FALLBACK_LIBRARY_PATH:+:${DYLD_FALLBACK_LIBRARY_PATH}}"
fi
# sbpf-linker's CLI drives the Rust bpf-linker internally, which expects
# bitcode input. If it rejects .o, THIS is the C0-2 finding we need.
# Record whatever stderr says.
if ! sbpf-linker \
  --cpu v2 \
  --llvm-args=-bpf-stack-size=4096 \
  --export entrypoint \
  -o "${SO}" \
  "${OBJ}" 2>&1 | tee "${OUT_DIR}/${EXAMPLE}.obj.linker.log"; then
  echo "[build-obj] sbpf-linker rejected ${OBJ} — see log above" >&2
  echo "[build-obj] C0-2 finding: need alternate entry point (direct byteparser)" >&2
  exit 3
fi

echo "[build-obj] candidate ready:"
ls -la "${SO}"
