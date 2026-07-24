# Official guest-Nix M1: `nix build #hello` from source under Darling

Status (2026-07-24): **the compiler blocker is FIXED and verified; the
end-to-end `hello_rc=0` run is now gated on a separate, pre-existing darlingserver
early-boot race.** hello's build reached configure and failed at the first clang
invocation. Root cause found and fixed: a single missing libc++ symbol
(`__libcpp_verbose_abort`), NOT the darlingserver concurrency bug it was first
attributed to. Fix committed in `patches/libcxx/0001`; the rebuilt monolith
(`inx96gmra`) exports the symbol and `clang`, `libLLVM` and `ld64` all show zero
top-level-`std::` gaps against Darling's 8419-symbol C++ runtime.

**Remaining e2e gate (separate issue):** driving the build to `hello_rc=0`
requires a clean darling container boot, and darling is currently hitting the
known early-boot SIGCHLD/RPC race (see the boot-race section at the bottom and
`plan/blockers.md`). The *same* boot binaries booted fine earlier this session
(they reached configure -- that is how the `conftest.err` above was captured), so
the race is timing/host-state dependent, not a regression from the libc++ change
(the old monolith fails identically now). A bounded, spaced overnight retry is
running to catch a good boot and finish the build.

The campaign goal (hello builds from source + runs under Darling) was already met
at the toolchain level (M1, `scripts/build-hello-under-darling.sh`: `hello_rc=0`,
"Hello, world!"). This doc is the *official* path -- driving the build through
guest `nix build` rather than hand-run configure/make.

## What works (was "3 sub-projects, not overnight" per 26.05-facts)

The pessimistic 26.05-facts assessment predates a key piece: **darlingserver.cpp
already implements a writable-`/nix` overlay** (host `/nix/store` + `/nix/var`
read-only lowers, tmpfs uppers, unprivileged `userxattr`), opt-in via a
`<prefix>/.enable-writable-nix` marker. With that, a single darling-shell session
(scripts/gnix-hello.sh) gets all the way to compiling hello:

1. **darwin nix runs under Darling** -- `nix (Nix) 2.34.8`.
2. **Writable native `/nix`** -- the overlay gives `nix_store_WRITABLE` +
   `nix_var_WRITABLE`; nix writes build outputs to the tmpfs upper.
3. **Local store, not the daemon** -- `NIX_STATE_DIR=/Users/root/nixstate` (a fresh
   guest-owned state dir; the inherited `/nix/var/nix/db` is owned by the unmapped
   host root in the rootless userns, so unwritable, and it has a daemon socket that
   makes nix auto-pick daemon mode). Also `NIX_LOG_DIR`, `HOME`, `TMPDIR` under
   `/Users/root` (`/tmp` is read-only in the container).
4. **Trust the pre-populated store** -- seed the fresh db with hello's **complete**
   build closure via `nix-store --dump-db` (host side) + `--load-db` (guest). The
   closure must be *complete*: `nix-store -qR --include-outputs` only lists *present*
   outputs, so the missing stdenv output was silently excluded until realised (see
   below). `sandbox = false`, `require-sigs = false`, `substituters = ""` (offline).
5. **No stdenv rebuild** -- on real macOS `nix build #hello` substitutes the whole
   closure (the darwin stdenv output is cached, HTTP 200) and builds only hello. The
   bootstrap intermediates (`bootstrap-stage0-stdenv-darwin`, HTTP 404) are only
   needed to *build* the stdenv, which we don't -- we fetch its output. Fix on the
   host: `nix-store -r` of hello.drv's input drvs (29 paths, 7.5 MiB) so the overlay
   presents the full closure to the guest.
6. **nix builds ONLY hello** -- unpackPhase, patchPhase, configurePhase run; ~15
   configure checks pass, each running nix-substituted tools (coreutils `install`,
   `mkdir`, gawk, gnutar, make) successfully under Darling.

## The blocker: one missing libc++ symbol (`__libcpp_verbose_abort`) -- FIXED

configure's compiler check (`checking whether the C compiler works`) failed at the
first `clang` invocation, two different ways across runs (a fork/exec **stall**
once, a **`SIGABRT`** the next). That variance *looked* like the darlingserver
fork/exec/SIGCHLD concurrency bug, and was first filed as such -- **wrong**.

Running the build with `--keep-failed` and reading clang's own stderr
(`conftest.err`) gave the real, deterministic cause:

```
dyld: Symbol not found: __ZNSt3__122__libcpp_verbose_abortEPKcz
  Referenced from: .../llvm-21.1.8-lib/lib/libLLVM.dylib (built for Mac OS X 14.0)
  Expected in: /usr/lib/libc++.1.dylib
```

That is `std::__1::__libcpp_verbose_abort(char const*, ...)`, the single
verbose-termination entry point libc++ gained in **LLVM 14**. Darling's libcxx is
**LLVM 13** and never exported it, so the nixpkgs LLVM-21 clang/libLLVM cannot be
loaded under Darling -- dyld aborts (the SIGABRT), or the aborting process leaves
the container in the stalled state that masqueraded as the concurrency bug.

**It is the only genuine libc++ gap.** `llvm-nm` over the *entire* nixpkgs clang
closure (every binary + dylib under `clang-21.1.8/{bin,lib}`), filtered to
top-level `std::__1` symbols and diffed against Darling's built
`libc++.1.dylib` + `libc++abi.1.dylib`, yields exactly one missing symbol:
`__ZNSt3__122__libcpp_verbose_abortEPKcz`. The other ~134 `std::__1` symbols
libLLVM imports are all already exported.

### Fix

Add `std::__1::__libcpp_verbose_abort` to Darling's libc++, mirroring the existing
`std::pmr` addition: a self-contained `src/verbose_abort_std.cpp` (standard
behaviour -- `vfprintf` the message to stderr, then `abort()`), forced to default
visibility (libcxx builds `-fvisibility=hidden`) so it is actually exported, and
listed in the libcxx `CMakeLists.txt`. Carried in
`patches/libcxx/0001-build-std-filesystem-into-libcxx.patch`. The compiled object
exports exactly `_ZNSt3__122__libcpp_verbose_abortEPKcz` (verified with `llvm-nm`
before the rebuild).

This was never the concurrency issue; the toolchain-M1 path avoids it only because
the in-tree bootstrap clang (LLVM 13-era) does not reference the LLVM-14 symbol.

## Reproduce

```sh
# host: fetch hello's full build closure + seed dump
nix-store -r $(nix-store -q --references <hello.drv> | grep '\.drv$')
nix-store --dump-db <closure minus hello output> > hello-db.dump
# guest (one darling shell session): scripts/gnix-hello.sh
touch <prefix>/.enable-writable-nix
DPREFIX=<prefix> darling shell sh gnix-hello.sh
```

`scripts/gnix-hello.sh` carries the full recipe; run with `--keep-failed` (already
set) to inspect any future build-dir failure via `conftest.err`.

## The e2e gate: darlingserver early-boot SIGCHLD/RPC race (SIGILL)

With the libc++ fix in place, the remaining obstacle is getting darling to boot
far enough to run the build. The container starts darlingserver (its socket +
`.init.pid` appear, and darlingserver does **not** crash -- 0 cores), but the
guest init aborts before `shellspawn` comes up:

```
Warning: failed to increase FD rlimit: Operation not permitted   (benign)
Error connecting to shellspawn (<prefix>/var/run/shellspawn.sock): No such file
mach_msg_overwrite failed (internally): -111
*** dserver_rpc_interrupt_enter failed with code -111 ***
```

Traced end to end:
- `mldr` dumps core with **SIGILL**; the faulting instruction is a `ud2` at the
  end of `___simple_abort` in `libsystem_kernel.dylib` (`kill(getpid, SIGABRT)`
  then `ud2`; SIGABRT is not delivered in the container so it falls through to
  the trap). So the guest is **deliberately aborting**, not hitting a bad opcode.
- The abort is from `sigexc_handler`
  (`.../linux_premigration/signal/sigexc.c`): on the first guest signal it calls
  `dserver_rpc_interrupt_enter()` and, if that RPC returns non-zero, immediately
  `__simple_abort()`s (no retry).
- Here it returns **-111 = -ECONNREFUSED**: the thread's RPC channel to
  darlingserver is not serving at the instant the signal (SIGCHLD from reaping an
  early boot-service child) is delivered. `call.cpp` has explicit,
  delicate concurrency handling around `InterruptEnter` -- this is the documented
  fork/exec/SIGCHLD race.

It is timing/host-state dependent: darling booted and ran configure earlier this
session with the same binaries, then began failing persistently after a heavy
monolith rebuild + symbol scans. A clean reset (kill all darling procs, remove
prefixes + the stale global `~/.darling` socket) did not restore it; resources
are not exhausted (namespaces 24/125911, nofile 524288, 15G free).

**Attempted fix + what it revealed (2026-07-24).** I added a bounded retry
(`interrupt_enter_tolerant()` in `sigexc.c`) so the two signal handlers
(`sigrt_handler`, `sigexc_handler`) re-issue `dserver_rpc_interrupt_enter()` on a
`-111` instead of aborting on the first failure, and rebuilt the monolith
(`qkr9rqjv`, which also carries the libc++ fix). Result: the
`dserver_rpc_interrupt_enter failed with code -111` abort is **gone** from the
boot output, but the boot still fails one layer deeper at
`mach_msg_overwrite failed (internally): -111` -- printed by the guest's
**general** mach RPC path (`.../xnu_syscall/mach/impl/mach_traps.c:94`). So the
`-111` (ECONNREFUSED) is **not** a transient per-call gap: the guest's *entire*
mach RPC transport to darlingserver is refused during early boot. A per-call
retry cannot fix a globally-refused transport (and a third call site,
`sigaction.c:177`, is unpatched).

**Real root cause / next step (darlingserver-side).** The guest cannot connect to
(or is refused by) darlingserver's per-process RPC socket during spawn -- the
documented fork/exec/SIGCHLD concurrency issue, now localized to the RPC
transport connection, not the `interrupt_enter` call. The fix belongs in
darlingserver's process-spawn / socket-accept path (ensure the child's RPC
endpoint is connected-and-serving before the guest issues its first mach_msg;
check the listen backlog / accept loop for a race under the boot connection
burst), or in the guest transport (`mach_traps.c`) to establish/retry the
connection. That is a focused darlingserver task for an attended session. The
`interrupt_enter_tolerant()` change is a correct robustness improvement but is
**not** sufficient on its own; it lives in the xnu working tree (built into
`qkr9rqjv`), not yet extracted as a patch.

### Transport mechanism (why ECONNREFUSED) + ranked fixes

darlingserver's RPC socket is a single **`AF_UNIX` `SOCK_DGRAM`** socket
(`server.cpp:452`), bound at `<prefix>/.darlingserver.sock` and drained by one
epoll worker. Every guest thread/process sends its RPC datagrams to it. Darling
does **not** create a network namespace (`darling.c` unshares USER/UTS/IPC;
`darlingserver.cpp` unshares mount -- no `CLONE_NEWNET`), so the socket is in the
**host** net namespace and inherits the host limits:
`net.unix.max_dgram_qlen = 512`, `net.core.rmem_max = 4 MiB`. When the early-boot
RPC burst outruns the worker's draining (the documented worker stall), the DGRAM
receive queue fills and further sends get **ECONNREFUSED (-111)** -- which the
guest send path (`dserver-rpc-defs.c`) does not retry, so the guest aborts. This
matches every observation: load/timing dependent, worked earlier under lighter
load, darlingserver itself never crashes.

Fixes, cheapest first:
1. **No rebuild, needs root:** `sudo sysctl -w net.unix.max_dgram_qlen=16384` (and
   optionally `net.core.rmem_max=16777216`) on the host, then re-run
   `scripts/gnix-hello.sh` against `qkr9rqjv`. If the 512-datagram queue is the
   binding limit, this absorbs the boot burst. **Try this first** -- it confirms
   or refutes the queue-overflow hypothesis with zero code.
   *Evidence (2026-07-24):* running darling in a nested user+net namespace where
   `max_dgram_qlen` is writable unprivileged and raising it to 16384 **removed
   both** the `mach_msg_overwrite ... -111` error **and** the mldr SIGILL core
   that every host boot (qlen=512) produces -- strong support that the queue is
   the trigger. That nested ns could not finish `shellspawn` for unrelated env
   reasons (fresh netns / nested userns), so it is not a clean full-boot proof;
   the host sysctl is. See `scratchpad/gnix-qlen*.sh`.
2. **darlingserver rebuild:** raise `SO_RCVBUF` on `_listenerSocket` toward
   `rmem_max` right after `socket()` in `server.cpp` (helps the byte limit; cannot
   raise the 512 datagram-count limit, which needs option 1).
3. **Guest transport rebuild:** bounded retry on `-111` in the send path
   (`dserver-rpc-defs.c`) -- the general form of `interrupt_enter_tolerant()`;
   rides out a transient full queue for all RPCs. Guard tightly (only when
   status == -111) so the normal path is untouched.
4. **Real fix:** stop darlingserver's worker from stalling under the boot burst
   (the fork/exec/SIGCHLD concurrency bug) so the queue never backs up.

### mono5 result: retries clear the crash, exposing a recv-side deadlock

Rebuilt monolith `4ickrj4r` (mono5) adds a bounded `-111` retry to the mach_msg
path (`mach_traps.c`) alongside the existing interrupt_enter retry. Result on the
host: the `mach_msg_overwrite ... -111` abort is **gone** and **mldr no longer
SIGILLs** -- the send-side crash is fixed. But boot still does not reach
shellspawn, and the live process state during a boot attempt is a **deadlock**,
not progress:
- `darlingserver` -> `do_epoll_wait` (idle, ~0 CPU)
- guest `mldr` thread -> `__skb_wait_for_more_packets` (blocked in `recvmsg`
  waiting for an RPC reply that never arrives), ~0 CPU

So the guest issues an RPC (checkin / mach_msg), blocks waiting for the reply, and
darlingserver never processes/answers it -- it sits in epoll. This is the core
RPC-processing concurrency stall, one layer past the send `-111`. A send-side
retry cannot fix a reply that never comes.

**Strong signal it is host state, not code:** this *same* darlingserver binary
processed RPCs fine earlier this session (that is how `conftest.err` was
captured). A darlingserver that worked, then sits idle-in-epoll while a guest
blocks on recv, points at a degraded host/kernel state from the night's churn
(heavy builds, 20+ mldr crashes, dozens of killed containers) rather than a code
regression. **A host reboot is the highest-probability path back to a working
boot**, after which the guest-Nix build against mono5 (all three fixes) should
reach `hello_rc=0`. The alternative is deep darlingserver worker/epoll concurrency
work (why a guest's request datagram is not processed under the boot burst).

### gdb of the deadlock: darlingserver is idle-CORRECT (the dig's conclusion)

Reproduced the mono5 deadlock and attached gdb to darlingserver. Both its threads
are correctly idle:
- main thread: `epoll_wait` <- `Server::start()` (no socket events pending)
- worker thread: `pthread_cond_wait` <- `WorkQueue<Thread>::worker()` (work queue
  empty)

So darlingserver never received the guest's RPC request (else main's epoll fires,
`receiveMany` drains, a Call is pushed and the worker's condvar is signalled).
`receiveMany` was verified to fully drain (loops recvmmsg until EAGAIN), so the
socket handling is correct. The guest meanwhile blocks in `recvmsg`
(`__skb_wait_for_more_packets`) for a reply. Net: the guest->darlingserver
datagram is not being delivered/queued (or an arrived message is dropped by
`callFromMessage` returning null), while darlingserver sits idle-correct.

Conclusion of the deep dig: this is NOT a darlingserver logic bug -- its event
loop, drain, and worker are all correct and simply have nothing to process. The
request is lost at the transport/kernel layer. Given the same binary delivered
RPCs fine earlier this session, this is degraded host/kernel AF_UNIX-datagram
state from the night's churn, which a darlingserver code change cannot fix. The
pragmatic fix is a host reboot; the only remaining code angle is to instrument
darlingserver (log whether a datagram arrives at all / whether callFromMessage
returns null) to prove which of the two, but that is diagnostics, not a fix.

## ACTUAL ROOT CAUSE (2026-07-24, via strace): DSERVER_FAST_EPOLL 30s reply stall

The boot is NOT deadlocked and NOT host-state -- it is a darlingserver bug that
makes every early-boot RPC reply take ~30 seconds, so boot exceeds darling.c's
120s shellspawn budget (src/startup/darling.c:244, 1200 x 100ms) and fails.
The earlier "needs reboot / host degradation" and "handshake deadlock" theories
were WRONG (no leak found; the RPC actually works).

strace of a boot shows the RPC round-trip working but with a ~30s gap on the
reply:
  08:20:51.489  guest sendmsg(-> .darlingserver.sock)          = 56   (request)
  08:20:51.489  darlingserver recvmmsg(3, ...)                 = 1    (received!)
  08:20:51.489  guest recvmsg(...)  <unfinished ...>                  (awaiting reply)
  08:21:21.491  guest <... recvmsg resumed> ... = 8                   (reply, +30s)
The reply is a real message (not a timeout error), and gdb shows darlingserver's
worker idle (WorkQueue empty) with the main thread in epoll_wait -- i.e. the reply
is already produced and sitting in the outbox, but the main loop is not woken to
send it until the ~30s dtape timer fires.

Root cause: the reply-wakeup eventfd (`_wakeupFD`) is armed EPOLLIN|EPOLLONESHOT.
The `DSERVER_FAST_EPOLL` optimization (CMakeLists option, ON by default) memoizes
the armed state in `_wakeupArmedEvents` to skip "redundant" EPOLL_CTL_MOD re-arms.
But EPOLLONESHOT auto-disarms in the kernel when it fires, so `_wakeupArmedEvents`
drifts and FAST_EPOLL then skips a *needed* re-arm. The worker's
`eventfd_write(_wakeupFD)` ("reply ready") is missed; the reply waits for the
timer. Intermittent (depends on fire-vs-update timing) -- which is exactly why the
same binary booted early this session and failed later.

Fix: DSERVER_FAST_EPOLL=OFF (src/external/darlingserver/CMakeLists.txt) -- the
unconditional-re-arm path re-MODs the eventfd every iteration and self-corrects
the drift. Rebuilt as monolith result-mono6; verifying a fast, reliable boot ->
hello_rc=0. (The libc++ __libcpp_verbose_abort fix + the sigexc/mach_msg -111
retries remain in; the retries are now defensive rather than load-bearing.)

## CORRECTION (2026-07-24): the 30s stall is `semaphore_timedwait_signal`, not FAST_EPOLL

The DSERVER_FAST_EPOLL theory above was WRONG (reverted). A cleaner strace
(mono7, FAST_EPOLL off) shows the ~30s delay is NOT a general reply-wakeup issue
-- most replies are instant. It is one specific RPC: **`semaphore_timedwait_signal`
(dserver call number 62)** whose body carries a 30s timeout (0x1e) and which the
guest's main boot thread waits on for the full 30s before the timeout reply
returns. During the entire 30s window there is zero other socket activity: no
`semaphore_signal` (call 57), no other guest thread -- so nothing signals the
semaphore in time. The guest's main thread blocks on a semaphore whose counterpart
(a worker thread that should signal it) is not there / not scheduled in time. The
boot issues a variable number of these -> variable boot time -> intermittent
completion (~130s when few, >360s when many), which is why the same binary boots
early in a session and stalls later, and why the FAST_EPOLL change made no
difference (the stall is identical on/off).

This is a darlingserver/mldr thread-coordination issue (semaphore signal/wait vs
worker-thread creation timing), NOT the reply-delivery path. Verified fixes so far:
- libc++ `__libcpp_verbose_abort` (patches/libcxx/0001) -- the real clang blocker, done.
- guest `-111` retries in sigexc.c + mach_traps.c -- defensive; prevent the earlier
  ECONNREFUSED abort/SIGILL. Kept.
- darling.c shellspawn wait 120s -> 360s -- lets a slow-but-completing cold boot
  finish; does not fix the underlying stall.
FAST_EPOLL reverted to ON (it was not the cause).

Next (real fix, deep): find why the semaphore's signaling thread is late during
early boot -- the mldr worker-thread creation (elfcalls/threads.c darling_thread_entry
+ dserver checkin) vs the guest's semaphore_timedwait_signal, in darlingserver's
dtape semaphore emulation. That is the remaining darlingserver concurrency bug
gating a reliable boot (and thus hello_rc=0).

## Deeper trace of the 30s stall (2026-07-24): libdispatch thread-teardown / stuck poll

Chased the `semaphore_timedwait_signal` (call 62, 30s) further:
- It is NOT the pthread-join custom-stack semaphore (that path uses `__ulock_wait`
  / `__semwait_signal_nocancel` with no timeout -- libpthread pthread_cancelable.c
  _pthread_joiner_wait:287, pthread.c:394). It is a **libdispatch
  `dispatch_semaphore_wait` with a 30s deadline** (libdispatch semaphore.c:116
  `_dispatch_sema4_timedwait`).
- All guest threads during a stall (via /proc/<mldr>/task/*/wchan):
  launchd (mldr) has 3 threads: one in recvmsg (the joiner/waiter on the 30s
  sema), one in **`poll_schedule_timeout` (a native poll, cpu=0, stuck the whole
  time)**, one in recvmsg. darlingserver: main in epoll_wait, worker in futex
  (idle). So a guest thread is parked in `poll` -- a cancellation point that is
  not being interrupted -- so the canceled thread never reaches
  `bsdthread_terminate` (which *does* signal the join sema, bsdthread_terminate.c:33),
  and the 30s dispatch-semaphore wait times out.
- The boot issues a variable number of these teardown/coordination cycles ->
  variable boot time -> intermittent (~130s completes, >360s fails).

So the remaining fix is in the **thread cancellation / poll-interrupt / libdispatch
worker-teardown coordination** -- why a canceled guest thread parked in a native
poll is not interrupted to terminate promptly. This is a deep, intermittent
darling concurrency bug (kqueue/poll cancellation fidelity + libdispatch teardown),
of the same class flagged for kqueue/poll in PLAN.md. A reliable fix needs an
instrument-rebuild-iterate loop (log the cancel/poll/terminate timeline in the
guest) or better guest-stack symbolication; both are multi-cycle. It is NOT the
reply-delivery/FAST_EPOLL path and NOT a missing signal in bsdthread_terminate.

## ROOT CAUSE FOUND + FIX (2026-07-24): thread cancellation is a no-op in darlingserver

The 30s boot stall is `dispatch_semaphore_wait` timing out because a canceled
guest thread never terminates promptly. Traced to the mechanism:

**darlingserver never implemented POSIX thread cancellation.** Three stubs:
- `Call::PthreadMarkcancel::processCall` (call.cpp): logged "TODO", returned
  `-ENOSYS`. So `__pthread_markcancel(kport)` did nothing -- the target thread
  was never kicked out of its blocking syscall.
- `Call::PthreadCanceled::processCall` (call.cpp): logged "TODO", returned
  `-ENOSYS`. So the guest's `CANCELATION_POINT()` macro (`if
  (sys_pthread_canceled(0) == 0) return -EINTR;`, cancelable.h) and
  libpthread's `_pthread_exit_if_canceled()` (pthread_cancelable.c:209) could
  never observe a cancellation.
- `thread_abort_safely()` (duct-tape/src/thread.c:1184): stub; its own comment
  says the fix is "another real-time signal with SA_RESTART off".

Consequence: `pthread_cancel(t)` set the guest-local PENDING bit and RPC'd
markcancel, which no-op'd. Thread `t`, blocked in a cancelable `poll` with a
~30s timeout (`poll_schedule_timeout`), was never interrupted, so it ran the
full 30s until the poll timed out. Its joiner's `dispatch_semaphore_wait(30s)`
therefore also timed out. launchd issues a variable number of these teardown
cycles at boot -> variable boot time -> intermittent (~130s completes, >360s
fails). All prior theories (host state/reboot, GC, unix qlen, FAST_EPOLL) were
wrong; this is the actual cause.

### The fix (this repo's working tree; guest = xnu submodule, server = darlingserver)

The guest already has the entire receive side of darwin cancellation:
`cerror()` (libsyscall/custom/errno.c:77) calls `_pthread_exit_if_canceled(err)`
on every failed syscall, which on `EINTR && __pthread_canceled(0)==0` calls
`pthread_exit(PTHREAD_CANCELED)`. Only the kernel (darlingserver) side + the
"kick" were missing. Implemented:

1. **darlingserver `Thread`**: added a `_canceled` flag with `markCanceled()`
   (sets it + sends the kick signal) and `isCanceled()`.
2. **`PthreadMarkcancel`**: `targetThread->markCanceled()`.
3. **`PthreadCanceled`**: action 0 returns 0 iff the calling thread `isCanceled()`
   (so `CANCELATION_POINT()` / `_pthread_exit_if_canceled` fire); action 1/2 are
   accepted no-ops (guest tracks enable/disable locally).
4. **Guest kick signal** `SIGNAL_SIGEXC_KICK = LINUX_SIGRTMIN + 2` (sigexc.h):
   a dedicated bare handler installed **without SA_RESTART** (sigexc.c
   `sigkick_handler`/`handle_kick_signal`), registered in `sigexc_setup1`,
   unblocked in `sigexc_setup2` and around `execve`. Being non-restarting, it
   forces a blocked interruptible syscall to return `EINTR` -> cerror ->
   pthread_exit(PTHREAD_CANCELED). `markCanceled()` sends it via
   `sendSignal(LINUX_SIGRTMIN + 2)`.
5. **RPC EINTR-robustness** (dserver-rpc-defs.h): the per-thread RPC send/recv
   now retry on `-LINUX_EINTR`. Required because the kick (SA_RESTART off) can
   land on a thread mid-RPC; the reply is still coming, so retry. The native
   `poll` the kick targets is a separate syscall, so this does not swallow the
   cancellation itself. (Previously nothing produced EINTR here since every
   handler was SA_RESTART.)

Flow: pthread_cancel -> markcancel -> darlingserver sets _canceled + kicks ->
guest poll returns EINTR -> cerror -> __pthread_canceled(0)==0 ->
pthread_exit(PTHREAD_CANCELED) -> bsdthread_terminate signals the join sema ->
joiner wakes immediately (no 30s). Building as mono8; boot-reliability + hello
e2e test pending.

## CORRECTION (2026-07-24): thread cancellation is NOT the boot-stall cause

Implemented the cancellation feature (mono8/mono9) and instrumented darlingserver
(/tmp/kickdbg.log logging every markcancel/canceled with TIDs). Instrumented boot
result is decisive:
- **pthread_markcancel: 0 calls during the entire pre-shellspawn stall.** No guest
  thread is ever canceled.
- pthread_canceled: ~45 calls, ALL returning canceled=0 -- these are just the
  routine CANCELATION_POINT() checks at the head of every cancelable syscall,
  correctly reporting "not canceled".

So the cancellation implementation is **inert during boot** (nothing triggers it),
which is why mono8/mono9 boot exactly like mono7. The earlier "markcancel ->
join stall" reading was wrong.

### What the stall actually is (via /proc/<tid>/syscall, no ptrace)

During the stall, launchd (mldr) has three threads:
- main: `recvmsg` (syscall 47) -- blocked awaiting a darlingserver RPC reply (the
  30s semaphore_timedwait_signal).
- worker: **`select`(syscall 23) on 4 fds with timeout=NULL -- blocked FOREVER**
  (`poll_schedule_timeout`) waiting for one of its fds to become readable.
- another: `recvmsg` (RPC wait).
A second guest process sits in `epoll_wait`.

So the real stall = a service thread blocked indefinitely in select() for an fd
event that darling never delivers, while launchd waits on a semaphore tied to it
(30s timeout, then it proceeds). This is the **kqueue / kevent / mach-notification
event-delivery class** (PLAN.md's kqueue/poll fidelity suspect), NOT cancellation.

The cancellation work stands as a valid fix of a genuine darling gap (the stubs
WERE unimplemented and pthread_cancel WAS a no-op), but it does not address M1's
boot stall. Debug instrumentation (kickdbg) to be removed. Next: identify the 4
select fds + why their event isn't delivered; and the intermittent early-boot
-111 (ECONNREFUSED) RPC race that aborts some boots outright.

## PRECISE boot-hang diagnosis (2026-07-24, via /proc, no ptrace)

Boot completion test: mono8 (clean), 3 boots, 300s cap each -> **0/3 completed**
(each with 2 transient, non-fatal -111s). So the boot does not reliably reach
shellspawn at all; this is baseline (mono8 == mono7 behaviourally; the
cancellation change is inert).

State during the hang (fds + per-thread wchan/syscall of `/sbin/launchd` mldr):
- launchd fd3 = epoll (kqueue emulation) watching: signalfds fd6-9
  (kqueue EVFILT_SIGNAL emulation), sockets fd4/fd12, and fd10=/proc/1/mounts.
- launchd threads: main in `recvmsg` (awaiting the 30s semaphore_timedwait_signal
  RPC reply); an event-loop thread in `select`(nfds=4, timeout=NULL) ->
  `poll_schedule_timeout`, blocked indefinitely; a third in `recvmsg`.
- **darlingserver is fully idle**: main loop in `epoll_wait`, WorkQueue worker in
  `futex`. It has already parked the semaphore microthread with a 30s dtape timer
  and has nothing else to do.

Interpretation: the hang is guest-side. launchd waits on a libdispatch semaphore
with a 30s timeout that nothing signals within the window, because its kqueue
event loop is blocked waiting for an event that darling never delivers -- most
likely a signal via signalfd (EVFILT_SIGNAL, e.g. SIGCHLD for a spawned service)
or a socket/mach message. Each unmet wait costs 30s; enough of them and the boot
exceeds every timeout.

=> The real M1 blocker is **darling kqueue / signal(signalfd) / event-delivery
fidelity during launchd startup** -- a deep, fundamental darling mechanism, NOT
cancellation and NOT any of the earlier theories. Next concrete step to fix:
instrument the full darlingserver call trace (repurpose the /tmp/kickdbg.log
writer at the call-dispatch point) to capture launchd's RPC sequence + the exact
semaphore and the event source it waits on, then fix that specific delivery path
(candidate areas: kqchan EVFILT_SIGNAL / signalfd population on guest signal
delivery; mach-port notification -> kqchan wakeup). The intermittent early-boot
-111 (ECONNREFUSED) RPC race is a separate, likely-related reliability bug.

## CONFIRMED root (2026-07-24, full darlingserver call trace via DSERVER_LOG_FILE)

Added an env-gated `DSERVER_LOG_FILE` override (logging.cpp) so the full per-call
trace lands on a host path. Boot with `DSERVER_LOG_FILE=... DSERVER_LOG_LEVEL=debug`.

Trace of a hung boot (launchd PID 1, ~1200 calls in 80s then quiet):
- Dominant calls: mach_msg_overwrite (121), pthread_canceled (90, routine), plus
  mach_reply_port/port_deallocate/checkin/kqchan. 12 `checkin` -> services DO
  start and check in.
- **The stall: launchd thread 3 loops on `semaphore_timedwait` (call 62); each
  reply lands EXACTLY 30.000s later (720.136 -> 750.136 -> 780.157) -> it times
  out every time.**
- **Zero `semaphore_signal` (call 57) in the entire boot** -> nothing ever signals
  any semaphore, so every wait times out.
- The `proc_get_effective_thread_policy` dtape stub fires just before each wait but
  is incidental (called while darlingserver processes the wait, not causal).
- The 220 "lock mutex without an active thread" warnings are benign: darlingserver
  init + the timeout-timer callback run without a microthread and fall back to a
  native lock (locks.c:60).

Chain: launchd's kqueue event-loop thread is blocked in `select`(NULL timeout) for
an fd event (epoll fd3 over signalfds=EVFILT_SIGNAL + sockets) that darling never
delivers -> the handler that would `dispatch_semaphore_signal` never runs -> every
downstream `semaphore_timedwait` times out at 30s -> boot limps in 30s steps and
never completes (0/3 at 300s).

**Root = darling event-delivery fidelity to launchd's kqueue loop** (top suspect:
a signal such as SIGCHLD not reaching the guest signalfd because guest children are
parented to darlingserver/mldr rather than the guest launchd; alt: a mach-port
notification / socket message not waking the kqchan). This is a deep, fundamental
darling mechanism -- the real M1 blocker. Next step to fix: find which fd/event
launchd's event loop is waiting on (read its kevent registrations / the select
readfds) and make darlingserver deliver that event (signalfd population on guest
signal delivery, or kqchan wakeup on the mach notification).

## Timeout-cap workaround RULED OUT (2026-07-24): boot does not converge

Tried a pragmatic unblock: cap the mach `semaphore_timedwait[_signal]` timeout
guest-side (30s -> 3s), reasoning that since these waits are never signalled they
always time out anyway, so a smaller cap would let the boot limp forward faster.
Built (mono11) + traced: the cap WORKS (replies now land at exactly 3.000s,
result code 49 = KERN_OPERATION_TIMED_OUT) -- but the boot STILL does not
complete (0/1, failed at 150s). The trace shows why:

**launchd TID 3 is an infinite loop that never converges:**
  semaphore_timedwait (times out) -> mach_msg_overwrite (sends a small RPC, gets a
  52-byte reply, dest pid -1=kernel and pid 1=launchd) -> pthread_canceled -> back
  to semaphore_timedwait ... forever, every timeout period.

So no timeout value fixes it: the semaphore is NEVER signalled, so TID 3 spins
forever and the boot hangs regardless. Cap reverted.

Conclusion: M1's boot blocker requires the ROOT fix -- deliver the event/work that
would signal TID 3's libdispatch semaphore (equivalently: wake launchd's kqueue
loop with the event it's polling for). This is a deep darling libdispatch /
kqueue / mach event-delivery issue, the fundamental longstanding boot blocker.
Tractable approaches tried and ruled out with data: thread cancellation (0
markcancel), FAST_EPOLL, unix qlen, host state, semaphore timeout cap.

Recommended next directions (in leverage order):
1. Compare against a known-good upstream darling `darling shell` boot: if upstream
   boots launchd reliably, darling-nix has a build/component-specific regression --
   diff the libdispatch/xnu/darlingserver revisions + patches to find the missing
   piece, rather than re-deriving event delivery.
2. Identify TID 3's exact libdispatch construct (which dispatch source / mach port
   it polls) from the guest side, then make darlingserver deliver that source's
   event so the semaphore gets signalled.

## Upstream comparison RESULT (2026-07-24): darling-nix ~= mainline; boot blocker is upstream darlingserver-mode immaturity

Compared darling-nix's component revs to mainline darling (github.com/darlinghq/darling
submodule gitlinks, via GitHub API):
- libdispatch  380f03c1 == mainline (identical)
- libpthread   f07f265b == mainline (identical)
- darlingserver 89751e64 == mainline base (vendored; only 2 local changes: writable-nix
  overlay + ucred cache -- neither touches event delivery)
- xnu          5f26a4c2 vs mainline fa29287a: darling-nix is an ANCESTOR by exactly
  2 commits, both "Fix Building For Fedora 44" (libsyscall/CMakeLists.txt only) -- NOT
  event-delivery.

=> darling-nix is essentially identical to mainline darling in every event-delivery
component. The boot hang is NOT a darling-nix regression and there is no mainline fix
to port.

Web check (darlinghq/darling issues #1173, #1093, #610): **darlingserver (the userspace
kernel server / rootless mode, which darling-nix uses) has long-standing, still-open
trouble completing launchd bootstrap.** The traditional LKM (kernel-module) path boots
launchd reliably but needs root + an out-of-tree kernel module (incompatible with
darling-nix's rootless design and this host's very recent Zen 7.1.2 kernel). darling-nix
gets FURTHER than the 2022 reports (launchd + launchctl run, services check in) but hits
the event-delivery/semaphore-starvation wall (TID 3 never-signalled loop).

**Conclusion:** M1's boot blocker = incomplete launchd-bootstrap event delivery in
darlingserver (userspace) mode. This is an upstream-darling maturity gap, not a
darling-nix bug. Fixing it = a deep upstream-caliber darlingserver contribution
(kqueue/kqchan/mach event delivery so the launchd dispatch semaphore gets signalled).

Possible directions:
1. Deep fix in darlingserver's event delivery (upstream-caliber; the "real" fix).
2. Minimal-launchd boot: skip the System-domain service whose event never fires, so
   `darling shell` reaches shellspawn without the full bootstrap (pragmatic; needs to
   identify the offending job in the launchd plist set).
3. Bypass full launchd: run guest nix in a thinner environment if darling allows it.
4. Track upstream darlingserver; the boot may improve as that mode matures.

## MAJOR CORRECTION (2026-07-24, re-evaluated critically): root = EVFILT_MACHPORT event delivery, NOT the TID3 semaphore

Prior evaluation (opus 4.8) concluded the boot hangs on launchd TID3's
never-signalled semaphore ("infinite loop / doesn't converge / upstream
darlingserver immaturity, unfixable"). Re-examined the full trace critically -->
that was WRONG (TID3 is just launchd's IDLE libdispatch manager, a symptom).

The real, verified root cause is a deterministic launchd<->launchctl bootstrap
DEADLOCK via broken EVFILT_MACHPORT delivery:
- launchd forks launchctl (`bootstrap -S System`). launchctl starts, checks in,
  sends its first bootstrap mach message to launchd, then blocks natively FOREVER
  (last RPC at t+130ms, silent for the remaining 48s).
- launchd opens an EVFILT_MACHPORT kqchan (KQ:0) on its bootstrap port. **Across
  the whole boot it fires `_notify` ZERO times** (verified: "sending notification"
  count for KQ:0 = 0). By contrast the EVFILT_PROC kqchan (KQ:1) fires correctly.
- So when launchctl's message lands on launchd's watched port, launchd's kqueue
  never wakes --> launchd never services the bootstrap --> launchctl deadlocks.
- Minimal-launchd (trim /System/Library/LaunchDaemons to shellspawn+opendirectoryd
  +iokitd) does NOT help (0/5): the hang is in the FIRST bootstrap message, before
  any daemon plist is read. Semaphore-timeout-cap does NOT help (infinite by
  design). Both ruled out with data.

Fix locus: darlingserver dtape `ipc_mqueue_post()` (ipc_mqueue.c:805-816) fires
`KNOTE(&mqueue->imq_klist, 0)` only if
  ip_active(port) && ip_receiver_name!=MACH_PORT_NULL && is_active(ip_receiver)
  && ipc_mqueue_has_klist(mqueue).
For launchd's bootstrap port one of these is false, so KNOTE is skipped and the
mach-port kqchan never notifies. Next: instrument which condition fails, then fix.
This is a SPECIFIC, likely-fixable dtape gap -- not the vague "upstream immaturity"
of the prior evaluation.
