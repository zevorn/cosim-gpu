# Independent Review Contract

Use this contract from `cosim-gpu-review`, `cosim-gpu-rlcr-loop`, and
`cosim-gpu-codex-review` whenever an independent reviewer is used.

## Brief Isolation

The reviewer starts from a written brief, not from the implementer's
conversation state. The brief may include:

- confirmed target from `plan.md`
- reviewed base, current `HEAD`, ancestry status, and file scope
- exact diff commands or scoped diffs
- required tests, matrix rows, verdicts, logs, and provenance paths
- prior public review comments

The brief must not include the implementer's intended fix, suspected mechanism,
private rationale, or dialogue-derived conclusions unless those claims are
already recorded in an artifact with command, path, and observed result.

## Reviewer Checklist

Ask the reviewer to inspect:

- new bugs introduced by the diff
- caller and callee contracts, assertions, initialization, and local invariants
- completion, callback, cleanup, and error paths that must execute exactly once
- ownership of memory, events, descriptors, and context values
- sibling call sites, wrappers, callbacks, reverse-direction operations, and
  default arguments that may still contain the same bug pattern
- formatter churn, debug leftovers, unrelated scope expansion, and commit hygiene
- whether tests prove the requested programs, current source, rebuilt binary,
  and `cosim-gpu-build` provenance gate
- whether each finding still applies to current `HEAD` when the reviewed change
  is historical

## Source And Verification Rules

Source optimization edits target checked-out `HEAD`. Historical commits may
define review intent, but fixes and cleanup apply to current files unless the
user explicitly requests history rewriting.

After any accepted source or behavior change, run the standard incremental
build through `cosim-gpu-build` and rerun affected rows. This is mandatory
verification inside the confirmed target, not a separate approval point. If the
execution platform blocks the command, request only the narrow build-script
authorization.

Source edits must use diff-scoped formatting. Whole-file or project-wide
formatter churn mixed with behavior changes fails review hygiene unless the
task is explicitly formatting-only. When formatter scope is in question, record
normal and whitespace-ignored diff stats.

For gem5 source changes, use gem5 repository tooling from inside `third_party/gem5/`.
Generic top-level format checks do not prove gem5 CI style.

## Evidence Records

Each independent review round records:

- the brief
- reviewer output
- maintainer audit
- disposition for each finding: accepted, rejected, fixed, or deferred with
  reason
- final build, provenance, and test evidence after accepted changes

Non-PASS rows go through `cosim-gpu-debug` or are recorded as invocation errors
with the artifact path and verdict reason.
