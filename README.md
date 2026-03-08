# QEMU + gem5 MI300X Co-simulation

[中文文档](README.zh.md)

Co-simulation framework that pairs **QEMU** (host CPU/system via KVM) with
**gem5** (cycle-accurate MI300X GPU model) to run real AMD ROCm/HIP workloads
on a simulated GPU without physical hardware.

```
┌─────────────────────────────┐       ┌────────────────────────────┐
│  QEMU  (Q35 + KVM)          │       │  gem5  (Docker)            │
│  ┌───────────────────────┐  │       │  ┌──────────────────────┐  │
│  │ Guest Linux           │  │       │  │ MI300X GPU Model     │  │
│  │ amdgpu driver         │  │       │  │  Shader / CU / SDMA  │  │
│  │ ROCm 7.0 / HIP        │  │       │  │  PM4 / Ruby caches   │  │
│  └───────────┬───────────┘  │       │  └──────────┬───────────┘  │
│  ┌───────────▼───────────┐  │       │  ┌──────────▼───────────┐  │
│  │ mi300x-gem5 PCIe dev  │◄────────►│  │ MI300XGem5Cosim      │  │
│  └───────────────────────┘  │ Unix  │  └──────────────────────┘  │
│                             │Socket │                            │
└─────────────────────────────┘       └────────────────────────────┘
        │                                       │
        ▼                                       ▼
  /dev/shm/cosim-guest-ram            /dev/shm/mi300x-vram
  (shared guest RAM)                  (shared GPU VRAM)
```

## Features

- **Full amdgpu driver load** — DRM initialized, 7 XCP partitions, gfx942
- **HIP compute verified** — hipMalloc, kernel dispatch, hipDeviceSynchronize
- **MSI-X interrupts** — gem5 → QEMU interrupt forwarding, IH ring buffer
- **Shared memory DMA** — zero-copy VRAM and guest RAM via `/dev/shm`
- **Auto driver load** — systemd service for `ip_block_mask=0x67 discovery=2`

## Prerequisites

| Requirement | Details |
|---|---|
| Host OS | Linux x86_64 with KVM (tested on WSL2 6.6.x) |
| Docker | Running daemon, user in `docker` group |
| KVM | `/dev/kvm` accessible |
| Disk space | ~120 GB (55G disk image + build artifacts) |
| RAM | 16 GB+ recommended |

## Quick Start

### Option A: Script-based

```bash
git clone --recurse-submodules git@github.com:zevorn/cosim.git
cd cosim

# Build gem5 + QEMU + disk image (~2h total, needs KVM + Docker + ~60GB disk)
GEM5_BUILD_IMAGE=ghcr.io/gem5/gpu-fs:latest ./scripts/run_mi300x_fs.sh build-all

# Build runtime Docker image (for running gem5 inside Docker)
cd scripts && docker build -t gem5-run:local -f Dockerfile.run . && cd ..

# Launch co-simulation
./scripts/cosim_launch.sh
```

### Option B: Manual step-by-step

```bash
# 1. Clone with submodules
git clone --recurse-submodules git@github.com:zevorn/cosim.git
cd cosim

# 2. Build gem5 (in Docker, ~30min; use -j1 if OOM-killed during linking)
cd gem5
docker run --rm -v "$(pwd):/gem5" -w /gem5 \
    -e PYTHONPATH=/usr/lib/python3.12/lib-dynload \
    ghcr.io/gem5/gpu-fs:latest \
    bash -c "scons build/VEGA_X86/gem5.opt -j4 GOLD_LINKER=True --linker=gold"
cd ..

# 3. Build runtime Docker image (for running gem5 inside Docker)
cd scripts && docker build -t gem5-run:local -f Dockerfile.run . && cd ..

# 4. Build QEMU (with mi300x-gem5 cosim PCIe device)
cd qemu && mkdir -p build && cd build
../configure --target-list=x86_64-softmmu
make -j$(nproc)
cd ../..

# 5. Pre-build m5 utility (recommended — avoids git clone inside guest VM)
docker run --rm -v "$(pwd)/gem5:/gem5" -w /gem5 \
    ghcr.io/gem5/gpu-fs:latest \
    bash -c "cd util/m5 && scons build/x86/out/m5"
cp gem5/util/m5/build/x86/out/m5 gem5-resources/src/x86-ubuntu-gpu-ml/files/

# 6. Build disk image (Ubuntu 24.04 + ROCm 7.0, ~40min, needs KVM + ~60GB disk)
./scripts/run_mi300x_fs.sh build-disk

# 7. Launch co-simulation
./scripts/cosim_launch.sh
```

After guest boots (auto-login as root):

```bash
# Load GPU driver
modprobe amdgpu ip_block_mask=0x67 discovery=2

# Verify
rocm-smi          # should show device 0x74a0
rocminfo          # should show gfx942, 320 CUs

# Run a HIP test
cat > /tmp/test.cpp << 'EOF'
#include <hip/hip_runtime.h>
#include <cstdio>
__global__ void add(int *a, int *b, int *c, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}
int main() {
    const int N = 4;
    int ha[] = {1,2,3,4}, hb[] = {10,20,30,40}, hc[4] = {};
    int *da, *db, *dc;
    hipMalloc(&da, N*4); hipMalloc(&db, N*4); hipMalloc(&dc, N*4);
    hipMemcpy(da, ha, N*4, hipMemcpyHostToDevice);
    hipMemcpy(db, hb, N*4, hipMemcpyHostToDevice);
    add<<<1, N>>>(da, db, dc, N);
    hipMemcpy(hc, dc, N*4, hipMemcpyDeviceToHost);
    printf("Result: %d %d %d %d\n", hc[0], hc[1], hc[2], hc[3]);
    printf("%s\n", (hc[0]==11&&hc[1]==22&&hc[2]==33&&hc[3]==44) ? "PASSED!" : "FAILED!");
    hipFree(da); hipFree(db); hipFree(dc);
}
EOF
/opt/rocm/bin/hipcc --offload-arch=gfx942 -o /tmp/test /tmp/test.cpp
/tmp/test
# Expected: Result: 11 22 33 44
#           PASSED!
```

## Repository Structure

```
cosim/
├── gem5/                    # gem5 simulator (submodule, cosim-gpu branch)
│   ├── src/dev/amdgpu/      # MI300X GPU device model & cosim bridge
│   └── configs/example/gpufs/mi300_cosim.py  # cosim configuration
├── qemu/                    # QEMU emulator (submodule, cosim-gpu branch)
│   ├── hw/misc/mi300x_gem5.c      # mi300x-gem5 PCIe device
│   └── include/hw/misc/mi300x_gem5.h
├── gem5-resources/          # disk images, kernels, GPU apps (submodule)
├── scripts/                 # build & launch scripts
│   ├── cosim_launch.sh      # one-click cosim launcher
│   ├── run_mi300x_fs.sh     # build orchestration
│   ├── cosim_guest_setup.sh # guest-side GPU setup
│   ├── cosim_test_client.py # socket test client
│   └── Dockerfile.run       # gem5 runtime Docker image
├── docs/                    # technical documentation (Chinese)
│   ├── cosim-usage-guide.md           # full usage guide
│   ├── cosim-technical-notes.md       # architecture & fixes
│   ├── mi300x-memory-management.md    # GPU memory & address translation
│   ├── gpu-fs-guide.md               # gem5 GPU FS setup
│   ├── cosim-guest-gpu-init.md        # guest GPU init flow
│   └── cosim-debugging-pitfalls.md    # debugging notes
├── LICENSE                  # Apache 2.0
└── README.md                # this file
```

## Key Components

### QEMU Side (`qemu/hw/misc/mi300x_gem5.c`)

A virtual PCIe device (`mi300x-gem5`) that exposes:
- **BAR0+1**: VRAM (64-bit, prefetchable, shared memory backed)
- **BAR2+3**: Doorbell (64-bit, forwarded to gem5)
- **BAR4**: MSI-X (256 vectors)
- **BAR5**: MMIO registers (32-bit, forwarded to gem5)

Communication: Unix domain socket (sync MMIO) + event thread (async IRQ/DMA).

### gem5 Side (`gem5/src/dev/amdgpu/`)

- **MI300XGem5Cosim** — socket server, message dispatch, shared memory setup
- **AMDGPUDevice** — MI300X GPU device model (MMIO, doorbell, config space)
- **PM4PacketProcessor** — command processor with VRAM-aware fence routing
- **SDMAEngine** — DMA engine with VRAM write-back support
- **AMDGPUVM** — GART translation with cosim fallback (shared VRAM PTE reads)

## Version Matrix

| Component | Version |
|---|---|
| Guest OS | Ubuntu 24.04.2 LTS |
| Guest kernel | 6.8.0-79-generic |
| ROCm | 7.0.0 |
| GPU device | MI300X (gfx942, DeviceID 0x74A0) |
| gem5 build | VEGA_X86, GPU_VIPER coherence |

## Documentation

Detailed technical documentation is available in [`docs/`](docs/) (Chinese):

- [Complete Usage Guide](docs/cosim-usage-guide.md) — build, run, test
- [Technical Notes](docs/cosim-technical-notes.md) — architecture, pitfalls, fixes
- [MI300X Memory Management](docs/mi300x-memory-management.md) — GART, address translation
- [GPU FS Guide](docs/gpu-fs-guide.md) — gem5 standalone GPU full-system simulation
- [Guest GPU Init](docs/cosim-guest-gpu-init.md) — driver initialization flow
- [Debugging Pitfalls](docs/cosim-debugging-pitfalls.md) — common issues and solutions

## License

This project is licensed under the [Apache License 2.0](LICENSE).

Note: The `gem5` and `qemu` submodules are governed by their own respective
licenses (gem5: BSD-3-Clause, QEMU: GPL-2.0).

## Acknowledgments

- [gem5](https://www.gem5.org/) — modular computer architecture simulator
- [QEMU](https://www.qemu.org/) — open-source machine emulator
- [ROCm](https://rocm.docs.amd.com/) — AMD GPU computing platform
