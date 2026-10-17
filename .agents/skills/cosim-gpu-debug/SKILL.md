---
name: cosim-gpu-debug
description: "Use as the main entry for cosim debugging: gem5 crashes, assertions, hangs, timeouts, address translation faults, non-PASS test results, guest-side waits, and QEMU exits that may be secondary to gem5. Collect logs, preserve live state when needed, route to gem5 model references, and decide the first failing component."
---

# Cosim Debug

Use this skill as the debugging entry point for non-PASS cosim behavior. Keep
the workflow evidence-first: identify the authoritative artifact, decide the
first failing component, then read only the reference that matches the observed
mechanism.

## Entry Guard

For debug requests, use this workflow directly. Do not search for retired debug
skills or older routing names. Translate historical dialogue into concrete
evidence fields: artifact path, failing command, program identity, run id,
environment row, first durable failure, live wait state, comparison row, and
source mechanism under inspection.

Environment variable questions are not debug evidence by themselves. Use
`cosim-gpu-test` for runner prefix handling and `cosim-gpu-rocm-stack` for ROCm meaning.
Return here when the environment row produces a non-PASS result or a live wait
state.

## Evidence Authority

Use `cosim-gpu-info-gathering` for broad artifact intake, prior conversation
review, or any task that may otherwise require scanning many logs. This debug
skill should reason from the compact evidence map before opening raw logs.

Start by classifying the artifact state:

| Artifact state | Action |
|---|---|
| `verdict.json`, `matrix.tsv`, and `patch/binary-provenance.txt` exist | Treat archived files as authority. |
| Runner row is incomplete and a matching process is alive | Take bounded live samples only when the active plan allows it. |
| Runner row is incomplete and dead | Rerun only the accepted manifest row through `cosim-gpu-test`. |
| Old row lacks gem5 log needed for ownership | Create a fixed rerun row with the same program, environment, timeout, and binary. |
| QEMU-visible failure has no matching gem5 evidence | Classify as provisional until gem5 log is available. |

Record the exact source and binary provenance before accepting any build or
test evidence. Use `cosim-gpu-build` for build rules; do not duplicate its checks
here.

## Observable Event Routing

For timeout, wait, and non-PASS rows, prefer a compact event summary before
reading broad logs. Debug flags such as `GPUWgProgress`,
`HSAPacketProcessor`, and `GPUCommandProc` are event sources, not the
classification model. Different logs may fill the same observation dimension.

Use `references/analysis/observable-dimensions.md` to map available logs into
standard dimensions:

- progress: dispatch count, completion count, active wave state
- queue: read pointer, write pointer, dispatch pointer, packet completion
- signal: completion signal address, signal write, interrupt or event wakeup
- pressure: SQC retry, Ruby rejection, BufferFull, DMA or cache backpressure
- failure: fatal, panic, assertion, translation fault, QEMU exit

The preferred artifact tables are `coverage.tsv`, `progress.tsv`,
`queue.tsv`, `signals.tsv`, and a short `diagnostic-summary.tsv`. Blank
dimensions mean the evidence was not collected; `UNEXPLAINED` means the
dimension was checked and no useful difference was found. Missing dimensions
should guide the next minimal debug flag rather than trigger broad log reads.

## Common Evidence Workflow

Collect these facts before proposing a source edit:

- Program path, run id, interrupt mode, timeout value, and exact runner command.
- Full gem5 log, QEMU log, guest log, verdict, matrix row, and binary
  provenance.
- First durable failure line and the last 50-100 relevant lines before it.
- Nearest passing comparison or a note explaining why none exists.
- First object that differs: packet id, queue id, doorbell offset, signal
  address, PASID, VMID, GPU virtual address, physical address, PTE value,
  callback id, or interrupt cookie.

Use focused searches first:

```bash
rg -n 'fatal|panic|assert|PM4|SDMA|VMID|PASID|doorbell|interrupt|signal|GART|PTE|translation|fault|timeout|Broken pipe|error_setv' \
  <artifact>/logs/gem5.log <artifact>/logs/qemu.log <artifact>/logs/guest
```

## Component Decision

Choose the next action from the first durable evidence:

| Evidence | Action |
|---|---|
| gem5 log ends with `fatal`, `panic`, assertion, or container exit | Inspect gem5 logs and load `references/gem5-model/overview.md`. |
| QEMU shows `error_setv`, vfio-user abort, socket close, or `Aborted` while gem5 may have exited | Treat QEMU as secondary until `references/qemu/error-setv-pattern.md` and gem5 logs say otherwise. |
| gem5 log shows `User translation fault`, `GART`, unmapped page, VMID/PASID, PTE, or doorbell evidence | Load `references/gem5-model/address-translation-fault.md`. |
| Workload is alive but output and progress counters stop changing | Keep the guest alive and load `references/analysis/live-wait-state.md`. |
| Workload times out while dispatch and completion keep changing | Classify as throughput, scale, or timeout-budget evidence before editing model code. |
| Non-PASS result has no crash | Use `references/analysis/debug-analysis.md` and `references/analysis/observable-dimensions.md`. |
| cache, signal, PM4, VMID, PASID, SDMA, TLB, or PWC appears in logs | Load the matching gem5 model reference. |

For the known MAP_QUEUES VMID assertion, inspect:

```bash
grep -n 'assert.*vmid\|assert(queue_vmid)\|MAPQueues' \
  third_party/gem5/src/dev/amdgpu/pm4_packet_processor.cc
```

Then read:

- `references/gem5-model/vmid-assert-lesson.md`
- `references/gem5-model/examples/vmid-assert-crash.md`
- `references/gem5-model/vmid-pasid-architecture.md`

## Timeout and Wait Workflow

Read `references/analysis/debug-workflows.md` for timeout, wait-state, and
throughput workflows after the artifact summary identifies the missing
dimension or live state.

## Performance Optimization Workflow

Read `references/analysis/debug-workflows.md` when the active objective is
simulator efficiency rather than functional correctness.

## Address Translation Fault Review

Use this when gem5 shows `User translation fault`, `GART cosim`, unmapped page,
PTE diagnostics, VMID/PASID mismatch, or unknown doorbell evidence near a
crash. Read `references/gem5-model/address-translation-fault.md`.

Minimum notes before editing:

- failing program, run id, HSA interrupt value, and nearest passing row
- first gem5 fatal line and any secondary QEMU socket or `error_setv` symptom
- faulting GPU virtual address, physical address if any, PTE value, GART base,
  page-table base, VMID, PASID, queue id, and doorbell offset
- PM4, SDMA, or HSA packet sequence immediately before the failing translation
- whether the fault is deterministic across interrupt modes

QEMU `error_setv`, EOF, broken pipe, and device-lost messages are secondary
when gem5 logs contain an earlier translation fatal for the same run id.

## Script Discipline

Read `references/analysis/debug-workflows.md` before adding debug scripts or
source instrumentation.

## Guest Inspection

Use `cosim-gpu-guest` for console transport and guest command injection. Gather:

- PCI device state for the emulated GPU
- loaded amdgpu module state
- `cosim-gpu-setup.service` status
- ROCm device visibility and agent enumeration
- full and filtered kernel logs
- target process id, thread table, wait channel, kernel stacks, file
  descriptors, and user-space backtrace when the target remains live

## Patch Readiness

Read `references/analysis/debug-workflows.md` before deciding that a source edit
is ready.

## QEMU Trace

Trace the standard vfio-user transport when QEMU-side protocol evidence is
needed:

```bash
./scripts/cosim_launch.sh --qemu-trace 'vfio_user_*'
```

Record the exact launch command and trace log with the run artifacts.

## References

- `references/analysis/debug-analysis.md` - fact recording and comparison guide
- `references/analysis/observable-dimensions.md` - observable dimensions checklist
- `references/analysis/live-wait-state.md` - live guest wait-state sampling
- `references/analysis/debug-workflows.md` - timeout, performance, script, and patch-readiness workflows
- `references/gem5-model/overview.md` - gem5 MI300X model map
- `references/gem5-model/discovery-log.md` - prior model discoveries
- `references/gem5-model/cache-coherence-checkpoints.md` - TLB, PWC, SQC, GL2 checkpoints
- `references/gem5-model/address-translation-fault.md` - GART, PTE, VMID/PASID, and doorbell fault review
- `references/gem5-model/hsa-signal-completion-pattern.md` - HSA signal completion design
- `references/gem5-model/vmid-pasid-architecture.md` - VMID/PASID semantics
- `references/gem5-model/vmid-assert-lesson.md` - MAP_QUEUES VMID assertion lesson
- `references/qemu/qemu-first-failure.md` - QEMU-first failure reference
- `references/qemu/error-setv-pattern.md` - QEMU error propagation pattern
