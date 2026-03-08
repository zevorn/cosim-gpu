[中文](../zh/gpu-fs-guide.md)

# gem5 MI300X Full-System GPU Simulation Reproduction Guide

Reproduce the full-system GPU simulation of AMD Instinct MI300X on the cosim branch from scratch,
until the `square` test passes.

## Prerequisites

| Requirement | Description |
|---|---|
| Host OS | Linux x86_64 with KVM support (verified on WSL2 6.6.x) |
| Docker | Daemon running, current user in `docker` group |
| KVM | `/dev/kvm` accessible (required for both disk image build and simulation) |
| QEMU | `qemu-system-x86_64` installed (used by Packer to build disk images) |
| Disk space | At least 120 GB free (55G disk image + build intermediates) |
| Tools | `git`, `unzip`, `guestfish` (optional, for disk image verification) |

### Docker Images

| Image | Purpose |
|---|---|
| `ghcr.io/gem5/gpu-fs:latest` | Base image for gem5 runtime container (amd64) |
| `gem5-run:local` | Runtime image built from `scripts/Dockerfile.run` |
| `ghcr.io/gem5/ubuntu-24.04_all-dependencies:v24-0` | gem5 compilation (arm64 only, see note below) |

> **Note:** `ghcr.io/gem5/ubuntu-24.04_all-dependencies:v24-0` is arm64 only.
> On amd64 hosts, use `ghcr.io/gem5/gpu-fs` as the build image or compile natively.
> You can override the default image by setting the `GEM5_BUILD_IMAGE` environment variable.

## Directory Structure

```
/home/zevorn/cosim/
    gem5/                          # gem5 source (cosim branch)
        build/VEGA_X86/gem5.opt    # gem5 binary
        configs/example/
            gem5_library/x86-mi300x-gpu.py   # stdlib config
            gpufs/mi300.py                   # legacy config
        scripts/
            run_mi300x_fs.sh       # orchestration script
            Dockerfile.run         # runtime Docker image
    gem5-resources/                # disk images, kernels, GPU apps
        src/x86-ubuntu-gpu-ml/
            disk-image/x86-ubuntu-rocm70   # 55G raw disk image
            vmlinux-rocm70                 # extracted kernel
        src/gpu/square/            # square test app
    docs/                          # documentation
    qemu/                          # QEMU source (cosim device)
        build/qemu-system-x86_64
```

## Step 1: Build gem5

```bash
cd /home/zevorn/cosim/gem5
./scripts/run_mi300x_fs.sh build-gem5
```

This command runs `scons build/VEGA_X86/gem5.opt` inside Docker.
Output: `build/VEGA_X86/gem5.opt` (approximately 1.1 GB).

Manual build without Docker:

```bash
scons build/VEGA_X86/gem5.opt -j$(nproc)
```

## Step 2: Build QEMU (Optional, Only Required for Cosim Mode)

```bash
./scripts/run_mi300x_fs.sh build-qemu
```

Requires QEMU source at `../qemu/`. Configures with `--target-list=x86_64-softmmu` and builds.
Output: `../qemu/build/qemu-system-x86_64`.

## Step 3: Obtain gem5-resources

```bash
./scripts/run_mi300x_fs.sh build-disk
# If gem5-resources does not exist, it will be cloned automatically, then disk image build begins
```

Or clone manually:

```bash
cd /home/zevorn/cosim
git clone --depth 1 https://github.com/gem5/gem5-resources.git gem5-resources
```

## Step 4: Build the Disk Image

The disk image build uses Packer + QEMU/KVM to install Ubuntu 24.04.2 + ROCm 7.0 +
kernel 6.8.0-79-generic with all required DKMS modules.

### Automated Build (via Orchestration Script)

```bash
./scripts/run_mi300x_fs.sh build-disk
```

### Manual Build

```bash
cd ../gem5-resources/src/x86-ubuntu-gpu-ml

# Download Packer and build
./build.sh -var "qemu_path=/usr/sbin/qemu-system-x86_64"
```

> **Important:** The default `qemu_path` in `x86-ubuntu-gpu-ml.pkr.hcl` is
> `/usr/bin/qemu-system-x86_64`. Some distributions (e.g., Arch) install it at
> `/usr/sbin/qemu-system-x86_64`, which requires overriding with `-var`.

### Build Process Details

1. Boot Ubuntu 24.04.2 ISO via QEMU/KVM for unattended installation
2. Run `scripts/rocm-install.sh`, which performs the following in order:
   - Compile and install the `m5` tool from gem5 source (`/sbin/m5`)
   - Install ROCm 7.0 from `repo.radeon.com/amdgpu/7.0/ubuntu`
   - Install `amdgpu-dkms` (compile DKMS kernel modules)
   - Install kernel `6.8.0-79-generic` and corresponding headers
   - Extract `vmlinux` kernel for gem5 use
   - Compile `gem5_wmi.ko` (ACPI patch module)
   - Install PyTorch (ROCm 6.0 support)
3. Copy GPU BIOS ROM (`mi300.rom`), IP discovery files, and boot scripts into the image
4. Download the extracted kernel from the VM as `vmlinux-rocm70`

### Output

| Artifact | Path | Size |
|---|---|---|
| Disk image | `disk-image/x86-ubuntu-rocm70` | ~55 GB |
| Kernel | `vmlinux-rocm70` | ~64 MB |

### Build Time

Approximately 30-60 minutes, depending on network speed and host performance.

### Verify the Disk Image (Optional)

Use `guestfish` to inspect disk image contents without mounting:

```bash
LIBGUESTFS_BACKEND=direct guestfish --ro \
    -a disk-image/x86-ubuntu-rocm70 -m /dev/sda1 <<'EOF'
echo "=== DKMS modules ==="
ls /lib/modules/6.8.0-79-generic/updates/dkms/
echo "=== ROCm version ==="
cat /opt/rocm/.info/version
echo "=== load_amdgpu.sh ==="
cat /home/gem5/load_amdgpu.sh
echo "=== m5 binary ==="
is-file /sbin/m5
echo "=== gem5_wmi module ==="
is-file /home/gem5/gem5_wmi.ko
EOF
```

Expected DKMS module list (all dependencies for the amdgpu driver):

```
amd-sched.ko.zst
amddrm_buddy.ko.zst
amddrm_exec.ko.zst        # Critical module -- missing in older builds
amddrm_ttm_helper.ko.zst
amdgpu.ko.zst
amdkcl.ko.zst
amdttm.ko.zst
amdxcp.ko.zst
```

## Step 5: Build the GPU Test Application

```bash
./scripts/run_mi300x_fs.sh build-app square
```

Compiles using Docker (`ghcr.io/gem5/gpu-fs`) or local `hipcc`.
Output: `../gem5-resources/src/gpu/square/bin.default/square.default`.

## Step 6: Build the Runtime Docker Image

The gem5 binary is linked against Ubuntu 24.04 libraries and requires a compatible runtime environment:

```bash
cd scripts
docker build -t gem5-run:local -f Dockerfile.run .
```

## Step 7: Run the Simulation

### stdlib Configuration (Recommended)

```bash
./scripts/run_mi300x_fs.sh run \
    ../gem5-resources/src/gpu/square/bin.default/square.default
```

> **Important: The `--app` parameter must be specified.** Without it, `readfile_contents` is
> an empty string `""`, which Python evaluates as falsy, so `KernelDiskWorkload._set_readfile_contents`
> is never called, and the amdgpu driver in the guest is never loaded.

### Legacy Configuration

```bash
./scripts/run_mi300x_fs.sh run-legacy \
    ../gem5-resources/src/gpu/square/bin.default/square.default
```

### Simulation Process Details

1. **KVM fast-boot phase** (~2-5 minutes): gem5 uses KVM to fast-forward Linux boot.
   Guest kernel boots, systemd initializes, and auto-login as root occurs.
2. **readfile execution**: The guest runs `/home/gem5/run_gem5_app.sh` via `.bashrc`,
   which calls `m5 readfile` to retrieve the host-injected script.
3. **Driver loading**: The script writes the GPU BIOS ROM to `/dev/mem`, creates symlinks
   for IP discovery files, then runs `load_amdgpu.sh` to insmod all DKMS modules in dependency order.
4. **GPU application execution**: The script decodes the base64-encoded GPU binary, runs it,
   then calls `m5 exit` to end the simulation.

### Monitoring Output

Guest serial console output is written to `m5out/board.pc.com_1.device`:

```bash
tail -f m5out/board.pc.com_1.device
```

### Expected Output from the square Test

```
3+0 records in
3+0 records out
3072 bytes (3.1 kB, 3.0 KiB) copied, ...
info: running on device AMD Instinct MI300X
info: allocate host and device mem (  7.63 MB)
info: launch 'vector_square' kernel
info: check result
PASSED!
```

## Troubleshooting

### `Failed to init DRM client: -13` Followed by Kernel Panic

**Root cause:** The disk image is missing the `amddrm_exec.ko.zst` DKMS module. Without this module,
the amdgpu TTM memory manager fails to initialize, `drm_dev_enter()` finds the device in an
"unplugged" state, and returns `-EACCES` (-13). The subsequent cleanup path triggers a NULL pointer
dereference in `ttm_resource_move_to_lru_tail`.

**Fix:** Rebuild the disk image using the latest `gem5-resources` (`origin/stable` branch).
The updated `rocm-install.sh` installs kernel `6.8.0-79-generic`, which fully matches
the ROCm 7.0 DKMS packages and includes all required modules.

**Verification:** Use `guestfish` to confirm that `amddrm_exec.ko.zst` exists in
`/lib/modules/6.8.0-79-generic/updates/dkms/`.

### `Can't open /dev/gem5_bridge: No such file or directory`

**Harmless warning.** The `m5` tool first attempts the `gem5_bridge` device driver, and falls back to
address-mapped MMIO mode (available when running as root) on failure. The readfile mechanism
still works correctly.

### Packer Build Fails: `output_directory already exists`

A leftover `disk-image/` directory from a previous build blocks Packer:

```bash
mv disk-image disk-image-old
# Then re-run the build
```

### Packer Build Fails: git clone Fails Inside the VM

Network issues inside the QEMU VM can cause `git clone` to fail. The `rocm-install.sh` script has
built-in retry logic (3 attempts, 10-second intervals). If it still fails, check the host network
connectivity and DNS resolution.

### GPU Driver Does Not Load When `--app` Is Not Specified

When running with `x86-mi300x-gpu.py` without the `--app` parameter, `readfile_contents` is
an empty string `""`. Python's truthiness check `elif readfile_contents:` evaluates to `False`,
so `_set_readfile_contents` is never called and the readfile is not written. The guest's
`run_gem5_app.sh` receives an empty file from `m5 readfile` and exits immediately.

**Solution:** Always specify the `--app` parameter when running GPU simulations.

### DRAM Capacity Warning

```
DRAM device capacity (16384 Mbytes) does not match the address range assigned (8192 Mbytes)
```

This is a configuration warning from the gem5 memory system and does not affect simulation correctness.

## Key File Reference

| File | Purpose |
|---|---|
| `scripts/run_mi300x_fs.sh` | Main orchestration script |
| `scripts/Dockerfile.run` | Runtime Docker image definition |
| `configs/example/gem5_library/x86-mi300x-gpu.py` | stdlib simulation config |
| `configs/example/gpufs/mi300.py` | Legacy simulation config |
| `src/python/gem5/prebuilt/viper/board.py` | ViperBoard: readfile injection, driver loading |
| `src/python/gem5/components/devices/gpus/amdgpu.py` | MI300X device definition |
| `src/dev/amdgpu/amdgpu_device.cc` | GPU device model core (modified in cosim branch) |
| `../gem5-resources/src/x86-ubuntu-gpu-ml/scripts/rocm-install.sh` | Disk image configuration script |
| `../gem5-resources/src/x86-ubuntu-gpu-ml/files/load_amdgpu.sh` | Guest-side driver loading script |
| `../gem5-resources/src/x86-ubuntu-gpu-ml/x86-ubuntu-gpu-ml.pkr.hcl` | Packer configuration |

## Version Matrix

| Component | Version |
|---|---|
| Guest OS | Ubuntu 24.04.2 LTS |
| Guest kernel | 6.8.0-79-generic |
| ROCm | 7.0.0 |
| amdgpu DKMS | Matches ROCm 7.0 |
| gem5 build target | VEGA_X86 |
| GPU device | MI300X (DeviceID 0x74A1) |
| Coherence protocol | GPU_VIPER |
