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

**All four self-contained kernel queries are now served FULLY in-guest, zero ciderd RPC (patches
0051 + 0052): host_info(200), host_get_clock_service(206), task special ports(3409, 3418).** exec-true
drops 12 RPCs/spawn (RECV 70 -> 58, those four ids 3 -> 0 each), rc=0, soak 10+/10+, replies
byte-identical to ciderd's. The port-returning queries hand back guest-minted port names (reserved
0xE0000000+ range) that exec-true only stores; a tiny guest port table serves their deallocate/mod_refs
in-guest too.

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
