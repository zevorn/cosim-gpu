[中文](../zh/cosim-memory-architecture.md)

# QEMU+gem5 Co-simulation: Memory Sharing Architecture

## 1. Background

In the QEMU+gem5 MI300X co-simulation, the GPU device model (gem5) and the host system (QEMU/KVM) run as two separate processes. The GPU needs to access two types of memory:

- **VRAM** (local video memory): GPU-private, stores textures, buffers, GART page tables, etc.
- **GTT** (Graphics Translation Table / System Memory): Host physical memory regions mapped by the GPU, used for ring buffers, fences, IH cookies, DMA buffers, etc.

Both types of memory must be shared between QEMU and gem5 — otherwise gem5 cannot read commands written by the driver, and QEMU cannot see results written back by the GPU.

### Key Takeaway

> **Both VRAM and Guest RAM (where GTT pages reside) are already shared via shared memory for bidirectional visibility.**
> The GART page table itself lives in VRAM and is also shared. gem5 reads GART PTEs directly from shared VRAM, then issues DMA to Guest RAM through the socket protocol.

## 2. Overall Architecture

```
+---------------------------+                    +----------------------------+
|  QEMU  (Q35 + KVM)        |                    |  gem5  (Docker)             |
|                            |                    |                             |
|  Guest Linux               |                    |  MI300X GPU Model           |
|  amdgpu driver             |                    |    Shader / CU / SDMA       |
|                            |                    |    PM4 / IH / Ruby caches   |
|  +--------+  +---------+  |    Unix Socket     |  +---------+  +----------+  |
|  | BAR0   |  | BAR5    |<----(MMIO/DMA/IRQ)---->| cosim     |  | GPU core |  |
|  | (VRAM) |  | (MMIO)  |  |                    |  | bridge   |  |          |  |
|  +---+----+  +---------+  |                    |  +----+----+  +----------+  |
|      |                     |                    |       |                      |
+------+---------------------+                    +-------+----------------------+
       |                                                  |
       v                                                  v
  /dev/shm/mi300x-vram (16 GiB)                    mmap same file
  (VRAM: GPU data + GART page tables)             (vramShmemPtr)
       |                                                  |
       v                                                  v
  /dev/shm/cosim-guest-ram (8 GiB)                  mmap same file
  (Guest RAM: ring buffers, fences,            (system->getPhysMem())
   GTT pages, kernel/user data)
```

### 2.1 Three Sharing Channels

| Channel | File/Socket | Size | Purpose | Access Method |
|---------|-------------|------|---------|---------------|
| VRAM Shared Memory | `/dev/shm/mi300x-vram` | 16 GiB | GPU VRAM + GART page tables | mmap (zero-copy) |
| Guest RAM Shared Memory | `/dev/shm/cosim-guest-ram` | 8 GiB | Host physical memory (GTT pages) | QEMU: mmap; gem5: DMA via socket |
| Control Socket | `/tmp/gem5-mi300x.sock` | — | MMIO, DMA requests, interrupts | Two connections (sync + async) |

## 3. VRAM Sharing (BAR0)

### 3.1 Initialization Flow

**QEMU side** (`mi300x_gem5.c:mi300x_gem5_realize`):

```c
// Open shared memory file
fd = open(s->shmem_path, O_RDWR | O_CREAT, 0666);  // "/dev/shm/mi300x-vram"
ftruncate(fd, vram_size);                             // 16 GiB

// Create BAR0 memory region mapped directly to the shared file
memory_region_init_ram_from_fd(&s->vram_bar, obj, "mi300x-vram",
                               s->vram_size, RAM_SHARED, fd, 0, &err);
pci_register_bar(pdev, MI300X_VRAM_BAR,
                 PCI_BASE_ADDRESS_MEM_PREFETCH | PCI_BASE_ADDRESS_MEM_TYPE_64,
                 &s->vram_bar);
```

**gem5 side** (`mi300x_gem5_cosim.cc:setupSharedMemory`):

```cpp
shmemFd = shm_open(shmemPath.c_str(), O_CREAT | O_RDWR, 0666);
ftruncate(shmemFd, vramSize);
shmemPtr = mmap(nullptr, vramSize, PROT_READ | PROT_WRITE, MAP_SHARED, shmemFd, 0);

// Key: pass the shared pointer to the GART translator
gpuDevice->getVM().vramShmemPtr = (uint8_t *)shmemPtr;
gpuDevice->getVM().vramShmemSize = vramSize;
```

### 3.2 VRAM Content Layout

```
Offset 0x000000000  +----------------------------+
                    |  GPU Data Area              |
                    |  - hipMalloc allocations     |
                    |  - Kernel args, textures     |
                    |  - Driver internal allocs    |
                    |                              |
                    |        ...                   |
                    |                              |
Offset ~0x3EE600000 +----------------------------+
(ptBase)            |  GART Page Table (PTEs)      |
                    |  8 bytes per PTE             |
                    |  Maps GPU VA -> phys addr    |
Offset 0x400000000  +----------------------------+
(16 GiB)
```

### 3.3 Access Patterns

| Scenario | Writer | Reader | Path |
|----------|--------|--------|------|
| GPU buffer allocation | Driver (via BAR0 write) | gem5 (via vramShmemPtr) | Shared memory direct access |
| GART PTE writes | Driver (via BAR0 write) | gem5 GART translator | memcpy from vramShmemPtr |
| IP Discovery table | gem5 initialization | Driver (via BAR0 read) | Shared memory direct access |

**Zero-copy**: Since QEMU's BAR0 and gem5's `vramShmemPtr` both mmap the same `/dev/shm` file, data written by the driver to BAR0 is **immediately visible** to gem5 with no socket communication required.

## 4. Guest RAM Sharing (GTT Pages)

### 4.1 What GTT Really Is

In AMD GPUs, **GTT = GART = Graphics Address Remapping Table**. It is a single-level page table (VMID 0) that maps GPU virtual addresses to host physical addresses. The host physical memory pages being mapped are the so-called "GTT pages."

Typical GTT page contents:

| Data Structure | Description | Access Direction |
|---------------|-------------|-----------------|
| PM4 Ring Buffer | GFX command queue | Driver writes -> GPU reads |
| SDMA Ring Buffer | DMA command queue | Driver writes -> GPU reads |
| IH Ring Buffer | Interrupt handler queue | GPU writes -> Driver reads |
| Fence values | Completion signals | GPU writes -> Driver reads |
| MQD (Map Queue Descriptor) | Queue descriptors | Driver writes -> GPU reads |
| User DMA buffers | hipMemcpy src/dst | Bidirectional |

### 4.2 Guest RAM Sharing Initialization

**QEMU side** (command-line arguments):

```bash
-object memory-backend-file,id=mem0,size=8G,\
        mem-path=/dev/shm/cosim-guest-ram,share=on
-numa node,memdev=mem0
```

`share=on` ensures the file mapping uses `MAP_SHARED`, making QEMU's modifications to guest memory visible to other processes.

**gem5 side** (`mi300_cosim.py`):

```python
system.shared_backstore = args.shmem_host_path     # "/cosim-guest-ram"
system.auto_unlink_shared_backstore = True
system.memories[0].shared_backstore = args.shmem_host_path
```

gem5's `PhysicalMemory` uses the same POSIX shared memory file as its backing store, achieving memory sharing with QEMU.

### 4.3 Why GTT Needs No Extra Sharing Mechanism

GTT pages reside in Guest RAM. Guest RAM is already shared between QEMU and gem5 via `/dev/shm/cosim-guest-ram`. Therefore:

1. **Driver writes to ring buffer** -> writes to Guest RAM -> `/dev/shm/cosim-guest-ram` -> gem5 can read
2. **gem5 writes fence** -> DMA writes to Guest RAM -> `/dev/shm/cosim-guest-ram` -> driver can read
3. **Physical addresses in GART PTEs** -> offsets within Guest RAM -> accessible by both sides

**Key distinction**: VRAM is accessed via zero-copy mmap; Guest RAM DMA operations go through the socket protocol (because gem5 needs to know the exact access timing to drive simulation events).

## 5. GART Translation Flow

### 5.1 Driver Writes GART PTEs

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
      +- MMIO -> socket -> gem5 -> invalidateTLBs()
```

### 5.2 gem5 Reads GART PTEs

```cpp
// amdgpu_vm.cc: GARTTranslationGen::translate()

// Step 1: compute PTE offset within VRAM
gart_addr = bits(transformedAddr, 63, 12);  // GPU VA page number
pte_table_offset = gart_addr - (ptStart * 8);

// Step 2: read PTE directly from shared VRAM (zero-copy)
pte_vram_offset = gartBase() + pte_table_offset;
memcpy(&pte, vramShmemPtr + pte_vram_offset, sizeof(uint64_t));

// Step 3: extract physical address
if (pte != 0) {
    paddr = (bits(pte, 47, 12) << 12) | bits(vaddr, 11, 0);
    //  paddr points to Guest RAM (GTT page) or VRAM
}
```

### 5.3 PTE Format

```
63    52 51  48 47              12 11  6 5  2 1   0
+-------+------+-----------------+------+----+---+---+
| Flags | BlkF | Physical Page   | Rsvd |Frag|Sys| V |
|       |      | (PA >> 12)      |      |    |   |   |
+-------+------+-----------------+------+----+---+---+

Bit 0: Valid     -- PTE is valid
Bit 1: System   -- 1=system memory (Guest RAM), 0=local VRAM
Bit 47:12       -- physical page number
```

### 5.4 Address Classification

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
  |       +- Access via socket DMA protocol
  |
  +- Neither?
      +- Sink (paddr=0, safely discarded)
```

## 6. DMA Flow

### 6.1 gem5 Reads from Guest RAM (ring buffers / fences)

```
gem5 GPU model (PM4/SDMA/IH)
  |
  |  Needs to read ring buffer commands from Guest RAM
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

### 6.2 gem5 Writes to Guest RAM (fences / IH cookies)

```
gem5 GPU model
  |
  |  Needs to write fence value to Guest RAM
  |
  v cosimBridge->sendDmaWrite(guestPhysAddr, length, data)
  |
  +- Construct DmaWrite message + data payload
  |   { type=DmaWrite, addr=guestPhysAddr, data=length, size=length }
  |
  +- sendAll(eventFd, &msg, 32)        -->  QEMU event thread
  +- sendAll(eventFd, data, length)    -->      |
  |                                           +- pci_dma_write(addr, buf, len)
  |                                           |  (writes to /dev/shm/cosim-guest-ram)
  |                                           |
  +- Done (DMA writes don't wait for response)  +- Driver can see data immediately
```

### 6.3 Why Guest RAM DMA Uses Socket Instead of Direct mmap

Although gem5's `system->getPhysMem()` can access shared memory directly (as `readROM()` does), most DMA operations go through the socket for the following reasons:

1. **Address translation**: Guest physical addresses need to go through QEMU's memory model (considering IOMMU, memory region mappings)
2. **Event-driven simulation**: gem5 is an event-driven simulator; DMA needs to trigger proper simulation events (cache coherence, timing)
3. **Consistency guarantees**: The socket's request-response pattern naturally provides memory barrier semantics
4. **IOMMU compatibility**: If IOMMU is enabled in the future, QEMU needs to perform address translation on its side

**Exception**: `readROM()` reads shared memory directly because ROM is read-only and accessed early in simulation, requiring no event synchronization.

## 7. Sink Mechanism

### 7.1 Problem Scenario

In co-simulation mode, some GART PTEs may be zero (uninitialized) or point to VRAM-internal addresses. If gem5 cannot translate these addresses, it throws a `GenericPageTableFault`, causing a DMA retry loop that hangs the simulation.

### 7.2 Solution

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

**Sink semantics**:
- `paddr=0` is always a valid physical address in gem5 (system RAM base)
- DMA reads return zeros
- DMA writes are silently discarded
- Prevents the fault -> retry deadloop

## 8. Complete Data Flow Example

Using a HIP kernel dispatch to illustrate the full memory interaction:

```
1. hipMalloc(&d_a, N*sizeof(int))
   Driver -> allocates buffer in VRAM
   Writes GART PTEs to shared VRAM (BAR0)

2. hipMemcpy(d_a, h_a, N*sizeof(int), hipMemcpyHostToDevice)
   Driver -> constructs SDMA copy command -> writes to Guest RAM (ring buffer)
   Driver -> writes Doorbell -> QEMU BAR2 -> socket -> gem5
   gem5 -> DMA reads ring buffer (Guest RAM via socket)
   gem5 -> parses SDMA command -> GART translates source address -> Guest RAM
   gem5 -> DMA reads source data (Guest RAM via socket)
   gem5 -> writes to VRAM destination (shared memory direct write)

3. kernel<<<1, N>>>(d_a, d_b, d_c, N)
   Driver -> constructs PM4 dispatch command -> writes to Guest RAM (ring buffer)
   Driver -> writes Doorbell -> gem5
   gem5 -> DMA reads PM4 command (Guest RAM via socket)
   gem5 -> launches shader execution
   gem5 -> shader reads/writes VRAM (shared memory direct access)
   gem5 -> writes fence on completion (Guest RAM via socket DMA write)
   gem5 -> sends MSI-X interrupt (socket event)

4. hipDeviceSynchronize()
   Driver -> polls fence value (until Guest RAM value matches)
   +- fence written by gem5 via DMA write
```

## 9. Known Limitations

### 9.1 DMA Buffer Size

Maximum single DMA transfer is 4 MiB (`COSIM_DMA_BUF_SIZE`). Transfers exceeding this size must be chunked. In practice, the driver typically submits page-sized transfers, so this limit is rarely hit.

### 9.2 User-space Page Tables (VMID > 0)

VMID 0 (kernel mode) GART page tables are fully visible via shared VRAM. However, VMID > 0 (user mode) multi-level page tables are walked by `VegaISA::Walker`, which uses gem5's internal TLB/page walker rather than reading directly from shared memory.

The practical impact is limited: after the driver writes page tables, it sends TLB invalidate MMIOs. gem5 flushes its TLB upon receiving these, and subsequent walker traversals read from the correct physical addresses (which point to shared VRAM or Guest RAM).

### 9.3 VRAM Write-back Semantics

Some GART addresses in gem5 point back to VRAM itself (VRAM-to-VRAM DMA). These addresses are routed to the sink (paddr=0), and writes are silently discarded. For pure compute workloads, this does not affect correctness.

## 10. File Reference

| File | Key Function/Region | Role |
|------|---------------------|------|
| `gem5/src/dev/amdgpu/amdgpu_vm.cc:396-557` | `GARTTranslationGen::translate()` | Core GART translation logic |
| `gem5/src/dev/amdgpu/amdgpu_vm.hh` | `AMDGPUSysVMContext`, `vramShmemPtr` | GART data structures |
| `gem5/src/dev/amdgpu/mi300x_gem5_cosim.cc:139-172` | `setupSharedMemory()` | VRAM shared memory initialization |
| `gem5/src/dev/amdgpu/mi300x_gem5_cosim.cc:808-900` | `sendDmaRead/Write()` | DMA request sending |
| `gem5/configs/example/gpufs/mi300_cosim.py` | `shared_backstore` config | Guest RAM sharing setup |
| `qemu/hw/misc/mi300x_gem5.c:549-602` | `mi300x_gem5_realize()` | BAR0 shared memory mapping |
| `qemu/hw/misc/mi300x_gem5.c:233-296` | event thread DMA handler | DMA request processing |
