[中文](../zh/cosim-guest-gpu-init.md)

# MI300X Co-simulation: Guest GPU Initialization Guide

## Overview

After QEMU boots the guest Linux and you obtain a root shell, you need to manually initialize the MI300X GPU before running any GPU workloads. There are **3 steps**, which must be executed **in order** as root.

All required files (ROM, firmware, kernel modules) are already included in the disk image -- just run the commands below.

## Prerequisites

- `cosim_launch.sh` is running (gem5 + QEMU are connected)
- The guest has booted and you have a root shell
- `modprobe.blacklist=amdgpu` was passed on the kernel command line
  (the launch script does this automatically)

## Quick Reference (Copy-Paste Ready)

```bash
# All 3 steps in one go:
dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128
ln -sf /usr/lib/firmware/amdgpu/mi300_discovery /usr/lib/firmware/amdgpu/ip_discovery.bin
bash /home/gem5/load_amdgpu.sh
```

Or use the automation script (included in the gem5 repo):

```bash
bash /path/to/gem5/scripts/cosim_guest_setup.sh
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
bash /home/gem5/load_amdgpu.sh
```

**What it does**: Manually loads the amdgpu driver and all its dependencies via `insmod` (bypassing `modprobe`).

**Why not use `modprobe`**: The QEMU+KVM environment has limited ACPI support compared to real hardware. Because certain ACPI methods are missing, WMI subsystem initialization fails during `modprobe`. The workaround is:

1. Load the stub module `gem5_wmi.ko`, which provides the missing ACPI symbols
2. Manually `insmod` each dependency in order
3. Load `amdgpu.ko.zst` with specific parameters

**amdgpu module parameters**:

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `ip_block_mask` | `0x6f` | Enable only supported IP blocks |
| `ppfeaturemask` | `0` | Disable power management features |
| `dpm` | `0` | Disable dynamic power management |
| `audio` | `0` | Disable audio (HDMI/DP) |
| `ras_enable` | `0` | Disable RAS (reliability) features |
| `discovery` | `2` | Use firmware file for IP discovery |

**Full insmod sequence** (for reference):

```bash
insmod /home/gem5/gem5_wmi.ko
insmod /lib/modules/$(uname -r)/kernel/drivers/acpi/video.ko.zst
insmod /lib/modules/$(uname -r)/kernel/drivers/i2c/algos/i2c-algo-bit.ko.zst
insmod /lib/modules/$(uname -r)/kernel/drivers/media/rc/rc-core.ko.zst
insmod /lib/modules/$(uname -r)/kernel/drivers/media/cec/core/cec.ko.zst
insmod /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/display/drm_display_helper.ko.zst
insmod /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/drm_suballoc_helper.ko.zst
insmod /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/drm_exec.ko.zst
insmod /lib/modules/$(uname -r)/updates/dkms/amdkcl.ko.zst
insmod /lib/modules/$(uname -r)/updates/dkms/amd-sched.ko.zst
insmod /lib/modules/$(uname -r)/updates/dkms/amdxcp.ko.zst
insmod /lib/modules/$(uname -r)/updates/dkms/amddrm_buddy.ko.zst
insmod /lib/modules/$(uname -r)/updates/dkms/amddrm_exec.ko.zst
insmod /lib/modules/$(uname -r)/updates/dkms/amdttm.ko.zst
insmod /lib/modules/$(uname -r)/updates/dkms/amddrm_ttm_helper.ko.zst
insmod /lib/modules/$(uname -r)/updates/dkms/amdgpu.ko.zst \
    ip_block_mask=0x6f ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

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
| `Unable to locate a BIOS ROM` | Step 1 was not executed, or mi300.rom is missing | Run the dd command; check that `/root/roms/mi300.rom` exists |
| `insmod: ERROR: could not load module` | Kernel version mismatch | Rebuild the disk image with a matching kernel |
| MMIO reads all return zero | gem5 is not connected or has crashed | Check `docker logs gem5-cosim` |
| `probe failed with error -12` | BAR layout mismatch | Rebuild QEMU with the correct BAR5=MMIO layout |
| gem5 crashes with `schedule()` assertion | Timer event overflow | Ensure `disable_rtc_events` and `disable_timer_events` are set |

## File Locations (Inside the Guest Disk Image)

| File | Path | Source |
|------|------|--------|
| VGA BIOS ROM | `/root/roms/mi300.rom` | Built by Packer |
| IP Discovery firmware | `/usr/lib/firmware/amdgpu/mi300_discovery` | Built by Packer |
| WMI stub module | `/home/gem5/gem5_wmi.ko` | Built by Packer |
| Driver loading script | `/home/gem5/load_amdgpu.sh` | `gem5-resources/src/x86-ubuntu-gpu-ml/files/` |
| amdgpu module | `/lib/modules/$(uname -r)/updates/dkms/amdgpu.ko.zst` | ROCm 7.0 DKMS |
