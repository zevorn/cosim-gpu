# QEMU + gem5 MI300X 联合仿真

[English](README.md)

将 **QEMU**（KVM 加速的宿主机 CPU/系统仿真）与 **gem5**（周期精确的 MI300X GPU
模型）相结合的联合仿真框架，无需物理 GPU 硬件即可运行真实的 AMD ROCm/HIP 工作负载。

```
┌─────────────────────────────┐       ┌────────────────────────────┐
│  QEMU  (Q35 + KVM)         │       │  gem5  (Docker 容器)        │
│  ┌───────────────────────┐  │       │  ┌──────────────────────┐  │
│  │ Guest Linux           │  │       │  │ MI300X GPU 模型      │  │
│  │ amdgpu 驱动            │  │       │  │  Shader / CU / SDMA  │  │
│  │ ROCm 7.0 / HIP        │  │       │  │  PM4 / Ruby 缓存     │  │
│  └───────────┬───────────┘  │       │  └──────────┬───────────┘  │
│  ┌───────────▼───────────┐  │       │  ┌──────────▼───────────┐  │
│  │ mi300x-gem5 PCIe 设备  │◄────────►│  │ MI300XGem5Cosim 桥接 │  │
│  └───────────────────────┘  │ Unix  │  └──────────────────────┘  │
│                             │Socket │                            │
└─────────────────────────────┘       └────────────────────────────┘
        │                                       │
        ▼                                       ▼
  /dev/shm/cosim-guest-ram            /dev/shm/mi300x-vram
  (共享 Guest 物理内存)                (共享 GPU VRAM)
```

## 功能特性

- **完整驱动加载** — amdgpu DRM 初始化，7 个 XCP 分区，gfx942 架构
- **HIP 计算验证** — hipMalloc、内核调度、hipDeviceSynchronize 全流程通过
- **MSI-X 中断转发** — gem5 → QEMU 中断转发，IH ring buffer 正常工作
- **共享内存 DMA** — 通过 `/dev/shm` 实现 VRAM 和 Guest RAM 的零拷贝共享
- **驱动自动加载** — systemd 服务自动以 `ip_block_mask=0x67 discovery=2` 加载

## 前置条件

| 需求 | 说明 |
|---|---|
| 宿主机系统 | Linux x86_64，支持 KVM（已在 WSL2 6.6.x 验证） |
| Docker | 守护进程运行中，当前用户在 `docker` 组 |
| KVM | `/dev/kvm` 可访问 |
| 磁盘空间 | 约 120 GB（55G 磁盘镜像 + 构建中间产物） |
| 内存 | 建议 16 GB 以上 |

## 快速开始

```bash
# 1. 克隆仓库（含子模块）
git clone --recurse-submodules git@github.com:zevorn/cosim.git
cd cosim

# 2. 编译 gem5（Docker 内）
cd gem5
docker run --rm -v "$(pwd):/gem5" -w /gem5 \
    -e PYTHONPATH=/usr/lib/python3.12/lib-dynload \
    ghcr.io/gem5/gpu-fs:latest \
    bash -c "scons build/VEGA_X86/gem5.opt -j4 GOLD_LINKER=True --linker=gold"

# 3. 构建运行时 Docker 镜像
cd scripts && docker build -t gem5-run:local -f Dockerfile.run . && cd ..

# 4. 编译 QEMU
cd ../qemu
mkdir -p build && cd build
../configure --target-list=x86_64-softmmu
make -j$(nproc)
cd ../..

# 5. 构建磁盘镜像（Ubuntu 24.04 + ROCm 7.0）
cd gem5
./scripts/run_mi300x_fs.sh build-disk

# 6. 启动联合仿真
./scripts/cosim_launch.sh
```

Guest 启动后（自动以 root 登录）：

```bash
# 加载 GPU 驱动
modprobe amdgpu ip_block_mask=0x67 discovery=2

# 验证
rocm-smi          # 应显示设备 0x74a0
rocminfo          # 应显示 gfx942, 320 CUs

# 运行 HIP 测试
cat > /tmp/test.cpp << 'EOF'
#include <hip/hip_runtime.h>
#include <cstdio>
__global__ void add(int *a, int *b, int *c, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}
int main() {
    const int N = 4;
    int ha[] = {1,2,3,4}, hb[] = {10,20,30,40}, hc[4] = {};
    int *da, *db, *dc;
    hipMalloc(&da, N*4); hipMalloc(&db, N*4); hipMalloc(&dc, N*4);
    hipMemcpy(da, ha, N*4, hipMemcpyHostToDevice);
    hipMemcpy(db, hb, N*4, hipMemcpyHostToDevice);
    add<<<1, N>>>(da, db, dc, N);
    hipMemcpy(hc, dc, N*4, hipMemcpyDeviceToHost);
    printf("Result: %d %d %d %d\n", hc[0], hc[1], hc[2], hc[3]);
    printf("%s\n", (hc[0]==11&&hc[1]==22&&hc[2]==33&&hc[3]==44) ? "PASSED!" : "FAILED!");
    hipFree(da); hipFree(db); hipFree(dc);
}
EOF
/opt/rocm/bin/hipcc --offload-arch=gfx942 -o /tmp/test /tmp/test.cpp
/tmp/test
# 预期输出: Result: 11 22 33 44
#           PASSED!
```

## 仓库结构

```
cosim/
├── gem5/                    # gem5 仿真器（子模块，cosim-gpu 分支）
│   ├── src/dev/amdgpu/      # MI300X GPU 设备模型和 cosim 桥接
│   └── configs/example/gpufs/mi300_cosim.py  # cosim 配置
├── qemu/                    # QEMU 模拟器（子模块，cosim-gpu 分支）
│   ├── hw/misc/mi300x_gem5.c      # mi300x-gem5 PCIe 设备
│   └── include/hw/misc/mi300x_gem5.h
├── scripts/                 # 构建和启动脚本
│   ├── cosim_launch.sh      # cosim 一键启动脚本
│   ├── run_mi300x_fs.sh     # 编排脚本
│   ├── cosim_guest_setup.sh # Guest 侧 GPU 设置脚本
│   ├── cosim_test_client.py # Socket 测试客户端
│   └── Dockerfile.run       # gem5 运行时 Docker 镜像
├── docs/                    # 技术文档（中文）
│   ├── cosim-usage-guide.md           # 完整使用指南
│   ├── cosim-technical-notes.md       # 架构与修复记录
│   ├── mi300x-memory-management.md    # GPU 内存管理与地址翻译
│   ├── gpu-fs-guide.md               # gem5 GPU 全系统仿真指南
│   ├── cosim-guest-gpu-init.md        # Guest 侧 GPU 初始化流程
│   └── cosim-debugging-pitfalls.md    # 调试踩坑记录
├── LICENSE                  # Apache 2.0
└── README.md                # 英文文档
```

## 技术文档

详细技术文档位于 [`docs/`](docs/) 目录下：

- [完整使用指南](docs/cosim-usage-guide.md) — 从编译到运行 HIP 测试的全流程
- [技术笔记](docs/cosim-technical-notes.md) — 架构设计、踩坑记录、修复方案
- [MI300X 内存管理](docs/mi300x-memory-management.md) — GART、地址翻译、内存映射
- [GPU 全系统仿真指南](docs/gpu-fs-guide.md) — gem5 单机 GPU FS 仿真复现
- [Guest GPU 初始化流程](docs/cosim-guest-gpu-init.md) — 驱动加载与设备初始化
- [调试踩坑记录](docs/cosim-debugging-pitfalls.md) — 常见问题与解决方案

## 版本矩阵

| 组件 | 版本 |
|---|---|
| Guest 操作系统 | Ubuntu 24.04.2 LTS |
| Guest 内核 | 6.8.0-79-generic |
| ROCm | 7.0.0 |
| GPU 设备 | MI300X (gfx942, DeviceID 0x74A0) |
| gem5 构建目标 | VEGA_X86, GPU_VIPER 一致性协议 |

## 许可证

本项目采用 [Apache License 2.0](LICENSE) 许可证。

注意：`gem5` 和 `qemu` 子模块分别遵循各自的许可证（gem5: BSD-3-Clause, QEMU: GPL-2.0）。

## 致谢

- [gem5](https://www.gem5.org/) — 模块化计算机体系结构仿真器
- [QEMU](https://www.qemu.org/) — 开源机器模拟器
- [ROCm](https://rocm.docs.amd.com/) — AMD GPU 计算平台
