[中文](../zh/cosim-dev-story.md)

# One Day, Two Submodules, Fifteen Bugs: How I Used Claude to Bring a $14,000 MI300X GPU into QEMU

> AMD Instinct MI300X: 304 compute units, 192GB HBM3, retail price over $14,000 per card.
> Now, all you need is an ordinary x86 Linux machine to run full ROCm/HIP workloads on QEMU.

## Prelude

I've been working on GPU simulators for a while. gem5 has a device model for the MI300X and supports full-system simulation, but its KVM fast-forward mode is still slow -- a Linux boot takes 5 minutes, driver loading takes another 5, and every time you debug an MMIO register issue, you're staring at a 10-minute blank wait.

I'd been wanting to do something: let QEMU run Linux and the amdgpu driver, while gem5 handles only the GPU compute model, bridged by some IPC mechanism. That way, QEMU uses KVM for the CPU part at near-native speed, and gem5 only processes GPU MMIO/Doorbell/DMA, focusing on simulation accuracy.

The idea sounds straightforward, but in practice it touches QEMU PCIe device models, gem5 SimObject architecture, Linux amdgpu driver initialization flow, GART address translation, shared memory file offset alignment, and Unix domain socket edge-triggered semantics -- and every intersection of these is a pitfall.

On the morning of March 6, 2026, I opened Claude Code and started this project. By the early hours of March 8, the first HIP vector addition test printed `PASSED!` in the co-simulation environment.

This article documents the pitfalls encountered and key decisions made throughout the process.

---

## Architecture: The One-Liner Version

```
QEMU (Q35+KVM, guest Linux + amdgpu driver)
    <-- Unix socket -->
gem5 (MI300X GPU model, no kernel)
    <-- shared memory -->
/dev/shm/cosim-guest-ram + /dev/shm/mi300x-vram
```

On the QEMU side, there's a full Q35 virtual machine running Ubuntu 24.04 + ROCm 7.0 + amdgpu driver. I added a `mi300x-gem5` PCIe device to QEMU that forwards all MMIO reads/writes and doorbell writes to gem5 via a Unix domain socket.

On the gem5 side, it runs the MI300X GPU device model -- Shader, CU arrays, PM4 command processor, SDMA engines, Ruby cache hierarchy -- but **no Linux kernel**. It starts with a `StubWorkload` shell and just waits for MMIO requests from QEMU over the socket.

Guest physical memory and GPU VRAM each have a shared memory file (`/dev/shm/`), both QEMU and gem5 can mmap directly, achieving zero-copy DMA.

The BAR layout must strictly match the amdgpu driver's hardcoded expectations:

| BAR | Content | Size | Communication |
|-----|---------|------|---------------|
| BAR0+1 | VRAM | 16 GiB | Shared memory |
| BAR2+3 | Doorbell | 4 MiB | Socket forwarding |
| BAR4 | MSI-X | 256 vectors | QEMU local |
| BAR5 | MMIO registers | 512 KiB | Socket forwarding |

---

## The First Hour: Writing a PCIe Device from Scratch

At 6:30 AM on March 6, I had Claude help me write the QEMU-side `mi300x_gem5.c`. It's a standard QEMU PCIe device, but with several special aspects:

1. **Six BARs**, three of which need 64-bit address space (16GB VRAM can't fit below 4G)
2. **Two socket connections**: one synchronous (MMIO request/response), one asynchronous (interrupts and DMA events)
3. **MSI-X support**: 256 interrupt vectors, gem5 notifies QEMU via the event socket to trigger `msix_notify()`

The gem5-side `MI300XGem5Cosim` SimObject is slightly more complex -- it's a socket server that listens for QEMU connections, dispatches received MMIO messages to `AMDGPUDevice` for processing, and sends results back.

The first version was about 1,500 lines (QEMU 700 + gem5 800), clean in structure but full of bugs.

---

## Bug #1: SIGIO Edge-Triggered Deadlock -- The Most Insidious Problem

gem5's event system uses `FASYNC`/`SIGIO` to monitor socket data. This is **edge-triggered** -- when the socket buffer transitions from empty to non-empty, the kernel sends one `SIGIO`, and only one.

The problem lies in the amdgpu driver's register access pattern. The driver frequently writes an INDEX register (selecting which internal register to access), then immediately reads the DATA register (getting the value). The write is fire-and-forget, the read blocks waiting for a response. When these two messages arrive back-to-back in gem5's socket buffer, only one SIGIO fires.

My initial `handleClientData()` read only one message per invocation. Result: gem5 reads the write message, processes it, then waits for the next SIGIO. But the read message is already in the buffer, and no new SIGIO will come to wake it up. QEMU blocks waiting for the read response. **Perfect deadlock.**

gem5 processed 15 messages and then hung forever.

The fix was simple -- change single-read to a drain loop:

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

After this fix, MMIO message count jumped from 15 to **35,181**. Driver initialization pushed all the way to the PSP firmware loading stage.

**Lesson: Any FASYNC-based I/O handler must drain all pending data. This is inevitable in PCIe indirect register access scenarios.**

---

## Bug #2: ip_block_mask -- The Documentation Lies

The amdgpu driver has an `ip_block_mask` parameter controlling which IP blocks to initialize. In cosim mode, PSP (security processor) and SMU (power management) aren't needed and must be disabled.

I initially used `0x6f`, thinking I'd disabled PSP (enum value 4) while keeping everything else. But PSP was still being initialized, firmware loading failed with `-EINVAL`, and the entire GPU init failed.

It took a while to figure out: `ip_block_mask` bits correspond to the **IP discovery detection order index**, not the `amd_ip_block_type` enum values. MI300X's detection order is:

```
0: soc15_common   1: gmc_v9_0    2: vega20_ih
3: psp            4: smu         5: gfx_v9_4_3
6: sdma_v4_4_2    7: vcn_v4_0_3  8: jpeg_v4_0_3
```

PSP is 4 in the enum but 3 in detection order. `0x6f` = `0110_1111` disables index 4 (smu), but index 3 (psp) remains enabled. The correct value is `0x67` = `0110_0111`, disabling both index 3 and 4.

**Lesson: There's no correspondence between the enum values in amd_shared.h and the actual bitmask the driver uses. Only the dmesg detection log tells the truth.**

---

## Bug #3: Shared Memory Offset -- Two Systems Disagree on Memory Layout

This bug was the most bizarre. GART page table entries read back as all zeros, the PM4 command processor kept reading opcode 0x0 (NOP) in an infinite loop.

The issue was a disagreement between QEMU Q35 and gem5 on memory splitting. With 8GB RAM configured:

- **QEMU Q35** hardcodes `below_4g = 2 GiB` (when `ram_size >= 0xB0000000`), placing the upper 6GB at file offset 2G
- **gem5** defaults to `below_4g = 3 GiB`, placing the upper 5GB at file offset 3G

Both sides mmap the same shared memory file, but disagree on "where above-4G memory sits in the file." gem5 reads GART page tables from offset 3G -- which is all zeros, because QEMU wrote the data at offset 2G.

Fix: Replicate Q35's split logic exactly in `mi300_cosim.py`.

**Lesson: When sharing a memory-backend-file, both parties must agree on file offsets for every range, not just total size.**

---

## Bug #4: VRAM Addresses Incorrectly Routed Through GART Translation

PM4's `RELEASE_MEM` and SDMA's rptr write-back sometimes target VRAM addresses (address < 16 GiB). The original code fed all addresses through `getGARTAddr()` for translation, but VRAM addresses have no corresponding GART page table entries. Translation failed 861,000+ times, eventually exhausting memory and segfaulting.

The fix used three layers of defense:

1. **PM4 layer**: `writeData()` / `releaseMem()` check `isVRAMAddress(addr)`, routing VRAM writes directly to device memory
2. **SDMA layer**: rptr write-back skips `getGARTAddr()` for VRAM addresses
3. **GART fallback**: Unmapped GART pages map to `paddr=0` (sink) instead of faulting

---

## The Moment: HIP Vector Addition PASSED

Early morning of March 8. All bugs fixed, driver loading normal, `rocm-smi` sees MI300X (0x74a0), `rocminfo` reports gfx942 architecture with 320 CUs.

In the guest, I wrote the simplest HIP test -- four-element vector addition:

```cpp
__global__ void add(int *a, int *b, int *c, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}
```

Compile, run:

```
Result: 11 22 33 44
PASSED!
```

`{1+10, 2+20, 3+30, 4+40}` = `{11, 22, 33, 44}`. hipMalloc, hipMemcpy (host-to-device / device-to-host), kernel dispatch, hipDeviceSynchronize all returned normally. MSI-X interrupts forwarded from gem5 through the event socket to QEMU, QEMU triggered `msix_notify()`, the guest IH handler processed them correctly -- the entire interrupt chain ran end-to-end for the first time.

This was the first time gem5 served as a "remote GPU" driven by a real amdgpu driver inside a QEMU guest for actual computation.

---

## Collaborating with Claude

The entire development happened in one massive conversation session, resumed as context ran out. The workflow was:

1. **I provide raw terminal output**: dmesg logs, gem5 panic messages, socket communication hexdumps
2. **Claude analyzes the output**, searches gem5/QEMU/Linux kernel source code to locate root causes
3. **Claude proposes and implements fixes** -- directly editing gem5 C++ code, QEMU C code, Python configs, shell scripts
4. **Background builds**: gem5 compilation ~30 min, QEMU ~5 min, disk image ~40 min -- all running in the background
5. **I test and post new output**, cycle continues

Claude's role in this project wasn't "a tool that writes code for me," but more like **a collaborator with deep understanding of gem5 and QEMU internals**. A few typical scenarios:

- **SIGIO deadlock**: I only posted "gem5 hangs after 15 messages," Claude immediately identified the FASYNC edge-triggered semantics and proposed the drain loop
- **ip_block_mask**: I posted the dmesg IP discovery log, Claude directly mapped out the detection order vs. bitmask mismatch
- **GART translation**: Claude traced the `getGARTAddr()` multiply-by-8 transformation through gem5 source code, discovering VRAM addresses being misdirected into the GART path
- **Q35 memory split**: Claude dug out the hardcoded 2GiB boundary at `qemu/hw/i386/pc_q35.c:161` and compared it with gem5's 3GiB default

Throughout the process, 15 blocking bugs were resolved one by one. Each fix was built on accurate understanding of underlying system behavior -- not trial and error, but root cause analysis.

---

## One Day's Results

| Metric | Data |
|--------|------|
| Development time | ~24 hours (Mar 6 06:30 - Mar 8 06:00) |
| New code | ~2,500 lines (gem5 C++ ~800, QEMU C ~700, Python config ~200, shell scripts ~800) |
| Blocking bugs resolved | 15 |
| Technical documentation | 6 articles (bilingual zh+en, ~2,000 lines total) |
| Git commits | 16 (cosim main repo) |
| MMIO operations | 65,000+ without crashes |
| HIP compute test | PASSED |

The final system supports:

- **Full amdgpu driver loading**: DRM initialized, 7 XCP partitions, gfx942 architecture
- **ROCm toolchain**: rocm-smi, rocminfo working normally
- **HIP GPU compute**: hipMalloc, kernel dispatch, hipDeviceSynchronize
- **MSI-X interrupt forwarding**: gem5 to QEMU event notification
- **Shared memory DMA**: zero-copy VRAM + Guest RAM
- **One-click launch**: `./scripts/cosim_launch.sh`

---

## What This Means

The MI300X is AMD's most powerful data center GPU, priced over $14,000 per card -- ordinary developers simply can't get their hands on one. But through QEMU + gem5 co-simulation, you can, on any x86 Linux machine:

- Run the full ROCm 7.0 software stack
- Compile and run HIP programs
- Perform performance analysis on a cycle-accurate GPU model
- Debug the amdgpu driver initialization flow
- Develop and validate new GPU architecture features

All code is open source: [github.com/zevorn/cosim-gpu](https://github.com/zevorn/cosim-gpu)

```bash
git clone --recurse-submodules git@github.com:zevorn/cosim-gpu.git
cd cosim-gpu
GEM5_BUILD_IMAGE=ghcr.io/gem5/gpu-fs:latest ./scripts/run_mi300x_fs.sh build-all
cd scripts && docker build -t gem5-run:local -f Dockerfile.run . && cd ..
./scripts/cosim_launch.sh
```

---

## Afterword

Some might ask: "Can code written in one day be reliable?"

Honestly, without Claude, this project would have taken at least two weeks. Not because of the code volume -- 2,500 lines isn't much for a PCIe device bridge -- but because the debugging process requires simultaneously understanding the internal behavior of three systems: QEMU's Q35 memory layout, gem5's event-driven I/O model, and the Linux amdgpu driver's IP block initialization sequence. Misunderstanding any single aspect means hours in a debugging black hole.

Claude's value isn't in writing code for me, but in **dramatically shortening the time from "seeing a symptom" to "understanding the root cause."** When I paste a segment of dmesg output, Claude can correlate it in seconds to specific functions in gem5 source code and hardcoded constants in QEMU -- this kind of cross-codebase correlation analysis simply can't be done at human speed by manually reading source code.

Of course, Claude isn't omnipotent. All testing was done by me, all architectural decisions were mine (like choosing two socket connections instead of one, choosing StubWorkload instead of full-system boot), and all final verification required confirmation in the real environment. AI is an amplifier, not a replacement.

But this amplifier is genuinely powerful. One day, one person, one AI, and a $14,000 GPU was brought into QEMU.

---

*Zewen, March 2026*
