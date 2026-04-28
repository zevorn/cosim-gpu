[中文](../zh/cosim-guest-gpu-init.md)

# MI300X Co-simulation: Guest GPU Initialization Guide

## Overview

The MI300X GPU driver can be loaded **automatically** or **manually** after the QEMU guest boots. The disk image includes a systemd service (`cosim-gpu-setup.service`) that handles the full initialization sequence at boot time.

All required files (ROM, firmware, kernel modules) are already included in the disk image.

## Automatic Loading (Default)

The disk image ships with `cosim-gpu-setup.service`, which runs at boot and performs:

1. `dd` the VGA ROM to `0xC0000` (required for gem5's `readROM()` via shared memory)
2. Symlink IP discovery firmware
3. `modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2`

The service completes in ~40 seconds. After guest login, GPU is ready:

```bash
rocm-smi          # should show device 0x74a0
rocminfo          # should show gfx942
```

The service file:

```ini
# /etc/systemd/system/cosim-gpu-setup.service
[Unit]
Description=MI300X GPU Setup for Co-simulation
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/cosim-gpu-setup.sh

[Install]
WantedBy=multi-user.target
```

> **Note:** `modprobe.blacklist=amdgpu` must remain in the kernel command line to prevent the PCI subsystem from auto-loading the driver before the ROM is written to shared memory. The systemd service handles the explicit `modprobe` after `dd`.

## Manual Loading

If the systemd service is not installed, run these commands manually after guest boot.

### Prerequisites

- `cosim_launch.sh` is running (gem5 + QEMU are connected)
- The guest has booted and you have a root shell
- `modprobe.blacklist=amdgpu` was passed on the kernel command line

### Quick Reference (Copy-Paste Ready)

```bash
dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128
ln -sf /usr/lib/firmware/amdgpu/mi300_discovery /usr/lib/firmware/amdgpu/ip_discovery.bin
modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

## Detailed Steps

### Step 1: Load the VGA BIOS ROM

```bash
dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128
```

**What it does**: Writes the MI300X VBIOS ROM image to the legacy VGA ROM region at physical address `0xC0000` (768 KB).

**Why it is needed**: The amdgpu driver reads the VBIOS from the legacy VGA ROM space (`0xC0000--0xDFFFF`, 128 KB) during initialization. The QEMU co-simulation device registers as `PCI_CLASS_DISPLAY_VGA`, so the kernel recognizes that address range as "shadowed ROM". Without the ROM, the driver will report `"Unable to locate a BIOS ROM"`.

**Parameter description**:
| Parameter | Value | Meaning |
|-----------|-------|---------|
| `if`      | `/root/roms/mi300.rom` | ROM binary file (in the disk image) |
| `of`      | `/dev/mem`             | Physical memory device |
| `bs`      | `1k`                   | Block size = 1024 bytes |
| `seek`    | `768`                  | Seek to 768 x 1024 = `0xC0000` |
| `count`   | `128`                  | Write 128 x 1024 = 128 KB |

### Step 2: Symlink the IP Discovery Firmware

```bash
ln -sf /usr/lib/firmware/amdgpu/mi300_discovery \
       /usr/lib/firmware/amdgpu/ip_discovery.bin
```

**What it does**: Points the driver's IP discovery firmware path to the MI300X-specific discovery binary.

**Why it is needed**: The amdgpu driver uses `discovery=2` mode, which reads GPU IP block information from a firmware file on disk rather than from the GPU's own ROM/registers. The gem5 GPU model provides this file via its `ipt_binary` parameter (empty string = use on-disk firmware). The driver looks for `/usr/lib/firmware/amdgpu/ip_discovery.bin`, which must point to the MI300X-specific file.

**Note**: Both files are already included in the disk image; this command only creates the correct symlink. If `mi300_discovery` does not exist, the driver will fall back to built-in defaults (which may not match MI300X).

### Step 3: Load the amdgpu Kernel Module

```bash
modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

**What it does**: Loads the amdgpu driver with co-simulation parameters.

**amdgpu module parameters**:

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `ip_block_mask` | `0x67` | Disable PSP (bit 3) and SMU (bit 4); cosim does not model these |
| `ppfeaturemask` | `0` | Disable PowerPlay features; cosim has no power management hardware |
| `dpm` | `0` | Disable Dynamic Power Management |
| `audio` | `0` | Disable audio; no HDMI/DP audio in cosim |
| `ras_enable` | `0` | Disable RAS — prevents NULL deref on `atom_context` when VBIOS is minimal |
| `discovery` | `2` | Use firmware file for IP discovery |

> **Warning**: Using `ip_block_mask=0x6f` (only disables SMU) will cause PSP firmware load failure and kernel panic. Always use `0x67`.

> **Warning**: The `dd` step (Step 1) is **mandatory** before `modprobe`. Without it, the driver's BIOS discovery chain fails (ACPI unavailable, SMU disabled), resulting in `"Unable to locate a BIOS ROM"` followed by a NULL pointer crash in `amdgpu_ras_init` → `amdgpu_atom_parse_data_header`.

## Verification

After completing step 3, check that the driver has loaded:

```bash
# Check dmesg for amdgpu initialization
dmesg | grep -i amdgpu | tail -20

# Check PCI device
lspci | grep -i amd

# Check ROCm (if available)
rocm-smi
rocminfo | head -40
```

**Expected results**: `dmesg` should show amdgpu initializing the GPU with no fatal errors. MMIO traffic should appear in the gem5 debug log.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Unable to locate a BIOS ROM` + NULL deref crash | Step 1 (dd ROM) was not executed before modprobe | Run `dd` first; check `/root/roms/mi300.rom` exists |
| `insmod: ERROR: could not load module` | Kernel version mismatch | Rebuild the disk image with a matching kernel |
| `cosim-gpu-setup.service` failed | Check `journalctl -u cosim-gpu-setup` | Verify ROM file and module exist in disk image |
| MMIO reads all return zero | gem5 is not connected or has crashed | Check `docker logs gem5-cosim` |
| `probe failed with error -12` | BAR layout mismatch | Rebuild QEMU with the correct BAR5=MMIO layout |
| gem5 crashes with `schedule()` assertion | Timer event overflow | Ensure `disable_rtc_events` and `disable_timer_events` are set |

## File Locations (Inside the Guest Disk Image)

| File | Path | Source |
|------|------|--------|
| VGA BIOS ROM | `/root/roms/mi300.rom` | Built by Packer |
| IP Discovery firmware | `/usr/lib/firmware/amdgpu/mi300_discovery` | Built by Packer |
| Auto-load service | `/etc/systemd/system/cosim-gpu-setup.service` | Installed via `guestmount` |
| Auto-load script | `/usr/local/bin/cosim-gpu-setup.sh` | Installed via `guestmount` |
| amdgpu module | `/lib/modules/$(uname -r)/updates/dkms/amdgpu.ko.zst` | ROCm 7.0 DKMS |
