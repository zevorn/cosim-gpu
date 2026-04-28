[English](../en/cosim-guest-gpu-init.md)

# MI300X 协同仿真：客户机 GPU 初始化指南

## 概述

MI300X GPU 驱动可在 QEMU 客户机启动后**自动**或**手动**加载。磁盘镜像中已包含 systemd 服务（`cosim-gpu-setup.service`），会在开机时自动完成完整的初始化流程。

磁盘镜像中已包含所有必需的文件（ROM、固件、内核模块）。

## 自动加载（默认）

磁盘镜像内置 `cosim-gpu-setup.service`，开机时自动执行：

1. `dd` 写入 VGA ROM 到 `0xC0000`（gem5 通过共享内存的 `readROM()` 需要此数据）
2. 链接 IP discovery 固件
3. `modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2`

服务约 40 秒完成。登录后 GPU 即可使用：

```bash
rocm-smi          # 应显示设备 0x74a0
rocminfo          # 应显示 gfx942
```

服务文件内容：

```ini
# /etc/systemd/system/cosim-gpu-setup.service
[Unit]
Description=MI300X GPU Setup for Co-simulation
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/cosim-gpu-setup.sh

[Install]
WantedBy=multi-user.target
```

> **注意：** 内核命令行必须保留 `modprobe.blacklist=amdgpu`，防止 PCI 子系统在 ROM 写入共享内存之前自动加载驱动。systemd 服务会在 `dd` 之后显式 `modprobe`。

## 手动加载

如果 systemd 服务未安装，在 guest 启动后手动执行以下命令。

### 前置条件

- `cosim_launch.sh` 正在运行（gem5 + QEMU 已连接）
- 客户机已启动并获取了 root shell
- 内核命令行中传递了 `modprobe.blacklist=amdgpu`

### 快速参考（可直接复制粘贴）

```bash
dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128
ln -sf /usr/lib/firmware/amdgpu/mi300_discovery /usr/lib/firmware/amdgpu/ip_discovery.bin
modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
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
modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

**功能说明**：使用协同仿真参数加载 amdgpu 驱动。

**amdgpu 模块参数**：

| 参数 | 值 | 含义 |
|-----------|-------|---------|
| `ip_block_mask` | `0x67` | 禁用 PSP（bit 3）和 SMU（bit 4）；cosim 不模拟这些 IP 块 |
| `ppfeaturemask` | `0` | 禁用 PowerPlay 特性；cosim 无电源管理硬件 |
| `dpm` | `0` | 禁用动态电源管理 |
| `audio` | `0` | 禁用音频；cosim 无 HDMI/DP 音频 |
| `ras_enable` | `0` | 禁用 RAS — 防止 VBIOS 最小化时 `atom_context` 为 NULL 导致的空指针崩溃 |
| `discovery` | `2` | 使用固件文件进行 IP discovery |

> **警告**：使用 `ip_block_mask=0x6f`（仅禁用 SMU）会导致 PSP 固件加载失败和内核 panic。务必使用 `0x67`。

> **警告**：`dd` 步骤（步骤 1）在 `modprobe` 之前**必须**执行。否则驱动的 BIOS 发现链全部失败（ACPI 不可用、SMU 已禁用），导致 `"Unable to locate a BIOS ROM"` 后在 `amdgpu_ras_init` → `amdgpu_atom_parse_data_header` 处发生空指针崩溃。

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
| `Unable to locate a BIOS ROM` + 空指针崩溃 | 步骤 1（dd ROM）未在 modprobe 之前执行 | 先执行 `dd`；检查 `/root/roms/mi300.rom` 是否存在 |
| `insmod: ERROR: could not load module` | 内核版本不匹配 | 使用匹配的内核重建磁盘镜像 |
| `cosim-gpu-setup.service` 失败 | 检查 `journalctl -u cosim-gpu-setup` | 确认磁盘镜像中 ROM 文件和模块存在 |
| MMIO 读取全部返回零 | gem5 未连接或已崩溃 | 检查 `docker logs gem5-cosim` |
| `probe failed with error -12` | BAR 布局不匹配 | 使用正确的 BAR5=MMIO 布局重建 QEMU |
| gem5 因 `schedule()` 断言崩溃 | 定时器事件溢出 | 确保设置了 `disable_rtc_events` 和 `disable_timer_events` |

## 文件位置（客户机磁盘镜像内部）

| 文件 | 路径 | 来源 |
|------|------|--------|
| VGA BIOS ROM | `/root/roms/mi300.rom` | 由 Packer 构建 |
| IP Discovery 固件 | `/usr/lib/firmware/amdgpu/mi300_discovery` | 由 Packer 构建 |
| 自动加载服务 | `/etc/systemd/system/cosim-gpu-setup.service` | 通过 `guestmount` 安装 |
| 自动加载脚本 | `/usr/local/bin/cosim-gpu-setup.sh` | 通过 `guestmount` 安装 |
| amdgpu 模块 | `/lib/modules/$(uname -r)/updates/dkms/amdgpu.ko.zst` | ROCm 7.0 DKMS |
