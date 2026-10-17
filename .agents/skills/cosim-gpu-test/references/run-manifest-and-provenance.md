# Run Manifest And Provenance

Read this when a cosim test task uses automation, repeats, environment rows,
non-default binaries, or evidence that must prove an uncommitted source state.

## Manifest Gate

Before automation, write or append
`artifacts/<task-slug>/tests/run-manifest.tsv`. Each row must name:

- exact program identity
- mode: `fresh_session`
- repeat count
- timeout policy
- literal `GUEST_TEST_PREFIX`, if any
- expected `HSA_ENABLE_INTERRUPT`
- gem5 binary path
- gem5 config arguments, if any
- run id and console log path
- expected failure artifact directory under `artifacts/<program>/<run-id>`
- matrix path
- provenance file
- literal runner argument
- guest bridge path policy, when the runner uses a host-created script or
  temporary output directory that must be visible inside the guest

Automation may execute only complete rows. Do not infer the target from nearby
filenames, prior conversation, partial filters, or failed discovery commands.
`--all` is valid only when the user explicitly requests all tests or the active
plan names it as the scope.

If a row has ambiguous program identity, conflicting timeout policy, unknown
guest environment, missing artifact path, missing matrix path, missing
binary/provenance data, or a mode mismatch, record a preflight failure and do
not launch it.

Artifact paths and guest bridge paths are different concerns. The artifact
directory is the durable evidence destination and may follow local host storage
policy. The guest bridge path is a transient path used by scripts executing
under `/mnt`; it must resolve inside the mounted share without relying on host
absolute paths or symlinks that leave the share. Prefer a configurable
repository-relative bridge path, archive the bridge script and guest output into
the artifact directory, and remove transient bridge contents during cleanup.

## Artifact Resolution

The run id and program name determine the guest-test failure directory.
Launcher failures use the standalone directory. Set a console log path under
the task artifact directory before launch. Resolve the failure artifact from:

1. `metadata.txt` run id and program name
2. `artifacts/<program>/<run-id>` for guest-test failures
3. `artifacts/standalone/<run-id>` for launcher failures

Zero or multiple matches is a checkpoint failure. Do not accept the row until a
single exact artifact directory is recorded.

## Acceptance Checks

Final acceptance must come from the executed command and captured logs, not
from the manifest alone. Verify:

- the runner exit status and exact program identity
- the console log and, on failure, runner metadata and simulator logs
- the effective guest settings recorded for the run
- the gem5 source revision, selected binary path and binary checksum

If source snapshot fails, classify the row as evidence-incomplete. Binary
provenance can identify the executable, but cannot replay uncommitted source
changes by itself.

## Build Gate

For review, RLCR, debug validation, and PR evidence, use the build and
provenance gate from `cosim-gpu-build`. Pass the standard gem5 binary
explicitly when needed:

```bash
RUN_DIR="artifacts/<task-slug>/<program>"
mkdir -p "$RUN_DIR"
GEM5_BIN="$(just --evaluate gem5_build_dir)/gem5.opt"
COSIM_RUN_ID="task-001" just test-gpu \
  --gem5-bin "$GEM5_BIN" \
  --screen-log "$RUN_DIR/qemu-console.log" \
  --test-timeout 120 \
  <program>
```

The test recipe passes `--gem5-bin` to the launcher. Use the build policy to
record the selected source revision and binary checksum; do not infer them
from the binary path alone.
