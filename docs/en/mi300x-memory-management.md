[中文](../zh/mi300x-memory-management.md)

# MI300X Memory Management, Address Translation, and Mapping

This document describes how the AMD MI300X GPU manages memory addresses in both standalone gem5 simulation and QEMU+gem5 co-simulation environments.

## 1. GPU Address Spaces

The MI300X (GFX 9.4.3) GPU uses multiple address spaces and apertures to access memory. Each memory access issued by the GPU is first classified by aperture, then translated into a physical address.

```
GPU Virtual Address (48-bit)
│
├─ AGP aperture      [agpBot, agpTop]
│  └─ Direct offset:  paddr = vaddr - agpBot + agpBase
│
├─ GART aperture     [ptStart<<12, ptEnd<<12]
│  └─ Page table:     paddr = GART_PTE[page_num].phys_addr | offset
│
├─ Framebuffer (FB)  [fbBase, fbTop]
│  └─ VRAM offset:    vram_off = vaddr - fbBase
│
├─ System aperture   [sysAddrL, sysAddrH]
│  └─ Direct map:     paddr = vaddr  (system memory)
│
├─ MMHUB aperture    [mmhubBase, mmhubTop]
│  └─ VRAM mirror:    vram_off = vaddr - mmhubBase
│
└─ User VM (VMID>0)  [arbitrary VAs]
   └─ Multi-level page table walk (4 or 5 levels)
```

### 1.1 Aperture Registers

These MMIO registers define the boundaries of each aperture. The values are programmed by the amdgpu driver during GMC (Graphics Memory Controller) initialization.

| Register | gem5 Field | Format | Description |
|----------|-----------|--------|-------------|
| `MC_VM_FB_LOCATION_BASE` | `vmContext0.fbBase` | `bits[23:0] << 24` | Start address of VRAM in MC address space |
| `MC_VM_FB_LOCATION_TOP` | `vmContext0.fbTop` | `bits[23:0] << 24 \| 0xFFFFFF` | End address of VRAM |
| `MC_VM_FB_OFFSET` | `vmContext0.fbOffset` | `bits[23:0] << 24` | FB relocation offset |
| `MC_VM_AGP_BASE` | `vmContext0.agpBase` | `bits[23:0] << 24` | AGP remap base address |
| `MC_VM_AGP_BOT` | `vmContext0.agpBot` | `bits[23:0] << 24` | AGP aperture bottom |
| `MC_VM_AGP_TOP` | `vmContext0.agpTop` | `bits[23:0] << 24 \| 0xFFFFFF` | AGP aperture top |
| `MC_VM_SYSTEM_APERTURE_LOW_ADDR` | `vmContext0.sysAddrL` | `bits[29:0] << 18` | System aperture low address |
| `MC_VM_SYSTEM_APERTURE_HIGH_ADDR` | `vmContext0.sysAddrH` | `bits[29:0] << 18` | System aperture high address |
| `VM_CONTEXT0_PAGE_TABLE_BASE_ADDR` | `vmContext0.ptBase` | raw 64-bit | Location of GART table in VRAM |
| `VM_CONTEXT0_PAGE_TABLE_START_ADDR` | `vmContext0.ptStart` | raw 64-bit | GART aperture start address (page number) |
| `VM_CONTEXT0_PAGE_TABLE_END_ADDR` | `vmContext0.ptEnd` | raw 64-bit | GART aperture end address (page number) |

**Typical values in co-simulation** (from driver initialization diagnostics):
```
ptBase   = 0x3EE600000     GART table at VRAM offset ~15.7 GiB
ptStart  = 0x7FFF00000     GART covers GPU VAs from 0x7FFF00000000
ptEnd    = 0x7FFF1FFFF     GART covers ~128K pages (512 MiB)
fbBase   = 0x8000000000    VRAM starts at MC address 512 GiB
fbTop    = 0x8400FFFFFF    VRAM ends at ~528 GiB (16 GiB range)
sysAddrL = 0x0             System aperture start
sysAddrH = 0x3FFEC0000     System aperture end (~4 TiB)
```

## 2. GART (Graphics Address Remapping Table)

### 2.1 Overview

GART is a single-level page table used by VMID 0 (kernel mode) to map GPU virtual addresses to system physical addresses. It enables the GPU to perform DMA access to host (guest) RAM for ring buffers, fence values, IH cookies, and other kernel-mode data structures.

### 2.2 Table Layout

```
VRAM offset = ptBase (gartBase)
┌─────────────────┐  ptBase + 0
│ PTE[0]  (8 bytes)│  maps page ptStart
├─────────────────┤  ptBase + 8
│ PTE[1]          │  maps page ptStart + 1
├─────────────────┤  ptBase + 16
│ PTE[2]          │  maps page ptStart + 2
│ ...             │
├─────────────────┤
│ PTE[N]          │  maps page ptStart + N
└─────────────────┘  ptBase + (ptEnd - ptStart + 1) * 8
```

Each PTE is 8 bytes with the following format:

| Bit Range | Field | Description |
|------|-------|-------------|
| 0 | Valid | Entry is valid |
| 1 | System | 1 = system memory, 0 = local VRAM |
| 5:2 | Fragment | Page fragment size |
| 47:12 | Physical Page | Physical address >> 12 |
| 51:48 | Block Fragment | Block fragment size |
| 63:52 | Flags | MTYPE, PRT, etc. |

**Physical address extraction**: `paddr = (bits(PTE, 47, 12) << 12) | page_offset`

### 2.3 getGARTAddr Transform

Before GART lookup, addresses are transformed via `getGARTAddr()`:

```cpp
// In pm4_packet_processor.cc and sdma_engine.cc:
Addr getGARTAddr(Addr addr) const {
    if (!gpuDevice->getVM().inAGP(addr)) {
        Addr low_bits = bits(addr, 11, 0);
        addr = (((addr >> 12) << 3) << 12) | low_bits;
    }
    return addr;
}
```

This function multiplies the page number by 8 (the size of a PTE), effectively converting a GPU VA into a byte offset within the GART table. The subsequent GART translation uses this transformed address to look up the PTE.

### 2.4 Translation Flow

```
Original GPU VA (e.g., 0x7FFF00032000)
  │
  ▼ getGARTAddr()
Transformed addr = ((VA>>12) * 8) << 12 | low_bits
                 = 0x3FFF80019_0000  (example)
  │
  ▼ GARTTranslationGen::translate()
gart_addr = bits(transformed, 63, 12) = page_num * 8
  │
  ├─ Look up gartTable hash map (populated by writeFrame / SDMA shadow)
  │
  ├─ Cosim fallback: read PTE from shared VRAM
  │   pte_offset = gart_addr - (ptStart * 8)
  │   pte = *(vramShmemPtr + ptBase + pte_offset)
  │
  ▼ Extract physical address
paddr = (bits(PTE, 47, 12) << 12) | bits(VA, 11, 0)
```

### 2.5 gartTable Hash Map vs. Shared VRAM

In standalone gem5 mode, GART entries are maintained in a hash map (`AMDGPUVM::gartTable`), populated by:

1. **Direct writes** (`amdgpu_device.cc:writeFrame()`): When the driver writes to the GART region of VRAM via BAR0, the values are stored in `gartTable[offset]`.

2. **SDMA shadow copies** (`sdma_engine.cc`): When SDMA writes to the GART range in device memory, the shadow copy updates `gartTable`.

In co-simulation mode, the driver writes GART PTEs through QEMU's BAR0 mapping, going directly into shared VRAM without passing through gem5's `writeFrame()`. Therefore, `gartTable` is essentially empty. The co-simulation fallback reads PTEs directly from shared VRAM at `vramShmemPtr + ptBase`.

## 3. MMHUB Aperture

MMHUB (Memory Management Hub) provides a shadow mapping of VRAM. Addresses within the `[mmhubBase, mmhubTop]` range are translated by subtracting the base address:

```
vram_offset = vaddr - mmhubBase
```

SDMA uses this aperture to access device memory in VMID 0 mode.

## 4. User-Space Translation (VMID > 0)

User-space GPU programs (such as HIP applications) use multi-level page tables similar to x86-64 paging. Each VMID (1-15) has its own page table base register.

```
VM_CONTEXT[N]_PAGE_TABLE_BASE_ADDR  → Page Directory Base
  │
  ▼ 4-level walk (PDE3 → PDE2 → PDE1 → PDE0 → PTE)
Physical address
```

The `UserTranslationGen` class performs this walk using the GPU's page table walker (`VegaISA::Walker`). SDMA in user mode (vmid > 0) uses this path.

## 5. DMA Routing in gem5

### 5.1 PM4 Packet Processor

```
PM4PacketProcessor::translate(vaddr, size)
  │
  ├─ inAGP(vaddr)?  → AGPTranslationGen  (direct offset)
  │
  └─ else           → GARTTranslationGen  (page table lookup)
```

All PM4 DMA uses GART translation (VMID 0). Addresses are transformed via `getGARTAddr()` before the DMA call.

### 5.2 SDMA Engine

```
SDMAEngine::translate(vaddr, size)
  │
  ├─ cur_vmid > 0?  → UserTranslationGen  (multi-level page table)
  │
  ├─ inAGP(vaddr)?  → AGPTranslationGen
  │
  ├─ inMMHUB(vaddr)?→ MMHUBTranslationGen (VRAM shadow)
  │
  └─ else           → GARTTranslationGen
```

SDMA has more aperture awareness than PM4, as it handles both kernel-mode (VMID 0) and user-mode (VMID > 0) operations.

### 5.3 VRAM vs. System Memory Detection

For PM4's RELEASE_MEM and WRITE_DATA packets, the destination can be either VRAM or system memory. Routing works as follows:

```cpp
bool vram = isVRAMAddress(pkt->addr);  // addr < gpuDevice->getVRAMSize()
Addr addr = vram ? pkt->addr : getGARTAddr(pkt->addr);

if (vram)
    gpuDevice->getMemMgr()->writeRequest(addr, data, size);  // device memory
else
    dmaWriteVirt(addr, size, cb, data);  // system memory via GART
```

## 6. Interrupt Handler (IH) DMA

The interrupt handler uses raw system physical addresses (not GART):

```
IH Ring Buffer:  regs.baseAddr    (from IH_RB_BASE register)
Wptr Address:    regs.WptrAddr    (from IH_RB_WPTR_ADDR registers)
```

These are GPAs (Guest Physical Addresses) programmed by the driver. The IH write flow:
1. Write the interrupt cookie (32 bytes) to `baseAddr + IH_Wptr`
2. Write the updated write pointer to `WptrAddr`
3. Then call `intrPost()` to send an MSI-X interrupt to the guest

In co-simulation mode, DMA writes land in shared guest RAM (`/dev/shm/cosim-guest-ram`), and interrupts are forwarded to QEMU via the event socket.

## 7. Co-simulation Memory Architecture

```
┌─────────────────────────────────────────────────────┐
│                 Host (Linux)                        │
│                                                     │
│  /dev/shm/cosim-guest-ram  (8 GiB)                 │
│  ┌────────────────────────────────────────────┐     │
│  │  Guest Physical RAM                        │     │
│  │  ← QEMU memory-backend-file (share=on)    │     │
│  │  ← gem5 system.shared_backstore            │     │
│  │                                             │     │
│  │  Contains: page tables, ring buffers,       │     │
│  │  IH ring, fence values, kernel code/data    │     │
│  └────────────────────────────────────────────┘     │
│                                                     │
│  /dev/shm/mi300x-vram  (16 GiB)                    │
│  ┌────────────────────────────────────────────┐     │
│  │  GPU VRAM                                   │     │
│  │  ← QEMU BAR0 mmap (driver writes here)     │     │
│  │  ← gem5 vramShmemPtr (GPU model reads)      │     │
│  │                                             │     │
│  │  Contains: GART page table, GPU page tables,│     │
│  │  frame data, device-local allocations       │     │
│  │                                             │     │
│  │  Layout:                                    │     │
│  │  [0, ~15.7G)     General VRAM allocations   │     │
│  │  [0x3EE600000]   GART page table (ptBase)   │     │
│  │  [~15.7G, 16G)   Reserved / metadata        │     │
│  └────────────────────────────────────────────┘     │
│                                                     │
│  /tmp/gem5-mi300x.sock  (Unix domain socket)        │
│  ┌────────────────────────────────────────────┐     │
│  │  MMIO connection:  QEMU ←→ gem5 (sync)     │     │
│  │  Event connection: gem5  → QEMU (async)     │     │
│  │    - IRQ raise/lower                        │     │
│  │    - DMA read/write requests                │     │
│  └────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────┘
```

### 7.1 Memory Split (Q35)

QEMU Q35 splits memory into two regions when RAM >= 2.75 GiB:
- Below-4G region: first 2 GiB (file offset 0)
- Above-4G region: the remainder at file offset 2 GiB, mapped to PA 0x100000000+

gem5's `mi300_cosim.py` replicates this split to ensure both sides maintain a consistent file layout.

### 7.2 GART PTE Co-simulation Fallback

Since the driver writes GART PTEs through QEMU's BAR0 (shared memory), gem5's `gartTable` hash map is not populated. The co-simulation fallback reads PTEs directly from shared VRAM:

```cpp
Addr pte_table_offset = gart_addr - (ptStart * 8);
Addr pte_vram_offset = gartBase() + pte_table_offset;
memcpy(&pte, vramShmemPtr + pte_vram_offset, sizeof(pte));
```

If a PTE is 0 (unmapped page), co-simulation mode maps to a sink (`paddr=0`) instead of faulting, avoiding infinite DMA retry crashes caused by `GenericPageTableFault`.

## 8. Address Flow Examples

### 8.1 Fence Write (RELEASE_MEM)

```
1. PM4 RELEASE_MEM packet: addr=0x113100000 (guest phys), data=0x1234
2. isVRAMAddress(0x113100000)? No (< 16 GiB but not a VRAM offset)
3. getGARTAddr(0x113100000) → 0x899800000000 (page * 8 transform)
4. dmaWriteVirt(0x899800000000, 8, cb, &data)
5. GARTTranslationGen::translate()
   - gart_addr = 0x89980000
   - Look up PTE from shared VRAM → PTE has paddr bits
   - paddr = extracted address (in guest RAM)
6. DMA write lands in /dev/shm/cosim-guest-ram at paddr offset
7. Guest driver reads fence value from same shared memory
```

### 8.2 HIP Kernel Dispatch

```
1. User writes AQL packet to queue ring buffer (user VA)
2. User writes doorbell → QEMU → gem5 (socket MMIO)
3. gem5 PM4 reads queue MQD (GART address → guest RAM)
4. gem5 GPU command processor dispatches kernel to CU array
5. CUs execute wavefronts (compute work)
6. On completion: RELEASE_MEM writes fence + triggers interrupt
7. IH writes cookie to IH ring (raw DMA to guest RAM)
8. intrPost() → sendIrqRaise(0) → QEMU event socket
9. QEMU msix_notify() → guest IH handler processes interrupt
10. hipDeviceSynchronize() returns success
```

## 9. Key Source Files

| File | Purpose |
|------|------|
| `src/dev/amdgpu/amdgpu_vm.{cc,hh}` | All translation generators (GART, AGP, MMHUB, User) |
| `src/dev/amdgpu/pm4_packet_processor.cc` | PM4 DMA routing and GART address transform |
| `src/dev/amdgpu/sdma_engine.cc` | SDMA DMA routing, GART shadow copies |
| `src/dev/amdgpu/interrupt_handler.cc` | IH ring buffer DMA and interrupt delivery |
| `src/dev/amdgpu/amdgpu_device.cc` | Device-level intrPost(), writeFrame() |
| `src/dev/amdgpu/mi300x_gem5_cosim.cc` | Co-simulation socket bridge, IRQ forwarding |
| `configs/example/gpufs/mi300_cosim.py` | Memory configuration, shared backstore setup |
