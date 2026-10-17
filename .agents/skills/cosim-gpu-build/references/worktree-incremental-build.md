# Isolated Build Worktrees

Use a complete cosim-gpu worktree when a task needs an isolated gem5 source
revision and a build produced from that revision. The simulator build recipes
read gem5 from that worktree's `third_party/gem5/` submodule and write outputs
to that worktree's top-level `build/` directory.

## Build in an isolated worktree

1. Create a cosim-gpu worktree at the required project revision.
2. Initialize its gem5 submodule:

   ```bash
   git submodule update --init --recursive third_party/gem5
   git -C third_party/gem5 rev-parse HEAD
   ```

3. Build through the worktree's top-level recipes:

   ```bash
   just build-gem5
   ```

4. Record the worktree's project commit, gem5 gitlink revision, selected
   `GEM5_BUILD_DIR`, and binary checksum. Use that worktree's exact binary for
   any test that claims evidence for its source revision.

## Output and source boundaries

- gem5 source: `third_party/gem5/`
- default gem5 output: `build/gem5/<host-architecture>/VEGA_X86/`
- QEMU source: `third_party/qemu/`
- default QEMU output: `build/qemu/`
- m5 source: `third_party/gem5/util/m5/`
- m5 output: `build/m5/`

`GEM5_BUILD_DIR` selects an output location under `build/`. The build recipe
does not accept a separate gem5 source directory. A standalone worktree created
inside the gem5 submodule is therefore not selected by `just build-gem5`.

Build outputs are worktree-local. Do not copy an output directory into a
different worktree and treat its binary as current without rebuilding and
recording which source revision produced it.
