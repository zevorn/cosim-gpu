#!/bin/bash
# Host-side single-operator test runner.
# Run one operator per QEMU + gem5 session to avoid cross-test state corruption.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COSIM_DIR="$(dirname "$SCRIPT_DIR")"
TESTS_DIR="${COSIM_DIR}/tests"
KERNELS_DIR="${TESTS_DIR}/kernels"
LAUNCH_SCRIPT="${SCRIPT_DIR}/cosim_launch.sh"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/cosim_lib.sh"

SESSION_NAME="${SESSION_NAME:-qemu-cosim-tests}"
SCREEN_LOG="${SCREEN_LOG:-}"
BOOT_TIMEOUT_SECS="${BOOT_TIMEOUT_SECS:-240}"
TEST_TIMEOUT_SECS="${TEST_TIMEOUT_SECS:-60}"
KEEP_ALIVE_ON_SUCCESS=0
RUN_ALL=0
REPEAT_COUNT=0
FILTER=""
PASSTHROUGH_ARGS=()
SCREEN_LOG_SET=0
SESSION_DIR=""
SESSION_FIFO=""
LAUNCH_PID=""
CONTROL_FD=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
# shellcheck disable=SC2317,SC2329
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "${CYAN}[STEP]${NC} $*"; }

usage() {
    cat <<EOF
Host-side single-operator cosim test runner.

Usage: $0 [options] <operator-filter>

Options:
  --all                  Run all operators, one fresh cosim session each
  --repeat N             Run the same operator N times (fresh session each)
  --keep-alive           Leave QEMU + gem5 running after a successful test
  --session-name NAME    detached session name (default: qemu-cosim-tests)
  --screen-log PATH      console log path (default: /tmp/qemu-cosim-tests.log)
  --boot-timeout SECS    guest boot timeout (default: 240)
  --test-timeout SECS    per-test timeout inside guest (default: 60)
  -h, --help             Show this help

Unknown options are passed through to cosim_launch.sh.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)              RUN_ALL=1; shift ;;
        --repeat)           REPEAT_COUNT="$2"; shift 2 ;;
        --keep-alive)       KEEP_ALIVE_ON_SUCCESS=1; shift ;;
        --session-name)     SESSION_NAME="$2"; shift 2 ;;
        --screen-log)       SCREEN_LOG="$2"; SCREEN_LOG_SET=1; shift 2 ;;
        --boot-timeout)     BOOT_TIMEOUT_SECS="$2"; shift 2 ;;
        --test-timeout)     TEST_TIMEOUT_SECS="$2"; shift 2 ;;
        -h|--help)          usage ;;
        --*)                PASSTHROUGH_ARGS+=("$1" "$2"); shift 2 ;;
        *)                  FILTER="$1"; shift ;;
    esac
done

COSIM_RUN_ID="${COSIM_RUN_ID:-$(generate_run_id)}"
export COSIM_RUN_ID

if [[ "$REPEAT_COUNT" -gt 0 && "$KEEP_ALIVE_ON_SUCCESS" -eq 1 ]]; then
    error "--keep-alive and --repeat cannot be used together"
fi
if [[ "$REPEAT_COUNT" -gt 0 && "$RUN_ALL" -eq 1 ]]; then
    error "--all and --repeat cannot be used together"
fi

if [[ "$SCREEN_LOG_SET" -eq 0 ]]; then
    SCREEN_LOG="$(cosim_screen_log "$COSIM_RUN_ID" "$SESSION_NAME")"
fi
SESSION_DIR="$(cosim_session_dir "$COSIM_RUN_ID" "$SESSION_NAME")"
SESSION_FIFO="${SESSION_DIR}/console.in"

# ---- Repeat mode: run same operator N times with fresh sessions ----

if [[ "$REPEAT_COUNT" -gt 0 && "$RUN_ALL" -eq 0 ]]; then
    [[ -n "$FILTER" ]] || { echo "Usage: $0 --repeat N <operator>"; exit 1; }

    # Resolve exact operator name for artifact paths
    REPEAT_OPERATOR=""
    while IFS= read -r k; do
        k="${k%.cpp}"
        if [[ "$k" == *"$FILTER"* ]]; then
            REPEAT_OPERATOR="$k"
        fi
    done < <(find "$KERNELS_DIR" -maxdepth 1 -type f -name '*.cpp' -printf '%f\n' | sort)
    REPEAT_OPERATOR="${REPEAT_OPERATOR:-$FILTER}"

    REPEAT_PASSED=0
    REPEAT_FAILED=0
    REPEAT_INFRA_FAIL=0
    declare -a REPEAT_MATRIX=()

    # shellcheck disable=SC2317
    repeat_partial_summary() {
        echo ""
        echo "============================================================"
        echo "  Repeat-Run Partial Summary (interrupted)"
        echo "  Operator: $FILTER"
        echo "  Completed: $((REPEAT_PASSED + REPEAT_FAILED)) / $REPEAT_COUNT"
        echo "  Passed: $REPEAT_PASSED  Failed: $REPEAT_FAILED  Infra failures: $REPEAT_INFRA_FAIL"
        echo "============================================================"
        for entry in "${REPEAT_MATRIX[@]}"; do
            echo "  $entry"
        done
        echo "============================================================"
    }
    trap 'repeat_partial_summary; exit 130' INT TERM

    for ((i=1; i<=REPEAT_COUNT; i++)); do
        iter_run_id="$(generate_run_id)"
        sub_session="${SESSION_NAME}-repeat-${i}"
        iter_artifact_dir="$(cosim_artifact_dir "$COSIM_DIR" "$REPEAT_OPERATOR" "$iter_run_id")"

        step "Repeat iteration $i/$REPEAT_COUNT (run-ID: $iter_run_id)"

        iter_category_file="/tmp/cosim-category-${iter_run_id}"
        if COSIM_RUN_ID="$iter_run_id" COSIM_CATEGORY_FILE="$iter_category_file" "$0" \
            --session-name "$sub_session" \
            --boot-timeout "$BOOT_TIMEOUT_SECS" \
            --test-timeout "$TEST_TIMEOUT_SECS" \
            "${PASSTHROUGH_ARGS[@]}" \
            "$FILTER"; then
            run_rc=0
            category="$COSIM_CAT_TEST_PASS"
        else
            run_rc=$?
            category="$COSIM_CAT_INFRA_UNKNOWN"
        fi
        if [[ -f "$iter_category_file" ]]; then
            category="$(cat "$iter_category_file")"
            rm -f "$iter_category_file"
        fi

        if [[ "$run_rc" -eq 0 ]]; then
            REPEAT_PASSED=$((REPEAT_PASSED + 1))
        else
            REPEAT_FAILED=$((REPEAT_FAILED + 1))
            if is_infra_failure "$category"; then
                REPEAT_INFRA_FAIL=$((REPEAT_INFRA_FAIL + 1))
            fi
        fi
        if [[ -d "$iter_artifact_dir" ]]; then
            actual_artifact_dir="$iter_artifact_dir"
        elif [[ -d "${COSIM_DIR}/artifacts/standalone/${iter_run_id}" ]]; then
            actual_artifact_dir="${COSIM_DIR}/artifacts/standalone/${iter_run_id}"
        else
            actual_artifact_dir="(none)"
        fi
        REPEAT_MATRIX+=("$i | $iter_run_id | $category | exit=$run_rc | artifacts=${actual_artifact_dir}")
    done

    echo ""
    echo "============================================================"
    echo "  Repeat-Run Results"
    echo "  Operator: $FILTER"
    echo "  Total: $REPEAT_COUNT  Passed: $REPEAT_PASSED  Failed: $REPEAT_FAILED  Infra failures: $REPEAT_INFRA_FAIL"
    echo "============================================================"
    echo "  # | Run-ID | Category | Exit | Artifacts"
    echo "  --|--------|----------|------|----------"
    for entry in "${REPEAT_MATRIX[@]}"; do
        echo "  $entry"
    done
    echo "============================================================"

    if [[ "$REPEAT_INFRA_FAIL" -gt 0 ]]; then
        exit 1
    fi
    [[ "$REPEAT_FAILED" -eq 0 ]]
    exit $?
fi

if [[ "$RUN_ALL" -eq 1 ]]; then
    mapfile -t ALL_TESTS < <(find "$KERNELS_DIR" -maxdepth 1 -type f -name '*.cpp' -printf '%f\n' | sed 's/\.cpp$//' | sort)
    [[ ${#ALL_TESTS[@]} -gt 0 ]] || error "No operators found in ${KERNELS_DIR}"

    PASSED=0
    FAILED=0

    for test_name in "${ALL_TESTS[@]}"; do
        sub_session="${SESSION_NAME}-${test_name}"
        if COSIM_RUN_ID="$(generate_run_id)" "$0" \
            --session-name "$sub_session" \
            --boot-timeout "$BOOT_TIMEOUT_SECS" \
            --test-timeout "$TEST_TIMEOUT_SECS" \
            "${PASSTHROUGH_ARGS[@]}" \
            "$test_name"; then
            run_rc=0
        else
            run_rc=$?
        fi

        if [[ "$run_rc" -eq 0 ]]; then
            PASSED=$((PASSED + 1))
        else
            FAILED=$((FAILED + 1))
        fi
    done

    echo "============================================================"
    echo "  Fresh-session Results: ${PASSED}/${#ALL_TESTS[@]} passed, ${FAILED} failed"
    echo "============================================================"
    if [[ "$FAILED" -ne 0 ]]; then
        exit 1
    fi
    exit 0
fi

[[ -n "$FILTER" ]] || usage

cleanup_session() {
    if [[ -n "${LAUNCH_PID:-}" ]] && kill -0 "$LAUNCH_PID" 2>/dev/null; then
        kill -TERM -- "-${LAUNCH_PID}" >/dev/null 2>&1 || true
        local wait_count=0
        while kill -0 "$LAUNCH_PID" 2>/dev/null && [[ $wait_count -lt 15 ]]; do
            sleep 1
            wait_count=$((wait_count + 1))
        done
        if kill -0 "$LAUNCH_PID" 2>/dev/null; then
            kill -KILL -- "-${LAUNCH_PID}" >/dev/null 2>&1 || true
        fi
    fi
    local cname
    cname="$(cosim_container_name "${COSIM_RUN_ID:-}")"
    docker rm -f "$cname" >/dev/null 2>&1 || true
    rm -rf "$SESSION_DIR" >/dev/null 2>&1 || true
    rm -f "/tmp/cosim-launcher-category-${COSIM_RUN_ID:-}.txt" "/tmp/cosim-test-done-${COSIM_RUN_ID:-}" 2>/dev/null || true
    if [[ -n "${COSIM_RUN_ID:-}" ]]; then
        rm -f "/tmp/gem5-mi300x-${COSIM_RUN_ID}.sock" 2>/dev/null || true
        rm -f "/tmp/gem5-mi300x-${COSIM_RUN_ID}-"[0-9]*.sock 2>/dev/null || true
        rm -f "/dev/shm/mi300x-vram-${COSIM_RUN_ID}" 2>/dev/null || true
        rm -f "/dev/shm/mi300x-vram-${COSIM_RUN_ID}-"[0-9]* 2>/dev/null || true
        rm -f "/dev/shm/cosim-guest-ram-${COSIM_RUN_ID}" 2>/dev/null || true
    fi
}

session_alive() {
    [[ -n "${LAUNCH_PID:-}" ]] && kill -0 "$LAUNCH_PID" 2>/dev/null
}

send_guest() {
    local line="$1"
    printf '%s\n' "$line" >&$CONTROL_FD
}

record_category() {
    local cat="$1"
    local use_launcher="${2:-false}"
    if [[ "$use_launcher" == "true" ]]; then
        local launcher_cat_file="/tmp/cosim-launcher-category-${COSIM_RUN_ID}.txt"
        if [[ -f "$launcher_cat_file" ]]; then
            local launcher_cat
            launcher_cat="$(cat "$launcher_cat_file")"
            rm -f "$launcher_cat_file"
            if [[ -n "$launcher_cat" && "$launcher_cat" != "$COSIM_CAT_TEST_PASS" ]]; then
                cat="$launcher_cat"
            fi
        fi
    fi
    if [[ -n "${COSIM_CATEGORY_FILE:-}" ]]; then
        echo "$cat" > "$COSIM_CATEGORY_FILE"
    fi
}

# shellcheck disable=SC2317,SC2329
on_interrupt() {
    echo ""
    if [[ "$KEEP_ALIVE_ON_SUCCESS" -eq 1 ]]; then
        warn "Interrupted. Session preserved (--keep-alive)."
        warn "Launcher PID: ${LAUNCH_PID:-unknown}"
        warn "Console log: ${SCREEN_LOG}"
        warn "Cleanup: kill -TERM -- -${LAUNCH_PID:-0}; docker rm -f $(cosim_container_name "${COSIM_RUN_ID:-}")"
    else
        warn "Interrupted. Cleaning up session..."
        cleanup_session
    fi
    exit 130
}

# shellcheck disable=SC2317
on_exit() {
    local rc=$?
    if [[ $rc -ne 0 && "$KEEP_ALIVE_ON_SUCCESS" -eq 0 ]]; then
        cleanup_session
    fi
}

trap on_interrupt INT TERM
trap on_exit EXIT

match_test() {
    local matches=()
    local kernel

    while IFS= read -r kernel; do
        kernel="${kernel%.cpp}"
        if [[ "$kernel" == *"$FILTER"* ]]; then
            matches+=("$kernel")
        fi
    done < <(find "$KERNELS_DIR" -maxdepth 1 -type f -name '*.cpp' -printf '%f\n' | sort)

    if [[ ${#matches[@]} -eq 0 ]]; then
        error "No operator matched '${FILTER}'"
    fi

    if [[ ${#matches[@]} -gt 1 ]]; then
        error "Filter '${FILTER}' matched multiple operators: ${matches[*]}"
    fi

    printf '%s\n' "${matches[0]}"
}

TEST_NAME="$(match_test)"
GUEST_SCRIPT=".cosim_guest_run.${COSIM_RUN_ID}.${TEST_NAME}.sh"
GUEST_SCRIPT_HOST="${TESTS_DIR}/${GUEST_SCRIPT}"
TOKEN="COSIM_TEST_DONE_${TEST_NAME}_$(date +%s)"

rm -rf "$SESSION_DIR"
mkdir -p "$SESSION_DIR"
rm -f "$SCREEN_LOG" "$SESSION_FIFO"
mkfifo "$SESSION_FIFO"
exec {CONTROL_FD}<>"$SESSION_FIFO"

step "[${TEST_NAME}] Starting detached QEMU + gem5 session..."
setsid stdbuf -oL -eL "$LAUNCH_SCRIPT" --share-dir "$TESTS_DIR" "${PASSTHROUGH_ARGS[@]}" \
    <&$CONTROL_FD >"$SCREEN_LOG" 2>&1 &
LAUNCH_PID=$!
echo "$LAUNCH_PID" >"${SESSION_DIR}/launcher.pid"

step "[${TEST_NAME}] Waiting for guest login prompt..."
start_ts=$(date +%s)
while true; do
    if [[ -f "$SCREEN_LOG" ]] && grep -a -q 'root@gem5:~#' "$SCREEN_LOG"; then
        info "[${TEST_NAME}] Guest shell is ready"
        break
    fi
    if ! session_alive; then
        rm -f "$GUEST_SCRIPT_HOST"
        record_category "$COSIM_CAT_QEMU_EXIT" "true"
        error "[${TEST_NAME}] detached session exited during boot. Log tail:\n$(tail -n 40 "$SCREEN_LOG" 2>/dev/null)"
    fi
    now_ts=$(date +%s)
    if (( now_ts - start_ts >= BOOT_TIMEOUT_SECS )); then
        record_category "$COSIM_CAT_BOOT_TIMEOUT" "true"
        error "[${TEST_NAME}] guest did not reach login prompt within ${BOOT_TIMEOUT_SECS}s"
    fi
    sleep 2
done

start_line=1
if [[ -f "$SCREEN_LOG" ]]; then
    start_line=$(( $(wc -l < "$SCREEN_LOG") + 1 ))
fi

cat >"$GUEST_SCRIPT_HOST" <<EOF
#!/bin/bash
set -uo pipefail

if ! mountpoint -q /mnt; then
    mount -t 9p -o trans=virtio,version=9p2000.L cosim_share /mnt
fi

cd /mnt || exit 2
make -j1
TEST_TIMEOUT_SECS=${TEST_TIMEOUT_SECS} ./run_tests.sh ${TEST_NAME}
rc=\$?
echo "__${TOKEN}__:\${rc}"
exit "\${rc}"
EOF
chmod +x "$GUEST_SCRIPT_HOST"

step "[${TEST_NAME}] Running test inside guest..."
send_guest "if ! mountpoint -q /mnt; then mount -t 9p -o trans=virtio,version=9p2000.L cosim_share /mnt; fi; bash /mnt/${GUEST_SCRIPT}"

last_printed=$((start_line - 1))
result_rc=""
while true; do
    if [[ -f "$SCREEN_LOG" ]]; then
        current_lines=$(wc -l < "$SCREEN_LOG")
        if (( current_lines > last_printed )); then
            sed -n "$((last_printed + 1)),${current_lines}p" "$SCREEN_LOG"
            last_printed=$current_lines
        fi
        if tr -d '\r' < "$SCREEN_LOG" | grep -a -q "^__${TOKEN}__:[0-9][0-9]*$"; then
            result_rc="$(tr -d '\r' < "$SCREEN_LOG" | grep -a "^__${TOKEN}__:[0-9][0-9]*$" | tail -1 | sed 's/.*://')"
            break
        fi
    fi
    if ! session_alive; then
        rm -f "$GUEST_SCRIPT_HOST"
        record_category "$COSIM_CAT_QEMU_EXIT" "true"
        error "[${TEST_NAME}] detached session exited before the test finished. Log tail:\n$(tail -n 80 "$SCREEN_LOG" 2>/dev/null)"
    fi
    sleep 1
done

rm -f "$GUEST_SCRIPT_HOST"

if [[ "$result_rc" -eq 0 ]]; then
    record_category "$COSIM_CAT_TEST_PASS"
else
    record_category "$COSIM_CAT_TEST_FAIL"
    runner_artifact_dir="$(cosim_artifact_dir "$COSIM_DIR" "${TEST_NAME}" "$COSIM_RUN_ID")"
    mkdir -p "$runner_artifact_dir"
    if [[ -f "$SCREEN_LOG" ]]; then
        cp "$SCREEN_LOG" "${runner_artifact_dir}/qemu-console.log" 2>/dev/null || true
    fi
    cname="$(cosim_container_name "$COSIM_RUN_ID")"
    docker logs "$cname" > "${runner_artifact_dir}/gem5.log" 2>&1 || true
    {
        echo "run_id=${COSIM_RUN_ID}"
        echo "category=${COSIM_CAT_TEST_FAIL}"
        echo "test=${TEST_NAME}"
        echo "exit_code=${result_rc}"
    } > "${runner_artifact_dir}/metadata.txt"
fi

if [[ "$KEEP_ALIVE_ON_SUCCESS" -eq 1 && "$result_rc" -eq 0 ]]; then
    info "[${TEST_NAME}] Leaving QEMU + gem5 running (--keep-alive)"
    info "Console log: ${SCREEN_LOG}"
    info "Console pipe: ${SESSION_FIFO}"
else
    if [[ "$result_rc" -eq 0 ]]; then
        touch "/tmp/cosim-test-done-${COSIM_RUN_ID}" 2>/dev/null || true
    fi
    step "[${TEST_NAME}] Cleaning up detached session..."
    cleanup_session
fi

exec {CONTROL_FD}>&-

exit "$result_rc"
