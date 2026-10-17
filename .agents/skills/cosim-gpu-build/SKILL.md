---
name: cosim-gpu-build
description: Use when building gem5, QEMU or m5, or checking their build inputs and binary provenance. Use the top-level just recipes.
---

# Cosim Build

Build simulators through the top-level `justfile`. The source submodules live
under `third_party/`, and build outputs stay under the repository's `build/`
directory.

## Build recipes

```bash
just dev-image
just build-gem5
just build-qemu
just build-m5 x86
```

Use `just build-m5` without an argument to select the host ABI. Pass `x86` for
the ROCm guest image profile. `just build-gem5 1` limits gem5 compilation to one
job when linking runs out of memory. The recipes select the host or development
container through `COSIM_ENV`.

## Source and output paths

| Component | Source | Default output |
|-----------|--------|---------------|
| gem5 | `third_party/gem5/` | `build/gem5/<host-architecture>/VEGA_X86/gem5.opt` |
| QEMU | `third_party/qemu/` | `build/qemu/qemu-system-<host-architecture>` |
| m5 | `third_party/gem5/util/m5/` | `build/m5/<abi>/out/m5` |

`GEM5_BUILD_DIR` can select another output directory under the repository's
`build/`. It does not select a different gem5 source tree. Inspect the selected
path with:

```bash
just --evaluate gem5_build_dir
```

## Build provenance

Read `references/build-policy-and-provenance.md` before deciding whether a
binary matches the checked-out sources or accepting build evidence. Read
`references/worktree-incremental-build.md` when building from an isolated
cosim-gpu worktree.

Use the binary at the selected output path when launching or testing. CI runtime
artifacts include a manifest with the source revision, build key and artifact
checksums.

Do not invoke `scripts/build.sh`, raw `scons`, QEMU `configure`, `make`, or
Docker build commands directly. Use the corresponding `just` recipe.
