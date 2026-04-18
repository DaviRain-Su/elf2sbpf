#!/usr/bin/env bash
# Fuzz-lite regression harness.
#
# Generate N random zignocchio examples, run each through the full
# shim vs. zig elf2sbpf byte-diff pipeline, and report MATCH / DIFFER / FAIL
# counts. Divergences get dumped into fixtures/fuzz-failures/<seed>/ for
# inclusion as a pinned regression golden (see C2-B.3).
#
# Usage:
#   ./scripts/fuzz/run.sh                 # default 50 iterations
#   ./scripts/fuzz/run.sh 200             # run 200
#   N=100 START=1000 ./scripts/fuzz/run.sh
#
# Env:
#   ZIGNOCCHIO_DIR  path to zignocchio (default ~/dev/active/zignocchio)
#   START           first seed                            (default 1)
#   N               iteration count (arg $1 overrides)    (default 50)
#   KEEP            "1" to keep generated example dirs    (default clean up)

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ZIGNOCCHIO_DIR="${ZIGNOCCHIO_DIR:-/Users/davirian/dev/active/zignocchio}"

START="${START:-1}"
N="${1:-${N:-50}}"
KEEP="${KEEP:-0}"

FAIL_DIR="${REPO_DIR}/fixtures/fuzz-failures"
mkdir -p "${FAIL_DIR}"

match=0
differ=0
fail=0
differ_seeds=()
fail_seeds=()

printf "fuzz-lite: seeds [%d..%d), zignocchio=%s\n" \
  "${START}" "$((START + N))" "${ZIGNOCCHIO_DIR}"

for ((i = 0; i < N; i++)); do
  seed=$((START + i))
  name=$(printf "fuzz_%04d" "${seed}")

  # Generate.
  if ! python3 "${REPO_DIR}/scripts/fuzz/gen.py" \
        --seed "${seed}" \
        --zignocchio "${ZIGNOCCHIO_DIR}" \
        --name "${name}" > /dev/null 2>&1; then
    fail=$((fail + 1))
    fail_seeds+=("${seed}")
    printf "  seed=%-6d %s gen FAIL\n" "${seed}" "${name}"
    continue
  fi

  # Run the validate table; pipe to a log file we can scrape.
  # validate-all echoes one data line per example to stdout.
  log_line=$(ZIGNOCCHIO_DIR="${ZIGNOCCHIO_DIR}" \
             "${REPO_DIR}/scripts/validate-all.sh" "${name}" 2>/dev/null \
             | awk -v n="${name}" '$1 == n')

  verdict=$(printf "%s" "${log_line}" | awk '{print $5}')

  case "${verdict}" in
    MATCH)
      match=$((match + 1))
      ;;
    DIFFER)
      differ=$((differ + 1))
      differ_seeds+=("${seed}")
      # Freeze the inputs + the two products for C2-B.3.
      dump="${FAIL_DIR}/${name}"
      mkdir -p "${dump}"
      cp "${REPO_DIR}/fixtures/validate-all/${name}.o"        "${dump}/" 2>/dev/null
      cp "${REPO_DIR}/fixtures/validate-all/${name}.shim.so"  "${dump}/" 2>/dev/null
      cp "${REPO_DIR}/fixtures/validate-all/${name}.zig.so"   "${dump}/" 2>/dev/null
      cp "${ZIGNOCCHIO_DIR}/examples/${name}/lib.zig"         "${dump}/" 2>/dev/null
      printf "  seed=%-6d %s DIFFER  (dumped to %s)\n" "${seed}" "${name}" "${dump}"
      ;;
    *)
      fail=$((fail + 1))
      fail_seeds+=("${seed}")
      printf "  seed=%-6d %s FAIL    (verdict=%s)\n" "${seed}" "${name}" "${verdict:-?}"
      ;;
  esac

  # Clean up the generated example unless KEEP=1.
  if [ "${KEEP}" != "1" ] && [ "${verdict}" = "MATCH" ]; then
    rm -rf "${ZIGNOCCHIO_DIR}/examples/${name}"
  fi
done

echo
printf "=== fuzz-lite summary ===\n"
printf "  runs:   %d\n" "${N}"
printf "  MATCH:  %d\n" "${match}"
printf "  DIFFER: %d  " "${differ}"
[ "${#differ_seeds[@]}" -gt 0 ] && printf "(seeds: %s)" "${differ_seeds[*]}"
printf "\n"
printf "  FAIL:   %d  " "${fail}"
[ "${#fail_seeds[@]}" -gt 0 ] && printf "(seeds: %s)" "${fail_seeds[*]}"
printf "\n"

# Exit non-zero if any DIFFER was found — this is the actual regression
# signal. FAIL (e.g. Zig source wouldn't compile) is noise we log but
# don't treat as a gate failure.
[ "${differ}" -eq 0 ]
