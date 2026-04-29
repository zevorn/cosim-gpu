#!/bin/bash
# Standalone preflight audit script.
# Lists cosim-related resources without modifying anything.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/cosim_lib.sh"

run_preflight_audit
