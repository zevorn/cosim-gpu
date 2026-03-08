[English](../en/mi300x-memory-management.md)

# MI300X 内存管理、地址转换与映射

本文档描述了 AMD MI300X GPU 在独立 gem5 仿真和 QEMU+gem5 协同仿真环境中如何管理内存地址。

## 1. GPU 地址空间

MI300X (GFX 9.4.3) GPU 使用多个地址空间和 aperture 来访问内存。GPU 发出的每次内存访问首先按 aperture 分类，然后转换为物理地址。

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

### 1.1 Aperture 寄存器

这些 MMIO 寄存器定义了每个 aperture 的边界。这些值由 amdgpu 驱动程序在 GMC（Graphics Memory Controller）初始化期间设置。

| 寄存器 | gem5 字段 | 格式 | 描述 |
|----------|-----------|--------|-------------|
| `MC_VM_FB_LOCATION_BASE` | `vmContext0.fbBase` | `bits[23:0] << 24` | MC 地址空间中 VRAM 的起始地址 |
| `MC_VM_FB_LOCATION_TOP` | `vmContext0.fbTop` | `bits[23:0] << 24 \| 0xFFFFFF` | VRAM 结束地址 |
| `MC_VM_FB_OFFSET` | `vmContext0.fbOffset` | `bits[23:0] << 24` | FB 重定位偏移量 |
| `MC_VM_AGP_BASE` | `vmContext0.agpBase` | `bits[23:0] << 24` | AGP 重映射基地址 |
| `MC_VM_AGP_BOT` | `vmContext0.agpBot` | `bits[23:0] << 24` | AGP aperture 底部 |
| `MC_VM_AGP_TOP` | `vmContext0.agpTop` | `bits[23:0] << 24 \| 0xFFFFFF` | AGP aperture 顶部 |
| `MC_VM_SYSTEM_APERTURE_LOW_ADDR` | `vmContext0.sysAddrL` | `bits[29:0] << 18` | System aperture 低地址 |
| `MC_VM_SYSTEM_APERTURE_HIGH_ADDR` | `vmContext0.sysAddrH` | `bits[29:0] << 18` | System aperture 高地址 |
| `VM_CONTEXT0_PAGE_TABLE_BASE_ADDR` | `vmContext0.ptBase` | raw 64-bit | GART 表在 VRAM 中的位置 |
| `VM_CONTEXT0_PAGE_TABLE_START_ADDR` | `vmContext0.ptStart` | raw 64-bit | GART aperture 起始地址（页号） |
| `VM_CONTEXT0_PAGE_TABLE_END_ADDR` | `vmContext0.ptEnd` | raw 64-bit | GART aperture 结束地址（页号） |

**协同仿真中的典型值**（来自驱动初始化诊断）：
```
ptBase   = 0x3EE600000     GART table at VRAM offset ~15.7 GiB
ptStart  = 0x7FFF00000     GART covers GPU VAs from 0x7FFF00000000
ptEnd    = 0x7FFF1FFFF     GART covers ~128K pages (512 MiB)
fbBase   = 0x8000000000    VRAM starts at MC address 512 GiB
fbTop    = 0x8400FFFFFF    VRAM ends at ~528 GiB (16 GiB range)
sysAddrL = 0x0             System aperture start
sysAddrH = 0x3FFEC0000     System aperture end (~4 TiB)
```

## 2. GART（Graphics Address Remapping Table）

### 2.1 概述

GART 是一个单级页表，供 VMID 0（内核模式）使用，将 GPU 虚拟地址映射到系统物理地址。它使 GPU 能够对主机（guest）RAM 进行 DMA 访问，用于 ring buffer、fence 值、IH cookie 以及其他内核模式数据结构。

### 2.2 表布局

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

每个 PTE 为 8 字节，格式如下：

| 位域 | 字段 | 描述 |
|------|-------|-------------|
| 0 | Valid | 条目有效 |
| 1 | System | 1 = 系统内存，0 = 本地 VRAM |
| 5:2 | Fragment | 页面片段大小 |
| 47:12 | Physical Page | 物理地址 >> 12 |
| 51:48 | Block Fragment | 块片段大小 |
| 63:52 | Flags | MTYPE、PRT 等 |

**物理地址提取**：`paddr = (bits(PTE, 47, 12) << 12) | page_offset`

### 2.3 getGARTAddr 变换

在 GART 查找之前，地址会通过 `getGARTAddr()` 进行变换：

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

该函数将页号乘以 8（PTE 的大小），实际上是将 GPU VA 转换为 GART 表内的字节偏移量。随后 GART 转换使用这个变换后的地址来查找 PTE。

### 2.4 转换流程

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

### 2.5 gartTable 哈希表 vs. 共享 VRAM

在独立 gem5 模式下，GART 条目维护在一个哈希表（`AMDGPUVM::gartTable`）中，由以下方式填充：

1. **直接写入**（`amdgpu_device.cc:writeFrame()`）：当驱动程序通过 BAR0 写入 VRAM 的 GART 区域时，值被存储到 `gartTable[offset]` 中。

2. **SDMA 影子拷贝**（`sdma_engine.cc`）：当 SDMA 写入设备内存中的 GART 范围时，影子拷贝会更新 `gartTable`。

在协同仿真模式下，驱动程序通过 QEMU 的 BAR0 映射写入 GART PTE，直接进入共享 VRAM，不经过 gem5 的 `writeFrame()`。因此，`gartTable` 基本为空。协同仿真回退机制直接从共享 VRAM 的 `vramShmemPtr + ptBase` 处读取 PTE。

## 3. MMHUB Aperture

MMHUB（Memory Management Hub）提供 VRAM 的影子映射。`[mmhubBase, mmhubTop]` 范围内的地址通过减去基地址进行转换：

```
vram_offset = vaddr - mmhubBase
```

SDMA 在 VMID 0 模式下使用此 aperture 访问设备内存。

## 4. 用户空间转换（VMID > 0）

用户空间 GPU 程序（如 HIP 应用）使用类似于 x86-64 分页的多级页表。每个 VMID（1-15）拥有自己的页表基址寄存器。

```
VM_CONTEXT[N]_PAGE_TABLE_BASE_ADDR  → Page Directory Base
  │
  ▼ 4-level walk (PDE3 → PDE2 → PDE1 → PDE0 → PTE)
Physical address
```

`UserTranslationGen` 类使用 GPU 的页表遍历器（`VegaISA::Walker`）执行此遍历。用户模式（vmid > 0）下的 SDMA 使用此路径。

## 5. gem5 中的 DMA 路由

### 5.1 PM4 Packet Processor

```
PM4PacketProcessor::translate(vaddr, size)
  │
  ├─ inAGP(vaddr)?  → AGPTranslationGen  (direct offset)
  │
  └─ else           → GARTTranslationGen  (page table lookup)
```

所有 PM4 DMA 使用 GART 转换（VMID 0）。地址在 DMA 调用之前先通过 `getGARTAddr()` 变换。

### 5.2 SDMA 引擎

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

SDMA 比 PM4 具有更多的 aperture 感知能力，因为它同时处理内核模式（VMID 0）和用户模式（VMID > 0）的操作。

### 5.3 VRAM vs. 系统内存检测

对于 PM4 的 RELEASE_MEM 和 WRITE_DATA 数据包，目标可以是 VRAM 或系统内存。路由方式如下：

```cpp
bool vram = isVRAMAddress(pkt->addr);  // addr < gpuDevice->getVRAMSize()
Addr addr = vram ? pkt->addr : getGARTAddr(pkt->addr);

if (vram)
    gpuDevice->getMemMgr()->writeRequest(addr, data, size);  // device memory
else
    dmaWriteVirt(addr, size, cb, data);  // system memory via GART
```

## 6. 中断处理器（IH）DMA

中断处理器使用原始系统物理地址（非 GART）：

```
IH Ring Buffer:  regs.baseAddr    (from IH_RB_BASE register)
Wptr Address:    regs.WptrAddr    (from IH_RB_WPTR_ADDR registers)
```

这些是驱动程序设置的 GPA（Guest Physical Address）。IH 写入流程：
1. 将中断 cookie（32 字节）写入 `baseAddr + IH_Wptr`
2. 将更新后的写指针写入 `WptrAddr`
3. 然后调用 `intrPost()` → 向 guest 发送 MSI-X 中断

在协同仿真模式下，DMA 写入落入共享 guest RAM（`/dev/shm/cosim-guest-ram`），中断通过事件 socket 转发给 QEMU。

## 7. 协同仿真内存架构

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

### 7.1 内存分割（Q35）

QEMU Q35 在 RAM >= 2.75 GiB 时将内存分为：
- 4G 以下区域：前 2 GiB（文件偏移 0）
- 4G 以上区域：其余部分位于文件偏移 2 GiB 处，映射到 PA 0x100000000+

gem5 的 `mi300_cosim.py` 复制了此分割方式，以确保双方在文件布局上保持一致。

### 7.2 GART PTE 协同仿真回退机制

由于驱动程序通过 QEMU 的 BAR0（共享内存）写入 GART PTE，gem5 的 `gartTable` 哈希表不会被填充。协同仿真回退机制直接从共享 VRAM 读取 PTE：

```cpp
Addr pte_table_offset = gart_addr - (ptStart * 8);
Addr pte_vram_offset = gartBase() + pte_table_offset;
memcpy(&pte, vramShmemPtr + pte_vram_offset, sizeof(pte));
```

如果 PTE 为 0（未映射的页面），协同仿真模式将映射到 sink（`paddr=0`），而不是产生 fault，从而避免 `GenericPageTableFault` 导致的无限 DMA 重试崩溃。

## 8. 地址流程示例

### 8.1 Fence 写入（RELEASE_MEM）

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

### 8.2 HIP 内核调度

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

## 9. 关键源文件

| 文件 | 作用 |
|------|------|
| `src/dev/amdgpu/amdgpu_vm.{cc,hh}` | 所有转换生成器（GART、AGP、MMHUB、User） |
| `src/dev/amdgpu/pm4_packet_processor.cc` | PM4 DMA 路由和 GART 地址变换 |
| `src/dev/amdgpu/sdma_engine.cc` | SDMA DMA 路由、GART 影子拷贝 |
| `src/dev/amdgpu/interrupt_handler.cc` | IH ring buffer DMA 和中断发送 |
| `src/dev/amdgpu/amdgpu_device.cc` | 设备级 intrPost()、writeFrame() |
| `src/dev/amdgpu/mi300x_gem5_cosim.cc` | 协同仿真 socket 桥接、IRQ 转发 |
| `configs/example/gpufs/mi300_cosim.py` | 内存配置、共享 backstore 设置 |
