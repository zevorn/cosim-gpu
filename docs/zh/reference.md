[English](../en/reference.md)

# 协同仿真参考手册

QEMU + gem5 MI300X 协同仿真系统的综合查阅参考。概念性说明请参阅[架构文档](architecture.md)；分步构建和运行指南请参阅[快速入门](getting-started.md)。

---

## 1. 参数参考

### 1.1 cosim_launch.sh / mi300_cosim.py 选项

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--socket-path` | `/tmp/gem5-mi300x.sock` | QEMU <-> gem5 通信套接字（vfio-user 协议） |
| `--shmem-path` | `/mi300x-vram` | GPU VRAM 共享内存名称（/dev/shm 下） |
| `--shmem-host-path` | `/cosim-guest-ram` | Guest RAM 共享内存名称（/dev/shm 下） |
| `--dgpu-mem-size` | `16GiB` | GPU VRAM 大小 |
| `--num-compute-units` | `40` | GPU 计算单元数量 |
| `--mem-size` | `8GiB` | Guest 物理内存大小 |
| `--cosim-backend` | `vfio-user` | cosim 后端类型：`vfio-user`（原版 QEMU 10.0+）或 `legacy`（自定义 QEMU） |
| `--gem5-debug` | （无） | gem5 调试标志，例如 `MI300XCosim`、`AMDGPUDevice,PM4PacketProcessor` |
| `--vram-size` | `32GiB` | 自定义 VRAM 大小（`--dgpu-mem-size` 的别名） |
| `--num-cus` | `80` | 自定义 CU 数量（`--num-compute-units` 的别名） |

### 1.2 amdgpu modprobe 参数

协同仿真模式下所有参数均为必需。完整命令：

```bash
modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

| 参数 | 值 | 用途 |
|------|-----|------|
| `ip_block_mask` | `0x67` | 二进制 `0110_0111`。启用 common、GMC、IH、GFX、SDMA；禁用 PSP（bit 3）和 SMU（bit 4）。详见[第 3 节](#3-ip-block-mask-参考) |
| `ppfeaturemask` | `0` | 禁用所有 PowerPlay 特性；cosim 无电源管理硬件 |
| `dpm` | `0` | 禁用动态电源管理 |
| `audio` | `0` | 禁用 HDMI/DP 音频；cosim 无音频硬件 |
| `ras_enable` | `0` | 禁用 RAS（可靠性、可用性、可维护性）。防止 VBIOS 最小化（cosim ROM 仅 3 KB）时 `atom_context` 为 NULL 导致的空指针崩溃 |
| `discovery` | `2` | 使用磁盘上的固件文件进行 IP discovery，而非从 GPU ROM/寄存器读取 |

> **警告**：使用 `ip_block_mask=0x6f`（启用 bit 3 的 PSP）会导致 PSP 固件加载失败和内核 panic。务必使用 `0x67`。

> **警告**：`ras_enable=0` 为强制参数。缺少时，`amdgpu_ras_init` 会调用 `amdgpu_atom_parse_data_header` 访问 NULL 的 `atom_context`，触发空指针崩溃。

### 1.3 dd 命令参数（VGA ROM）

```bash
dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128
```

| 参数 | 值 | 含义 |
|------|-----|------|
| `if` | `/root/roms/mi300.rom` | ROM 二进制文件（在磁盘镜像中） |
| `of` | `/dev/mem` | 物理内存设备 |
| `bs` | `1k` | 块大小 = 1024 字节 |
| `seek` | `768` | 跳转至 768 x 1024 = `0xC0000`（传统 VGA ROM 区域） |
| `count` | `128` | 写入 128 x 1024 = 128 KB |

`dd` 步骤将 MI300X VBIOS 写入共享内存（`/dev/shm/cosim-guest-ram`）中的物理地址 `0xC0000`--`0xDFFFF`。gem5 的 `AMDGPUDevice::readROM()` 通过 `system->getPhysMem()` 从该地址读取。此步骤在 `modprobe` 之前**必须**执行 -- amdgpu 驱动的五种 BIOS 发现方法在 cosim 模式下全部失败：

| BIOS 发现方法 | 在 cosim 下失败的原因 |
|---------------|----------------------|
| `amdgpu_atrm_get_bios()` | QEMU Q35 无 ACPI ATRM 方法 |
| `amdgpu_acpi_vfct_bios()` | 无 ACPI VFCT 表 |
| `amdgpu_read_bios_from_rom()` | 通过 SMU 寄存器读取，但 SMU 被 `ip_block_mask=0x67` 禁用 |
| `amdgpu_read_platform_bios()` | 无平台提供的 ROM |
| `amdgpu_read_disabled_bios()` | cosim 下不可用 |

### 1.4 内核命令行

内核必须使用以下命令行启动：

```
console=ttyS0,115200 root=/dev/vda1 modprobe.blacklist=amdgpu
```

`modprobe.blacklist=amdgpu` 防止 PCI 子系统在 ROM 写入共享内存之前自动加载驱动。`cosim-gpu-setup.service` 会按正确顺序初始化（dd ROM → modprobe）。

---

## 2. 版本矩阵

| 组件 | 版本 |
|------|------|
| Guest 操作系统 | Ubuntu 24.04.2 LTS |
| Guest 内核 | 6.8.0-79-generic |
| ROCm | 7.0.0 |
| amdgpu DKMS | 匹配 ROCm 7.0 |
| gem5 构建目标 | VEGA_X86 |
| GPU 设备 | MI300X (gfx942, DeviceID 0x74A0) |
| 一致性协议 | GPU_VIPER |
| QEMU | 10.0+（vfio-user 后端）或 cosim 分支（legacy 后端） |

### Docker 镜像

| 镜像 | 用途 |
|------|------|
| `ghcr.io/gem5/gpu-fs:latest` | gem5 运行时容器的基础镜像（amd64） |
| `gem5-run:local` | 从 `scripts/Dockerfile.run` 构建的运行时镜像（添加 Python 3.12 支持） |
| `ghcr.io/gem5/ubuntu-24.04_all-dependencies:v24-0` | gem5 编译用（仅 arm64） |

> 在 amd64 宿主机上，请使用 `ghcr.io/gem5/gpu-fs` 作为编译镜像或原生编译。

### 构建产物

| 产物 | 路径 | 大小 |
|------|------|------|
| gem5 二进制 | `build/VEGA_X86/gem5.opt` | 约 1.1 GB |
| 磁盘镜像 | `../gem5-resources/src/x86-ubuntu-gpu-ml/disk-image/x86-ubuntu-rocm70` | 约 55 GB |
| 内核 | `../gem5-resources/src/x86-ubuntu-gpu-ml/vmlinux-rocm70` | 约 64 MB |
| QEMU 二进制 | `qemu/build/qemu-system-x86_64` | -- |

---

## 3. IP Block Mask 参考

### 检测顺序表

`ip_block_mask` 参数使用的是 **检测顺序索引** 作为位位置，而非 `amd_shared.h` 中的 `amd_ip_block_type` 枚举值。枚举值具有误导性 -- 真正起作用的是 IP discovery 过程中各块出现的顺序。

MI300X 检测顺序（ROCm 7.0 DKMS，来自 dmesg）：

| 索引 | IP Block | mask 中的位 | 在 0x67 中是否启用？ |
|------|----------|-------------|----------------------|
| 0 | `soc15_common` | `0x01` | 是 |
| 1 | `gmc_v9_0` | `0x02` | 是 |
| 2 | `vega20_ih` | `0x04` | 是 |
| 3 | `psp` | `0x08` | **否**（禁用） |
| 4 | `smu` | `0x10` | **否**（禁用） |
| 5 | `gfx_v9_4_3` | `0x20` | 是 |
| 6 | `sdma_v4_4_2` | `0x40` | 是 |
| 7 | `vcn_v4_0_3` | `0x80` | 否（非必需） |
| 8 | `jpeg_v4_0_3` | `0x100` | 否（非必需） |

### 位掩码计算

驱动检查 `(amdgpu_ip_block_mask & (1 << i))`，其中 `i` 是检测顺序索引（`amdgpu_device.c:2807`）。

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

### 常见掩码值

| 掩码 | 二进制 | 启用的 IP 块 | 用途 |
|------|--------|-------------|------|
| `0x67` | `0110_0111` | common、GMC、IH、GFX、SDMA | **cosim（正确值）** |
| `0x6f` | `0110_1111` | common、GMC、IH、PSP、GFX、SDMA | **错误 -- PSP 导致内核 panic** |
| `0xFF` | `1111_1111` | 包含 PSP+SMU 在内的所有块 | 仅限真实硬件 |

---

## 4. 已知问题与陷阱

### 4.1 VGA ROM 空指针崩溃

| | |
|---|---|
| **症状** | `modprobe amdgpu` 导致内核空指针崩溃，位于 `amdgpu_atom_parse_data_header+0x1b`。调用链：`amdgpu_ras_init` -> `amdgpu_atomfirmware_mem_ecc_supported` -> `amdgpu_atom_parse_data_header`。RAX=0（NULL `atom_context`） |
| **根因** | amdgpu 驱动的五种 BIOS 发现方法在 cosim 模式下全部失败（详见[第 1.3 节](#13-dd-命令参数vga-rom)）。驱动打印 `"Unable to locate a BIOS ROM"` 后继续执行，但 RAS 初始化路径无条件调用 `amdgpu_atom_parse_data_header()` 而不检查 NULL `atom_context`。QEMU 的 `romfile=` 属性无效 -- amdgpu 驱动通过 SMU 寄存器访问 ROM，而非 PCI ROM BAR |
| **修复** | 在 `modprobe` **之前**执行 `dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128`。`cosim-gpu-setup.service` 会自动完成此操作 |

### 4.2 PSP / SMU 固件加载失败

| | |
|---|---|
| **症状** | `PSP load tmr failed!`、`hw_init of IP block <psp> failed -22`、`Fatal error during GPU init` |
| **根因** | `ip_block_mask=0x6f` 启用了 PSP（检测顺序索引 3），但 cosim 不模拟 PSP 硬件。`amd_shared.h` 中的 `amd_ip_block_type` 枚举显示 PSP=4，但 mask 使用的是检测顺序，PSP 的索引为 3 |
| **修复** | 使用 `ip_block_mask=0x67` 同时禁用 PSP（bit 3）和 SMU（bit 4）。详见[第 3 节](#3-ip-block-mask-参考) |

### 4.3 SIGIO 合并导致的死锁（仅 Legacy 后端）

| | |
|---|---|
| **症状** | 驱动在首次访问 INDEX2/DATA2 寄存器对时挂起。gem5 处理约 15 条消息后停止响应。QEMU socket 缓冲区被填满 |
| **根因** | Linux FASYNC/SIGIO 是边沿触发的。当 QEMU 快速连续发送一个 write 和一个 read 时，两条消息在 gem5 的 SIGIO handler 触发前同时到达。系统只投递一个信号；handler 读取一条消息后第二条永远滞留 |
| **修复** | `MI300XGem5Cosim::handleClientData()` 使用 `do/while` 排空循环配合 `poll(fd, POLLIN, 0)` 读取每次 SIGIO 到来时的所有待处理消息。不适用于 vfio-user 后端（使用 libvfio-user 的非阻塞 poll） |

### 4.4 协同仿真模式下 GART 表未填充

| | |
|---|---|
| **症状** | 大量 `GART translation for X not found` 警告。PM4 读到全零内存（opcode 0x0）。KIQ ring test 超时 |
| **根因** | 在两种后端中，VRAM 均由共享内存（`/dev/shm/mi300x-vram`）支撑。驱动对 VRAM 的写入完全绕过 gem5 的内存系统，因此 `AMDGPUVM::gartTable` 哈希表不会通过 `AMDGPUDevice::writeFrame()` 被填充 |
| **修复** | `GARTTranslationGen::translate()` 中的协同仿真回退机制：当 `gartTable` 未命中时，直接从共享 VRAM 的 `vramShmemPtr + (gartBase - fbBase) + gart_byte_offset` 处读取 PTE。关键细节：`getGARTAddr()` 已将页索引乘以 8，因此 `bits(vaddr, 63, 12)` 已经是字节偏移 -- 不可再乘以 8 |

### 4.5 GART 未映射页崩溃

| | |
|---|---|
| **症状** | `hipMalloc OK` 后，gem5 段错误并伴随重复的 `GART translation for 0x3fff800000000 not found` 警告。无限 DMA 重试导致内存耗尽 |
| **根因** | GPU PM4/SDMA 引擎尝试 DMA 到驱动尚未映射的 GART 页（PTE=0）。原始代码创建 `GenericPageTableFault`，但 DMA 回调链无限重试同一个失败地址 |
| **修复** | 未映射的 GART 页被映射到 sink（`paddr=0`）。DMA 读操作返回零，写操作被丢弃，仿真保持存活。这是正常现象：`ptStart` 处的第一页本身就是未映射的 |

### 4.6 SDMA Ring 测试超时

| | |
|---|---|
| **症状** | 驱动初始化过程中 SDMA ring 测试返回 `-110`（`-ETIMEDOUT`）。`sdma v4_4_2: ring 0 test failed (-110)` |
| **根因** | `sdma_engine.hh` 中 `sdma_delay` 默认值为 `1e9` ticks。在 cosim 模式下，对应约 500ms 墙钟时间，超过驱动约 200ms 的超时窗口。流程：驱动写入 SDMA ring 并敲 doorbell → gem5 以 `sdma_delay` ticks 延迟调度 SDMA 事件 → 驱动在 gem5 完成前超时 |
| **修复** | 将 `sdma_delay` 从 `1e9` 减小到 `1000` ticks。将 `KEEPALIVE_INTERVAL` 增大到 `1e9` 以避免 keepalive 干扰时序 |

### 4.7 VRAM 地址 GART 翻译错误

| | |
|---|---|
| **症状** | 地址 `0x1f72fa8000` 产生 861,000 多次 GART 翻译错误，内存耗尽，段错误 |
| **根因** | SDMA rptr 回写地址和 PM4 RELEASE_MEM 目标地址可能指向 VRAM（地址 < 16 GiB）。这些地址经过 `getGARTAddr()` 处理时页号会被乘以 8，然后 GART 查找失败，因为 VRAM 没有对应的页表项 |
| **修复** | 三层防护：(1) PM4：`writeData()`、`releaseMem()`、`queryStatus()` 检查 `isVRAMAddress(addr)` 并路由到 `getMemMgr()->writeRequest()`。(2) SDMA：`setGfxRptrLo/Hi()` 和 rptr 回写对 VRAM 地址跳过 `getGARTAddr()`。(3) GART 兜底：检测 VRAM 地址并映射到 sink（`paddr=0`） |

### 4.8 共享内存文件偏移量不匹配

| | |
|---|---|
| **症状** | GART 页表项读出全为零。PM4 opcode 0x0（NOP，count 0）无限重复 |
| **根因** | QEMU Q35 配置 8 GiB RAM 时：`below_4g = 2 GiB`（当 `ram_size >= 0xB0000000` 时硬编码）。gem5 配置为 3 GiB 以下 / 5 GiB 以上。QEMU 将 4G 以上数据放在文件偏移 2 GiB 处；gem5 从偏移 3 GiB 处读取 -- 全为零 |
| **修复** | `mi300_cosim.py` 复刻了 Q35 的拆分逻辑：`below_4g = min(total_mem, 0x80000000 if total_mem >= 0xB0000000 else 0xB0000000)` |

### 4.9 定时器溢出崩溃

| | |
|---|---|
| **症状** | 经过数十亿 tick 后，gem5 因 `curTick()` 整数溢出而崩溃。`schedule()` 断言失败 |
| **根因** | RTC 和 PIT 定时器持续调度事件，在 cosim 的长期运行模式下导致 tick 计数器溢出 |
| **修复** | 为 `Cmos` 添加了 `disable_rtc_events` 参数，为 `I8254` 添加了 `disable_timer_events` 参数。在 `mi300_cosim.py` 中均设为禁用。cosim 桥接中的 keepalive 事件防止事件队列变空 |

### 4.10 PM4ReleaseMem.dataSelect Panic

| | |
|---|---|
| **症状** | gem5 panic，报错 `Unimplemented PM4ReleaseMem.dataSelect` |
| **根因** | `pm4_packet_processor.cc` 仅实现了 `dataSelect == 1`（32 位数据写入）。驱动在 GFX 初始化过程中使用其他模式 |
| **修复** | 添加了所有常见 dataSelect 值：0 = 不写入数据（仅触发事件），1 = 32 位写入（已有），2 = 64 位写入，3 = 64 位 GPU 时钟计数器，其他 = 警告并视为空操作 |

### 4.11 不支持的 PM4 操作码

| | |
|---|---|
| **症状** | gem5 在遇到未识别的 PM4 opcode 时崩溃 |
| **根因** | `ACQUIRE_MEM` (0x58) 和 `SET_RESOURCES` (0xA0) 未被处理 |
| **修复** | 两者均已添加到 `pm4_defines.hh` 并在 `pm4_packet_processor.cc:decodeHeader()` 中作为跳过并继续（NOP）处理 |

### 4.12 PCI Class Code 不匹配

| | |
|---|---|
| **症状** | amdgpu 驱动跳过了 `0xC0000` 处的 legacy VGA ROM 检查 |
| **根因** | PCI class 为 `PCI_CLASS_DISPLAY_OTHER (0x0380)` 而非 `PCI_CLASS_DISPLAY_VGA (0x0300)` |
| **修复** | 改为 `PCI_CLASS_DISPLAY_VGA`。内核随即将该地址范围识别为"带有 shadowed ROM 的视频设备" |

### 4.13 QEMU 串口控制台冲突

| | |
|---|---|
| **症状** | 同时使用 `-serial unix:/tmp/serial.sock -nographic` 时 guest 无串口输出 |
| **根因** | `-nographic` 隐含了 `-serial mon:stdio`，创建映射到 stdio 的 serial0。显式的 `-serial unix:...` 变成 serial1（ttyS1），但内核使用的是 `console=ttyS0` |
| **修复** | 单独使用 `-nographic`。如需程序化访问，在 `screen` 中运行 QEMU |

### 4.14 gem5 链接时内存不足（OOM）

| | |
|---|---|
| **症状** | 即使使用 `-j2`，链接器也被 OOM killer 终止 |
| **根因** | 默认链接器占用内存过多 |
| **修复** | 使用 `scons build/VEGA_X86/gem5.opt -j1 GOLD_LINKER=True --linker=gold` |

### 4.15 DRM Client 错误 -13（缺少 DKMS 模块）

| | |
|---|---|
| **症状** | `Failed to init DRM client: -13` 后内核 panic。`ttm_resource_move_to_lru_tail` 中空指针崩溃 |
| **根因** | 磁盘镜像缺少 `amddrm_exec.ko.zst` DKMS 模块。缺少此模块时 TTM 内存管理器初始化失败，`drm_dev_enter()` 返回 `-EACCES`（-13） |
| **修复** | 使用最新的 `gem5-resources`（`origin/stable` 分支）重新构建磁盘镜像。用 `guestfish` 确认 `amddrm_exec.ko.zst` 存在于 `/lib/modules/6.8.0-79-generic/updates/dkms/` 中 |

### 4.16 驱动 hw_init 失败后 rmmod 导致 oops

| | |
|---|---|
| **症状** | 驱动 `hw_init` 失败后，`rmmod amdgpu` 导致 kernel oops（`kgd2kfd_device_exit` 中的 page fault）。模块停留在 "busy" 状态 |
| **根因** | 部分初始化后清理路径不健壮 |
| **修复** | 无法绕过。需重启整个 cosim 环境（杀掉 QEMU，重启 gem5 Docker 容器，重启 QEMU） |

---

## 5. 调试快速参考

### gem5 调试标志

| 标志组合 | 显示内容 |
|----------|----------|
| `MI300XCosim` | cosim socket/vfio-user 消息 |
| `AMDGPUDevice` | MMIO 寄存器读/写 |
| `PM4PacketProcessor` | PM4 包解码和处理 |
| `SDMAEngine` | SDMA 操作 |
| `AMDGPUDevice,PM4PacketProcessor` | MMIO + PM4（组合） |
| `MI300XCosim,AMDGPUDevice,PM4PacketProcessor` | 完整 cosim 调试 |

用法：

```bash
./scripts/cosim_launch.sh --gem5-debug MI300XCosim
# 或手动：
build/VEGA_X86/gem5.opt --debug-flags=MI300XCosim,AMDGPUDevice ...
```

### QEMU Trace 事件

```bash
./scripts/cosim_launch.sh --qemu-trace 'mi300x_gem5_*'
```

### 日志检查命令

```bash
# gem5 容器日志（stderr）
docker logs gem5-cosim 2>&1 | tee /tmp/gem5.log

# 过滤警告/错误
docker logs gem5-cosim 2>&1 | grep -E "warn|error|GART"

# Guest dmesg（通过 screen）
screen -S qemu-cosim -X stuff 'dmesg | tail -20\n'

# Guest 串口输出（独立仿真）
tail -f m5out/board.pc.com_1.device
```

### Socket 测试

```bash
python3 scripts/cosim_test_client.py /tmp/gem5-mi300x.sock
```

### 增量重建

```bash
# 删除过期的目标文件，然后重建
docker run --rm -v "$PWD:/gem5" -w /gem5 gem5-run:local \
    sh -c 'rm -f build/VEGA_X86/dev/amdgpu/<file>.o'
docker run --rm -v "$PWD:/gem5" -w /gem5 \
    gem5-run:local scons build/VEGA_X86/gem5.opt -j1
```

### 快速诊断表

| 症状 | 首先检查 |
|------|----------|
| gem5 容器启动后立即退出 | `docker logs gem5-cosim` |
| QEMU 连接失败 | gem5 是否就绪？（socket `chmod 777` 了吗？） |
| `psp_gpu_reset` 空指针崩溃 | `ip_block_mask` 错误（应使用 `0x67`） |
| GART translation not found | 是否使用了最新编译的 gem5 二进制？ |
| SDMA ring test -110 | 检查 `sdma_delay` 是否为 `1000` |
| hipcc "cannot find ROCm device library" | `ls /opt/rocm/lib/`，使用 `--offload-arch=gfx942` |
| MMIO 读取全部返回零 | gem5 未连接或已崩溃 |
| `insmod: ERROR: could not load module` | 内核版本不匹配 |
| `cosim-gpu-setup.service` 失败 | `journalctl -u cosim-gpu-setup` |
| BAR 布局 probe 错误 -12 | 使用正确的 BAR5=MMIO 布局重建 QEMU |

---

## 6. GART 表格式与 PTE 布局

GPU 地址空间和转换流程的概念性说明请参阅[架构文档 §5](architecture.md#gpu-地址转换与-gart)。

### GART PTE 格式

每个 GART 页表项为 8 字节：

| 位域 | 字段 | 描述 |
|------|-------|------|
| 0 | Valid | 条目有效 |
| 1 | System | 1 = 系统内存，0 = 本地 VRAM |
| 5:2 | Fragment | 页面片段大小 |
| 47:12 | Physical Page | 物理地址 >> 12 |
| 51:48 | Block Fragment | 块片段大小 |
| 63:52 | Flags | MTYPE、PRT 等 |

**物理地址提取**：`paddr = (bits(PTE, 47, 12) << 12) | page_offset`

### Aperture 寄存器

| 寄存器 | gem5 字段 | 格式 | 描述 |
|--------|-----------|------|------|
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

### 协同仿真中的典型值

```
ptBase   = 0x3EE600000     GART table at VRAM offset ~15.7 GiB
ptStart  = 0x7FFF00000     GART covers GPU VAs from 0x7FFF00000000
ptEnd    = 0x7FFF1FFFF     GART covers ~128K pages (512 MiB)
fbBase   = 0x8000000000    VRAM starts at MC address 512 GiB
fbTop    = 0x8400FFFFFF    VRAM ends at ~528 GiB (16 GiB range)
sysAddrL = 0x0             System aperture start
sysAddrH = 0x3FFEC0000     System aperture end (~4 TiB)
```

### GART 表在 VRAM 中的布局

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

### 协同仿真 PTE 回退查找

在 cosim 模式下，`gartTable` 为空（VRAM 写入绕过 gem5）。回退机制直接从共享 VRAM 读取 PTE：

```cpp
Addr pte_table_offset = gart_addr - (ptStart * 8);
Addr pte_vram_offset = gartBase() + pte_table_offset;
memcpy(&pte, vramShmemPtr + pte_vram_offset, sizeof(pte));
```

若 PTE 为 0（未映射），则映射到 sink（`paddr=0`）而非产生 fault。

---

## 7. 国内镜像配置

在国内构建磁盘镜像时，VM 内的 `apt` 会从 `us.archive.ubuntu.com` 拉包，常因网络波动挂住（Packer 报 `Timeout waiting for SSH`，或 provisioner 在安装 ROCm 时退出）。

### 应用补丁

```bash
cd gem5-resources
git apply ../scripts/patches/0001-user-data-cn-mirror.patch
```

### 回滚补丁

```bash
cd gem5-resources
git apply -R ../scripts/patches/0001-user-data-cn-mirror.patch
```

如需使用其他镜像源，修改 patch 文件中的 URI 后重新 apply。

---

## 8. 文件参考

### gem5 源文件（`src/dev/amdgpu/`）

| 文件 | 用途 |
|------|------|
| `mi300x_vfio_user.{cc,hh}` | vfio-user 服务端 SimObject（**默认后端**） |
| `MI300XVfioUser.py` | SimObject Python 封装（vfio-user） |
| `cosim_bridge.hh` | 抽象 CosimBridge 接口（两种后端均实现此接口） |
| `mi300x_gem5_cosim.{cc,hh}` | Legacy socket 桥接 SimObject |
| `MI300XGem5Cosim.py` | SimObject Python 封装（legacy） |
| `amdgpu_device.cc` | GPU 设备模型核心，`readROM()`、`intrPost()`、`writeFrame()` |
| `amdgpu_vm.{cc,hh}` | 所有转换生成器（GART、AGP、MMHUB、User），cosim VRAM 回退 |
| `pm4_packet_processor.{cc,hh}` | PM4 包解码、DMA 路由、VRAM 写路由、`isVRAMAddress()` |
| `pm4_defines.hh` | PM4 操作码，包括 `IT_ACQUIRE_MEM`、`IT_SET_RESOURCES` |
| `sdma_engine.{cc,hh}` | SDMA 操作、rptr 回写路由、`sdma_delay` 参数 |
| `interrupt_handler.cc` | IH ring buffer DMA 和 MSI-X 中断发送 |
| `amdgpu_nbio.cc` | ASIC 初始化完成寄存器 |

### gem5 配置和脚本

| 文件 | 用途 |
|------|------|
| `configs/example/gpufs/mi300_cosim.py` | cosim 系统配置（`--cosim-backend=vfio-user\|legacy`） |
| `configs/example/gem5_library/x86-mi300x-gpu.py` | 独立 stdlib 仿真配置 |
| `configs/example/gpufs/mi300.py` | Legacy 独立仿真配置 |
| `scripts/cosim_launch.sh` | cosim 编排（Docker + QEMU 启动） |
| `scripts/run_mi300x_fs.sh` | 构建编排（编译、磁盘镜像、运行） |
| `scripts/Dockerfile.run` | 运行时 Docker 镜像定义 |
| `scripts/cosim_test_client.py` | Socket 连通性测试工具 |
| `scripts/patches/0001-user-data-cn-mirror.patch` | 磁盘镜像构建的国内镜像补丁 |

### gem5 修改的基础设施文件

| 文件 | 变更内容 |
|------|----------|
| `src/dev/intel_8254_timer.{cc,hh}` | `disable_timer_events` 参数（cosim 定时器溢出修复） |
| `src/dev/mc146818.{cc,hh}` | `disable_rtc_events` 参数（cosim 定时器溢出修复） |

### gem5 Python 组件

| 文件 | 用途 |
|------|------|
| `src/python/gem5/prebuilt/viper/board.py` | ViperBoard：readfile 注入、驱动加载 |
| `src/python/gem5/components/devices/gpus/amdgpu.py` | MI300X 设备定义 |

### QEMU 文件（仅 Legacy 后端）

| 文件 | 用途 |
|------|------|
| `qemu/hw/misc/mi300x_gem5.c` | 带 socket 桥接的 MI300X PCI 设备 |
| `qemu/hw/misc/mi300x_gem5.h` | 头文件 |
| `qemu/hw/misc/trace-events` | trace 事件定义 |

> vfio-user 后端使用 QEMU 内建的 `vfio-user-pci` 设备，不需要任何自定义 QEMU 代码。

### 外部依赖

| 路径 | 用途 |
|------|------|
| `ext/libvfio-user/` | libvfio-user 库（git 子模块，vfio-user 后端） |

### Guest 磁盘镜像内容

| 文件（Guest 内部） | 用途 |
|--------------------|------|
| `/root/roms/mi300.rom` | VGA BIOS ROM 二进制 |
| `/usr/lib/firmware/amdgpu/mi300_discovery` | IP discovery 固件 |
| `/etc/systemd/system/cosim-gpu-setup.service` | 自动加载服务单元 |
| `/usr/local/bin/cosim-gpu-setup.sh` | 自动加载脚本 |
| `/lib/modules/$(uname -r)/updates/dkms/amdgpu.ko.zst` | amdgpu 内核模块（ROCm 7.0 DKMS） |
| `/home/gem5/load_amdgpu.sh` | 驱动加载脚本（独立仿真） |
| `/sbin/m5` | gem5 伪指令工具 |

### PCI BAR 布局

| BAR | 资源 | 类型 | 大小 |
|-----|------|------|------|
| BAR0+1 | VRAM | 64-bit prefetchable | 16 GiB（共享内存） |
| BAR2+3 | Doorbell | 64-bit | 4 MiB |
| BAR4 | MSI-X | exclusive | -- |
| BAR5 | MMIO 寄存器 | 32-bit | 512 KiB（转发到 gem5） |

驱动常量：`AMDGPU_VRAM_BAR=0`、`AMDGPU_DOORBELL_BAR=2`、`AMDGPU_MMIO_BAR=5`。

### 资源路由（两种后端通用）

| 资源 | 通过 Socket/vfio-user？ | 通过共享内存？ |
|------|------------------------|---------------|
| MMIO 寄存器（BAR5） | 是 | 否 |
| VRAM（BAR0，16 GiB） | **否** | 是（`/dev/shm/mi300x-vram`） |
| Doorbell（BAR2） | 是 | 否 |

任何通过拦截 VRAM 写入来填充的 gem5 数据结构（如 `gartTable`、页表、ring buffer）在 cosim 模式下都**不会**被填充，需要显式的共享 VRAM 回退机制。
