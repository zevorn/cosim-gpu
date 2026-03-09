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
SCREEN_LOG="${SCREEN_LOG:-/tmp/${SESSION_NAME}.log}"
BOOT_TIMEOUT_SECS="${BOOT_TIMEOUT_SECS:-240}"
TEST_TIMEOUT_SECS="${TEST_TIMEOUT_SECS:-60}"
KEEP_ALIVE_ON_SUCCESS=0
FILTER=""
PASSTHROUGH_ARGS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "${CYAN}[STEP]${NC} $*"; }

usage() {
    cat <<EOF
Host-side single-operator cosim test runner.

Usage: $0 [options] <operator-filter>

Options:
  --keep-alive           Leave QEMU + gem5 running after a successful test
  --session-name NAME    screen session name (default: qemu-cosim-tests)
  --screen-log PATH      screen log path (default: /tmp/qemu-cosim-tests.log)
  --boot-timeout SECS    guest boot timeout (default: 240)
  --test-timeout SECS    per-test timeout inside guest (default: 60)
  -h, --help             Show this help

Unknown options are passed through to cosim_launch.sh.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-alive)       KEEP_ALIVE_ON_SUCCESS=1; shift ;;
        --session-name)     SESSION_NAME="$2"; shift 2 ;;
        --screen-log)       SCREEN_LOG="$2"; shift 2 ;;
        --boot-timeout)     BOOT_TIMEOUT_SECS="$2"; shift 2 ;;
        --test-timeout)     TEST_TIMEOUT_SECS="$2"; shift 2 ;;
        -h|--help)          usage ;;
        --*)                PASSTHROUGH_ARGS+=("$1" "$2"); shift 2 ;;
        *)                  FILTER="$1"; shift ;;
    esac
done

[[ -n "$FILTER" ]] || usage

cleanup_session() {
    screen -S "$SESSION_NAME" -X quit >/dev/null 2>&1 || true
    docker rm -f gem5-cosim >/dev/null 2>&1 || true
    rm -f /tmp/gem5-mi300x.sock /dev/shm/mi300x-vram /dev/shm/cosim-guest-ram 2>/dev/null || true
}

on_interrupt() {
    echo ""
    warn "Interrupted. The current QEMU + gem5 session remains running."
    warn "Attach: screen -r ${SESSION_NAME}"
    warn "Cleanup: screen -S ${SESSION_NAME} -X quit && docker rm -f gem5-cosim"
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

screen -S "$SESSION_NAME" -Q select . >/dev/null 2>&1 && \
    error "screen session '${SESSION_NAME}' already exists"

rm -f "$SCREEN_LOG"

step "[${TEST_NAME}] Starting detached QEMU + gem5 session..."
screen -L -Logfile "$SCREEN_LOG" -dmS "$SESSION_NAME" \
    "$LAUNCH_SCRIPT" --share-dir "$TESTS_DIR" "${PASSTHROUGH_ARGS[@]}"
screen -S "$SESSION_NAME" -X logfile flush 1 >/dev/null 2>&1 || true

step "[${TEST_NAME}] Waiting for guest login prompt..."
start_ts=$(date +%s)
while true; do
    if [[ -f "$SCREEN_LOG" ]] && grep -a -q 'root@gem5:~#' "$SCREEN_LOG"; then
        info "[${TEST_NAME}] Guest shell is ready"
        break
    fi
    if ! screen -S "$SESSION_NAME" -Q select . >/dev/null 2>&1; then
        error "[${TEST_NAME}] screen session exited during boot"
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
screen -S "$SESSION_NAME" -X stuff \
    "if ! mountpoint -q /mnt; then mount -t 9p -o trans=virtio,version=9p2000.L cosim_share /mnt; fi; bash /mnt/${GUEST_SCRIPT}"$'\n'

last_printed=$((start_line - 1))
result_rc=""
while true; do
    if [[ -f "$SCREEN_LOG" ]]; then
        current_lines=$(wc -l < "$SCREEN_LOG")
        if (( current_lines > last_printed )); then
            sed -n "$((last_printed + 1)),${current_lines}p" "$SCREEN_LOG"
            last_printed=$current_lines
        fi
        if grep -a -q "^__${TOKEN}__:[0-9][0-9]*$" "$SCREEN_LOG"; then
            result_rc="$(grep -a "^__${TOKEN}__:[0-9][0-9]*$" "$SCREEN_LOG" | tail -1 | sed 's/.*://')"
            break
        fi
    fi
    if ! screen -S "$SESSION_NAME" -Q select . >/dev/null 2>&1; then
        rm -f "$GUEST_SCRIPT_HOST"
        error "[${TEST_NAME}] screen session exited before the test finished"
    fi
    sleep 1
done

rm -f "$GUEST_SCRIPT_HOST"

if [[ "$KEEP_ALIVE_ON_SUCCESS" -eq 1 && "$result_rc" -eq 0 ]]; then
    info "[${TEST_NAME}] Leaving QEMU + gem5 running (--keep-alive)"
    info "Attach: screen -r ${SESSION_NAME}"
else
    step "[${TEST_NAME}] Cleaning up detached session..."
    cleanup_session
fi

exit "$result_rc"
