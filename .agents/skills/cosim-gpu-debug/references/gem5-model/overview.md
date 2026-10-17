# gem5 MI300X Model Reference

Use this reference when `cosim-gpu-debug` evidence points at gem5 GPU behavior:
PM4, SDMA, interrupts, HSA queues, VMID/PASID, translation, TLB/PWC, or cache
maintenance.

## Architecture

```
Guest ROCm driver
  <-> QEMU MI300X cosim device or vfio-user-pci
  <-> gem5 MI300X GPU model
      AMDGPUDevice
      PM4PacketProcessor
      SDMAEngine
      HSAPacketProcessor
      GPUDynInst
      Ruby memory system
```

## Key source files

| Area | Files | Use |
|------|-------|-----|
| Device | `third_party/gem5/src/dev/amdgpu/amdgpu_device.cc/hh` | BARs, VMID allocation, PASID mapping, interrupts |
| VM | `third_party/gem5/src/dev/amdgpu/amdgpu_vm.cc/hh` | GPU page tables, GART, translation, TLB/PWC invalidation |
| PM4 | `third_party/gem5/src/dev/amdgpu/pm4_packet_processor.cc/hh` | MAP_PROCESS, RUN_LIST, INDIRECT_BUFFER, RELEASE_MEM, WRITE_DATA |
| Interrupts | `third_party/gem5/src/dev/amdgpu/interrupt_handler.cc/hh` | CP_EOP and TRAP interrupt cookies |
| SDMA | `third_party/gem5/src/dev/amdgpu/sdma_engine.cc/hh` | copy operations |
| HSA | `third_party/gem5/src/dev/hsa/hsa_packet_processor.cc/hh` | AQL dispatch, barriers, signals |
| Scheduler | `third_party/gem5/src/dev/hsa/hw_scheduler.cc/hh` | queue management and RUN_LIST |
| Compute | `third_party/gem5/src/gpu-compute/gpu_command_processor.cc/hh` | kernel launch and kernarg handling |
| TLB | `third_party/gem5/src/arch/amdgpu/vega/tlb.cc` | TLB and page-walk-cache behavior |
| Ruby | `third_party/gem5/src/mem/ruby/**` | GPU cache hierarchy and maintenance callbacks |

## PM4 command flow

```
Guest doorbell write
  -> PM4PacketProcessor::processPkt()
  -> MAP_PROCESS allocates VMID and binds PASID
  -> RUN_LIST submits command buffers
  -> INDIRECT_BUFFER follows command buffer chains
  -> WRITE_DATA writes constants or signals
  -> RELEASE_MEM flushes and writes completion signal
```

## Interrupt handling

| Source | Purpose | VMID sensitivity |
|--------|---------|------------------|
| CP_EOP | command processor completion | VMID from running queue |
| TRAP | exception or page fault | not VMID-sensitive in current model |

`interrupt_handler.cc::prepareInterruptCookie()` sets PASID and VMID from the
current context. Guest amdgpu uses the cookie to route interrupts to the owning
process.

## VMID and PASID

- VMID selects the GPU page-table context. VMID 0 is reserved for kernel or
  driver paths.
- PASID identifies the process address space.
- MAP_PROCESS binds PASID to a VMID.
- `pasidFromVMID()` returns the mapped PASID or 0 when unknown.
- Current testing is centered on one user VMID.

For the full semantics, read `vmid-pasid-architecture.md`.

## MAP_QUEUES VMID assertion

When launch or driver initialization fails with QEMU `error_setv`, vfio-user
abort, socket close, or a missing gem5 container, inspect:

```bash
grep -n 'assert.*vmid\|assert(queue_vmid)\|MAPQueues' \
  third_party/gem5/src/dev/amdgpu/pm4_packet_processor.cc
```

If `assert(queue_vmid)` is present near MAP_QUEUES, read
`vmid-assert-lesson.md` and `examples/vmid-assert-crash.md`. In this pattern,
QEMU reports the socket failure after gem5 exits first.

Accepted fallback:

```cpp
const uint16_t queue_vmid =
    pkt->vmid ? pkt->vmid : gpuDevice->lastVMID();
```

## Translation and cache checkpoints

- TLB and PWC invalidation are separate model responsibilities.
- PWC entries are not tagged per VMID in the current model.
- CP writes can bypass the same GL2 path used by CU scalar loads.
- Kernarg correctness can require GL2 and SQC maintenance before shader
  execution.

Read `cache-coherence-checkpoints.md` and `discovery-log.md` when logs show
translation, kernarg, SQC, GL2, PWC, or TLB symptoms.

## Known limitations

1. Single user VMID is the normal tested path.
2. Power management is disabled through driver parameters.
3. Device-side printf is unsupported and can hang.
4. Some HSA packets may be fake-completed by the packet processor.
5. Cherry-picking from `fix-hsa-signal-ih-completion-2` can introduce the
   MAP_QUEUES VMID assertion.
