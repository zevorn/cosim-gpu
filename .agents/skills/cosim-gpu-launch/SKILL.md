---
name: cosim-gpu-launch
description: Use when you need to start the QEMU+gem5 cosim environment. Launches gem5 in Docker, QEMU with KVM on host, via vfio-user or legacy cosim socket.
---

# Cosim Launch

Launch the QEMU+gem5 co-simulation environment.

This is a direct launcher, not the test harness. Use it for manual boot,
interactive inspection, backend checks, and standalone QEMU+gem5 sessions. It
does not accept `--output-dir`, does not create test matrices, does not write
guest program logs, and does not run binary-provenance hooks. Use `cosim-gpu-test`
when a run must produce case-managed evidence.

## Quickstart

```bash
just run-preflight
just run-launch
just run-launch --gem5-debug MI300XCosim
just run-launch --cosim-backend legacy
```

After guest boots, the driver loads automatically via `cosim-gpu-setup.service`.
If not, manually load with `cosim-gpu-guest`.

## Autonomy

Run `just run-preflight` to inspect host resources before launch. It does not
change files or remove resources. Use `just run-clean-orphans` only when
orphaned resources need removal.

## Backends

| Backend | Protocol | Default? | Notes |
|---------|----------|----------|-------|
| vfio-user | `libvfio-user` over Unix socket | Yes | Standard, no custom QEMU code |
| legacy | Custom cosim socket protocol | No | QEMU `mi300x-gem5` device |

## Architecture

```
QEMU (Q35+KVM, host) ←Unix socket→ gem5 (MI300X GPU, Docker)
```

Shared memory uses run-id names: `/dev/shm/cosim-guest-ram-<run-id>` for guest RAM and `/dev/shm/mi300x-vram-<run-id>` for VRAM.
BAR layout: 0+1=VRAM, 2+3=Doorbell, 4=MSI-X, 5=MMIO.

## Driver parameters

```
ip_block_mask=0x67  # enable common/GMC/IH/GFX/SDMA; disable PSP bit 3 and SMU bit 4
ppfeaturemask=0     # disable power play
dpm=0               # disable dynamic power management
audio=0             # no audio controller
ras_enable=0        # disable RAS
discovery=2         # firmware-based discovery
```

## Troubleshooting

| Symptom | Route |
|---------|-------|
| gem5 container exited during launch | Use `cosim-gpu-debug` to inspect active gem5 container logs |
| Driver failed while parsing AtomBIOS | Use `cosim-gpu-guest` or launch setup workflow to inspect ROM visibility before amdgpu loads |
| KIQ disable timeout (-110) | Treat as expected cosim noise unless followed by a functional failure |
| DRM client -13 / EPERM | Use guest setup or disk-image workflow to inspect permissions and image state |

## Integration

- **Before**: use `cosim-gpu-build` when binaries are stale or missing
- **Before**: run `just run-preflight` to inspect host resources
- **While running**: `cosim-gpu-guest` to interact, `cosim-gpu-debug` to inspect
- **Testing**: Prefer `cosim-gpu-test` for automated execution (handles launch internally)
