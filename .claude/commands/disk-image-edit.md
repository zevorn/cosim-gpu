---
description: Edit the guest disk image (add files, systemd services, config) using guestmount without sudo. Use when the disk image needs modification without a full packer rebuild.
allowed-tools: Bash, Read, Write, Edit, Glob
argument-hint: "[description of what to add/modify]"
---

# Disk Image Editing Workflow

Modify the cosim guest disk image for: $ARGUMENTS

## Prerequisites

- QEMU must NOT be running (the disk image cannot be mounted while in use)
- `guestmount` must be available (from `libguestfs-tools` package)

```bash
# Verify QEMU is stopped
screen -ls 2>/dev/null | grep qemu && echo "STOP QEMU FIRST" || echo "OK"

# Verify guestmount is available
which guestmount || echo "Install: sudo pacman -S libguestfs / apt install libguestfs-tools"
```

## Disk Image Location

```
gem5-resources/src/x86-ubuntu-gpu-ml/disk-image/x86-ubuntu-rocm70
```

Format: raw, GPT, partition 1 is the root filesystem.

## Mount Workflow

```bash
# Mount (no sudo needed with guestmount + FUSE)
DISK="./gem5-resources/src/x86-ubuntu-gpu-ml/disk-image/x86-ubuntu-rocm70"
MOUNTPOINT="/tmp/cosim-disk"
mkdir -p "$MOUNTPOINT"
guestmount -a "$DISK" -m /dev/sda1 --rw "$MOUNTPOINT"

# Verify
ls "$MOUNTPOINT"/etc/os-release
```

## Common Operations

### Add a systemd service

```bash
# 1. Write the service file
cat > "$MOUNTPOINT/etc/systemd/system/my-service.service" << 'EOF'
[Unit]
Description=My Service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/my-script.sh

[Install]
WantedBy=multi-user.target
EOF

# 2. Write the script
cat > "$MOUNTPOINT/usr/local/bin/my-script.sh" << 'EOF'
#!/bin/bash
echo "Hello from my-service"
EOF
chmod +x "$MOUNTPOINT/usr/local/bin/my-script.sh"

# 3. Enable the service (create symlink)
ln -sf /etc/systemd/system/my-service.service \
       "$MOUNTPOINT/etc/systemd/system/multi-user.target.wants/my-service.service"
```

### Add a file to the guest

```bash
cp /path/to/local/file "$MOUNTPOINT/root/file"
```

### Modify kernel module parameters

```bash
# Create modprobe config
cat > "$MOUNTPOINT/etc/modprobe.d/amdgpu-cosim.conf" << 'EOF'
options amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
EOF
```

### Check existing services

```bash
ls "$MOUNTPOINT/etc/systemd/system/"
ls "$MOUNTPOINT/etc/systemd/system/multi-user.target.wants/"
```

### Check disk image partition layout (if mount fails)

```bash
fdisk -l "$DISK"
# Look for "Start" column of the Linux filesystem partition
# Offset = Start × 512
```

## Unmount

**Always unmount before starting QEMU!**

```bash
guestunmount "$MOUNTPOINT"
# Wait for unmount to complete (guestunmount is async)
sleep 2
ls "$MOUNTPOINT" 2>/dev/null && echo "Still mounted!" || echo "Unmounted OK"
```

## Important Notes

- `guestmount` uses FUSE (userspace filesystem), no sudo needed
- The disk image is ~55 GB raw format; mounting is fast (metadata only)
- Changes are written directly to the raw image file
- `guestunmount` may take a few seconds to flush writes
- If mount fails with "already mounted", check `fusermount -u "$MOUNTPOINT"`
- Back up the disk image before making risky changes (it's 55 GB, so consider snapshots)
- Alternative approach: `sudo mount -o loop,offset=1048576` works if sudo is available
  (offset = partition start sector 2048 * 512 = 1048576)
