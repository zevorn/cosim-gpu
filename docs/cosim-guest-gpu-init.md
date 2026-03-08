# MI300X 协同仿真：客户机 GPU 初始化指南

## 概述

QEMU 启动客户机 Linux 并获取 root shell 后，需要在运行任何 GPU 工作负载之前手动初始化 MI300X GPU。共有 **3 个步骤**，必须以 root 身份**按顺序**执行。

磁盘镜像中已包含所有必需的文件（ROM、固件、内核模块）——只需运行以下命令即可。

## 前置条件

- `cosim_launch.sh` 正在运行（gem5 + QEMU 已连接）
- 客户机已启动并获取了 root shell
- 内核命令行中传递了 `modprobe.blacklist=amdgpu`
  （启动脚本会自动执行此操作）

## 快速参考（可直接复制粘贴）

```bash
# All 3 steps in one go:
dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128
ln -sf /usr/lib/firmware/amdgpu/mi300_discovery /usr/lib/firmware/amdgpu/ip_discovery.bin
bash /home/gem5/load_amdgpu.sh
```

或使用自动化脚本（已在 gem5 仓库中）：

```bash
bash /path/to/gem5/scripts/cosim_guest_setup.sh
```

## 详细步骤

### 步骤 1：加载 VGA BIOS ROM

```bash
dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128
```

**功能说明**：将 MI300X VBIOS ROM 镜像写入物理地址 `0xC0000`（768 KB）处的传统 VGA ROM 区域。

**必要性**：amdgpu 驱动在初始化期间从传统 VGA ROM 空间（`0xC0000–0xDFFFF`，128 KB）读取 VBIOS。QEMU 协同仿真设备注册为 `PCI_CLASS_DISPLAY_VGA`，因此内核将该地址范围识别为 "shadowed ROM"。如果没有 ROM，驱动将报错 `"Unable to locate a BIOS ROM"`。

**参数说明**：
| 参数 | 值 | 含义 |
|-----------|-------|---------|
| `if`      | `/root/roms/mi300.rom` | ROM 二进制文件（在磁盘镜像中） |
| `of`      | `/dev/mem`             | 物理内存设备 |
| `bs`      | `1k`                   | 块大小 = 1024 字节 |
| `seek`    | `768`                  | 跳转至 768 × 1024 = `0xC0000` |
| `count`   | `128`                  | 写入 128 × 1024 = 128 KB |

### 步骤 2：链接 IP Discovery 固件

```bash
ln -sf /usr/lib/firmware/amdgpu/mi300_discovery \
       /usr/lib/firmware/amdgpu/ip_discovery.bin
```

**功能说明**：将驱动的 IP discovery 固件路径指向 MI300X 专用的 discovery 二进制文件。

**必要性**：amdgpu 驱动使用 `discovery=2` 模式，该模式从磁盘上的固件文件读取 GPU IP 块信息，而非从 GPU 自身的 ROM/寄存器读取。gem5 GPU 模型通过其 `ipt_binary` 参数提供此文件（空字符串 = 使用磁盘固件）。驱动查找 `/usr/lib/firmware/amdgpu/ip_discovery.bin`，该文件必须指向 MI300X 专用文件。

**注意**：磁盘镜像中已包含这两个文件；此命令仅创建正确的符号链接。如果 `mi300_discovery` 不存在，驱动将回退到内置默认值（可能与 MI300X 不匹配）。

### 步骤 3：加载 amdgpu 内核模块

```bash
bash /home/gem5/load_amdgpu.sh
```

**功能说明**：通过 `insmod` 手动加载 amdgpu 驱动及其所有依赖项（绕过 `modprobe`）。

**为何不使用 `modprobe`**：QEMU+KVM 环境相比真实系统具有有限的 ACPI 支持。由于某些 ACPI 方法缺失，WMI 子系统初始化在 `modprobe` 期间会失败。解决方法是：

1. 加载提供缺失 ACPI 符号的桩模块 `gem5_wmi.ko`
2. 按顺序手动 `insmod` 每个依赖项
3. 使用特定参数加载 `amdgpu.ko.zst`

**amdgpu 模块参数**：

| 参数 | 值 | 含义 |
|-----------|-------|---------|
| `ip_block_mask` | `0x6f` | 仅启用受支持的 IP 块 |
| `ppfeaturemask` | `0` | 禁用电源管理功能 |
| `dpm` | `0` | 禁用动态电源管理 |
| `audio` | `0` | 禁用音频（HDMI/DP） |
| `ras_enable` | `0` | 禁用 RAS（可靠性）功能 |
| `discovery` | `2` | 使用固件文件进行 IP discovery |

**完整 insmod 序列**（供参考）：

```bash
insmod /home/gem5/gem5_wmi.ko
insmod /lib/modules/$(uname -r)/kernel/drivers/acpi/video.ko.zst
insmod /lib/modules/$(uname -r)/kernel/drivers/i2c/algos/i2c-algo-bit.ko.zst
insmod /lib/modules/$(uname -r)/kernel/drivers/media/rc/rc-core.ko.zst
insmod /lib/modules/$(uname -r)/kernel/drivers/media/cec/core/cec.ko.zst
insmod /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/display/drm_display_helper.ko.zst
insmod /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/drm_suballoc_helper.ko.zst
insmod /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/drm_exec.ko.zst
insmod /lib/modules/$(uname -r)/updates/dkms/amdkcl.ko.zst
insmod /lib/modules/$(uname -r)/updates/dkms/amd-sched.ko.zst
insmod /lib/modules/$(uname -r)/updates/dkms/amdxcp.ko.zst
insmod /lib/modules/$(uname -r)/updates/dkms/amddrm_buddy.ko.zst
insmod /lib/modules/$(uname -r)/updates/dkms/amddrm_exec.ko.zst
insmod /lib/modules/$(uname -r)/updates/dkms/amdttm.ko.zst
insmod /lib/modules/$(uname -r)/updates/dkms/amddrm_ttm_helper.ko.zst
insmod /lib/modules/$(uname -r)/updates/dkms/amdgpu.ko.zst \
    ip_block_mask=0x6f ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

## 验证

完成步骤 3 后，检查驱动是否已加载：

```bash
# Check dmesg for amdgpu initialization
dmesg | grep -i amdgpu | tail -20

# Check PCI device
lspci | grep -i amd

# Check ROCm (if available)
rocm-smi
rocminfo | head -40
```

**预期结果**：`dmesg` 应显示 amdgpu 正在初始化 GPU 且无致命错误。MMIO 流量应出现在 gem5 调试日志中。

## 故障排查

| 症状 | 原因 | 解决方法 |
|---------|-------|-----|
| `Unable to locate a BIOS ROM` | 步骤 1 未执行，或 mi300.rom 缺失 | 运行 dd 命令；检查 `/root/roms/mi300.rom` 是否存在 |
| `insmod: ERROR: could not load module` | 内核版本不匹配 | 使用匹配的内核重建磁盘镜像 |
| MMIO 读取全部返回零 | gem5 未连接或已崩溃 | 检查 `docker logs gem5-cosim` |
| `probe failed with error -12` | BAR 布局不匹配 | 使用正确的 BAR5=MMIO 布局重建 QEMU |
| gem5 因 `schedule()` 断言崩溃 | 定时器事件溢出 | 确保设置了 `disable_rtc_events` 和 `disable_timer_events` |

## 文件位置（客户机磁盘镜像内部）

| 文件 | 路径 | 来源 |
|------|------|--------|
| VGA BIOS ROM | `/root/roms/mi300.rom` | 由 Packer 构建 |
| IP Discovery 固件 | `/usr/lib/firmware/amdgpu/mi300_discovery` | 由 Packer 构建 |
| WMI 桩模块 | `/home/gem5/gem5_wmi.ko` | 由 Packer 构建 |
| 驱动加载脚本 | `/home/gem5/load_amdgpu.sh` | `gem5-resources/src/x86-ubuntu-gpu-ml/files/` |
| amdgpu 模块 | `/lib/modules/$(uname -r)/updates/dkms/amdgpu.ko.zst` | ROCm 7.0 DKMS |
