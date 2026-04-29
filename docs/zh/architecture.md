[English](../en/architecture.md)

# 协同仿真架构

本文档深入介绍 QEMU + gem5 MI300X 协同仿真系统的架构与设计。涵盖系统级结构、内存共享机制、GPU 地址转换、DMA 数据流、中断转发、xGMI 互连模型以及开发过程中的关键设计决策。

---

## 目录

- [系统架构概述](#系统架构概述)
  - [组件图](#组件图)
  - [关键组件](#关键组件)
  - [通信通道](#通信通道)
- [vfio-user 与 Legacy 后端](#vfio-user-与-legacy-后端)
  - [vfio-user 后端（默认）](#vfio-user-后端默认)
  - [Legacy Socket 后端](#legacy-socket-后端)
  - [后端对比](#后端对比)
- [PCI BAR 布局](#pci-bar-布局)
- [内存共享架构](#内存共享架构)
  - [三个共享通道](#三个共享通道)
  - [VRAM 共享（BAR0）](#vram-共享bar0)
  - [Guest RAM 共享（GTT 页面）](#guest-ram-共享gtt-页面)
  - [内存分割（Q35）](#内存分割q35)
  - [Sink 机制](#sink-机制)
- [GPU 地址转换与 GART](#gpu-地址转换与-gart)
  - [GPU 地址空间与 Aperture](#gpu-地址空间与-aperture)
  - [Aperture 寄存器](#aperture-寄存器)
  - [GART 结构与表布局](#gart-结构与表布局)
  - [PTE 格式](#pte-格式)
  - [getGARTAddr 变换](#getgartaddr-变换)
  - [转换流程](#转换流程)
  - [gartTable 哈希表 vs. 共享 VRAM](#garttable-哈希表-vs-共享-vram)
  - [转换后地址分类](#转换后地址分类)
  - [MMHUB Aperture](#mmhub-aperture)
  - [用户空间转换（VMID > 0）](#用户空间转换vmid-0)
- [DMA 数据流](#dma-数据流)
  - [PM4 Packet Processor 路由](#pm4-packet-processor-路由)
  - [SDMA 引擎路由](#sdma-引擎路由)
  - [VRAM vs. 系统内存检测](#vram-vs-系统内存检测)
  - [vfio-user 后端：共享内存直接访问](#vfio-user-后端共享内存直接访问)
  - [Legacy 后端：Socket DMA 协议](#legacy-后端socket-dma-协议)
  - [中断处理器（IH）DMA](#中断处理器ihdma)
  - [完整数据流示例](#完整数据流示例)
- [MSI-X 中断转发](#msi-x-中断转发)
  - [中断传递路径](#中断传递路径)
  - [IH Ring Buffer 交互](#ih-ring-buffer-交互)
- [xGMI 互连模型](#xgmi-互连模型)
  - [数据包格式](#数据包格式)
  - [地址映射](#地址映射)
  - [拓扑配置](#拓扑配置)
  - [链路参数](#链路参数)
  - [流量控制](#流量控制)
  - [架构阶段](#架构阶段)
- [设计历程与关键决策](#设计历程与关键决策)
  - [为什么选择 vfio-user 而非自定义协议](#为什么选择-vfio-user-而非自定义协议)
  - [为什么选择 Q35 + KVM](#为什么选择-q35-kvm)
  - [共享内存设计](#共享内存设计)
  - [SIGIO 边沿触发排空](#sigio-边沿触发排空)
  - [GART 回退方案](#gart-回退方案)
  - [VRAM 路由发现](#vram-路由发现)

---

## 系统架构概述

协同仿真系统将 GPU 工作负载的执行拆分到两个进程中：QEMU（配合 KVM）负责宿主 CPU、Guest OS 和 amdgpu 驱动，以接近原生的速度运行；gem5 则建模 MI300X GPU 设备——Shader 阵列、命令处理器、SDMA 引擎和 Ruby 缓存层次结构——提供 cycle 级精度。两个进程通过 Unix 域套接字通信，并通过 POSIX 共享内存文件实现零拷贝 DMA。

### 组件图

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

gem5 运行在 Docker 容器内，使用 `StubWorkload`（不运行 Linux 内核）。它作为 vfio-user 服务端启动，监听 Unix 套接字，等待来自 QEMU 的 MMIO 请求。

### 关键组件

| 组件 | 位置 | 作用 |
|---|---|---|
| `MI300XVfioUser` | `src/dev/amdgpu/mi300x_vfio_user.{cc,hh}` | gem5 vfio-user 服务端；通过 libvfio-user 处理 BAR 访问和中断（默认后端） |
| `vfio-user-pci` | QEMU 内建设备 | QEMU 侧 vfio-user 客户端；无需自定义 QEMU 代码 |
| `CosimBridge` | `src/dev/amdgpu/cosim_bridge.hh` | 抽象协同仿真桥接接口，vfio-user 和 legacy 后端均实现此接口 |
| `MI300XGem5Cosim` | `src/dev/amdgpu/mi300x_gem5_cosim.{cc,hh}` | 旧版 socket 桥接 SimObject |
| `mi300x_gem5.c` | `qemu/hw/misc/` | 旧版 QEMU PCI 设备；通过自定义 socket 协议转发 MMIO/doorbell |
| `mi300_cosim.py` | `configs/example/gpufs/` | gem5 配置；通过 `--cosim-backend=vfio-user|legacy` 选择后端 |
| `cosim_launch.sh` | `scripts/` | 编排 Docker (gem5) + QEMU 的启动流程 |

### 通信通道

系统在 QEMU 和 gem5 之间使用三个不同的通道：

1. **VRAM 共享内存**（`/dev/shm/mi300x-vram`，16 GiB）——GPU 显存，包括 GART 页表。双方 mmap 同一文件，实现零拷贝访问。
2. **Guest RAM 共享内存**（`/dev/shm/cosim-guest-ram`，8 GiB）——宿主物理内存，包含 ring buffer、fence、GTT 页面。QEMU 使用 `memory-backend-file` 配合 `share=on`；gem5 使用 `shared_backstore`。
3. **vfio-user socket**（`/tmp/gem5-mi300x.sock`）——承载 MMIO 读写、配置空间访问、Doorbell 写操作和中断通知，使用 vfio-user 协议。

---

## vfio-user 与 Legacy 后端

协同仿真系统支持两种通信后端，通过 gem5 配置中的 `--cosim-backend=vfio-user|legacy` 选择。

### vfio-user 后端（默认）

vfio-user 后端使用行业标准的 vfio-user 协议（QEMU 10.0+ 内置支持）。gem5 侧使用 Nutanix 的 libvfio-user 库作为服务端。

- **QEMU 侧**：使用内建的 `vfio-user-pci` 设备。无需自定义 QEMU 代码；任何原生 QEMU 10.0+ 构建均可使用。
- **gem5 侧**：`MI300XVfioUser` 向 libvfio-user 注册 BAR 区域、配置空间和 MSI-X capability，然后处理来自 QEMU 的请求。
- **DMA**：gem5 通过 Ruby 内存系统的共享后端直接访问 Guest RAM，无需 socket 往返。
- **中断**：通过 `irq_fd`（注入 KVM 的 eventfd）传递，不需要自定义中断消息。

### Legacy Socket 后端

旧版后端使用自定义的 `mi300x-gem5` QEMU PCI 设备和基于两条 Unix socket 连接的自定义二进制协议：

- **同步连接**：MMIO 请求-响应对（QEMU 发送写/读，gem5 响应）。
- **异步连接**：gem5 向 QEMU 发送 IRQ raise/lower 事件和 DMA 读写请求。

此后端需要从 `cosim/qemu/` 目录编译的 QEMU。

### 后端对比

| 维度 | vfio-user 后端 | Legacy Socket 后端 |
|------|---------------|-------------------|
| Guest RAM DMA | Ruby 内存系统直接访问共享后端 | Socket 请求-响应协议 |
| VRAM 访问 | mmap 零拷贝 | mmap 零拷贝 |
| 中断 | irq_fd（eventfd -> KVM） | 自定义 socket 消息 |
| MMIO | vfio-user 消息传递 | 自定义二进制协议 |
| QEMU 侧设备 | 内置 `vfio-user-pci` | 自定义 `mi300x_gem5.c` |
| 地址转换 | gem5 内部 GART 转换 | QEMU 端 `pci_dma_read/write` |
| QEMU 版本 | 原生 QEMU 10.0+ | 需要自定义分支 |

---

## PCI BAR 布局

PCI BAR 布局必须与 amdgpu 驱动中硬编码的预期一致（`AMDGPU_VRAM_BAR=0`、`AMDGPU_DOORBELL_BAR=2`、`AMDGPU_MMIO_BAR=5`）。

```
BAR0+1  VRAM         64-bit prefetchable   16 GiB  (shared memory)
BAR2+3  Doorbell     64-bit                 4 MiB
BAR4    MSI-X        exclusive              256 vectors
BAR5    MMIO regs    32-bit                512 KiB  (forwarded to gem5)
```

| BAR | 内容 | 大小 | 通信方式 |
|-----|------|------|---------|
| BAR0+1 | VRAM | 16 GiB | 共享内存（零拷贝 mmap） |
| BAR2+3 | Doorbell | 4 MiB | Socket 转发（vfio-user 或 legacy） |
| BAR4 | MSI-X | 256 vectors | QEMU 本地 |
| BAR5 | MMIO 寄存器 | 512 KiB | Socket 转发（vfio-user 或 legacy） |

BAR0+1 和 BAR2+3 是 64 位 BAR（16 GiB VRAM 无法放入 32 位地址空间）。在 PCI BAR size probing 期间，每个 64 位 BAR 的上半部分必须返回 size mask 的高 32 位。

PCI class code 设置为 `PCI_CLASS_DISPLAY_VGA (0x0300)` 而非 `PCI_CLASS_DISPLAY_OTHER (0x0380)`，使内核将设备检测为"带有 shadowed ROM 的视频设备"，从而启用 `0xC0000` 处的 VGA ROM 查找。

---

## 内存共享架构

在协同仿真中，GPU 设备模型（gem5）和宿主系统（QEMU/KVM）运行在两个独立进程中。GPU 需要访问两类内存：

- **VRAM**（本地显存）：GPU 私有，存放纹理、buffer、GART 页表和设备本地分配。
- **GTT**（Graphics Translation Table / System Memory）：宿主物理内存中被 GPU 映射的区域，用于 ring buffer、fence、IH cookie 和 DMA 缓冲。

这两类内存都通过 POSIX 共享内存文件实现双向可见，无需 socket 通信。

### 三个共享通道

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
  /dev/shm/mi300x-vram (16 GiB)                      mmap 同一文件
  (VRAM: GPU 数据 + GART 页表)                     (vramShmemPtr)
       |                                                   |
       v                                                   v
  /dev/shm/cosim-guest-ram (8 GiB)                    mmap 同一文件
  (Guest RAM: ring buffer, fence,                (system->getPhysMem())
   GTT 页面, 内核/用户数据)
```

| 通道 | 文件/Socket | 大小 | 用途 | 访问方式 |
|------|-----------|------|------|---------|
| VRAM 共享内存 | `/dev/shm/mi300x-vram` | 16 GiB | GPU 显存 + GART 页表 | mmap（零拷贝） |
| Guest RAM 共享内存 | `/dev/shm/cosim-guest-ram` | 8 GiB | 宿主物理内存（GTT 页面） | QEMU: mmap; gem5: Ruby 内存系统直接访问共享后端 |
| vfio-user Socket | `/tmp/gem5-mi300x.sock` | -- | MMIO/配置空间/Doorbell；中断通过 irq_fd（eventfd -> KVM） | vfio-user 协议 |

### VRAM 共享（BAR0）

#### 初始化流程

gem5 侧（`mi300x_vfio_user.cc:setupVramShm`）：

```cpp
shmemFd = shm_open(shmemPath.c_str(), O_CREAT | O_RDWR, 0666);
ftruncate(shmemFd, vramSize);
shmemPtr = mmap(nullptr, vramSize, PROT_READ | PROT_WRITE, MAP_SHARED, shmemFd, 0);

// Pass the shared pointer to the GART translator
gpuDevice->getVM().vramShmemPtr = (uint8_t *)shmemPtr;
gpuDevice->getVM().vramShmemSize = vramSize;
```

QEMU 通过 vfio-user DMA 区域映射机制获取 BAR0 映射——不再直接打开 VRAM 共享内存文件，而是通过 vfio-user 协议获取映射。

#### VRAM 内容布局

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

#### 访问模式

| 场景 | 写入方 | 读取方 | 路径 |
|------|--------|--------|------|
| GPU buffer 分配 | 驱动（via BAR0 write） | gem5（via vramShmemPtr） | 共享内存直接访问 |
| GART PTE 写入 | 驱动（via BAR0 write） | gem5 GART 翻译器 | memcpy from vramShmemPtr |
| IP Discovery 表 | gem5 初始化 | 驱动（via BAR0 read） | 共享内存直接访问 |

由于 QEMU BAR0 和 gem5 的 `vramShmemPtr` 映射的是同一个 `/dev/shm` 文件，驱动写入 BAR0 的数据对 gem5 立即可见，无需任何 socket 通信。

### Guest RAM 共享（GTT 页面）

在 AMD GPU 中，GTT = GART = Graphics Address Remapping Table。它是一个单级页表（VMID 0），将 GPU 虚拟地址映射到宿主物理地址。被映射的宿主物理内存页面就是所谓的"GTT 页面"。

典型的 GTT 页面内容：

| 数据结构 | 说明 | 访问方向 |
|---------|------|---------|
| PM4 Ring Buffer | GFX 命令队列 | 驱动写 -> GPU 读 |
| SDMA Ring Buffer | DMA 命令队列 | 驱动写 -> GPU 读 |
| IH Ring Buffer | 中断处理队列 | GPU 写 -> 驱动读 |
| Fence 值 | 完成信号 | GPU 写 -> 驱动读 |
| MQD (Map Queue Descriptor) | 队列描述符 | 驱动写 -> GPU 读 |
| 用户 DMA 缓冲 | hipMemcpy 源/目标 | 双向 |

#### 初始化流程

QEMU 侧（命令行参数）：

```bash
-object memory-backend-file,id=mem0,size=8G,\
        mem-path=/dev/shm/cosim-guest-ram,share=on
-numa node,memdev=mem0
```

`share=on` 确保文件映射使用 `MAP_SHARED`，其他进程可以看到 QEMU 对 Guest 内存的修改。

gem5 侧（`mi300_cosim.py`）：

```python
system.shared_backstore = args.shmem_host_path     # "/cosim-guest-ram"
system.auto_unlink_shared_backstore = True
system.memories[0].shared_backstore = args.shmem_host_path
```

gem5 的 `PhysicalMemory` 使用同一个 POSIX 共享内存文件作为后端。

#### 为什么 GTT 不需要额外的共享机制

GTT 页面存在于 Guest RAM 中。Guest RAM 已经通过 `/dev/shm/cosim-guest-ram` 在 QEMU 和 gem5 之间共享：

1. **驱动写入 ring buffer** -> 写入 Guest RAM -> 共享内存 -> gem5 可读
2. **gem5 写入 fence** -> Ruby 内存控制器写入共享后端 -> 驱动可读
3. **GART PTE 指向的物理地址** -> 就是 Guest RAM 中的偏移 -> 双方都能访问

### 内存分割（Q35）

QEMU Q35 在 RAM >= 2.75 GiB 时将内存分为两个区域：

- **4G 以下区域**：前 2 GiB（文件偏移 0）
- **4G 以上区域**：其余部分位于文件偏移 2 GiB 处，映射到 Guest 物理地址 0x100000000+

gem5 的 `mi300_cosim.py` 复制了此分割逻辑，以确保双方在文件布局上保持一致：

```python
total_mem = convert.toMemorySize(args.mem_size)
lowmem_limit = 0x80000000 if total_mem >= 0xB0000000 else 0xB0000000
below_4g = min(total_mem, lowmem_limit)
above_4g = total_mem - below_4g
```

如果双方在 4G 以上内存的文件偏移位置上不一致，gem5 会读到过期或全零的数据（例如 GART PTE 读出全零，导致 PM4 命令处理器中的无限 NOP 循环）。

### Sink 机制

在协同仿真模式下，部分 GART PTE 可能为零（未初始化）或指向 VRAM 内部地址。如果 gem5 无法转换这些地址，原始行为是抛出 `GenericPageTableFault`，导致 DMA 重试循环直至仿真挂死。

Sink 机制防止了这一问题：

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

Sink 语义：

- `paddr=0` 在 gem5 中始终是有效的物理地址（系统 RAM 基址）
- DMA 读取返回零
- DMA 写入被静默丢弃
- 避免了 fault -> retry 死循环

此行为是安全的：诊断确认 GART 第一页（ptStart 本身）通常是未映射的，而后续 PTE 包含有效条目。Sink 确保即使 GPU 尝试 DMA 到驱动尚未映射的页面，仿真仍然保持存活。

---

## GPU 地址转换与 GART

MI300X（GFX 9.4.3）使用多个地址空间和 aperture 来访问内存。GPU 发出的每次内存访问首先按 aperture 分类，然后转换为物理地址。

### GPU 地址空间与 Aperture

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

### Aperture 寄存器

这些 MMIO 寄存器定义了每个 aperture 的边界。这些值由 amdgpu 驱动在 GMC（Graphics Memory Controller）初始化期间设置。

| 寄存器 | gem5 字段 | 格式 | 描述 |
|----------|-----------|--------|-------------|
| `MC_VM_FB_LOCATION_BASE` | `vmContext0.fbBase` | `bits[23:0] << 24` | MC 地址空间中 VRAM 的起始地址 |
| `MC_VM_FB_LOCATION_TOP` | `vmContext0.fbTop` | `bits[23:0] << 24 | 0xFFFFFF` | VRAM 结束地址 |
| `MC_VM_FB_OFFSET` | `vmContext0.fbOffset` | `bits[23:0] << 24` | FB 重定位偏移量 |
| `MC_VM_AGP_BASE` | `vmContext0.agpBase` | `bits[23:0] << 24` | AGP 重映射基地址 |
| `MC_VM_AGP_BOT` | `vmContext0.agpBot` | `bits[23:0] << 24` | AGP aperture 底部 |
| `MC_VM_AGP_TOP` | `vmContext0.agpTop` | `bits[23:0] << 24 | 0xFFFFFF` | AGP aperture 顶部 |
| `MC_VM_SYSTEM_APERTURE_LOW_ADDR` | `vmContext0.sysAddrL` | `bits[29:0] << 18` | System aperture 低地址 |
| `MC_VM_SYSTEM_APERTURE_HIGH_ADDR` | `vmContext0.sysAddrH` | `bits[29:0] << 18` | System aperture 高地址 |
| `VM_CONTEXT0_PAGE_TABLE_BASE_ADDR` | `vmContext0.ptBase` | raw 64-bit | GART 表在 VRAM 中的位置 |
| `VM_CONTEXT0_PAGE_TABLE_START_ADDR` | `vmContext0.ptStart` | raw 64-bit | GART aperture 起始地址（页号） |
| `VM_CONTEXT0_PAGE_TABLE_END_ADDR` | `vmContext0.ptEnd` | raw 64-bit | GART aperture 结束地址（页号） |

协同仿真中的典型值（来自驱动初始化诊断）：

```
ptBase   = 0x3EE600000     GART table at VRAM offset ~15.7 GiB
ptStart  = 0x7FFF00000     GART covers GPU VAs from 0x7FFF00000000
ptEnd    = 0x7FFF1FFFF     GART covers ~128K pages (512 MiB)
fbBase   = 0x8000000000    VRAM starts at MC address 512 GiB
fbTop    = 0x8400FFFFFF    VRAM ends at ~528 GiB (16 GiB range)
sysAddrL = 0x0             System aperture start
sysAddrH = 0x3FFEC0000     System aperture end (~4 TiB)
```

### GART 结构与表布局

GART 是一个单级页表，供 VMID 0（内核模式）使用，将 GPU 虚拟地址映射到系统物理地址。它使 GPU 能够对主机（Guest）RAM 进行 DMA 访问，用于 ring buffer、fence 值、IH cookie 以及其他内核模式数据结构。

GART 表位于 VRAM 偏移 `ptBase` 处：

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

### PTE 格式

每个 PTE 为 8 字节：

```
63    52 51  48 47              12 11  6 5  2 1   0
+-------+------+-----------------+------+----+---+---+
| Flags | BlkF | Physical Page   | Rsvd |Frag|Sys| V |
|       |      | (PA >> 12)      |      |    |   |   |
+-------+------+-----------------+------+----+---+---+
```

| 位域 | 字段 | 描述 |
|------|-------|-------------|
| 0 | Valid | 条目有效 |
| 1 | System | 1 = 系统内存（Guest RAM），0 = 本地 VRAM |
| 5:2 | Fragment | 页面片段大小 |
| 47:12 | Physical Page | 物理地址 >> 12 |
| 51:48 | Block Fragment | 块片段大小 |
| 63:52 | Flags | MTYPE、PRT 等 |

物理地址提取：`paddr = (bits(PTE, 47, 12) << 12) | page_offset`

### getGARTAddr 变换

在 GART 查找之前，地址通过 `getGARTAddr()` 进行变换。该函数将页号乘以 8（PTE 的大小），实际上是将 GPU VA 转换为 GART 表内的字节偏移量：

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

### 转换流程

完整的 GART 转换序列：

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

驱动通过以下路径写入 GART PTE：

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

### gartTable 哈希表 vs. 共享 VRAM

在独立 gem5 模式下，GART 条目维护在一个哈希表（`AMDGPUVM::gartTable`）中，由以下方式填充：

1. **直接写入**（`amdgpu_device.cc:writeFrame()`）：当驱动通过 BAR0 写入 VRAM 的 GART 区域时，值被存储到 `gartTable[offset]` 中。
2. **SDMA 影子拷贝**（`sdma_engine.cc`）：当 SDMA 写入设备内存中的 GART 范围时，影子拷贝会更新 `gartTable`。

在协同仿真模式下，驱动通过 QEMU 的 BAR0 映射写入 GART PTE，直接进入共享 VRAM，不经过 gem5 的 `writeFrame()`。因此，`gartTable` 基本为空。协同仿真回退机制直接从共享 VRAM 的 `vramShmemPtr + ptBase` 处读取 PTE：

```cpp
Addr pte_table_offset = gart_addr - (ptStart * 8);
Addr pte_vram_offset = gartBase() + pte_table_offset;
memcpy(&pte, vramShmemPtr + pte_vram_offset, sizeof(pte));
```

如果 PTE 为 0（未映射的页面），协同仿真模式将映射到 sink（`paddr=0`），而不是产生 fault（参见 [Sink 机制](#sink-机制)）。

### 转换后地址分类

GART 转换得到物理地址后，gem5 判断该地址指向哪里：

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

MMHUB（Memory Management Hub）提供 VRAM 的影子映射。`[mmhubBase, mmhubTop]` 范围内的地址通过减去基地址进行转换：

```
vram_offset = vaddr - mmhubBase
```

SDMA 在 VMID 0 模式下使用此 aperture 访问设备内存。

### 用户空间转换（VMID > 0）

用户空间 GPU 程序（如 HIP 应用）使用类似于 x86-64 分页的多级页表。每个 VMID（1-15）拥有自己的页表基址寄存器。

```
VM_CONTEXT[N]_PAGE_TABLE_BASE_ADDR  -> Page Directory Base
  |
  v 4-level walk (PDE3 -> PDE2 -> PDE1 -> PDE0 -> PTE)
Physical address
```

`UserTranslationGen` 类使用 GPU 的页表遍历器（`VegaISA::Walker`）执行此遍历。用户模式（vmid > 0）下的 SDMA 使用此路径。

VMID 0（内核模式）GART 页表通过共享 VRAM 完全可见。VMID > 0（用户模式）多级页表由 `VegaISA::Walker` 遍历，它使用 gem5 内部的 TLB/page walker，而非直接从共享内存读取。实际影响有限：驱动写入页表后会发送 TLB invalidate MMIO，gem5 收到后刷新 TLB，后续 walker 遍历时会从正确的物理地址读取。

---

## DMA 数据流

### PM4 Packet Processor 路由

```
PM4PacketProcessor::translate(vaddr, size)
  |
  +-- inAGP(vaddr)?  -> AGPTranslationGen  (direct offset)
  |
  +-- else           -> GARTTranslationGen  (page table lookup)
```

所有 PM4 DMA 使用 GART 转换（VMID 0）。地址在 DMA 调用之前先通过 `getGARTAddr()` 变换。

### SDMA 引擎路由

SDMA 比 PM4 具有更多的 aperture 感知能力，因为它同时处理内核模式（VMID 0）和用户模式（VMID > 0）的操作：

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

### VRAM vs. 系统内存检测

对于 PM4 的 RELEASE_MEM 和 WRITE_DATA 数据包，目标可以是 VRAM 或系统内存。路由逻辑：

```cpp
bool vram = isVRAMAddress(pkt->addr);  // addr < gpuDevice->getVRAMSize()
Addr addr = vram ? pkt->addr : getGARTAddr(pkt->addr);

if (vram)
    gpuDevice->getMemMgr()->writeRequest(addr, data, size);  // device memory
else
    dmaWriteVirt(addr, size, cb, data);  // system memory via GART
```

如果没有此检查，VRAM 地址会被送入 `getGARTAddr()` 导致页号乘以 8，GART 转换失败（VRAM 地址没有对应的页表项）。三层防护（PM4 层、SDMA 层、GART 回退 sink）防止仿真崩溃。

### vfio-user 后端：共享内存直接访问

在 vfio-user 后端下，gem5 通过 Ruby 内存系统的共享后端直接访问 Guest RAM，无需基于 socket 的 DMA 操作：

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

关键优势：

- **零拷贝**：DMA 读写直接操作共享内存，无需序列化/反序列化
- **低延迟**：省去了 socket 请求-响应的往返开销
- **简化架构**：无需自定义 DMA 协议，Ruby 内存系统天然支持共享后端

### Legacy 后端：Socket DMA 协议

旧版后端通过 socket 使用自定义二进制协议路由 DMA。

**gem5 读取 Guest RAM**（ring buffer / fence）：

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

**gem5 写入 Guest RAM**（fence / IH cookie）：

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

Legacy 后端的单次 DMA 最大传输量为 4 MiB（`COSIM_DMA_BUF_SIZE`）。实际场景中驱动通常以页为单位提交。

### 中断处理器（IH）DMA

中断处理器使用原始系统物理地址（非 GART）：

```
IH Ring Buffer:  regs.baseAddr    (from IH_RB_BASE register)
Wptr Address:    regs.WptrAddr    (from IH_RB_WPTR_ADDR registers)
```

这些是驱动设置的 GPA（Guest Physical Address）。IH 写入流程：

1. 将中断 cookie（32 字节）写入 `baseAddr + IH_Wptr`
2. 将更新后的写指针写入 `WptrAddr`
3. 调用 `intrPost()` 向 Guest 发送 MSI-X 中断

在协同仿真模式下，DMA 写入落入共享 Guest RAM（`/dev/shm/cosim-guest-ram`），中断通过 vfio-user 的 irq_fd 机制（或 legacy 后端的 event socket）转发给 QEMU。

### 完整数据流示例

以 HIP kernel dispatch 为例，展示跨两个共享内存区域的完整内存交互：

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

Fence 写入（RELEASE_MEM）的地址转换细节：

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

## MSI-X 中断转发

### 中断传递路径

GPU 通过 MSI-X 中断向 Guest 发出完成事件信号（fence 回写、IH ring 条目）。中断传递链在不同后端中有所不同：

**vfio-user 后端**：

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

vfio-user 后端使用注册到 KVM 的 eventfd 描述符（`irq_fd`）。当 gem5 触发中断时，它写入 eventfd，KVM 直接将中断注入 Guest——热路径无需 QEMU 参与。

**Legacy 后端**：

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

设备支持 256 个 MSI-X 向量（BAR4）。

### IH Ring Buffer 交互

MSI-X 中断到达后，Guest 的 IH（Interrupt Handler）从 Guest RAM 中的 IH ring buffer 读取中断 cookie：

1. gem5 将 32 字节中断 cookie 写入 Guest RAM 的 `IH_RB_BASE + IH_Wptr`
2. gem5 更新 `IH_RB_WPTR_ADDR` 处的写指针
3. gem5 调用 `intrPost()` 传递 MSI-X 中断
4. Guest IH handler 唤醒，从 ring buffer 读取 cookie，处理事件

Ring buffer 和写指针都位于共享 Guest RAM 中，gem5 的 Ruby 内存系统写入后 Guest 立即可见。

---

## xGMI 互连模型

xGMI（芯片间全局内存互连）模型提供 cosim-gpu 多 GPU hive 中的 GPU 间通信。它挂载在每个 GPU 的 L2 缓存（TCC）出口端口上，将远程 VRAM 访问通过可配置的带宽、延迟和拓扑的 xGMI 链路模型进行路由。

### 数据包格式

| 字段 | 类型 | 描述 |
|------|------|------|
| src_gpu | uint8 | 源 GPU ID |
| dst_gpu | uint8 | 目标 GPU ID |
| addr | uint64 | 目标 VRAM 地址 |
| size | uint32 | 负载大小（字节） |
| payload | bytes | 数据（写操作时） |

### 地址映射

每个 GPU 拥有连续的 VRAM 地址范围：

```
GPU 0: [0, vram_size)
GPU 1: [vram_size, 2 * vram_size)
GPU N: [N * vram_size, (N+1) * vram_size)
```

桥接器通过检查地址落入哪个 GPU 的范围来判断本地或远程访问。

### 拓扑配置

启动参数 `--xgmi-topology`：

- **mesh**：每个 GPU 与所有其他 GPU 直连。8 GPU mesh 创建 28 条双向链路。
- **ring**：每个 GPU 连接其两个邻居。链路数更少但非相邻 GPU 需多跳。

### 链路参数

| 参数 | 默认值 | CLI 标志 |
|------|--------|----------|
| 每链路带宽 | 128 GB/s | `--xgmi-bandwidth` |
| 每跳延迟 | 100 ns | `--xgmi-latency` |
| 每链路通道数 | 16 | （SimObject 参数） |
| 每 GPU 最大链路 | 7 | （SimObject 参数） |
| 流控信用 | 32 | （SimObject 参数） |

### 流量控制

基于信用的背压机制防止数据丢失：

1. 每条链路初始 N 个信用（默认 32）。
2. 发送一个数据包消耗一个信用。
3. 接收方在接受数据包后归还信用。
4. 信用归零时发送方阻塞（永不丢弃）。

### 架构阶段

**Path A（自建 xGMI 模型）**：

- 单进程多 GPU：进程内函数调用
- 多进程 8-GPU hive：通过共享内存环形缓冲区或 Unix socket 的 IPC 传输

**Path B（SST Merlin 集成）**：

- 用 SST Merlin 网络引擎替换 xGMI 传输
- 三层同步：QEMU（功能仿真）<-> gem5（GPU 时序）<-> SST（网络时序）
- 支持任意拓扑（fat-tree、dragonfly）

### 关键源文件

- `gem5/src/dev/amdgpu/XGMIBridge.py` -- SimObject 定义
- `gem5/src/dev/amdgpu/xgmi_bridge.hh` -- C++ 头文件
- `gem5/src/dev/amdgpu/xgmi_bridge.cc` -- C++ 实现
- `gem5/configs/example/gpufs/mi300_cosim.py` -- 配置和连线

---

## 设计历程与关键决策

本节记录了塑造协同仿真系统的关键架构决策和重要 bug 修复洞察。

### 为什么选择 vfio-user 而非自定义协议

初始实现使用自定义二进制协议，通过两条 Unix socket 连接传输（一条同步用于 MMIO，一条异步用于事件）。这种方式可以工作，但需要维护一个自定义 QEMU PCI 设备（`mi300x_gem5.c`）和自定义协议定义。

迁移到 vfio-user 由三个因素驱动：

1. **无需自定义 QEMU 代码**：任何原生 QEMU 10.0+ 构建都可以通过内置的 `vfio-user-pci` 设备直接连接 gem5，无需维护 QEMU 分支。
2. **协议标准化**：BAR 映射、配置空间、中断和 DMA 全部由 vfio-user 规范定义，减少了协议层面的 bug 可能性。
3. **更简单的部署**：用户只需构建支持 libvfio-user 的 gem5；QEMU 直接使用原生版本。

vfio-user 迁移过程中解决的问题：

- libvfio-user 的 BAR size 字段是 `uint32_t`，无法表示 16 GiB VRAM——改为 `uint64_t`。
- 64 位 BAR 的上半部分在 PCI BAR size probing 时需要返回 size mask 的高 32 位。
- PCIe Express 和 MSI-X capability 必须在 `vfu_realize_ctx()` 之前注册。
- SDMA ring test 超时：`sdma_delay=1e9` 导致约 500 ms 墙钟延迟，超过驱动端约 200 ms 的超时窗口——将 `sdma_delay` 减小到 1000，同时将 `KEEPALIVE_INTERVAL` 增加到 `1e9`。

### 为什么选择 Q35 + KVM

协同仿真使用 QEMU 的 Q35 机器类型配合 KVM 加速：

- **KVM**：以接近原生的速度运行 Guest CPU。完整的 Linux 启动 + 驱动加载在一分钟内完成，而 gem5 全系统模式下需要 10 分钟以上。这大幅缩短了调试周期。
- **Q35**：提供现代 PCIe 芯片组，支持 64 位 BAR（16 GiB VRAM BAR 所必需）和 MSI-X 中断。
- **gem5 端的 StubWorkload**：gem5 不运行自己的内核。它启动一个最小事件循环，等待来自 QEMU 的 MMIO 请求。这避免了双内核的复杂性，使 gem5 专注于 GPU 建模。

### 共享内存设计

使用两个独立的 POSIX 共享内存文件（`/dev/shm/cosim-guest-ram` 和 `/dev/shm/mi300x-vram`）而非单一统一内存的决策，源于两个内存区域本质上的不同：

- **Guest RAM** 必须作为 QEMU `memory-backend-file`（配合 `share=on`）和 gem5 `PhysicalMemory`（通过 `shared_backstore`）的后端存储。文件布局必须精确复制 Q35 的 4G 以下/4G 以上内存分割方式。
- **VRAM** 作为 BAR0 暴露给 QEMU，作为设备内存暴露给 gem5。它有自己的内部布局（数据区 + GART 页表），与 Guest 物理地址空间无关。

将两者合并到一个文件中会引入复杂的偏移算术和两个独立地址空间之间的耦合。

### SIGIO 边沿触发排空

gem5 的 `PollQueue` 使用 `FASYNC`/`SIGIO` 监听 socket，这是边沿触发的：当 socket 缓冲区从空变为非空时，内核发送一次 `SIGIO`，且仅此一次。

amdgpu 驱动频繁地先写 INDEX 寄存器（选择要访问的内部寄存器），然后立即读 DATA 寄存器（获取值）。这两条消息背靠背到达 gem5 的 socket 缓冲区，但只会触发一次 SIGIO。如果消息处理器每次只读一条消息，第二条消息就会留在缓冲区中，没有信号唤醒 gem5。QEMU 阻塞等待读响应。结果：处理 15 条消息后死锁。

修复方案：使用 `do/while` 排空循环配合 `poll(fd, POLLIN, 0)`，在每次 SIGIO 到来时消费所有待处理消息：

```cpp
do {
    // read and process one message
    ...
    struct pollfd pfd = {fd, POLLIN, 0};
} while (poll(&pfd, 1, 0) > 0 && (pfd.revents & POLLIN));
```

此问题仅影响 legacy 后端。vfio-user 后端使用 libvfio-user 的非阻塞 poll 机制。

### GART 回退方案

在独立 gem5 模式下，GART 条目维护在哈希表（`gartTable`）中，由 `writeFrame()` 和 SDMA 影子拷贝填充。在协同仿真中，驱动通过 QEMU 的 BAR0 映射写入 GART PTE，直接进入共享 VRAM，不经过 gem5 的 `writeFrame()`。哈希表为空。

协同仿真回退机制直接从共享 VRAM 的 `vramShmemPtr + ptBase` 处读取 PTE。当 PTE 为零（未映射）时，条目映射到 sink（`paddr=0`），而非产生 fault。这防止了 `GenericPageTableFault` -> DMA 重试死循环（此前曾导致内存耗尽和段错误）。

诊断确认共享 VRAM 中 `gartBase`（= `ptBase`）处的 GART PTE 已被驱动正确填充。第一页（ptStart 本身）只是未映射——这是正常行为——而后续 PTE（偏移 0x32E0+）包含有效条目。

### VRAM 路由发现

地址 `0x1f72fa8000` 触发了超过 861,000 次 GART 转换错误，导致内存耗尽和段错误。根因：SDMA rptr 回写地址和 PM4 RELEASE_MEM 目标地址可能指向 VRAM（地址 < 16 GiB）。当这些地址被送入 `getGARTAddr()` 时，页号被乘以 8，GART 转换失败（VRAM 地址没有对应的页表项）。

修复采用三层防护：

1. **PM4 层**（`pm4_packet_processor.cc`）：`writeData()`、`releaseMem()`、`queryStatus()` 检查 `isVRAMAddress(addr)`，将 VRAM 写操作通过 `gpuDevice->getMemMgr()->writeRequest()`（设备内存）路由，而非 `dmaWriteVirt()`（通过 GART 的系统内存）。
2. **SDMA 层**（`sdma_engine.cc`）：`setGfxRptrLo/Hi()` 和 rptr 回写对 VRAM 地址跳过 `getGARTAddr()`，改用 `getMemMgr()->writeRequest()`。
3. **GART 兜底**（`amdgpu_vm.cc`）：`GARTTranslationGen::translate()` 通过逆向 `getGARTAddr` 变换（`orig_page = page_num >> 3`）检测 VRAM 地址，并将其映射到 `paddr=0` 作为 sink，而非产生 fault。

---

## 关键源文件

| 文件 | 作用 |
|------|------|
| `src/dev/amdgpu/mi300x_vfio_user.{cc,hh}` | vfio-user 服务端 SimObject（默认后端） |
| `src/dev/amdgpu/mi300x_gem5_cosim.{cc,hh}` | 旧版 socket 桥接 SimObject |
| `src/dev/amdgpu/cosim_bridge.hh` | 抽象 CosimBridge 接口 |
| `src/dev/amdgpu/amdgpu_vm.{cc,hh}` | 所有转换生成器（GART、AGP、MMHUB、User） |
| `src/dev/amdgpu/pm4_packet_processor.{cc,hh}` | PM4 DMA 路由、VRAM 检测、`getGARTAddr` |
| `src/dev/amdgpu/sdma_engine.{cc,hh}` | SDMA DMA 路由、GART 影子拷贝 |
| `src/dev/amdgpu/interrupt_handler.cc` | IH ring buffer DMA 和中断传递 |
| `src/dev/amdgpu/amdgpu_device.cc` | 设备级 `intrPost()`、`writeFrame()` |
| `src/dev/amdgpu/xgmi_bridge.{cc,hh}` | xGMI 互连桥接 |
| `configs/example/gpufs/mi300_cosim.py` | 系统配置、内存设置、后端选择 |
| `scripts/cosim_launch.sh` | 启动编排 |
