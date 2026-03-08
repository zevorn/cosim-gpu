[English](../en/cosim-dev-story.md)

# 一天、两个子模块、十五个 Bug：我用 Claude 把十万块的 MI300X GPU 搬进了 QEMU

> AMD Instinct MI300X，304 个计算单元，192GB HBM3 显存，单卡零售价超过 10 万人民币。
> 现在，你只需要一台普通的 x86 Linux 机器，就能在 QEMU 上跑起完整的 ROCm/HIP 工作负载。

## 引子

我做 GPU 模拟器已经有一段时间了。gem5 有 MI300X 的设备模型，也有全系统仿真的能力，但它的 KVM 快进模式仍然很慢——一次 Linux 启动要等 5 分钟，驱动加载再等 5 分钟，每次调试一个 MMIO 寄存器的问题都意味着 10 分钟的空白等待。

我一直想做一件事：让 QEMU 跑 Linux 和 amdgpu 驱动，gem5 只负责 GPU 计算模型，中间用某种 IPC 桥接起来。这样 QEMU 用 KVM 跑 CPU 部分，速度接近原生；gem5 只处理 GPU 的 MMIO/Doorbell/DMA，可以专注在计算仿真的精度上。

这个想法听起来不复杂，但实际做起来涉及到 QEMU PCIe 设备模型、gem5 SimObject 架构、Linux amdgpu 驱动的初始化流程、GART 地址翻译、共享内存文件偏移量对齐、Unix 域套接字的边沿触发语义——这些东西的交叉点上全是坑。

2026 年 3 月 6 日早上，我打开了 Claude Code，开始了这个项目。到 3 月 8 日凌晨，第一个 HIP 向量加法测试在联合仿真环境下跑出了 `PASSED!`。

这篇文章记录了整个过程中踩过的坑和关键决策。

---

## 架构：一句话版本

```
QEMU (Q35+KVM, guest Linux + amdgpu driver)
    <-- Unix socket -->
gem5 (MI300X GPU model, no kernel)
    <-- shared memory -->
/dev/shm/cosim-guest-ram + /dev/shm/mi300x-vram
```

QEMU 这边是一个完整的 Q35 虚拟机，跑 Ubuntu 24.04 + ROCm 7.0 + amdgpu 驱动。我在 QEMU 里加了一个 `mi300x-gem5` PCIe 设备，它通过 Unix 域套接字把所有 MMIO 读写和 Doorbell 写操作转发给 gem5。

gem5 这边跑的是 MI300X 的 GPU 设备模型——Shader、CU 阵列、PM4 命令处理器、SDMA 引擎、Ruby 缓存层次结构——但**没有 Linux 内核**。它用 `StubWorkload` 空壳启动，只等 QEMU 通过 socket 发来 MMIO 请求。

Guest 物理内存和 GPU VRAM 各有一块共享内存文件（`/dev/shm/`），QEMU 和 gem5 都能直接 mmap，实现零拷贝 DMA。

BAR 布局必须严格匹配 amdgpu 驱动的硬编码预期：

| BAR | 内容 | 大小 | 通信方式 |
|-----|------|------|----------|
| BAR0+1 | VRAM | 16 GiB | 共享内存 |
| BAR2+3 | Doorbell | 4 MiB | Socket 转发 |
| BAR4 | MSI-X | 256 vectors | QEMU 本地 |
| BAR5 | MMIO 寄存器 | 512 KiB | Socket 转发 |

---

## 第一个小时：从零开始写 PCIe 设备

6 号早上 6 点半，我让 Claude 帮我写了 QEMU 侧的 `mi300x_gem5.c`。这是一个标准的 QEMU PCIe 设备，但有几个特殊的地方：

1. **六个 BAR**，其中三个需要 64 位地址空间（VRAM 16GB 不可能放在 4G 以下）
2. **两条 socket 连接**：一条同步（MMIO 请求/响应），一条异步（中断和 DMA 事件）
3. **MSI-X 支持**：256 个中断向量，gem5 通过 event socket 通知 QEMU 触发 `msix_notify()`

gem5 侧的 `MI300XGem5Cosim` SimObject 稍微复杂一点——它是一个 socket 服务器，监听来自 QEMU 的连接，接收 MMIO 消息后分发给 `AMDGPUDevice` 处理，再把结果发回去。

第一版代码大约 1500 行（QEMU 700 行 + gem5 800 行），结构清晰但全是 bug。

---

## Bug #1：SIGIO 边沿触发死锁——最阴险的问题

gem5 的事件系统使用 `FASYNC`/`SIGIO` 来监听 socket 上的数据。这是**边沿触发**的——当 socket 缓冲区从空变非空时，内核发一次 `SIGIO`，仅此一次。

问题出在 amdgpu 驱动的寄存器访问模式上。驱动经常先写 INDEX 寄存器（选择要访问哪个内部寄存器），然后立即读 DATA 寄存器（拿到值）。write 是 fire-and-forget 的，read 是阻塞等待响应的。当这两条消息背靠背到达 gem5 的 socket 缓冲区时，只会触发一次 SIGIO。

我最初的 `handleClientData()` 每次只读一条消息。结果：gem5 读了 write 消息，处理完毕，然后就傻等下一次 SIGIO。但 read 消息已经在缓冲区里了，不会再有新的 SIGIO 来唤醒它。QEMU 那边死等 read 响应。**完美死锁。**

gem5 处理了 15 条消息后就永远挂住了。

修复方法很简单——把单次读取改成排空循环：

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

修完这个之后，MMIO 消息数从 15 跳到了 **35,181**。驱动初始化一路推进到了 PSP 固件加载阶段。

**教训：任何基于 FASYNC 的 I/O handler 都必须排空所有待处理数据。这在 PCIe 间接寄存器访问的场景下是必然的。**

---

## Bug #2：ip_block_mask——文档骗人

amdgpu 驱动有一个 `ip_block_mask` 参数，用来控制哪些 IP 块需要初始化。cosim 模式下不需要 PSP（安全处理器）和 SMU（电源管理），需要禁用它们。

我最初用的是 `0x6f`，觉得禁用了 PSP（枚举值 4）和保留了其他。结果 PSP 还是被初始化了，加载固件时报 `-EINVAL` 然后整个 GPU init 失败。

花了好一阵子才搞明白：`ip_block_mask` 的位对应的是 **IP discovery 的检测顺序索引**，不是 `amd_ip_block_type` 枚举值。MI300X 的检测顺序是：

```
0: soc15_common   1: gmc_v9_0    2: vega20_ih
3: psp            4: smu         5: gfx_v9_4_3
6: sdma_v4_4_2    7: vcn_v4_0_3  8: jpeg_v4_0_3
```

PSP 在枚举值里是 4，但在检测顺序里是 3。`0x6f` = `0110_1111` 禁用的是索引 4（smu），但索引 3（psp）还是被启用了。正确的值是 `0x67` = `0110_0111`，同时禁用索引 3 和 4。

**教训：amd_shared.h 的枚举值和驱动实际使用的位掩码之间没有对应关系。只有 dmesg 的检测日志才是真相。**

---

## Bug #3：共享内存偏移量——两个系统的内存观不一致

这个 bug 最诡异。GART 页表项读出来全是零，PM4 命令处理器一直读到 opcode 0x0（NOP），无限循环。

问题出在 QEMU Q35 和 gem5 对内存拆分方式的不同。配置 8GB RAM 时：

- **QEMU Q35** 硬编码 `below_4g = 2 GiB`（当 `ram_size >= 0xB0000000`），上方 6GB 放在文件偏移 2G 处
- **gem5** 默认 `below_4g = 3 GiB`，上方 5GB 放在文件偏移 3G 处

两边 mmap 同一个共享内存文件，但对"第 4G 以上的内存在文件的哪个偏移"意见不一致。gem5 从偏移 3G 处读 GART 页表——那里全是零，因为 QEMU 把数据写在了偏移 2G 处。

修复：在 `mi300_cosim.py` 里完全复制 Q35 的拆分逻辑。

**教训：共享 memory-backend-file 时，双方必须在每个范围的文件偏移量上达成一致，不仅仅是总大小。**

---

## Bug #4：VRAM 地址被错误地走了 GART 翻译

PM4 的 `RELEASE_MEM` 和 SDMA 的 rptr 回写，目标地址有时候指向 VRAM（地址 < 16GiB）。原来的代码把所有地址都扔进 `getGARTAddr()` 做翻译，但 VRAM 地址在 GART 里没有对应的页表项，翻译失败 861,000 多次，最后内存耗尽段错误。

修复用了三层防护：

1. **PM4 层**：`writeData()` / `releaseMem()` 检查 `isVRAMAddress(addr)`，VRAM 写直接走设备内存
2. **SDMA 层**：rptr 回写对 VRAM 地址跳过 `getGARTAddr()`
3. **GART 兜底**：未映射的 GART 页映射到 `paddr=0`（sink），不产生 fault

---

## 那一刻：HIP 向量加法 PASSED

3 月 8 日凌晨，所有 bug 修完，驱动加载正常，`rocm-smi` 看到了 MI300X (0x74a0)，`rocminfo` 报告 gfx942 架构、320 个 CU。

在 Guest 里写了一个最简单的 HIP 测试——四个元素的向量加法：

```cpp
__global__ void add(int *a, int *b, int *c, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}
```

编译，运行：

```
Result: 11 22 33 44
PASSED!
```

`{1+10, 2+20, 3+30, 4+40}` = `{11, 22, 33, 44}`。hipMalloc、hipMemcpy（host-to-device / device-to-host）、kernel dispatch、hipDeviceSynchronize 全部正常返回。MSI-X 中断从 gem5 通过 event socket 转发给 QEMU，QEMU 触发 `msix_notify()`，guest 的 IH handler 正确处理——整个中断链路首次端到端跑通。

这是 gem5 第一次作为"远程 GPU"被 QEMU guest 里的真实 amdgpu 驱动驱动起来做计算。

---

## 和 Claude 的协作方式

整个开发过程在一个巨型对话里完成，上下文用完了就续上。工作流是这样的：

1. **我提供原始的终端输出**：dmesg 日志、gem5 panic 信息、socket 通信的 hexdump
2. **Claude 分析输出**，搜索 gem5/QEMU/Linux 内核源码定位根因
3. **Claude 提出并实现修复**——直接编辑 gem5 C++ 代码、QEMU C 代码、Python 配置、Shell 脚本
4. **后台构建**：gem5 编译约 30 分钟，QEMU 约 5 分钟，磁盘镜像约 40 分钟——这些都在后台跑
5. **我测试，贴新的输出**，循环继续

Claude 在这个项目里的角色不是"帮我写代码的工具"，而更像一个**对 gem5 和 QEMU 内部机制有深入了解的协作者**。几个典型场景：

- **SIGIO 死锁**：我只贴了"gem5 处理 15 条消息后挂住"，Claude 立刻定位到 FASYNC 的边沿触发语义，给出了排空循环的方案
- **ip_block_mask**：我贴了 dmesg 的 IP discovery 日志，Claude 直接对照出了检测顺序和位掩码的不匹配
- **GART 翻译**：Claude 从 gem5 源码中追踪了 `getGARTAddr()` 的乘 8 变换，发现了 VRAM 地址被误导入 GART 路径的问题
- **Q35 内存拆分**：Claude 翻出了 `qemu/hw/i386/pc_q35.c:161` 的硬编码 2GiB 边界，和 gem5 的 3GiB 默认值做对比

整个过程中，15 个 blocking bug 被逐一解决。每个 bug 的修复都建立在对底层系统行为的准确理解上——不是试错，而是溯源。

---

## 一天的成果

| 指标 | 数据 |
|------|------|
| 开发耗时 | ~24 小时（3月6日 06:30 → 3月8日 06:00） |
| 新增代码 | ~2500 行（gem5 C++ ~800，QEMU C ~700，Python 配置 ~200，Shell 脚本 ~800） |
| 解决的 blocking bug | 15 个 |
| 技术文档 | 6 篇（中英双语，共 ~2000 行） |
| Git 提交 | 16 笔（cosim 主仓库） |
| MMIO 操作 | 65,000+ 次无崩溃 |
| HIP 计算测试 | PASSED |

最终的系统支持：

- **完整 amdgpu 驱动加载**：DRM 初始化，7 个 XCP 分区，gfx942 架构
- **ROCm 工具链**：rocm-smi、rocminfo 正常工作
- **HIP GPU 计算**：hipMalloc、kernel dispatch、hipDeviceSynchronize
- **MSI-X 中断转发**：gem5 → QEMU 事件通知
- **共享内存 DMA**：零拷贝 VRAM + Guest RAM
- **一键启动**：`./scripts/cosim_launch.sh`

---

## 这意味着什么

MI300X 是 AMD 最强的数据中心 GPU，单卡价格超过 10 万人民币，普通开发者根本摸不到。但通过 QEMU + gem5 联合仿真，你可以在任何一台 x86 Linux 机器上：

- 跑完整的 ROCm 7.0 软件栈
- 编译和运行 HIP 程序
- 在 cycle-accurate 的 GPU 模型上做性能分析
- 调试 amdgpu 驱动的初始化流程
- 开发和验证 GPU 架构的新特性

所有代码已开源：[github.com/zevorn/cosim-gpu](https://github.com/zevorn/cosim-gpu)

```bash
git clone --recurse-submodules git@github.com:zevorn/cosim-gpu.git
cd cosim-gpu
GEM5_BUILD_IMAGE=ghcr.io/gem5/gpu-fs:latest ./scripts/run_mi300x_fs.sh build-all
cd scripts && docker build -t gem5-run:local -f Dockerfile.run . && cd ..
./scripts/cosim_launch.sh
```

---

## 后记

有人可能会说："一天写完的代码能靠谱吗？"

说实话，如果没有 Claude，这个项目至少需要两周。不是因为代码量大——2500 行代码对于一个 PCIe 设备桥接来说并不多——而是因为调试过程中需要同时理解三个系统的内部行为：QEMU 的 Q35 内存布局、gem5 的事件驱动 I/O 模型、Linux amdgpu 驱动的 IP block 初始化顺序。任何一个环节理解错了，就是几小时的调试黑洞。

Claude 的价值不在于帮我写代码，而在于**大幅缩短了从"看到症状"到"理解根因"的时间**。当我贴上一段 dmesg 输出，Claude 能在几秒钟内关联到 gem5 源码中的具体函数和 QEMU 的硬编码常量——这种跨代码库的关联分析，是人工翻源码做不到的速度。

当然，Claude 也不是万能的。所有的测试都是我跑的，所有的架构决策都是我做的（比如选择两条 socket 连接而不是一条，选择 StubWorkload 而不是全系统启动），所有的最终验证都需要在真实环境里确认。AI 是放大器，不是替代品。

但这个放大器确实很强。一天，一个人，一个 AI，十万块的 GPU 搬进了 QEMU。

---

*泽文，2026 年 3 月*
