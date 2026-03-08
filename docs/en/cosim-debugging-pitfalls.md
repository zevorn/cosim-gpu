[中文](../zh/cosim-debugging-pitfalls.md)

# MI300X Co-simulation: Debugging Pitfalls and Fixes

This document records bugs encountered and fixed during the QEMU+gem5 MI300X co-simulation bringup process, including some non-obvious root cause analyses.

## 1. SIGIO Coalescing Deadlock (handleClientData Single Read)

**Symptom**: The driver hangs on its first access to the PCIe INDEX2/DATA2 register pair. gem5 stops responding after processing approximately 15 messages.

**Root Cause**: Linux FASYNC/SIGIO is **edge-triggered**. When QEMU sends a fire-and-forget MMIO write immediately followed by a blocking MMIO read, both messages may arrive before gem5's SIGIO handler fires. In this case, only one signal is delivered. The original `handleClientData()` read only one message per SIGIO, leaving the second message stranded forever.

**Fix** (`mi300x_gem5_cosim.cc`): Changed `handleClientData()` to a drain loop that checks for more data using `poll(fd, POLLIN, 0)` after processing each message:

```cpp
void MI300XGem5Cosim::handleClientData(int fd) {
    struct pollfd pfd;
    do {
        CosimMsgHeader msg;
        if (!recvAll(fd, &msg, COSIM_MSG_HDR_SIZE)) {
            closeClient(fd); return;
        }
        processMessage(fd, msg);
        pfd = {fd, POLLIN, 0};
    } while (poll(&pfd, 1, 0) > 0 && (pfd.revents & POLLIN));
}
```

**Lesson**: Any FASYNC-based I/O handler must drain all pending data rather than reading just one message. This pattern (write + read coalescing) is common in PCIe indirect register access.

---

## 2. ip_block_mask Uses Discovery Order, Not Type Enum Values

**Symptom**: `PSP load tmr failed!`, `hw_init of IP block <psp> failed -22`, `Fatal error during GPU init`.

**Root Cause**: The ROCm 7.0 DKMS driver (`amdgpu_device.c:2807`) checks `(amdgpu_ip_block_mask & (1 << i))`, where `i` is the **discovery order index**, not the `amd_ip_block_type` enum value.

MI300X discovery order (from dmesg):

| Index | IP Block        | Bit in Mask |
|-------|-----------------|-------------|
| 0     | soc15_common    | 0x01        |
| 1     | gmc_v9_0        | 0x02        |
| 2     | vega20_ih       | 0x04        |
| 3     | psp             | 0x08        |
| 4     | smu             | 0x10        |
| 5     | gfx_v9_4_3      | 0x20        |
| 6     | sdma_v4_4_2     | 0x40        |
| 7     | vcn_v4_0_3      | 0x80        |
| 8     | jpeg_v4_0_3     | 0x100       |

**Fix**: Changed `ip_block_mask` from `0x6f` to `0x67`:
- `0x6f` = `0110_1111` -- enables common, gmc, ih, **psp**, gfx, sdma
- `0x67` = `0110_0111` -- enables common, gmc, ih, gfx, sdma (disables psp at index 3 and smu at index 4)

**Pitfall**: The `amd_ip_block_type` enum in `amd_shared.h` shows PSP=4, but the actual mask bit for PSP is `(1 << 3)` because PSP is the third block discovered during IP discovery (index 3). The documentation and enum values are misleading.

---

## 3. PM4ReleaseMem.dataSelect Panic

**Symptom**: gem5 panics with `Unimplemented PM4ReleaseMem.dataSelect`.

**Root Cause**: `pm4_packet_processor.cc` only implemented `dataSelect == 1` (32-bit data write). The driver uses other modes during GFX initialization.

**Fix**: Added handling for all common dataSelect values:

| dataSelect | Behavior                                |
|------------|-----------------------------------------|
| 0          | No data written (event trigger only)    |
| 1          | Write 32-bit value (already existed)    |
| 2          | Write 64-bit value                      |
| 3          | Write 64-bit GPU clock counter          |
| Other      | Warn and treat as no-op                 |

---

## 4. GART Table Not Populated in Co-simulation Mode

**Symptom**: Massive `GART translation for X not found` warnings. PM4 processor reads all-zero memory (opcode 0x0). KIQ ring test times out.

**Root Cause**: In co-simulation mode, QEMU's BAR2 (VRAM, 16GB) is backed by a shared memory file (`/dev/shm/mi300x-vram`). Driver writes to VRAM go directly into the shared file, **completely bypassing gem5's socket protocol**. gem5's `AMDGPUVM::gartTable` hash table is populated in `AMDGPUDevice::writeFrame()`, which only executes when writes go through gem5's memory system. Since VRAM writes bypass gem5, `gartTable` remains empty.

**Fix** (`amdgpu_vm.cc` + `amdgpu_vm.hh`): Added a shared VRAM fallback in `GARTTranslationGen::translate()`:

1. Added `vramShmemPtr` / `vramShmemSize` fields to `AMDGPUVM`
2. `MI300XGem5Cosim` sets these fields after mapping the shared VRAM
3. When `gartTable` misses, read the PTE directly from shared VRAM:

```cpp
Addr gart_byte_offset = bits(range.vaddr, 63, 12);
Addr pte_vram_offset = (gartBase() - getFBBase()) + gart_byte_offset;
memcpy(&pte, vramShmemPtr + pte_vram_offset, sizeof(pte));
```

**Key Detail**: `getGARTAddr()` (called before translate) already multiplies the page index by 8 to get a byte offset:
```cpp
addr = (((addr >> 12) << 3) << 12) | low_bits;  // page_num *= 8
```
Therefore `bits(vaddr, 63, 12)` in the translate function is already the PTE's **byte offset**, not a page index. Multiplying by 8 again would cause the address to overshoot 8x into the GART table.

**Architecture Note**: The "expansion formula" in the original translate code (`gart_addr += lsb * 7`) is effectively a no-op for addresses processed by `getGARTAddr()`, because `lsb = (page_num * 8) & 7 = 0` (`page_num * 8` is always 8-aligned, so the lower 3 bits are always zero).

---

## General Notes on Co-simulation Architecture

### Operations That Bypass the Socket Protocol

| Resource         | QEMU BAR | gem5 BAR | Via Socket? | Via Shared Memory? |
|------------------|----------|----------|-------------|--------------------|
| MMIO Registers   | BAR0     | BAR5     | Yes         | No                 |
| VRAM (16GB)      | BAR2     | BAR0     | **No**      | Yes                |
| Doorbells        | BAR4     | BAR2     | Yes         | No                 |

Any gem5 data structure populated by intercepting VRAM writes (such as `gartTable`, page tables, ring buffers) will **not** be populated in co-simulation mode. These structures require explicit fallback mechanisms to read data from the shared VRAM.

### Guest Must Be Rebooted After Driver Load Failure

After a driver `hw_init` failure, executing `rmmod amdgpu` causes a kernel oops (page fault in `kgd2kfd_device_exit`). The module gets stuck in a "busy" state and cannot be reloaded. The only workaround is to restart the entire co-simulation environment (kill QEMU, restart the gem5 Docker container, restart QEMU).
