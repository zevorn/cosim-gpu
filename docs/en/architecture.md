[中文](../zh/architecture.md)

# Co-simulation Architecture

This document provides a deep-dive into the architecture and design of the QEMU + gem5 MI300X co-simulation system. It covers the system-level structure, memory sharing mechanisms, GPU address translation, DMA data flows, interrupt forwarding, the xGMI interconnect model, and key design decisions made during development.

---

## Table of Contents

- [System Architecture Overview](#system-architecture-overview)
  - [Component Diagram](#component-diagram)
  - [Key Components](#key-components)
  - [Communication Channels](#communication-channels)
- [vfio-user and Legacy Backends](#vfio-user-and-legacy-backends)
  - [vfio-user Backend (Default)](#vfio-user-backend-default)
  - [Legacy Socket Backend](#legacy-socket-backend)
  - [Backend Comparison](#backend-comparison)
- [PCI BAR Layout](#pci-bar-layout)
- [Memory Sharing Architecture](#memory-sharing-architecture)
  - [Three Sharing Channels](#three-sharing-channels)
  - [VRAM Sharing (BAR0)](#vram-sharing-bar0)
  - [Guest RAM Sharing (GTT Pages)](#guest-ram-sharing-gtt-pages)
  - [Memory Split (Q35)](#memory-split-q35)
  - [Sink Mechanism](#sink-mechanism)
- [GPU Address Translation and GART](#gpu-address-translation-and-gart)
  - [GPU Address Spaces and Apertures](#gpu-address-spaces-and-apertures)
  - [Aperture Registers](#aperture-registers)
  - [GART Structure and Table Layout](#gart-structure-and-table-layout)
  - [PTE Format](#pte-format)
  - [getGARTAddr Transform](#getgartaddr-transform)
  - [Translation Flow](#translation-flow)
  - [gartTable Hash Map vs. Shared VRAM](#garttable-hash-map-vs-shared-vram)
  - [Address Classification After Translation](#address-classification-after-translation)
  - [MMHUB Aperture](#mmhub-aperture)
  - [User-Space Translation (VMID > 0)](#user-space-translation-vmid-0)
- [DMA Data Flow](#dma-data-flow)
  - [PM4 Packet Processor Routing](#pm4-packet-processor-routing)
  - [SDMA Engine Routing](#sdma-engine-routing)
  - [VRAM vs. System Memory Detection](#vram-vs-system-memory-detection)
  - [vfio-user Backend: Shared Memory Direct Access](#vfio-user-backend-shared-memory-direct-access)
  - [Legacy Backend: Socket DMA Protocol](#legacy-backend-socket-dma-protocol)
  - [Interrupt Handler (IH) DMA](#interrupt-handler-ih-dma)
  - [Complete Data Flow Example](#complete-data-flow-example)
- [MSI-X Interrupt Forwarding](#msi-x-interrupt-forwarding)
  - [Interrupt Delivery Path](#interrupt-delivery-path)
  - [IH Ring Buffer Interaction](#ih-ring-buffer-interaction)
- [xGMI Interconnect Model](#xgmi-interconnect-model)
  - [Packet Format](#packet-format)
  - [Address Mapping](#address-mapping)
  - [Topology Configuration](#topology-configuration)
  - [Link Parameters](#link-parameters)
  - [Flow Control](#flow-control)
  - [Architecture Phases](#architecture-phases)
- [Design History and Key Decisions](#design-history-and-key-decisions)
  - [Why vfio-user Over a Custom Protocol](#why-vfio-user-over-a-custom-protocol)
  - [Why Q35 + KVM](#why-q35-kvm)
  - [Shared Memory Design](#shared-memory-design)
  - [SIGIO Edge-Triggered Drain](#sigio-edge-triggered-drain)
  - [GART Fallback Approach](#gart-fallback-approach)
  - [VRAM Routing Discovery](#vram-routing-discovery)

---

## System Architecture Overview

The co-simulation system splits GPU workload execution across two processes: QEMU (with KVM) handles the host CPU, guest OS, and amdgpu driver at near-native speed, while gem5 models the MI300X GPU device -- shader arrays, command processors, SDMA engines, and the Ruby cache hierarchy -- with cycle-level accuracy. The two processes communicate via a Unix domain socket and share memory through POSIX shared memory files for zero-copy DMA.

### Component Diagram

```
+--------------------------------------+
|  QEMU  (Q35 + KVM)                   |
|  +--------------------------------+  |
|  |  Guest Linux (Ubuntu 24)       |  |
|  |  amdgpu driver (ROCm 7)        |  |
|  |  ROCm userspace                |  |
|  +--------------+-----------------+  |
|                 | MMIO / Doorbell    |
|  +--------------v-----------------+  |
|  |  vfio-user-pci                 |  |
|  |  (QEMU built-in device)        |  |
|  +--------------+-----------------+  |
|                 | vfio-user protocol |
+-----------------+--------------------+
                  |  /tmp/gem5-mi300x.sock
                  |  (Unix socket)
+-----------------+--------------------+
|  gem5           |                    |
|  +--------------v-----------------+  |
|  |  MI300XVfioUser                |  |
|  |  (mi300x_vfio_user.cc)         |  |
|  |  [libvfio-user server]         |  |
|  +--------------+-----------------+  |
|                 | AMDGPUDevice API   |
|  +--------------v-----------------+  |
|  |  AMDGPUDevice                  |  |
|  |  PM4PacketProcessor            |  |
|  |  SDMAEngine                    |  |
|  |  Shader / CU array             |  |
|  +--------------------------------+  |
+--------------------------------------+

Shared Memory:
  /dev/shm/cosim-guest-ram   Guest physical RAM (QEMU <-> gem5 DMA)
  /dev/shm/mi300x-vram       GPU VRAM (QEMU BAR0 <-> gem5 device memory)
```

gem5 runs inside a Docker container with a `StubWorkload` (no Linux kernel of its own). It starts as a vfio-user server, listens on the Unix socket, and waits for MMIO requests from QEMU.

### Key Components

| Component | Location | Purpose |
|---|---|---|
| `MI300XVfioUser` | `src/dev/amdgpu/mi300x_vfio_user.{cc,hh}` | gem5 vfio-user server; handles BAR access and interrupts via libvfio-user (default backend) |
| `vfio-user-pci` | QEMU built-in device | QEMU-side vfio-user client; no custom QEMU code needed |
| `CosimBridge` | `src/dev/amdgpu/cosim_bridge.hh` | Abstract co-simulation bridge interface, implemented by both backends |
| `MI300XGem5Cosim` | `src/dev/amdgpu/mi300x_gem5_cosim.{cc,hh}` | Legacy socket bridge SimObject |
| `mi300x_gem5.c` | `qemu/hw/misc/` | Legacy QEMU PCI device; forwards MMIO/doorbell via custom socket protocol |
| `mi300_cosim.py` | `configs/example/gpufs/` | gem5 config; selects backend via `--cosim-backend=vfio-user|legacy` |
| `cosim_launch.sh` | `scripts/` | Orchestrates Docker (gem5) + QEMU launch sequence |

### Communication Channels

The system uses three distinct channels between QEMU and gem5:

1. **VRAM shared memory** (`/dev/shm/mi300x-vram`, 16 GiB) -- GPU VRAM including GART page tables. Both sides mmap the same file for zero-copy access.
2. **Guest RAM shared memory** (`/dev/shm/cosim-guest-ram`, 8 GiB) -- Host physical memory containing ring buffers, fences, GTT pages. QEMU uses `memory-backend-file` with `share=on`; gem5 uses `shared_backstore`.
3. **vfio-user socket** (`/tmp/gem5-mi300x.sock`) -- Carries MMIO reads/writes, config space access, doorbell writes, and interrupt notifications via the vfio-user protocol.

---

## vfio-user and Legacy Backends

The co-simulation system supports two communication backends, selectable via `--cosim-backend=vfio-user|legacy` in the gem5 configuration.

### vfio-user Backend (Default)

The vfio-user backend uses the industry-standard vfio-user protocol (QEMU 10.0+ built-in support). On the gem5 side, Nutanix's libvfio-user library acts as the server.

- **QEMU side**: Uses the built-in `vfio-user-pci` device. No custom QEMU code is required; any stock QEMU 10.0+ build works.
- **gem5 side**: `MI300XVfioUser` registers BAR regions, configuration space, and MSI-X capabilities with libvfio-user, then serves requests from QEMU.
- **DMA**: gem5 accesses Guest RAM directly through the Ruby memory system's shared backstore, with no socket round-trips.
- **Interrupts**: Delivered via `irq_fd` (eventfd injected into KVM), eliminating custom interrupt messages.

### Legacy Socket Backend

The legacy backend uses a custom `mi300x-gem5` QEMU PCI device and a custom binary protocol over two Unix socket connections:

- **Synchronous connection**: MMIO request-response pairs (QEMU sends write/read, gem5 responds).
- **Asynchronous connection**: gem5 sends IRQ raise/lower events and DMA read/write requests to QEMU.

This backend requires a QEMU build from the `cosim/qemu/` directory.

### Backend Comparison

| Dimension | vfio-user Backend | Legacy Socket Backend |
|-----------|-------------------|----------------------|
| Guest RAM DMA | Ruby memory system direct access to shared backstore | Socket request-response protocol |
| VRAM access | mmap zero-copy | mmap zero-copy |
| Interrupts | irq_fd (eventfd -> KVM) | Custom socket messages |
| MMIO | vfio-user message passing | Custom binary protocol |
| QEMU-side device | Built-in `vfio-user-pci` | Custom `mi300x_gem5.c` |
| Address translation | gem5-internal GART translation | QEMU-side `pci_dma_read/write` |
| QEMU version | Stock QEMU 10.0+ | Custom fork required |

---

## PCI BAR Layout

The PCI BAR layout must match the expectations hardcoded in the amdgpu driver (`AMDGPU_VRAM_BAR=0`, `AMDGPU_DOORBELL_BAR=2`, `AMDGPU_MMIO_BAR=5`).

```
BAR0+1  VRAM         64-bit prefetchable   16 GiB  (shared memory)
BAR2+3  Doorbell     64-bit                 4 MiB
BAR4    MSI-X        exclusive              256 vectors
BAR5    MMIO regs    32-bit                512 KiB  (forwarded to gem5)
```

| BAR | Content | Size | Communication Method |
|-----|---------|------|---------------------|
| BAR0+1 | VRAM | 16 GiB | Shared memory (zero-copy mmap) |
| BAR2+3 | Doorbell | 4 MiB | Socket forwarding (vfio-user or legacy) |
| BAR4 | MSI-X | 256 vectors | QEMU local |
| BAR5 | MMIO registers | 512 KiB | Socket forwarding (vfio-user or legacy) |

BAR0+1 and BAR2+3 are 64-bit BARs (16 GiB VRAM cannot fit in the 32-bit address space). During PCI BAR size probing, the upper half of each 64-bit BAR must return the high 32 bits of the size mask.

The PCI class code is set to `PCI_CLASS_DISPLAY_VGA (0x0300)` rather than `PCI_CLASS_DISPLAY_OTHER (0x0380)`, so the kernel detects the device as a "video device with shadowed ROM" and enables VGA ROM lookup at `0xC0000`.

---

## Memory Sharing Architecture

In co-simulation, the GPU device model (gem5) and the host system (QEMU/KVM) run as separate processes. The GPU needs access to two types of memory:

- **VRAM** (local video memory): GPU-private storage for textures, buffers, GART page tables, and device-local allocations.
- **GTT** (Graphics Translation Table / System Memory): Host physical memory regions mapped by the GPU, used for ring buffers, fences, IH cookies, and DMA buffers.

Both types are shared via POSIX shared memory files, enabling bidirectional visibility without socket communication.

### Three Sharing Channels

```
+----------------------------+                    +-----------------------------+
|  QEMU  (Q35 + KVM)         |                    |  gem5  (Docker)             |
|                            |                    |                             |
|  Guest Linux               |                    |  MI300X GPU Model           |
|  amdgpu driver             |                    |    Shader / CU / SDMA       |
|                            |                    |    PM4 / IH / Ruby caches   |
|                            |                    |                             |
|  +--------+  +---------+   |  vfio-user (Unix)  |  +------------+ +--------+  |
|  | BAR0   |  | BAR5    |<---(MMIO/CFG/Doorbell)--->|MI300XVfio  | |GPU core|  |
|  | (VRAM) |  | (MMIO)  |   |                    |  |User bridge | |        |  |
|  +---+----+  +---------+   |                    |  +-----+------+ +--------+  |
|      |                     |                    |        |                    |
+------+---------------------+                    +--------+--------------------+
       |                                                   |
       v                                                   v
  /dev/shm/mi300x-vram (16 GiB)                      mmap same file
  (VRAM: GPU data + GART page tables)              (vramShmemPtr)
       |                                                   |
       v                                                   v
  /dev/shm/cosim-guest-ram (8 GiB)                    mmap same file
  (Guest RAM: ring buffers, fences,                (system->getPhysMem())
   GTT pages, kernel/user data)
```

| Channel | File/Socket | Size | Purpose | Access Method |
|---------|-------------|------|---------|---------------|
| VRAM Shared Memory | `/dev/shm/mi300x-vram` | 16 GiB | GPU VRAM + GART page tables | mmap (zero-copy) |
| Guest RAM Shared Memory | `/dev/shm/cosim-guest-ram` | 8 GiB | Host physical memory (GTT pages) | QEMU: mmap; gem5: Ruby memory system direct access to shared backstore |
| vfio-user Socket | `/tmp/gem5-mi300x.sock` | -- | MMIO/config space/doorbell; interrupts via irq_fd (eventfd -> KVM) | vfio-user protocol |

### VRAM Sharing (BAR0)

#### Initialization

On the gem5 side (`mi300x_vfio_user.cc:setupVramShm`):

```cpp
shmemFd = shm_open(shmemPath.c_str(), O_CREAT | O_RDWR, 0666);
ftruncate(shmemFd, vramSize);
shmemPtr = mmap(nullptr, vramSize, PROT_READ | PROT_WRITE, MAP_SHARED, shmemFd, 0);

// Pass the shared pointer to the GART translator
gpuDevice->getVM().vramShmemPtr = (uint8_t *)shmemPtr;
gpuDevice->getVM().vramShmemSize = vramSize;
```

QEMU obtains the BAR0 mapping through the vfio-user DMA region mapping mechanism -- it no longer directly opens the VRAM shared memory file, but instead receives the mapping through the vfio-user protocol.

#### VRAM Content Layout

```
Offset 0x000000000  +------------------------------+
                    |  GPU Data Area               |
                    |  - hipMalloc allocations     |
                    |  - Kernel args, textures     |
                    |  - Driver internal allocs    |
                    |                              |
                    |        ...                   |
                    |                              |
Offset ~0x3EE600000 +------------------------------+
(ptBase)            |  GART Page Table (PTEs)      |
                    |  8 bytes per PTE             |
                    |  Maps GPU VA -> phys addr    |
Offset 0x400000000  +------------------------------+
(16 GiB)
```

#### Access Patterns

| Scenario | Writer | Reader | Path |
|----------|--------|--------|------|
| GPU buffer allocation | Driver (via BAR0 write) | gem5 (via vramShmemPtr) | Shared memory direct access |
| GART PTE writes | Driver (via BAR0 write) | gem5 GART translator | memcpy from vramShmemPtr |
| IP Discovery table | gem5 initialization | Driver (via BAR0 read) | Shared memory direct access |

Since QEMU's BAR0 and gem5's `vramShmemPtr` both mmap the same `/dev/shm` file, data written by the driver to BAR0 is immediately visible to gem5 with no socket communication required.

### Guest RAM Sharing (GTT Pages)

In AMD GPUs, GTT = GART = Graphics Address Remapping Table. It is a single-level page table (VMID 0) that maps GPU virtual addresses to host physical addresses. The host physical memory pages being mapped are "GTT pages."

Typical GTT page contents:

| Data Structure | Description | Access Direction |
|---------------|-------------|-----------------|
| PM4 Ring Buffer | GFX command queue | Driver writes -> GPU reads |
| SDMA Ring Buffer | DMA command queue | Driver writes -> GPU reads |
| IH Ring Buffer | Interrupt handler queue | GPU writes -> Driver reads |
| Fence values | Completion signals | GPU writes -> Driver reads |
| MQD (Map Queue Descriptor) | Queue descriptors | Driver writes -> GPU reads |
| User DMA buffers | hipMemcpy src/dst | Bidirectional |

#### Initialization

QEMU side (command-line):

```bash
-object memory-backend-file,id=mem0,size=8G,\
        mem-path=/dev/shm/cosim-guest-ram,share=on
-numa node,memdev=mem0
```

`share=on` ensures `MAP_SHARED`, making QEMU's modifications visible to other processes.

gem5 side (`mi300_cosim.py`):

```python
system.shared_backstore = args.shmem_host_path     # "/cosim-guest-ram"
system.auto_unlink_shared_backstore = True
system.memories[0].shared_backstore = args.shmem_host_path
```

gem5's `PhysicalMemory` uses the same POSIX shared memory file as its backing store.

#### Why GTT Needs No Extra Sharing Mechanism

GTT pages reside in Guest RAM, which is already shared via `/dev/shm/cosim-guest-ram`:

1. **Driver writes to ring buffer** -> writes to Guest RAM -> shared memory -> gem5 can read
2. **gem5 writes fence** -> Ruby memory controller writes to shared backstore -> driver can read
3. **Physical addresses in GART PTEs** -> offsets within Guest RAM -> accessible by both sides

### Memory Split (Q35)

QEMU Q35 splits memory into two regions when RAM >= 2.75 GiB:

- **Below-4G region**: first 2 GiB (file offset 0)
- **Above-4G region**: the remainder at file offset 2 GiB, mapped to guest physical address 0x100000000+

gem5's `mi300_cosim.py` replicates this split to ensure both sides maintain consistent file offsets:

```python
total_mem = convert.toMemorySize(args.mem_size)
lowmem_limit = 0x80000000 if total_mem >= 0xB0000000 else 0xB0000000
below_4g = min(total_mem, lowmem_limit)
above_4g = total_mem - below_4g
```

If the two sides disagree on where above-4G memory sits in the file, gem5 reads stale or zeroed data (e.g., GART PTEs reading as all zeros, causing infinite NOP loops in the PM4 command processor).

### Sink Mechanism

In co-simulation mode, some GART PTEs may be zero (uninitialized) or point to VRAM-internal addresses. If gem5 cannot translate these addresses, the original behavior was to throw a `GenericPageTableFault`, causing a DMA retry loop that hangs the simulation.

The sink mechanism prevents this:

```cpp
// amdgpu_vm.cc: GARTTranslationGen::translate()

if (pte == 0) {
    if (origAddr < vramShmemSize && vramShmemPtr) {
        // VRAM address -> map to sink (paddr=0)
        range.paddr = 0;
        warn_once("GART: VRAM address mapped to sink -- "
                  "VRAM write-backs are no-ops in cosim");
    } else if (vramShmemPtr) {
        // Unmapped GART page -> sink
        range.paddr = 0;
        warn_once("GART cosim: unmapped page -> sink");
    }
}
```

Sink semantics:

- `paddr=0` is always a valid physical address in gem5 (system RAM base)
- DMA reads return zeros
- DMA writes are silently discarded
- Prevents the fault -> retry deadloop

This behavior is safe: diagnostics confirmed that the first GART page (ptStart itself) is normally unmapped, while subsequent PTEs contain valid entries. The sink ensures the simulation stays alive even when the GPU attempts DMA to pages the driver has not yet mapped.

---

## GPU Address Translation and GART

The MI300X (GFX 9.4.3) uses multiple address spaces and apertures to access memory. Each memory access issued by the GPU is first classified by aperture, then translated into a physical address.

### GPU Address Spaces and Apertures

```
GPU Virtual Address (48-bit)
|
+-- AGP aperture      [agpBot, agpTop]
|  +-- Direct offset:  paddr = vaddr - agpBot + agpBase
|
+-- GART aperture     [ptStart<<12, ptEnd<<12]
|  +-- Page table:     paddr = GART_PTE[page_num].phys_addr | offset
|
+-- Framebuffer (FB)  [fbBase, fbTop]
|  +-- VRAM offset:    vram_off = vaddr - fbBase
|
+-- System aperture   [sysAddrL, sysAddrH]
|  +-- Direct map:     paddr = vaddr  (system memory)
|
+-- MMHUB aperture    [mmhubBase, mmhubTop]
|  +-- VRAM mirror:    vram_off = vaddr - mmhubBase
|
+-- User VM (VMID>0)  [arbitrary VAs]
   +-- Multi-level page table walk (4 or 5 levels)
```

### Aperture Registers

These MMIO registers define the boundaries of each aperture. The values are programmed by the amdgpu driver during GMC (Graphics Memory Controller) initialization.

| Register | gem5 Field | Format | Description |
|----------|-----------|--------|-------------|
| `MC_VM_FB_LOCATION_BASE` | `vmContext0.fbBase` | `bits[23:0] << 24` | Start address of VRAM in MC address space |
| `MC_VM_FB_LOCATION_TOP` | `vmContext0.fbTop` | `bits[23:0] << 24 | 0xFFFFFF` | End address of VRAM |
| `MC_VM_FB_OFFSET` | `vmContext0.fbOffset` | `bits[23:0] << 24` | FB relocation offset |
| `MC_VM_AGP_BASE` | `vmContext0.agpBase` | `bits[23:0] << 24` | AGP remap base address |
| `MC_VM_AGP_BOT` | `vmContext0.agpBot` | `bits[23:0] << 24` | AGP aperture bottom |
| `MC_VM_AGP_TOP` | `vmContext0.agpTop` | `bits[23:0] << 24 | 0xFFFFFF` | AGP aperture top |
| `MC_VM_SYSTEM_APERTURE_LOW_ADDR` | `vmContext0.sysAddrL` | `bits[29:0] << 18` | System aperture low address |
| `MC_VM_SYSTEM_APERTURE_HIGH_ADDR` | `vmContext0.sysAddrH` | `bits[29:0] << 18` | System aperture high address |
| `VM_CONTEXT0_PAGE_TABLE_BASE_ADDR` | `vmContext0.ptBase` | raw 64-bit | Location of GART table in VRAM |
| `VM_CONTEXT0_PAGE_TABLE_START_ADDR` | `vmContext0.ptStart` | raw 64-bit | GART aperture start address (page number) |
| `VM_CONTEXT0_PAGE_TABLE_END_ADDR` | `vmContext0.ptEnd` | raw 64-bit | GART aperture end address (page number) |

Typical values in co-simulation (from driver initialization diagnostics):

```
ptBase   = 0x3EE600000     GART table at VRAM offset ~15.7 GiB
ptStart  = 0x7FFF00000     GART covers GPU VAs from 0x7FFF00000000
ptEnd    = 0x7FFF1FFFF     GART covers ~128K pages (512 MiB)
fbBase   = 0x8000000000    VRAM starts at MC address 512 GiB
fbTop    = 0x8400FFFFFF    VRAM ends at ~528 GiB (16 GiB range)
sysAddrL = 0x0             System aperture start
sysAddrH = 0x3FFEC0000     System aperture end (~4 TiB)
```

### GART Structure and Table Layout

GART is a single-level page table used by VMID 0 (kernel mode) to map GPU virtual addresses to system physical addresses. It enables the GPU to perform DMA access to host (guest) RAM for ring buffers, fence values, IH cookies, and other kernel-mode data structures.

The GART table resides in VRAM at offset `ptBase`:

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

### PTE Format

Each PTE is 8 bytes:

```
63    52 51  48 47              12 11  6 5  2 1   0
+-------+------+-----------------+------+----+---+---+
| Flags | BlkF | Physical Page   | Rsvd |Frag|Sys| V |
|       |      | (PA >> 12)      |      |    |   |   |
+-------+------+-----------------+------+----+---+---+
```

| Bit Range | Field | Description |
|-----------|-------|-------------|
| 0 | Valid | Entry is valid |
| 1 | System | 1 = system memory (Guest RAM), 0 = local VRAM |
| 5:2 | Fragment | Page fragment size |
| 47:12 | Physical Page | Physical address >> 12 |
| 51:48 | Block Fragment | Block fragment size |
| 63:52 | Flags | MTYPE, PRT, etc. |

Physical address extraction: `paddr = (bits(PTE, 47, 12) << 12) | page_offset`

### getGARTAddr Transform

Before GART lookup, addresses are transformed via `getGARTAddr()`, which multiplies the page number by 8 (the size of a PTE), converting a GPU VA into a byte offset within the GART table:

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

### Translation Flow

The complete GART translation sequence:

```
Original GPU VA (e.g., 0x7FFF00032000)
  |
  v getGARTAddr()
Transformed addr = ((VA>>12) * 8) << 12 | low_bits
                 = 0x3FFF80019_0000  (example)
  |
  v GARTTranslationGen::translate()
gart_addr = bits(transformed, 63, 12) = page_num * 8
  |
  +-- Look up gartTable hash map (populated by writeFrame / SDMA shadow)
  |
  +-- Cosim fallback: read PTE from shared VRAM
  |   pte_offset = gart_addr - (ptStart * 8)
  |   pte = *(vramShmemPtr + ptBase + pte_offset)
  |
  v Extract physical address
paddr = (bits(PTE, 47, 12) << 12) | bits(VA, 11, 0)
```

The driver writes GART PTEs through the following path:

```
amdgpu driver (guest)
  |
  +- amdgpu_gart_map(): compute PTE value
  |   pte = (phys_addr >> 12) << 12 | flags
  |
  +- write to BAR0 + ptBase + (gpu_page * 8)
  |   |
  |   +- QEMU BAR0 = mmap of /dev/shm/mi300x-vram
  |       +- data immediately appears in shared memory
  |
  +- TLB invalidate: write VM_INVALIDATE_ENG17 register
      +- MMIO -> vfio-user -> gem5 -> invalidateTLBs()
```

### gartTable Hash Map vs. Shared VRAM

In standalone gem5 mode, GART entries are maintained in a hash map (`AMDGPUVM::gartTable`), populated by:

1. **Direct writes** (`amdgpu_device.cc:writeFrame()`): When the driver writes to the GART region of VRAM via BAR0, the values are stored in `gartTable[offset]`.
2. **SDMA shadow copies** (`sdma_engine.cc`): When SDMA writes to the GART range in device memory, the shadow copy updates `gartTable`.

In co-simulation mode, the driver writes GART PTEs through QEMU's BAR0 mapping, going directly into shared VRAM without passing through gem5's `writeFrame()`. Therefore, `gartTable` is essentially empty. The co-simulation fallback reads PTEs directly from shared VRAM at `vramShmemPtr + ptBase`:

```cpp
Addr pte_table_offset = gart_addr - (ptStart * 8);
Addr pte_vram_offset = gartBase() + pte_table_offset;
memcpy(&pte, vramShmemPtr + pte_vram_offset, sizeof(pte));
```

If a PTE is 0 (unmapped page), co-simulation mode maps to a sink (`paddr=0`) instead of faulting (see [Sink Mechanism](#sink-mechanism)).

### Address Classification After Translation

After GART translation yields a physical address, gem5 determines where it points:

```
Physical address paddr
  |
  +- Within fbBase ~ fbTop range?
  |   +- YES -> VRAM address
  |       +- Access directly via vramShmemPtr (zero-copy)
  |
  +- Within sysAddrL ~ sysAddrH range?
  |   +- YES -> Guest RAM address (GTT page)
  |       +- Access via Ruby memory system (shared memory direct access)
  |
  +- Neither?
      +- Sink (paddr=0, safely discarded)
```

### MMHUB Aperture

MMHUB (Memory Management Hub) provides a shadow mapping of VRAM. Addresses within the `[mmhubBase, mmhubTop]` range are translated by subtracting the base address:

```
vram_offset = vaddr - mmhubBase
```

SDMA uses this aperture to access device memory in VMID 0 mode.

### User-Space Translation (VMID > 0)

User-space GPU programs (such as HIP applications) use multi-level page tables similar to x86-64 paging. Each VMID (1-15) has its own page table base register.

```
VM_CONTEXT[N]_PAGE_TABLE_BASE_ADDR  -> Page Directory Base
  |
  v 4-level walk (PDE3 -> PDE2 -> PDE1 -> PDE0 -> PTE)
Physical address
```

The `UserTranslationGen` class performs this walk using the GPU's page table walker (`VegaISA::Walker`). SDMA in user mode (vmid > 0) uses this path.

VMID 0 (kernel mode) GART page tables are fully visible via shared VRAM. VMID > 0 (user mode) multi-level page tables are walked by `VegaISA::Walker`, which uses gem5's internal TLB/page walker rather than reading directly from shared memory. The practical impact is limited: after the driver writes page tables, it sends TLB invalidate MMIOs, gem5 flushes its TLB, and subsequent walker traversals read from the correct physical addresses.

---

## DMA Data Flow

### PM4 Packet Processor Routing

```
PM4PacketProcessor::translate(vaddr, size)
  |
  +-- inAGP(vaddr)?  -> AGPTranslationGen  (direct offset)
  |
  +-- else           -> GARTTranslationGen  (page table lookup)
```

All PM4 DMA uses GART translation (VMID 0). Addresses are transformed via `getGARTAddr()` before the DMA call.

### SDMA Engine Routing

SDMA has more aperture awareness than PM4, as it handles both kernel-mode (VMID 0) and user-mode (VMID > 0) operations:

```
SDMAEngine::translate(vaddr, size)
  |
  +-- cur_vmid > 0?  -> UserTranslationGen  (multi-level page table)
  |
  +-- inAGP(vaddr)?  -> AGPTranslationGen
  |
  +-- inMMHUB(vaddr)?-> MMHUBTranslationGen (VRAM shadow)
  |
  +-- else           -> GARTTranslationGen
```

### VRAM vs. System Memory Detection

For PM4's RELEASE_MEM and WRITE_DATA packets, the destination can be either VRAM or system memory. The routing logic:

```cpp
bool vram = isVRAMAddress(pkt->addr);  // addr < gpuDevice->getVRAMSize()
Addr addr = vram ? pkt->addr : getGARTAddr(pkt->addr);

if (vram)
    gpuDevice->getMemMgr()->writeRequest(addr, data, size);  // device memory
else
    dmaWriteVirt(addr, size, cb, data);  // system memory via GART
```

Without this check, VRAM addresses fed through `getGARTAddr()` have their page numbers multiplied by 8, and GART translation fails because VRAM addresses have no corresponding page table entries. The three-layer defense (PM4 layer, SDMA layer, GART fallback sink) prevents this from crashing the simulation.

### vfio-user Backend: Shared Memory Direct Access

With the vfio-user backend, gem5 accesses Guest RAM directly through the Ruby memory system's shared backstore, with no socket-based DMA operations:

```
gem5 GPU model (PM4/SDMA/IH)
  |
  |  Needs to read ring buffer commands / write fence values
  |
  v  Ruby memory system request
  |
  +- Address translated by GART -> Guest physical address
  |
  +- Ruby memory controller accesses PhysicalMemory
  |   |
  |   +- PhysicalMemory backed by /dev/shm/cosim-guest-ram (MAP_SHARED)
  |       +- read/write directly hits shared memory
  |       +- QEMU sees changes immediately (same mmap file)
  |
  +- Done (no socket round-trip needed)
```

Advantages:

- **Zero-copy**: DMA reads and writes operate directly on shared memory with no serialization/deserialization
- **Low latency**: Eliminates the socket request-response round-trip overhead
- **Simplified architecture**: No custom DMA protocol needed; Ruby's memory system natively supports shared backstores

### Legacy Backend: Socket DMA Protocol

The legacy backend routes DMA through the socket using a custom binary protocol.

**gem5 reads from Guest RAM** (ring buffers / fences):

```
gem5 GPU model (PM4/SDMA/IH)
  |
  v cosimBridge->sendDmaRead(guestPhysAddr, length)
  |
  +- Construct DmaRead message (32-byte header)
  |   { type=DmaRead, addr=guestPhysAddr, data=length }
  |
  +- sendAll(eventFd, &msg, 32)        -->  QEMU event thread
  |                                           |
  |                                           +- pci_dma_read(addr, buf, len)
  |                                           |  (reads from /dev/shm/cosim-guest-ram)
  |                                           |
  |                                           +- sendAll(eventFd, &resp, 32)
  |  <------------------------------------------+- sendAll(eventFd, data, len)
  |
  +- memcpy(dest, recvBuf, length)     // data arrives at gem5
```

**gem5 writes to Guest RAM** (fences / IH cookies):

```
gem5 GPU model
  |
  v cosimBridge->sendDmaWrite(guestPhysAddr, length, data)
  |
  +- Construct DmaWrite message + data payload
  |   { type=DmaWrite, addr=guestPhysAddr, data=length, size=length }
  |
  +- sendAll(eventFd, &msg, 32)        -->  QEMU event thread
  +- sendAll(eventFd, data, length)    -->    |
  |                                           +- pci_dma_write(addr, buf, len)
  |                                           |  (writes to /dev/shm/cosim-guest-ram)
  |
  +- Done (DMA writes don't wait for response)
```

Maximum single DMA transfer in the legacy backend is 4 MiB (`COSIM_DMA_BUF_SIZE`). In practice, the driver typically submits page-sized transfers.

### Interrupt Handler (IH) DMA

The interrupt handler uses raw system physical addresses (not GART):

```
IH Ring Buffer:  regs.baseAddr    (from IH_RB_BASE register)
Wptr Address:    regs.WptrAddr    (from IH_RB_WPTR_ADDR registers)
```

These are GPAs (Guest Physical Addresses) programmed by the driver. The IH write flow:

1. Write the interrupt cookie (32 bytes) to `baseAddr + IH_Wptr`
2. Write the updated write pointer to `WptrAddr`
3. Call `intrPost()` to send an MSI-X interrupt to the guest

In co-simulation mode, DMA writes land in shared guest RAM (`/dev/shm/cosim-guest-ram`), and interrupts are forwarded to QEMU via the vfio-user irq_fd mechanism (or event socket in the legacy backend).

### Complete Data Flow Example

A HIP kernel dispatch illustrates the full memory interaction across both shared memory regions:

```
1. hipMalloc(&d_a, N*sizeof(int))
   Driver -> allocates buffer in VRAM
   Writes GART PTEs to shared VRAM (BAR0)

2. hipMemcpy(d_a, h_a, N*sizeof(int), hipMemcpyHostToDevice)
   Driver -> constructs SDMA copy command -> writes to Guest RAM (ring buffer)
   Driver -> writes Doorbell -> QEMU BAR2 -> vfio-user -> gem5
   gem5 -> reads ring buffer (Guest RAM via shared memory)
   gem5 -> parses SDMA command -> GART translates source address -> Guest RAM
   gem5 -> reads source data (Guest RAM via shared memory)
   gem5 -> writes to VRAM destination (shared memory direct write)

3. kernel<<<1, N>>>(d_a, d_b, d_c, N)
   Driver -> constructs PM4 dispatch command -> writes to Guest RAM (ring buffer)
   Driver -> writes Doorbell -> gem5
   gem5 -> reads PM4 command (Guest RAM via shared memory)
   gem5 -> launches shader execution
   gem5 -> shader reads/writes VRAM (shared memory direct access)
   gem5 -> writes fence on completion (Guest RAM via Ruby memory write)
   gem5 -> sends MSI-X interrupt (irq_fd -> KVM)

4. hipDeviceSynchronize()
   Driver -> polls fence value (until Guest RAM value matches)
   +- fence written by gem5 via Ruby memory write to shared backstore
```

A fence write (RELEASE_MEM) example showing address translation detail:

```
1. PM4 RELEASE_MEM packet: addr=0x113100000 (guest phys), data=0x1234
2. isVRAMAddress(0x113100000)? No (< 16 GiB but not a VRAM offset)
3. getGARTAddr(0x113100000) -> 0x899800000000 (page * 8 transform)
4. dmaWriteVirt(0x899800000000, 8, cb, &data)
5. GARTTranslationGen::translate()
   - gart_addr = 0x89980000
   - Look up PTE from shared VRAM -> PTE has paddr bits
   - paddr = extracted address (in guest RAM)
6. DMA write lands in /dev/shm/cosim-guest-ram at paddr offset
7. Guest driver reads fence value from same shared memory
```

---

## MSI-X Interrupt Forwarding

### Interrupt Delivery Path

The GPU signals completion events (fence write-backs, IH ring entries) to the guest via MSI-X interrupts. The interrupt delivery chain differs between backends:

**vfio-user backend**:

```
gem5 AMDGPUDevice::intrPost()
  |
  +-> cosimBridge->sendIrqRaise(0)
  |
  +-> MI300XVfioUser: vfu_irq_trigger(irq_fd)
  |     eventfd write -> KVM
  |
  +-> KVM injects MSI-X interrupt into guest
  |
  +-> Guest IH handler processes interrupt
       reads IH ring buffer from Guest RAM
```

The vfio-user backend uses eventfd descriptors (`irq_fd`) registered with KVM. When gem5 triggers an interrupt, it writes to the eventfd, and KVM directly injects the interrupt into the guest -- no QEMU involvement in the hot path.

**Legacy backend**:

```
gem5 AMDGPUDevice::intrPost()
  |
  +-> cosimBridge->sendIrqRaise(0)
  |
  +-> MI300XGem5Cosim: send IrqRaise message via event socket
  |
  +-> QEMU mi300x_gem5.c: event thread receives message
  |     msix_notify(pci_dev, vector)
  |
  +-> KVM injects MSI-X interrupt into guest
  |
  +-> Guest IH handler processes interrupt
```

The device supports 256 MSI-X vectors (BAR4).

### IH Ring Buffer Interaction

After the MSI-X interrupt arrives, the guest's IH (Interrupt Handler) reads the interrupt cookie from the IH ring buffer in Guest RAM:

1. gem5 writes a 32-byte interrupt cookie to `IH_RB_BASE + IH_Wptr` in Guest RAM
2. gem5 updates the write pointer at `IH_RB_WPTR_ADDR`
3. gem5 calls `intrPost()` to deliver the MSI-X interrupt
4. Guest IH handler wakes up, reads the cookie from the ring buffer, and processes the event

Both the ring buffer and the write pointer reside in shared Guest RAM, so the data is immediately visible to the guest once written by gem5's Ruby memory system.

---

## xGMI Interconnect Model

The xGMI (inter-chip Global Memory Interconnect) model provides GPU-to-GPU communication within a cosim-gpu multi-GPU hive. It attaches to each GPU's L2 cache (TCC) egress and routes remote VRAM accesses through a modeled xGMI link with configurable bandwidth, latency, and topology.

### Packet Format

| Field | Type | Description |
|-------|------|-------------|
| src_gpu | uint8 | Source GPU ID |
| dst_gpu | uint8 | Destination GPU ID |
| addr | uint64 | Target VRAM address |
| size | uint32 | Payload size in bytes |
| payload | bytes | Data (for write operations) |

### Address Mapping

Each GPU owns a contiguous VRAM address range:

```
GPU 0: [0, vram_size)
GPU 1: [vram_size, 2 * vram_size)
GPU N: [N * vram_size, (N+1) * vram_size)
```

The bridge determines whether an address is local or remote by checking which GPU's range it falls into.

### Topology Configuration

Launch-time parameter `--xgmi-topology`:

- **mesh**: Every GPU has a direct link to every other GPU. An 8-GPU mesh creates 28 bidirectional links.
- **ring**: Each GPU connects to its two neighbors. Lower link count but multi-hop for non-adjacent GPUs.

### Link Parameters

| Parameter | Default | CLI Flag |
|-----------|---------|----------|
| Per-link bandwidth | 128 GB/s | `--xgmi-bandwidth` |
| Per-hop latency | 100 ns | `--xgmi-latency` |
| Lanes per link | 16 | (SimObject param) |
| Max links per GPU | 7 | (SimObject param) |
| Flow-control credits | 32 | (SimObject param) |

### Flow Control

Credit-based back-pressure prevents data loss:

1. Each link starts with N credits (default 32).
2. Sending a packet consumes one credit.
3. The receiver returns a credit upon packet acceptance.
4. When credits reach zero, the sender stalls (never drops).

### Architecture Phases

**Path A (Self-built xGMI model)**:

- Single-process multi-GPU: in-process function calls between GPU models
- Multi-process 8-GPU hive: IPC transport via shared memory ring buffers or Unix sockets

**Path B (SST Merlin integration)**:

- Replace xGMI transport with SST Merlin network engine
- Three-layer synchronization: QEMU (functional) <-> gem5 (GPU timing) <-> SST (network timing)
- Supports arbitrary topologies (fat-tree, dragonfly)

### Key Source Files

- `gem5/src/dev/amdgpu/XGMIBridge.py` -- SimObject definition
- `gem5/src/dev/amdgpu/xgmi_bridge.hh` -- C++ header
- `gem5/src/dev/amdgpu/xgmi_bridge.cc` -- C++ implementation
- `gem5/configs/example/gpufs/mi300_cosim.py` -- Configuration and wiring

---

## Design History and Key Decisions

This section documents the key architectural decisions and critical bug-fix insights that shaped the co-simulation system.

### Why vfio-user Over a Custom Protocol

The initial implementation used a custom binary protocol over two Unix socket connections (one synchronous for MMIO, one asynchronous for events). This worked but required maintaining a custom QEMU PCI device (`mi300x_gem5.c`) and a custom protocol definition.

The migration to vfio-user was driven by three factors:

1. **No custom QEMU code**: Any stock QEMU 10.0+ build can connect to gem5 directly via the built-in `vfio-user-pci` device, eliminating the need to maintain a QEMU fork.
2. **Protocol standardization**: BAR mapping, configuration space, interrupts, and DMA are all defined by the vfio-user specification, reducing the surface area for protocol bugs.
3. **Simpler deployment**: Users only need to build gem5 with libvfio-user support; QEMU is used as-is.

Issues resolved during the vfio-user migration:

- libvfio-user's BAR size field was `uint32_t`, unable to represent 16 GiB VRAM -- changed to `uint64_t`.
- The upper half of 64-bit BARs must return the high 32 bits of the size mask during PCI BAR size probing.
- PCIe Express and MSI-X capabilities must be registered before `vfu_realize_ctx()`.
- SDMA ring test timeout: `sdma_delay=1e9` caused ~500 ms wall-clock delay, exceeding the driver's ~200 ms timeout window -- reduced to 1000 and increased `KEEPALIVE_INTERVAL` to `1e9`.

### Why Q35 + KVM

The co-simulation uses QEMU's Q35 machine type with KVM acceleration:

- **KVM**: Runs the guest CPU at near-native speed. A full Linux boot + driver loading completes in under a minute, compared to 10+ minutes under gem5's full-system mode. This dramatically reduces the debug cycle time.
- **Q35**: Provides a modern PCIe-capable chipset that supports 64-bit BARs (required for the 16 GiB VRAM BAR) and MSI-X interrupts.
- **StubWorkload on gem5**: gem5 runs no kernel of its own. It starts a minimal event loop and waits for MMIO requests from QEMU. This avoids dual-kernel complexity and focuses gem5 purely on GPU modeling.

### Shared Memory Design

The decision to use two separate POSIX shared memory files (`/dev/shm/cosim-guest-ram` and `/dev/shm/mi300x-vram`) rather than a single unified memory was driven by the fundamentally different nature of the two memory regions:

- **Guest RAM** must be the backing store for QEMU's `memory-backend-file` (with `share=on`) and gem5's `PhysicalMemory` (via `shared_backstore`). The file layout must exactly replicate Q35's below-4G/above-4G memory split.
- **VRAM** is exposed to QEMU as BAR0 and to gem5 as device memory. It has its own internal layout (data area + GART page table) unrelated to guest physical address space.

Combining them into one file would introduce complex offset arithmetic and coupling between two independent address spaces.

### SIGIO Edge-Triggered Drain

gem5's `PollQueue` uses `FASYNC`/`SIGIO` for socket monitoring, which is edge-triggered: the kernel sends one `SIGIO` when the socket buffer transitions from empty to non-empty, and only one.

The amdgpu driver frequently writes an INDEX register (selecting which internal register to access) then immediately reads the DATA register (getting the value). These two messages arrive back-to-back in gem5's socket buffer, but only one SIGIO fires. If the message handler reads only one message per invocation, the second message sits in the buffer with no signal to wake gem5. QEMU blocks waiting for the read response. Result: deadlock after 15 messages.

The fix: a `do/while` drain loop with `poll(fd, POLLIN, 0)` that consumes all pending messages on each SIGIO arrival:

```cpp
do {
    // read and process one message
    ...
    struct pollfd pfd = {fd, POLLIN, 0};
} while (poll(&pfd, 1, 0) > 0 && (pfd.revents & POLLIN));
```

This issue only affects the legacy backend. The vfio-user backend uses libvfio-user's non-blocking poll mechanism.

### GART Fallback Approach

In standalone gem5 mode, GART entries are maintained in a hash map (`gartTable`), populated by `writeFrame()` and SDMA shadow copies. In co-simulation, the driver writes GART PTEs through QEMU's BAR0 mapping, going directly into shared VRAM without passing through gem5's `writeFrame()`. The hash map is empty.

The co-simulation fallback reads PTEs directly from shared VRAM at `vramShmemPtr + ptBase`. When a PTE is zero (unmapped), the entry maps to a sink (`paddr=0`) instead of faulting. This prevents the `GenericPageTableFault` -> DMA retry deadloop that previously caused memory exhaustion and segfaults.

Diagnostics confirmed that GART PTEs at `gartBase` (= `ptBase`) in shared VRAM were correctly populated by the driver. The first page (ptStart itself) is simply unmapped -- normal behavior -- while subsequent PTEs (offset 0x32E0+) contain valid entries.

### VRAM Routing Discovery

Address `0x1f72fa8000` triggered over 861,000 GART translation errors, memory exhaustion, and a segfault. The root cause: SDMA rptr writeback addresses and PM4 RELEASE_MEM destination addresses can point to VRAM (address < 16 GiB). When these addresses are fed through `getGARTAddr()`, the page number is multiplied by 8, and GART translation fails because VRAM addresses have no corresponding page table entries.

The fix was a three-layer defense:

1. **PM4 layer** (`pm4_packet_processor.cc`): `writeData()`, `releaseMem()`, `queryStatus()` check `isVRAMAddress(addr)` and route VRAM writes through `gpuDevice->getMemMgr()->writeRequest()` (device memory) instead of `dmaWriteVirt()` (system memory via GART).
2. **SDMA layer** (`sdma_engine.cc`): `setGfxRptrLo/Hi()` and rptr writeback skip `getGARTAddr()` for VRAM addresses, using `getMemMgr()->writeRequest()` instead.
3. **GART fallback** (`amdgpu_vm.cc`): `GARTTranslationGen::translate()` detects VRAM addresses by reversing the `getGARTAddr` transform (`orig_page = page_num >> 3`) and maps them to `paddr=0` as a sink instead of faulting.

---

## Key Source Files

| File | Purpose |
|------|---------|
| `src/dev/amdgpu/mi300x_vfio_user.{cc,hh}` | vfio-user server SimObject (default backend) |
| `src/dev/amdgpu/mi300x_gem5_cosim.{cc,hh}` | Legacy socket bridge SimObject |
| `src/dev/amdgpu/cosim_bridge.hh` | Abstract CosimBridge interface |
| `src/dev/amdgpu/amdgpu_vm.{cc,hh}` | All translation generators (GART, AGP, MMHUB, User) |
| `src/dev/amdgpu/pm4_packet_processor.{cc,hh}` | PM4 DMA routing, VRAM detection, `getGARTAddr` |
| `src/dev/amdgpu/sdma_engine.{cc,hh}` | SDMA DMA routing, GART shadow copies |
| `src/dev/amdgpu/interrupt_handler.cc` | IH ring buffer DMA and interrupt delivery |
| `src/dev/amdgpu/amdgpu_device.cc` | Device-level `intrPost()`, `writeFrame()` |
| `src/dev/amdgpu/xgmi_bridge.{cc,hh}` | xGMI interconnect bridge |
| `configs/example/gpufs/mi300_cosim.py` | System config, memory setup, backend selection |
| `scripts/cosim_launch.sh` | Launch orchestration |
