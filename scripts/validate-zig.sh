#!/usr/bin/env bash
# Back-compat wrapper used by docs/test-spec.
#
# Usage:
#   ./scripts/validate-zig.sh
#   ./scripts/validate-zig.sh hello
#   ./scripts/validate-zig.sh hello counter

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "${SCRIPT_DIR}/validate-all.sh" "$@"
