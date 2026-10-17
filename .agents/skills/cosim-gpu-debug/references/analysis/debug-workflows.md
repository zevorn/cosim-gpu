# Debug Workflows

Read this from `cosim-gpu-debug` after the first durable evidence identifies a
timeout, wait state, performance objective, or source-edit candidate.

## Timeout And Wait

Separate timeout evidence into three classes:

- No guest business output: verify build, executable path, runtime loader, and
  guest command before model debugging.
- Guest output advances to a named workload phase: add bounded dispatch and
  completion progress diagnostics.
- Dispatch/completion counters advance until timeout: treat it as scale or
  model-throughput evidence unless a later snapshot shows a fixed wait state.

For long timeout rows, use script-produced summaries when available. Read raw
log windows only after the summary names a missing dimension or a specific
event source and line range.

For known wait-state investigation, do not use the normal timeout wrapper. It
can kill the target process that holds useful state. Use `cosim-gpu-guest` and
take two bounded samples that agree on process id, thread states, wait
channels, kernel stacks, user-space backtraces, and absence of new target
output.

Choose the next debug flag from the missing dimension:

| Missing dimension | Minimal next source |
|---|---|
| dispatch or completion count | `GPUWgProgress` |
| queue read/write or packet completion | `HSAPacketProcessor` |
| completion signal write or EOP path | `GPUCommandProc` |
| fetch retry or Ruby rejection | SQC/Ruby focused flags |
| live userspace wait state | `cosim-gpu-guest` live wait sampling |

## Performance Optimization

Use this when the active objective is simulator efficiency rather than
functional correctness. Keep the parent goal and candidate stage separate: a
candidate can be evaluated and rejected while the broader search remains active.

Before proposing a performance patch, build four evidence views when available:
host CPU profile, gem5 event or callback breakdown, Ruby/GPU path counters, and
guest workload timing. Separate guest boot and runner framework time from the
target workload window.

For each candidate, use one isolated worktree, one explicit gem5 binary, one
per-row output directory, one candidate-only diff, and one full reconstructable
diff.

Rank candidates by end-to-end effect, not by local counter reduction alone. If
a candidate reduces a hot function, event, or callback but runner wall time or
workload window remains flat, record it as local cleanup or secondary
optimization.

For event-loop or polling changes, preserve protocol progress semantics. A
candidate that reduces empty calls but increases scheduler events, fails boot,
or changes vfio-user progress behavior is rejected unless a follow-up row proves
both PASS and end-to-end improvement.

## Script Discipline

- Use `just build-gem5`, `just test-gpu`, `just run-launch`, and
  `just run-preflight` for simulator builds, guest tests, manual launches, and
  read-only resource checks.
- Prefer fixed manifest rows over ad hoc loops.
- Add parameters only when the evidence needs them and record each value in the
  artifact.
- Do not bypass provenance hooks.
- Preserve runner exit code, verdict, matrix row, and logs.
- Keep diagnostic source instrumentation behind debug flags when possible.

## Patch Readiness

A source edit is ready only when notes identify:

- failing command and exact program path
- first failing component, with log lines or backtrace
- nearest passing comparison or reason no comparison exists
- observed object that differs
- source location implementing the relevant mechanism
- verification plan using the same test runner and provenance checks

Use diff-scoped formatting for behavior fixes. Do not mix broad formatting with
debugging changes.
