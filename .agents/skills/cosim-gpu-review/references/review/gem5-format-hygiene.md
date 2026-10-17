# Gem5 Format Hygiene Review

Use this reference when reviewing gem5 changes that may contain formatter churn,
commit splitting mistakes, or mixed style and behavior edits.

## Goal

Keep behavior commits semantically reviewable. Formatting is acceptable only
when it is limited to touched hunks and immediate context, or when it is
isolated in a confirmed formatting-only commit.

## Required Checks

1. Inspect every reviewed commit individually. A later commit that removes or
   rewrites the same function does not excuse style-only churn in an earlier
   behavior commit.
2. Compare ordinary diff output with whitespace-ignored output:
   `git -C third_party/gem5 diff --stat <base>..<head>` and
   `git -C third_party/gem5 diff -w --stat <base>..<head>`. For single commits, replace
   the range with `<commit>^!`.
3. Check formatter scope before accepting the patch. Prefer gem5 modified-range
   tooling such as `util/run-git-clang-format.py --pre-commit`, `git-clang-format
   --diff <base> HEAD --style=file`, or `util/style.py -m` from inside the
   `third_party/gem5/` worktree.
4. Run `git -C third_party/gem5 diff --check <range>` or the equivalent staged range check
   before final acceptance.
5. When formatter churn is found in a behavior commit, classify it as a commit
   hygiene defect until the churn is moved to a formatting-only commit or
   removed from the behavior diff.

## High-Risk Areas

Always scan these areas manually because formatters often change them without
changing behavior:

- log and diagnostic calls, including `DPRINTF`, `panic`, `warn`, and fatal
  messages
- long format strings and argument wrapping
- function signatures and multi-line call sites
- lambda capture lists
- pointer and reference declarations
- short helper methods that a formatter expands or collapses
- local boolean conditions and arithmetic expressions wrapped only for column
  width

## Gem5 Formatter Caveat

Gem5 has repository style tooling, but broad formatter ranges can still rewrite
old code toward the current `.clang-format` approximation. That output may be
style-correct yet unrelated to the behavior under review. Treat the modified
range as part of the evidence: if the range is wider than the true semantic
change, the resulting diff is not acceptable in a behavior commit.

## Evidence To Record

Record these items in the review artifact:

- base and head commit hashes plus commit messages
- per-commit diff command used for inspection
- ordinary and whitespace-ignored diff stats
- formatter command and range
- any isolated formatting-only commit subject
- final statement that behavior commits contain no unrelated formatter churn
