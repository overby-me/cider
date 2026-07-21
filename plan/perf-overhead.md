# Reducing Darling runtime overhead toward Wine

## Goal

Cut Darling's per-operation and per-process overhead so running/building macOS
programs (configure/make/bash/hello) is closer to Wine's near-native cost.

## Core insight

Wine is thin because Win32 userspace maps onto Linux syscalls **in-process**, and
`wineserver` is consulted only for shared kernel state; its landmark win was
**esync/fsync** (eventfd/futex waits in userspace, no server round-trip). Darling
is thick because macOS is Mach-based and Darling emulates XNU in **darlingserver**,
routing Mach IPC, task/thread/port objects, signals, synchronization, and service
lookups through a Unix-socket RPC (context switch + copy per round-trip).

**The lever is the same lesson: move hot paths in-process and delete darlingserver
round-trips.**

## Candidate hot paths, ranked for build/run workloads

1. **Per-process startup.** configure/make fork thousands of tiny processes; each
   pays mldr + dyld + darlingserver task registration. Ensure the dyld shared
   cache is used; defer framework init; trim the registration handshake.
2. **Synchronization ("fsync for Darling").** Map `__ulock_wait`/`__ulock_wake`
   (and psynch mutex/cond) onto Linux `futex(2)` in-process instead of an RPC.
3. **getpwuid / DirectoryService.** Observed ~133 `getpwuid` Mach round-trips in
   one ./configure; short-circuit to an in-process /etc/passwd read + cache.
4. **BSD syscall passthrough.** Maximize inline macOS→Linux syscall translation in
   libsystem_kernel vs bouncing to darlingserver.
5. **mach_msg fast paths.** Handle same-task / local-port messages in-process.

## Method: measure → fix → re-measure

- `scripts/darling-perf-probe.sh` counts darlingserver socket round-trips
  (`sendmsg`/`recvmsg` on the dserver fd) and `futex` calls via `strace -f -c`,
  and times per-process startup (`darling shell true` loop). Run it on: (a) a bare
  `sh -c true`, (b) a `getpwuid`/`id`-heavy snippet, (c) a small configure
  fragment. The histogram tells us which candidate dominates *this* workload
  before writing code.
- Implement the top win, rebuild the relevant component, re-run the probe, compare.

## Iteration cost

- Changes in libsystem_kernel / libsyscall (ulock, syscall dispatch, mach_msg):
  rebuildable per-edge via **nix-ninja** (`darling-kernel-ninja` target) for a fast
  loop, or the monolithic build.
- Changes in **darlingserver** need the darlingserver build (monolithic darling,
  ~minutes).

## Findings (investigation + measurement)

Static analysis (agent) + dynamic profiling reshaped the picture. Several
suspected hot paths are already optimal:

- **BSD syscalls** (read/write/open/stat/fork) dispatch table-driven to direct
  Linux syscalls — no RPC. `openat` only RPCs for the `/dev/console` special case.
- **`__ulock_wait`/`__ulock_wake`** already map straight to Linux `futex(2)`
  in-process (the "fsync for Darling" is done for the ulock path).
- **Path translation** (`vchroot_expand`) is in-process after a one-time prefix
  fetch — no per-`open` RPC.
- **`mach_task_self()`/`mach_host_self()`** are `#define`d to globals set once at
  init — already cached; the VM traps read the global, no RPC.
- getpwuid is glibc NSS, not a server RPC.

What actually dominates: I profiled **darlingserver's own syscalls** while it
served 200 `uname` process spawns (strace attached to the daemon, which lives
outside the emulated userns so its RPC handling is visible). Result:

| syscall | total (200 spawns) | per spawn | note |
|---|---|---|---|
| getpid | 425,728 | ~2,128 | constant — daemon's own pid |
| getuid | 425,728 | ~2,128 | constant |
| getgid | 425,728 | ~2,128 | constant |
| futex | 39,609 | ~198 | internal locking (57% of *time*) |
| rt_sigprocmask | 56,021 | ~280 | |
| recv/sendmmsg | ~39,000 | ~195 | actual RPC I/O (batched) |
| **total** | **1,537,526** | ~7,687 | |

**getpid+getuid+getgid = 1.28M calls = 83% of darlingserver's entire syscall
volume**, roughly one of each per RPC message — all returning the daemon's own
constant identity. Root cause: `src/message.cpp` filled `struct ucred`
(SCM_CREDENTIALS) from live `getpid()/getuid()/getgid()` on *every* `Message`
(ctor line ~69, resize path line ~352).

## Fix implemented

`patches/darlingserver/0002-cache-darlingserver-own-credentials.patch`: cache the
daemon's `ucred` once via a thread-safe C++ magic static (`ourCachedCredentials()`)
and reuse it at both fill sites. Safe because darlingserver never changes uid/gid
after its startup root check and never forks (workers are threads sharing one pid;
managed processes are separate mldr-launched processes — verified no
`fork`/`clone`/`daemon` in its source). Eliminates ~1.28M syscalls per 200 spawns
(~6,400/spawn), i.e. the 83% bulk of darlingserver's syscall load.

## Status

- Fix written + carried as a submodule patch (validated: reverse-applies against
  the dirty tree ⇒ forward-applies clean). Measurement tooling committed
  (`scripts/darling-perf-probe.sh`, `scripts/measure-rpc.sh`-style attach probe).
- NEXT: rebuild darling, re-run the darlingserver-attach probe, record before/after
  (expect getpid/getuid/getgid → ~0 in the daemon's profile).
- FOLLOW-UPS ranked: (1) `rt_sigprocmask` ~280/spawn (the per-RPC signal-mask
  atomic section — investigate necessity); (2) `futex` ~198/spawn is 57% of *time*
  — darlingserver internal lock contention, the next structural target;
  (3) reduce raw RPC count/spawn (~195) via startup-handshake batching.
