[English](../en/cosim-memory-architecture.md)

# QEMU+gem5 协同仿真：内存共享架构详解

## 1. 问题背景

在 QEMU+gem5 MI300X 协同仿真中，GPU 设备模型（gem5）和宿主系统（QEMU/KVM）运行在两个独立进程中。GPU 需要访问两类内存：

- **VRAM**（本地显存）：GPU 私有，存放纹理、buffer、GART 页表等
- **GTT**（Graphics Translation Table / System Memory）：宿主物理内存中被 GPU 映射的区域，用于 ring buffer、fence、IH cookie、DMA 缓冲等

这两类内存都必须在 QEMU 和 gem5 之间共享，否则 gem5 无法读取驱动写入的命令，QEMU 无法看到 GPU 写回的结果。

### 核心结论

> **VRAM 和 Guest RAM（GTT 页所在的宿主内存）都已通过共享内存实现双向可见。**
> GART 页表本身存放在 VRAM 中，也是共享的。gem5 直接从共享 VRAM 读取 GART PTE，然后通过 socket 协议对 Guest RAM 发起 DMA。

## 2. 总体架构

```
+----------------------------+                    +-----------------------------+
|  QEMU  (Q35 + KVM)         |                    |  gem5  (Docker)             |
|                            |                    |                             |
|  Guest Linux               |                    |  MI300X GPU Model           |
|  amdgpu driver             |                    |    Shader / CU / SDMA       |
|                            |                    |    PM4 / IH / Ruby caches   |
|  +--------+  +---------+   |    Unix Socket     |  +---------+  +----------+  |
|  | BAR0   |  | BAR5    |<-----(MMIO/DMA/IRQ)------>| cosim   |  | GPU core |  |
|  | (VRAM) |  | (MMIO)  |   |                    |  | bridge  |  |          |  |
|  +---+----+  +---------+   |                    |  +----+----+  +----------+  |
|      |                     |                    |       |                     |
+------+---------------------+                    +-------+---------------------+
       |                                                  |
       v                                                  v
  /dev/shm/mi300x-vram (16 GiB)                     mmap 同一文件
  (VRAM: GPU 数据 + GART 页表)                    (vramShmemPtr)
       |                                                  |
       v                                                  v
  /dev/shm/cosim-guest-ram (8 GiB)                   mmap 同一文件
  (Guest RAM: ring buffer, fence,                (system->getPhysMem())
   GTT 页面, 内核/用户数据)
```

### 2.1 三个共享通道

| 通道 | 文件/Socket | 大小 | 用途 | 访问方式 |
|------|-----------|------|------|---------|
| VRAM 共享内存 | `/dev/shm/mi300x-vram` | 16 GiB | GPU 显存 + GART 页表 | mmap（零拷贝） |
| Guest RAM 共享内存 | `/dev/shm/cosim-guest-ram` | 8 GiB | 宿主物理内存（GTT 页面） | QEMU: mmap; gem5: DMA via socket |
| 控制 Socket | `/tmp/gem5-mi300x.sock` | — | MMIO、DMA 请求、中断 | 两条连接（同步+异步） |

## 3. VRAM 共享（BAR0）

### 3.1 初始化流程

**QEMU 侧** (`mi300x_gem5.c:mi300x_gem5_realize`)：

```c
// 打开共享内存文件
fd = open(s->shmem_path, O_RDWR | O_CREAT, 0666);  // "/dev/shm/mi300x-vram"
ftruncate(fd, vram_size);                             // 16 GiB

// 创建 BAR0 内存区域，直接映射到共享文件
memory_region_init_ram_from_fd(&s->vram_bar, obj, "mi300x-vram",
                               s->vram_size, RAM_SHARED, fd, 0, &err);
pci_register_bar(pdev, MI300X_VRAM_BAR,
                 PCI_BASE_ADDRESS_MEM_PREFETCH | PCI_BASE_ADDRESS_MEM_TYPE_64,
                 &s->vram_bar);
```

**gem5 侧** (`mi300x_gem5_cosim.cc:setupSharedMemory`)：

```cpp
shmemFd = shm_open(shmemPath.c_str(), O_CREAT | O_RDWR, 0666);
ftruncate(shmemFd, vramSize);
shmemPtr = mmap(nullptr, vramSize, PROT_READ | PROT_WRITE, MAP_SHARED, shmemFd, 0);

// 关键：将共享指针传递给 GART 翻译器
gpuDevice->getVM().vramShmemPtr = (uint8_t *)shmemPtr;
gpuDevice->getVM().vramShmemSize = vramSize;
```

### 3.2 VRAM 内容布局

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

### 3.3 访问模式

| 场景 | 写入方 | 读取方 | 路径 |
|------|--------|--------|------|
| GPU buffer 分配 | 驱动（via BAR0 write） | gem5（via vramShmemPtr） | 共享内存直接访问 |
| GART PTE 写入 | 驱动（via BAR0 write） | gem5 GART 翻译器 | memcpy from vramShmemPtr |
| IP Discovery 表 | gem5 初始化 | 驱动（via BAR0 read） | 共享内存直接访问 |

**零拷贝**：由于 QEMU BAR0 和 gem5 的 `vramShmemPtr` 映射的是同一个 `/dev/shm` 文件，驱动写入 BAR0 的数据对 gem5 **立即可见**，无需任何 socket 通信。

## 4. Guest RAM 共享（GTT 页面）

### 4.1 GTT 的本质

在 AMD GPU 中，**GTT = GART = Graphics Address Remapping Table**。它是一个单级页表（VMID 0），将 GPU 虚拟地址映射到宿主物理地址。被映射的宿主物理内存页面就是所谓的"GTT 页面"。

典型的 GTT 页面内容：

| 数据结构 | 说明 | 访问方向 |
|---------|------|---------|
| PM4 Ring Buffer | GFX 命令队列 | 驱动写 → GPU 读 |
| SDMA Ring Buffer | DMA 命令队列 | 驱动写 → GPU 读 |
| IH Ring Buffer | 中断处理队列 | GPU 写 → 驱动读 |
| Fence 值 | 完成信号 | GPU 写 → 驱动读 |
| MQD (Map Queue Descriptor) | 队列描述符 | 驱动写 → GPU 读 |
| 用户 DMA 缓冲 | hipMemcpy 源/目标 | 双向 |

### 4.2 Guest RAM 共享初始化

**QEMU 侧**（命令行参数）：

```bash
-object memory-backend-file,id=mem0,size=8G,\
        mem-path=/dev/shm/cosim-guest-ram,share=on
-numa node,memdev=mem0
```

`share=on` 确保文件映射使用 `MAP_SHARED`，其他进程可以看到 QEMU 对 guest 内存的修改。

**gem5 侧** (`mi300_cosim.py`)：

```python
system.shared_backstore = args.shmem_host_path     # "/cosim-guest-ram"
system.auto_unlink_shared_backstore = True
system.memories[0].shared_backstore = args.shmem_host_path
```

gem5 的 `PhysicalMemory` 使用同一个 POSIX 共享内存文件作为后端，实现与 QEMU 的内存共享。

### 4.3 为什么 GTT 不需要额外的共享机制

GTT 页面存在于 Guest RAM 中。Guest RAM 已经通过 `/dev/shm/cosim-guest-ram` 在 QEMU 和 gem5 之间共享。因此：

1. **驱动写入 ring buffer** → 写入 Guest RAM → `/dev/shm/cosim-guest-ram` → gem5 可读
2. **gem5 写入 fence** → 通过 DMA 写入 Guest RAM → `/dev/shm/cosim-guest-ram` → 驱动可读
3. **GART PTE 指向的物理地址** → 就是 Guest RAM 中的偏移 → 双方都能访问

**关键区别**：VRAM 通过 mmap 直接零拷贝访问；Guest RAM 的 DMA 操作通过 socket 协议中转（因为 gem5 需要知道确切的访问时机来驱动仿真事件）。

## 5. GART 翻译流程

### 5.1 驱动写入 GART PTE

```
amdgpu driver (guest)
  │
  ├─ amdgpu_gart_map(): 计算 PTE 值
  │   pte = (phys_addr >> 12) << 12 | flags
  │
  ├─ 写入 BAR0 + ptBase + (gpu_page * 8)
  │   │
  │   └─ QEMU BAR0 = mmap of /dev/shm/mi300x-vram
  │       └─ 数据立即出现在共享内存中
  │
  └─ TLB invalidate: 写 VM_INVALIDATE_ENG17 寄存器
      └─ MMIO → socket → gem5 → invalidateTLBs()
```

### 5.2 gem5 读取 GART PTE

```cpp
// amdgpu_vm.cc: GARTTranslationGen::translate()

// Step 1: 计算 PTE 在 VRAM 中的偏移
gart_addr = bits(transformedAddr, 63, 12);  // GPU VA page number
pte_table_offset = gart_addr - (ptStart * 8);

// Step 2: 从共享 VRAM 直接读取 PTE（零拷贝）
pte_vram_offset = gartBase() + pte_table_offset;
memcpy(&pte, vramShmemPtr + pte_vram_offset, sizeof(uint64_t));

// Step 3: 提取物理地址
if (pte != 0) {
    paddr = (bits(pte, 47, 12) << 12) | bits(vaddr, 11, 0);
    //  paddr 指向 Guest RAM（GTT 页）或 VRAM
}
```

### 5.3 PTE 格式

```
63    52 51  48 47              12 11  6 5  2 1   0
┌───────┬──────┬─────────────────┬──────┬────┬───┬───┐
│ Flags │ BlkF │ Physical Page   │ Rsvd │Frag│Sys│ V │
│       │      │ (PA >> 12)      │      │    │   │   │
└───────┴──────┴─────────────────┴──────┴────┴───┴───┘

Bit 0: Valid     — PTE 有效
Bit 1: System    — 1=系统内存(Guest RAM), 0=本地 VRAM
Bit 47:12        — 物理页号
```

### 5.4 地址分类

GART 翻译得到物理地址后，gem5 需要判断该地址指向哪里：

```
物理地址 paddr
  │
  ├─ 在 fbBase ~ fbTop 范围内？
  │   └─ YES → VRAM 地址
  │       └─ 直接通过 vramShmemPtr 访问（零拷贝）
  │
  ├─ 在 sysAddrL ~ sysAddrH 范围内？
  │   └─ YES → Guest RAM 地址 (GTT 页面)
  │       └─ 通过 socket DMA 协议访问
  │
  └─ 都不是？
      └─ Sink（paddr=0, 安全丢弃）
```

## 6. DMA 流程

### 6.1 gem5 读取 Guest RAM（读 ring buffer / fence）

```
gem5 GPU 模型 (PM4/SDMA/IH)
  │
  │  需要读取 Guest RAM 中的 ring buffer 命令
  │
  ▼ cosimBridge->sendDmaRead(guestPhysAddr, length)
  │
  ├─ 构造 DmaRead 消息 (32 字节头)
  │   { type=DmaRead, addr=guestPhysAddr, data=length }
  │
  ├─ sendAll(eventFd, &msg, 32)        ──→  QEMU event thread
  │                                           │
  │                                           ├─ pci_dma_read(addr, buf, len)
  │                                           │  (从 /dev/shm/cosim-guest-ram 读取)
  │                                           │
  │                                           ├─ sendAll(eventFd, &resp, 32)
  │  ←──────────────────────────────────────  ├─ sendAll(eventFd, data, len)
  │
  └─ memcpy(dest, recvBuf, length)     // 数据到达 gem5
```

### 6.2 gem5 写入 Guest RAM（写 fence / IH cookie）

```
gem5 GPU 模型
  │
  │  需要写入 fence 值到 Guest RAM
  │
  ▼ cosimBridge->sendDmaWrite(guestPhysAddr, length, data)
  │
  ├─ 构造 DmaWrite 消息 + 数据载荷
  │   { type=DmaWrite, addr=guestPhysAddr, data=length, size=length }
  │
  ├─ sendAll(eventFd, &msg, 32)        ──→  QEMU event thread
  ├─ sendAll(eventFd, data, length)    ──→    │
  │                                           ├─ pci_dma_write(addr, buf, len)
  │                                           │  (写入 /dev/shm/cosim-guest-ram)
  │                                           │
  └─ 完成（DMA 写入不等待响应）               └─ 驱动可立即看到数据
```

### 6.3 为什么 Guest RAM DMA 走 Socket 而非直接 mmap

虽然 gem5 的 `system->getPhysMem()` 可以直接访问共享内存（`readROM()` 就是这么做的），但大多数 DMA 操作走 socket 有以下原因：

1. **地址翻译**：Guest 物理地址需要经过 QEMU 的内存模型翻译（考虑 IOMMU、memory region 映射）
2. **事件驱动**：gem5 是事件驱动的仿真器，DMA 需要触发正确的仿真事件（缓存一致性、时序）
3. **一致性保证**：socket 的请求-响应模式天然提供内存屏障语义
4. **IOMMU 兼容**：未来如果启用 IOMMU，QEMU 端需要做地址翻译

**例外**：`readROM()` 直接读共享内存是因为 ROM 是只读的且在仿真早期访问，不需要事件同步。

## 7. Sink 机制

### 7.1 问题场景

在协同仿真模式下，部分 GART PTE 可能为零（未初始化）或指向 VRAM 内部地址。如果 gem5 无法翻译这些地址，会抛出 `GenericPageTableFault`，导致 DMA 重试循环直至仿真挂死。

### 7.2 解决方案

```cpp
// amdgpu_vm.cc: GARTTranslationGen::translate()

if (pte == 0) {
    if (origAddr < vramShmemSize && vramShmemPtr) {
        // VRAM 地址 → 映射到 sink (paddr=0)
        range.paddr = 0;
        warn_once("GART: VRAM address mapped to sink — "
                  "VRAM write-backs are no-ops in cosim");
    } else if (vramShmemPtr) {
        // 未映射的 GART 页 → sink
        range.paddr = 0;
        warn_once("GART cosim: unmapped page → sink");
    }
}
```

**Sink 的语义**：
- `paddr=0` 是 gem5 中始终有效的物理地址（系统 RAM 基址）
- DMA 读取返回零
- DMA 写入被静默丢弃
- 避免了 fault → retry 死循环

## 8. 完整的数据流示例

以 HIP kernel dispatch 为例，展示完整的内存交互：

```
1. hipMalloc(&d_a, N*sizeof(int))
   驱动 → 在 VRAM 中分配 buffer
   写入 GART PTE 到 shared VRAM (BAR0)

2. hipMemcpy(d_a, h_a, N*sizeof(int), hipMemcpyHostToDevice)
   驱动 → 构造 SDMA copy 命令 → 写入 Guest RAM (ring buffer)
   驱动 → 写 Doorbell → QEMU BAR2 → socket → gem5
   gem5 → DMA 读取 ring buffer (Guest RAM via socket)
   gem5 → 解析 SDMA 命令 → GART 翻译源地址 → Guest RAM
   gem5 → DMA 读取源数据 (Guest RAM via socket)
   gem5 → 写入 VRAM 目标地址 (shared memory 直接写)

3. kernel<<<1, N>>>(d_a, d_b, d_c, N)
   驱动 → 构造 PM4 dispatch 命令 → 写入 Guest RAM (ring buffer)
   驱动 → 写 Doorbell → gem5
   gem5 → DMA 读取 PM4 命令 (Guest RAM via socket)
   gem5 → 启动 shader 执行
   gem5 → shader 读写 VRAM (shared memory 直接访问)
   gem5 → 完成后写 fence (Guest RAM via socket DMA write)
   gem5 → 发送 MSI-X 中断 (socket event)

4. hipDeviceSynchronize()
   驱动 → 轮询 fence 值（直到 Guest RAM 中的值匹配）
   └─ fence 由 gem5 通过 DMA write 写入
```

## 9. 已知限制

### 9.1 DMA 缓冲大小

单次 DMA 最大 4 MiB（`COSIM_DMA_BUF_SIZE`）。超过此大小的传输需要分块。实际场景中驱动通常以页为单位提交，不会触及此限制。

### 9.2 User-space 页表（VMID > 0）

VMID 0 (kernel mode) 的 GART 页表通过共享 VRAM 完全可见。但 VMID > 0 (user mode) 的多级页表由 `VegaISA::Walker` 遍历，它使用 gem5 内部的 TLB/page walker，而非直接从共享内存读取。

实际影响有限：驱动写入页表后会发送 TLB invalidate MMIO，gem5 收到后刷新 TLB，下次 walker 遍历时会从正确的物理地址读取（该地址指向共享 VRAM 或 Guest RAM）。

### 9.3 VRAM 写回语义

gem5 中某些 GART 地址指向 VRAM 本身（VRAM-to-VRAM DMA）。这些地址被路由到 sink（paddr=0），写入被静默丢弃。对于纯计算场景，这不影响正确性。

## 10. 文件参考

| 文件 | 关键函数/区域 | 角色 |
|------|-------------|------|
| `gem5/src/dev/amdgpu/amdgpu_vm.cc:396-557` | `GARTTranslationGen::translate()` | GART 翻译核心逻辑 |
| `gem5/src/dev/amdgpu/amdgpu_vm.hh` | `AMDGPUSysVMContext`, `vramShmemPtr` | GART 数据结构 |
| `gem5/src/dev/amdgpu/mi300x_gem5_cosim.cc:139-172` | `setupSharedMemory()` | VRAM 共享内存初始化 |
| `gem5/src/dev/amdgpu/mi300x_gem5_cosim.cc:808-900` | `sendDmaRead/Write()` | DMA 请求发送 |
| `gem5/configs/example/gpufs/mi300_cosim.py` | `shared_backstore` 配置 | Guest RAM 共享设置 |
| `qemu/hw/misc/mi300x_gem5.c:549-602` | `mi300x_gem5_realize()` | BAR0 共享内存映射 |
| `qemu/hw/misc/mi300x_gem5.c:233-296` | event thread DMA handler | DMA 请求处理 |
