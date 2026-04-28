---
description: Debug QEMU+gem5 co-simulation issues by inspecting both sides (guest serial via screen, gem5 via docker logs), checking PCI devices, kernel messages, and MMIO traffic.
allowed-tools: Bash, Read, Grep, Glob, Agent
argument-hint: "[symptom or error message]"
---

# Co-simulation Debugging Workflow

Debug the QEMU+gem5 MI300X co-simulation for issue: $ARGUMENTS

## Environment Check

First verify both sides are running:

```bash
# gem5 container status
docker ps -a --filter name=gem5-cosim --format '{{.Status}}'

# QEMU screen session
screen -ls 2>/dev/null | grep qemu

# Shared resources
ls -la /tmp/gem5-mi300x.sock /dev/shm/mi300x-vram /dev/shm/cosim-guest-ram 2>/dev/null
```

## Two-Sided Log Collection

### gem5 side (Docker)

```bash
# Full gem5 logs (cosim socket, MMIO, GART, SDMA)
docker logs gem5-cosim 2>&1 | tail -50

# Filter by subsystem
docker logs gem5-cosim 2>&1 | grep -E "warn|error|GART|cosim|SDMA"
```

### QEMU / Guest side (screen)

```bash
# Capture current screen state (non-destructive snapshot)
screen -S qemu-cosim -p 0 -X hardcopy /tmp/qemu-snap.txt
cat /tmp/qemu-snap.txt | grep -v "^$" | tail -30

# Or read the serial log if QEMU was started with tee:
tail -30 /tmp/qemu-serial.log

# Send a command to guest and capture result
screen -S qemu-cosim -p 0 -X stuff 'COMMAND_HERE\n'
sleep 3
screen -S qemu-cosim -p 0 -X hardcopy /tmp/qemu-snap.txt
```

## Guest-Side Inspection Commands

Send these via `screen -S qemu-cosim -p 0 -X stuff '...\n'`:

```bash
# Kernel driver messages
dmesg | grep -i amdgpu | tail -20

# PCI device details (MI300X is usually at 00:03.0)
lspci
lspci -vvs 00:03.0

# Check if driver loaded
lsmod | grep amdgpu

# Check systemd service
systemctl status cosim-gpu-setup.service

# ROCm verification
rocm-smi
rocminfo 2>/dev/null | grep -A5 "Agent 2"
```

## Common Failure Patterns

### 1. NULL deref in amdgpu_atom_parse_data_header

**Symptom**: Kernel oops at `amdgpu_atom_parse_data_header+0x1b`, RAX=0.

**Cause**: `dd` ROM to 0xC0000 was not done before `modprobe`. The driver's BIOS
discovery chain (ACPI ATRM/VFCT, SMU ROM read, platform ROM) all fail in cosim mode.
Without ROM in shared memory, `atom_context` is NULL.

**Fix**:
```bash
dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128
modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

**Why it works**: The `dd` writes ROM to guest physical memory at 0xC0000, which maps
to `/dev/shm/cosim-guest-ram`. gem5's `AMDGPUDevice::readROM()` reads from this shared
memory via `system->getPhysMem()` when the driver accesses SMU ROM registers through
MMIO. QEMU's `romfile=` property loads ROM to PCI ROM BAR but the driver doesn't read
from PCI ROM BAR directly -- it uses SMU register-based ROM access.

### 2. PSP firmware load failure (ip_block_mask=0x6f)

**Symptom**: `PSP load tmr failed!`, kernel panic during GPU init.

**Cause**: `0x6f` disables SMU (bit 4) but NOT PSP (bit 3). PSP init triggers GPU
reset that gem5 cannot handle.

**Fix**: Use `ip_block_mask=0x67` (disables both PSP bit 3 and SMU bit 4).

### 3. gem5 container exits immediately

**Check**: `docker logs gem5-cosim 2>&1 | tail -20`

Common causes: Python config syntax error, missing shared memory, OOM during startup.

### 4. QEMU "lost connection to gem5"

gem5 crashed or socket closed. Check gem5 docker logs for `fatal`, `panic`, or
`schedule()` assertion errors.

### 5. Driver loads but rocm-smi shows "Driver not initialized"

Check `dmesg | grep -i amdgpu` for initialization errors. Common cause: the driver
was blacklisted but modprobe was never run (check `cosim-gpu-setup.service` status).

### 6. cosim-gpu-setup.service exits 0 but driver not loaded

**Symptom**: `systemctl status cosim-gpu-setup` shows SUCCESS, but `lsmod | grep amdgpu`
is empty.

**Cause**: `modprobe.blacklist=amdgpu` on the kernel command line creates a runtime
blacklist file at `/run/modprobe.d/`. The `modprobe` command silently skips blacklisted
modules (returns exit 0 without loading).

**Fix**: The setup script must remove the runtime blacklist before calling modprobe:
```bash
rm -f /run/modprobe.d/*blacklist* 2>/dev/null
modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

## Debugging Tips

- **Start QEMU with serial log capture**: Use `2>&1 | tee /tmp/qemu-serial.log` to
  have both interactive screen and searchable log file.
- **gem5 debug flags**: Restart gem5 with `--debug-flags=MI300XCosim,AMDGPUDevice` for
  verbose MMIO logging.
- **ROM file inspection**: `xxd /root/roms/mi300.rom | head -10` to verify 55 AA signature.
- **After kernel oops**: The module is stuck; `rmmod` will fail. Must restart the full
  cosim environment (QEMU + gem5).
- **PCI ROM BAR**: `lspci -vvs 00:03.0` shows `Expansion ROM at 000c0000 [disabled]`.
  This is from QEMU's `romfile=` but the driver doesn't use it.
