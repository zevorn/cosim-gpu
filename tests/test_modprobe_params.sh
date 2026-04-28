#!/bin/bash
# Regression test: ensure all cosim modprobe/insmod commands include the
# required parameters.  Missing ppfeaturemask/dpm/audio causes -EINVAL
# on ROCm 7.0+ (see issue #9).
#
# Scans cosim shell scripts for the AMDGPU_ARGS definition (or inline
# modprobe commands) and verifies required parameters are present.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

REQUIRED_PARAMS=(
    "ip_block_mask=0x67"
    "ppfeaturemask=0"
    "dpm=0"
    "ras_enable=0"
    "discovery=2"
)

FAILED=0
CHECKED=0

check_file() {
    local file="$1"
    # Strategy: collect all lines that define AMDGPU_ARGS or directly call
    # modprobe/insmod with inline parameters (not via a variable).
    # Merge them into one string for parameter checking.
    local param_lines=""

    # Check for AMDGPU_ARGS definition (array or string form)
    local args_def
    args_def=$(grep -E '^[[:space:]]*AMDGPU_ARGS=' "$file" 2>/dev/null || true)
    if [[ -n "$args_def" ]]; then
        param_lines="$args_def"
    fi

    # Also check for inline modprobe/insmod (params directly on the line)
    local inline
    inline=$(grep -E '(modprobe|insmod).*amdgpu.*ip_block_mask' "$file" 2>/dev/null || true)
    if [[ -n "$inline" ]]; then
        param_lines="${param_lines}${inline}"
    fi

    if [[ -z "$param_lines" ]]; then
        echo "WARN: ${file}: no AMDGPU_ARGS or inline modprobe found"
        return
    fi

    CHECKED=$((CHECKED + 1))
    for param in "${REQUIRED_PARAMS[@]}"; do
        if ! echo "$param_lines" | grep -qF "$param"; then
            echo "FAIL: ${file} missing required param '${param}'"
            FAILED=$((FAILED + 1))
            return
        fi
    done
}

COSIM_SCRIPTS=(
    "$REPO_ROOT/scripts/cosim_guest_setup.sh"
    "$REPO_ROOT/gem5-resources/src/x86-ubuntu-gpu-ml/files/cosim-gpu-setup.sh"
)

for script in "${COSIM_SCRIPTS[@]}"; do
    if [[ -f "$script" ]]; then
        check_file "$script"
    else
        echo "SKIP: ${script} not found (submodule not checked out?)"
    fi
done

echo ""
echo "Checked $CHECKED files, $FAILED failures."

if [[ $FAILED -gt 0 ]]; then
    echo "FAIL: Missing required modprobe parameters (see issue #9)."
    exit 1
fi

if [[ $CHECKED -eq 0 ]]; then
    echo "WARN: No modprobe parameter definitions found."
    exit 0
fi

echo "PASS: All cosim modprobe commands include required parameters."
