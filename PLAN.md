# darling-nix

darling-nix is a Nix-packaged fork of [Darling](https://github.com/darlinghq/darling)
(a userspace macOS/Darwin compatibility layer for Linux, "Wine for macOS"). Its host and
guest runtime have been rewritten in Rust.

**End goal:** build `aarch64-darwin` nixpkgs derivations on non-Apple ARM Linux, using
Darling as the Darwin layer, verified bit-for-bit against cache.nixos.org.

**Current campaign:** make `x86_64-darwin` builds work end-to-end against **nixpkgs 26.05**
(the last release supporting x86_64-darwin: a frozen target and a permanent cache oracle).
x86_64 is the native-speed test rig; most work (libSystem surface, harness, oracle, daemon)
is architecture-independent and transfers to ARM.

Tag work: **[ARCH-FREE]** (transfers as-is), **[ARCH-PARAM]** (transfers if parameterized
now), **[X86-ONLY]** (throwaway, minimize investment).

> This file supersedes the old sprawling `plan/` docs (Campaign 1 + Campaign 2), which
> were consolidated into it. Campaign 1's detailed history lives in git and the removed
> `plan/*.md` (recoverable from history).

---

## Status (2026-07)

Done:
- **Rust rewrite complete and default.** Host daemon (`linux/server`, crate `darling`, bin
  `darlingserverd`), launcher (`linux/launcher`, bin `darling`), guest loader
  (`darwin/loader`, bin `mldr`). The C++ daemon and C launcher/loader are deleted.
- **Boots to Darwin; M1 achieved.** Guest nix 2.34.8 builds and runs `hello` (and `pv`)
  from source under rootless Darling, launchd-free. `nix eval builtins.currentSystem` →
  `"x86_64-darwin"`.
- **Off git submodules.** Nix (`nix/submodules.json`, 147 pins + `nix/lib/darling-src.nix`)
  is the sole source path; `.gitmodules` + gitlinks deleted, no `?submodules=1`.
- **Full `.#default` builds green and boots.**
- **Identity:** macOS **14.4.1** / Darwin **23.4.0** / build **23E224**
  (`patches/xnu/0005` + `SystemVersion.plist`); clang auto-targets
  `x86_64-apple-darwin23.4.0`. `CMAKE_OSX_DEPLOYMENT_TARGET` stays 11.0 by choice.

Phases A (identity), B (symbol gap), C (bootstrap tools execute + build hello / M1) are done.
The open frontier is D (oracle), E (package ladder), F (ARM prep), plus the Rust/build/perf
tracks below.

---

## Architecture

- **Call chain (the debugging map):** Darwin binary → Darwin libc → `libsystem_kernel`
  BSD-trap stub → daemon translates to Linux → kernel. Syscalls are implemented only to the
  depth Nix needs, not for general macOS compat.
- **launcher** (`linux/launcher`, libc-only, builds offline): rootless userns re-exec,
  prefix bootstrap, spawns the daemon as container init, shellspawn client, teardown. Owns
  NO mounts/vchroot (the daemon does).
- **daemon** (`linux/server`): single-threaded epoll loop + a **stackful microthread
  scheduler** (`sched.rs`) — not async, because duct-tape suspends microthreads
  synchronously from inside C stacks; single-worker is correct (duct-tape locks are
  cooperative). RPC codec (`rpc_wire.rs`) is generated from the calls list, 162/162
  byte-identical to C. Wire = SOCK_DGRAM + SO_PASSCRED (sender pid via SCM_CREDENTIALS, used
  for `process_vm_readv` because the guest is in its own PID namespace).
- **duct-tape** (`src/external/darlingserver/duct-tape/`, still C): kernel-emulation glue
  that compiles the vendored XNU (osfmk/bsd). Linked into the daemon crate by
  `linux/server/build.rs`: bindgen generates the 36-field `dtape_hooks_t` from source
  headers; static libs (`libdarlingserver_duct_tape.a`, `liblibsimple_darlingserver.a`)
  come via the `DUCT_TAPE_LIB` env var. The Rust/C seam is the frozen `dtape_*` API +
  `dtape_hooks` vtable — Rust above, C+XNU below.
- **mldr loader** (`darwin/loader`, libc + goblin): guest Mach-O loader — segment mmap/slide,
  commpage, the elfcalls vtable (ELF↔Mach-O), start stack, daemon checkin, jump to dyld.
- **Container model:** an overlayfs prefix (`~/.darling`, macOS FS hierarchy) entered
  **rootless** via unprivileged user namespaces (needs
  `kernel.unprivileged_userns_clone=1`, kernel ≥5.11). **One command per fresh container** —
  a sibling userns cannot join a running container's mount ns.
- **Shared store:** guest `/nix/store` is the host store via a `/nix →
  /Volumes/SystemRoot/nix` symlink (the host root is mounted at `/Volumes/SystemRoot`);
  `/nix/var` stays Darling-local to avoid db/schema conflicts.
- **apple-sdk `.tbd` stubs:** binaries link against stub symbols, resolved at runtime from
  Darling's reimplemented libraries — so derivation hashes never depend on Darling.
- **sandbox-exec** is a parse-and-ignore stub (the Linux container already isolates).
- **Nix packaging:** `nix/lib/darling-src.nix` assembles the tree from the 147 pins +
  `patches/<name>/`; `nix/package.nix` builds the Darwin userland and installs the Rust
  crates; `nix/{launcher,server,duct-tape,loader,cctools-port}.nix`.

---

## Invariants (never violate)

1. **Official nixpkgs 26.05 only.** A patched input makes hashes incomparable and the oracle
   worthless. Record nixpkgs-side needs as a blocker entry (see Blockers), don't fork inputs.
2. **No Apple-proprietary bits** in outputs or the repo. Reimplement from Apple open source
   (APSL) or clean-room from public docs; note provenance in commits. SDK stubs flow through
   Nix's own `apple-sdk` fetch, never vendored.
3. **Green never regresses.** Every fix lands with a regression test; `scripts/run-tests.sh`
   + flake checks pass before every commit; the compatibility matrix is append-only.
4. **Arch discipline.** Code touching registers, syscall numbers, thread state, signal
   frames, TLS, page size, or Mach-O CPU types goes behind the arch boundary. aarch64 is the
   customer; x86_64 is the test rig.

---

## Open work

### D — Correctness oracle (the keystone remaining) [ARCH-FREE]
"It built" → "it built **correctly**." The project's core value proposition.
- **D.1** `scripts/oracle.sh <attr>` = `nix build --rebuild` vs cache.nixos.org, JSON
  (match / mismatch / build-failure / known-nondeterministic).
- **D.2** oracle column in `tests/nix/compatibility-matrix.sh`; a justified
  non-determinism allowlist.
- **D.3** on mismatch: diffoscope + classify (codegen vs metadata vs fs-ordering vs
  miscompile). **A codegen-class divergence is stop-the-line** — the shim is lying to the
  compiler (math, memory layout, or a syscall result) and everything above is suspect.

### M1 tail (Phase C.3–C.4b) [ARCH-FREE]
- Drive the official `pkgs.hello` **derivation** through guest nix (not hand-run
  configure/make). `scripts/build-pkg-bypass.sh <attr>` generalizes to any nixpkgs
  x86_64-darwin attr. Widen to no-substitute deps.
- **C.4b** gdb-on-timeout stall capture (timeout + on-timeout stack of the guest process +
  daemon), filed to the Stall notes below. (The old `config.status` here-doc pipe hang was
  the checkout lifetime-pipe fd leak → pipe-page starvation, now FIXED; reverify if it
  recurs.)

### E — Climb the package ladder [ARCH-FREE]
- **E.1** dependency-weighted 26.05 x86_64-darwin target list (CLI-only; GUI *runtime* out
  of scope — building GUI apps against link-time framework stubs is fine).
- **E.2** grind loop per package: build → triage (syscall / symbol / stall / semantic
  divergence) → fix with a regression test → oracle → append to matrix.
- **E.3** milestone packages: `python3` (pip-stall class), `git`, `cmake`, `openssl`, a
  large C++ package (`llvm`); stretch: `swiftc` (stresses libdispatch/CF).
- **Exit (campaign):** the full Tier-1..3 matrix green with oracle, on a frozen 26.05 pin,
  in CI, reproducibly from a clean prefix.

### F — ARM readiness (prep only, do not start the port) [ARCH-PARAM]
- **F.1** salvage-assess the three `feature/arm-support*` branches → `plan/arm-salvage.md`.
- **F.2** arch-boundary audit (syscall numbers, ucontext layouts, asm, page size). Audit
  host-page-size vs Darwin `vm_page_size`: arm64 userland assumes **16K pages** — plan to
  report 16K from libSystem regardless of host, and prefer `CONFIG_ARM64_16K_PAGES` guests.
- **F.3** parameterize harness / VM tests / matrix / oracle / symbol tooling by arch.
  aarch64-darwin outputs carry ad-hoc code signatures (nixpkgs signs via sigtool) — the
  oracle must handle signature bytes correctly, not diff them naively.
- **F.4** document the QEMU aarch64 dev recipe (share `/nix/store` via virtiofs; never run
  darlingserver under qemu-user — signal/TLS fidelity).

### Rust + tooling
- **#63 exec across architectures** [narrow] — daemon cross-arch exec; the guest 32-bit
  loader (`mldr32`, cmake `BUILD_TARGET_32BIT`) is port-or-drop-undecided. Fat/universal
  Mach-O selection already done.
- **#72 duct-tape → self-contained `-sys` crate** — decouple XNU from the cmake tree (today
  linked via `DUCT_TAPE_LIB` at the cmake build's `.a`; bindgen runs on in-tree headers).
  Aspirational, not started.
- **#73 port build-time codegen to Rust** — `generate-rpc-wrappers.py` (already extended to
  emit the Rust codec, but still Python) and `tools/generate-xcode-stubs.py`.
- **#69 mig (Mach Interface Generator)** — still the C `bootstrap_cmds` fork (Apple-tracking,
  no nixpkgs substitute). A Rust rewrite is unstarted; only its nix-ninja edge handling is
  patched (see Build system).
- **#68 finish the repo reorg** — move the C++ darlingserver + duct-tape from `src/external`
  into `linux/darlingserver/`, completing the `darwin/` (guest) + `linux/` (host) seam.
- **Linker (#57 tail)** — `packages.darling-ld64` (`nix/cctools-port.nix`) done; fold in
  `install_name_tool`/`nmedit`, validate a real darwin dylib link with `-DDARLING_LD64_DIR`.

### Build system — make nix-ninja the primary incremental build (#26/#39)
Lower every edge of Darling's ~26k-edge ninja graph to its own content-addressed nix
derivation (the ~40-min monolith → seconds-incremental, fully cacheable, pure-nix). Infra:
`nix/lib/darlingNinja.nix` (`buildTarget`), vendored `nix/lib/nix-ninja/`.
- **State:** the libSystem umbrella builds per-edge (~5036 edges, valid Mach-O);
  darlingserver-ninja green per-edge; the graph-json IFD is feasible (~100s). Interim fast
  loops exist (`packages.darlingserver` coarse ~5-6 min vs 40; launcher fast-path).
- **Open blocker:** full-graph `buildTarget {}` (the `all` phony) stops at
  `migHeaderIncsFor` scope-sensitivity — `asl.c`'s `<asl_ipc.h>` `-I` resolves at subgraph
  scope but returns `[]` at full-graph scope.
- **To make primary:** (1) close the asl.c blocker → full-graph green; (2) build the
  install/fixup wrapper reproducing `package.nix`'s exact `libexec/darling` layout from
  per-edge outputs, diff'd identical; (3) wire `packages.darling-ninja`, kept OUT of
  `nix flake check` (thousands of derivations hang it); (4) vendor rust-ninja, drop the
  `overby` input.

### Multi-user / launchd / #47
- **#47 launchd: a guest RPC sendmsg gets ECONNREFUSED** [long-term] — narrowed 2026-08-01
  from "launchd deadlocks" to a 15-line syscall reproduction. The SPIN half is FIXED
  (patches/xnu/0008): a failed sigexc used to abort, and aborting needs the machinery that
  just failed, so it looped on ud2 -- 56,676,502 SIGILLs at one address, ~50% CPU,
  unkillable. It now exits with a diagnostic. launchd still does not work.

  The whole failure, from `strace -ff -e trace=socket,connect,bind,close,fcntl,sendmsg,sendto`:

        socket(AF_UNIX, SOCK_DGRAM, 0)  = 10
        bind(10, {AF_UNIX}, 2)          = 0        # autobind, NOT connected
        fcntl(10, F_DUPFD_CLOEXEC, 512) = 513      # RPC fd parked high
        close(10)
        sendto (513, #1  checkin)            = 40  # ok
        sendmsg(513, #35 thread_self_trap)         # ok
        sendmsg(513, #8  set_thread_handles)       # ok
        sendmsg(513, #31 pthread_canceled)         # ok
        sendmsg(513, #36 mach_reply_port)          # ok
        sendmsg(513, #38 mach_msg_overwrite)       # ok
        sendmsg(513, #31 pthread_canceled)         # ok
        sendmsg(513, #38 mach_msg_overwrite) = -1 ECONNREFUSED   <-- the bug
        --- SIGABRT {si_code=SI_USER, si_pid=1} ---             # __simple_abort
        sendmsg(513, #14 interrupt_enter)    = -1 ECONNREFUSED  # sigexc, same fault
        +++ exited with 1 +++                                    # 0008 working

  So: the SECOND mach_msg_overwrite on a socket whose previous seven sends all succeeded,
  same fd, same path, sender never connected. That is the entire open question.

  The FIRST failure in the system is not launchd's, though. A launchd JOB (guest pid 4)
  starts, closes the inherited RPC fds 512/513/514, opens its own, checks in, runs ~20 RPCs
  fine, and then its last mach_msg_overwrite comes back with reply status **0x10000003 =
  MACH_SEND_INVALID_DEST**, whereupon it exit_group(1). launchd sees that as
  `SIGCHLD {si_pid=4, si_status=1}`, keeps going for another dozen successful RPCs, and only
  THEN gets ECONNREFUSED. So MACH_SEND_INVALID_DEST is the earliest thing that goes wrong and
  is the better thread to pull; the ECONNREFUSED may well be downstream of whatever state
  that leaves behind.

  ELIMINATED by measurement, do not re-investigate:
    * The portset/kqueue linkage. One portset, not empty, and a message on a member port
      DOES wake the kqchan waiter.
    * "Stranded messages on ports with empty klists." Posted == consumed, 18 for 18.
    * The daemon restarting or its socket being replaced. `Listener::bind` unlinks and binds
      once; the socket inode is stable across a run and `lsof` shows it alive and
      `type=DGRAM (UNCONNECTED)` at failure time.
    * "Two daemons fighting over the path." The WORKING (DARLING_NO_LAUNCHD=1) run has
      three darlingserver processes and the failing one has two, so the count is not it.

    * The socket being replaced mid-run. Sampled at 100 Hz for 6s: the inode at
      <prefix>/.darlingserver.sock never changes.
    * The container's mount namespace resolving the path differently. The host, the daemon's
      /proc/PID/root and the guest's /proc/PID/root all stat the SAME inode.

  ANSWERED: the destination is **MACH_PORT_NULL**. Instrumenting all three INVALID_DEST
  exits of ipc_kmsg_copyin_header gives exactly one event per boot:

        copyin_header: INVALID_DEST (name not valid) dest=0x0 reply=0x403 dest_type=19

  dest=0x0 with a perfectly good reply port (0x403) and dest_type 19 (COPY_SEND). The job is
  not sending to a stale or dead port; it is sending to a port it never got. That makes this
  a BOOTSTRAP PORT problem, not an IPC one: a launchd job whose bootstrap_port is null fails
  its first service lookup and exits, which is the exit(1) launchd sees.

  ROOT CAUSE FOUND AND FIXED (the first cause, not the whole task). Every guest task was
  created with NO PARENT: Registry::ensure_task passed std::ptr::null_mut() to
  dtape_task_create, which its own comment admitted ("Parent is NULL for now"). ipc_task_init's
  parent==TASK_NULL branch sets itk_bootstrap = IP_NULL, so a launchd JOB could never inherit
  launchd's bootstrap port however correct everything else was. It asked, got nil, sent its
  first service lookup to MACH_PORT_NULL and exited.

  ensure_task now finds the parent through /proc/<host pid>/PPid and passes its task. The
  lookup has to happen there rather than in Handler::set_current, because the task is created
  before the first call is dispatched and set_current's parent link comes too late. With a
  parent, ipc_task_init also inherits the exception ports, the registered ports and the
  security/audit tokens, which is what XNU does.

  Measured, same boot, before and after:

        before   dtape_task_create: nsid=4 parent=(nil)      GET bootstrap -> (nil)   INVALID_DEST dest=0x0
        after    dtape_task_create: nsid=4 parent=0x..d8e10  GET bootstrap -> 0x..cbe50   INVALID_DEST count 0

  launchd STILL does not complete. It is NOT a deadlock: it is a 30-SECOND POLL LOOP.
  Timestamping the daemon's own strace and measuring the gaps gives 29.555s, 30.001s, 30.001s,
  each ending with a reply to call #62 semaphore_timedwait. launchd waits on a semaphore with
  a 30 second timeout, times out, does two or three RPCs, and waits again -- forever. An
  earlier revision of this entry called it a quiescent deadlock with ninety seconds of
  silence; that was an artifact of filtering the trace on one timestamp prefix and missing the
  intermediate cycles. Read gaps, do not eyeball a filtered tail.

  The ECONNREFUSED cascade is separately an artifact of TEARDOWN, not the defect. `strace -ff -tt` across every
  thread settles it by timestamp:

        11:59:32.5   all activity stops, about one second into the boot
        ...          NINETY SECONDS of complete silence, every process blocked in recvmsg
        12:01:11.6   the harness's own `timeout 100` fires and SIGTERMs the daemon
        12:01:11.648832  daemon killed
        12:01:11.648946  launchd's sendmsg -> ECONNREFUSED, 114 MICROSECONDS later

  So the ECONNREFUSED, the -111, the abort and the exit(1) are all artifacts of the TEARDOWN.
  They are what any process gets for talking to a daemon that has just been killed. Do not
  chase them again; use a timeout longer than the observed hang and look at the QUIET period.

  WHO IS WAITING, from the daemon's own RECV trace (DSERVER_TRACE_CALLS=1), last call parked
  per (nsid, tid):

        nsid=1 tid=1  #38 mach_msg_overwrite   launchd's dispatch thread, blocked on the PORTSET
        nsid=1 tid=3  #62 semaphore_timedwait  a launchd worker in a timed wait
        nsid=4 tid=4  #38 mach_msg_overwrite   the JOB, blocked in a mach_msg

  And guest pid 4 is `launchctl bootstrap -S System` (from its execve). So the ORIGINAL entry
  named the right victim after all, even though its portset explanation was wrong.

  THE IPC ITSELF WORKS. Measured in one round trip, lines 793-808 of the daemon log:
    * the job sends to launchd; the message lands on a port that IS in the portset and
      `wq_prepost_do_post_locked` preposts it to set 0x40001;
    * launchd's receive CONSUMES that prepost (`waitq_clear_prepost_locked: invalidate
      prepost 0x280000`);
    * launchd replies to pid 4 and the post finds a real receiver (`receiver=0x..247b60`).
  So bootstrap messaging is not broken. After that exchange everything simply goes idle.

  NEXT: the job was woken at that reply and then issued NO further RPC. Find out whether its
  RPC reply was actually SENT after the microthread was woken, or whether the wake and the
  reply have come apart. That is a narrow question about the daemon's parked-microthread
  resume path, and it is the last unexplained step.

  Not a lead: shellspawn is PRESENT in the prefix, at usr/libexec/shellspawn (NOT
  usr/libexec/darling/shellspawn, where I looked first and wrongly concluded it was missing),
  together with System/Library/LaunchDaemons/org.darlinghq.shellspawn.plist. `launchctl
  bootstrap -S System` is what should load that plist, which is why nothing runs the command:
  the launcher waits for a shellspawn that never starts because bootstrap never finishes.

  ELIMINATED for the ECONNREFUSED before it turned out to be a teardown artifact, kept because
  the same ideas will tempt the next reader: the daemon closing its socket (it binds fd 3 once
  and never closes it), the path resolving differently after vchroot (host and every guest
  /proc/PID/root stat the same inode), and an fd-parking race on 512/513/514 across launchd's
  shared thread fd table (with -tt, no other thread touches those fds anywhere near the send).

  Do NOT misread launchd's console banner: "launchd[1] has started up" followed by "Shutdown
  logging is enabled" is its STARTUP message, and the second line is about log configuration,
  not a shutdown. The guest also keeps its own RPC log at
  /tmp/dserver-client-rpc.log -- INSIDE the container's mount namespace, so it is not visible
  at that path on the host, which is why it reads as empty there.

  A note on tools: `ss -x` cannot see the daemon socket from the host, because unix sockets
  are netns-scoped and the daemon lives in the container's namespace. `lsof -U` can (it walks
  /proc/*/fd), and /proc/<daemon pid>/net/unix reads that namespace's table directly.

  Reproduce by dropping `DARLING_NO_LAUNCHD=1`. The daemon's own log is
  `<prefix>/darlingserver.log`, NOT the launcher's stderr. Still bypassed by
  `DARLING_NO_LAUNCHD=1`; not on the nix-builds critical path.
- Multi-user nix-daemon, `_nixbldN` setuid-in-userns, concurrent-build fcntl locking — open,
  production-hardening, not on the critical path (single-user M1 sidesteps it).

### CI + remote builder (built in Campaign 1, unvalidated — needs rework)
Machinery exists but was **never validated end-to-end on a live prefix** and predates the
Rust rewrite / launchd-bypass / 26.05 pin / submodule removal:
- CI: `.tangled/workflows/ci.yml` (tangled.org), `tests/*.nix`,
  `tests/nix/compatibility-matrix.sh`, dirserv-stubs check.
- Remote builder: `nix/darlingBuilderModule.nix` (`services.darling-builder`, sshd in prefix,
  `nix.buildMachines`), `scripts/darling-build-hook`, VM tests. Design (host
  `nix.buildMachines` → sshd in Darling → guest nix-daemon, shared store avoids SSH copy) is
  the north star but unexercised — and conflicts with one-command-per-container.

### Performance (measure during E; acceptable-if-slow for CI)
Baseline: spawn ~11–12× native (~28 ms/proc), compute ~7.6×. Spawn tax: ~22 ms (78%) = the
daemon fork/exec/RPC path. Landed and done: P0 ucred cache, P1 sigmask-free context switch,
P2 epoll re-arm memoize.
- **P0.7 spawn-path round-trips** — batch the fork/exec/registration RPCs. THE biggest
  wall-clock lever (~22 ms/spawn). High risk (IPC core).
- **P3 mach_msg same-task fast path** — handle same-task/local-port sends+recvs in-process.
  High risk. **P4** userspace signal deferral (drop the per-RPC sigmask pair). **P5** psynch
  uncontended CAS fast path. **P6** inline small OOL payloads into the datagram. **P8**
  scheduler futex contention (lock-free hot path) — deepest, do last.
- P0.5 dyld shared cache: DOWNGRADED to low (saves ~1.8 ms/spawn only).
- **Meta-blocker:** P3–P8 are core-cutting and not isolate-testable → gated on a reliable
  non-flaky spawn/IPC stress harness + fast daemon iteration (nix-ninja). Build that first.
- Already optimal (don't touch): BSD syscall dispatch (table-driven to Linux),
  `__ulock_wait/wake`→`futex(2)`, `vchroot_expand` path translation, cached
  `mach_task_self`/`mach_host_self`, getpwuid via glibc NSS.

### Watch-items (reopen on demand)
- **Symbol:** 6 lazy-bound FSEvents stubs (`_FSEventStream*`, CoreServices) only if a real
  binary calls them. Re-run `symbol-demand.sh` as the package set widens (larger C++/Swift
  broadens the surface). Supply = `nm --defined-only` ∪ full export-trie (both, or you
  undercount re-exports).
- **Syscall:** dup2-to-guarded-fd → return EBADF, don't abort; may recur in
  `fcntl(F_DUPFD)`/`dup`. Network.framework `nw_*` = 39 loud NULL stubs (real impl out of
  scope; nix never uses S3 for local builds).
- **`-111`/ECONNREFUSED:** doesn't fire on `net.unix.max_dgram_qlen=16384` hosts; the two
  guest busy-spin band-aids (sigexc.c, mach_traps.c) are vestigial there but needed on
  qlen=512. Proper host-independent fix (open): the daemon drains the socket to EAGAIN
  (recvmmsg loop) into an internal queue so it never backs up.
- **SIGFPE exec-fidelity flake (#44):** intermittent signal-8 in guest build/test binaries —
  retryable (nix build ×4), not a real error nor a Rust regression.

### Upstream adoption
Fork point `f39a29489` (2026-03); upstream idle on core as of 2026-07-19. Adopt only when a
concrete failure justifies it:
- Newer-toolchain build fixes (we build under clang 21): darling
  `e3fe4288 3f277ba5 9f485c91 ddd118d9 fc5c0666`, xnu `644decacee`. Cherry-pick onto our
  patched xnu; **don't bump the gitlink** (ours diverges).
- libkqueue `b0795a2e` (EVFILT_TIMER type-punning) if a kqueue-timer stall appears.
- Upstream darlingserver C++ tracking is obsolete (we're full-Rust). Fixing the launchd-boot
  hang would be an upstream-caliber rootless contribution.

---

## Operational notes / gotchas

- **Run recipe** (from a built `$out = nix build .#default`):
  `DSERVER_LIBEXEC_PATH=$out/libexec/darling
  DSERVER_MLDR_PATH=$out/libexec/darling/usr/libexec/darling/mldr DARLING_NO_LAUNCHD=1
  DPREFIX=<fresh dir> $out/bin/darling shell sh -c 'uname -sm'` → `Darwin x86_64`.
- **Phantom-path trap:** after any commit that touches a Rust crate, `.#default`'s hash
  changes and `nix eval .outPath` returns a NEW, UNBUILT path. Booting against it fails
  SILENTLY (daemon binary absent → launcher spins in its container-acquisition loop,
  wchan=hrtimer_nanosleep, empty log, `pgrep darlingserver` finds nothing). Always
  `nix build .#default` first (or assert `test -x $out/bin/darlingserver`). The same drift
  happens dirty→committed (a dirty-tree build and its commit hash differ).
- **mldr debug is gated** behind `MLDR_DEBUG=1` (default off). Do NOT grep for `[mldr]` to
  confirm a boot with the gate off — grep guest stdout (`Darwin`/`uname` output). The ungated
  ~15-line-per-process flood interleaving with stdout under `2>&1` was the false
  "concurrent-output flake"; measure output completeness with stdout/stderr SEPARATED.
- **mldr elfcall movaps constraint:** the guest calls elfcalls on an 8-byte-misaligned
  stack, so elfcall-reachable loader code must be movaps-free — no `mem::zeroed`/`Default` of
  a >8-byte struct on the stack (emits an aligned SSE store that #GPs); use `MaybeUninit` +
  scalar fills.
- **duct-tape two-phase init:** `dtape_init` then `dtape_init_in_thread` on a kernel
  microthread (psynch etc.); no hook in the 36-field vtable may ever be NULL (NULL → indirect
  call to 0x0).
- **RPC socket fork-safety:** sockets live at high fds + FD_CLOEXEC (so a forked subshell's
  low-fd dup2/close can't clobber them); the child does a socket-refresh.
- **One command per fresh container** (kill the stale daemon first). Keep the prefix path
  short — the daemon/shellspawn AF_UNIX socket lives under `<prefix>/var/run/` and overflows
  `sockaddr_un.sun_path` (~108 chars) on long paths; use `~/.darling`. Export
  `TMPDIR=$HOME/tmp` (the default Darwin temp dir EACCESes). Two-boot warm flow; harness
  output must be file-based, never piped through a reader (a leaked container holds the pipe
  write-end open and blocks EOF).
- **`__private_extern__` is not a linker bug (#57):** modern clang emits it as an *undefined*
  symbol; link the consumer against real ncurses/libtinfo, don't touch ld64. `-fcommon`
  doesn't fix it.
- **xnu pin gotcha:** the super-repo gitlink was a Campaign-1 rev never published upstream;
  darling-src fetches the pinned rev from `submodules.json` + applies `patches/xnu/*`.
  Cherry-pick upstream fixes onto our patched xnu; don't bump the pin blindly.
- **nix-ninja / mig gotchas:** merged `$out` conflates a checked-in `osfmk/**/X.h` with the
  same-named mig-generated header (10 collisions; `notify.h` is
  `_MIG_KERNEL_SPECIFIC_CODE_`-sensitive — force it to 1 via a duct-tape patch); mig edges
  need `-DKERNEL_USER -DMACH_KERNEL -DKERNEL`; `lower.nix` must `rm -f` a staged read-only
  source symlink at a declared output path (else mig `fopen`→EACCES). Full-graph nix-ninja is
  ~26k derivations — keep it OUT of `nix flake check`.

---

## Working agreements

- **Verification is execution in a clean prefix**, not inspection. A task is done when its
  test runs green from a fresh prefix, not when the code looks right.
- **Small commits**, phase-tagged (`feat(phaseB.3): ...`), tests included, this doc updated
  in the same commit.
- **When blocked** (a nixpkgs-side change seems required, a licensing question, a
  divergence-class stop-the-line, or >1 day stuck on one signature): add a dated entry under
  Blockers with reproduction steps and stop that thread; take the next ranked item.
- **Insurance:** mirror the bootstrap-tools closure + key reference narinfo/nars to our own
  Cachix early (the oracle depends on cache retention past 26.05 EOL, end of 2026).

## Risk register

| Risk | Class | Mitigation |
|---|---|---|
| Silent output divergence (shim lies subtly) | correctness | Phase D oracle + stop-the-line |
| Stalls in event-loop-heavy builds (kqueue/poll) | fidelity | C.4b watchdog + stall triage |
| macOS-14 symbol surface larger than expected | scope | demand-driven ordering; stubs last |
| Mach IPC perf through userspace daemon | perf | measure during E; acceptable for CI |
| Cache retention past 26.05 EOL | infra | mirror reference closures to own Cachix |
| x86-only effort waste | strategy | ARCH tags; Phase F keeps the boundary honest |

---

## Blockers

Active blockers get a dated entry here (repro steps + what's stuck); resolved ones fold into
Gotchas or Open work. The known standing limitations are already tracked above — the launchd
portset deadlock (#47, bypassed by `DARLING_NO_LAUNCHD=1`), the SIGFPE exec-fidelity flake
(#44, retryable), and the nix-ninja full-graph `migHeaderIncsFor` blocker. Nothing else is
currently un-tracked.

## Grouped build: eval speed (done) vs incremental rebuild (open) — task #80

The grouped lowering (task #78) built every ninja edge's command + staging script as a Nix
string DURING EVAL, so whole-Darling eval was ~15-40 min, paid on every build (the graph-json
IFD busts Nix's eval cache). Fixed by **build-time lowering** (`nix/lib/nix-ninja/build/lower_group.py`,
flag `buildTimeLowering`): Nix eval now computes only each group's `{edge list, external-group
drvs}`; the tool reads the shared `graph.json` in the sandbox and does the rewrite/stage/run.
Measured: `darling-full-group-bt` eval **~58 s** (was ~35 min); migcom + libSystem green through
it. `darling-{group-test3,libsystem-group,full-group}-bt` exercise it; the legacy eval-time
`mkGroup` path is untouched behind the flag.

**Incremental rebuild is a separate, still-open problem, and it is NOT just source staging.**
A small source edit currently triggers a ~full recompile, because of a chain of store-path
couplings that all rehash on any source change:
- `cmakeSrcStore` (whole source tree) rehashes → CMake **re-configures** (~min) →
- `build.ninja` bakes absolute `cmake-src` / `cmake-ninja-configured` paths → the **graph-json
  (`graphDrv`) rehashes** (confirmed: `graphDrv` contains those store paths) →
- every bt group derivation reads `graphDrv` (and mounts the rewrite roots) → **all ~900 groups
  rebuild**.

So per-component source staging alone cannot deliver incrementality — `graphDrv` is the dominant
blocker. The full fix is three pieces, in order:
1. **Relativise the graph** so `graphDrv` is content-stable across source edits (strip the
   rewrite-root prefixes in the graph-json derivation; make it content-addressed so a re-config
   that yields byte-identical relative content keeps the same store path). This is the key
   enabler — without it (2)/(3) are moot.
2. **Per-component source subtrees** (`builtins.path` slice of `cmakeSrcStore/<component>`,
   content-addressed): a group depends only on its component's subtree, so editing one `.c`
   re-keys just that component. Keeps eval fast (no per-file `indivOf`/`readDir` in eval).
3. **Configure decoupling**: feed the configure derivation only CMake-relevant files so a
   `.c`-content edit does not re-run cmake at all.

Honest architectural note: this is exactly where the nix-ninja + IFD approach hits its
structural ceiling. Even done perfectly, it re-evaluates every build (~58 s) and its
incrementality is per-*derivation* (whole component recompiles), never per-*action* (one `.o` +
relink). **Buck2's persistent daemon avoids all of these store-path-rehash couplings by design**
(no configure/eval per build, per-action deps) — so the fast edit->rebuild inner loop is the
genuine case FOR a Buck2 port, distinct from the eval-speed problem (which was a fixable Nix
issue, now fixed). Recommendation: finish the full-green grind (#2) + implement (1)-(3) to get a
~1-3 min component-incremental loop with no port; treat Buck2 as the deliberate next step only if
that loop proves too slow for how Darling actually gets developed.

### Full-green grind (#2): where it stands (branch `wip-mega-group-unwind`)

The build-time path (`darling-full-group-bt`) grinds green through migcom -> libSystem -> duct-tape
-> libc -> and reaches the `security/*` / openssh tier. Mechanical gaps fixed along the way (all
committed): skip CMake housekeeping targets, shebang rewrites on staged sources AND generated script
outputs, rspfiles, ext-dir de-symlink before cp, command-referenced source staging, srcHeaders
non-header include-chain data (`.exp`/`.exp-in`/`.list`/`.ipp`), cctools ar+ranlib co-grouping by
OUTPUT tool dir.

Wall #2 from the earlier note (the `build-mig` dense-staging mega-SCC) is now UNWOUND, and the
duct-tape `notify.h` wall is FIXED. Committed on the branch (`639e374e`, `c723f265`):
- **notify.h source-restore** (`lower_group.py`): `mach/notify.h` exists as BOTH a hand-written
  source header (defines `MACH_NOTIFY_*` + the notify structs) and a mig re-emission (routine stubs
  only). The merged `$out` cannot hold both; mig's copy shadowed the source and broke every
  `<mach/notify.h>` kernel consumer. Fix: after a source-backed generated header is produced, restore
  the authoritative source copy over it (the mig `.c` consumers only need the structs, also in source).
- **mega-SCC unwind** (`lower.nix`): `rawHeaderProducerGroups` is now GROUP-LEVEL pure -- a mixed
  pure-gen + compile-dependent group no longer becomes a universal dep, so `build-mig` no longer
  absorbs duct-tape/bootstrap_cmds/... Mixed-group header producers retarget per-component via
  `migByCompDir` (which skips source-backed headers).
- **Tarjan SCC topo** (`lower_group.py`): the old Kahn fallback dumped a blocked SCC's edges in
  list order, mis-ordering acyclic producer->consumer pairs riding on the SCC (libc's dylib link ran
  before the `notify_firstpass` it links). Replaced with iterative Tarjan condensation (producers
  first; only genuine cycles emit as a block). Fixed libc.

Remaining `darling-full-group-bt` failures (18, taxonomised), in priority order:

1. **Source header shadows a SYSTEM header for a C compile (WALL #1, ~14 failures, dominant).**
   Confirmed via the compiler's `In file included from` chain (NOT a plain libcxx-on-`-I` issue):
   a C compile in `security/*` (e.g. `Security_x86_64_only_stuff`, `SecLogging.c`; `-std=gnu99`, no
   `-isysroot`) includes the SDK's `corecrypto/ccdigest.h` -> `cc.h` -> `cc_config.h:429`, which does
   `#include <endian.h>`. That resolves to `src/external/security/OSX/libsecurity_utilities/lib/
   endian.h` -- a SOURCE header shadowing the system `<endian.h>` because security's lib dir is on the
   compile's `-I` list -- and it drags in the security_utilities C++ chain (`utilities.h` -> `errors.h`
   -> `<exception>` -> libcxx `<cstddef>`), which is C++-only and explodes in C mode (`unknown type
   name 'using'`). So the trigger is `-I` precedence over SYSTEM headers, not libcxx per se. The
   reference build avoids it (some mix of `-isysroot`, `-iquote` vs `-I`, or not having that lib dir on
   the C compile's search path); our flat merged-`$out` + broad `-I` list does not. Fix needs deliberate
   header-search scoping so source-tree dirs do NOT shadow toolchain/SDK system headers for a compile
   that only asked for `<endian.h>` -- e.g. move project header dirs to `-iquote`/`-idirafter`, or add
   `-isysroot <SDK>` AND ensure system-name includes prefer the sysroot. This is the genuinely DEEP
   design wall (same class the eval-time `mkGroup` path would hit); needs a header-search decision, not
   a one-line strip. UNVERIFIED fix.
2. **libbsm cross-group `libSystem.B.dylib` staging (1 failure, foundational).** `libbsm` links the
   final umbrella `libSystem.B.dylib`; at BUILD time it is missing from libbsm's group sandbox. Ground
   truth (instrumented): libbsm's group ran but did NOT contain the libSystem.B producer edge, and the
   umbrella dylib was not ext-dir-staged in -- yet an eval probe reported the two edges in the SAME
   group with the producer in `extGids`. That **eval-vs-build grouping inconsistency** is the bug to
   chase next (idsInGroup vs the `--edges` actually passed, or a realProducers path-form mismatch).
3. **Generated data files not staged (2 failures).** openssh `ge25519_base.data`, libsecurity_cssm
   `derived_src/funcnames.gen` -- generated non-header data a compile reads, not reaching the sandbox.

Status: the eval floor is fixed+committed; the notify.h wall + mega-SCC are fixed+committed; libc
green. `main` stays green on the default (eval-time) path and `darling-{group-test3,libsystem-group}
-bt`; `libSystem-group-bt` is green on the build-time path too (re-verified). `full-group-bt` green
through libc; the dominant remaining blocker is WALL #1 (root-separation). The generic `nix-ninja`
lib is upstreamable to overby.me (sibling to its buck2/cargo libs; rust-ninja extractor already
lives there) -- root-separation is the main pre-upstream item.
