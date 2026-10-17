---
name: cosim-gpu-disk-image-edit
description: Use when the guest disk image needs modification without a full rebuild. Mount with guestmount, add files, systemd services, kernel module config.
---

# Cosim Disk Image Edit

Modify the cosim guest disk image without rebuilding.

## Prerequisites

- QEMU must NOT be running (disk image cannot be mounted while in use)
- `guestmount` must be available (`libguestfs-tools` package)

```bash
pgrep -af 'qemu-system-x86_64|cosim_launch.sh|run_cosim_tests.sh' && echo "STOP COSIM FIRST" || echo "OK"
find /tmp -maxdepth 1 -type d -name '*qemu-cosim*.session' -print
which guestmount || echo "Install: apt install libguestfs-tools"
```

## Disk image location

```
build/images/guest/ubuntu/24.04/x86_64/rocm7_0/disk
```

Format: QCOW2, based on the pinned Ubuntu 24.04 cloud disk image.

## Mount

```bash
DISK="./build/images/guest/ubuntu/24.04/x86_64/rocm7_0/disk"
MOUNTPOINT="/tmp/cosim-disk"
mkdir -p "$MOUNTPOINT"
guestmount -a "$DISK" -i --rw "$MOUNTPOINT"
```

## Edit scope

Supported edit classes:

- Add or replace files under the guest filesystem.
- Add or update systemd units and matching enablement symlinks.
- Add or update kernel module configuration under `/etc/modprobe.d/`.
- Install ROCm runtime debug components through repository scripts when the task is runtime debugging.
- Inspect disk layout with `qemu-img info "$DISK"` if `guestmount` cannot inspect the image.

Keep the concrete file contents in the task artifact or source patch. Do not embed large service templates or generated scripts in the skill itself.

## Unmount

Always unmount before starting QEMU:

```bash
guestunmount "$MOUNTPOINT"
sleep 2
ls "$MOUNTPOINT" 2>/dev/null && echo "Still mounted!" || echo "OK"
```

## Notes

- `guestmount` uses FUSE — no sudo needed
- Changes write directly to the QCOW2 image file
- Back up the disk image before risky changes (56 GB virtual capacity)
