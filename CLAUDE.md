# cosim — QEMU + gem5 MI300X Co-simulation

## Repo Layout

```
cosim/                        # top-level (this repo)
├── gem5/                     # submodule (cosim-gpu branch, zevorn/gem5)
│   ├── src/dev/amdgpu/       # MI300X device model + cosim bridge
│   └── configs/example/gpufs/mi300_cosim.py
├── qemu/                     # submodule (cosim-gpu branch, zevorn/qemu)
│   └── hw/misc/mi300x_gem5.c
├── gem5-resources/           # submodule (stable branch, gem5/gem5-resources)
├── scripts/                  # build & launch scripts
└── docs/                     # technical docs (zh + en)
    ├── zh/                   # Chinese
    └── en/                   # English
```

## Key Source Files

| File | Role |
|------|------|
| `gem5/src/dev/amdgpu/mi300x_gem5_cosim.cc` | gem5 cosim socket server |
| `gem5/src/dev/amdgpu/mi300x_gem5_cosim.hh` | cosim protocol + header |
| `gem5/src/dev/amdgpu/amdgpu_device.cc` | GPU device model (MMIO, doorbell) |
| `gem5/src/dev/amdgpu/pm4_packet_processor.cc` | PM4 command processor |
| `gem5/src/dev/amdgpu/sdma_engine.cc` | SDMA DMA engine |
| `gem5/src/dev/amdgpu/amdgpu_vm.cc` | GART translation |
| `gem5/configs/example/gpufs/mi300_cosim.py` | gem5 cosim Python config |
| `qemu/hw/misc/mi300x_gem5.c` | QEMU PCIe bridge device |
| `qemu/include/hw/misc/mi300x_gem5.h` | QEMU header + protocol enums |
| `scripts/cosim_launch.sh` | One-click launcher (gem5 Docker + QEMU) |
| `scripts/run_mi300x_fs.sh` | Build orchestration script |

## Build

```bash
# gem5 (in Docker, ~30min)
cd gem5 && docker run --rm -v "$(pwd):/gem5" -w /gem5 \
    ghcr.io/gem5/gpu-fs:latest \
    bash -c "scons build/VEGA_X86/gem5.opt -j4 GOLD_LINKER=True --linker=gold"

# QEMU
cd qemu && mkdir -p build && cd build && ../configure --target-list=x86_64-softmmu && make -j$(nproc)

# gem5 runtime Docker image
cd scripts && docker build -t gem5-run:local -f Dockerfile.run .
```

Use `-j1` for gem5 linking if OOM-killed.

## Launch

```bash
./scripts/cosim_launch.sh                         # default
./scripts/cosim_launch.sh --gem5-debug MI300XCosim # with debug trace
```

After guest boots:
```bash
modprobe amdgpu ip_block_mask=0x67 discovery=2
rocm-smi          # verify device 0x74a0
rocminfo          # verify gfx942, 320 CUs
```

## Architecture

```
QEMU (Q35+KVM, guest Linux + amdgpu) ←→ gem5 (MI300X GPU model)
    Unix socket: MMIO (sync) + events (async IRQ/DMA)
    Shared memory: /dev/shm/cosim-guest-ram + /dev/shm/mi300x-vram
```

- QEMU BAR0+1 = VRAM → gem5 FRAMEBUFFER_BAR
- QEMU BAR2+3 = Doorbell → gem5 DOORBELL_BAR
- QEMU BAR4 = MSI-X (256 vectors)
- QEMU BAR5 = MMIO → gem5 MMIO_BAR
- Driver params: `ip_block_mask=0x67` disables PSP+SMU; `discovery=2` uses firmware

## Debugging

### gem5 debug flags
```bash
--gem5-debug MI300XCosim          # cosim socket messages
--gem5-debug AMDGPUDevice         # GPU MMIO register reads/writes
--gem5-debug AMDGPUDevice,PM4PacketProcessor  # + PM4 command processing
--gem5-debug SDMAEngine           # SDMA operations
```

### QEMU trace events
```bash
--qemu-trace "mi300x_gem5_*"     # all mi300x trace events
```
Defined in `qemu/hw/misc/trace-events`.

### Collecting logs
```bash
# gem5 logs (inside Docker)
docker logs gem5-cosim 2>&1 | tee /tmp/gem5.log

# QEMU serial console (already on stdout with -nographic)
# For background: screen -dmS qemu -L -Logfile /tmp/qemu.log <qemu-cmd>

# Guest kernel ring buffer
dmesg | grep -i amdgpu
```

### Common issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `gem5 container exited` | Python config error or OOM | `docker logs gem5-cosim` |
| `lost connection to gem5` | gem5 crashed or socket closed | Check gem5 logs for fatal/panic |
| `KIQ disable timeout (-110)` | gem5 doesn't handle KIQ cmd | Expected in cosim; gem5 continues |
| `Unable to locate BIOS ROM` | No VGA ROM in VRAM | Harmless; driver works without it |
| DRM client -13 / EPERM | Kernel/ROCm version mismatch | Rebuild disk image with latest gem5-resources |
| `readfile` empty, driver not loading | Missing `--app` in gem5 standalone | Always pass `--app` for standalone mode |

### Socket protocol debugging
```bash
python3 scripts/cosim_test_client.py /tmp/gem5-mi300x.sock
```

## Commit Rules

- gem5: pre-commit hooks enforce clang-format, black, isort, gem5 style checker.
  Commit tags must match `MAINTAINERS.yaml` (use `dev-amdgpu:`, `configs:`, `dev:`).
- QEMU: checkpatch.pl enforces line length (<90 chars) and style.
- Top-level cosim: no hooks; standard git commit.
- Signed-off-by: derive from `git config user.name` and `git config user.email`.

## Documentation Rules

- All docs under `docs/` must have both Chinese (`docs/zh/`) and English (`docs/en/`) versions.
- Each doc must start with a language switch link on the first line:
  - Chinese: `[English](../en/<filename>.md)`
  - English: `[中文](../zh/<filename>.md)`
- When adding or modifying a doc, always update both language versions.
