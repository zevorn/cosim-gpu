[English](../en/cosim-debugging-pitfalls.md)

# MI300X 协同仿真：调试陷阱与修复

本文档记录了在 QEMU+gem5 MI300X 协同仿真启动过程中遇到并修复的 bug，包含一些不易察觉的根因分析。

## 1. SIGIO 合并导致的死锁（handleClientData 单次读取）

**现象**：驱动在首次访问 PCIe INDEX2/DATA2 寄存器对时挂起。gem5 处理约 15 条消息后停止响应。

**根因**：Linux FASYNC/SIGIO 是**边沿触发**的。当 QEMU 发送一个 fire-and-forget 的 MMIO write 后紧接着一个阻塞式 MMIO read 时，两条消息可能在 gem5 的 SIGIO handler 触发前同时到达。此时系统只会投递一个信号。原始的 `handleClientData()` 每次 SIGIO 只读取一条消息，导致第二条消息永远滞留。

**修复**（`mi300x_gem5_cosim.cc`）：将 `handleClientData()` 改为排空循环，每处理一条消息后使用 `poll(fd, POLLIN, 0)` 检查是否还有更多数据：

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

**教训**：任何基于 FASYNC 的 I/O handler 都必须排空所有待处理数据，而不能只读一条消息。这种模式（write + read 合并）在 PCIe 间接寄存器访问中很常见。

---

## 2. ip_block_mask 使用的是检测顺序而非类型枚举值

**现象**：`PSP load tmr failed!`、`hw_init of IP block <psp> failed -22`、`Fatal error during GPU init`。

**根因**：ROCm 7.0 DKMS 驱动（`amdgpu_device.c:2807`）检查 `(amdgpu_ip_block_mask & (1 << i))`，其中 `i` 是 **检测顺序索引**，而非 `amd_ip_block_type` 枚举值。

MI300X 检测顺序（来自 dmesg）：

| 索引 | IP Block        | mask 中的位 |
|------|-----------------|-------------|
| 0    | soc15_common    | 0x01        |
| 1    | gmc_v9_0        | 0x02        |
| 2    | vega20_ih       | 0x04        |
| 3    | psp             | 0x08        |
| 4    | smu             | 0x10        |
| 5    | gfx_v9_4_3      | 0x20        |
| 6    | sdma_v4_4_2     | 0x40        |
| 7    | vcn_v4_0_3      | 0x80        |
| 8    | jpeg_v4_0_3     | 0x100       |

**修复**：将 `ip_block_mask` 从 `0x6f` 改为 `0x67`：
- `0x6f` = `0110_1111` → 启用 common、gmc、ih、**psp**、gfx、sdma
- `0x67` = `0110_0111` → 启用 common、gmc、ih、gfx、sdma（禁用索引 3 的 psp 和索引 4 的 smu）

**陷阱**：`amd_shared.h` 中的 `amd_ip_block_type` 枚举显示 PSP=4，但 PSP 的 mask 位实际是 `(1 << 3)`，因为 PSP 在 IP discovery 过程中排在第三个（索引 3）。文档和枚举值具有误导性。

---

## 3. PM4ReleaseMem.dataSelect panic

**现象**：gem5 panic，报错 `Unimplemented PM4ReleaseMem.dataSelect`。

**根因**：`pm4_packet_processor.cc` 中只实现了 `dataSelect == 1`（32 位数据写入）。驱动在 GFX 初始化过程中会使用其他模式。

**修复**：添加了所有常见 dataSelect 值的处理：

| dataSelect | 行为                          |
|------------|-------------------------------|
| 0          | 不写入数据（仅触发事件）      |
| 1          | 写入 32 位值（已有实现）      |
| 2          | 写入 64 位值                  |
| 3          | 写入 64 位 GPU 时钟计数器     |
| 其他       | 发出警告并视为空操作          |

---

## 4. 协同仿真模式下 GART 表未填充

**现象**：大量 `GART translation for X not found` 警告。PM4 处理器读到全零内存（opcode 0x0）。KIQ ring test 超时。

**根因**：在协同仿真模式下，QEMU 的 BAR2（VRAM，16GB）由共享内存文件（`/dev/shm/mi300x-vram`）支撑。驱动对 VRAM 的写入直接进入共享文件，**完全绕过了 gem5 的 socket 协议**。gem5 的 `AMDGPUVM::gartTable` 哈希表在 `AMDGPUDevice::writeFrame()` 中填充，而该函数仅在写入通过 gem5 内存系统时才会执行。由于 VRAM 写入绕过了 gem5，`gartTable` 始终为空。

**修复**（`amdgpu_vm.cc` + `amdgpu_vm.hh`）：在 `GARTTranslationGen::translate()` 中添加了共享 VRAM 回退机制：

1. 在 `AMDGPUVM` 中添加 `vramShmemPtr` / `vramShmemSize` 字段
2. `MI300XGem5Cosim` 在映射共享 VRAM 后设置这些字段
3. 当 `gartTable` 未命中时，直接从共享 VRAM 读取 PTE：

```cpp
Addr gart_byte_offset = bits(range.vaddr, 63, 12);
Addr pte_vram_offset = (gartBase() - getFBBase()) + gart_byte_offset;
memcpy(&pte, vramShmemPtr + pte_vram_offset, sizeof(pte));
```

**关键细节**：`getGARTAddr()`（在 translate 之前调用）已经将页索引乘以 8 得到字节偏移：
```cpp
addr = (((addr >> 12) << 3) << 12) | low_bits;  // page_num *= 8
```
因此 translate 函数中 `bits(vaddr, 63, 12)` 已经是 PTE 的**字节偏移**，而不是页索引。如果再乘以 8，会导致地址偏移到 GART 表中 8 倍远的位置。

**架构注释**：原始 translate 代码中的"扩展公式"（`gart_addr += lsb * 7`）对于经过 `getGARTAddr()` 处理的地址实际上是空操作，因为 `lsb = (page_num * 8) & 7 = 0`（`page_num * 8` 始终是 8 对齐的，所以低 3 位永远为零）。

---

## 协同仿真架构通用说明

### 哪些操作绕过了 socket 协议

| 资源           | QEMU BAR | gem5 BAR | 通过 Socket？ | 通过共享内存？ |
|----------------|----------|----------|---------------|----------------|
| MMIO 寄存器    | BAR0     | BAR5     | 是            | 否             |
| VRAM（16GB）   | BAR2     | BAR0     | **否**        | 是             |
| Doorbells      | BAR4     | BAR2     | 是            | 否             |

任何通过拦截 VRAM 写入来填充的 gem5 数据结构（如 `gartTable`、页表、ring buffer）在协同仿真模式下都**不会**被填充。这些结构需要显式的回退机制来从共享 VRAM 中读取数据。

### 驱动加载失败后需要重启 guest

驱动 `hw_init` 失败后执行 `rmmod amdgpu` 会导致 kernel oops（`kgd2kfd_device_exit` 中的 page fault）。模块会停留在 "busy" 状态，无法重新加载。唯一的解决方法是重启整个协同仿真环境（杀掉 QEMU，重启 gem5 Docker 容器，重启 QEMU）。
