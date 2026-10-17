# Build Policy And Provenance

Use the repository's `just` recipes to build simulator binaries. Source trees
are git submodules under `third_party/`; generated binaries and build metadata
belong under the top-level `build/` directory.

## Select the build

```bash
git submodule status
git -C third_party/gem5 rev-parse HEAD
just --evaluate gem5_build_dir
just build-gem5
just build-qemu
```

Use `just build-m5 x86` for the x86 guest profile. `GEM5_BUILD_DIR` changes the
gem5 output directory under `build/`; `just build-gem5` always reads sources
from `third_party/gem5/`.

## Verify a local binary

Find the selected gem5 binary using `just --evaluate gem5_build_dir`, then
record its checksum and the checked-out source revision:

```bash
git -C third_party/gem5 rev-parse HEAD
sha256sum "$(just --evaluate gem5_build_dir)/gem5.opt"
```

On x86_64 hosts, record `build/qemu/qemu-system-x86_64`. On AArch64 hosts,
record `build/qemu/qemu-system-aarch64`.

The source revision identifies the current submodule checkout. A binary
checksum identifies the executable. Rebuild with `just build-gem5` or
`just build-qemu` when a binary is missing or its build inputs changed.

## CI artifacts

The CI runtime artifact manifest records source identities, architecture,
build key, image identity and payload checksums. The cache is reusable only
when its build key and source revision match the current workflow inputs.
The CI workflow validates a restored artifact with
`just test-ci-artifact build/cache/gem5-runtime build/ci-build` before using
its binary or development image.

## Isolated source trees

The build recipe uses `third_party/gem5/` as its source. See
`worktree-incremental-build.md` before preparing an isolated cosim-gpu
worktree, so the selected source checkout and output directory remain explicit.
