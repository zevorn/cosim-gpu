[中文](../zh/getting-started.md)

# Getting Started

A quick-start guide for newcomers to the QEMU + gem5 MI300X co-simulation project.
From building the components to running your first HIP GPU compute test.

## Overview

```
+---------------------------------+     +------------------------------+
|  QEMU (Q35 + KVM)              |     |  gem5 (inside Docker)        |
|  +---------------------------+  |     |  +------------------------+  |
|  | Guest Linux (Ubuntu 24.04)|  |     |  | MI300X GPU Model       |  |
|  | amdgpu driver             |  |     |  | - Shader + CU          |  |
|  | ROCm 7.0 / HIP runtime   |  |     |  | - PM4 / SDMA Engines   |  |
|  +-----------+---------------+  |     |  | - Ruby Cache Hierarchy |  |
|              | MMIO/Doorbell    |     |  +----------+-------------+  |
|  +-----------v---------------+  |     |  +----------v-------------+  |
|  | vfio-user-pci (built-in)  |<--------->| MI300XVfioUser Server  |  |
|  +---------------------------+  |vfio-|  +------------------------+  |
|                                 |user |                              |
+---------------------------------+     +------------------------------+
        |                                         |
        v                                         v
  /dev/shm/cosim-guest-ram              /dev/shm/mi300x-vram
  (Guest Physical Memory, Shared)       (GPU VRAM, Shared)
```

- **QEMU** handles CPU execution, Linux kernel boot, PCIe enumeration, and amdgpu driver loading.
- **gem5** models the MI300X GPU: Shader, Compute Units, Cache hierarchy, and DMA engines.
- They communicate via the **vfio-user protocol** over a Unix domain socket. QEMU uses its built-in `vfio-user-pci` device; gem5 runs `MI300XVfioUser` as the server.
- Guest RAM and GPU VRAM are shared via **shared memory** under `/dev/shm/`.

For a deeper dive into the memory architecture and BAR layout, see [Architecture](architecture.md#memory-sharing-architecture).

## Prerequisites

| Requirement | Description |
|---|---|
| Host OS | Linux x86_64 with KVM support (verified on WSL2 6.6.x) |
| Docker | Daemon running, current user in `docker` group |
| KVM | `/dev/kvm` accessible |
| QEMU | `qemu-system-x86_64` installed (used by Packer during disk image build) |
| Disk Space | At least 120 GB (55G disk image + build artifacts) |
| Memory | 16 GB or more recommended (gem5 compilation and runtime are memory-intensive) |
| Tools | `git`, `screen`, `unzip` |

## Building gem5 and QEMU

### Build the Runtime Docker Image

Before building gem5, create the runtime Docker image:

```bash
cd scripts
docker build -t gem5-run:local -f Dockerfile.run .
```

This image is based on `ghcr.io/gem5/gpu-fs` with Python 3.12 support added.

### Build gem5

The gem5 binary links against Ubuntu 24.04 libraries and must be compiled in a compatible environment.

> **Note:** The vfio-user backend requires `libjson-c-dev` (build-time) and `libjson-c5` (runtime). The `gem5-run:local` image already includes this dependency.

**Option 1: Orchestration Script**

```bash
./scripts/run_mi300x_fs.sh build-gem5
```

**Option 2: Build inside Docker (Manual)**

```bash
cd /home/zevorn/cosim/gem5

docker run --rm \
    -v "$(pwd):/gem5" -w /gem5 \
    gem5-run:local \
    scons build/VEGA_X86/gem5.opt -j4
```

> **Tip:** Reduce parallelism (`-j1` or `-j2`) if OOM-killed during linking.

Output: `build/VEGA_X86/gem5.opt` (approximately 1.1 GB).

### Build QEMU

With the vfio-user backend, a **stock QEMU 10.0+** build works out of the box -- the `vfio-user-pci` device is built-in and no custom QEMU code is needed.

```bash
mkdir -p qemu-build && cd qemu-build
/path/to/qemu/configure --target-list=x86_64-softmmu
make -j$(nproc)
```

Or via the orchestration script:

```bash
./scripts/run_mi300x_fs.sh build-qemu
```

Output: `qemu-system-x86_64`.

> **Legacy backend:** If using `--cosim-backend=legacy`, the `cosim/qemu/` source containing the `mi300x-gem5` device is required. The build procedure is the same, but you must use the cosim branch QEMU source.

## Building the Disk Image

The disk image contains Ubuntu 24.04 + ROCm 7.0 + kernel 6.8.0-79-generic with amdgpu DKMS modules.

### Automated Build

```bash
./scripts/run_mi300x_fs.sh build-disk
```

If `gem5-resources` does not exist, it will be cloned automatically before the build begins.

### Manual Build

```bash
cd ../gem5-resources/src/x86-ubuntu-gpu-ml
./build.sh -var "qemu_path=/usr/sbin/qemu-system-x86_64"
```

> On Arch Linux the QEMU path is `/usr/sbin/`; other distributions may use `/usr/bin/`.

### Output

| Artifact | Path | Size |
|---|---|---|
| Disk Image | `gem5-resources/src/x86-ubuntu-gpu-ml/disk-image/x86-ubuntu-rocm70` | ~55 GB |
| Kernel | `gem5-resources/src/x86-ubuntu-gpu-ml/vmlinux-rocm70` | ~64 MB |

> **Tip (China network):** If the build hangs on package downloads, apply the China mirror patch to speed up `apt` inside the VM. See [Reference §7](reference.md#7-china-mirror-configuration) for instructions.

## Launching Co-simulation

### Option 1: One-click Launch Script (Recommended)

```bash
./scripts/cosim_launch.sh
```

This script automatically starts the gem5 container, waits for readiness, fixes permissions, starts QEMU, and enters the serial console in interactive mode.

Common options:

```bash
./scripts/cosim_launch.sh --gem5-debug MI300XCosim   # enable gem5 debug output
./scripts/cosim_launch.sh --vram-size 32GiB          # custom VRAM size
./scripts/cosim_launch.sh --num-cus 80               # custom CU count
./scripts/cosim_launch.sh --cosim-backend=legacy     # use legacy socket backend
```

### Option 2: Manual Step-by-step Launch

#### Start gem5 (Docker Container)

```bash
docker run -d --name gem5-cosim \
    -v /home/zevorn/cosim/gem5:/gem5 \
    -v /tmp:/tmp \
    -v /dev/shm:/dev/shm \
    -w /gem5 \
    -e PYTHONPATH=/usr/lib/python3.12/lib-dynload \
    gem5-run:local \
    /gem5/build/VEGA_X86/gem5.opt --listener-mode=on \
    /gem5/configs/example/gpufs/mi300_cosim.py \
    --socket-path=/tmp/gem5-mi300x.sock \
    --shmem-path=/mi300x-vram \
    --shmem-host-path=/cosim-guest-ram \
    --dgpu-mem-size=16GiB \
    --num-compute-units=40 \
    --mem-size=8G
```

#### Wait for gem5 to be Ready

```bash
docker logs -f gem5-cosim
```

The following output indicates readiness:

```
============================================================
gem5 MI300X co-simulation server ready
  Socket:     /tmp/gem5-mi300x.sock
  VRAM SHM:   /mi300x-vram
  Host SHM:   /cosim-guest-ram
  VRAM size:  16GiB
  Host RAM:   8GiB
  CUs:        40
Waiting for QEMU to connect...
============================================================
```

#### Fix Permissions

Files created by Docker are owned by root; permissions must be fixed so QEMU can access them:

```bash
docker exec gem5-cosim chmod 777 /tmp/gem5-mi300x.sock
docker exec gem5-cosim chmod 666 /dev/shm/mi300x-vram
```

#### Start QEMU

```bash
qemu-system-x86_64 \
    -machine q35 -enable-kvm -cpu host \
    -m 8G -smp 4 \
    -object memory-backend-file,id=mem0,size=8G,mem-path=/dev/shm/cosim-guest-ram,share=on \
    -numa node,memdev=mem0 \
    -kernel /home/zevorn/cosim/gem5-resources/src/x86-ubuntu-gpu-ml/vmlinux-rocm70 \
    -append "console=ttyS0,115200 root=/dev/vda1 modprobe.blacklist=amdgpu" \
    -drive file=/home/zevorn/cosim/gem5-resources/src/x86-ubuntu-gpu-ml/disk-image/x86-ubuntu-rocm70,format=raw,if=virtio \
    -device 'vfio-user-pci,socket={"type":"unix","path":"/tmp/gem5-mi300x.sock"}' \
    -nographic -no-reboot
```

> **Important:** The kernel command line must include `modprobe.blacklist=amdgpu` to prevent auto-loading the driver before the VGA ROM is written to shared memory. The `cosim-gpu-setup.service` handles the correct initialization order.

#### SSH Access to Guest

The `cosim_launch.sh` script enables user networking and SSH port forwarding by default. After configuring a network interface inside the guest with `netplan`, connect from the host:

```bash
ssh -p 2222 gem5@localhost
# Default password: 12345
```

### Shutting Down

```bash
# In the QEMU serial console:
poweroff
# Or force quit: Ctrl-A X

# Clean up Docker container and shared memory:
docker rm -f gem5-cosim
rm -f /dev/shm/mi300x-vram /dev/shm/cosim-guest-ram
rm -f /tmp/gem5-mi300x.sock
```

> When using `cosim_launch.sh`, cleanup is performed automatically after exiting QEMU.

## GPU Driver Initialization

The MI300X GPU driver can be loaded **automatically** or **manually** after the QEMU guest boots. All required files (ROM, firmware, kernel modules) are already included in the disk image.

### Automatic Loading (Default)

The disk image ships with `cosim-gpu-setup.service`, which runs at boot and performs:

1. `dd` the VGA ROM to `0xC0000` (required for gem5's `readROM()` via shared memory)
2. Symlink IP discovery firmware
3. `modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2`

The service completes in ~40 seconds. After guest login, the GPU is ready:

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

### Manual Loading

If the systemd service is not installed, or you need to reload the driver, run these commands manually after guest boot.

**Prerequisites:** `cosim_launch.sh` is running (gem5 + QEMU are connected), the guest has booted with a root shell, and `modprobe.blacklist=amdgpu` was passed on the kernel command line.

**Quick reference (copy-paste ready):**

```bash
dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128
ln -sf /usr/lib/firmware/amdgpu/mi300_discovery /usr/lib/firmware/amdgpu/ip_discovery.bin
modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

### Detailed Steps

#### Step 1: Load the VGA BIOS ROM

```bash
dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128
```

Writes the MI300X VBIOS ROM image to the legacy VGA ROM region at physical address `0xC0000` (768 KB). The amdgpu driver reads the VBIOS from this address during initialization. Without the ROM, the driver will report `"Unable to locate a BIOS ROM"`.

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `if`      | `/root/roms/mi300.rom` | ROM binary file (in the disk image) |
| `of`      | `/dev/mem`             | Physical memory device |
| `bs`      | `1k`                   | Block size = 1024 bytes |
| `seek`    | `768`                  | Seek to 768 x 1024 = `0xC0000` |
| `count`   | `128`                  | Write 128 x 1024 = 128 KB |

#### Step 2: Symlink the IP Discovery Firmware

```bash
ln -sf /usr/lib/firmware/amdgpu/mi300_discovery \
       /usr/lib/firmware/amdgpu/ip_discovery.bin
```

Points the driver's IP discovery firmware path to the MI300X-specific discovery binary. The `discovery=2` mode reads GPU IP block information from this firmware file rather than from GPU ROM/registers.

#### Step 3: Load the amdgpu Kernel Module

```bash
modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

Key parameters:

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `ip_block_mask` | `0x67` | Disable PSP (bit 3) and SMU (bit 4); cosim does not model these |
| `ppfeaturemask` | `0` | Disable PowerPlay features; cosim has no power management hardware |
| `dpm` | `0` | Disable Dynamic Power Management |
| `audio` | `0` | Disable audio; no HDMI/DP audio in cosim |
| `ras_enable` | `0` | Disable RAS -- prevents NULL deref when VBIOS is minimal |
| `discovery` | `2` | Use firmware file for IP discovery |

> **Warning**: Using `ip_block_mask=0x6f` (only disables SMU) will cause PSP firmware load failure and kernel panic. Always use `0x67`.

> **Warning**: The `dd` step (Step 1) is **mandatory** before `modprobe`. Without it, the driver's BIOS discovery chain fails, resulting in a NULL pointer crash in `amdgpu_atom_parse_data_header`.

### Verification

```bash
# Check dmesg for amdgpu initialization
dmesg | grep -i amdgpu | tail -20

# Check PCI device
lspci | grep -i amd

# Verify device recognition and capabilities
rocm-smi
rocminfo | head -40
```

Expected output:

```
# rocm-smi
GPU[0]  : Device Name: 0x74a0
GPU[0]  : Partition: SPX

# rocminfo
Name:                    gfx942
Compute Unit:            320
KERNEL_DISPATCH capable
```

> Approximately 80 fence fallback timer warnings may appear during loading. This is normal -- the DRM subsystem uses a polling-mode timeout fallback when probing ring buffers.

### File Locations (Inside the Guest Disk Image)

| File | Path |
|------|------|
| VGA BIOS ROM | `/root/roms/mi300.rom` |
| IP Discovery firmware | `/usr/lib/firmware/amdgpu/mi300_discovery` |
| Auto-load service | `/etc/systemd/system/cosim-gpu-setup.service` |
| Auto-load script | `/usr/local/bin/cosim-gpu-setup.sh` |
| amdgpu module | `/lib/modules/$(uname -r)/updates/dkms/amdgpu.ko.zst` |

## Running HIP Tests

### Compile a HIP Test Program

Write a simple vector addition program inside the guest:

```bash
cat > /tmp/vec_add.cpp << 'EOF'
#include <hip/hip_runtime.h>
#include <cstdio>

__global__ void vec_add(int *a, int *b, int *c, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}

int main() {
    const int N = 4;
    int ha[N] = {1, 2, 3, 4};
    int hb[N] = {10, 20, 30, 40};
    int hc[N] = {0};

    int *da, *db, *dc;
    hipMalloc(&da, N * sizeof(int));
    hipMalloc(&db, N * sizeof(int));
    hipMalloc(&dc, N * sizeof(int));

    hipMemcpy(da, ha, N * sizeof(int), hipMemcpyHostToDevice);
    hipMemcpy(db, hb, N * sizeof(int), hipMemcpyHostToDevice);

    vec_add<<<1, N>>>(da, db, dc, N);

    hipMemcpy(hc, dc, N * sizeof(int), hipMemcpyDeviceToHost);

    printf("Result: %d %d %d %d\n", hc[0], hc[1], hc[2], hc[3]);

    bool pass = (hc[0]==11 && hc[1]==22 && hc[2]==33 && hc[3]==44);
    printf("%s\n", pass ? "PASSED!" : "FAILED!");

    hipFree(da); hipFree(db); hipFree(dc);
    return pass ? 0 : 1;
}
EOF
```

Compile and run:

```bash
# Compile (gfx942 = MI300X architecture)
/opt/rocm/bin/hipcc --offload-arch=gfx942 -o /tmp/vec_add /tmp/vec_add.cpp

# Run
/tmp/vec_add
```

### Expected Output

```
Result: 11 22 33 44
PASSED!
```

### Using the square Test from gem5-resources

You can also use the `square` test program included in gem5-resources. Compile it on the host:

```bash
./scripts/run_mi300x_fs.sh build-app square
```

Then copy the compiled binary into the guest (via `scp -P 2222` or by mounting the disk image) and run it:

```bash
./square.default
```

Expected output:

```
info: running on device AMD Instinct MI300X
info: allocate host and device mem (  7.63 MB)
info: launch 'vector_square' kernel
info: check result
PASSED!
```

## Appendix: Standalone gem5 GPU FS Simulation

The co-simulation workflow described above uses QEMU for fast KVM-accelerated boot with gem5 providing only the GPU model. An alternative workflow runs **everything inside gem5** (CPU + GPU), with no QEMU involved. This is the standard gem5 full-system GPU simulation.

### Key Differences

| Aspect | Co-simulation (QEMU + gem5) | Standalone gem5 |
|---|---|---|
| CPU execution | KVM (near-native speed) | gem5 atomic/timing model |
| Boot time | ~30 seconds | ~2-5 minutes (KVM fast-forward) |
| GPU model | gem5 MI300X via vfio-user | gem5 MI300X (same model) |
| Driver loading | systemd service or manual `modprobe` | Automated via `m5 readfile` |
| Use case | Driver development, interactive debugging | Microarchitecture research, benchmarking |

### Quick Start

**1. Build gem5 and disk image** (same as the co-simulation steps above).

**2. Build a GPU test application:**

```bash
./scripts/run_mi300x_fs.sh build-app square
```

**3. Run the simulation:**

```bash
./scripts/run_mi300x_fs.sh run \
    ../gem5-resources/src/gpu/square/bin.default/square.default
```

> **Important:** The `--app` parameter must always be specified. Without it, the driver is never loaded inside the guest.

**4. Monitor output:**

```bash
tail -f m5out/board.pc.com_1.device
```

The simulation uses KVM to fast-forward through Linux boot, then automatically loads the GPU driver and runs the specified application. The guest calls `m5 exit` when the test completes.

For full details on the standalone workflow, including legacy configuration, disk image verification with `guestfish`, and build process internals, see the gem5 documentation for details.

## Quick Troubleshooting

The five most common issues and their fixes:

| Symptom | Cause | Fix |
|---------|-------|-----|
| gem5 container exits immediately | `gem5.opt` not compiled, wrong path, or Python import failure | Run `docker logs gem5-cosim` to see the error |
| `Failed to connect to /tmp/gem5-mi300x.sock` | gem5 not ready or socket permissions wrong | Wait for "Waiting for QEMU to connect" in gem5 logs; run `chmod 777` on the socket |
| NULL deref crash at `amdgpu_atom_parse_data_header` | VGA ROM was not written before `modprobe` | Run `dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128` before loading the driver |
| PSP GPU reset kernel panic | Wrong `ip_block_mask` (e.g., `0x6f` instead of `0x67`) | Always use `ip_block_mask=0x67` to disable both PSP and SMU |
| `hipcc` error: cannot find ROCm device library | ROCm not installed or wrong arch flag | Verify `/opt/rocm/lib/` exists; use `--offload-arch=gfx942` |

For the complete troubleshooting table and debugging techniques, see [Reference §4](reference.md#4-known-issues-and-pitfalls).
