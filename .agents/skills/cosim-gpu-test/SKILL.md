---
name: cosim-gpu-test
description: Use when running GPU programs against cosim and classifying outcomes. Requires exact program identity, fresh-session runner use, and build provenance. After cosim-gpu-flow-plan for planned test tasks.
---

# Cosim Test

Execute GPU programs against cosim in fresh sessions. The test runner owns
launching, guest execution, exit status, failure categories, diagnostic logs,
and session cleanup. Record build provenance through `cosim-gpu-build`.

Use `cosim-gpu-launch` only for manual boot or interactive inspection. Use this
skill whenever a program result, matrix row, verification result, or PR-grade
test artifact is required.

## Quickstart

```bash
just test-gpu vector_add
just test-gpu --all
just test-gpu --repeat 3 vector_add
just test-gpu --test-timeout 120 vector_add
just test-gpu --keep-alive vector_add
```

`just test-gpu` runs one program in a fresh cosim session. `--all` and
`--repeat N` start a fresh session for every program or repetition. Use
`--keep-alive` when a successful run must leave the guest available for manual
inspection; use `just run-launch` for a manual guest session.

Set `COSIM_RUN_ID` to make a run addressable. On failure, the runner records
the run id, category, program and exit code with the captured guest and
simulator logs.

## Required Gates

Before launching a named program, prove exact program identity. Read
`references/program-identity-and-guest-env.md` for local kernels, ROCm
examples, variants, timeout estimation, device-side `printf`, or
`GUEST_TEST_PREFIX`.

Before automated rows, repeats, environment matrices, non-default binaries, or
evidence intended to prove uncommitted source, read
`references/run-manifest-and-provenance.md`.

For long diagnostic rows, performance rows, matrix runs, or interrupted test
automation, read `references/diagnostic-and-matrix-runs.md`.

Use `cosim-gpu-build` for build readiness and binary provenance decisions. Do
not duplicate build metadata rules here.

## Automation Rule

When program identity, manifest rows, and required provenance checks are
complete, run the `just test-gpu` recipe. Do not ask before standard
test execution, repeats, interrupt-mode matrix rows, timeout probes, post-fix
reruns inside the current scope, standard incremental build, or standard
preflight cleanup.

Ask only before changing target program, changing fixed environment values,
using a nonstandard binary, full or cold rebuilds, deletion outside repository
cleanup scripts, or switching from normal test mode to live debug mode when the
target is not already known to hang.

## Result Classification

The runner exit status reports the guest program result. On failure, use the
recorded category and logs from the corresponding artifact directory. Treat
launcher or guest boot failures as infrastructure evidence rather than a
program result.

| Exit status | Meaning | Action |
|-------------|---------|--------|
| `0` | Program completed successfully | Record the exact program and run id |
| nonzero | Program or launcher failed | Route by the recorded category and logs |

If QEMU or gem5 exits before the guest test starts, treat it as launcher or
backend evidence rather than a program result.

## Integration

- Before planned test work: `cosim-gpu-flow-plan --type test`
- Before accepting evidence: build/provenance gate from `cosim-gpu-build`
- Before launch: `just run-preflight`
- After any non-PASS row: `cosim-gpu-debug`
- Output authority: runner exit status, failure category and logs, plus the
  source and binary provenance recorded for the run

For each recorded run, preserve program identity, outcome, artifact path, gem5
source revision, selected binary path and binary checksum. Manifest values are
pre-run contracts, not proof of execution.
