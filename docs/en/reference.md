[中文](../zh/reference.md)

# Co-simulation Reference Guide

Consolidated lookup reference for the QEMU + gem5 MI300X co-simulation system. For conceptual explanations, see [architecture.md](architecture.md). For step-by-step build/run instructions, see [getting-started.md](getting-started.md).

---

## 1. Parameter Reference

### 1.1 cosim_launch.sh / mi300_cosim.py Options

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--socket-path` | `/tmp/gem5-mi300x.sock` | QEMU <-> gem5 communication socket (vfio-user protocol) |
| `--shmem-path` | `/mi300x-vram` | GPU VRAM shared memory name (under `/dev/shm`) |
| `--shmem-host-path` | `/cosim-guest-ram` | Guest RAM shared memory name (under `/dev/shm`) |
| `--dgpu-mem-size` | `16GiB` | GPU VRAM size |
| `--num-compute-units` | `40` | Number of GPU compute units |
| `--mem-size` | `8GiB` | Guest physical memory size |
| `--cosim-backend` | `vfio-user` | Cosim backend type: `vfio-user` (stock QEMU 10.0+) or `legacy` (custom QEMU) |
| `--gem5-debug` | (none) | gem5 debug flag(s), e.g. `MI300XCosim`, `AMDGPUDevice,PM4PacketProcessor` |
| `--vram-size` | `32GiB` | Custom VRAM size (alias for `--dgpu-mem-size`) |
| `--num-cus` | `80` | Custom CU count (alias for `--num-compute-units`) |

### 1.2 amdgpu modprobe Parameters

All parameters are required for co-simulation. The full command:

```bash
modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `ip_block_mask` | `0x67` | Binary `0110_0111`. Enables common, GMC, IH, GFX, SDMA; disables PSP (bit 3) and SMU (bit 4). See [Section 3](#3-ip-block-mask-reference) for details |
| `ppfeaturemask` | `0` | Disable all PowerPlay features; cosim has no power management hardware |
| `dpm` | `0` | Disable Dynamic Power Management |
| `audio` | `0` | Disable HDMI/DP audio; no audio hardware in cosim |
| `ras_enable` | `0` | Disable RAS (Reliability, Availability, Serviceability). Prevents NULL deref on `atom_context` when VBIOS is minimal (3 KB cosim ROM) |
| `discovery` | `2` | Use firmware file on disk for IP discovery instead of GPU ROM/registers |

> **Warning**: Using `ip_block_mask=0x6f` (enables PSP at bit 3) causes PSP firmware load failure and kernel panic. Always use `0x67`.

> **Warning**: `ras_enable=0` is mandatory. Without it, `amdgpu_ras_init` calls `amdgpu_atom_parse_data_header` on NULL `atom_context`, crashing with a NULL pointer dereference.

### 1.3 dd Command Parameters (VGA ROM)

```bash
dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128
```

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `if` | `/root/roms/mi300.rom` | ROM binary file (inside disk image) |
| `of` | `/dev/mem` | Physical memory device |
| `bs` | `1k` | Block size = 1024 bytes |
| `seek` | `768` | Seek to 768 x 1024 = `0xC0000` (legacy VGA ROM region) |
| `count` | `128` | Write 128 x 1024 = 128 KB |

The `dd` step writes the MI300X VBIOS to physical address `0xC0000`--`0xDFFFF` in shared memory (`/dev/shm/cosim-guest-ram`). gem5's `AMDGPUDevice::readROM()` reads from this address via `system->getPhysMem()`. This step is **mandatory** before `modprobe` -- all five BIOS discovery methods fail in cosim mode:

| BIOS Discovery Method | Why It Fails in Cosim |
|-----------------------|----------------------|
| `amdgpu_atrm_get_bios()` | No ACPI ATRM method in QEMU Q35 |
| `amdgpu_acpi_vfct_bios()` | No ACPI VFCT table |
| `amdgpu_read_bios_from_rom()` | Reads via SMU registers, but SMU disabled by `ip_block_mask=0x67` |
| `amdgpu_read_platform_bios()` | No platform-provided ROM |
| `amdgpu_read_disabled_bios()` | Not functional in cosim |

### 1.4 Kernel Command Line

The kernel must be booted with:

```
console=ttyS0,115200 root=/dev/vda1 modprobe.blacklist=amdgpu
```

`modprobe.blacklist=amdgpu` prevents auto-loading the driver before the ROM is written to shared memory. The `cosim-gpu-setup.service` handles the correct initialization order (dd ROM, then modprobe).

---

## 2. Version Matrix

| Component | Version |
|-----------|---------|
| Guest OS | Ubuntu 24.04.2 LTS |
| Guest Kernel | 6.8.0-79-generic |
| ROCm | 7.0.0 |
| amdgpu DKMS | Matches ROCm 7.0 |
| gem5 Build Target | VEGA_X86 |
| GPU Device | MI300X (gfx942, DeviceID 0x74A0) |
| Coherence Protocol | GPU_VIPER |
| QEMU | 10.0+ (vfio-user backend) or cosim branch (legacy backend) |

### Docker Images

| Image | Purpose |
|-------|---------|
| `ghcr.io/gem5/gpu-fs:latest` | Base image for gem5 runtime container (amd64) |
| `gem5-run:local` | Runtime image built from `scripts/Dockerfile.run` (adds Python 3.12 support) |
| `ghcr.io/gem5/ubuntu-24.04_all-dependencies:v24-0` | gem5 compilation (arm64 only) |

> On amd64 hosts, use `ghcr.io/gem5/gpu-fs` as the build image or compile natively.

### Build Artifacts

| Artifact | Path | Size |
|----------|------|------|
| gem5 binary | `build/VEGA_X86/gem5.opt` | ~1.1 GB |
| Disk image | `../gem5-resources/src/x86-ubuntu-gpu-ml/disk-image/x86-ubuntu-rocm70` | ~55 GB |
| Kernel | `../gem5-resources/src/x86-ubuntu-gpu-ml/vmlinux-rocm70` | ~64 MB |
| QEMU binary | `qemu/build/qemu-system-x86_64` | -- |

---

## 3. IP Block Mask Reference

### Discovery Order Table

The `ip_block_mask` parameter uses the **discovery order index** as bit positions, NOT the `amd_ip_block_type` enum values from `amd_shared.h`. The enum values are misleading -- what matters is the order blocks appear during IP discovery.

MI300X discovery order (ROCm 7.0 DKMS, from dmesg):

| Index | IP Block | Bit in Mask | Enabled in 0x67? |
|-------|----------|-------------|-------------------|
| 0 | `soc15_common` | `0x01` | Yes |
| 1 | `gmc_v9_0` | `0x02` | Yes |
| 2 | `vega20_ih` | `0x04` | Yes |
| 3 | `psp` | `0x08` | **No** (disabled) |
| 4 | `smu` | `0x10` | **No** (disabled) |
| 5 | `gfx_v9_4_3` | `0x20` | Yes |
| 6 | `sdma_v4_4_2` | `0x40` | Yes |
| 7 | `vcn_v4_0_3` | `0x80` | No (not needed) |
| 8 | `jpeg_v4_0_3` | `0x100` | No (not needed) |

### Bit Mask Calculation

The driver checks `(amdgpu_ip_block_mask & (1 << i))` where `i` is the discovery order index (`amdgpu_device.c:2807`).

```
0x67 = 0110_0111 (binary)
       ||||_||||
       |||| |||+-- bit 0: soc15_common  (enabled)
       |||| ||+--- bit 1: gmc_v9_0      (enabled)
       |||| |+---- bit 2: vega20_ih     (enabled)
       |||| +----- bit 3: psp           (DISABLED)
       |||+------- bit 4: smu           (DISABLED)
       ||+-------- bit 5: gfx_v9_4_3    (enabled)
       |+--------- bit 6: sdma_v4_4_2   (enabled)
       +---------- bit 7: vcn_v4_0_3    (disabled)
```

### Common Mask Values

| Mask | Binary | Enables | Use Case |
|------|--------|---------|----------|
| `0x67` | `0110_0111` | common, GMC, IH, GFX, SDMA | **Cosim (correct)** |
| `0x6f` | `0110_1111` | common, GMC, IH, PSP, GFX, SDMA | **Wrong -- PSP causes kernel panic** |
| `0xFF` | `1111_1111` | All blocks including PSP+SMU | Real hardware only |

---

## 4. Known Issues and Pitfalls

### 4.1 VGA ROM NULL Dereference

| | |
|---|---|
| **Symptom** | `modprobe amdgpu` causes kernel NULL pointer dereference at `amdgpu_atom_parse_data_header+0x1b`. Call chain: `amdgpu_ras_init` -> `amdgpu_atomfirmware_mem_ecc_supported` -> `amdgpu_atom_parse_data_header`. RAX=0 (NULL `atom_context`) |
| **Root Cause** | All five BIOS discovery methods fail in cosim mode (see [Section 1.3](#13-dd-command-parameters-vga-rom)). The driver logs `"Unable to locate a BIOS ROM"` and proceeds, but the RAS init path unconditionally calls `amdgpu_atom_parse_data_header()` without NULL-checking `atom_context`. QEMU's `romfile=` property is insufficient -- the amdgpu driver uses SMU register-based ROM access, not the PCI ROM BAR |
| **Fix** | Run `dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128` **before** `modprobe`. The `cosim-gpu-setup.service` does this automatically |

### 4.2 PSP / SMU Firmware Load Failure

| | |
|---|---|
| **Symptom** | `PSP load tmr failed!`, `hw_init of IP block <psp> failed -22`, `Fatal error during GPU init` |
| **Root Cause** | `ip_block_mask=0x6f` enables PSP (discovery index 3) but cosim does not model PSP hardware. The `amd_ip_block_type` enum in `amd_shared.h` shows PSP=4, but the mask uses discovery order where PSP is index 3 |
| **Fix** | Use `ip_block_mask=0x67` to disable both PSP (bit 3) and SMU (bit 4). See [Section 3](#3-ip-block-mask-reference) |

### 4.3 SIGIO Coalescing Deadlock (Legacy Backend Only)

| | |
|---|---|
| **Symptom** | Driver hangs on first INDEX2/DATA2 register pair access. gem5 stops responding after ~15 messages. QEMU socket buffer fills up |
| **Root Cause** | Linux FASYNC/SIGIO is edge-triggered. When QEMU sends a write + read in quick succession, both arrive before gem5's SIGIO handler fires. Only one signal is delivered; the handler reads one message and the second is stranded forever |
| **Fix** | `MI300XGem5Cosim::handleClientData()` uses a `do/while` drain loop with `poll(fd, POLLIN, 0)` to read all pending messages per SIGIO. Not applicable to vfio-user backend (uses libvfio-user's non-blocking poll) |

### 4.4 GART Table Not Populated in Co-simulation

| | |
|---|---|
| **Symptom** | Massive `GART translation for X not found` warnings. PM4 reads all-zero memory (opcode 0x0). KIQ ring test times out |
| **Root Cause** | In both backends, VRAM is backed by shared memory (`/dev/shm/mi300x-vram`). Driver writes to VRAM bypass gem5's memory system entirely, so `AMDGPUVM::gartTable` hash map is never populated via `AMDGPUDevice::writeFrame()` |
| **Fix** | Co-simulation fallback in `GARTTranslationGen::translate()`: when `gartTable` misses, read the PTE directly from shared VRAM at `vramShmemPtr + (gartBase - fbBase) + gart_byte_offset`. Key detail: `getGARTAddr()` already multiplies the page index by 8, so `bits(vaddr, 63, 12)` is already a byte offset -- do not multiply by 8 again |

### 4.5 GART Unmapped Page Crash

| | |
|---|---|
| **Symptom** | After `hipMalloc OK`, gem5 segfaults with repeated `GART translation for 0x3fff800000000 not found`. Memory exhaustion from infinite DMA retry |
| **Root Cause** | GPU PM4/SDMA engines attempt DMA to GART pages the driver has not mapped (PTE=0). The original code created `GenericPageTableFault`, but the DMA callback chain retried the same failing address infinitely |
| **Fix** | Unmapped GART pages are mapped to a sink (`paddr=0`). DMA reads return zeros, writes are discarded, simulation stays alive. This is normal: the first page at `ptStart` is simply unmapped |

### 4.6 SDMA Ring Test Timeout

| | |
|---|---|
| **Symptom** | SDMA ring test returns `-110` (`-ETIMEDOUT`) during driver initialization. `sdma v4_4_2: ring 0 test failed (-110)` |
| **Root Cause** | `sdma_delay` in `sdma_engine.hh` defaults to `1e9` ticks. In cosim mode, this translates to ~500ms wall-clock time, exceeding the driver's ~200ms timeout window. Flow: driver writes to SDMA ring, rings doorbell, gem5 schedules SDMA event with `sdma_delay` ticks delay, driver times out before gem5 completes |
| **Fix** | Reduced `sdma_delay` from `1e9` to `1000` ticks. Increased `KEEPALIVE_INTERVAL` to `1e9` to prevent keepalive interference |

### 4.7 VRAM Address GART Translation Error

| | |
|---|---|
| **Symptom** | Address `0x1f72fa8000` triggers 861,000+ GART translation errors, memory exhaustion, segfault |
| **Root Cause** | SDMA rptr writeback and PM4 RELEASE_MEM destination addresses may point to VRAM (address < 16 GiB). When these pass through `getGARTAddr()`, page number is multiplied by 8, and GART lookup fails because VRAM has no page table entries |
| **Fix** | Three-layer defense: (1) PM4: `writeData()`, `releaseMem()`, `queryStatus()` check `isVRAMAddress(addr)` and route to `getMemMgr()->writeRequest()`. (2) SDMA: `setGfxRptrLo/Hi()` and rptr writeback skip `getGARTAddr()` for VRAM addresses. (3) GART fallback: detect VRAM addresses and map to sink (`paddr=0`) |

### 4.8 Shared Memory File Offset Mismatch

| | |
|---|---|
| **Symptom** | GART page table entries read back as all zeros. PM4 opcode 0x0 (NOP, count 0) repeats infinitely |
| **Root Cause** | QEMU Q35 with 8 GiB RAM: `below_4g = 2 GiB` (hardcoded when `ram_size >= 0xB0000000`). gem5 configured as 3 GiB below / 5 GiB above. QEMU places above-4G data at file offset 2 GiB; gem5 reads from offset 3 GiB -- all zeros |
| **Fix** | `mi300_cosim.py` replicates the Q35 split logic: `below_4g = min(total_mem, 0x80000000 if total_mem >= 0xB0000000 else 0xB0000000)` |

### 4.9 Timer Overflow Crash

| | |
|---|---|
| **Symptom** | After billions of ticks, gem5 crashes due to `curTick()` integer overflow. `schedule()` assertion failure |
| **Root Cause** | RTC and PIT timers continuously schedule events, causing tick counter overflow in cosim's long-running mode |
| **Fix** | Added `disable_rtc_events` parameter to `Cmos` and `disable_timer_events` to `I8254`. Both disabled in `mi300_cosim.py`. A keepalive event in the cosim bridge prevents the event queue from becoming empty |

### 4.10 PM4ReleaseMem.dataSelect Panic

| | |
|---|---|
| **Symptom** | gem5 panics with `Unimplemented PM4ReleaseMem.dataSelect` |
| **Root Cause** | `pm4_packet_processor.cc` only implemented `dataSelect == 1` (32-bit data write). Driver uses other modes during GFX initialization |
| **Fix** | Added all common dataSelect values: 0 = no data (event trigger only), 1 = 32-bit write (existed), 2 = 64-bit write, 3 = 64-bit GPU clock counter, other = warn and no-op |

### 4.11 Unsupported PM4 Opcodes

| | |
|---|---|
| **Symptom** | gem5 crashes on unrecognized PM4 opcode |
| **Root Cause** | `ACQUIRE_MEM` (0x58) and `SET_RESOURCES` (0xA0) were not handled |
| **Fix** | Both added to `pm4_defines.hh` and handled in `pm4_packet_processor.cc:decodeHeader()` as skip-and-continue (NOP) |

### 4.12 PCI Class Code Mismatch

| | |
|---|---|
| **Symptom** | amdgpu driver skips the legacy VGA ROM check at `0xC0000` |
| **Root Cause** | PCI class was `PCI_CLASS_DISPLAY_OTHER (0x0380)` instead of `PCI_CLASS_DISPLAY_VGA (0x0300)` |
| **Fix** | Changed to `PCI_CLASS_DISPLAY_VGA`. Kernel now recognizes the address range as "shadowed ROM" |

### 4.13 QEMU Serial Console Conflict

| | |
|---|---|
| **Symptom** | No serial output from guest when using `-serial unix:/tmp/serial.sock -nographic` together |
| **Root Cause** | `-nographic` implies `-serial mon:stdio`, creating serial0 on stdio. Explicit `-serial unix:...` becomes serial1 (ttyS1), but kernel uses `console=ttyS0` |
| **Fix** | Use `-nographic` alone. For programmatic access, run QEMU inside `screen` |

### 4.14 OOM During gem5 Linking

| | |
|---|---|
| **Symptom** | Linker killed by OOM killer even with `-j2` |
| **Root Cause** | Default linker uses too much memory |
| **Fix** | Use `scons build/VEGA_X86/gem5.opt -j1 GOLD_LINKER=True --linker=gold` |

### 4.15 DRM Client Error -13 (Missing DKMS Module)

| | |
|---|---|
| **Symptom** | `Failed to init DRM client: -13` followed by kernel panic. NULL pointer dereference in `ttm_resource_move_to_lru_tail` |
| **Root Cause** | Disk image missing `amddrm_exec.ko.zst` DKMS module. Without it, TTM memory manager fails, `drm_dev_enter()` returns `-EACCES` (-13) |
| **Fix** | Rebuild disk image using latest `gem5-resources` (`origin/stable` branch). Verify with `guestfish` that `amddrm_exec.ko.zst` exists in `/lib/modules/6.8.0-79-generic/updates/dkms/` |

### 4.16 Driver rmmod After hw_init Failure

| | |
|---|---|
| **Symptom** | After a driver `hw_init` failure, `rmmod amdgpu` causes kernel oops (page fault in `kgd2kfd_device_exit`). Module gets stuck in "busy" state |
| **Root Cause** | Cleanup path not robust after partial initialization |
| **Fix** | No workaround. Restart the entire cosim environment (kill QEMU, restart gem5 Docker container, restart QEMU) |

---

## 5. Debugging Quick Reference

### gem5 Debug Flags

| Flag Combination | What It Shows |
|------------------|---------------|
| `MI300XCosim` | Cosim socket/vfio-user messages |
| `AMDGPUDevice` | MMIO register reads/writes |
| `PM4PacketProcessor` | PM4 packet decode and processing |
| `SDMAEngine` | SDMA operations |
| `AMDGPUDevice,PM4PacketProcessor` | MMIO + PM4 (combined) |
| `MI300XCosim,AMDGPUDevice,PM4PacketProcessor` | Full cosim debug |

Usage:

```bash
./scripts/cosim_launch.sh --gem5-debug MI300XCosim
# or manual:
build/VEGA_X86/gem5.opt --debug-flags=MI300XCosim,AMDGPUDevice ...
```

### QEMU Trace Events

```bash
./scripts/cosim_launch.sh --qemu-trace 'mi300x_gem5_*'
```

### Log Inspection Commands

```bash
# gem5 container logs (stderr)
docker logs gem5-cosim 2>&1 | tee /tmp/gem5.log

# Filter for warnings/errors
docker logs gem5-cosim 2>&1 | grep -E "warn|error|GART"

# Guest dmesg (via screen)
screen -S qemu-cosim -X stuff 'dmesg | tail -20\n'

# Guest serial output (standalone sim)
tail -f m5out/board.pc.com_1.device
```

### Socket Test

```bash
python3 scripts/cosim_test_client.py /tmp/gem5-mi300x.sock
```

### Incremental Rebuild

```bash
# Delete stale object file, then rebuild
docker run --rm -v "$PWD:/gem5" -w /gem5 gem5-run:local \
    sh -c 'rm -f build/VEGA_X86/dev/amdgpu/<file>.o'
docker run --rm -v "$PWD:/gem5" -w /gem5 \
    gem5-run:local scons build/VEGA_X86/gem5.opt -j1
```

### Quick Diagnostic Table

| Symptom | First Check |
|---------|-------------|
| gem5 container exits immediately | `docker logs gem5-cosim` |
| QEMU fails to connect | Is gem5 ready? (`chmod 777` socket?) |
| NULL deref at `psp_gpu_reset` | Wrong `ip_block_mask` (use `0x67`) |
| GART translation not found | Using latest gem5 binary? |
| SDMA ring test -110 | Check `sdma_delay` is `1000` |
| hipcc "cannot find ROCm device library" | `ls /opt/rocm/lib/`, use `--offload-arch=gfx942` |
| MMIO reads all return zero | gem5 not connected or crashed |
| `insmod: ERROR: could not load module` | Kernel version mismatch |
| `cosim-gpu-setup.service` failed | `journalctl -u cosim-gpu-setup` |
| BAR layout probe error -12 | Rebuild QEMU with correct BAR5=MMIO layout |

---

## 6. GART Table Format and PTE Layout

For conceptual explanation of GPU address spaces and translation flow, see architecture.md Section 5.

### GART PTE Format

Each GART page table entry is 8 bytes:

| Bit Range | Field | Description |
|-----------|-------|-------------|
| 0 | Valid | Entry is valid |
| 1 | System | 1 = system memory, 0 = local VRAM |
| 5:2 | Fragment | Page fragment size |
| 47:12 | Physical Page | Physical address >> 12 |
| 51:48 | Block Fragment | Block fragment size |
| 63:52 | Flags | MTYPE, PRT, etc. |

**Physical address extraction**: `paddr = (bits(PTE, 47, 12) << 12) | page_offset`

### Aperture Registers

| Register | gem5 Field | Format | Description |
|----------|-----------|--------|-------------|
| `MC_VM_FB_LOCATION_BASE` | `vmContext0.fbBase` | `bits[23:0] << 24` | Start of VRAM in MC address space |
| `MC_VM_FB_LOCATION_TOP` | `vmContext0.fbTop` | `bits[23:0] << 24 \| 0xFFFFFF` | End of VRAM |
| `MC_VM_FB_OFFSET` | `vmContext0.fbOffset` | `bits[23:0] << 24` | FB relocation offset |
| `MC_VM_AGP_BASE` | `vmContext0.agpBase` | `bits[23:0] << 24` | AGP remap base address |
| `MC_VM_AGP_BOT` | `vmContext0.agpBot` | `bits[23:0] << 24` | AGP aperture bottom |
| `MC_VM_AGP_TOP` | `vmContext0.agpTop` | `bits[23:0] << 24 \| 0xFFFFFF` | AGP aperture top |
| `MC_VM_SYSTEM_APERTURE_LOW_ADDR` | `vmContext0.sysAddrL` | `bits[29:0] << 18` | System aperture low |
| `MC_VM_SYSTEM_APERTURE_HIGH_ADDR` | `vmContext0.sysAddrH` | `bits[29:0] << 18` | System aperture high |
| `VM_CONTEXT0_PAGE_TABLE_BASE_ADDR` | `vmContext0.ptBase` | raw 64-bit | GART table location in VRAM |
| `VM_CONTEXT0_PAGE_TABLE_START_ADDR` | `vmContext0.ptStart` | raw 64-bit | GART aperture start (page number) |
| `VM_CONTEXT0_PAGE_TABLE_END_ADDR` | `vmContext0.ptEnd` | raw 64-bit | GART aperture end (page number) |

### Typical Values in Co-simulation

```
ptBase   = 0x3EE600000     GART table at VRAM offset ~15.7 GiB
ptStart  = 0x7FFF00000     GART covers GPU VAs from 0x7FFF00000000
ptEnd    = 0x7FFF1FFFF     GART covers ~128K pages (512 MiB)
fbBase   = 0x8000000000    VRAM starts at MC address 512 GiB
fbTop    = 0x8400FFFFFF    VRAM ends at ~528 GiB (16 GiB range)
sysAddrL = 0x0             System aperture start
sysAddrH = 0x3FFEC0000     System aperture end (~4 TiB)
```

### GART Table Layout in VRAM

```
VRAM offset = ptBase (gartBase)
+-------------------+  ptBase + 0
| PTE[0]  (8 bytes) |  maps page ptStart
+-------------------+  ptBase + 8
| PTE[1]            |  maps page ptStart + 1
+-------------------+  ptBase + 16
| PTE[2]            |  maps page ptStart + 2
| ...               |
+-------------------+
| PTE[N]            |  maps page ptStart + N
+-------------------+  ptBase + (ptEnd - ptStart + 1) * 8
```

### Co-simulation PTE Fallback Lookup

In cosim mode, `gartTable` is empty (VRAM writes bypass gem5). The fallback reads PTEs directly from shared VRAM:

```cpp
Addr pte_table_offset = gart_addr - (ptStart * 8);
Addr pte_vram_offset = gartBase() + pte_table_offset;
memcpy(&pte, vramShmemPtr + pte_vram_offset, sizeof(pte));
```

If PTE is 0 (unmapped), the address is mapped to sink (`paddr=0`) instead of faulting.

---

## 7. China Mirror Configuration

When building disk images from China, `apt` inside the VM fetches from `us.archive.ubuntu.com`, which often hangs (Packer reports `Timeout waiting for SSH`, or the provisioner aborts during ROCm installation).

### Apply the Patch

```bash
cd gem5-resources
git apply ../scripts/patches/0001-user-data-cn-mirror.patch
```

### Revert the Patch

```bash
cd gem5-resources
git apply -R ../scripts/patches/0001-user-data-cn-mirror.patch
```

To use a different mirror, edit the URI in the patch file and re-apply.

---

## 8. File Reference

### gem5 Source Files (`src/dev/amdgpu/`)

| File | Purpose |
|------|---------|
| `mi300x_vfio_user.{cc,hh}` | vfio-user server SimObject (**default backend**) |
| `MI300XVfioUser.py` | SimObject Python wrapper (vfio-user) |
| `cosim_bridge.hh` | Abstract CosimBridge interface (both backends implement this) |
| `mi300x_gem5_cosim.{cc,hh}` | Legacy socket bridge SimObject |
| `MI300XGem5Cosim.py` | SimObject Python wrapper (legacy) |
| `amdgpu_device.cc` | GPU device model core, `readROM()`, `intrPost()`, `writeFrame()` |
| `amdgpu_vm.{cc,hh}` | All translation generators (GART, AGP, MMHUB, User), cosim VRAM fallback |
| `pm4_packet_processor.{cc,hh}` | PM4 packet decode, DMA routing, VRAM write routing, `isVRAMAddress()` |
| `pm4_defines.hh` | PM4 opcodes including `IT_ACQUIRE_MEM`, `IT_SET_RESOURCES` |
| `sdma_engine.{cc,hh}` | SDMA operations, rptr writeback routing, `sdma_delay` parameter |
| `interrupt_handler.cc` | IH ring buffer DMA and MSI-X interrupt delivery |
| `amdgpu_nbio.cc` | ASIC initialization complete register |

### gem5 Configuration and Scripts

| File | Purpose |
|------|---------|
| `configs/example/gpufs/mi300_cosim.py` | Cosim system config (`--cosim-backend=vfio-user\|legacy`) |
| `configs/example/gem5_library/x86-mi300x-gpu.py` | Standalone stdlib simulation config |
| `configs/example/gpufs/mi300.py` | Legacy standalone simulation config |
| `scripts/cosim_launch.sh` | Cosim orchestration (Docker + QEMU launch) |
| `scripts/run_mi300x_fs.sh` | Build orchestration (compile, disk image, run) |
| `scripts/Dockerfile.run` | Runtime Docker image definition |
| `scripts/cosim_test_client.py` | Socket connectivity test tool |
| `scripts/patches/0001-user-data-cn-mirror.patch` | China mirror patch for disk image build |

### gem5 Modified Infrastructure Files

| File | Changes |
|------|---------|
| `src/dev/intel_8254_timer.{cc,hh}` | `disable_timer_events` parameter (cosim timer overflow fix) |
| `src/dev/mc146818.{cc,hh}` | `disable_rtc_events` parameter (cosim timer overflow fix) |

### gem5 Python Components

| File | Purpose |
|------|---------|
| `src/python/gem5/prebuilt/viper/board.py` | ViperBoard: readfile injection, driver loading |
| `src/python/gem5/components/devices/gpus/amdgpu.py` | MI300X device definition |

### QEMU Files (Legacy Backend Only)

| File | Purpose |
|------|---------|
| `qemu/hw/misc/mi300x_gem5.c` | MI300X PCI device with socket bridge |
| `qemu/hw/misc/mi300x_gem5.h` | Header file |
| `qemu/hw/misc/trace-events` | Trace event definitions |

> The vfio-user backend uses QEMU's built-in `vfio-user-pci` device. No custom QEMU code is needed.

### External Dependencies

| Path | Purpose |
|------|---------|
| `ext/libvfio-user/` | libvfio-user library (git submodule, vfio-user backend) |

### Guest Disk Image Contents

| File (inside guest) | Purpose |
|----------------------|---------|
| `/root/roms/mi300.rom` | VGA BIOS ROM binary |
| `/usr/lib/firmware/amdgpu/mi300_discovery` | IP discovery firmware |
| `/etc/systemd/system/cosim-gpu-setup.service` | Auto-load service unit |
| `/usr/local/bin/cosim-gpu-setup.sh` | Auto-load script |
| `/lib/modules/$(uname -r)/updates/dkms/amdgpu.ko.zst` | amdgpu kernel module (ROCm 7.0 DKMS) |
| `/home/gem5/load_amdgpu.sh` | Driver loading script (standalone sim) |
| `/sbin/m5` | gem5 pseudo-instruction tool |

### PCI BAR Layout

| BAR | Resource | Type | Size |
|-----|----------|------|------|
| BAR0+1 | VRAM | 64-bit prefetchable | 16 GiB (shared memory) |
| BAR2+3 | Doorbell | 64-bit | 4 MiB |
| BAR4 | MSI-X | exclusive | -- |
| BAR5 | MMIO registers | 32-bit | 512 KiB (forwarded to gem5) |

Driver constants: `AMDGPU_VRAM_BAR=0`, `AMDGPU_DOORBELL_BAR=2`, `AMDGPU_MMIO_BAR=5`.

### Resource Routing (Both Backends)

| Resource | Via Socket/vfio-user? | Via Shared Memory? |
|----------|----------------------|--------------------|
| MMIO Registers (BAR5) | Yes | No |
| VRAM (BAR0, 16 GiB) | **No** | Yes (`/dev/shm/mi300x-vram`) |
| Doorbells (BAR2) | Yes | No |

Any gem5 data structure populated by intercepting VRAM writes (e.g., `gartTable`, page tables, ring buffers) will **not** be populated in cosim mode and requires explicit shared-VRAM fallback.
