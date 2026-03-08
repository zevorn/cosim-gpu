---
description: Interact with the QEMU+gem5 cosim guest Linux via screen session. Send commands, read output, mount 9p shares, build and run GPU tests.
allowed-tools: Bash, Read, Grep, Glob, Agent
argument-hint: "<command to run in guest | 'run-tests' | 'mount-share' | 'status'>"
---

# Co-simulation Guest Interaction

Interact with the cosim guest Linux for: $ARGUMENTS

## Prerequisites

The cosim environment must be running. Verify with:

```bash
# Check screen session (QEMU serial console)
screen -ls 2>/dev/null | grep cosim-launch

# Check gem5 container
docker ps --filter name=gem5-cosim --format '{{.Names}}: {{.Status}}'

# Check log file
tail -5 /tmp/cosim-launch.log
```

The screen session name is `cosim-launch` and log file is `/tmp/cosim-launch.log`.

## Sending Commands to Guest

Use `screen -S cosim-launch -X stuff` to send commands:

```bash
# Send a command
screen -S cosim-launch -X stuff '<command>\n'

# Send Ctrl-C to interrupt
screen -S cosim-launch -X stuff $'\x03'

# Read output (wait a few seconds for command to execute)
tail -N /tmp/cosim-launch.log
```

**Important**: After sending a command, wait for output by monitoring the log file
line count. Use a pattern like:

```bash
baseline=$(wc -l < /tmp/cosim-launch.log)
# send command...
# then poll:
while true; do
    current=$(wc -l < /tmp/cosim-launch.log)
    if [[ "$current" -gt "$((baseline + N))" ]]; then
        tail -M /tmp/cosim-launch.log
        break
    fi
    sleep 10
done
```

## Common Operations

### Mount 9p shared directory

The `--share-dir` option in cosim_launch.sh enables virtio-9p sharing.
In the guest:

```bash
screen -S cosim-launch -X stuff 'mount -t 9p -o trans=virtio,version=9p2000.L cosim_share /mnt\n'
```

Files from the host `--share-dir` path are then available under `/mnt/`.

### Build and run GPU tests

```bash
# Copy test sources from 9p mount and build
screen -S cosim-launch -X stuff 'mkdir -p /root/tests && cp -r /mnt/* /root/tests/ && make -C /root/tests all 2>&1 | tail -3\n'

# Run all tests
screen -S cosim-launch -X stuff 'make -C /root/tests test 2>&1\n'

# Run a single test
screen -S cosim-launch -X stuff '/root/tests/build/<test_name> 2>&1\n'
```

### Check GPU status

```bash
screen -S cosim-launch -X stuff 'rocm-smi\n'
screen -S cosim-launch -X stuff 'rocminfo 2>/dev/null | head -40\n'
screen -S cosim-launch -X stuff 'dmesg | grep -i amdgpu | tail -10\n'
screen -S cosim-launch -X stuff 'systemctl is-active cosim-gpu-setup\n'
```

### Shutdown guest cleanly

```bash
# Ctrl-A X quits QEMU
screen -S cosim-launch -X stuff $'\x01x'

# Or from inside guest
screen -S cosim-launch -X stuff 'poweroff\n'
```

## Waiting for Test Results

For long-running tests, use background monitoring:

```bash
# Wait for specific test output
baseline=$(wc -l < /tmp/cosim-launch.log)
while true; do
    current=$(wc -l < /tmp/cosim-launch.log)
    if [[ "$current" -gt "$((baseline + 3))" ]]; then
        tail -10 /tmp/cosim-launch.log
        break
    fi
    sleep 10
done
```

Or use the `run_in_background` parameter for non-blocking monitoring.

## Launching the Cosim Environment

```bash
# Basic launch (screen + log)
screen -dmS cosim-launch -L -Logfile /tmp/cosim-launch.log \
    ./scripts/cosim_launch.sh

# With 9p share and debug
screen -dmS cosim-launch -L -Logfile /tmp/cosim-launch.log \
    ./scripts/cosim_launch.sh --share-dir /path/to/dir --gem5-debug MI300XCosim

# Wait for guest boot
while ! grep -q 'automatic login' /tmp/cosim-launch.log 2>/dev/null; do sleep 10; done
```

## Cleanup

```bash
# Kill QEMU (Ctrl-A X)
screen -S cosim-launch -X stuff $'\x01x'

# Remove residual resources
docker rm -f gem5-cosim 2>/dev/null
rm -f /tmp/gem5-mi300x.sock /dev/shm/mi300x-vram /dev/shm/cosim-guest-ram 2>/dev/null
```
