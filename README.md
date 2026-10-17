<div align="center">
  <h1 align="center">Cosim-GPU</h1>
  <p><strong>YAML-driven QEMU + gem5 co-simulation for AMD MI300X</strong></p>
</div>

<p align="center">
  <img alt="Linux x86_64 and ARM64" src="https://img.shields.io/badge/Linux-x86%5F64%20%7C%20ARM64-FCC624?logo=linux&amp;logoColor=black">
  <img alt="Rust 1.95+" src="https://img.shields.io/badge/Rust-1.95%2B-orange?logo=rust&amp;logoColor=white">
  <img alt="QEMU device models" src="https://img.shields.io/badge/QEMU-vfio--user-FF6600">
  <img alt="gem5 MI300X" src="https://img.shields.io/badge/gem5-MI300X-6f42c1">
  <img alt="ROCm HIP" src="https://img.shields.io/badge/ROCm-HIP-ED1C24">
  <img alt="Apache 2.0 license" src="https://img.shields.io/badge/license-Apache--2.0-34a853">
</p>

<p align="center">
  <strong>English</strong> ·
  <a href="README.zh.md">简体中文</a>
</p>

<p align="center">
  <a href="docs/en/getting-started.md">Getting started</a> ·
  <a href="docs/en/topology.md">Topology reference</a> ·
  <a href="docs/en/architecture.md">Architecture</a>
</p>

Define Linux hosts and simulated devices in YAML, then launch a session with
the Rust <code>cosim</code> CLI. Host QEMU connects to gem5 MI300X and QEMU
device processes over **vfio-user**; ROCm/HIP workloads run in the Linux guest.

## Architecture

~~~mermaid
flowchart LR
    YAML[Topology YAML] --> CLI[Rust cosim launcher]

    subgraph Linux host
        CLI --> H[Host QEMU]
        CLI --> G[gem5 MI300X process]
        CLI --> Q[QEMU device process]
        H <-->|vfio-user| G
        H <-->|vfio-user| Q
        H --- P[Machine memory pool]
        G --- P
        Q --- P
        H --> Guest[Linux guest · ROCm/HIP]
    end
~~~

The launcher prepares memory and disk resources, starts devices before the
host, and cleans up the session. Device models implement device behavior and
timing.

## Quick start

~~~bash
just submodules
just dev-image        # Non-Linux hosts, or set COSIM_ENV=container

# Build the toolchain and guest-image workflow, then start a sample machine
just build-all
just run samples/machines/single-gpu.yaml
~~~

### Sample topologies

- <code>samples/machines/single-gpu.yaml</code> — start a single-GPU guest.
- <code>samples/machines/mixed-models.yaml</code> — combine gem5 and QEMU device models.
- <code>samples/machines/gpu-8.yaml</code> — inspect an eight-GPU machine with a 96 GiB memory pool.
- <code>samples/machines/host-only-aarch64.yaml</code> — check a host-only setup on ARM64.

<details>
<summary>Example: one machine with gem5 and QEMU devices</summary>

~~~yaml
version: 1
imports:
  - hosts/qemu.yaml
  - hosts/ubuntu-24.yaml
  - devices/gpu/mi300x.yaml
  - devices/pci/qemu-edu.yaml
machines:
  - id: m0
    host: {use: ubuntu, memory: 32G}
    devices:
      - {use: mi300x, count: 2}
      - {use: qemu-edu}
~~~

The QEMU device example serves the real <code>edu</code> PCI model through
<code>x-vfio-user-server</code> from the QEMU built by <code>just build-qemu</code>.

</details>

## Host and build environment

### Launcher and configuration tools

Use Rust 1.95+, Cargo and just for the launcher. Build recipes for QEMU, gem5,
m5, topology runs and Rust checks use <code>scripts/dev.sh</code>. On non-Linux
hosts or with <code>COSIM_ENV=container</code>, they use a temporary container
from <code>scripts/Dockerfile.dev</code>. Guest-image and HIP builds, plus
<code>just launch</code> and <code>just test</code>, use their own Docker workflows.

### Linux host sessions

- glibc and <code>setpriv</code> from util-linux.
- QEMU for the host architecture and <code>qemu-img</code>.
- x86_64 hosts use <code>qemu-system-x86_64</code>; ARM64 hosts use
  <code>qemu-system-aarch64</code>.
- <code>COSIM_HOST_ARCH</code> selects the build architecture and defaults to
  the current host. gem5 builds into
  <code>build/x86_64/VEGA_X86</code> on x86_64 and
  <code>build/aarch64/VEGA_X86</code> on ARM64.

### MI300X and QEMU device models

- MI300X co-simulation needs gem5 VEGA_X86, QEMU with vfio-user support,
  guest-image inputs, and KVM for the Ubuntu guest.
- QEMU device servers need a build with
  <code>--enable-vfio-user-server</code>.
- The supplied Ubuntu/ROCm guest-image builder targets x86_64.
- Guest-image builds and simulator artifacts need sufficient disk space. The
  memory-pool filesystem must accommodate the complete machine layout.

## Commands

### Inspect a topology

~~~bash
just cosim validate samples/machines/gpu-8.yaml
just cosim plan samples/machines/mixed-models.yaml
just cosim graph samples/clusters/cluster-4x8.yaml
~~~

### Build

- <code>just build-cosim</code> builds the release launcher.
- <code>just build-qemu [jobs]</code> builds QEMU with KVM and vfio-user support.
- <code>just build-gem5 [jobs]</code> builds gem5; use one job for memory-constrained linking.
- <code>just build-disk</code> builds the Ubuntu/ROCm guest image.

### Run and test

- <code>just run &lt;yaml&gt;</code> launches a topology.
- <code>just run-dev &lt;yaml&gt;</code> launches with the development build.
- <code>just launch [options]</code> runs the shell-based QEMU/gem5 interface.
- <code>just test --all</code> runs guest GPU tests in fresh sessions.
- <code>just check-cosim</code> runs rustfmt, Clippy and Rust tests.
- <code>just test-cosim-integration</code> runs sessions with real QEMU processes, disks and signals.
- <code>just test-cosim-vfio-user</code> adds a QEMU vfio-user device to the integration session.

Host-only checks with an installed QEMU:

~~~bash
just run-dev samples/machines/host-only.yaml --run-for 1
just run-dev samples/machines/host-only-aarch64.yaml --run-for 1
~~~

The session directory contains the resolved plan, memory layouts, process logs
and <code>verdict.json</code>. Guest driver initialization is provided by
<code>cosim-gpu-setup.service</code> with:

~~~text
amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2
~~~

## Repository map

- **Rust workspace:** <code>crates/cosim-topology/</code>,
  <code>crates/cosim-runtime/</code> and <code>crates/cosim-cli/</code>.
- **Simulation models:** <code>gem5/</code>, <code>qemu/</code>,
  <code>gem5-resources/</code> and <code>configs/sst/</code>.
- **Project tools:** <code>samples/</code>, <code>scripts/</code>,
  <code>justfile</code> and <code>.agents/</code>.

## More documentation

- [Rust guidelines](docs/en/guidelines.md)
- [Reference](docs/en/reference.md)
- [Contributing](docs/en/contributing.md)

The top-level project uses the [Apache 2.0 license](LICENSE). Submodules retain
their respective licenses.
