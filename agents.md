# cosim-gpu Agent Rules

## Scope

This repository hosts the QEMU + gem5 MI300X GPU co-simulation source tree.
Reusable agent workflows are no longer stored as `.claude/commands`; they are
vendored in-tree under `.agents/skills/` (previously the
`gevico/cosim-gpu-skills` submodule) and are tracked directly by this repository.

`CLAUDE.md` is a symbolic mapping to this file so Claude-compatible tools read
the same canonical rules.

## Skill Paths

Load the matching skill before running these workflows:

- Debugging co-simulation failures: `.agents/skills/cosim-gpu-debug/SKILL.md`
- Guest serial interaction and GPU test runs: `.agents/skills/cosim-gpu-guest/SKILL.md`
- Guest disk-image edits with `guestmount`: `.agents/skills/cosim-gpu-disk-image-edit/SKILL.md`

Do not add new project-specific command implementations under `.claude/commands`.
Add reusable workflows under `.agents/skills/` instead, then update this mapping.

## Build

All build, launch, test and check tasks are recipes in the top-level `justfile`
(`just --list`). Use the recipes instead of calling the scripts directly.
The QEMU, gem5, m5, Rust and topology recipes run on the Linux host, or in a
temporary development container when `COSIM_ENV=container` (the default
outside Linux); `just dev-image` builds its image.

```bash
just build-all
```

Individual steps when needed:

```bash
just dev-image
just build-qemu
just build-gem5
just build-m5
just build-disk
```

Use `just build-gem5 1` for gem5 linking if the host is OOM-killed.

## Launch

```bash
just run-topology samples/machines/single-gpu.yaml
just run-launch
just run-launch --gem5-debug MI300XCosim
just test-gpu --all
```

After guest boot, `cosim-gpu-setup.service` copies the ROM and loads `amdgpu`.
Manual recovery:

```bash
dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128
modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

## Architecture

QEMU (Q35+KVM) communicates with gem5's MI300X model through the standard
vfio-user protocol over a Unix socket. The `third_party/qemu` submodule tracks the
`gevico/cosim-gpu` branch of gevico/qemu (QEMU v11.1.2, no co-simulation
patches);
`just build-qemu` builds it, and the launcher falls back to the system QEMU.
Guest RAM and VRAM are shared through `/dev/shm/cosim-guest-ram` and
`/dev/shm/mi300x-vram`. BAR layout: 0+1=VRAM, 2+3=Doorbell, 4=MSI-X, 5=MMIO.

Driver parameters for this cosim path:

```text
ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

## Commit Rules

- gem5: pre-commit hooks apply; use tags from `MAINTAINERS.yaml`.
- Top-level cosim-gpu: every non-merge commit must pass `just check-patch`
  (QEMU `checkpatch.pl` rules, enforced by the `Checkpatch` CI job). See
  `docs/en/contributing.md`.
- Every tracked file must belong to an area in `MAINTAINERS.yml`; update it
  in the same commit that adds files outside existing areas, and run
  `just check-maintainers`.
- Sign commits with `Signed-off-by` from `git config user.name` and
  `git config user.email`.

## Documentation Rules

- Project docs under `docs/` must keep both `docs/zh/` and `docs/en/` versions.
- First line: `[English](../en/<file>.md)` or `[中文](../zh/<file>.md)`.
- When adding or modifying a doc, update both language versions.
