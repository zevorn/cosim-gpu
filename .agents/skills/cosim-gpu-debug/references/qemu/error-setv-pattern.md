# QEMU error_setv Double-Set Pattern

Reference for diagnosing and fixing the `error_setv` assertion failure in QEMU.
Discovered during cosim vfio-user launch debugging (June 2026).

## Mechanism

QEMU's error reporting convention uses `Error **errp` — a pointer to an
error pointer. The invariant: `*errp` must be `NULL` when a new error is set.

```c
// util/error.c:51-62
static void error_setv(Error **errp, ...) {
    if (errp == NULL) {          // L59: NULL → harmless, return immediately
        return;
    }
    assert(*errp == NULL);       // L62: *errp already set → SIGABRT
}
```

Key behaviors:
- `errp == NULL`: callee does not want error detail → `error_setv` returns early (no crash)
- `errp != NULL && *errp == NULL`: normal path — first error is set
- `errp != NULL && *errp != NULL`: **assertion fires** — a second error is being set on a dirty `*errp`

## The anti-pattern

Passing the same `Error **errp` to two functions that can both set errors:

```c
// ANTI-PATTERN (proxy.c:234-241, also present in upstream QEMU master):
ret = qio_channel_readv_full(proxy->ioc, &iov, 1, fdp, numfdp, 0,
                             errp);   // ← this may set *errp on failure (ECONNRESET)
if (ret < 0) {
    error_setg_errno(errp, errno, "failed to read header");
    // ↑ tries to set *errp again → assert(*errp == NULL) fails → SIGABRT
}
```

## The fix pattern

Use a local `Error *` to decouple the two error-setting calls:

```c
// FIX:
Error *local_err = NULL;
ret = qio_channel_readv_full(proxy->ioc, &iov, 1, fdp, numfdp, 0,
                             &local_err);  // isolate the inner error
if (ret < 0) {
    error_propagate_prepend(errp, local_err, "failed to read header: ");
    // local_err is consumed; *errp is only set once
}
```

`error_propagate_prepend` transfers ownership of `local_err` to `*errp`
(with a prefix message), so `*errp` is set exactly once.

## Identifying the pattern

Search QEMU source for any function call that passes `errp` as argument
followed by another error-set call on the same `errp`:

```bash
# Find potential double-set sites in QEMU
search pattern="error_set[gv]_errno\(errp" paths=["third_party/qemu/"]
# Cross-check: does the immediately preceding call also receive errp?
```

Additional risk: `error_report_err` + `error_free` is safe (it reads and clears
`*errp`), but `error_report_err` alone leaves `*errp` set → next `error_setv`
crashes if it receives the same `errp`.

## Crash chain: gem5 → QEMU secondary failure

The common trigger in cosim: gem5 crashes → socket closes → QEMU sees
ECONNRESET → the double-set path is reached.

```
gem5 assert/crash → socket disconnect
  → QEMU vfio_user_recv_hdr sees ECONNRESET
  → qio_channel_readv_full sets *errp (ECONNRESET)
  → error_setg_errno tries to set *errp again → SIGABRT
```

**The QEMU double-set is a defensive bug**: it should never happen in normal
operation, but it should also never crash when it does happen. The gem5 crash
is the first failing component; the QEMU crash is a secondary effect that masks
it.

## GDB debugging

When the crash is inside QEMU, use a conditional breakpoint to isolate the
real trigger (avoid stopping on harmless `errp == NULL` paths like SGX init):

```gdb
# Only break when the assertion would actually fire
break error.c:62 if *errp != NULL

# Or from command line:
gdb -q -batch \
  -ex 'break error.c:62 if *errp != NULL' \
  -ex run \
  -ex 'bt full' \
  --args build/qemu/qemu-system-x86_64 [args...]
```

## Upstream status

This bug exists in upstream QEMU (`gitlab.com/qemu-project/qemu`, master)
at `hw/vfio-user/proxy.c:234-241`. The same fix applies.

## Cross-references

- `qemu-first-failure.md`: QEMU-first failure checks
- `../gem5-model/vmid-assert-lesson.md`: the specific instance of this pattern in cosim (gem5 `assert(queue_vmid)` → QEMU double-error crash)
- `../analysis/debug-analysis.md`: gem5 vs QEMU first-failure comparison
