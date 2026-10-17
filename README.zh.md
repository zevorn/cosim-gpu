<div align="center">
  <h1 align="center">Cosim-GPU</h1>
  <p><strong>使用 QEMU 和 gem5 进行 YAML 配置的 AMD MI300X GPU 联合仿真</strong></p>
</div>

<p align="center">
  <img alt="Linux x86_64 与 ARM64" src="https://img.shields.io/badge/Linux-x86%5F64%20%7C%20ARM64-FCC624?logo=linux&amp;logoColor=black">
  <img alt="Rust 1.95+" src="https://img.shields.io/badge/Rust-1.95%2B-orange?logo=rust&amp;logoColor=white">
  <img alt="QEMU 设备模型" src="https://img.shields.io/badge/QEMU-vfio--user-FF6600">
  <img alt="gem5 MI300X" src="https://img.shields.io/badge/gem5-MI300X-6f42c1">
  <img alt="ROCm HIP" src="https://img.shields.io/badge/ROCm-HIP-ED1C24">
  <img alt="Apache 2.0 许可证" src="https://img.shields.io/badge/license-Apache--2.0-34a853">
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <strong>简体中文</strong>
</p>

<p align="center">
  <a href="docs/zh/getting-started.md">快速入门</a> ·
  <a href="docs/zh/topology.md">拓扑参考</a> ·
  <a href="docs/zh/architecture.md">架构说明</a>
</p>

使用 YAML 描述 Linux 宿主机和模拟设备，再用 Rust <code>cosim</code> 启动会话。
宿主 QEMU 通过 **vfio-user** 连接 gem5 MI300X 或 QEMU 设备进程，客户机中运行
ROCm/HIP 负载。

## 架构

~~~mermaid
flowchart LR
    YAML[拓扑 YAML] --> CLI[Rust cosim 启动器]

    subgraph Linux 宿主机
        CLI --> H[宿主 QEMU]
        CLI --> G[gem5 MI300X 进程]
        CLI --> Q[QEMU 设备进程]
        H <-->|vfio-user| G
        H <-->|vfio-user| Q
        H --- P[机器内存池]
        G --- P
        Q --- P
        H --> Guest[Linux 客户机 · ROCm/HIP]
    end
~~~

启动器准备内存和磁盘资源，先启动设备再启动宿主机，并在会话结束时清理资源。
设备行为和模拟时序由设备模型负责。

## 快速入门

~~~bash
just dev-submodules
just dev-image        # 非 Linux 主机，或设置 COSIM_ENV=container

# 在带 KVM 的 x86_64 Linux 主机上构建工具链和客户机镜像
just build-all
just run-topology samples/machines/single-gpu.yaml --payload samples/payloads/ubuntu-rocm7_0.yaml
~~~

首次构建镜像时会使用 `resources/images/` 中选定的配方，并将验证后的磁盘与内核
保存在 `build/images/`。可以先检查解析后的配方和启动命令，不构建镜像或启动进程：

~~~bash
just run-topology samples/machines/single-gpu.yaml --payload samples/payloads/ubuntu-rocm7_0.yaml --dry-run
~~~

### 拓扑示例

- <code>samples/machines/single-gpu.yaml</code>：启动单 GPU 客户机。
- <code>samples/machines/mixed-models.yaml</code>：组合 gem5 和 QEMU 设备模型。
- <code>samples/machines/gpu-8.yaml</code>：查看八 GPU 机器及其 96 GiB 内存池。
- <code>samples/machines/host-only-aarch64.yaml</code>：在 ARM64 上检查仅含宿主机的配置。

<details>
<summary>示例：一台机器组合 gem5 和 QEMU 设备</summary>

~~~yaml
version: 1
imports:
  - hosts/qemu.yaml
  - devices/gpu/mi300x.yaml
  - devices/pci/qemu-edu.yaml
machines:
  - id: m0
    host: {use: host-x86, memory: 32G}
    devices:
      - {use: mi300x, count: 2}
      - {use: qemu-edu}
~~~

运行 `just run-topology` 时传入 `--payload samples/payloads/ubuntu-rocm7_0.yaml`，以加载客户机内核
和磁盘输入。构建产物统一保存在仓库顶层的 `build/` 目录中。

QEMU 设备示例使用 <code>just build-qemu</code> 构建的 QEMU，通过
<code>x-vfio-user-server</code> 提供真实的 <code>edu</code> PCI 模型。

</details>

## 宿主机与构建环境

### 启动器和配置工具

启动器需要 Rust 1.95+、Cargo 和 just。QEMU、gem5、m5 构建，拓扑运行和 Rust 检查
通过 <code>scripts/dev.sh</code> 执行。非 Linux 主机或设置
<code>COSIM_ENV=container</code> 时，命令使用基于
<code>scripts/Dockerfile.dev</code> 的临时容器。客户机镜像、HIP 应用以及
<code>just run-launch</code> 和 <code>just test-gpu</code> 使用各自的 Docker 流程。

### Linux 宿主机运行会话

- 需要 glibc 和 util-linux 提供的 <code>setpriv</code>。
- 需要匹配宿主机架构的 QEMU 和 <code>qemu-img</code>。
- x86_64 使用 <code>qemu-system-x86_64</code>；ARM64 使用
  <code>qemu-system-aarch64</code>。
- <code>COSIM_HOST_ARCH</code> 用于选择构建架构，默认使用当前宿主机架构。
  gem5 在 x86_64 上构建到 <code>build/gem5/x86_64/VEGA_X86</code>，在 ARM64 上构建到
  <code>build/gem5/aarch64/VEGA_X86</code>。

### MI300X 和 QEMU 设备模型

- MI300X 联合仿真需要 gem5 VEGA_X86、支持 vfio-user 的 QEMU、客户机镜像输入，
  以及 Ubuntu 客户机所需的 KVM。
- QEMU 设备服务端需要使用 <code>--enable-vfio-user-server</code> 构建。
- 提供的 Ubuntu/ROCm 客户机镜像构建流程面向 x86_64。
- 客户机镜像和模拟器产物需要足够的磁盘空间。内存池所在文件系统必须容纳完整的机器布局。

## 仓库目录

- **Rust 工作区：** <code>crates/cosim-topology/</code>、
  <code>crates/cosim-runtime/</code> 和 <code>crates/cosim-cli/</code>。
- **模拟器模型：** <code>third_party/gem5/</code>、
  <code>third_party/qemu/</code>、<code>third_party/gem5-resources/</code> 和
  <code>configs/sst/</code>。
- **项目工具：** <code>samples/</code>、<code>scripts/</code>、
  <code>justfile</code> 和 <code>.agents/</code>。
- **Guest 镜像配方：** <code>resources/images/</code> 中按操作系统组织的 Packer/QEMU
  和 Ansible 配置。

## 更多文档

- [Rust 开发规范](docs/zh/guidelines.md)
- [参考手册](docs/zh/reference.md)
- [贡献指南](docs/zh/contributing.md)

顶层项目使用 [Apache 2.0 许可证](LICENSE)。子模块保留各自的许可证。
