# Cache Coherence Checkpoints

Use this reference when `cosim-gpu-debug` evidence points at cache-coherence or
translation behavior. These are source-level checkpoints for gem5 model
inspection; they are not a replacement for per-case evidence.

## PWC and TLB

Question:
- Does the invalidation path clear final TLB entries and page-walk-cache state?
- Does the path cover the VMID or address range used by the failing sample?

Checkpoints:
- `third_party/gem5/src/arch/amdgpu/vega/tlb.cc`: `GpuTLB::invalidateAll()` should reach PWC invalidation when the current branch requires full translation maintenance.
- `third_party/gem5/src/arch/amdgpu/vega/pagetable_walker.cc`: `Walker::invalidatePWC()` is the page-walk-cache invalidation entry.
- `third_party/gem5/src/dev/amdgpu/amdgpu_vm.cc`: GPU VM invalidation routes driver-visible invalidation events to registered GPU TLBs.

Evidence to record:
- TLB invalidation count.
- PWC invalidation count.
- VMID or address scope.
- Last translation state before the failed signal, packet, or memory access.

## Kernarg Physical Range Capture

Question:
- Did dispatch setup record the physical ranges backing the kernarg segment?
- Are system-memory kernarg ranges distinguished from device-memory ranges?

Checkpoints:
- `third_party/gem5/src/gpu-compute/gpu_command_processor.cc`: dispatch setup reads kernel metadata, translates kernarg ranges, and records them on the task.
- `third_party/gem5/src/gpu-compute/hsa_queue_entry.hh`: task state stores kernarg address, size, and translated physical ranges.

Evidence to record:
- Kernarg virtual address and size.
- Translated physical ranges.
- Whether each range is system memory or device memory.
- Dispatch id or task id that owns the range.

## SQC and GL2 Maintenance

Question:
- Does dispatch-boundary maintenance cover the scalar path that will read kernarg data?
- Does GL2 invalidation complete before shader execution starts?

Checkpoints:
- `third_party/gem5/src/gpu-compute/shader.cc`: `Shader::prepareInvalidate()` performs dispatch-boundary invalidation work before kernel execution.
- `third_party/gem5/src/gpu-compute/compute_unit.cc`: `ComputeUnit::doSQCInvalidate()` and `handleSQCReturn()` cover SQC invalidation and completion.
- `third_party/gem5/src/mem/ruby/system/VIPERCoalescer.cc`: TCC/GL2 invalidation callbacks show whether Ruby-side cache maintenance completed.

Evidence to record:
- SQC invalidation count and completion marker.
- GL2/TCC invalidation count and callback order.
- Shader execution start marker.
- First CU scalar-load address for the kernarg path.
