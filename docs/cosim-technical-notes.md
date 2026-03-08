# QEMU + gem5 MI300X 协同仿真：技术笔记

本文档总结了 QEMU + gem5 MI300X 协同仿真系统的架构、实现细节、已解决的问题和已知限制。

## 1. 架构概述

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

### 关键组件

| 组件 | 位置 | 作用 |
|---|---|---|
| `mi300x_gem5.c` | `qemu/hw/misc/` | QEMU PCI 设备；通过 socket 将 MMIO/doorbell 转发到 gem5 |
| `MI300XGem5Cosim` | `src/dev/amdgpu/mi300x_gem5_cosim.{cc,hh}` | gem5 SimObject；接受 socket 连接，分发到 AMDGPUDevice |
| `mi300_cosim.py` | `configs/example/gpufs/` | gem5 配置；最小化的 System()，包含 GPU 层次结构，无 kernel |
| `cosim_launch.sh` | `scripts/` | 编排 Docker (gem5) + QEMU 的启动流程 |

### PCI BAR 布局

```
BAR0+1  VRAM         64-bit prefetchable   16 GiB  (shared memory)
BAR2+3  Doorbell     64-bit                 4 MiB
BAR4    MSI-X        exclusive
BAR5    MMIO regs    32-bit                512 KiB  (forwarded to gem5)
```

此布局**必须**与 amdgpu 驱动中硬编码的预期一致（`AMDGPU_VRAM_BAR=0`、`AMDGPU_DOORBELL_BAR=2`、`AMDGPU_MMIO_BAR=5`）。

## 2. 已解决的问题（踩坑日志）

### 2.1 共享内存文件偏移量不匹配（严重）

**现象**：GART 页表项读出全为零；PM4 opcode 0x0（NOP，count 为 0）无限重复。

**根因**：QEMU Q35 和 gem5 对 4G 以下/4G 以上的内存拆分方式不一致，导致共享后备存储中的文件偏移量不同。

- QEMU Q35 配置 8 GiB RAM 时：`below_4g = 2 GiB`（当 `ram_size >= 0xB0000000` 时硬编码）。参见 `qemu/hw/i386/pc_q35.c:161`。
- gem5 配置为 3 GiB 以下 / 5 GiB 以上。
- QEMU 将 4G 以上数据放在文件偏移 2 GiB 处；gem5 从偏移 3 GiB 处读取 → 全为零。

**修复**：`mi300_cosim.py` 复刻了 Q35 的拆分逻辑：

```python
total_mem = convert.toMemorySize(args.mem_size)
lowmem_limit = 0x80000000 if total_mem >= 0xB0000000 else 0xB0000000
below_4g = min(total_mem, lowmem_limit)
above_4g = total_mem - below_4g
```

**关键教训**：当两个系统共享 memory-backend-file 时，它们必须在每个范围的文件偏移量上达成一致，而不仅仅是总大小。

### 2.2 SIGIO 边沿触发排空问题（严重）

**现象**：gem5 处理完第一条 MMIO 消息后永远挂起。QEMU 的 socket 缓冲区被填满。

**根因**：gem5 的 `PollQueue` 使用 `FASYNC`/`SIGIO`，这是**边沿触发**的。如果在处理第一条消息之前有多条消息到达，只会触发一次 `SIGIO`。处理完一条消息后，剩余的消息留在 socket 缓冲区中，没有信号唤醒 gem5。

**修复**：`mi300x_gem5_cosim.cc:handleClientData()` 使用 `do/while` 循环配合 `poll(fd, POLLIN, 0)` 来排空每次 SIGIO 到来时**所有**待处理的消息。

```cpp
do {
    // read and process one message
    ...
    struct pollfd pfd = {fd, POLLIN, 0};
} while (poll(&pfd, 1, 0) > 0 && (pfd.revents & POLLIN));
```

### 2.3 VRAM 地址 GART 翻译错误（严重）

**现象**：地址 `0x1f72fa8000` 产生 861,000 多次 GART 翻译错误，内存耗尽，段错误。

**根因**：SDMA rptr 回写地址和 PM4 RELEASE_MEM 目标地址可能指向 VRAM（地址 < 16 GiB）。这些地址经过 `getGARTAddr()` 处理时会将页号乘以 8，然后 GART 翻译失败，因为 VRAM 地址没有对应的页表项。

**修复（三层防护）**：

1. **PM4 层**（`pm4_packet_processor.cc`）：`writeData()`、`releaseMem()`、`queryStatus()` 检查 `isVRAMAddress(addr)`，将 VRAM 写操作通过 `gpuDevice->getMemMgr()->writeRequest()`（设备内存）路由，而非 `dmaWriteVirt()`（通过 GART 的系统内存）。

2. **SDMA 层**（`sdma_engine.cc`）：`setGfxRptrLo/Hi()` 和 rptr 回写对 VRAM 地址跳过 `getGARTAddr()`，改用 `getMemMgr()->writeRequest()`。

3. **GART 兜底**（`amdgpu_vm.cc`）：`GARTTranslationGen::translate()` 通过逆向 `getGARTAddr` 变换（`orig_page = page_num >> 3`）检测 VRAM 地址，并将其映射到 `paddr=0` 作为 sink，而非产生 fault。

### 2.4 协同仿真模式下的定时器溢出

**现象**：经过数十亿 tick 后，gem5 因 `curTick()` 整数溢出而崩溃（RTC 和 PIT 定时器持续调度事件）。

**修复**：为 `Cmos` 添加了 `disable_rtc_events` 参数，为 `I8254` 添加了 `disable_timer_events` 参数。在 `mi300_cosim.py` 中均设为禁用。`MI300XGem5Cosim` 中的 keepalive 事件防止事件队列变空。

### 2.5 PSP / SMU 固件加载失败

**现象**：使用 `ip_block_mask=0x6f` 执行 `modprobe amdgpu` 时，在 PSP 固件加载阶段出现 `-EINVAL` 错误。

**根因**：在 ROCm 7.0 的 `amdgpu_discovery.c` 中，IP block 枚举顺序为：
```
0: soc15_common  1: gmc_v9_0  2: vega20_ih
3: psp           4: smu       5: gfx_v9_4_3
6: sdma_v4_4_2   7: vcn_v4_0_3  8: jpeg_v4_0_3
```

`ip_block_mask=0x6f` = `0b01101111` 禁用了 bit 4（SMU）但**没有**禁用 bit 3（PSP）。应使用 `ip_block_mask=0x67` = `0b01100111` 来同时禁用 PSP（bit 3）和 SMU（bit 4）。

### 2.6 QEMU 串口控制台与 `-nographic` 的冲突

**现象**：同时使用 `-serial unix:/tmp/serial.sock -nographic` 时，guest 没有串口输出。

**根因**：`-nographic` 隐含了 `-serial mon:stdio`，它创建了映射到 stdio 的 serial0。显式的 `-serial unix:...` 变成了 serial1（ttyS1），但 kernel 使用的是 `console=ttyS0`。

**修复**：单独使用 `-nographic`（串口输出到 stdio）。如需程序化访问，在 `screen` 中运行 QEMU：
```bash
screen -dmS qemu-cosim -L -Logfile /tmp/log <qemu-cmd>
screen -S qemu-cosim -X stuff 'command\n'
```

### 2.7 不支持的 PM4 操作码

| 操作码 | 名称 | 说明 | 修复方式 |
|--------|------|------|----------|
| `0x58` | `ACQUIRE_MEM` | 内存屏障 / 缓存刷新 | NOP（跳过包体） |
| `0xA0` | `SET_RESOURCES` | 队列资源配置 | NOP（跳过包体） |

两者均已添加到 `pm4_defines.hh` 中，并在 `pm4_packet_processor.cc:decodeHeader()` 中作为跳过并继续处理。

### 2.8 链接时内存不足（OOM）

**现象**：即使使用 `-j2`，链接器也被 OOM killer 终止。

**修复**：使用 gold 链接器并限制单任务：
```bash
scons build/VEGA_X86/gem5.opt -j1 GOLD_LINKER=True --linker=gold
```

### 2.9 PCI Class Code

**现象**：amdgpu 驱动跳过了 `0xC0000` 处的 legacy VGA ROM 检查。

**修复**：将 PCI class 从 `PCI_CLASS_DISPLAY_OTHER (0x0380)` 改为 `PCI_CLASS_DISPLAY_VGA (0x0300)`。使用 VGA class 后，kernel 自动检测为"带有 shadowed ROM 的视频设备"。

### 2.10 GART 未映射页崩溃（严重）

**现象**：HIP 程序输出 `hipMalloc OK` 后，gem5 段错误，伴随重复的 `GART translation for 0x3fff800000000 not found` 警告。

**根因**：GPU 的 PM4/SDMA 引擎尝试 DMA 到驱动尚未映射的 GART 页（共享 VRAM 中 PTE = 0）。原始代码创建了 `GenericPageTableFault`，但 DMA 回调链无限重试同一个失败地址，耗尽内存并崩溃。

**修复**：在协同仿真模式下，将未映射的 GART 页映射到 sink（`paddr=0`）而非产生 fault。DMA 读操作返回零，写操作被丢弃，但仿真保持存活。GART sink 诊断信息还会记录 `fbBase` 以辅助调试。

**关键发现**：共享 VRAM 中 `gartBase`（= `ptBase`）处的 GART PTE 已被驱动正确填充。诊断信息确认后续的 PTE（偏移 0x32E0+）包含有效条目，而第一页（ptStart 本身）只是未映射——这是正常现象。

## 3. 当前状态

### 已实现的功能

- **驱动初始化**：amdgpu 3.64.0 完整加载
  - 从固件文件进行 IP discovery（`discovery=2`）
  - GMC（内存控制器）、GFX（计算）、SDMA、IH（中断处理器）
  - 8 个 KIQ ring 已映射（mec 2 pipe 1 q 0）
  - 4 个 SDMA 引擎 × 4 队列 = 16 个 SDMA ring
  - 跨 8 个 XCP 分区的 64 个以上 compute ring
  - 7 个 DRM XCP 设备节点（`/dev/dri/renderD129..135`）
- **ROCm 工具**：
  - `rocm-smi`：设备 0x74a0，SPX 分区，1% VRAM
  - `rocminfo`：Agent gfx942，320 CU，4 SIMD/CU，KERNEL_DISPATCH
- **KFD**（Kernel Fusion Driver）：节点已添加，16383 MB VRAM，HSA agent 已注册
- **GPU 计算（HIP）**：完全可用！
  - `hipMalloc` / `hipMemcpy`（host-to-device、device-to-host）
  - Kernel dispatch（`addKernel<<<1, N>>>`）运行在 gfx942 上
  - `hipDeviceSynchronize` 返回 `hipSuccess`
  - 结果验证正确：`{1+10, 2+20, 3+30, 4+40}` = `{11, 22, 33, 44}`
- **MSI-X 中断转发**：gem5 → QEMU 通过 event socket
  - `AMDGPUDevice::intrPost()` → `cosimBridge->sendIrqRaise(0)`
  - QEMU event 线程 → `msix_notify()` → guest IH 处理程序
- **GART 翻译**：协同仿真兜底机制从共享 VRAM 读取 PTE；未映射页安全路由到 sink
- **65,000+ 次 MMIO 操作**处理无崩溃
- **磁盘镜像**：`ip_block_mask=0x67` 通过 systemd 服务持久化（`load-amdgpu.service` → `/root/load_amdgpu.sh`）

### 已知限制

1. **Fence 回退定时器**：驱动初始化期间出现 80 多次 DRM fence 超时（每次约 500 ms）。ring 测试通过 DRM 回退定时器"通过"。驱动加载完成后，MSI 中断可正常用于计算分发。

2. **无 VGA BIOS ROM**：`Unable to locate a BIOS ROM` 警告。计算场景不需要；可跳过 VGA ROM dd 步骤。

3. **GART 未映射页**：部分 GART 页的 PTE=0，路由到 sink。这是安全的，但意味着 DMA 到这些地址时读取到零。

## 4. 文件变更总结

### gem5（新文件）
| 文件 | 说明 |
|---|---|
| `src/dev/amdgpu/mi300x_gem5_cosim.{cc,hh}` | Socket 桥接 SimObject |
| `src/dev/amdgpu/MI300XGem5Cosim.py` | SimObject Python 封装 |
| `configs/example/gpufs/mi300_cosim.py` | 协同仿真系统配置 |
| `scripts/cosim_launch.sh` | 启动编排脚本 |

### gem5（修改的文件）
| 文件 | 变更内容 |
|---|---|
| `src/dev/amdgpu/pm4_packet_processor.{cc,hh}` | VRAM 写路由、`isVRAMAddress()`、ACQUIRE_MEM/SET_RESOURCES NOP |
| `src/dev/amdgpu/pm4_defines.hh` | 添加 `IT_ACQUIRE_MEM`、`IT_SET_RESOURCES` |
| `src/dev/amdgpu/sdma_engine.cc` | VRAM rptr 回写路由 |
| `src/dev/amdgpu/amdgpu_vm.{cc,hh}` | GART 协同仿真兜底（共享 VRAM PTE 读取）、VRAM 地址 sink |
| `src/dev/amdgpu/amdgpu_device.cc` | 协同仿真集成钩子 |
| `src/dev/amdgpu/amdgpu_nbio.cc` | ASIC 初始化完成寄存器 |
| `src/dev/intel_8254_timer.{cc,hh}` | `disable_timer_events` 参数 |
| `src/dev/mc146818.{cc,hh}` | `disable_rtc_events` 参数 |

### QEMU（新文件）
| 文件 | 说明 |
|---|---|
| `hw/misc/mi300x_gem5.c` | 带 socket 桥接的 MI300X PCI 设备 |
| `hw/misc/mi300x_gem5.h` | 头文件 |
| `hw/misc/trace-events` | trace 事件定义 |

## 5. 运行方法

### 前置条件
- 安装 Docker 并构建 `gem5-run:local` 镜像
- 从 `cosim/qemu/` 编译的 QEMU（包含 mi300x-gem5 设备）
- 磁盘镜像 `x86-ubuntu-rocm70` + 内核 `vmlinux-rocm70`

### 快速启动
```bash
cd cosim/gem5
bash scripts/cosim_launch.sh
# Guest 启动后（以 root 自动登录）：
ln -sf /usr/lib/firmware/amdgpu/mi300_discovery \
       /usr/lib/firmware/amdgpu/ip_discovery.bin
modprobe amdgpu ip_block_mask=0x67 discovery=2
rocm-smi   # 验证 GPU 是否可见
```

### 手动启动（用于调试）
```bash
# 1. 在 Docker 中运行 gem5
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

# 2. 等待 socket 创建完成并修复权限
docker exec gem5-cosim chmod 777 /tmp/gem5-mi300x.sock
docker exec gem5-cosim chmod 666 /dev/shm/mi300x-vram

# 3. 在 screen 中运行 QEMU
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

# 4. 交互操作
screen -S qemu-cosim -X stuff 'modprobe amdgpu ip_block_mask=0x67 discovery=2\n'
```

## 6. 调试技巧

- **gem5 调试标志**：`--debug-flags=MI300XCosim,AMDGPUDevice,PM4PacketProcessor`
- **QEMU trace**：`--qemu-trace 'mi300x_gem5_*'`
- **检查 gem5 日志**：`docker logs gem5-cosim 2>&1 | grep -E "warn|error|GART"`
- **检查 guest dmesg**：`screen -S qemu-cosim -X stuff 'dmesg | tail -20\n'`
- **增量重建**：删除过期的 `.o` 文件，使用 gold 链接器重建：
  ```bash
  docker run --rm -v "$PWD:/gem5" -w /gem5 gem5-run:local \
    sh -c 'rm -f build/VEGA_X86/dev/amdgpu/<file>.o'
  docker run --rm -v "$PWD:/gem5" -w /gem5 \
    -e PYTHONPATH=/usr/lib/python3.12/lib-dynload \
    gem5-run:local scons build/VEGA_X86/gem5.opt -j1 \
    GOLD_LINKER=True --linker=gold
  ```
