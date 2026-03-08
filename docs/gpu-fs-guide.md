# gem5 MI300X 全系统 GPU 仿真复现指南

从零开始复现 cosim 分支上 AMD Instinct MI300X 的全系统 GPU 仿真流程，
直到 `square` 测试通过。

## 前置条件

| 需求 | 说明 |
|---|---|
| 宿主机系统 | Linux x86_64，支持 KVM（已在 WSL2 6.6.x 上验证） |
| Docker | 守护进程运行中，当前用户在 `docker` 组 |
| KVM | `/dev/kvm` 可访问（磁盘镜像构建和仿真均需要） |
| QEMU | 安装 `qemu-system-x86_64`（用于 Packer 构建磁盘镜像） |
| 磁盘空间 | 至少 120 GB 可用（55G 磁盘镜像 + 构建中间产物） |
| 工具 | `git`、`unzip`、`guestfish`（可选，用于磁盘镜像验证） |

### Docker 镜像

| 镜像 | 用途 |
|---|---|
| `ghcr.io/gem5/gpu-fs:latest` | gem5 运行时容器的基础镜像（amd64） |
| `gem5-run:local` | 从 `scripts/Dockerfile.run` 构建的运行时镜像 |
| `ghcr.io/gem5/ubuntu-24.04_all-dependencies:v24-0` | gem5 编译用（仅 arm64，见下方说明） |

> **注意：** `ghcr.io/gem5/ubuntu-24.04_all-dependencies:v24-0` 仅有 arm64 版本。
> 在 amd64 宿主机上请使用 `ghcr.io/gem5/gpu-fs` 作为编译镜像或原生编译。
> 可通过设置 `GEM5_BUILD_IMAGE` 环境变量来覆盖默认镜像。

## 目录结构

```
/home/zevorn/cosim/
    gem5/                          # gem5 源码（cosim 分支）
        build/VEGA_X86/gem5.opt    # gem5 二进制
        configs/example/
            gem5_library/x86-mi300x-gpu.py   # stdlib 配置
            gpufs/mi300.py                   # legacy 配置
        scripts/
            run_mi300x_fs.sh       # 编排脚本
            Dockerfile.run         # 运行时 Docker 镜像
    gem5-resources/                # 磁盘镜像、内核、GPU 应用
        src/x86-ubuntu-gpu-ml/
            disk-image/x86-ubuntu-rocm70   # 55G raw 磁盘镜像
            vmlinux-rocm70                 # 提取的内核
        src/gpu/square/            # square 测试应用
    docs/                          # 文档
    qemu/                          # QEMU 源码（cosim 设备）
        build/qemu-system-x86_64
```

## 第一步：编译 gem5

```bash
cd /home/zevorn/cosim/gem5
./scripts/run_mi300x_fs.sh build-gem5
```

此命令在 Docker 内执行 `scons build/VEGA_X86/gem5.opt`。
产出：`build/VEGA_X86/gem5.opt`（约 1.1 GB）。

不使用 Docker 的手动编译方式：

```bash
scons build/VEGA_X86/gem5.opt -j$(nproc)
```

## 第二步：编译 QEMU（可选，仅 cosim 模式需要）

```bash
./scripts/run_mi300x_fs.sh build-qemu
```

要求 QEMU 源码位于 `../qemu/`。使用 `--target-list=x86_64-softmmu` 配置并编译。
产出：`../qemu/build/qemu-system-x86_64`。

## 第三步：获取 gem5-resources

```bash
./scripts/run_mi300x_fs.sh build-disk
# 若 gem5-resources 不存在会自动克隆，然后开始构建磁盘镜像
```

或手动克隆：

```bash
cd /home/zevorn/cosim
git clone --depth 1 https://github.com/gem5/gem5-resources.git gem5-resources
```

## 第四步：构建磁盘镜像

磁盘镜像构建使用 Packer + QEMU/KVM，安装 Ubuntu 24.04.2 + ROCm 7.0 +
内核 6.8.0-79-generic 及全部所需的 DKMS 模块。

### 自动构建（通过编排脚本）

```bash
./scripts/run_mi300x_fs.sh build-disk
```

### 手动构建

```bash
cd ../gem5-resources/src/x86-ubuntu-gpu-ml

# 下载 Packer 并构建
./build.sh -var "qemu_path=/usr/sbin/qemu-system-x86_64"
```

> **重要：** `x86-ubuntu-gpu-ml.pkr.hcl` 中默认 `qemu_path` 为
> `/usr/bin/qemu-system-x86_64`。某些发行版（如 Arch）的实际路径是
> `/usr/sbin/qemu-system-x86_64`，需要用 `-var` 覆盖。

### 构建过程详解

1. 通过 QEMU/KVM 启动 Ubuntu 24.04.2 ISO 进行自动安装
2. 运行 `scripts/rocm-install.sh`，依次完成：
   - 从 gem5 源码编译并安装 `m5` 工具（`/sbin/m5`）
   - 从 `repo.radeon.com/amdgpu/7.0/ubuntu` 安装 ROCm 7.0
   - 安装 `amdgpu-dkms`（编译 DKMS 内核模块）
   - 安装内核 `6.8.0-79-generic` 及对应 headers
   - 提取 `vmlinux` 内核供 gem5 使用
   - 编译 `gem5_wmi.ko`（ACPI 补丁模块）
   - 安装 PyTorch（ROCm 6.0 支持）
3. 复制 GPU BIOS ROM（`mi300.rom`）、IP discovery 文件和启动脚本到镜像中
4. 从 VM 中下载提取的内核为 `vmlinux-rocm70`

### 产出

| 产物 | 路径 | 大小 |
|---|---|---|
| 磁盘镜像 | `disk-image/x86-ubuntu-rocm70` | 约 55 GB |
| 内核 | `vmlinux-rocm70` | 约 64 MB |

### 构建耗时

大约 30-60 分钟，取决于网络速度和宿主机性能。

### 验证磁盘镜像（可选）

使用 `guestfish` 在不挂载的情况下检查磁盘镜像内容：

```bash
LIBGUESTFS_BACKEND=direct guestfish --ro \
    -a disk-image/x86-ubuntu-rocm70 -m /dev/sda1 <<'EOF'
echo "=== DKMS 模块 ==="
ls /lib/modules/6.8.0-79-generic/updates/dkms/
echo "=== ROCm 版本 ==="
cat /opt/rocm/.info/version
echo "=== load_amdgpu.sh ==="
cat /home/gem5/load_amdgpu.sh
echo "=== m5 二进制 ==="
is-file /sbin/m5
echo "=== gem5_wmi 模块 ==="
is-file /home/gem5/gem5_wmi.ko
EOF
```

预期的 DKMS 模块列表（amdgpu 驱动的全部依赖）：

```
amd-sched.ko.zst
amddrm_buddy.ko.zst
amddrm_exec.ko.zst        # 关键模块——旧版构建中缺失
amddrm_ttm_helper.ko.zst
amdgpu.ko.zst
amdkcl.ko.zst
amdttm.ko.zst
amdxcp.ko.zst
```

## 第五步：编译 GPU 测试应用

```bash
./scripts/run_mi300x_fs.sh build-app square
```

使用 Docker（`ghcr.io/gem5/gpu-fs`）或本地 `hipcc` 编译。
产出：`../gem5-resources/src/gpu/square/bin.default/square.default`。

## 第六步：构建运行时 Docker 镜像

gem5 二进制链接了 Ubuntu 24.04 的库，需要兼容的运行时环境：

```bash
cd scripts
docker build -t gem5-run:local -f Dockerfile.run .
```

## 第七步：运行仿真

### stdlib 配置（推荐）

```bash
./scripts/run_mi300x_fs.sh run \
    ../gem5-resources/src/gpu/square/bin.default/square.default
```

> **重要：必须指定 `--app` 参数。** 不指定时，`readfile_contents` 为空字符串
> `""`，Python 将其判为 falsy，`KernelDiskWorkload._set_readfile_contents` 不会
> 被调用，guest 中的 amdgpu 驱动永远不会被加载。

### legacy 配置

```bash
./scripts/run_mi300x_fs.sh run-legacy \
    ../gem5-resources/src/gpu/square/bin.default/square.default
```

### 仿真过程详解

1. **KVM 快速启动阶段**（约 2-5 分钟）：gem5 使用 KVM 快进 Linux 启动过程。
   Guest 内核引导、systemd 初始化、自动以 root 登录。
2. **readfile 执行**：Guest 通过 `.bashrc` 运行 `/home/gem5/run_gem5_app.sh`，
   调用 `m5 readfile` 获取宿主机注入的脚本。
3. **驱动加载**：脚本将 GPU BIOS ROM 写入 `/dev/mem`，创建 IP discovery 文件
   的符号链接，然后运行 `load_amdgpu.sh` 按依赖顺序 insmod 所有 DKMS 模块。
4. **GPU 应用执行**：脚本解码 base64 编码的 GPU 二进制，运行它，
   然后调用 `m5 exit` 结束仿真。

### 监控输出

Guest 串口控制台输出写入 `m5out/board.pc.com_1.device`：

```bash
tail -f m5out/board.pc.com_1.device
```

### square 测试预期输出

```
3+0 records in
3+0 records out
3072 bytes (3.1 kB, 3.0 KiB) copied, ...
info: running on device AMD Instinct MI300X
info: allocate host and device mem (  7.63 MB)
info: launch 'vector_square' kernel
info: check result
PASSED!
```

## 故障排查

### `Failed to init DRM client: -13` 后内核 panic

**根因：** 磁盘镜像缺少 `amddrm_exec.ko.zst` DKMS 模块。缺少此模块时，
amdgpu TTM 内存管理器初始化失败，`drm_dev_enter()` 发现设备处于 "unplugged"
状态，返回 `-EACCES`（-13）。后续清理路径在
`ttm_resource_move_to_lru_tail` 触发 NULL 指针解引用。

**修复：** 使用最新的 `gem5-resources`（`origin/stable` 分支）重新构建磁盘镜像。
更新后的 `rocm-install.sh` 安装了内核 `6.8.0-79-generic`，与 ROCm 7.0 DKMS
包完全匹配，包含所有所需模块。

**验证：** 用 `guestfish` 确认 `amddrm_exec.ko.zst` 存在于
`/lib/modules/6.8.0-79-generic/updates/dkms/` 中。

### `Can't open /dev/gem5_bridge: No such file or directory`

**无害警告。** `m5` 工具优先尝试 `gem5_bridge` 设备驱动，失败后回退到
地址映射 MMIO 模式（以 root 运行时可用）。readfile 机制仍然正常工作。

### Packer 构建失败：`output_directory already exists`

上一次构建遗留的 `disk-image/` 目录会阻塞 Packer：

```bash
mv disk-image disk-image-old
# 然后重新运行构建
```

### Packer 构建失败：VM 内 git clone 失败

QEMU VM 内部的网络问题可能导致 `git clone` 失败。`rocm-install.sh` 脚本已内置
重试逻辑（3 次尝试，间隔 10 秒）。若仍然失败，检查宿主机网络连接和 DNS 解析。

### 不指定 `--app` 时 GPU 驱动不加载

使用 `x86-mi300x-gpu.py` 不带 `--app` 参数运行时，`readfile_contents` 为空字符串
`""`。Python 的真值检查 `elif readfile_contents:` 求值为 `False`，因此
`_set_readfile_contents` 不会被调用，不会写入 readfile 文件。Guest 中的
`run_gem5_app.sh` 从 `m5 readfile` 获得空文件后直接退出。

**解决方式：** 运行 GPU 仿真时始终指定 `--app` 参数。

### DRAM 容量警告

```
DRAM device capacity (16384 Mbytes) does not match the address range assigned (8192 Mbytes)
```

这是 gem5 内存系统的配置警告，不影响仿真正确性。

## 关键文件参考

| 文件 | 用途 |
|---|---|
| `scripts/run_mi300x_fs.sh` | 主编排脚本 |
| `scripts/Dockerfile.run` | 运行时 Docker 镜像定义 |
| `configs/example/gem5_library/x86-mi300x-gpu.py` | stdlib 仿真配置 |
| `configs/example/gpufs/mi300.py` | legacy 仿真配置 |
| `src/python/gem5/prebuilt/viper/board.py` | ViperBoard：readfile 注入、驱动加载 |
| `src/python/gem5/components/devices/gpus/amdgpu.py` | MI300X 设备定义 |
| `src/dev/amdgpu/amdgpu_device.cc` | GPU 设备模型核心（cosim 分支修改） |
| `../gem5-resources/src/x86-ubuntu-gpu-ml/scripts/rocm-install.sh` | 磁盘镜像配置脚本 |
| `../gem5-resources/src/x86-ubuntu-gpu-ml/files/load_amdgpu.sh` | Guest 侧驱动加载脚本 |
| `../gem5-resources/src/x86-ubuntu-gpu-ml/x86-ubuntu-gpu-ml.pkr.hcl` | Packer 配置 |

## 版本矩阵

| 组件 | 版本 |
|---|---|
| Guest 操作系统 | Ubuntu 24.04.2 LTS |
| Guest 内核 | 6.8.0-79-generic |
| ROCm | 7.0.0 |
| amdgpu DKMS | 匹配 ROCm 7.0 |
| gem5 构建目标 | VEGA_X86 |
| GPU 设备 | MI300X（DeviceID 0x74A1） |
| 一致性协议 | GPU_VIPER |
