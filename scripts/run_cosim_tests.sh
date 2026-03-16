#!/bin/bash
# Host-side single-operator test runner.
# Run one operator per QEMU + gem5 session to avoid cross-test state corruption.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COSIM_DIR="$(dirname "$SCRIPT_DIR")"
TESTS_DIR="${COSIM_DIR}/tests"
KERNELS_DIR="${TESTS_DIR}/kernels"
LAUNCH_SCRIPT="${SCRIPT_DIR}/cosim_launch.sh"

SESSION_NAME="${SESSION_NAME:-qemu-cosim-tests}"
SCREEN_LOG="${SCREEN_LOG:-}"
BOOT_TIMEOUT_SECS="${BOOT_TIMEOUT_SECS:-240}"
TEST_TIMEOUT_SECS="${TEST_TIMEOUT_SECS:-60}"
KEEP_ALIVE_ON_SUCCESS=0
RUN_ALL=0
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

if [[ "$SCREEN_LOG_SET" -eq 0 ]]; then
    SCREEN_LOG="/tmp/${SESSION_NAME}.log"
fi
SESSION_DIR="/tmp/${SESSION_NAME}.session"
SESSION_FIFO="${SESSION_DIR}/console.in"

if [[ "$RUN_ALL" -eq 1 ]]; then
    mapfile -t ALL_TESTS < <(find "$KERNELS_DIR" -maxdepth 1 -type f -name '*.cpp' -printf '%f\n' | sed 's/\.cpp$//' | sort)
    [[ ${#ALL_TESTS[@]} -gt 0 ]] || error "No operators found in ${KERNELS_DIR}"

    PASSED=0
    FAILED=0

    for test_name in "${ALL_TESTS[@]}"; do
        sub_session="${SESSION_NAME}-${test_name}"
        sub_log="/tmp/${sub_session}.log"
        if "$0" \
            --session-name "$sub_session" \
            --screen-log "$sub_log" \
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
    if [[ -n "${LAUNCH_PID:-}" ]]; then
        kill -TERM -- "-${LAUNCH_PID}" >/dev/null 2>&1 || true
        sleep 1
        kill -KILL -- "-${LAUNCH_PID}" >/dev/null 2>&1 || true
    fi
    docker rm -f gem5-cosim >/dev/null 2>&1 || true
    rm -rf "$SESSION_DIR" >/dev/null 2>&1 || true
    rm -f /tmp/gem5-mi300x.sock /dev/shm/mi300x-vram /dev/shm/cosim-guest-ram 2>/dev/null || true
}

session_alive() {
    [[ -n "${LAUNCH_PID:-}" ]] && kill -0 "$LAUNCH_PID" 2>/dev/null
}

send_guest() {
    local line="$1"
    printf '%s\n' "$line" >&$CONTROL_FD
}

# shellcheck disable=SC2317,SC2329
on_interrupt() {
    echo ""
    warn "Interrupted. The current QEMU + gem5 session remains running."
    warn "Launcher PID: ${LAUNCH_PID:-unknown}"
    warn "Console log: ${SCREEN_LOG}"
    warn "Console pipe: ${SESSION_FIFO}"
    warn "Cleanup: kill -TERM -- -${LAUNCH_PID:-0}; docker rm -f gem5-cosim"
    exit 130
}

trap on_interrupt INT TERM

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
GUEST_SCRIPT=".cosim_guest_run.${SESSION_NAME}.${TEST_NAME}.sh"
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
        error "[${TEST_NAME}] detached session exited during boot. Log tail:\n$(tail -n 40 "$SCREEN_LOG" 2>/dev/null)"
    fi
    now_ts=$(date +%s)
    if (( now_ts - start_ts >= BOOT_TIMEOUT_SECS )); then
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
        error "[${TEST_NAME}] detached session exited before the test finished. Log tail:\n$(tail -n 80 "$SCREEN_LOG" 2>/dev/null)"
    fi
    sleep 1
done

rm -f "$GUEST_SCRIPT_HOST"

if [[ "$KEEP_ALIVE_ON_SUCCESS" -eq 1 && "$result_rc" -eq 0 ]]; then
    info "[${TEST_NAME}] Leaving QEMU + gem5 running (--keep-alive)"
    info "Console log: ${SCREEN_LOG}"
    info "Console pipe: ${SESSION_FIFO}"
else
    step "[${TEST_NAME}] Cleaning up detached session..."
    cleanup_session
fi

exec {CONTROL_FD}>&-

exit "$result_rc"
