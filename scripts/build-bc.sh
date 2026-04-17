#!/usr/bin/env bash
# C0 baseline path: zig -> LLVM bitcode -> sbpf-linker -> .so
#
# We bypass zignocchio's build.zig because it hardcodes Linux-specific
# libLLVM paths. Instead we directly invoke the same `zig build-lib` and
# `sbpf-linker` commands its build.zig would run, and on macOS we set
# DYLD_FALLBACK_LIBRARY_PATH instead of LD_LIBRARY_PATH.
#
# Usage:
#   ZIGNOCCHIO_DIR=/path/to/zignocchio ./scripts/build-bc.sh [example_name]

set -euo pipefail

ZIGNOCCHIO_DIR="${ZIGNOCCHIO_DIR:-/Users/davirian/dev/active/zignocchio}"
EXAMPLE="${1:-hello}"

if [ ! -d "${ZIGNOCCHIO_DIR}" ]; then
  echo "[build-bc] zignocchio not found at ${ZIGNOCCHIO_DIR}" >&2
  exit 1
fi

OUT_DIR="$(pwd)/fixtures/helloworld/out"
mkdir -p "${OUT_DIR}"

BC="${OUT_DIR}/${EXAMPLE}.bc"
SO="${OUT_DIR}/${EXAMPLE}.bc.so"

echo "[build-bc] zig build-lib (emit bitcode)"
(
  cd "${ZIGNOCCHIO_DIR}"
  zig build-lib \
    -target bpfel-freestanding \
    -O ReleaseSmall \
    -femit-llvm-bc="${BC}" \
    -fno-emit-bin \
    --dep sdk \
    "-Mroot=examples/${EXAMPLE}/lib.zig" \
    "-Msdk=sdk/zignocchio.zig"
)

if [ ! -f "${BC}" ]; then
  echo "[build-bc] bitcode not produced at ${BC}" >&2
  exit 2
fi

echo "[build-bc] sbpf-linker (bitcode -> .so)"
# macOS needs DYLD_FALLBACK_LIBRARY_PATH pointing at a dir with libLLVM.dylib.
# Linux would use LD_LIBRARY_PATH; detect platform.
if [ "$(uname)" = "Darwin" ]; then
  export DYLD_FALLBACK_LIBRARY_PATH="/opt/homebrew/opt/llvm/lib${DYLD_FALLBACK_LIBRARY_PATH:+:${DYLD_FALLBACK_LIBRARY_PATH}}"
fi

sbpf-linker \
  --cpu v2 \
  --llvm-args=-bpf-stack-size=4096 \
  --export entrypoint \
  -o "${SO}" \
  "${BC}" 2>&1 | tee "${OUT_DIR}/${EXAMPLE}.bc.linker.log"

echo "[build-bc] baseline ready:"
ls -la "${SO}"
