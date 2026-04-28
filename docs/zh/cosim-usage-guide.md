[English](../en/cosim-usage-guide.md)

# QEMU + gem5 MI300X 联合仿真使用指南

从编译到运行 HIP GPU 计算的完整流程。

## 架构概述

```
+---------------------------------+     +------------------------------+
|  QEMU (Q35 + KVM)              |     |  gem5 (Docker 容器内)        |
|  +---------------------------+  |     |  +------------------------+  |
|  | Guest Linux (Ubuntu 24.04)|  |     |  | MI300X GPU 模型        |  |
|  | amdgpu 驱动               |  |     |  | - Shader + CU          |  |
|  | ROCm 7.0 / HIP 运行时     |  |     |  | - PM4 / SDMA 引擎      |  |
|  +-----------+---------------+  |     |  | - Ruby 缓存层次         |  |
|              | MMIO/Doorbell    |     |  +----------+-------------+  |
|  +-----------v---------------+  |     |  +----------v-------------+  |
|  | vfio-user-pci (built-in)  |<--------->| MI300XVfioUser Server  |  |
|  +---------------------------+  |vfio-|  +------------------------+  |
|                                 |user |                              |
+---------------------------------+     +------------------------------+
        |                                         |
        v                                         v
  /dev/shm/cosim-guest-ram              /dev/shm/mi300x-vram
  (Guest 物理内存, 共享)                 (GPU VRAM, 共享)
```

- **QEMU** 负责：CPU 执行、Linux 内核引导、PCIe 枚举、amdgpu 驱动加载
- **gem5** 负责：MI300X GPU 计算模型（Shader、CU、缓存、DMA 引擎）
- 两者通过 **vfio-user 协议**（基于 Unix 域套接字）通信。QEMU 使用内置的 `vfio-user-pci` 设备，gem5 端运行 `MI300XVfioUser` 作为 vfio-user 服务端，透明处理 MMIO / Doorbell / PCI Config 访问。数据通过 **共享内存** 共享

## 前置条件

| 需求 | 说明 |
|---|---|
| 宿主机系统 | Linux x86_64，支持 KVM（已在 WSL2 6.6.x 验证） |
| Docker | 守护进程运行中，当前用户在 `docker` 组 |
| KVM | `/dev/kvm` 可访问 |
| 磁盘空间 | 至少 120 GB（55G 磁盘镜像 + 构建中间产物） |
| 内存 | 建议 16 GB 以上（gem5 编译和运行都比较占内存） |
| 工具 | `git`、`screen`、`unzip` |

## 目录结构

```
/home/zevorn/cosim/
    gem5/                              # gem5 源码（cosim 分支）
        build/VEGA_X86/gem5.opt        # gem5 二进制
        configs/example/gpufs/
            mi300_cosim.py             # cosim 配置脚本
        scripts/
            run_mi300x_fs.sh           # 编排脚本
            cosim_launch.sh            # cosim 一键启动脚本
            Dockerfile.run             # 运行时 Docker 镜像
    gem5-resources/                    # 磁盘镜像、内核、GPU 应用
        src/x86-ubuntu-gpu-ml/
            disk-image/x86-ubuntu-rocm70   # 55G raw 磁盘镜像
            vmlinux-rocm70                 # 内核
    docs/                              # 文档
    qemu/                              # QEMU 源码（仅 legacy 后端需要）
        build/qemu-system-x86_64       # QEMU 二进制
```

---

## 第一步：编译 gem5

gem5 二进制链接了 Ubuntu 24.04 的库，需要在兼容环境中编译。

> **注意：** vfio-user 后端依赖 `libjson-c-dev`（编译时）和 `libjson-c5`（运行时）。`ghcr.io/gem5/gpu-fs:latest` 镜像已包含此依赖，无需额外安装。若在宿主机上直接编译，请先安装 `libjson-c-dev`。

### 方式一：Docker 内编译（推荐）

```bash
cd /home/zevorn/cosim/gem5

# 使用 gpu-fs 镜像编译（amd64，包含所有依赖）
docker run --rm \
    -v "$(pwd):/gem5" -w /gem5 \
    gem5-run:local \
    scons build/VEGA_X86/gem5.opt -j4
```

> **注意：** 内存不足时降低并行度（`-j1` 或 `-j2`）。使用 gold linker 可减少链接阶段内存占用。

### 方式二：编排脚本

```bash
./scripts/run_mi300x_fs.sh build-gem5
```

产出：`build/VEGA_X86/gem5.opt`（约 1.1 GB）。

### 构建运行时 Docker 镜像

```bash
cd scripts
docker build -t gem5-run:local -f Dockerfile.run .
```

此镜像基于 `ghcr.io/gem5/gpu-fs`，添加了 Python 3.12 支持，用于运行 gem5。

---

## 第二步：编译 QEMU

使用 vfio-user 后端时，**原版 QEMU 10.0+** 即可直接使用（内置 `vfio-user-pci` 设备），无需自定义 QEMU 代码。标准编译：

```bash
# 任意 QEMU 10.0+ 源码均可
mkdir -p qemu-build && cd qemu-build
/path/to/qemu/configure --target-list=x86_64-softmmu
make -j$(nproc)
```

产出：`qemu-system-x86_64`。

> **Legacy 后端：** 若使用 `--cosim-backend=legacy`，则需要 `cosim/qemu/` 中包含 `mi300x-gem5` 设备的源码。编译方式同上，但必须使用 cosim 分支的 QEMU 源码。

也可通过编排脚本：

```bash
cd /home/zevorn/cosim/gem5
./scripts/run_mi300x_fs.sh build-qemu
```

---

## 第三步：准备磁盘镜像和内核

磁盘镜像包含 Ubuntu 24.04 + ROCm 7.0 + 内核 6.8.0-79-generic 及 amdgpu DKMS 模块。

### 自动构建

```bash
./scripts/run_mi300x_fs.sh build-disk
```

### 手动构建

```bash
cd ../gem5-resources/src/x86-ubuntu-gpu-ml
./build.sh -var "qemu_path=/usr/sbin/qemu-system-x86_64"
```

> Arch Linux 上 QEMU 路径为 `/usr/sbin/`，其他发行版可能是 `/usr/bin/`。

### 产出

| 产物 | 路径 | 大小 |
|---|---|---|
| 磁盘镜像 | `../gem5-resources/src/x86-ubuntu-gpu-ml/disk-image/x86-ubuntu-rocm70` | 约 55 GB |
| 内核 | `../gem5-resources/src/x86-ubuntu-gpu-ml/vmlinux-rocm70` | 约 64 MB |

---

## 第四步：启动 cosim

### 方式一：一键启动脚本（推荐）

```bash
cd /home/zevorn/cosim/gem5
./scripts/cosim_launch.sh
```

此脚本会自动完成以下所有步骤（启动 gem5 容器、等待就绪、修复权限、启动 QEMU），并以交互模式进入 QEMU 串口控制台。

可用参数：

```bash
./scripts/cosim_launch.sh --help
./scripts/cosim_launch.sh --gem5-debug MI300XCosim   # 开启 gem5 调试输出
./scripts/cosim_launch.sh --vram-size 32GiB          # 自定义 VRAM 大小
./scripts/cosim_launch.sh --num-cus 80               # 自定义 CU 数量
./scripts/cosim_launch.sh --cosim-backend=vfio-user  # 使用 vfio-user 后端（默认）
./scripts/cosim_launch.sh --cosim-backend=legacy     # 使用 legacy 自定义套接字后端
```

### 方式二：手动分步启动

#### 4.1 启动 gem5（Docker 容器）

```bash
docker run -d --name gem5-cosim \
    -v /home/zevorn/cosim/gem5:/gem5 \
    -v /tmp:/tmp \
    -v /dev/shm:/dev/shm \
    -w /gem5 \
    -e PYTHONPATH=/usr/lib/python3.12/lib-dynload \
    gem5-run:local \
    /gem5/build/VEGA_X86/gem5.opt --listener-mode=on \
    /gem5/configs/example/gpufs/mi300_cosim.py \
    --socket-path=/tmp/gem5-mi300x.sock \
    --shmem-path=/mi300x-vram \
    --shmem-host-path=/cosim-guest-ram \
    --dgpu-mem-size=16GiB \
    --num-compute-units=40 \
    --mem-size=8G
```

#### 4.2 等待 gem5 就绪

```bash
# 查看 gem5 日志，等待出现 "listening" 或 "ready"
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

#### 4.3 修复权限

Docker 创建的文件归 root 所有，需要修复权限以便 QEMU 访问：

```bash
docker exec gem5-cosim chmod 777 /tmp/gem5-mi300x.sock
docker exec gem5-cosim chmod 666 /dev/shm/mi300x-vram
```

#### 4.4 启动 QEMU

```bash
# 前台交互模式（vfio-user 后端，使用原版 QEMU 10.0+）
qemu-system-x86_64 \
    -machine q35 -enable-kvm -cpu host \
    -m 8G -smp 4 \
    -object memory-backend-file,id=mem0,size=8G,mem-path=/dev/shm/cosim-guest-ram,share=on \
    -numa node,memdev=mem0 \
    -kernel /home/zevorn/cosim/gem5-resources/src/x86-ubuntu-gpu-ml/vmlinux-rocm70 \
    -append "console=ttyS0,115200 root=/dev/vda1 modprobe.blacklist=amdgpu" \
    -drive file=/home/zevorn/cosim/gem5-resources/src/x86-ubuntu-gpu-ml/disk-image/x86-ubuntu-rocm70,format=raw,if=virtio \
    -device 'vfio-user-pci,socket={"type":"unix","path":"/tmp/gem5-mi300x.sock"}' \
    -nographic -no-reboot
```

> **重要：** 内核命令行必须包含 `modprobe.blacklist=amdgpu`，防止 PCI 子系统在 VGA ROM 写入共享内存之前自动加载驱动。`cosim-gpu-setup.service` 会按正确顺序初始化（dd ROM → modprobe）。
>
> **注意：** 使用 vfio-user 后端时，无需在 QEMU 侧指定 `shmem-path` 或 `vram-size` 参数，共享内存由 gem5 端的 `MI300XVfioUser` 服务端负责创建和管理。

或者以后台 screen 模式运行：

```bash
screen -dmS qemu-cosim -L -Logfile /tmp/qemu-cosim-screen.log \
    qemu-system-x86_64 \
    -machine q35 -enable-kvm -cpu host \
    -m 8G -smp 4 \
    -object memory-backend-file,id=mem0,size=8G,mem-path=/dev/shm/cosim-guest-ram,share=on \
    -numa node,memdev=mem0 \
    -kernel /home/zevorn/cosim/gem5-resources/src/x86-ubuntu-gpu-ml/vmlinux-rocm70 \
    -append "console=ttyS0,115200 root=/dev/vda1 modprobe.blacklist=amdgpu" \
    -drive file=/home/zevorn/cosim/gem5-resources/src/x86-ubuntu-gpu-ml/disk-image/x86-ubuntu-rocm70,format=raw,if=virtio \
    -device 'vfio-user-pci,socket={"type":"unix","path":"/tmp/gem5-mi300x.sock"}' \
    -nographic -no-reboot

# 连接 screen 查看串口输出
screen -r qemu-cosim
# 退出 screen: Ctrl-A D（分离）
```

#### 4.5 SSH 访问 Guest

`cosim_launch.sh` 脚本默认启用了用户态网络和 SSH 端口转发（`-netdev user,id=net0,hostfwd=tcp::2222-:22` + `virtio-net-pci`）。要通过 SSH 访问 Guest，需要先在 Guest 内配置网络。

**1. 查看网卡名称：**

```bash
ip a
```

找到 virtio 网卡接口（如 `enp0s2`），具体名称取决于 PCI 拓扑，可能不同。

**2. 配置 netplan：**

编辑 `/etc/netplan/50-cloud-init.yaml`：

```yaml
network:
  version: 2
  ethernets:
    enp0s2:
      dhcp4: true
```

> **注意：** 将 `enp0s2` 替换为 `ip a` 输出中的实际接口名称。

**3. 应用配置：**

```bash
netplan apply
```

**4. 从宿主机 SSH 登录：**

在宿主机上打开另一个终端，执行：

```bash
ssh -p 2222 gem5@localhost
```

默认密码：`12345`。

> **提示：** 相比 QEMU 串口控制台，SSH 访问在交互操作、文件传输（`scp -P 2222`）以及多会话场景下更加方便。

---

## 第五步：加载 GPU 驱动

Guest Linux 启动完成后（自动以 root 登录），执行以下命令加载 amdgpu 驱动。

### 方式一：自动加载（默认）

磁盘镜像内置 `cosim-gpu-setup.service`，开机时自动执行：

1. 通过 `dd` 写入 VGA ROM 到 `0xC0000`（gem5 `readROM()` 需要此数据）
2. 链接 IP discovery 固件
3. 执行 `modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2`

服务约 40 秒完成。登录后用 `rocm-smi` 验证。

### 方式二：手动加载

```bash
# 1. 加载 VGA ROM（modprobe 之前必须执行）
dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128

# 2. 链接 IP discovery 固件
ln -sf /usr/lib/firmware/amdgpu/mi300_discovery \
       /usr/lib/firmware/amdgpu/ip_discovery.bin

# 3. 加载 amdgpu 驱动
modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
```

> **关键参数说明：**
> - `ip_block_mask=0x67`（二进制 0110_0111）启用 GMC、IH、DCN、GFX、SDMA、VCN，禁用 PSP 和 SMU
> - 若使用错误的 mask（如 0x6f），PSP 初始化会触发 GPU reset 导致内核 panic
> - `ras_enable=0` 防止 `amdgpu_atom_parse_data_header` 中的空指针崩溃（cosim ROM 仅 3KB，ATOMBIOS 数据最小化）
> - `dd` 步骤**必须**在 modprobe 之前执行 — 否则驱动的 BIOS 发现链全部失败，`atom_context` 为 NULL

### 验证驱动加载

```bash
# 检查 dmesg — 应看到 "amdgpu: DRM initialized" 和 "7 XCP partitions"
dmesg | grep -i amdgpu | tail -20

# 验证设备识别
rocm-smi

# 验证 GPU 能力
rocminfo | head -40
```

预期输出：

```
# rocm-smi 输出
GPU[0]  : Device Name: 0x74a0
GPU[0]  : Partition: SPX

# rocminfo 输出
Name:                    gfx942
Compute Unit:            320
KERNEL_DISPATCH capable
```

> 加载过程中可能出现约 80 条 fence fallback timer 警告，这是正常现象——DRM 子系统在探测所有 ring buffer 时使用轮询模式的超时回退机制。

---

## 第六步：运行 GPU 计算测试

### 编译 HIP 测试程序

在 Guest 内编写一个简单的向量加法程序：

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

也可以使用 gem5-resources 自带的 square 测试程序。需要先在宿主机编译：

```bash
cd /home/zevorn/cosim/gem5
./scripts/run_mi300x_fs.sh build-app square
```

然后将编译产物拷入 Guest（通过 scp 或直接挂载磁盘镜像），在 Guest 内运行：

```bash
./square.default
```

---

## 关闭 cosim

### 在 QEMU 串口控制台

```
# 正常关机
poweroff

# 或强制退出 QEMU
Ctrl-A X
```

### 清理 Docker 容器和共享内存

```bash
docker rm -f gem5-cosim
rm -f /dev/shm/mi300x-vram /dev/shm/cosim-guest-ram
rm -f /tmp/gem5-mi300x.sock
```

> 使用 `cosim_launch.sh` 时，退出 QEMU 后会自动执行清理。

---

## 故障排查

### gem5 容器启动后立即退出

```bash
docker logs gem5-cosim
```

常见原因：
- `gem5.opt` 未编译或路径错误
- Python 模块导入失败（检查 PYTHONPATH）
- 共享内存创建权限问题

### QEMU 连接 gem5 失败

```
Failed to connect to /tmp/gem5-mi300x.sock
```

- 确认 gem5 已完成初始化（看到 "Waiting for QEMU to connect"）
- 确认 socket 权限已修复（`chmod 777`）

### 驱动加载失败 — PSP GPU reset panic

```
BUG: kernel NULL pointer dereference at psp_gpu_reset+0x43
```

- 使用了错误的 `ip_block_mask`。必须用 `0x67`（禁用 PSP+SMU），不能用 `0x6f`

### gem5 崩溃 — GART translation not found

```
GART translation for 0x3fff800000000 not found
```

- 这是已修复的 bug：未映射的 GART 页会被路由到 sink 地址（paddr=0），不再崩溃
- 如果仍然出现，确认使用的是最新编译的 gem5 二进制

### hipcc 编译报错 — offload arch

```
error: cannot find ROCm device library
```

- 确认 ROCm 正确安装：`ls /opt/rocm/lib/`
- 使用正确的架构标志：`--offload-arch=gfx942`

### GPU 计算超时

- 检查 gem5 日志（`docker logs gem5-cosim`）是否有错误
- 少量 fence timeout 是正常的，大量超时可能表示 DMA 或中断路径有问题

---

## 关键参数参考

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--socket-path` | `/tmp/gem5-mi300x.sock` | QEMU <-> gem5 通信套接字（vfio-user 协议） |
| `--shmem-path` | `/mi300x-vram` | GPU VRAM 共享内存名称（/dev/shm 下） |
| `--shmem-host-path` | `/cosim-guest-ram` | Guest RAM 共享内存名称 |
| `--dgpu-mem-size` | `16GiB` | GPU VRAM 大小 |
| `--num-compute-units` | `40` | GPU 计算单元数量 |
| `--mem-size` | `8GiB` | Guest 物理内存大小 |
| `--cosim-backend` | `vfio-user` | cosim 后端类型（`vfio-user` 或 `legacy`） |
| `ip_block_mask` | `0x67` | amdgpu 驱动 IP 块掩码 |
| `discovery` | `2` | 使用 IP discovery 固件 |

## 关键文件参考

| 文件 | 用途 |
|---|---|
| `scripts/cosim_launch.sh` | cosim 一键启动脚本 |
| `scripts/run_mi300x_fs.sh` | 编排脚本（编译、构建镜像、运行） |
| `configs/example/gpufs/mi300_cosim.py` | gem5 cosim 配置 |
| `src/dev/amdgpu/mi300x_vfio_user.{cc,hh}` | gem5 侧 vfio-user 服务端（默认后端） |
| `src/dev/amdgpu/mi300x_gem5_cosim.{cc,hh}` | gem5 侧 legacy 桥接（legacy 后端） |
| `src/dev/amdgpu/amdgpu_device.cc` | GPU 设备模型 |
| `src/dev/amdgpu/amdgpu_vm.cc` | GPU 地址翻译（GART 等） |
| `qemu/hw/misc/mi300x_gem5.c` | QEMU 侧 mi300x-gem5 PCIe 设备（仅 legacy 后端） |

## 版本矩阵

| 组件 | 版本 |
|---|---|
| Guest 操作系统 | Ubuntu 24.04.2 LTS |
| Guest 内核 | 6.8.0-79-generic |
| ROCm | 7.0.0 |
| amdgpu DKMS | 匹配 ROCm 7.0 |
| gem5 构建目标 | VEGA_X86 |
| GPU 设备 | MI300X (gfx942, DeviceID 0x74A0) |
| 一致性协议 | GPU_VIPER |
| QEMU | 10.0+（vfio-user 后端）或 cosim 分支（legacy 后端） |
