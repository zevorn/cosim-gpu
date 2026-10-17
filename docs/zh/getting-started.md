[English](../en/getting-started.md)

# 快速入门

QEMU + gem5 MI300X 联合仿真项目的快速入门指南。
从编译各组件到运行第一个 HIP GPU 计算测试。

## 架构概述

```
+-----------------------------+       +----------------------------+
|  QEMU  (Q35 + KVM)          |       |  gem5  (Docker)            |
|  +-----------------------+  |       |  +----------------------+  |
|  | Guest Linux           |  |       |  | MI300X GPU Model     |  |
|  | amdgpu driver         |  |       |  |  Shader / CU / SDMA  |  |
|  | ROCm 7.0 / HIP        |  |       |  |  PM4 / Ruby caches   |  |
|  +----------+------------+  |       |  +---------+------------+  |
|  +----------v------------+  |       |  +---------v------------+  |
|  | vfio-user-pci         |<-------->|  | MI300XVfioUser       |  |
|  | (QEMU built-in)       |  |vfio-  |  | (libvfio-user)       |  |
|  +-----------------------+  |user   |  +----------------------+  |
+-----------------------------+       +----------------------------+
        |                                       |
        v                                       v
  /dev/shm/cosim-guest-ram            /dev/shm/mi300x-vram
  (shared guest RAM)                  (shared GPU VRAM)
```

- **QEMU** 负责：CPU 执行、Linux 内核引导、PCIe 枚举、amdgpu 驱动加载
- **gem5** 负责：MI300X GPU 计算模型（Shader、CU、缓存、DMA 引擎）
- 两者通过 **vfio-user 协议**（基于 Unix 域套接字）通信。QEMU 使用内置的 `vfio-user-pci` 设备，gem5 端运行 `MI300XVfioUser` 作为 vfio-user 服务端
- Guest 物理内存和 GPU VRAM 通过 `/dev/shm/` 下的**共享内存**共享

关于内存架构和 BAR 布局的详细说明，请参阅[架构文档](architecture.md#共享内存)。

## 前置条件

| 需求 | 说明 |
|---|---|
| 宿主机系统 | Linux x86_64，支持 KVM（已在 WSL2 6.6.x 验证） |
| Docker | 守护进程运行中，当前用户在 `docker` 组 |
| KVM | `/dev/kvm` 可访问 |
| QEMU | 由 `qemu` 子模块编译（`just build-qemu`），或使用系统安装且提供 `vfio-user-pci` 的 QEMU 10.1+ |
| 磁盘空间 | 至少 120 GB（55G 磁盘镜像 + 构建中间产物） |
| 内存 | 建议 16 GB 以上（gem5 编译和运行都比较占内存） |
| 工具 | `git`、`screen`、`unzip`、[`just`](https://github.com/casey/just) 1.27+ |

构建、启动和检查任务都定义在仓库根目录的 `justfile` 中。在仓库根目录运行 `just` 可以列出全部任务。

## 编译 gem5 与 QEMU

### 选择构建环境

在 Linux 上，QEMU、gem5 和 m5 的构建 recipe 默认在主机上运行，此时主机需要安装
`scripts/Dockerfile.dev` 中列出的 gem5 和 QEMU 编译依赖，包括 `scons`。设置
`COSIM_ENV=container` 后，这些 recipe 改为在临时开发容器中运行；其他系统默认使用
开发容器。先构建一次镜像：

```bash
just dev-image
export COSIM_ENV=container    # 未安装编译依赖的 Linux 主机
```

`scripts/Dockerfile.dev` 基于 Ubuntu 24.04，包含 gem5 和 QEMU 的编译依赖、Rust、QEMU
和 `qemu-img`。`scripts/dev.sh` 按主机上的路径挂载源码树，每条命令结束后删除容器。

### 编译 gem5

gem5 二进制链接了 Ubuntu 24.04 的库，需要在兼容环境中编译。

> **注意：** vfio-user 后端依赖 `libjson-c-dev`（编译时）和 `libjson-c5`（运行时）。`cosim-dev:local` 镜像已包含此依赖，无需额外安装。

```bash
just build-gem5        # 使用宿主机全部 CPU
just build-gem5 2      # 限制并行度，例如链接阶段内存不足时
```

产出：`build/gem5/<native>/VEGA_X86/gem5.opt`，其中 `<native>` 为
`aarch64` 或 `x86_64`。两种构建均通过 `build_opts/VEGA_X86` 选择模拟的
X86、VEGA 模型及 GPU_VIPER 配置。

### 编译 QEMU

`qemu` 子模块跟踪 [gevico/qemu](https://github.com/gevico/qemu) 的 `gevico/cosim-gpu` 分支，该分支基于 QEMU v11.1.2 发布版本。联合仿真使用其中内置的 `vfio-user-pci` 设备。

```bash
just build-qemu        # 使用宿主机全部 CPU；`just build-qemu 4` 限制并行任务数
```

该任务在 `build/qemu` 中为主机架构配置启用 KVM 和 vfio-user server 的 softmmu 目标，完成编译，并检查程序是否提供 `vfio-user-pci` 和 `x-vfio-user-server`。不使用开发容器的 Linux 主机需要安装 QEMU 的编译依赖（`ninja`、`pkg-config`、`glib-2.0`、`pixman`、`slirp`、`json-c`、`cmocka`，以及带 `venv` 的 Python 3）。

`just run-launch` 和 `just build-disk` 按以下顺序选择 QEMU：

1. `--qemu-bin PATH`（启动时）或环境变量 `QEMU_BIN`
2. 子模块编译出的 `build/qemu/qemu-system-x86_64`
3. `PATH` 中的 `qemu-system-x86_64`（原版 QEMU 10.1+ 同样可用）

## 构建磁盘镜像

当前镜像配方构建 Ubuntu 24.04、ROCm 7.0、amdgpu DKMS 模块及与模块匹配的内核。

### 自动构建

```bash
just build-m5 x86      # 推荐：避免在 Guest 虚拟机内 git clone
just build-disk
just test-rocm-assets
```

镜像配方和 Ansible 任务放在 `resources/images/`。构建过程使用保留在
`third_party/gem5-resources/` 中的固件、WMI 源码和 GPU 支持文件。

### 自定义镜像构建

```bash
scripts/cosim-image list
scripts/cosim-image validate guest/ubuntu/24.04/x86_64/rocm7_0
```

添加新的 profile 目录即可选择其他操作系统镜像或软件包组合。

### 产出

| 产物 | 路径 | 大小 |
|---|---|---|
| 磁盘镜像 | `build/images/guest/ubuntu/24.04/x86_64/rocm7_0/disk` | 虚拟容量 56 GB |
| 内核 | `build/images/guest/ubuntu/24.04/x86_64/rocm7_0/kernel` | 配方产物 |

使用 `cosim run --dry-run` 可以检查 payload、镜像缓存状态和解析后的启动命令，
整个过程不会构建镜像，也不会启动模拟器。

## 启动联合仿真

### 方式一：一键启动（推荐）

```bash
just run-launch
```

该任务运行 `scripts/cosim_launch.sh`，自动完成以下所有步骤（启动 gem5 容器、等待就绪、修复权限、启动 QEMU），并以交互模式进入 QEMU 串口控制台。

可用参数（传给 `scripts/cosim_launch.sh`）：

```bash
just run-launch --gem5-debug MI300XCosim   # 开启 gem5 调试输出
just run-launch --vram-size 32GiB          # 自定义 VRAM 大小
just run-launch --num-cus 80               # 自定义 CU 数量
```

相关任务：`just run-preflight` 列出残留的联合仿真资源，`just run-clean-orphans` 删除这些资源。

### 方式二：手动分步启动

#### 启动 gem5（Docker 容器）

```bash
docker run -d --name gem5-cosim \
    -v /path/to/cosim-gpu/third_party/gem5:/gem5 \
    -v /path/to/cosim-gpu/build:/build \
    -v /tmp:/tmp \
    -v /dev/shm:/dev/shm \
    -w /gem5 \
    -e PYTHONPATH=/usr/lib/python3.12/lib-dynload \
    cosim-dev:local \
    /build/gem5/x86_64/VEGA_X86/gem5.opt --listener-mode=on \
    /gem5/configs/example/gpufs/mi300_cosim.py \
    --socket-path=/tmp/gem5-mi300x.sock \
    --shmem-path=/mi300x-vram \
    --shmem-host-path=/cosim-guest-ram \
    --dgpu-mem-size=16GiB \
    --num-compute-units=40 \
    --mem-size=8G
```

#### 等待 gem5 就绪

```bash
docker logs -f gem5-cosim
```

看到如下输出即表示就绪：

```
============================================================
gem5 MI300X co-simulation server ready
  Socket:     /tmp/gem5-mi300x.sock
  VRAM SHM:   /mi300x-vram
  Host SHM:   /cosim-guest-ram
  VRAM size:  16GiB
  Host RAM:   8GiB
  CUs:        40
Waiting for QEMU to connect...
============================================================
```

#### 修复权限

Docker 创建的文件归 root 所有，需要修复权限以便 QEMU 访问：

```bash
docker exec gem5-cosim chmod 777 /tmp/gem5-mi300x.sock
docker exec gem5-cosim chmod 666 /dev/shm/mi300x-vram
```

#### 启动 QEMU

```bash
qemu-system-x86_64 \
    -machine q35 -enable-kvm -cpu host \
    -snapshot \
    -m 8G -smp 4 \
    -object memory-backend-file,id=mem0,size=8G,mem-path=/dev/shm/cosim-guest-ram,share=on \
    -numa node,memdev=mem0 \
    -kernel "$PWD/build/images/guest/ubuntu/24.04/x86_64/rocm7_0/kernel" \
    -append "console=ttyS0,115200 root=/dev/vda1 modprobe.blacklist=amdgpu" \
    -drive "file=$PWD/build/images/guest/ubuntu/24.04/x86_64/rocm7_0/disk,format=qcow2,if=virtio" \
    -device 'vfio-user-pci,socket={"type":"unix","path":"/tmp/gem5-mi300x.sock"}' \
    -nographic -no-reboot
```

> **重要：** 内核命令行必须包含 `modprobe.blacklist=amdgpu`，防止 PCI 子系统在 VGA ROM 写入共享内存之前自动加载驱动。`cosim-gpu-setup.service` 会按正确顺序初始化。

QEMU 会把客户机的修改写入临时覆盖镜像，并在退出时丢弃这些修改，从而保留已校验的镜像包。

#### SSH 访问客户机

`cosim_launch.sh` 脚本默认启用了用户态网络和 SSH 端口转发。在客户机内通过 `netplan` 配置网络接口后，从宿主机连接：

```bash
ssh -p 2222 gem5@localhost
# 默认密码：12345
```

### 关闭

```bash
# 在 QEMU 串口控制台：
poweroff
# 或强制退出：Ctrl-A X

# 清理 Docker 容器和共享内存：
docker rm -f gem5-cosim
rm -f /dev/shm/mi300x-vram /dev/shm/cosim-guest-ram
rm -f /tmp/gem5-mi300x.sock
```

> 使用 `cosim_launch.sh` 时，退出 QEMU 后会自动执行清理。

## GPU 驱动初始化

MI300X GPU 驱动可在 QEMU 客户机启动后**自动**或**手动**加载。磁盘镜像中已包含所有必需的文件（ROM、固件、内核模块）。

### 自动加载（默认）

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

### 手动加载

如果 systemd 服务未安装，或需要重新加载驱动，在客户机启动后手动执行以下命令。

**前置条件：** `cosim_launch.sh` 正在运行（gem5 + QEMU 已连接），客户机已启动并获取了 root shell，内核命令行中传递了 `modprobe.blacklist=amdgpu`。

**快速参考（可直接复制粘贴）：**

```bash
dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128
ln -sf /usr/lib/firmware/amdgpu/mi300_discovery /usr/lib/firmware/amdgpu/ip_discovery.bin
modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

### 详细步骤

#### 步骤 1：加载 VGA BIOS ROM

```bash
dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128
```

将 MI300X VBIOS ROM 镜像写入物理地址 `0xC0000`（768 KB）处的传统 VGA ROM 区域。amdgpu 驱动在初始化期间从该地址读取 VBIOS。如果没有 ROM，驱动将报错 `"Unable to locate a BIOS ROM"`。

| 参数 | 值 | 含义 |
|-----------|-------|---------|
| `if`      | `/root/roms/mi300.rom` | ROM 二进制文件（在磁盘镜像中） |
| `of`      | `/dev/mem`             | 物理内存设备 |
| `bs`      | `1k`                   | 块大小 = 1024 字节 |
| `seek`    | `768`                  | 跳转至 768 × 1024 = `0xC0000` |
| `count`   | `128`                  | 写入 128 × 1024 = 128 KB |

#### 步骤 2：链接 IP Discovery 固件

```bash
ln -sf /usr/lib/firmware/amdgpu/mi300_discovery \
       /usr/lib/firmware/amdgpu/ip_discovery.bin
```

将驱动的 IP discovery 固件路径指向 MI300X 专用的 discovery 二进制文件。`discovery=2` 模式从磁盘上的固件文件读取 GPU IP 块信息，而非从 GPU 自身的 ROM/寄存器读取。

#### 步骤 3：加载 amdgpu 内核模块

```bash
modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

关键参数：

| 参数 | 值 | 含义 |
|-----------|-------|---------|
| `ip_block_mask` | `0x67` | 禁用 PSP（bit 3）和 SMU（bit 4）；cosim 不模拟这些 IP 块 |
| `ppfeaturemask` | `0` | 禁用 PowerPlay 特性；cosim 无电源管理硬件 |
| `dpm` | `0` | 禁用动态电源管理 |
| `audio` | `0` | 禁用音频；cosim 无 HDMI/DP 音频 |
| `ras_enable` | `0` | 禁用 RAS — 防止 VBIOS 最小化时空指针崩溃 |
| `discovery` | `2` | 使用固件文件进行 IP discovery |

> **警告**：使用 `ip_block_mask=0x6f`（仅禁用 SMU）会导致 PSP 固件加载失败和内核 panic。务必使用 `0x67`。

> **警告**：`dd` 步骤（步骤 1）在 `modprobe` 之前**必须**执行。否则驱动的 BIOS 发现链全部失败，`atom_context` 为 NULL，导致在 `amdgpu_atom_parse_data_header` 处发生空指针崩溃。

### 验证

```bash
# 检查 dmesg 中 amdgpu 初始化信息
dmesg | grep -i amdgpu | tail -20

# 检查 PCI 设备
lspci | grep -i amd

# 验证设备识别和 GPU 能力
rocm-smi
rocminfo | head -40
```

预期输出：

```
# rocm-smi
GPU[0]  : Device Name: 0x74a0
GPU[0]  : Partition: SPX

# rocminfo
Name:                    gfx942
Compute Unit:            320
KERNEL_DISPATCH capable
```

> 加载过程中可能出现约 80 条 fence fallback timer 警告，这是正常现象——DRM 子系统在探测所有 ring buffer 时使用轮询模式的超时回退机制。

### 文件位置（客户机磁盘镜像内部）

| 文件 | 路径 |
|------|------|
| VGA BIOS ROM | `/root/roms/mi300.rom` |
| IP Discovery 固件 | `/usr/lib/firmware/amdgpu/mi300_discovery` |
| 自动加载服务 | `/etc/systemd/system/cosim-gpu-setup.service` |
| 自动加载脚本 | `/usr/local/bin/cosim-gpu-setup.sh` |
| amdgpu 模块 | `/lib/modules/$(uname -r)/updates/dkms/amdgpu.ko.zst` |

## 运行 HIP 测试

### 编译 HIP 测试程序

在客户机内编写一个简单的向量加法程序：

```bash
cat > /tmp/vec_add.cpp << 'EOF'
#include <hip/hip_runtime.h>
#include <cstdio>

__global__ void vec_add(int *a, int *b, int *c, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}

int main() {
    const int N = 4;
    int ha[N] = {1, 2, 3, 4};
    int hb[N] = {10, 20, 30, 40};
    int hc[N] = {0};

    int *da, *db, *dc;
    hipMalloc(&da, N * sizeof(int));
    hipMalloc(&db, N * sizeof(int));
    hipMalloc(&dc, N * sizeof(int));

    hipMemcpy(da, ha, N * sizeof(int), hipMemcpyHostToDevice);
    hipMemcpy(db, hb, N * sizeof(int), hipMemcpyHostToDevice);

    vec_add<<<1, N>>>(da, db, dc, N);

    hipMemcpy(hc, dc, N * sizeof(int), hipMemcpyDeviceToHost);

    printf("Result: %d %d %d %d\n", hc[0], hc[1], hc[2], hc[3]);

    bool pass = (hc[0]==11 && hc[1]==22 && hc[2]==33 && hc[3]==44);
    printf("%s\n", pass ? "PASSED!" : "FAILED!");

    hipFree(da); hipFree(db); hipFree(dc);
    return pass ? 0 : 1;
}
EOF
```

编译并运行：

```bash
# 编译（gfx942 = MI300X 架构）
/opt/rocm/bin/hipcc --offload-arch=gfx942 -o /tmp/vec_add /tmp/vec_add.cpp

# 运行
/tmp/vec_add
```

### 预期输出

```
Result: 11 22 33 44
PASSED!
```

### 使用 gem5-resources 中的 square 测试

也可以使用 gem5-resources 自带的 `square` 测试程序。需要先在宿主机编译：

```bash
just build-gpu-app square
```

然后将编译产物拷入客户机（通过 `scp -P 2222` 或直接挂载磁盘镜像），在客户机内运行：

```bash
./square.default
```

预期输出：

```
info: running on device AMD Instinct MI300X
info: allocate host and device mem (  7.63 MB)
info: launch 'vector_square' kernel
info: check result
PASSED!
```

## 附录：独立 gem5 GPU 全系统仿真

上述联合仿真流程使用 QEMU 进行 KVM 加速启动，gem5 仅提供 GPU 模型。另一种方式是**完全在 gem5 内部运行**（CPU + GPU），无需 QEMU。这是标准的 gem5 全系统 GPU 仿真。

### 主要区别

| 方面 | 联合仿真（QEMU + gem5） | 独立 gem5 |
|---|---|---|
| CPU 执行 | KVM（接近原生速度） | gem5 atomic/timing 模型 |
| 启动时间 | 约 30 秒 | 约 2-5 分钟（KVM 快进） |
| GPU 模型 | gem5 MI300X（通过 vfio-user） | gem5 MI300X（同一模型） |
| 驱动加载 | systemd 服务或手动 `modprobe` | 通过 `m5 readfile` 自动化 |
| 适用场景 | 驱动开发、交互式调试 | 微架构研究、性能基准测试 |

### 快速开始

**1. 编译 gem5 和磁盘镜像**（步骤与上述联合仿真相同）。

**2. 编译 GPU 测试应用：**

```bash
just build-gpu-app square
```

**3. 运行仿真：**

```bash
just run-gem5-fs build/apps/square/square.default
```

> **重要：** 必须指定 `--app` 参数。不指定时，`readfile_contents` 为空字符串，驱动永远不会被加载。

**4. 监控输出：**

```bash
tail -f m5out/board.pc.com_1.device
```

仿真使用 KVM 快进 Linux 启动过程，然后自动加载 GPU 驱动并运行指定的应用。Guest 在测试完成后调用 `m5 exit` 结束仿真。

关于独立仿真流程的完整细节（包括另一套 `gpufs` 配置、使用 `guestfish`
验证磁盘镜像以及构建过程内部原理），请参阅 gem5 文档。

## 常见问题排查

五个最常见的问题及其解决方法：

| 症状 | 原因 | 解决方法 |
|---------|-------|-----|
| gem5 容器启动后立即退出 | `gem5.opt` 未编译、路径错误或 Python 模块导入失败 | 执行 `docker logs gem5-cosim` 查看错误信息 |
| `Failed to connect to /tmp/gem5-mi300x.sock` | gem5 未就绪或 socket 权限不正确 | 等待 gem5 日志中出现 "Waiting for QEMU to connect"；执行 `chmod 777` 修复 socket 权限 |
| `amdgpu_atom_parse_data_header` 处空指针崩溃 | `modprobe` 之前未写入 VGA ROM | 先执行 `dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128` |
| PSP GPU reset 导致内核 panic | 使用了错误的 `ip_block_mask`（如 `0x6f` 而非 `0x67`） | 务必使用 `ip_block_mask=0x67` 同时禁用 PSP 和 SMU |
| `hipcc` 报错：cannot find ROCm device library | ROCm 未安装或架构标志错误 | 确认 `/opt/rocm/lib/` 存在；使用 `--offload-arch=gfx942` |

完整的故障排查表和调试技术，请参阅[参考手册 §4](reference.md#4-已知问题与陷阱)。
