#!/bin/bash
# Shared library for cosim infrastructure: run-ID generation, resource path
# computation, failure taxonomy, resource manifest, and diagnostic utilities.

# ---- Run-ID Generation ----

generate_run_id() {
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local rand
    rand="$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
    echo "${ts}-${rand}"
}

# ---- Resource Path Computation ----

cosim_container_name() {
    local run_id="$1"
    echo "gem5-cosim-${run_id}"
}

cosim_socket_path() {
    local run_id="$1"
    local gpu_id="${2:-0}"
    local num_gpus="${3:-1}"
    if [[ "$num_gpus" -eq 1 ]]; then
        echo "/tmp/gem5-mi300x-${run_id}.sock"
    else
        echo "/tmp/gem5-mi300x-${run_id}-${gpu_id}.sock"
    fi
}

cosim_vram_shmem_path() {
    local run_id="$1"
    local gpu_id="${2:-0}"
    local num_gpus="${3:-1}"
    if [[ "$num_gpus" -eq 1 ]]; then
        echo "/dev/shm/mi300x-vram-${run_id}"
    else
        echo "/dev/shm/mi300x-vram-${run_id}-${gpu_id}"
    fi
}

cosim_guest_ram_shmem_path() {
    local run_id="$1"
    echo "/dev/shm/cosim-guest-ram-${run_id}"
}

cosim_session_dir() {
    local run_id="$1"
    local session_name="${2:-cosim}"
    echo "/tmp/${session_name}-${run_id}.session"
}

cosim_screen_log() {
    local run_id="$1"
    local session_name="${2:-cosim}"
    echo "/tmp/${session_name}-${run_id}.log"
}

cosim_artifact_dir() {
    local cosim_dir="$1"
    local operator="$2"
    local run_id="$3"
    echo "${cosim_dir}/artifacts/${operator}/${run_id}"
}

# ---- Failure Taxonomy (exported for use by sourcing scripts) ----

export COSIM_CAT_TEST_PASS="test_pass"
export COSIM_CAT_TEST_FAIL="test_fail"
export COSIM_CAT_TEST_TIMEOUT="test_timeout"
export COSIM_CAT_BOOT_TIMEOUT="boot_timeout"
export COSIM_CAT_GEM5_INIT_TIMEOUT="gem5_init_timeout"
export COSIM_CAT_GEM5_EXIT="gem5_exit"
export COSIM_CAT_QEMU_EXIT="qemu_exit"
export COSIM_CAT_READINESS_FAIL="readiness_fail"
export COSIM_CAT_STALE_CONFLICT="stale_conflict"
export COSIM_CAT_INTERRUPT="interrupt"
export COSIM_CAT_CLEANUP_FAIL="cleanup_fail"
export COSIM_CAT_INFRA_UNKNOWN="infra_unknown"

is_infra_failure() {
    local category="$1"
    case "$category" in
        "$COSIM_CAT_TEST_PASS"|"$COSIM_CAT_TEST_FAIL"|"$COSIM_CAT_TEST_TIMEOUT"|"$COSIM_CAT_INTERRUPT")
            return 1 ;;
        *)
            return 0 ;;
    esac
}

# ---- Resource Manifest ----

COSIM_MANIFEST_FILE=""

manifest_init() {
    local session_dir="$1"
    COSIM_MANIFEST_FILE="${session_dir}/resources.manifest"
    mkdir -p "$session_dir"
    : > "$COSIM_MANIFEST_FILE"
}

manifest_add() {
    local role="$1"   # runtime or artifact
    local type="$2"   # container, socket, shmem, file, directory
    local path="$3"
    [[ -n "$COSIM_MANIFEST_FILE" ]] || return 1
    echo "${role}|${type}|${path}" >> "$COSIM_MANIFEST_FILE"
}

manifest_runtime_paths() {
    [[ -f "$COSIM_MANIFEST_FILE" ]] || return
    grep '^runtime|' "$COSIM_MANIFEST_FILE" | cut -d'|' -f3
}

manifest_artifact_paths() {
    [[ -f "$COSIM_MANIFEST_FILE" ]] || return
    grep '^artifact|' "$COSIM_MANIFEST_FILE" | cut -d'|' -f3
}

# ---- Diagnostic Artifact Capture ----

capture_artifacts() {
    local artifact_dir="$1"
    local container_name="$2"
    local screen_log="${3:-}"
    local run_id="${4:-unknown}"
    local category="${5:-$COSIM_CAT_INFRA_UNKNOWN}"

    mkdir -p "$artifact_dir"

    echo "run_id=${run_id}" > "${artifact_dir}/metadata.txt"
    echo "category=${category}" >> "${artifact_dir}/metadata.txt"
    echo "timestamp=$(date -Iseconds)" >> "${artifact_dir}/metadata.txt"

    docker logs "$container_name" > "${artifact_dir}/gem5.log" 2>&1 || true
    docker inspect "$container_name" > "${artifact_dir}/docker-inspect.json" 2>&1 || true

    if [[ -n "$screen_log" && -f "$screen_log" ]]; then
        cp "$screen_log" "${artifact_dir}/qemu-console.log" 2>/dev/null || true
    fi

    ls -la /dev/shm/ > "${artifact_dir}/devshm-listing.txt" 2>&1 || true
    ls -la /tmp/gem5-mi300x*.sock > "${artifact_dir}/socket-listing.txt" 2>&1 || true
    pgrep -af '(gem5|qemu)' > "${artifact_dir}/process-snapshot.txt" 2>&1 || true
    docker ps -a --filter "name=gem5-cosim" > "${artifact_dir}/docker-ps.txt" 2>&1 || true
}

# ---- Cleanup Utilities ----

cleanup_from_manifest() {
    local container_name="$1"

    # Snapshot runtime paths before deleting session directory
    local -a runtime_paths=()
    local path
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        runtime_paths+=("$path")
    done < <(manifest_runtime_paths)

    # Store for verify_cleanup
    _COSIM_RUNTIME_PATHS=("${runtime_paths[@]+"${runtime_paths[@]}"}")

    docker rm -f "$container_name" >/dev/null 2>&1 || true

    for path in "${runtime_paths[@]+"${runtime_paths[@]}"}"; do
        if [[ -d "$path" ]]; then
            rm -rf "$path" 2>/dev/null || true
        else
            rm -f "$path" 2>/dev/null || true
        fi
    done
}

verify_cleanup() {
    local timeout_secs="${1:-10}"
    local container_name="${2:-}"
    local elapsed=0

    local -a paths=("${_COSIM_RUNTIME_PATHS[@]+"${_COSIM_RUNTIME_PATHS[@]}"}")

    while [[ $elapsed -lt $timeout_secs ]]; do
        local remaining=0

        if [[ -n "$container_name" ]]; then
            if docker inspect "$container_name" >/dev/null 2>&1; then
                remaining=$((remaining + 1))
            fi
        fi

        for path in "${paths[@]+"${paths[@]}"}"; do
            if [[ -e "$path" ]]; then
                remaining=$((remaining + 1))
            fi
        done

        if [[ $remaining -eq 0 ]]; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

_COSIM_RUNTIME_PATHS=()

# ---- Force-Clean (Dry-Run by Default) ----

force_clean_orphans() {
    local confirm="${1:-false}"
    local found=0

    local c
    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        echo "  orphan container: $c"
        found=1
        if [[ "$confirm" == "true" ]]; then
            docker rm -f "$c" >/dev/null 2>&1 || true
        fi
    done < <(docker ps -a --filter "name=gem5-cosim-" --filter "status=exited" --filter "status=dead" --filter "status=created" --format '{{.Names}}' 2>/dev/null)

    _extract_run_id() {
        local name="$1"
        if [[ "$name" =~ ^([0-9]{8}-[0-9]{6}-[0-9a-f]+) ]]; then
            echo "${BASH_REMATCH[1]}"
        fi
    }

    _is_run_active() {
        local rid="$1"
        [[ -n "$rid" ]] || return 1
        local cname="gem5-cosim-${rid}"
        [[ "$(docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null)" == "true" ]]
    }

    local f rid
    for f in /tmp/gem5-mi300x-*.sock; do
        [[ -e "$f" ]] || continue
        rid="$(_extract_run_id "${f#/tmp/gem5-mi300x-}")"
        if [[ -n "$rid" ]] && _is_run_active "$rid"; then
            echo "  active socket (skipped): $f"
            continue
        fi
        echo "  orphan socket: $f"
        found=1
        if [[ "$confirm" == "true" ]]; then
            rm -f "$f" 2>/dev/null || true
        fi
    done

    for f in /dev/shm/mi300x-vram /dev/shm/mi300x-vram-* /dev/shm/cosim-guest-ram /dev/shm/cosim-guest-ram-*; do
        [[ -e "$f" ]] || continue
        rid=""
        case "$f" in
            /dev/shm/mi300x-vram-*)      rid="$(_extract_run_id "${f#/dev/shm/mi300x-vram-}")" ;;
            /dev/shm/cosim-guest-ram-*)   rid="$(_extract_run_id "${f#/dev/shm/cosim-guest-ram-}")" ;;
        esac
        if [[ -n "$rid" ]] && _is_run_active "$rid"; then
            echo "  active shmem (skipped): $f"
            continue
        fi
        echo "  orphan shmem: $f"
        found=1
        if [[ "$confirm" == "true" ]]; then
            rm -f "$f" 2>/dev/null || true
        fi
    done

    # Legacy un-namespaced resources
    if [[ -e /tmp/gem5-mi300x.sock ]]; then
        echo "  orphan legacy socket: /tmp/gem5-mi300x.sock"
        found=1
        if [[ "$confirm" == "true" ]]; then
            rm -f /tmp/gem5-mi300x.sock 2>/dev/null || true
        fi
    fi
    if docker ps -a --filter "status=exited" --filter "status=dead" --filter "status=created" --format '{{.Names}}' 2>/dev/null | grep -qx 'gem5-cosim'; then
        echo "  orphan legacy container: gem5-cosim"
        found=1
        if [[ "$confirm" == "true" ]]; then
            docker rm -f gem5-cosim >/dev/null 2>&1 || true
        fi
    fi

    if [[ $found -eq 0 ]]; then
        echo "  (no orphaned resources found)"
    elif [[ "$confirm" != "true" ]]; then
        echo "  (dry-run: use --force-clean --confirm to delete)"
    fi

    return 0
}

# ---- Health Check ----

check_readiness() {
    local socket_path="$1"
    local vram_shmem="$2"
    local guest_ram_shmem="$3"
    local container_name="$4"
    local expected_vram_bytes="${5:-17179869184}"
    local expected_ram_bytes="${6:-8589934592}"

    if [[ ! -S "$socket_path" ]]; then
        echo "readiness check failed: socket $socket_path does not exist or is not a Unix socket"
        return 1
    fi

    if [[ ! -f "$vram_shmem" ]]; then
        echo "readiness check failed: VRAM shmem $vram_shmem does not exist"
        return 1
    fi
    local vram_size
    vram_size="$(stat -c%s "$vram_shmem" 2>/dev/null || echo 0)"
    if [[ "$vram_size" -ne "$expected_vram_bytes" ]]; then
        echo "readiness check failed: VRAM shmem size $vram_size != expected $expected_vram_bytes"
        return 1
    fi

    if [[ ! -f "$guest_ram_shmem" ]]; then
        echo "readiness check failed: guest RAM shmem $guest_ram_shmem does not exist"
        return 1
    fi
    local ram_size
    ram_size="$(stat -c%s "$guest_ram_shmem" 2>/dev/null || echo 0)"
    if [[ "$ram_size" -ne "$expected_ram_bytes" ]]; then
        echo "readiness check failed: guest RAM shmem size $ram_size != expected $expected_ram_bytes"
        return 1
    fi

    if [[ "$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null)" != "true" ]]; then
        echo "readiness check failed: container $container_name is not running"
        return 1
    fi

    return 0
}

# ---- Preflight Audit ----

run_preflight_audit() {
    echo "=== Preflight Resource Audit ==="
    echo "Timestamp: $(date -Iseconds)"
    echo ""

    echo "--- Docker containers (gem5-cosim) ---"
    docker ps -a --filter "name=gem5-cosim" 2>/dev/null || echo "(docker not available)"
    echo ""

    echo "--- /dev/shm (cosim-related) ---"
    ls -la /dev/shm/mi300x-vram* /dev/shm/cosim-guest-ram* 2>/dev/null || echo "(none found)"
    echo ""

    echo "--- /tmp sockets (gem5-mi300x) ---"
    ls -la /tmp/gem5-mi300x*.sock 2>/dev/null || echo "(none found)"
    echo ""

    echo "--- gem5 processes ---"
    pgrep -a gem5 2>/dev/null || echo "(none found)"
    echo ""

    echo "=== End Preflight Audit ==="
}
