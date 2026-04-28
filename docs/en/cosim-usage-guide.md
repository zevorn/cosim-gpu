[中文](../zh/cosim-usage-guide.md)

# QEMU + gem5 MI300X Co-simulation Usage Guide

A complete workflow from compilation to running HIP GPU compute.

## Architecture Overview

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

- **QEMU** is responsible for: CPU execution, Linux kernel boot, PCIe enumeration, amdgpu driver loading
- **gem5** is responsible for: MI300X GPU compute model (Shader, CU, Cache, DMA engines)
- They communicate via the **vfio-user protocol** (over a Unix domain socket). QEMU uses its built-in `vfio-user-pci` device, while gem5 runs `MI300XVfioUser` as a vfio-user server, transparently handling MMIO / Doorbell / PCI Config accesses. Data is shared via **shared memory**

## Prerequisites

| Requirement | Description |
|---|---|
| Host OS | Linux x86_64 with KVM support (verified on WSL2 6.6.x) |
| Docker | Daemon running, current user in `docker` group |
| KVM | `/dev/kvm` accessible |
| Disk Space | At least 120 GB (55G disk image + build artifacts) |
| Memory | 16 GB or more recommended (gem5 compilation and runtime are memory-intensive) |
| Tools | `git`, `screen`, `unzip` |

## Directory Structure

```
/home/zevorn/cosim/
    gem5/                              # gem5 source (cosim branch)
        build/VEGA_X86/gem5.opt        # gem5 binary
        configs/example/gpufs/
            mi300_cosim.py             # cosim config script
        scripts/
            run_mi300x_fs.sh           # orchestration script
            cosim_launch.sh            # cosim one-click launch script
            Dockerfile.run             # runtime Docker image
    gem5-resources/                    # disk images, kernels, GPU apps
        src/x86-ubuntu-gpu-ml/
            disk-image/x86-ubuntu-rocm70   # 55G raw disk image
            vmlinux-rocm70                 # kernel
    docs/                              # documentation
    qemu/                              # QEMU source (only needed for legacy backend)
        build/qemu-system-x86_64       # QEMU binary
```

---

## Step 1: Build gem5

The gem5 binary links against Ubuntu 24.04 libraries and must be compiled in a compatible environment.

> **Note:** The vfio-user backend requires `libjson-c-dev` (build-time) and `libjson-c5` (runtime). The `ghcr.io/gem5/gpu-fs:latest` image already includes this dependency. If building directly on the host, install `libjson-c-dev` first.

### Option 1: Build inside Docker (Recommended)

```bash
cd /home/zevorn/cosim/gem5

# Build using the gpu-fs image (amd64, includes all dependencies)
docker run --rm \
    -v "$(pwd):/gem5" -w /gem5 \
    gem5-run:local \
    scons build/VEGA_X86/gem5.opt -j4
```

> **Note:** Reduce parallelism (`-j1` or `-j2`) if running out of memory. Using the gold linker reduces memory usage during the linking stage.

### Option 2: Orchestration Script

```bash
./scripts/run_mi300x_fs.sh build-gem5
```

Output: `build/VEGA_X86/gem5.opt` (approximately 1.1 GB).

### Build the Runtime Docker Image

```bash
cd scripts
docker build -t gem5-run:local -f Dockerfile.run .
```

This image is based on `ghcr.io/gem5/gpu-fs` with Python 3.12 support added, used for running gem5.

---

## Step 2: Build QEMU

With the vfio-user backend, a **stock QEMU 10.0+** build works out of the box (the `vfio-user-pci` device is built-in) -- no custom QEMU code is needed. Standard build:

```bash
# Any QEMU 10.0+ source tree works
mkdir -p qemu-build && cd qemu-build
/path/to/qemu/configure --target-list=x86_64-softmmu
make -j$(nproc)
```

Output: `qemu-system-x86_64`.

> **Legacy backend:** If using `--cosim-backend=legacy`, the `cosim/qemu/` source containing the `mi300x-gem5` device is required. The build procedure is the same, but you must use the cosim branch QEMU source.

Alternatively, via the orchestration script:

```bash
cd /home/zevorn/cosim/gem5
./scripts/run_mi300x_fs.sh build-qemu
```

---

## Step 3: Prepare the Disk Image and Kernel

The disk image contains Ubuntu 24.04 + ROCm 7.0 + kernel 6.8.0-79-generic with amdgpu DKMS modules.

### Automated Build

```bash
./scripts/run_mi300x_fs.sh build-disk
```

### Manual Build

```bash
cd ../gem5-resources/src/x86-ubuntu-gpu-ml
./build.sh -var "qemu_path=/usr/sbin/qemu-system-x86_64"
```

> On Arch Linux the QEMU path is `/usr/sbin/`, other distributions may use `/usr/bin/`.

### Output

| Artifact | Path | Size |
|---|---|---|
| Disk Image | `../gem5-resources/src/x86-ubuntu-gpu-ml/disk-image/x86-ubuntu-rocm70` | ~55 GB |
| Kernel | `../gem5-resources/src/x86-ubuntu-gpu-ml/vmlinux-rocm70` | ~64 MB |

---

## Step 4: Launch cosim

### Option 1: One-click Launch Script (Recommended)

```bash
cd /home/zevorn/cosim/gem5
./scripts/cosim_launch.sh
```

This script automatically performs all the following steps (starts the gem5 container, waits for readiness, fixes permissions, starts QEMU), and enters the QEMU serial console in interactive mode.

Available options:

```bash
./scripts/cosim_launch.sh --help
./scripts/cosim_launch.sh --gem5-debug MI300XCosim   # enable gem5 debug output
./scripts/cosim_launch.sh --vram-size 32GiB          # custom VRAM size
./scripts/cosim_launch.sh --num-cus 80               # custom CU count
./scripts/cosim_launch.sh --cosim-backend=vfio-user  # use vfio-user backend (default)
./scripts/cosim_launch.sh --cosim-backend=legacy     # use legacy custom socket backend
```

### Option 2: Manual Step-by-step Launch

#### 4.1 Start gem5 (Docker Container)

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

#### 4.2 Wait for gem5 to be Ready

```bash
# Watch gem5 logs, wait for "listening" or "ready"
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

#### 4.3 Fix Permissions

Files created by Docker are owned by root; permissions must be fixed so QEMU can access them:

```bash
docker exec gem5-cosim chmod 777 /tmp/gem5-mi300x.sock
docker exec gem5-cosim chmod 666 /dev/shm/mi300x-vram
```

#### 4.4 Start QEMU

```bash
# Foreground interactive mode (vfio-user backend, stock QEMU 10.0+)
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

> **Important:** The kernel command line must include `modprobe.blacklist=amdgpu` to prevent the PCI subsystem from auto-loading the driver before the VGA ROM is written to shared memory. The `cosim-gpu-setup.service` handles the correct initialization order (dd ROM → modprobe).
>
> **Note:** With the vfio-user backend, there is no need to specify `shmem-path` or `vram-size` on the QEMU side. Shared memory is created and managed by the `MI300XVfioUser` server in gem5.

Or run in background screen mode:

```bash
screen -dmS qemu-cosim -L -Logfile /tmp/qemu-cosim-screen.log \
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

# Attach to the screen session to view serial output
screen -r qemu-cosim
# Detach from screen: Ctrl-A D
```

#### 4.5 SSH Access to Guest

The `cosim_launch.sh` script enables user networking and SSH port forwarding by default (`-netdev user,id=net0,hostfwd=tcp::2222-:22` + `virtio-net-pci`). To use SSH access to the guest, configure networking inside the guest first.

**1. Identify the network interface name:**

```bash
ip a
```

Look for the virtio NIC interface (e.g., `enp0s2`). The exact name may vary depending on the PCI topology.

**2. Configure netplan:**

Edit `/etc/netplan/50-cloud-init.yaml`:

```yaml
network:
  version: 2
  ethernets:
    enp0s2:
      dhcp4: true
```

> **Note:** Replace `enp0s2` with the actual interface name from the `ip a` output.

**3. Apply the configuration:**

```bash
netplan apply
```

**4. SSH from the host:**

Open another terminal on the host and connect:

```bash
ssh -p 2222 gem5@localhost
```

Default password: `12345`.

> **Tip:** SSH access is much more convenient than the QEMU serial console for interactive use, file transfers (`scp -P 2222`), and running multiple sessions.

---

## Step 5: Load the GPU Driver

After the guest Linux finishes booting (auto-login as root), run the following commands to load the amdgpu driver.

### Option 1: Automatic Loading (Default)

The disk image includes `cosim-gpu-setup.service` which runs at boot:

1. Writes VGA ROM to `0xC0000` via `dd` (required for gem5 `readROM()`)
2. Symlinks IP discovery firmware
3. Runs `modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2`

The service completes in ~40 seconds. After login, verify with `rocm-smi`.

### Option 2: Manual Loading

```bash
# 1. Load VGA ROM (REQUIRED before modprobe)
dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128

# 2. Symlink the IP discovery firmware
ln -sf /usr/lib/firmware/amdgpu/mi300_discovery \
       /usr/lib/firmware/amdgpu/ip_discovery.bin

# 3. Load the amdgpu driver
modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

> **Key parameter notes:**
> - `ip_block_mask=0x67` (binary 0110_0111) enables GMC, IH, DCN, GFX, SDMA, VCN, and disables PSP and SMU
> - Using an incorrect mask (e.g., 0x6f) will cause PSP initialization to trigger a GPU reset, resulting in a kernel panic
> - `ras_enable=0` is required to prevent a NULL pointer crash in `amdgpu_atom_parse_data_header` (the 3KB cosim ROM has minimal ATOMBIOS data)
> - The `dd` step is **mandatory** -- without it, the driver's BIOS discovery chain fails and `atom_context` is NULL

### Verify Driver Loading

```bash
# Check dmesg - should see "amdgpu: DRM initialized" and "7 XCP partitions"
dmesg | grep -i amdgpu | tail -20

# Verify device recognition
rocm-smi

# Verify GPU capabilities
rocminfo | head -40
```

Expected output:

```
# rocm-smi output
GPU[0]  : Device Name: 0x74a0
GPU[0]  : Partition: SPX

# rocminfo output
Name:                    gfx942
Compute Unit:            320
KERNEL_DISPATCH capable
```

> Approximately 80 fence fallback timer warnings may appear during the loading process. This is normal -- the DRM subsystem uses a polling-mode timeout fallback mechanism when probing all ring buffers.

---

## Step 6: Run GPU Compute Tests

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

You can also use the square test program included in gem5-resources. First compile it on the host:

```bash
cd /home/zevorn/cosim/gem5
./scripts/run_mi300x_fs.sh build-app square
```

Then copy the compiled binary into the guest (via scp or by directly mounting the disk image) and run it inside the guest:

```bash
./square.default
```

---

## Shutting Down cosim

### In the QEMU Serial Console

```
# Normal shutdown
poweroff

# Or force quit QEMU
Ctrl-A X
```

### Clean Up Docker Container and Shared Memory

```bash
docker rm -f gem5-cosim
rm -f /dev/shm/mi300x-vram /dev/shm/cosim-guest-ram
rm -f /tmp/gem5-mi300x.sock
```

> When using `cosim_launch.sh`, cleanup is performed automatically after exiting QEMU.

---

## Troubleshooting

### gem5 Container Exits Immediately After Starting

```bash
docker logs gem5-cosim
```

Common causes:
- `gem5.opt` not compiled or incorrect path
- Python module import failure (check PYTHONPATH)
- Shared memory creation permission issues

### QEMU Fails to Connect to gem5

```
Failed to connect to /tmp/gem5-mi300x.sock
```

- Confirm gem5 has finished initialization (look for "Waiting for QEMU to connect")
- Confirm socket permissions have been fixed (`chmod 777`)

### Driver Loading Fails -- PSP GPU Reset Panic

```
BUG: kernel NULL pointer dereference at psp_gpu_reset+0x43
```

- An incorrect `ip_block_mask` was used. Must use `0x67` (disables PSP+SMU), not `0x6f`

### gem5 Crash -- GART Translation Not Found

```
GART translation for 0x3fff800000000 not found
```

- This is a fixed bug: unmapped GART pages are now routed to a sink address (paddr=0) and no longer cause crashes
- If this still occurs, confirm you are using the latest compiled gem5 binary

### hipcc Compilation Error -- Offload Arch

```
error: cannot find ROCm device library
```

- Confirm ROCm is properly installed: `ls /opt/rocm/lib/`
- Use the correct architecture flag: `--offload-arch=gfx942`

### GPU Compute Timeout

- Check gem5 logs (`docker logs gem5-cosim`) for errors
- A small number of fence timeouts is normal; a large number may indicate issues with the DMA or interrupt path

---

## Key Parameter Reference

| Parameter | Default | Description |
|---|---|---|
| `--socket-path` | `/tmp/gem5-mi300x.sock` | QEMU <-> gem5 communication socket (vfio-user protocol) |
| `--shmem-path` | `/mi300x-vram` | GPU VRAM shared memory name (under /dev/shm) |
| `--shmem-host-path` | `/cosim-guest-ram` | Guest RAM shared memory name |
| `--dgpu-mem-size` | `16GiB` | GPU VRAM size |
| `--num-compute-units` | `40` | Number of GPU compute units |
| `--mem-size` | `8GiB` | Guest physical memory size |
| `--cosim-backend` | `vfio-user` | Cosim backend type (`vfio-user` or `legacy`) |
| `ip_block_mask` | `0x67` | amdgpu driver IP block mask |
| `discovery` | `2` | Use IP discovery firmware |

## Key File Reference

| File | Purpose |
|---|---|
| `scripts/cosim_launch.sh` | cosim one-click launch script |
| `scripts/run_mi300x_fs.sh` | Orchestration script (compile, build image, run) |
| `configs/example/gpufs/mi300_cosim.py` | gem5 cosim configuration |
| `src/dev/amdgpu/mi300x_vfio_user.{cc,hh}` | gem5-side vfio-user server (default backend) |
| `src/dev/amdgpu/mi300x_gem5_cosim.{cc,hh}` | gem5-side legacy bridge (legacy backend) |
| `src/dev/amdgpu/amdgpu_device.cc` | GPU device model |
| `src/dev/amdgpu/amdgpu_vm.cc` | GPU address translation (GART, etc.) |
| `qemu/hw/misc/mi300x_gem5.c` | QEMU-side mi300x-gem5 PCIe device (legacy backend only) |

## Version Matrix

| Component | Version |
|---|---|
| Guest OS | Ubuntu 24.04.2 LTS |
| Guest Kernel | 6.8.0-79-generic |
| ROCm | 7.0.0 |
| amdgpu DKMS | Matches ROCm 7.0 |
| gem5 Build Target | VEGA_X86 |
| GPU Device | MI300X (gfx942, DeviceID 0x74A0) |
| Coherence Protocol | GPU_VIPER |
| QEMU | 10.0+ (vfio-user backend) or cosim branch (legacy backend) |
