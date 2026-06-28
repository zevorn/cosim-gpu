# cosim-gpu Agent Rules

## Scope

This repository hosts the QEMU + gem5 MI300X GPU co-simulation source tree.
Reusable agent workflows are no longer stored as `.claude/commands`; they live in
the `.agents` submodule, which points at `zevorn/cosim-gpu-skills`.

`CLAUDE.md` is a symbolic mapping to this file so Claude-compatible tools read
the same canonical rules.

## Skill Paths

Load the matching skill before running these workflows:

- Debugging co-simulation failures: `.agents/skills/cosim-gpu-debug/SKILL.md`
- Guest serial interaction and GPU test runs: `.agents/skills/cosim-gpu-guest/SKILL.md`
- Guest disk-image edits with `guestmount`: `.agents/skills/cosim-gpu-disk-image/SKILL.md`

Do not add new project-specific command implementations under `.claude/commands`.
Add reusable workflows to `cosim-gpu-skills` instead, then update this mapping.

## Build

```bash
./scripts/run_mi300x_fs.sh build-all
cd scripts && docker build -t gem5-run:local -f Dockerfile.run . && cd ..
```

Manual path when needed:

```bash
cd scripts && docker build -t gem5-run:local -f Dockerfile.run . && cd ..
cd gem5 && docker run --rm -v "$(pwd):/gem5" -w /gem5 \
    gem5-run:local \
    scons build/VEGA_X86/gem5.opt -j4
cd ../qemu && mkdir -p build && cd build && ../configure --target-list=x86_64-softmmu && make -j$(nproc)
cd ../..
docker run --rm -v "$(pwd)/gem5:/gem5" -w /gem5 gem5-run:local \
    bash -c "cd util/m5 && scons build/x86/out/m5"
cp gem5/util/m5/build/x86/out/m5 gem5-resources/src/x86-ubuntu-gpu-ml/files/
./scripts/run_mi300x_fs.sh build-disk
```

Use `-j1` for gem5 linking if the host is OOM-killed.

## Launch

```bash
./scripts/cosim_launch.sh
./scripts/cosim_launch.sh --gem5-debug MI300XCosim
```

After guest boot, `cosim-gpu-setup.service` copies the ROM and loads `amdgpu`.
Manual recovery:

```bash
dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128
modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

## Architecture

QEMU (Q35+KVM) communicates with gem5's MI300X model over a Unix socket. Guest
RAM and VRAM are shared through `/dev/shm/cosim-guest-ram` and
`/dev/shm/mi300x-vram`. BAR layout: 0+1=VRAM, 2+3=Doorbell, 4=MSI-X, 5=MMIO.

Driver parameters for this cosim path:

```text
ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

## Commit Rules

- gem5: pre-commit hooks apply; use tags from `MAINTAINERS.yaml`.
- QEMU: run checkpatch discipline for touched patches.
- Top-level cosim-gpu: no project-specific hooks.
- Sign commits with `Signed-off-by` from `git config user.name` and
  `git config user.email`.

## Documentation Rules

- Project docs under `docs/` must keep both `docs/zh/` and `docs/en/` versions.
- First line: `[English](../en/<file>.md)` or `[中文](../zh/<file>.md)`.
- When adding or modifying a doc, update both language versions.
