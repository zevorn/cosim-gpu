[中文](../zh/cosim-technical-notes.md)

# QEMU + gem5 MI300X Co-simulation: Technical Notes

This document summarizes the architecture, implementation details, resolved issues, and known limitations of the QEMU + gem5 MI300X co-simulation system.

## 1. Architecture Overview

```
┌──────────────────────────────────┐
│  QEMU  (Q35 + KVM)              │
│  ┌──────────────────────────┐   │
│  │  Guest Linux (Ubuntu 24) │   │
│  │  amdgpu driver (ROCm 7)  │   │
│  │  ROCm userspace           │   │
│  └──────────┬───────────────┘   │
│             │ MMIO / Doorbell    │
│  ┌──────────▼───────────────┐   │
│  │  mi300x-gem5 PCI device  │   │
│  │  (qemu/hw/misc/          │   │
│  │   mi300x_gem5.c)         │   │
│  └──────────┬───────────────┘   │
│             │ Unix socket        │
└─────────────┼───────────────────┘
              │  /tmp/gem5-mi300x.sock
              │  (MMIO conn + Event conn)
┌─────────────┼───────────────────┐
│  gem5       │                   │
│  ┌──────────▼───────────────┐   │
│  │  MI300XGem5Cosim bridge  │   │
│  │  (mi300x_gem5_cosim.cc)  │   │
│  └──────────┬───────────────┘   │
│             │ AMDGPUDevice API   │
│  ┌──────────▼───────────────┐   │
│  │  AMDGPUDevice            │   │
│  │  PM4PacketProcessor      │   │
│  │  SDMAEngine              │   │
│  │  Shader / CU array       │   │
│  └──────────────────────────┘   │
└─────────────────────────────────┘

Shared Memory:
  /dev/shm/cosim-guest-ram   Guest physical RAM (QEMU ↔ gem5 DMA)
  /dev/shm/mi300x-vram       GPU VRAM (QEMU BAR0 ↔ gem5 device memory)
```

### Key Components

| Component | Location | Purpose |
|---|---|---|
| `mi300x_gem5.c` | `qemu/hw/misc/` | QEMU PCI device; forwards MMIO/doorbell to gem5 via socket |
| `MI300XGem5Cosim` | `src/dev/amdgpu/mi300x_gem5_cosim.{cc,hh}` | gem5 SimObject; accepts socket connections, dispatches to AMDGPUDevice |
| `mi300_cosim.py` | `configs/example/gpufs/` | gem5 config; minimal System() with GPU hierarchy, no kernel |
| `cosim_launch.sh` | `scripts/` | Orchestrates Docker (gem5) + QEMU launch sequence |

### PCI BAR Layout

```
BAR0+1  VRAM         64-bit prefetchable   16 GiB  (shared memory)
BAR2+3  Doorbell     64-bit                 4 MiB
BAR4    MSI-X        exclusive
BAR5    MMIO regs    32-bit                512 KiB  (forwarded to gem5)
```

This layout **must** match the expectations hardcoded in the amdgpu driver (`AMDGPU_VRAM_BAR=0`, `AMDGPU_DOORBELL_BAR=2`, `AMDGPU_MMIO_BAR=5`).

## 2. Resolved Issues (Pitfall Log)

### 2.1 Shared Memory File Offset Mismatch (Critical)

**Symptom**: GART page table entries read back as all zeros; PM4 opcode 0x0 (NOP, count 0) repeats infinitely.

**Root cause**: QEMU Q35 and gem5 split memory below/above 4G differently, resulting in different file offsets within the shared backing store.

- QEMU Q35 with 8 GiB RAM: `below_4g = 2 GiB` (hardcoded when `ram_size >= 0xB0000000`). See `qemu/hw/i386/pc_q35.c:161`.
- gem5 configured as 3 GiB below / 5 GiB above.
- QEMU places above-4G data at file offset 2 GiB; gem5 reads from offset 3 GiB -> all zeros.

**Fix**: `mi300_cosim.py` replicates the Q35 split logic:

```python
total_mem = convert.toMemorySize(args.mem_size)
lowmem_limit = 0x80000000 if total_mem >= 0xB0000000 else 0xB0000000
below_4g = min(total_mem, lowmem_limit)
above_4g = total_mem - below_4g
```

**Key lesson**: When two systems share a memory-backend-file, they must agree on file offsets for each range, not just the total size.

### 2.2 SIGIO Edge-Triggered Drain Issue (Critical)

**Symptom**: gem5 hangs forever after processing the first MMIO message. QEMU's socket buffer fills up.

**Root cause**: gem5's `PollQueue` uses `FASYNC`/`SIGIO`, which is **edge-triggered**. If multiple messages arrive before the first one is processed, only one `SIGIO` fires. After handling one message, the remaining messages sit in the socket buffer with no signal to wake gem5.

**Fix**: `mi300x_gem5_cosim.cc:handleClientData()` uses a `do/while` loop with `poll(fd, POLLIN, 0)` to drain **all** pending messages on each SIGIO arrival.

```cpp
do {
    // read and process one message
    ...
    struct pollfd pfd = {fd, POLLIN, 0};
} while (poll(&pfd, 1, 0) > 0 && (pfd.revents & POLLIN));
```

### 2.3 VRAM Address GART Translation Error (Critical)

**Symptom**: Address `0x1f72fa8000` triggers over 861,000 GART translation errors, memory exhaustion, and segfault.

**Root cause**: SDMA rptr writeback addresses and PM4 RELEASE_MEM destination addresses may point to VRAM (address < 16 GiB). When these addresses go through `getGARTAddr()`, the page number is multiplied by 8, and GART translation fails because VRAM addresses have no corresponding page table entries.

**Fix (three-layer defense)**:

1. **PM4 layer** (`pm4_packet_processor.cc`): `writeData()`, `releaseMem()`, `queryStatus()` check `isVRAMAddress(addr)` and route VRAM writes through `gpuDevice->getMemMgr()->writeRequest()` (device memory) instead of `dmaWriteVirt()` (system memory via GART).

2. **SDMA layer** (`sdma_engine.cc`): `setGfxRptrLo/Hi()` and rptr writeback skip `getGARTAddr()` for VRAM addresses, using `getMemMgr()->writeRequest()` instead.

3. **GART fallback** (`amdgpu_vm.cc`): `GARTTranslationGen::translate()` detects VRAM addresses by reversing the `getGARTAddr` transform (`orig_page = page_num >> 3`) and maps them to `paddr=0` as a sink instead of faulting.

### 2.4 Timer Overflow in Co-simulation Mode

**Symptom**: After billions of ticks, gem5 crashes due to `curTick()` integer overflow (RTC and PIT timers continuously scheduling events).

**Fix**: Added a `disable_rtc_events` parameter to `Cmos` and a `disable_timer_events` parameter to `I8254`. Both are disabled in `mi300_cosim.py`. A keepalive event in `MI300XGem5Cosim` prevents the event queue from becoming empty.

### 2.5 PSP / SMU Firmware Load Failure

**Symptom**: `modprobe amdgpu` with `ip_block_mask=0x6f` fails with `-EINVAL` during PSP firmware loading.

**Root cause**: In ROCm 7.0's `amdgpu_discovery.c`, the IP block enumeration order is:
```
0: soc15_common  1: gmc_v9_0  2: vega20_ih
3: psp           4: smu       5: gfx_v9_4_3
6: sdma_v4_4_2   7: vcn_v4_0_3  8: jpeg_v4_0_3
```

`ip_block_mask=0x6f` = `0b01101111` disables bit 4 (SMU) but does **not** disable bit 3 (PSP). Use `ip_block_mask=0x67` = `0b01100111` to disable both PSP (bit 3) and SMU (bit 4).

### 2.6 QEMU Serial Console Conflict with `-nographic`

**Symptom**: No serial output from guest when using `-serial unix:/tmp/serial.sock -nographic` together.

**Root cause**: `-nographic` implies `-serial mon:stdio`, which creates serial0 mapped to stdio. The explicit `-serial unix:...` becomes serial1 (ttyS1), but the kernel uses `console=ttyS0`.

**Fix**: Use `-nographic` alone (serial output goes to stdio). For programmatic access, run QEMU inside `screen`:
```bash
screen -dmS qemu-cosim -L -Logfile /tmp/log <qemu-cmd>
screen -S qemu-cosim -X stuff 'command\n'
```

### 2.7 Unsupported PM4 Opcodes

| Opcode | Name | Description | Fix |
|--------|------|-------------|-----|
| `0x58` | `ACQUIRE_MEM` | Memory barrier / cache flush | NOP (skip packet body) |
| `0xA0` | `SET_RESOURCES` | Queue resource configuration | NOP (skip packet body) |

Both have been added to `pm4_defines.hh` and handled in `pm4_packet_processor.cc:decodeHeader()` as skip-and-continue.

### 2.8 Out-of-Memory (OOM) During Linking

**Symptom**: Linker killed by OOM killer even with `-j2`.

**Fix**: Use the gold linker and limit to a single job:
```bash
scons build/VEGA_X86/gem5.opt -j1 GOLD_LINKER=True --linker=gold
```

### 2.9 PCI Class Code

**Symptom**: amdgpu driver skips the legacy VGA ROM check at `0xC0000`.

**Fix**: Changed PCI class from `PCI_CLASS_DISPLAY_OTHER (0x0380)` to `PCI_CLASS_DISPLAY_VGA (0x0300)`. With VGA class, the kernel automatically detects it as a "video device with shadowed ROM".

### 2.10 GART Unmapped Page Crash (Critical)

**Symptom**: After a HIP program outputs `hipMalloc OK`, gem5 segfaults with repeated `GART translation for 0x3fff800000000 not found` warnings.

**Root cause**: The GPU's PM4/SDMA engines attempt DMA to GART pages that the driver has not yet mapped (PTE = 0 in shared VRAM). The original code created a `GenericPageTableFault`, but the DMA callback chain retried the same failing address infinitely, exhausting memory and crashing.

**Fix**: In co-simulation mode, unmapped GART pages are mapped to a sink (`paddr=0`) instead of faulting. DMA reads return zeros, writes are discarded, but the simulation stays alive. GART sink diagnostics also log `fbBase` to aid debugging.

**Key finding**: GART PTEs at `gartBase` (= `ptBase`) in shared VRAM were correctly populated by the driver. Diagnostics confirmed that subsequent PTEs (offset 0x32E0+) contain valid entries, while the first page (ptStart itself) is simply unmapped -- this is normal behavior.

## 3. Current Status

### Implemented Features

- **Driver initialization**: amdgpu 3.64.0 fully loaded
  - IP discovery from firmware files (`discovery=2`)
  - GMC (memory controller), GFX (compute), SDMA, IH (interrupt handler)
  - 8 KIQ rings mapped (mec 2 pipe 1 q 0)
  - 4 SDMA engines x 4 queues = 16 SDMA rings
  - 64+ compute rings across 8 XCP partitions
  - 7 DRM XCP device nodes (`/dev/dri/renderD129..135`)
- **ROCm tools**:
  - `rocm-smi`: device 0x74a0, SPX partition, 1% VRAM
  - `rocminfo`: Agent gfx942, 320 CU, 4 SIMD/CU, KERNEL_DISPATCH
- **KFD** (Kernel Fusion Driver): node added, 16383 MB VRAM, HSA agent registered
- **GPU compute (HIP)**: fully functional!
  - `hipMalloc` / `hipMemcpy` (host-to-device, device-to-host)
  - Kernel dispatch (`addKernel<<<1, N>>>`) runs on gfx942
  - `hipDeviceSynchronize` returns `hipSuccess`
  - Results verified correct: `{1+10, 2+20, 3+30, 4+40}` = `{11, 22, 33, 44}`
- **MSI-X interrupt forwarding**: gem5 -> QEMU via event socket
  - `AMDGPUDevice::intrPost()` -> `cosimBridge->sendIrqRaise(0)`
  - QEMU event thread -> `msix_notify()` -> guest IH handler
- **GART translation**: co-simulation fallback reads PTEs from shared VRAM; unmapped pages safely routed to sink
- **65,000+ MMIO operations** handled without crashes
- **Disk image**: `ip_block_mask=0x67` persisted via systemd service (`load-amdgpu.service` -> `/root/load_amdgpu.sh`)

### Known Limitations

1. **Fence fallback timer**: 80+ DRM fence timeouts during driver initialization (~500 ms each). Ring tests "pass" via the DRM fallback timer. After driver loading completes, MSI interrupts work normally for compute dispatch.

2. **No VGA BIOS ROM**: `Unable to locate a BIOS ROM` warning. Not needed for compute workloads; the VGA ROM dd step can be skipped.

3. **GART unmapped pages**: Some GART pages have PTE=0 and are routed to sink. This is safe but means DMA reads to those addresses return zeros.

## 4. File Change Summary

### gem5 (New Files)
| File | Description |
|---|---|
| `src/dev/amdgpu/mi300x_gem5_cosim.{cc,hh}` | Socket bridge SimObject |
| `src/dev/amdgpu/MI300XGem5Cosim.py` | SimObject Python wrapper |
| `configs/example/gpufs/mi300_cosim.py` | Co-simulation system config |
| `scripts/cosim_launch.sh` | Launch orchestration script |

### gem5 (Modified Files)
| File | Changes |
|---|---|
| `src/dev/amdgpu/pm4_packet_processor.{cc,hh}` | VRAM write routing, `isVRAMAddress()`, ACQUIRE_MEM/SET_RESOURCES NOP |
| `src/dev/amdgpu/pm4_defines.hh` | Added `IT_ACQUIRE_MEM`, `IT_SET_RESOURCES` |
| `src/dev/amdgpu/sdma_engine.cc` | VRAM rptr writeback routing |
| `src/dev/amdgpu/amdgpu_vm.{cc,hh}` | GART co-simulation fallback (shared VRAM PTE reads), VRAM address sink |
| `src/dev/amdgpu/amdgpu_device.cc` | Co-simulation integration hooks |
| `src/dev/amdgpu/amdgpu_nbio.cc` | ASIC initialization complete register |
| `src/dev/intel_8254_timer.{cc,hh}` | `disable_timer_events` parameter |
| `src/dev/mc146818.{cc,hh}` | `disable_rtc_events` parameter |

### QEMU (New Files)
| File | Description |
|---|---|
| `hw/misc/mi300x_gem5.c` | MI300X PCI device with socket bridge |
| `hw/misc/mi300x_gem5.h` | Header file |
| `hw/misc/trace-events` | Trace event definitions |

## 5. How to Run

### Prerequisites
- Docker installed with `gem5-run:local` image built
- QEMU compiled from `cosim/qemu/` (with mi300x-gem5 device)
- Disk image `x86-ubuntu-rocm70` + kernel `vmlinux-rocm70`

### Quick Start
```bash
cd cosim/gem5
bash scripts/cosim_launch.sh
# After guest boots (auto-login as root):
ln -sf /usr/lib/firmware/amdgpu/mi300_discovery \
       /usr/lib/firmware/amdgpu/ip_discovery.bin
modprobe amdgpu ip_block_mask=0x67 discovery=2
rocm-smi   # verify GPU is visible
```

### Manual Launch (for Debugging)
```bash
# 1. Run gem5 in Docker
docker run -d --name gem5-cosim \
  -v "$PWD:/gem5" -v /tmp:/tmp -v /dev/shm:/dev/shm -w /gem5 \
  -e PYTHONPATH=/usr/lib/python3.12/lib-dynload \
  gem5-run:local build/VEGA_X86/gem5.opt \
  --debug-flags=MI300XCosim --listener-mode=on \
  configs/example/gpufs/mi300_cosim.py \
  --socket-path=/tmp/gem5-mi300x.sock \
  --shmem-path=/mi300x-vram \
  --shmem-host-path=/cosim-guest-ram \
  --dgpu-mem-size=16GiB --num-compute-units=40 --mem-size=8G

# 2. Wait for socket creation and fix permissions
docker exec gem5-cosim chmod 777 /tmp/gem5-mi300x.sock
docker exec gem5-cosim chmod 666 /dev/shm/mi300x-vram

# 3. Run QEMU in screen
screen -dmS qemu-cosim -L -Logfile /tmp/qemu-cosim-screen.log \
  ../qemu/build/qemu-system-x86_64 \
  -machine q35 -enable-kvm -cpu host -m 8G -smp 4 \
  -object memory-backend-file,id=mem0,size=8G,\
          mem-path=/dev/shm/cosim-guest-ram,share=on \
  -numa node,memdev=mem0 \
  -kernel ../gem5-resources/src/x86-ubuntu-gpu-ml/vmlinux-rocm70 \
  -append "console=ttyS0,115200 root=/dev/vda1 \
           modprobe.blacklist=amdgpu earlyprintk=serial,ttyS0,115200" \
  -drive file=../gem5-resources/src/x86-ubuntu-gpu-ml/disk-image/x86-ubuntu-rocm70,\
         format=raw,if=virtio \
  -device mi300x-gem5,gem5-socket=/tmp/gem5-mi300x.sock,\
          shmem-path=/dev/shm/mi300x-vram,vram-size=17179869184 \
  -nographic -no-reboot

# 4. Interactive operations
screen -S qemu-cosim -X stuff 'modprobe amdgpu ip_block_mask=0x67 discovery=2\n'
```

## 6. Debugging Tips

- **gem5 debug flags**: `--debug-flags=MI300XCosim,AMDGPUDevice,PM4PacketProcessor`
- **QEMU trace**: `--qemu-trace 'mi300x_gem5_*'`
- **Check gem5 logs**: `docker logs gem5-cosim 2>&1 | grep -E "warn|error|GART"`
- **Check guest dmesg**: `screen -S qemu-cosim -X stuff 'dmesg | tail -20\n'`
- **Incremental rebuild**: Delete stale `.o` files and rebuild with gold linker:
  ```bash
  docker run --rm -v "$PWD:/gem5" -w /gem5 gem5-run:local \
    sh -c 'rm -f build/VEGA_X86/dev/amdgpu/<file>.o'
  docker run --rm -v "$PWD:/gem5" -w /gem5 \
    -e PYTHONPATH=/usr/lib/python3.12/lib-dynload \
    gem5-run:local scons build/VEGA_X86/gem5.opt -j1 \
    GOLD_LINKER=True --linker=gold
  ```
