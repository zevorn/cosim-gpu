---
name: cosim-gpu-guest
description: Use when you need to send commands to a running cosim guest. Console pipe interaction, 9p share mount, GPU status check, manual driver load.
---

# Cosim Guest

Interact with the cosim guest Linux through a successful test session kept
alive with `just test-gpu --keep-alive <program>`. A `just run-launch` session
keeps the console attached to the terminal instead of creating a detached
console pipe.

## Prerequisites

The launcher or test runner prints the active console log and control pipe:

```text
Console log: /path/to/qemu.log
Console pipe: /tmp/<session-name>-<run-id>.session/console.in
```

If those lines are unavailable, derive the paths from the run id and session
name:

```bash
SESSION_NAME=qemu-cosim-tests
RUN_ID=<run-id>
CONSOLE_PIPE="/tmp/${SESSION_NAME}-${RUN_ID}.session/console.in"
CONSOLE_LOG="/tmp/${SESSION_NAME}-${RUN_ID}.log"
docker ps --filter name=gem5-cosim --format '{{.Names}}: {{.Status}}'
test -p "$CONSOLE_PIPE"
test -f "$CONSOLE_LOG"
```

## Sending Commands

```bash
printf '%s\n' '<command>' > "$CONSOLE_PIPE"
printf '\003' > "$CONSOLE_PIPE"   # Ctrl-C
tail -n 80 "$CONSOLE_LOG"
```

Wait pattern:
```bash
baseline=$(wc -l < "$CONSOLE_LOG")
printf '%s\n' '<command>' > "$CONSOLE_PIPE"
while true; do
    current=$(wc -l < "$CONSOLE_LOG")
    if [[ "$current" -gt "$((baseline + 3))" ]]; then
        tail -20 "$CONSOLE_LOG"
        break
    fi
    sleep 2
done
```

## Common operations

### Mount 9p share

```bash
printf '%s\n' 'mount -t 9p -o trans=virtio,version=9p2000.L cosim_share /mnt' > "$CONSOLE_PIPE"
```

After mounting, paths under `/mnt` must resolve inside the shared tree. Host
symlinks that point outside the shared repository will appear in the guest but
may resolve to an unmounted guest path. If a script or artifact is missing
through such a symlink, classify it as a guest bridge path issue and rerun with
a guest-visible path before using the result as model evidence.

Do not assume any particular host storage layout for artifacts. One developer
may keep artifacts as a real directory, another may point it at a larger disk,
and a CI worker may use a temporary workspace. Runner scripts that execute in
the guest should therefore use a configurable guest-visible bridge path inside
the shared tree, while final logs, matrices, verdicts, and provenance are still
archived under the requested artifact directory. The transient bridge directory
is not evidence by itself; preserve its script and output under the row artifact
before cleanup.

### Build and run tests

```bash
# Build tests from 9p share
printf '%s\n' 'cd /mnt/tests && make -j1' > "$CONSOLE_PIPE"

# Run a ROCm device program with the same privilege level as the test runner.
printf '%s\n' "printf '%s\n' \"\${COSIM_GUEST_SUDO_PASSWORD:?set COSIM_GUEST_SUDO_PASSWORD}\" | sudo -S bash -lc 'cd /mnt/tests && ./build/vector_add'" > "$CONSOLE_PIPE"
```

Use this privilege pattern for programs that open `/dev/kfd` or
`/dev/dri/renderD*`. A plain `gem5` user launch is an invalid device-debug
setup because it can enumerate no GPU device.

### Check GPU status

```bash
printf '%s\n' 'rocm-smi' > "$CONSOLE_PIPE"
printf '%s\n' 'rocminfo 2>/dev/null | head -40' > "$CONSOLE_PIPE"
printf '%s\n' 'dmesg | grep -i amdgpu | tail -10' > "$CONSOLE_PIPE"
```

### Manual driver load

```bash
printf '%s\n' 'dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128 && rm -f /run/modprobe.d/*blacklist* && modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2' > "$CONSOLE_PIPE"
```

### Shutdown

```bash
printf '%s\n' "printf '%s\n' \"\${COSIM_GUEST_SUDO_PASSWORD:?set COSIM_GUEST_SUDO_PASSWORD}\" | sudo -S poweroff" > "$CONSOLE_PIPE"
```

Use privileged shutdown after guest evidence is saved. This matches the
privilege level used for ROCm device programs and avoids leaving a live guest
waiting for manual poweroff. If the guest no longer accepts console input,
record that fact and use `just run-clean-orphans` to remove orphaned host
resources.

## Integration

- Use `cosim-gpu-test` for automated test execution
- Use `cosim-gpu-debug` for two-sided inspection
- For manual debugging sessions, send commands directly as shown above
