---
name: cosim-gpu-repo-maintenance
description: Use for cosim-gpu repository maintenance that is not cosim execution: submodule pointers, commit splitting, history rewrite for local commits, staged-index cleanup, author/signoff checks, ignore rules, skill hygiene audits for sensitive literals or unwanted coupling, skill routing validation after skill instruction changes, and keeping generated artifacts out of commits. Separates general Git practice from cosim-gpu-specific repository policy.
---

# Cosim Repo Maintenance

Use this skill for repository hygiene in the cosim-gpu repository when the task
does not need cosim build, launch, test, debug, review, or RLCR evidence.

Examples:

- locate or update a submodule under `third_party/`, or edit the vendored
  `.agents` skill files
- split a large local commit
- rewrite local unpushed commits for better topic boundaries
- audit skill files for sensitive literals or unwanted coupling
- validate skill routing after skill instruction changes
- inspect staged, unstaged, and untracked files before committing
- keep logs, artifacts, build outputs, and scratch files out of history
- verify commit author and `Signed-off-by`
- update ignore rules for generated outputs

Do not use `cosim-gpu-flow-plan` for ordinary repository maintenance. If the
task starts requiring cosim test evidence, switch to the matching cosim domain
skill.

## General Git Practice

These are general rules, not project-specific behavior:

- Inspect before changing: `git status --short`, `git diff --stat`,
  `git diff --cached --stat`, and submodule status when relevant.
- Keep commits topic-scoped and reviewable.
- Do not include unrelated working-tree changes.
- Do not rewrite commits that may already be shared unless the user explicitly
  asks.
- Prefer path-limited `git add` and `git commit` over broad staging in a dirty
  tree.
- Never use destructive checkout or reset commands to discard unknown changes
  without explicit user direction.

## Project-Specific Rules

Read `references/cosim-gpu-repo-policy.md` before changing submodule pointers,
editing skill files, or preparing project commits.

## Maintenance Workflow

1. Record repository state:

   ```bash
   git status --short
   git submodule status
   git diff --stat
   git diff --cached --stat
   ```

2. Classify changes by owner:

   - top-level repository files, including vendored `.agents` skills
   - `third_party/gem5` source submodule
   - `third_party/gem5-resources` resource submodule
   - `third_party/qemu` source submodule
   - generated artifacts or local scratch

3. Commit inside the affected submodule before recording its superproject
   gitlink. `.agents` changes are ordinary top-level changes.

4. For commit splitting, group by behavior and ownership. Keep generated
   output, logs, `artifacts/`, `m5out/`, and scratch files out unless the user
   explicitly asks to preserve a small source artifact.

5. After changing skill instructions, run a routing validation pass:

   - list 3-5 realistic user prompts affected by the change
   - map each prompt to the expected skill or expected no-skill path
   - compare against the skill frontmatter descriptions currently visible to
     the agent
   - check that the first loaded instructions would route to the intended
     reference files or scripts
   - record any prompt that still risks stale behavior or overbroad matching

   This is a skill-design check, not cosim execution evidence.

6. Before final reporting, show current `third_party/` submodule pointers and
   remaining dirty files.

## Commit Messages

Use normal project style and include `Signed-off-by` from:

```bash
git config user.name
git config user.email
```

Do not add AI assistant identities to trailers.
