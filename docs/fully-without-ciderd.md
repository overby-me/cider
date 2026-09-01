# Fully without ciderd (the endgame)

Status: roadmap (2026-08-29). The user clarified the xnu-rpc-free goal is **FULLY** without
ciderd, not "mostly": a guest process must run with ZERO ciderd RPCs and, ultimately, no ciderd
daemon at all. This doc is the structured campaign from the current state (~30 RPCs/spawn, all
served by the ciderd daemon) to that endgame. See [[cider-xnu-rpc-free-goal]] and docs/xnu-rpc-free.md
(the incremental-reduction design that landed 0047-0050, 43->30/spawn).

## What ciderd actually is (why this is a re-architecture, not a tweak)

ciderd (`src/linux/server`, a persistent Linux daemon) is FOUR things bundled:
1. **The emulated XNU kernel** -- 1620 C files / 77MB under `vendor/pins/ciderd/xnu-sys` plus the
   Rust glue in `src/linux/server/src/xnu/` (task/thread/ipc_space/ipc_port/ipc_kmsg/vm/semaphore/
   psynch/kqueue). Holds the kernel state for every guest task.
2. **The container / filesystem** -- `container.rs`: private mount namespace, prefix overlay, the
   macOS root view. Set up once at daemon boot (`ciderd.rs:259`).
3. **The RPC server** -- per-thread unix socket -> epoll -> `rpc_wire::dispatch` -> `handler.rs`,
   run on cooperative microthreads (`sched.rs`) so many guests are served concurrently.
4. **The process lifecycle** -- `registry.rs` tracks tasks; checkin/checkout register + reap; a
   pidfd death-watch drives teardown (Pass 136-138).

"Fully without ciderd" means all four stop being a separate daemon: the guest owns its XNU state
IN-PROCESS, the launcher owns the container, and the lifecycle is Linux-native.

## Architecture

Two regimes, because the hard part is cross-process:

- **Self-contained guest (single process, no cross-task Mach IPC): a LEAN in-guest XNU.** exec true,
  and most leaf build steps (cc, ld, a shell command), never send a Mach message to ANOTHER task --
  all their Mach traffic is self-ports, reply ports, kernel queries (host_info, special ports), and
  self-VM. That subset does NOT need the 1620-file kernel; it needs a few hundred lines of guest-side
  bookkeeping in libsystem_kernel: an in-guest port table (mint names, track urefs, deliver a message
  to a local queue), synthesized MIG replies for the static kernel queries, and the already-landed
  self-VM short-circuit. This is the tractable near-term target and it is where the RPC count actually
  goes to 0 for the common case.
- **Cross-process guest (bash pipelines to other guests, launchd, notifyd, XPC): shared-memory kernel
  state.** When a port name must be understood by ANOTHER process, a per-process table is not enough.
  The emulated XNU state (or the subset that escapes) moves to a shared-memory segment all guests map,
  operated on in-process with locking -- a "kernel" with no central thread. This is the deep part and
  is deferred behind the self-contained milestones; it is what finally removes the daemon entirely.

## The RPC surface, and how each op leaves ciderd

Per-spawn calls (post-0050 histogram) and their in-guest disposition:

| call | now | in-guest plan | regime |
| --- | --- | --- | --- |
| mach_vm_allocate/deallocate/protect (self) | mmap already | DONE | self |
| task/host/thread_self_trap | cached fetch | mint FIXED local names (real XNU uses fixed task-self); no RPC | self |
| host_info / host_get_io_master / task special ports | cached (0048) | SYNTHESIZE the MIG reply in-guest (static data + minted port names) | self |
| mach_reply_port(_batch) | pooled (0047) | mint reply-port names in-guest, no batch RPC | self |
| mach_msg_overwrite | cache (0048/0050) | in-guest port table: local enqueue/dequeue + synthesized kernel replies | self |
| mach_port_deallocate / mod_refs | guard (0049) | in-guest uref table | self |
| uidgid | seeded (#25) | serve from the seed / Linux getuid; no RPC | self |
| vchroot_path | seeded (#25) | resolve in-guest against the known prefix root | self |
| set_thread_handles | RPC | in-guest thread table | self |
| checkin / checkout / fork_wait / started_suspended / get_tracer | RPC | launcher spawns + waitpid + a pipe for rc; no daemon registration | lifecycle |
| kqchan_proc_open / mldr_path | RPC | launcher passes mldr path in apple[]; death via waitpid | lifecycle |
| mach_msg to bootstrap / launchd / another task | RPC | shared-memory kernel routing | cross |

## Milestones (each buildable + gated via the buck2 swap, no nix)

1. **In-guest self-ports + kernel-query synthesis.** task/host/thread_self mint fixed names;
   mach_msg to those ports synthesizes the reply in-guest. Kills self-port fetches + the queries
   (~7-10 RPCs). Extends mach_traps.c's self-VM precedent + the 0048/0050 cache. **START HERE.**
2. **In-guest port table + self-IPC.** Reply ports minted locally; mach_msg to own/reply ports
   enqueues/dequeues in a guest table; deallocate/mod_refs update urefs. Kills reply_port + the
   remaining mach_msg + deallocate.
3. **In-guest uidgid + vchroot + set_thread_handles.** Serve from the seed / Linux / a guest table.
4. **Launcher-managed lifecycle.** Launcher spawns the guest, sets up the container itself
   (namespaces + prefix mount, moved out of ciderd), waitpids for the exit code; no checkin/checkout.
   This is the milestone that lets a guest run with the ciderd daemon NOT PRESENT.
5. **exec true with 0 RPCs and no ciderd process.** The self-contained endgame -- gate: `cider exec
   true` works with ciderd never started; RPC count 0; correctness + soak.
6. **fork/exec + bash** (in-guest fork registers the child in the guest/launcher, no ciderd).
7. **Cross-process: shared-memory kernel** for bootstrap/launchd/XPC. Removes the daemon for the
   general case.

## Milestone 1 status + key finding (2026-08-29)

**Milestone 1 (in-guest self-contained Mach IPC) is essentially COMPLETE: exec-true RECV 70 -> 25
flag-on, rc=0, soak 12/12** (patches 0051-0056, gated by CIDER_INGUEST_IPC, flag-off = baseline
70 -> 59 after the #25 dylib-seed fix). All served fully in-guest, 0 ciderd RPC:
- kernel queries: host_info(200), host_get_clock_service(206), task special ports(3409/3418) -- data +
  COMPLEX port-descriptor replies byte-identical to ciderd's; port-returning ones mint guest-owned
  names in a reserved 0xE0000000+ port table (deallocate/mod_refs on them served in-guest).
- the per-thread MIG reply port (minted in-guest -- 0 ciderd mach_msg remain, so it's never sent out).
- host_self + thread_self (minted); task_self + uidgid + vchroot SEEDED into the dylib copy too (0055
  moved the #25 checkin seeds out of #ifdef VARIANT_DYLD -- the general baseline win 70 -> 59).
- set_thread_handles skipped (ciderd stores it, never reads it).

The load-bearing bug (days of "blocked on ciderd state") was buffer aliasing: mach_msg_trap passes
rcv_msg = msg, so the reply memset zeroed the request's msgh_id before it was read (reply id 100 not
300 -> MIG stub rejected -> host_info() error -> pthread init assert). Fix: read request fields first.
The dyld-loader copy needs NO separate patch -- it compiles the same patched sources, so a prefix build
gets it (validated by rebuilding //vendor/src/dyld:dyld: RECV 34 dylib-only -> 25 both copies).

Remaining flag-on RECV=19 (after 0057) is NOT self-contained Mach; it is the harder next phases:

## Milestone 3/4: the harder remaining, ordered (the endgame dependency)

Flag-on RECV=19 (exec-true, after 0057; 18 after 0058) = vchroot_path x5, checkin x4, uidgid x2,
checkout x2, mldr_path x2, vchroot x1, task_self x1, kqchan_proc_open x1, fork_wait_for_child x1.
(This host's `cider exec` cannot resolve macOS paths: its launcher realpath validates against the host
FS, which lacks /usr/bin/true, so measure with `cider shell /usr/bin/true` instead. That is a heavier
bash-boot baseline, flag-on RECV 42 with the same RPC mix. See the cider-test-recipe-nix-host memory.)

- **Milestone 3 (BSD): mldr_path LANDED (0059); vchroot_path/uidgid remain.** mldr_path was gated-safe
  after all: the RPC only echoes DSERVER_MLDR_PATH, which mldr also leaves in /proc/self/environ, so
  sys_execve reads it in-guest with an RPC fallback (new inguest_environ_value(), mirroring
  host_loader_path). shell workload mldr_path 5 -> 0, RECV 42 -> 37, rc=0, soak 8/8, flag-off unchanged.
  vchroot_path/vchroot return the container prefix root. ATTEMPTED the mldr_path env-technique and
  REVERTED: expose the prefix as DSERVER_VCHROOT_PATH in the env (it propagates launcher->guest, value
  is correct) and read it in init_vchroot_path via inguest_environ_value when flag-on. Result: the
  container init (guest PID 1) CRASHES -- setting prefix_path before its thread registration breaks
  early-init ordering (the vchroot_path RPC there doubles as a sync point). Excluding PID 1 stops the
  crash but reduces 0 RPCs: every vchroot_path fetch is an early (pre-mach_driver_init) init context
  where the /proc/self/environ read is premature or the process otherwise resists it. So unlike
  mldr_path (whose RPC is in sys_execve, well after init), the vchroot_path RPCs are STRUCTURAL
  early-init fetches; the env-read technique does not transfer without reworking the init's early
  path-resolution ordering. Delicate, deferred.

  CORRECTION (session 2, RPC-attribution by ciderd nsid): the GUEST is already CLEAN of vchroot_path.
  The seed (apple[] dserver_vchroot) is applied in __libkernel_init -> mach_init(apple) -> __vchroot_seed
  BEFORE any path op, so the guest never hits init_vchroot_path. The vchroot_path (#3) RPCs all come from
  SHELLSPAWN (nsid=1, the container-setup process, pre-vchroot): its apple[] lacks dserver_vchroot because
  the container is not set up yet, so it legitimately RPCs ciderd to establish + read the vchroot.
  Eliminating them = re-architecting container SETUP (launcher/ciderd own the vchroot), a milestone-4
  concern, NOT a guest seed. So the earlier "vchroot in-guest" attempts targeted the wrong process. The
  guest's own remaining RPCs are uidgid x2 + checkin/checkout: uidgid RPCs because __getuidgid_seed got no
  valid uid/gid (getuid.c aborts-or-RPCs when stored_uid/gid == -1; lkm.c seeds only if both
  dserver_uid/gid >= 0 in apple[]), so the loader/checkin handed uid/gid = -1 for that process. NEXT WIN
  LEAD: attribute the 2 uidgid (fetch getuid.c:41 vs set getuid.c:63) and why seed_uid is -1 (checkin
  reply / stack.rs fold); if a real fetch with a bad seed, provide valid uid/gid so the existing seed
  wires it like vchroot -- the most tractable remaining guest-side win.
- **Milestone 4 (lifecycle): fork_wait + checkout + fork-checkin removed; only exec-checkin + shellspawn
  infra remain.** The earlier belief that "checkout/fork_wait hang off checkin" was WRONG, and so was
  treating the "checkin abort" as a deep unfixable signal-routing bug. fork_wait (0062): child
  self-checks-in, parent reaps via in-guest wait4. checkout (0063): ciderd's #30 exec-reuse reaps the
  old thread at the new image's re-checkin; the #33 death-watch cleans the rest. **fork-checkin (0064):
  RESOLVED the 3-session abort.** The abort was never caused by skipping checkin -- it was the HALF-OPEN
  connection prior attempts left by skipping only the checkin RPC while KEEPING the socket refresh.
  Skipping the WHOLE post-fork dserver block (socket + lifetime pipe + guards + checkin) removes the
  half-open state and the abort. A self-contained fork child then makes zero RPCs and is invisible to
  ciderd (nothing allocated to leak); an exec'd child gets mldr's checkin + the death-watch. The
  remaining checkins are mldr EXEC-checkins, still load-bearing (initial registration + the
  exec-replacement reap that checkout-skip depends on, e.g. bash's --login re-exec), and mldr cannot
  cheaply tell an initial registration from a replacement -- so removing them is the launcher/shellspawn
  re-arch (ciderd stops registering; the container init reports births/deaths), a genuine multi-part
  effort. Not gated on the abort anymore -- that wall is gone.

Net (session 4): flag-on `shell /usr/bin/true` RECV 25 -> 12 (cumulative 132 -> 12). Landed + gated +
soak-verified (simple + a 100-exec bash loop + 200 pure-fork subshells, flag-off unchanged at 132):
checkout 5 -> 0 (0063); vchroot_path 8 -> 4 (mldr recovers the prefix locally; the loop test caught +
fixed an empty-prefix bug for a host-resolved shebang argv0); fork-checkin 10 -> 6 (0064, the abort
fix). Remaining 12: checkin x6 (mldr exec-checkins: nsid 1/2/3/5), vchroot_path x4 (init x3 + basename
cp), vchroot x1 + kqchan x1 (shellspawn container setup). 7 of the 12 are nsid=1 (shellspawn/init) infra.
The rest is the launcher/shellspawn re-arch.

## Milestone 4 design (detail): launcher-managed lifecycle

What each lifecycle RPC does (read from src/linux/server/src/handler.rs + the guest callers):
- **checkin** (fork.c, per process + per fork child): registers the process and does THREE things --
  (a) queues a ciderd DEATH-WATCH (pidfd reap when it exits), (b) UPs the parent's fork semaphore
  (this is what fork_wait_for_child parks on), (c) returns the SEED reply (task_self/host_self/uid/gid/
  vchroot -- the #25 seed the guest caches).
- **checkout** (execve.c, on re-exec): `thread::dying(...)` tears down the thread's emulated-XNU state
  + closes the lifetime pipe.
- **fork_wait_for_child** (_mach_fork_parent): the parent parks on the fork semaphore until the child
  checks in.
- **kqchan_proc_open** (for-libkqueue.c): the parent's EVFILT_PROC exit-watch on the child.

**Key insight:** for the SELF-CONTAINED case, ciderd's per-task/thread emulated-XNU state is now UNUSED
-- every Mach op is served in-guest (milestone 1) and task_self is guest-owned (0058). So checkin/
checkout are pure bookkeeping that a LAUNCHER can own instead:
1. **Container:** the launcher sets up the namespaces + prefix overlay (today ciderd at boot,
   container.rs) and spawns the guest into it.
2. **Reap:** the launcher waitpids the guest for the exit code -- replaces the checkin death-watch +
   checkout + kqchan_proc_open exit-watch.
3. **Fork:** an in-guest fork no longer needs the ciderd sync if the child does not check in; the
   fork semaphore + fork_wait_for_child existed only to order the child's checkin.
4. **Seed:** uid/gid already ride apple[] (#25); task_self/host_self are minted in-guest (0054/0058);
   vchroot from the seed -- so no checkin reply is needed.

**Dependency / order:** this only holds once NOTHING the guest does needs ciderd -- true for the Mach
side, but the milestone-3 BSD RPCs (vchroot_path/uidgid/mldr_path) still hit ciderd, so they must move
in-guest FIRST or they keep the daemon alive. Then checkin/checkout/fork_wait/kqchan can be gated off
guest-side WHILE the launcher takes spawn/reap/container.

**Risk / why this needs the user:** this alters the BASELINE (launcher + ciderd + guest, not a gated
guest-only flag), touches fork/exec correctness (the checkin is load-bearing -- vfork attempts broke
exec, plan-aarch64 Pass 126), and is the riskiest part of the campaign. It is NOT an autonomous grind:
it wants a real design review + fork-heavy/login/build validation. Recommended sequencing: (i) finish
milestone-3 BSD in-guest (carefully -- vchroot is startup-fragile); (ii) prototype the launcher
waitpid-reap path + the guest-side checkin/checkout skip together, behind the flag, with heavy
validation; (iii) only then remove the daemon for the self-contained case.

What landed (behind `CIDER_INGUEST_IPC`, a dev flag, default OFF; flag-off is byte-identical baseline):
- **Dual-variant apple[] flag.** libsystem_kernel is compiled twice (the dyld loader's VARIANT_DYLD
  copy for early traffic, and libsystem_kernel.dylib for the guest); each has its OWN mach_traps.c
  statics. The guest's host_info runs through the DYLIB copy (`mach_init_doit -> mach_driver_init(apple)`
  at libc init), so any in-guest gate/seed must be parsed OUTSIDE the `#ifdef VARIANT_DYLD` block to
  reach both copies. This is the reusable lever for every future in-guest gate. The loader
  (`stack.rs`) folds `cider_inguest_ipc={0,1}` into apple[] from mldr's env (NOT getenv in-guest:
  getenv from mach_msg during early init hangs).
- **host_info reply synthesis**, flavor-aware (BASIC + PRIORITY), recursion-safe (cpu/mem via direct
  `sched_getaffinity`/`__linux_sysinfo`, never sysconf, which IS host_info).

The days-long "blocker" was NOT ciderd state -- it was a **buffer-aliasing bug**. `mach_msg_trap` passes
`rcv_msg = msg`, so the reply buffer aliases the request; the synthesis read `req->msgh_id` for the reply
id AFTER `memset(rcv, 0, ...)`, which had zeroed the aliased request -> reply id 100 instead of req+100
= 300 -> the MIG stub rejected the reply -> `host_info()` returned an error -> pthread init's
`host_info() != KERN_SUCCESS` assert (a `brk #1` in `___pthread_init`) fired. The shadow test that
"proved state" used a scratch buffer (no aliasing), masking it. Symbolicated via `DSERVER_TRACE_SIGNAL=5`
(gave rip + insn) + a byte-pattern search of the guest dylibs. Fix: read every request field into a
local before the reply memset.

**Consequence for the campaign: the data-only queries do NOT need the port/thread layer.** host_info is
proof. Next are the PORT-RETURNING queries (host_get_io_master 206, task special ports 3409/3418): those
need in-guest port NAMES for the returned ports, which is where the port table below comes in -- but the
reply-port/per-thread-state fear is retired.

## In-guest port table: design (the milestone-1/2 core)

The finding forces the shape. Because MIG reuses ONE per-thread reply port (`mig_get_reply_port`)
for every kernel query, making that reply port guest-owned makes ALL of a self-contained thread's
Mach queries in-guest **atomically**: you cannot hand an in-guest reply-port name to ciderd for a
query you did not synthesize. So milestone 1 is the whole self-contained query set at once, not one
routine at a time.

Structure (mach_traps.c, gated by `CIDER_INGUEST_IPC`):
- **Reserved range `0xE0000000+`** for guest-owned port names (ciderd's names sit far lower, no
  collision). A small fixed table `{name, kind (recv/send/send-once/dead), urefs}`, minted
  monotonically.
- **`mig_get_reply_port` (gated):** return a guest-minted receive-right name instead of the ciderd
  reply-port pool (0047). This one switch is what makes the thread self-contained.
- **`mach_msg_overwrite` (gated):** when the destination is a self/host/task/guest name, serve
  in-guest and never touch the socket:
  - host port -> route by msgh_id: host_info(200, data-only, DONE + byte-verified),
    host_get_io_master(206) -> a guest-minted io_master send right, host_get_special_port, ...
  - task port -> task_get_special_port(3409/3418) -> guest-minted send rights.
  - Reply header: `msgh_local_port` = the reply port, MOVE_SEND_ONCE in the LOCAL field, id=req+100,
    NDR int_rep=1, RetCode 0, payload, 8-byte format-0 trailer; consume the reply-port send-once in
    the table.
- **Port-returning queries** mint a guest name for the returned port; callers later
  deallocate/mod_refs those names -> handled in-guest via the table (task_self's 0049 deallocate
  guard is the precedent).
- **`mach_port_deallocate` / `mod_refs` / `mach_port_type` (gated):** name `>= 0xE0000000` -> table;
  else RPC.
- **Safety fallback:** switch `mig_get_reply_port` to in-guest only if EVERY query the thread will
  issue is synthesizable; an unknown msgh_id must abort the in-guest path for that thread (back to
  ciderd) rather than leak a guest name to the daemon.

Query set for exec-true (flag-off RECV histogram): 200 host_info, 206 host_get_io_master, 3409 +
3418 task special ports. Notifications (id 1/2) and the checkin/checkout lifecycle do NOT use the MIG
reply port and stay on ciderd until milestone 4. Dev loop: temporarily FORCE the in-guest reply port
(bypass the safety fallback) and add one query at a time -- exec-true dies one query later as each
lands (crash-advance) until it completes with 200/206/3409/3418 all at 0 RPC; then re-enable the
fallback for production.

## Correctness discipline (unchanged)

Every milestone gated via the buck2 dev-loop swap (build the changed components, swap into a prefix
copy, measure -- see [[cider-buck2-dev-loop]]): RPC count drops, exec true 50x + 16-way + fork-heavy
correct, no ciderd leak, ciderd survives (until milestone 4 removes it). One heavy build at a time.

## Milestone 4 refined (session 2): reaping is ALREADY in-guest, so it is more tractable

Guest BSD is now COMPLETE (mldr_path 0059 + uidgid 0060). The remaining ciderd RPCs are the lifecycle.
KEY FINDING: the guest reaps its own children via LINUX_SYSCALL(__NR_wait4) (wait4.c:36), NOT through
ciderd -- so the launcher does NOT need to reap. ciderd's death-watch (task #33) is only for (a) its own
task cleanup (N/A without ciderd) and (b) kqchan_proc_open (a guest watching a process via kqueue
EVFILT_PROC). So the lifecycle RPCs are ciderd-TRACKING, not reaping.

For NO ciderd (Mach in-guest milestone-1 + BSD in-guest; a forked child INHERITS prefix_path/stored_uid/
reset ports, so it needs no RPCs except the lifecycle):
- checkin (fork.c:61, per-fork) -> SKIP flag-on + skip the RPC-socket/lifetime-pipe refresh.
- checkout (execve.c:434, exec/exit teardown) -> SKIP flag-on (nothing to tear down without ciderd).
- fork_wait_for_child (#11) -> NO guest emulation call site; triggered server-side or by mldr -- find it,
  it may not need gating.
- kqchan_proc_open (#29) -> serve in-guest via Linux pidfd_open(target) feeding the kqueue EVFILT_PROC,
  or verify it does not fire for the self-contained case.

PLAN (coordinated, flag-on, validate via `cider shell /usr/bin/true`, revert on ANY break/hang, never
regress flag-off): (1) gate checkin + socket/pipe refresh (fork.c); (2) gate checkout (execve.c); (3)
kqchan in-guest pidfd or verify absent; (4) confirm fork_wait does not hang. Then ciderd is unneeded for
the self-contained case. This IS validatable (shell forks/execs/reaps bash + children), so attempt it
incrementally rather than flag it -- but stop + revert on the first hang/crash given the crashed-session
history.

## Milestone 4 -- the lifecycle skip is multi-target + cascading (session 2/3, final map)

STATUS: four incremental guest-side wins are COMPLETE -- milestone-1 (in-guest self-contained Mach IPC),
milestone-3 (in-guest BSD: mldr_path 0059 + uidgid 0060), the interrupt gate (0061), and the fork_wait
skip (0062). A self-contained guest's Mach + BSD + forwarded-signal handling run with 0 ciderd RPCs.
`cider shell /usr/bin/true` flag-on RECV 35 -> 25 (0061 + 0062); flag-off 132; both rc=0, soak.

interrupt (0061) was NOT the delicate signal-exception-delivery piece feared earlier. Trace shows bash's
signals fire the NON-ptraced handler_linux_to_bsd_wrapper (sigaction.c), which brackets the forwarded
handler in interrupt_enter/exit but does NO sigprocess. Those brackets are no-ops for the self-contained
case: sigexc_enter's clear_wait has no in-guest Mach wait to interrupt, and the user_state sigexc_enter2
pushes is read only by thread_get_state, which a plain forwarded handler never calls. So gating them
flag-on is safe + validatable. The PTRACED sigexc_handler+sigprocess path is separate and still
load-bearing (not hit by an unattached process).

The remaining flag-on 25 are ALL structural: #1 checkin x10, #3 vchroot_path x8 (SHELLSPAWN container
setup, nsid=1), #2 checkout x5, #9 vchroot x1, #29 kqchan x1 (fork_wait is now 0 via 0062). Key: ciderd's
per-task state is UNUSED for the self-contained case (the guest mints its own ports since 0058), so
checkin creates a task nothing reads -- yet the mechanisms are load-bearing:
- checkin supplies state the fork child's libc needs post-fork, beyond registration (set_current
  auto-registers) and beyond the minted #25 seeds: skipping it makes the child abort() (raw libc SIGABRT
  via the ptraced sigexc_handler path). Load-bearing; the abort root is still open.
- checkout's essential job is CLOSING the lifetime pipe (handler.rs:471) -- skip it and ciderd leaks one
  pipe read-end per process, reproducing the config.status write() hang (a real M1 bug). Not a gate.
- kqchan_proc_open here is SHELLSPAWN's (nsid=1) watching the guest -- infra, not a guest gate.

ORDERED plan to remove the lifecycle:
1. kqchan in-guest -- NOT a raw pidfd as out_socket (that HANGS: cider's libkqueue linux/proc.c is the
   ciderd-socket client -- it epolls the socketpair and reads SEQPACKET NOTE_EXIT frames in
   evfilt_proc_copyout, so a bare pidfd yields no frame; posix/proc.c is EVFILT_NOTIMPL). The real fix is
   rewriting that filter to epoll pidfd_open(target) directly and synthesize NOTE_EXIT locally -- bounded
   to one filter file, but its own libkqueue build target + delicate kqueue semantics (oneshot/rearm).
2. fork_wait skip -- LANDED (0062). _mach_fork_parent skips dserver_rpc_fork_wait_for_child flag-on; the
   child checks in itself and the parent reaps via in-guest wait4. shell RECV 29 -> 25, rc=0, soak 3/3.
   Isolated cleanly: fork_wait alone has ZERO aborts.
3. checkin skip (fork.c) -- NOT viable yet. set_current auto-registers the child (registration is not the
   blocker) and skipping checkout too does not help, but skipping checkin makes the fork child abort()
   (raw libc SIGABRT, group-propagated from the aborting nsid, via the ptraced sigexc_handler path; the
   saved rip is bogus). checkin supplies libc-needed state to the fork child; cracking that root (what
   state, supplied in-guest) is the next thread -- it unblocks checkin (10) then checkout (5). (vfork
   broke exec at Pass 126 -- lifecycle changes are delicate.)

VALIDATION remains the binding constraint on THIS host: `cider exec` (the clean signal-free case) is
rc=1 (SYSTEM_ROOT/container quirk), and `cider shell` (bash) exercises the full lifecycle. A working
exec-true baseline (launcher exec fix or full prefix build) would de-risk step 2. This is a dedicated,
careful, high-risk effort -- not an incremental gate.

## Milestone 4 -- checkin-abort root exhaustively characterized (session 3) + the plan

The checkin skip (fork.c) is blocked by a TEARDOWN abort, traced end-to-end this session (all instruments
reverted; baseline clean at flag-on RECV 25):
- nsid 5 = /usr/libexec/path_helper, a LOGIN-CHAIN helper (tree: shellspawn(1) > bash(2) > cp(3) +
  path_helper(5) + subshell(4)), NOT the user's command. path_helper's source is CLEAN (read /etc/paths,
  print, return 0; no kill/abort). So `true` still returns rc=0.
- Without its fork.c checkin, path_helper (which is exec'd + mldr-checked-in) emits a spurious group
  SIGABRT (SI_USER, sender=5) that kills innocent siblings blocked in sys_read (bash nsid 2) + sys_wait4
  (subshell nsid 4); they self-terminate via the sigexc default-effect. It is TEARDOWN-phase.
- path_helper itself shows NO EXIT-PRE (never reaches sys_exit) and NO SIGABRT-IN (never receives via
  sigexc) -- it dies abnormally with neither a normal exit nor a caught signal.
- The SIGABRT-send BYPASSES every instrumentable kill path: guest sys_kill (KILLBT never fired),
  sigexc:487 default-kill (DEFKILL was only the receivers self-killing, self_pid 2/4), and ciderd's
  send_thread_signal (tgkill = SI_TKILL, but this is SI_USER). So the send is the guest libc abort/
  pthread_kill path OR the emulation's exit/reap of a checkin-less process, mis-resolving the target --
  most likely a Mach thread-port mapping corrupted by the skipped fork checkin.
- Instruments used + reverted: fork.c checkin gate; sigexc ABORTBT (tstate.__pc/__lr + fp-walk) +
  SIGABRT-IN; kill.c KILLBT; sigexc:487 DEFKILL; execve EXECVE path; exit.c EXIT-PRE/POSTFINI.
  Symbolication: DYLD_PRINT_SEGMENTS=1 + `llvm-nm -n` (abort pc = _linux_syscall in libsystem_kernel).

DIAGNOSIS: the fork->exec transition WITHOUT the fork.c checkin corrupts the exec'd process's
post-mldr-checkin ciderd-side per-thread signal-routing, so a routine teardown signal is mis-delivered to
relatives. checkin's load-bearing role is NOT registration (set_current auto-registers from SO_PASSCRED)
nor the #25 seeds (milestone-1 mints task_self/host_self, 0060 seeds uid/gid) -- it is establishing the
per-thread signal-routing state that must survive the exec.

PLAN (multi-session, in priority order):
1. Fix the checkin-abort in CIDERD: make per-thread signal routing consistent for a process whose fork.c
   checkin was skipped (its teardown signal must target itself, not relatives). Deepest piece; look at
   handler.rs set_current auto-register + the thread/task creation vs the checkin path + send_thread_signal
   target resolution. Validate: skip checkin+fork_wait+checkout flag-on -> cider shell rc=0, no SIGABRT,
   RECV well below 25.
2. If (1) is intractable, PIVOT to the launcher-managed lifecycle (the original design above): the launcher
   owns the container + reaps via in-guest wait4 + serves the seeds, removing ciderd from the lifecycle
   entirely -- bigger but cleaner, and it sidesteps the checkin-skip exit-abort.
3. vchroot_path x8 + vchroot x1: shellspawn container bootstrap (structural early-init; the env-seed
   technique crashed PID 1). Needs shellspawn's early path-resolution reworked.
4. kqchan x1: shellspawn's libkqueue EVFILT_PROC; rewrite linux/proc.c (the ciderd-socket client) to a
   pidfd -- bounded to one filter, delicate oneshot/rearm; libc/system_c build target.
5. SEPARATELY, task #24 (JSC arm64 LLInt/WASM offline-asm link failure) blocks the FULL prefix build;
   unrelated to the lifecycle.

STATUS (session 3 end): 4 patches landed (0059 mldr_path, 0060 uidgid, 0061 interrupt, 0062 fork_wait),
flag-on RECV 35 -> 25, milestone-1 + milestone-3 complete. The remaining is a dedicated multi-session
re-architecture; the checkin-abort (the bulk, checkin x10 + checkout x5) is now precisely characterized
above so a future session can go straight to the ciderd-side fix or the launcher pivot.

## Milestone 5 LANDED (session 4) -- socket-less non-pid-1 procs run END-TO-END

Bookmark milestone5-socketless-signals (commit 8ca032ce). A flag-on non-pid-1 process now runs with NO
ciderd socket: (1) mldr skips create_socket+checkin, seeds uid/gid from local getuid/getgid (fixes the
startup abort), recovers vchroot locally; (2) mldr rpc::set_sockpath fills SERVER_ADDR so sys_execve
builds the child's __mldr_sockpath instead of deref'ing a NULL sockaddr (the strlen(0x2) SIGSEGV,
sun_path at offset 2 of NULL); (3) patch 0065 gates sigexc_handler's interrupt_enter/sigprocess/
interrupt_exit via __cider_no_daemon(), and the EXISTING in-guest default-effect path (sigexc.c ~458)
delivers the signal -- the "reimplement signal actions" scope below was too pessimistic; no reimpl
needed. Socket-less `cider shell` (login chain + bash fork/exec loop + shell math) soaks 4/4+2/2,
flag-off 2/2, rc=0. REMAINING for full no-daemon: pid-1/shellspawn still checks in + container
lifecycle still on ciderd. The design/analysis that led here (now partly superseded):

## Milestone 4/5 update (session 3, later) -- remaining wall = exec-checkin -> sigprocess-needs-socket; in-guest signal processing (#40) is BOUNDED

The fork-checkin abort above is now FIXED (patches 0063 skip-exec-checkout, 0064 skip-fork-child-connect-checkin); flag-on RECV 132->11 this session, exec loop DONE rc=0, baseline committed on bookmark fully-without-ciderd. The REMAINING blocker to removing the EXEC checkin is different and precisely pinned: a checkin-less (socket-less) process dies on its FIRST default-action signal at `sigprocess failed ... signal 6: -32` (sigexc.c:421), because dserver_rpc_sigprocess (RPC #12) needs the ciderd socket. So the endgame's true prerequisite is IN-GUEST SIGNAL PROCESSING (task #40), and it is MORE BOUNDED than "port XNU Thread::processSignal":
- ciderd sigprocess (handler.rs:558) = load the guest reg state -> `xnu_sys_thread_process_signal` (thread.rs:72, the full BSD signal-frame machinery) -> wait_while_user_suspended (ptrace) -> save state; reply = the pending bsd signal.
- BUT the guest ALREADY has what the self-contained case needs: `sig_handlers[]` + `cider_signal_is_fatal()` (sigexc.c:136/436), and patch 0061 already dispatches REGISTERED handlers in-guest (handler_linux_to_bsd_wrapper, no sigprocess). So for a non-ptraced self-contained process the ONLY signals still reaching sigexc_handler -> sigprocess are UNHANDLED / default-action ones (SIGABRT with no app handler, SIGSEGV, ...). There is no handler frame to build for those -- the correct XNU effect is simply TERMINATE with the signal's semantics.
- IN-GUEST REPLACEMENT (flag-on, socket-less): in sigexc_handler, when there is no app handler and the signal is fatal (cider_signal_is_fatal), restore SIG_DFL and let Linux apply the fatal default (synchronous signals: rt_sigreturn to re-run the faulting insn under SIG_DFL; async: re-raise) -- correct exit status + core -- instead of RPCing sigprocess. The ptrace/debugger + Mach exception-port paths stay RPC (neither is present in the self-contained target). Gate on CIDER_INGUEST_IPC + socket-absent; keep the RPC path for flag-off and for a socketed process.
- RISK / DISCIPLINE: the signal path silently defeated 4+ prior attempts, and the DYLD copy of the handler must be rebuilt too (//vendor/src/dyld:dyld runs the handler). Landable, but it must be gated + soaked for SIGABRT/SIGSEGV exit-status correctness + fork-heavy, so it is a SUPERVISED milestone, not an autonomous-loop change against the clean baseline.

## Task #24 -- JSC arm64 LLInt offline-asm gap, root-caused (session 3)

The FULL prefix's JavaScriptCore_dylib link fails with undefined offline-asm entry symbols
(_vmEntryToJavaScript, _wasm_entry, _wasmLLIntPCRange*). ROOT: JavaScriptCore/CMakeLists.txt (which the
BUCK is generated from) handles the low_level_interpreter for TARGET_x86_64 (X86_64/debug LLIntOffsets
header) and TARGET_i386 (C_LOOP/debug header) but has NO arm64 case (~lines 2160-2181) -- so on arm64,
llint/LowLevelInterpreter.cpp is built as an EMPTY stub (darling/source/empty.c) and the LLInt/WASM entry
symbols are never defined. The pre-generated DerivedSources LLIntOffsets exist for C_LOOP + X86_64 only;
no ARM64.

FIX PATH (add an arm64 case building llint/LowLevelInterpreter.cpp with an ARM64 or C_LOOP header):
- offlineasm HAS arm64.rb + arm64e.rb backends (offlineasm/backends.rb requires + lists ARM64/ARM64E), so
  a NATIVE arm64 header can be generated: offset extractor (generate_offset_extractor.rb -> compile for
  arm64 -> run -> offsets) then `ruby offlineasm/asm.rb` (ARM64 backend) llint/LowLevelInterpreter.asm
  <offsets> -> DerivedSources/JavaScriptCore/LLIntOffsets/ARM64/{release,debug}/LLIntAssembly.h.
- OR simplest: mirror i386 and use the existing C_LOOP/debug header for arm64 (portable C++ interpreter),
  with ENABLE(C_LOOP) set for the arm64 JSC build -- slower JS but no offline-asm needed; fine for cider
  (correctness, not JS perf). Must also cover WASM (wasm_entry/wasmLLIntPCRange*): C_LOOP-WASM or
  ENABLE(WEBASSEMBLY)=0.
VERIFY (bounded, no full-dylib link needed): compile LowLevelInterpreter.cpp with the chosen header ->
`llvm-nm` the obj -> confirm the entry symbols are DEFINED; then the full JavaScriptCore_dylib links.
NON-GATING: bash + nix + the min prefix do NOT need JSC; #24 only blocks the FULL prefix.
