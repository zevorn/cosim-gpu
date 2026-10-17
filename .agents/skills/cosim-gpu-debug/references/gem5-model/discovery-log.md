# Cosim gem5 AMD GPU Model — Discovery Log

Record of coherence and correctness discoveries from cosim stability debugging (May 2026).
Each entry captures what was found, the evidence that proved it, and where the fix was applied.
Use these as routing hints for new debugging sessions; each new case still needs its own evidence.

## 1. PWC not invalidated on full TLB flush

**Discovery**: May 2026, RLCR round 4-6. Repeated vector_add execution caused TLB entries to be reused across
sessions. `invalidateAll` cleared the TLB but not the page walk cache, so stale PTE fragments survived.

**Evidence**: Two-snapshot state comparison showed TLB empty after `invalidateAll` but PWC still held entries
matching the old page table. Next page walk returned stale PWC data without re-traversing.

**Fix**: `third_party/gem5/src/arch/amdgpu/vega/tlb.cc` — conservative full PWC invalidation on every full TLB flush.
Commit: `arch-amdgpu: invalidate PWC on full TLB flush`.

**Verification**: 200× vector_add with PWC invalidation: 0 TIMEOUT_WAIT (was ~3% failure rate before fix).

**Debug reference**: `cosim-gpu-debug` cache and translation evidence; see
`overview.md` and `cache-coherence-checkpoints.md`.

## 2. Kernarg L2 visibility gap

**Discovery**: May 2026, RLCR round 7-8. Command processor (CP) wrote kernarg data through a path that bypassed
GL2/L2, while compute unit (CU) scalar loads read through GL2. Stale L2 cache lines delivered old values.

**Evidence**: CP-side kernarg dump (instrumented) showed correct values; CU-side scalar load trace showed different
values for the same physical addresses. CP writes were systemReq (bypassing GPU GL2 path), CU reads went through
Ruby VIPER L2.

**Fix**: Track kernarg system memory ranges and invalidate GL2 cache lines for these ranges before kernel launch.
PR: `zevorn/gem5#1`.

**Verification**: `docs/silent_data_error_kernarg_l2_record.md` — kernarg validation pass after invalidation.

**Debug reference**: `cosim-gpu-debug` cache evidence; see `overview.md` cache
hierarchy and `cache-coherence-checkpoints.md`.

## 3. QEMU↔gem5 memory coherence gap

**Discovery**: May 2026. Under repeated execution, the ROCm runtime allocates new virtual addresses, reuses page
table pages, and updates PTEs. QEMU and gem5 share guest RAM via `/dev/shm/cosim-guest-ram`, but there is no
explicit coherence protocol: gem5 may see stale or missing PTEs if it accesses a page before QEMU's PTE update
propagates through the shared memory.

**Evidence**: Multiple instances of `TIMEOUT_WAIT` correlated with stale PTE values in gem5's TLB compared to
current values in QEMU's shadow page table.

**Status**: Partially addressed by PWC fix (#1 above) and cache coherence fixes (#2, #4). Full coherence
protocol between QEMU and gem5 is deferred.

**Debug reference**: `cosim-gpu-debug` translation and VMID evidence; see
`cosim-gpu-rocm-stack` KFD ioctls for unmap triggers.

## 4. ACQUIRE_MEM / RELEASE_MEM semantics incomplete

**Discovery**: May 2026. The gem5 model recognized ACQUIRE_MEM and RELEASE_MEM PM4 packets but did not perform
full cache maintenance. ACQUIRE_MEM with base=0, size=0xffffffffffffff00 (global) should invalidate code and
data caches, but the model only processed it for code objects, missing data cache invalidation.

**Evidence**: ROCm Compute Profiler documentation and gem5 PM4 packet traces showed ACQUIRE_MEM arriving before
kernel execution but the invalidation scope was narrower than hardware behavior.

**Status**: Investigated May 2026; fix scope reframed to specific cache-layer fixes (#1, #2) instead of full
ACQUIRE_MEM/RELEASE_MEM implementation.

**Debug reference**: `cosim-gpu-debug` PM4 packet comparison; see `overview.md`.

## 5. SQC (scalar L1) not invalidated on kernel launch

**Discovery**: May 2026. `prepareInvalidate` on kernel launch invalidated GL2 cache lines for kernarg ranges but
did not reach SQC. Scalar loads that hit SQC after a prior kernel execution could return stale values even when
GL2 was clean.

**Evidence**: Instrumentation showed SQC hit counts for kernarg addresses after GL2 invalidation completed.
Adding SQC invalidation eliminated residual wrong results.

**Fix**: Extended `prepareInvalidate` to include SQC invalidation for kernarg ranges.

**Debug reference**: `cosim-gpu-debug` cache evidence; see `overview.md` cache
hierarchy.

## 6. Interrupt VMID routing for multi-operation programs

**Discovery**: May-June 2026. Programs with both kernel execution and hipFree experienced signal timeout because
the RELEASE_MEM-triggered CP_EOP interrupt carried the wrong VMID. The driver's interrupt handler used the
interrupt cookie VMID to route the signal completion, but the cookie was populated from the last known VMID
rather than the correct MAP_PROCESS context.

**Evidence**: hipFree signal address traced through gem5 showed correct write, but interrupt cookie had vmid=0
instead of vmid=3. Driver received interrupt but could not match it to the waiting user process.

**Fix**: `third_party/gem5/src/dev/amdgpu/interrupt_handler.cc` — track VMID from MAP_PROCESS rather than lastVMID.
PR: `zevorn/gem5#4`.

**Debug reference**: `cosim-gpu-debug` signal, interrupt, translation, and VMID
evidence; see `overview.md` interrupt handling section.

## Cross-cutting lessons

1. **Cache coherence is layered**: Bug symptoms at one layer (signal timeout) often root-cause to another
   (PWC holding stale PTE). Check all cache layers before concluding.

2. **Repeated execution exposes coherence gaps**: Single-run tests mask stale-state bugs. Always verify with
   repeated-program matrices.

3. **CP vs. CU coherence domains**: The command processor and compute units access memory through different
   paths. What CP writes may not be visible to CU without explicit invalidation.

4. **Instrumentation must be non-invasive**: Adding debug prints that trigger cache lookups, TLB walks, or
   packet processing can change the failure pattern. Prefer passive observation on existing paths.
