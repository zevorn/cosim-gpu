# cosim — QEMU + gem5 MI300X Co-simulation

## Build

```bash
# Option A: script-based
./scripts/run_mi300x_fs.sh build-all
cd scripts && docker build -t gem5-run:local -f Dockerfile.run . && cd ..

# Option B: manual
cd gem5 && docker run --rm -v "$(pwd):/gem5" -w /gem5 \
    -e PYTHONPATH=/usr/lib/python3.12/lib-dynload \
    ghcr.io/gem5/gpu-fs:latest \
    bash -c "scons build/VEGA_X86/gem5.opt -j4 GOLD_LINKER=True --linker=gold"
cd ../qemu && mkdir -p build && cd build && ../configure --target-list=x86_64-softmmu && make -j$(nproc)
cd ../../scripts && docker build -t gem5-run:local -f Dockerfile.run . && cd ..
docker run --rm -v "$(pwd)/gem5:/gem5" -w /gem5 ghcr.io/gem5/gpu-fs:latest \
    bash -c "cd util/m5 && scons build/x86/out/m5"
cp gem5/util/m5/build/x86/out/m5 gem5-resources/src/x86-ubuntu-gpu-ml/files/
./scripts/run_mi300x_fs.sh build-disk
```

Use `-j1` for gem5 linking if OOM-killed.

## Launch

```bash
./scripts/cosim_launch.sh                         # default
./scripts/cosim_launch.sh --gem5-debug MI300XCosim # with debug trace
```

After guest boots: driver auto-loads via `cosim-gpu-setup.service` (dd ROM + modprobe).
Manual: `dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128 && modprobe amdgpu ip_block_mask=0x67 discovery=2 ras_enable=0`

## Architecture

QEMU (Q35+KVM) ←Unix socket→ gem5 (MI300X GPU model, no kernel).
Shared memory: `/dev/shm/cosim-guest-ram` (guest RAM) + `/dev/shm/mi300x-vram` (VRAM).
BAR layout: 0+1=VRAM, 2+3=Doorbell, 4=MSI-X, 5=MMIO.
Driver params: `ip_block_mask=0x67` (disable PSP+SMU), `discovery=2` (firmware).

## Debugging

```bash
--gem5-debug MI300XCosim                          # cosim socket messages
--gem5-debug AMDGPUDevice,PM4PacketProcessor      # MMIO + PM4
--gem5-debug SDMAEngine                           # SDMA
--qemu-trace "mi300x_gem5_*"                      # QEMU trace events
docker logs gem5-cosim 2>&1 | tee /tmp/gem5.log   # gem5 logs
python3 scripts/cosim_test_client.py /tmp/gem5-mi300x.sock  # socket test
```

| Symptom | Fix |
|---------|-----|
| gem5 container exited | `docker logs gem5-cosim` (config error or OOM) |
| NULL deref in `amdgpu_atom_parse_data_header` | Must `dd` ROM to 0xC0000 before modprobe |
| KIQ disable timeout (-110) | Expected in cosim; harmless |
| DRM client -13 / EPERM | Rebuild disk image with latest gem5-resources |

## Commit Rules

- gem5: pre-commit hooks (clang-format, black, isort). Tags from `MAINTAINERS.yaml`.
- QEMU: checkpatch.pl (<90 chars).
- Top-level cosim: no hooks.
- Signed-off-by: derive from `git config user.name` and `git config user.email`.

## Documentation Rules

- All docs under `docs/` must have both `docs/zh/` and `docs/en/` versions.
- First line: `[English](../en/<file>.md)` or `[中文](../zh/<file>.md)`.
- When adding or modifying a doc, always update both language versions.
