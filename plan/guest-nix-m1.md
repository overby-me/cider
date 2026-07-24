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
