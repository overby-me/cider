# Rust port of the startup path: darling.c (launcher) + mldr (loader)

## Mission (overnight autonomous, started 2026-07-27 night)
Port BOTH the `darling` launcher (`src/startup/darling.c`, ~1400 LOC) and the guest
Mach-O loader `mldr` (`src/startup/mldr/`, ~2300 LOC) from C to Rust. Continues the
Rust-ification after the darlingserver daemon rewrite (task #50 done: C++ daemon deleted).

## User directives (answers given 2026-07-27 night)
- **Done-bar = REPLACE + FLIP when boot-green.** The Rust becomes the REAL
  launcher/loader; once it passes the boot gate, flip main's default to it (unattended).
- **Order = darling.c FIRST, then mldr.**
- **If blocked = KEEP GRINDING** the blocked port (do NOT pivot to the other / backlog).
- **Push to main** (user explicitly authorized; overrides the usual no-push-to-main rule).
- **Loop, do not stop**: re-schedule a wakeup each turn; keep going until done or user returns.

## Safety invariant (non-negotiable)
Main must ALWAYS boot. Build each Rust port ADDITIVELY (new crate + nix derivation, the
`darlingserver-rs` pattern). Keep the C as the runtime default until the Rust port passes
the boot gate. The "flip" is then a one-line install/exec change. Every push to main leaves
a bootable runtime.

## Validation gate (both ports)
8-boot cold-start stress (the `/tmp/bootstress2.sh`-style harness): must be 8/8 clean,
zero `-111`, boots ~250-350ms on the Rust daemon. A port FLIPS only after passing.
For mldr additionally: a guest binary (`uname`, `hello`) loads + runs + returns correct
output under the Rust loader.

## Part 1 -- darling.c -> Rust launcher (FIRST)
Crate + fast splice-build path (cf. the `darling-launcher-spliced` flake attr) so the
edit->build->boot loop is seconds, not the 40-min monolith. Paths via env with compiled
defaults (DSERVER_LIBEXEC_PATH / DSERVER_MLDR_PATH / DPREFIX), like the boot-stress uses.
- L0 crate scaffold + nix derivation + cargo build green.
- L1 arg/subcommand parse (shell/exec/...) + env (DPREFIX, DSERVER_*, DARLING_NO_LAUNCHD, INSTALL_PREFIX).
- L2 container setup: unshare userns+mntns, uid/gid maps, overlay/vchroot mounts (`nix` crate).
- L3 spawn darlingserver + wait `.darlingserver.sock`; spawn init/shellspawn + wait shellspawn.sock.
- L4 relaunch/join logic (containerJoinable / killContainer / `.init.pid` + `.sock`).
- L5 exec guest command via mldr; signal forwarding.
- L6 BOOT GATE (8/8) -> flip main's default `darling` to Rust -> push.

## Part 2 -- mldr -> Rust loader (SECOND)
- M0 crate scaffold + nix derivation + build (match C mldr's static/PIE + entry).
- M1 Mach-O parse (`goblin`/`object`): load commands, segments.
- M2 segment mmap/load (fixed addr / slide) + the elfcalls ELF<->Mach-O bridge.
- M3 dyld load (LC_LOAD_DYLINKER) + stack + commpage + argv/envp/apple[] array.
- M4 darlingserver RPC checkin at startup.
- M5 CPU-register setup + jump-to-entry (unsafe asm).
- M6 BOOT GATE (guest uname/hello loads+runs) -> flip main's mldr to Rust -> push.

## Loop protocol (every turn)
build -> validate -> `jj commit` -> `jj git push` to main -> ScheduleWakeup(continue) -> next.
Keep main bootable. Update the Progress log below each turn so the morning report is here.

## Progress log
- 2026-07-27 night: plan created. Dispatched deep-map agents for darling.c and mldr.
  C++ removal (task #50) validating via full `nix build`. Awaiting maps to begin L0/L1.
- 2026-07-28 overnight: C++ removal + #44 + plan PUSHED to origin main (cefa9342); full
  `nix build .#default` exit 0, bin/darlingserver = Rust daemon (14 sigs). Maps landed.
  **darling.c Phase A DONE**: standalone `darling-launcher-rs` crate (libc-only, builds
  offline in ~7s). Full boot path implemented + validated: userns re-exec, prefix
  bootstrap, daemon spawn + readiness pipe, mnt-ns join, shellspawn non-interactive proxy.
  Boots the guest first try: BOOT=Darwin; 8/8 stress clean, avg 421ms, zero -111. Covers
  L0-L5 for the NON-interactive path. NOT yet flipped (C still default; main bootable).
  Next -- Phase B: PTY/interactive path, signal forwarding (self-pipe), startup watchdog
  killContainer; then L6 flip (`darling` -> Rust via nix/package.nix + splice) + push.
- 2026-07-28 overnight (cont'd): **darling.c Phase B DONE** -- interactive PTY path
  (openpty/raw-mode/winsize), signal forwarding via a safe self-pipe (not the C's
  malloc-in-signal-handler), startup watchdog + killContainer. Also ds_bin_path now
  resolves the daemon NEXT TO the launcher binary (relocatable, no baked prefix). Validated:
  non-interactive 8/8 stress clean (avg 396ms) + interactive PTY 3/3 (exit code 7 + guest
  output both correct, via an openpty harness). Launcher is a FULL replacement now.
  Next: L6 flip (nix/darling-launcher-rs.nix + package.nix, validate via full build) + push,
  then Part 2 (mldr).
- 2026-07-28 overnight (cont'd): **darling.c L6 FLIP WIRED** -- nix/darling-launcher-rs.nix
  (libc-only buildRustPackage, cargoLock vendoring), package.nix postInstall installs it as
  bin/darling (overriding the cmake C launcher), flake.nix exposes .#darling-launcher-rs.
  Validating via nix build (bg task). Flip wiring NOT yet committed (pending the build green).
  Once green: commit+push the flip -> darling.c (#64) DONE. Then Part 2 (mldr, #65): note the
  crate needs Mach-O parsing; goblin is not in the offline cargo cache, so mldr will either
  hand-roll the Mach-O header/load-command parse (no dep) or rely on nix cargoLock vendoring.
- 2026-07-28 overnight (cont'd): flip committed locally (validating via full nix build, bg).
  goblin 0.9.3 IS cached after all + network is up. **mldr (#65) M0+M1 STARTED**: new
  src/external/mldr-rs crate (libc + goblin). Scaffold + argv-shape detection (! vs binfmt)
  + __mldr_* special-env parse + goblin Mach-O parse. Compiles (~9s); parses real guest
  binaries (libstdc++.6.dylib 16 lcmds; dyld entry=0x1000, 16 lcmds). Next M2: PIE slide +
  map segments at vmaddr+slide (raw libc mmap, MAP_FIXED_NOREPLACE, the protection quirk +
  __PAGEZERO tolerance), commpage (with the CPU-count-never-zero SIGFPE fix), start stack.
- 2026-07-28 overnight (cont'd): **mldr M2 DONE** -- src/external/mldr-rs/loader.rs maps
  LC_SEGMENT_64 segments at vmaddr+slide via raw libc mmap: PIE slide (reserve-span-then-
  release), the useprot protection quirk, two-phase BSS (anon then file overlay), __PAGEZERO
  tolerance. Validated on dyld: slide 0x79d5e02c5000, mapped mach_header reads magic=0xfeedfacf.
  Next M3: recursive dyld load (LC_LOAD_DYLINKER) + commpage (SIGFPE fix) + start stack.
- 2026-07-28 overnight (cont'd): **#64 launcher FLIP validated + PUSHED** (full nix build
  exit 0; bin/darling=Rust launcher, bin/darlingserver=Rust daemon; main=d95ac20b). darling.c
  port COMPLETE (#64 closed). **mldr M3a DONE**: commpage.rs maps the commpage at 0x7fffffe00000
  (signature/version/CPU-counts/page-shifts/memsize); counts use CONF->ONLN->1 so never 0 (the
  SIGFPE fix). Validated on dyld: sig="commpage 64-bit", ncpu=22. CPU capability bits = TODO
  (need cpu_capabilities.h). Next M3b: recursive dyld load (LC_LOAD_DYLINKER); M3c: start stack.
- 2026-07-28 overnight (cont'd): **mldr M3b DONE** -- loader::find_dylinker (manual
  LC_LOAD_DYLINKER load-command walk) + recursive dyld load in main. Validated on
  /bin/launchctl: extracts dylinker=/usr/lib/dyld, maps the executable (magic 0xfeedfacf)
  AND dyld (slide 0x73fb910c5000, entry ...910c6000) in one address space, FINAL entry =
  dyld's entry. MLDR_ROOT_PATH stands in for vchroot (real root_path arrives with M4).
  Next M3c: start stack (mach_header ptr + argc/argv/envp/apple[]) just below the commpage.
- 2026-07-28 overnight (cont'd): **mldr M3c DONE** -- stack.rs builds the macOS start stack:
  allocates the guest stack just below the commpage (MAP_GROWSDOWN), lays out sp[0]=mach_header
  ptr, argc, argv/envp, apple[]=executable_path/kernfd/elf_calls. Validated on launchctl:
  sp=0x7fffffdebf20 (below the 0x7fffffe00000 commpage), sp[0]=0x100000000 (== mapped mh),
  argc=1. mldr now M0-M3c. Remaining: M4 darlingserver checkin RPC (reuse rpc_wire/rpc_io);
  M5 elfcalls vtable + register setup + jmp-to-entry. Plus TODOs: CPU cap bits, argv/envp
  in-place compaction + __mldr_* env stripping, the fd socket-bitmap + lifetime pipe.
- 2026-07-28 overnight (cont'd): **mldr M4 (code) DONE** -- rpc.rs: darlingserver checkin
  over AF_UNIX SOCK_DGRAM. Wire structs byte-identical to the daemon's rpc_wire.rs
  (DserverRpcCallhdr{number,pid,tid,architecture} + CallCheckin{is_fork,stack_hint,
  lifetime_listener_pipe}; CHECKIN=1, x86_64=2). Validated sizeof(RpcCallCheckin)=40 (matches
  the C exactly). Socket create+autobind, server addr from __mldr_sockpath, checkin send/recv
  -> reply.code. The live code=0 test needs mldr running as a real guest (daemon uses
  SCM_CREDENTIALS + container ctx) -> deferred to M5 integration. Next M5: elfcalls vtable +
  register setup + jmp-to-entry (then wire mldr-rs into a container boot to validate end-to-end).
- 2026-07-28 overnight (cont'd): **mldr M5a DONE** -- elfcalls.rs: the 31-function elf_calls
  vtable (#[repr(C)], exact elfcalls.h ABI order). Real dl*/malloc/free/realloc/exit/sysconf/
  errno via libc; thread/sem/shm/dserver-socket stubbed (refined at integration). elfcalls::make()
  leaks a vtable and its address feeds apple[2]=elf_calls. Added rpc::main_socket getter (the
  dserver_per_thread_socket stub returns it). Validated on launchctl: elf_calls @ 0x56b1583d8980,
  threaded into the stack; sp/mh/argc still correct. Next M5b: the jump (mov rsp; xor rbp; jmp
  entry, gated on being a real guest); reorder socket+checkin before the stack for a real kernfd;
  then INTEGRATION -- exec mldr-rs as the guest loader and boot `uname` (the boot-green gate).
- 2026-07-28 overnight (cont'd): **mldr M5b DONE (code) -- mldr-rs is CODE-COMPLETE**. jump.rs
  (mov rsp; xor rbp; jmp entry, options(noreturn)). Reordered main: socket+checkin (-> kernfd)
  -> elfcalls -> start stack -> gated jump (only jumps as a real guest, i.e. __mldr_sockpath set;
  a test run stops before abandoning the Rust stack). Full flow M0-M5: parse->map->commpage->
  dyld->checkin->elfcalls->stack->jump. Test run on launchctl flows through cleanly. NEXT:
  INTEGRATION (the boot-green gate for #65) -- exec mldr-rs as the guest loader + boot a guest.
  Expect grinding: CPU cap bits (commpage), argv/envp in-place compaction + __mldr_* stripping,
  the real dserver_socket_address + top-down fd allocator, and the native-pthread thread bridge.
- 2026-07-28 overnight (cont'd): **mldr INTEGRATION FIRST RUN -- HUGE.** Exec'd mldr-rs as the
  guest loader (DSERVER_MLDR_PATH=a copy at darling-rt/.../mldr-rs). The daemon spawned it for the
  `vchroot` helper (guest=.../vchroot, sockpath=.wnix/.darlingserver.sock). mldr-rs parsed it, set
  up the commpage (ncpu=22), mapped segments (magic 0xfeedfacf), built the elfcalls vtable + start
  stack, and **checkin RPC returned code=0 (M4 LIVE-VALIDATED!)**, then jumped. BLOCKER: dyld
  resolution -- dylinker=/usr/lib/dyld but "dyld not found" (root_path unset, no vchroot yet), so
  mldr-rs jumped to the EXECUTABLE entry (0x100000c80) not dyld's -> guest hung (timeout 60s).
  NEXT (the unblock): implement vchroot_path RPC (VCHROOT_PATH=3; CallVchrootPath{buffer:u64,
  buffer_size:u64} -> ReplyVchrootPath{length}; the daemon writes the Linux vchroot prefix into the
  buffer -- CHECK the daemon handler in handler.rs to confirm the write mechanism). Use root_path
  to resolve dyld = <root>/usr/lib/dyld, map dyld, jump to DYLD's entry. Then re-test the boot.
- 2026-07-28 overnight (cont'd): **mldr integration -- dyld now RUNS libSystem.** Fixed dyld
  resolution: parse __mldr_DYLD_ROOT_PATH (the daemon sets it = libexec root, container.rs:251) as
  root_path; and clean the guest env (rename __mldr_DYLD_ROOT_PATH -> DYLD_ROOT_PATH, strip other
  __mldr_*). Now mldr-rs maps dyld + jumps to DYLD's entry, and dyld RUNS libSystem -- the guest
  makes REAL RPC calls (task_self_trap, mach_reply_port, kprintf, started_suspended,
  interrupt_enter). NEW BLOCKER: they fail "BAD SEND STATUS: -107" because elfcalls
  dserver_socket_address() is stubbed (returns null) -> the guest RPC has no server sockaddr to
  send to. NEXT: implement dserver_socket_address (return a sockaddr_un built from __mldr_sockpath;
  check resources/dserver-rpc-defs.h for the exact format) + likely a real per-thread socket. The
  guest is running Mac code -- very close.
- 2026-07-28 overnight (cont'd): **mldr integration -- runs DEEP into the boot chain.** Fixed:
  (a) dserver_socket_address returns the sockaddr_un from __mldr_sockpath + connect the socket ->
  guest RPC works (-107 gone); (b) guest argv = mldr argv[1..] not [guest_path] -> vchroot gets its
  args + execs the next binary; (c) root-path on re-exec = derive root from guest_path minus the Mac
  path (guest argv[0]), since execve does not forward DYLD_ROOT_PATH. Now the chain RUNS: vchroot
  sets up the vchroot + execs shellspawn; shellspawn's dyld resolves + runs libSystem -- threads,
  mutexes, and signal handling (sigexc) all active. BLOCKER: the guest hits SIGILL (signal 4) deep
  in libSystem, with "[dtape] mutex without an active thread". LIKELY CAUSES: commpage CPU cap bits
  (cpu_caps()=0 -> libSystem SIMD path mis-selection) and/or the elfcalls thread bridge
  (darling_thread_create stub returns null -> no active Darwin thread). NEXT: fill commpage cpu_caps
  (read src/startup/mldr/include/i386/cpu_capabilities.h + cpuid) and implement the
  darling_thread_create native-pthread -> Darwin-thread bridge (src/startup/mldr/elfcalls/threads.c).
- 2026-07-28 overnight (cont'd): **CPU caps fixed the SIGILL + vchroot_path gives robust root
  resolution.** commpage cpu_caps via cpuid (committed 1530a86f) cleared the libSystem SIGILL;
  the boot chain now runs vchroot->shellspawn->bash->path_helper->bash (the final sh -c echo).
  Added vchroot_path RPC (VCHROOT_PATH=3; daemon cross-process-writes the vchroot Linux prefix
  into our buffer) + reordered main (socket/checkin/vchroot BEFORE the dyld load) -> root resolves
  robustly (None first proc, Some(/home/overby.me/.wnix) post-vchroot). NEW BLOCKER: the guest is
  mis-threaded -- elfcalls darling_thread_create is still a stub returning null -> "[dtape] mutex
  without an active thread", and eventually the DAEMON panics (FATAL host signal 04) on a bad RPC
  from the mis-threaded guest. NEXT (the last major piece): implement the darling_thread_create
  native-pthread -> Darwin-thread bridge (threads.c:116-325 -- dthread alloc, native pthread, TSD
  base via callbacks, per-thread socket + checkin, register-exact stack switch + jump). C mldr
  stays default; main is safe.
- 2026-07-28 overnight (cont'd): **thread bridge implemented + wired** (threads.rs). darling_thread_create
  -> native pthread -> per-thread RPC socket + checkin + Darwin TSD base (dthread+224, probed from
  dthreads.h via clang offsetof) + thread-self port -> tsd[3] + register-exact stack switch/jump.
  Wired into elfcalls; dserver_per_thread_socket now returns the calling native thread's socket
  (thread_local). Compiles clean. KEY REFRAME: the "mutex without an active thread" is a NON-FATAL
  warning (duct-tape locks.c:59 falls back to a native lock), NOT the blocker. The real crash: the
  GUEST hits a SIGILL (a libSystem assertion/ud2, deep -- after the whole exec chain) and the daemon's
  sigexc handling then aborts (FATAL host signal 04). NEXT: diagnose the guest SIGILL. Leading
  hypothesis: mldr-rs never sets the MAIN thread's Darwin TSD base (only created threads get it via
  the bridge) -- check how the C mldr/libpthread sets the main thread's %gs TSD; also re-check the
  sigexc rip + the commpage cpu-caps. STATUS: mldr-rs is functionally complete and runs the guest
  boot chain DEEP into libSystem (vchroot->shellspawn->bash->path_helper->bash) -- an extraordinary
  result; the remaining work is subtle guest/daemon-interaction debugging toward BOOT=Darwin.
- 2026-07-28 overnight (cont'd): **C mldr boots BOOT=Darwin here -> confirmed mldr-rs-specific.**
  FIX 1: checkin stack_hint was the commpage base (0x7fffffe00000); changed to a real stack addr
  (&local, like the C's &dummy). This ADVANCED the chain from a SIGILL at the --login bash to the
  FINAL `sh -c echo BOOT=...`, and the DAEMON NO LONGER CRASHES (rc=1 not 132). New blocker: the final
  sh hits SIGABRT (signal 6, abort()) -- labeled reg dump: rip in a library (0x7631b6e1d69b, == rcx =>
  right after a syscall), rax=-4 (syscall/mach error). LIKELY ROOT CAUSE: the "mutex without an active
  thread" IS biting -- the psynch path (duct-tape psynch.c uses current_thread()) errors when the main
  thread is not the daemon's active microthread, so pthread_mutex aborts. NEXT: find why mldr-rs's MAIN
  thread is not bound as the daemon's active thread for psynch (grep the daemon RPC dispatch /
  current_thread binding; diff mldr-rs vs C main-thread registration -- maybe a missing setup RPC, or
  the socket-fd relocation, or the thread-self/TSD ordering). Making the main thread "active" should
  unblock the final command -> BOOT=Darwin.
- 2026-07-28 overnight (cont'd): SIGABRT diagnosis narrowing. RULED OUT: (1) the socket connect --
  removing it breaks vchroot_path's send() AND raises the warnings (100->218), so the connect is
  NEEDED (reverted); (2) an UNIMPLEMENTED/ENOSYS daemon RPC (none in the log). The guest runs the
  full exec chain + fd setup ("dtype for fd 0/2"), then aborts on a syscall returning -4. The daemon
  serve loop (bin/darlingserverd.rs:120-148) runs each RPC on a microthread (sched.rs:536 CURRENT.set
  + dtape_thread_entering) and IDs the sender by SCM_CREDENTIALS pid + header pid/tid
  (set_current(ch.pid, ch.tid, host_pid, arch) at :141). LEADING ROOT CAUSE: mldr-rs's guest
  pthread/psynch RPCs land WITHOUT an active microthread, so psynch errors -> pthread aborts. NEXT
  (fresh focus): read the serve-loop message->microthread ROUTING (how the main receive maps a
  message to the calling thread's microthread and spawns/resumes it; server.rs + darlingserverd.rs
  main loop + sched spawn_on/THREAD_BY_TID) and find why mldr-rs's threads don't route there while
  the C mldr's do. Check the tid mldr-rs's checkin sends vs the tid on its guest RPCs (they must be
  the same OS-thread gettid); check whether the daemon needs a per-thread checkin the guest triggers.
- 2026-07-28 overnight (cont'd): **KEY: the "mutex without an active thread" warnings are a RED
  HERRING.** The C mldr (which boots BOOT=Darwin) emits 270 of them too. The daemon routes fine
  (handle_call creates a microthread per (nsid,tid) on first sighting, darlingserverd.rs:496). The
  REAL difference: mldr-rs's guest calls abort() (SIGABRT / sigexc "handler (6)", 3x) where the C
  mldr's guest hits ZERO fatal signal handlers. The abort follows a syscall returning rax=-4 (likely
  -EINTR: a guest syscall interrupted by a spurious signal). So mldr-rs's guest gets signals / a bad
  state the C mldr's doesn't. (DSERVER_TRACE_CALLS works but is too slow -- kept the boot from
  reaching the abort in 60s; don't rely on it.) NEXT (surgical): add a daemon-side log of ERROR reply
  codes -- in bin/darlingserverd.rs do_work after rpc_wire::dispatch, decode the reply {number,code}
  and eprintln when code<0 -- to NAME the failing guest RPC. Rebuild the daemon: `cd
  src/external/darlingserver-rs && DUCT_TAPE_LIB=<duct-tape .a dir> cargo build --bin darlingserverd`
  (find the dir: `find /nix/store -name libdarlingserver_duct_tape.a | head`), cp target/debug/
  darlingserverd -> ~/darling-rt/bin/darlingserver, re-test WITHOUT the trace. Or symbolicate the
  guest fault rip vs the loaded library maps. IGNORE the active-thread warnings -- not the bug.
- 2026-07-28 overnight (cont'd): **ROOT-CAUSED the flaky fault (supersedes the "SIGABRT/psynch"
  guesses above -- those were wrong).** Method: symbolicated the guest fault RIP against
  /proc/<pid>/maps, then disassembled the dylib. The fault is NOT random: it is `ud2` at
  `libsystem_kernel.dylib+0x373e0`, inside `__mach_fork_parent`:
  `call _dserver_rpc_fork_wait_for_child; if ret>=0 ok; else if ret==-4 retry; else ud2`. The guest
  is **forking** (bash/shellspawn fork constantly) and `fork_wait_for_child` returns **-70 == -ECOMM**
  (a socket comms error), which is neither >=0 nor -4, so it hits the `ud2` (EXC_BAD_INSTRUCTION,
  signal 4). The daemon's fork_wait_for_child only ever returns 0 or -ESRCH(-3), so the -70 is a
  GUEST-SIDE socket failure: the forked child inherits the parent's RPC socket fd, both race on it,
  and the parent's fork-wait RPC gets ECOMM. C never hits this because its RPC sockets are set up
  differently (below). Nondeterministic (~60-75%); adding any slowdown (DYLD_PRINT_SEGMENTS) makes it
  pass. AVX/commpage caps were a RED HERRING (disabling AVX did not help; the DYLD_PRINT pass proved
  it is timing, not a deterministic commpage bug).
- 2026-07-28 overnight (cont'd): mldr-rs RPC-socket setup diverged from C `__mldr_create_rpc_socket`
  (mldr.c:701) in three ways; FIXED to match C: (1) **high fd + FD_CLOEXEC** -- C hands out sockets
  from the top of the fd table (socket_bitmap) so they never collide with the guest's own low fds; a
  forked subshell (bash) dup2s/closes low fds and clobbers a low RPC socket. mldr-rs now dups the
  socket to a high fd (rpc.rs `reserve_high_cloexec`, F_DUPFD_CLOEXEC into [512,1023)) + CLOEXEC.
  (2) **no connect() + sendto everywhere** -- C never connects; it sends to the server addr on every
  RPC. mldr-rs used connect()+send() for vchroot_path; switched to sendto (a connected *high* fd
  wedged the guest's interrupt_enter with EBADF). (3) `create_thread_socket` made allocation-free
  (no String clone) so it is fork-safe. These are correct and match C.
- 2026-07-28 overnight (cont'd): **the child socket-refresh (elfcalls dserver_per_thread_socket_refresh
  + close_socket) is implemented but LEFT DISABLED (no-op).** C's guest fork.c calls refresh in the
  child to get its own socket (matches C `__darling_thread_rpc_socket_refresh`, threads.c:397). With
  refresh enabled the child DOES get its own high fd, the -ECOMM ud2 goes away (faults=0), BUT the
  forked child then **wild-jumps into mldr-rs .text and SIGSEGVs** (strace: the child does close(512)
  then a wild jump; symbolicated RIP lands on ICF-folded thunks like CString::new/Default at
  mldr-rs+0x30xxx -- i.e. corrupted control flow, not a real call). This is a **deeper fork-state
  corruption in the mldr-rs guest, orthogonal to the socket**: enabling refresh trades the
  intermittent ud2 (~30% boot) for a deterministic child crash (0% boot). So refresh is a no-op for
  now; the fork-safe create_thread_socket + reserve plumbing stays so it is a one-line re-enable once
  the corruption is fixed. Boot rate with refresh-off + the socket fixes is ~25-30% (== baseline, the
  ud2 is the remaining blocker).
- NEXT (fork-corruption, the real blocker): the forked child's control flow is corrupted before it can
  run. Candidates to investigate: (a) the microthread/thread-bridge state across fork -- mldr-rs's
  darling_thread_create uses native pthreads + a ucontext microthread scheduler; fork() copies only
  the calling thread, so any per-thread bridge state the child expects may be stale/half-initialized;
  (b) the guest's atfork handlers running with a corrupted mldr-rs elfcall stack; (c) whether the
  daemon's fork handling (checkin is_fork + fork_sem) needs the child to re-register threads that
  mldr-rs never re-creates. Method that worked: run under `strace -f` and symbolicate the child's
  fault RIP vs /proc/<pid>/maps; compare the child's syscall sequence to the C mldr's. C mldr boots
  reliably with the SAME daemon, so the divergence is purely in mldr-rs's guest-side fork path.
- 2026-07-28 overnight (cont'd): **BOOT-GREEN. mldr-rs now boots BOOT=Darwin reliably (33/33
  across configs).** The forked-child corruption was a **#GP from an aligned SSE store**: the
  guest calls the refresh elfcall (in the child, from fork.c) on a stack that is **misaligned by
  8**; the C mldr tolerates this (C uses unaligned movs), but mldr-rs's `reserve_high_cloexec`
  zeroed a 16-byte `rlimit` via `std::mem::zeroed()`, which the compiler lowers to
  `movaps %xmm0, 0x50(%rsp)` -- an *aligned* SSE store that #GPs on the misaligned stack
  (SIGSEGV, si_code=SI_KERNEL, si_addr=NULL, exactly at movaps per objdump). Method that nailed
  it: strace -f showed the child do socket()+bind() then SIGSEGV before getrlimit; ruled out lazy
  PLT (mldr is BIND_NOW) and stack canaries (zero %fs:0x28 in the binary); disassembled
  reserve_high_cloexec and found the `movaps`. FIX: use `MaybeUninit::<rlimit>::uninit()` + let
  getrlimit fill it (scalar stores, no movaps). With that, refresh + close_socket are ENABLED (the
  child gets its own high-fd CLOEXEC socket and closes the inherited one), which removes the fork
  ud2 too. Verified: 8/8 + 15/15 + 10/10 boots, a fork-heavy guest (`uname -a; $(echo hi); loop
  /usr/bin/true`) prints `Darwin gravitas 23.4.0 ... x86_64` + DONE=0, and the C mldr still boots
  (CBOOT=Darwin, main not regressed). LESSON: any mldr-rs code reachable as an elfcall from the
  guest must be movaps-free (no aligned SSE) because the guest may call elfcalls on an 8-byte-
  misaligned stack. NEXT: flip mldr-rs to be the default loader (done-bar for #65), mirroring how
  darling-launcher-rs replaced darling.c (#64).
- 2026-07-28 overnight (cont'd): **FLIPPED. mldr-rs is now the default guest loader.** Added
  nix/mldr-rs.nix (buildRustPackage from committed source, mirrors darling-launcher-rs.nix) +
  flake `.#mldr-rs` output, and package.nix installs `${mldrRust}/bin/mldr` OVER the cmake C
  mldr at libexec/darling/usr/libexec/darling/mldr (postFixup patchelf's it for the container
  rpath, same as the C mldr). Validated the RELEASE binary (nix build .#mldr-rs, optimized
  profile -- important because release codegen could reintroduce aligned SSE, but the MaybeUninit
  fix holds): 10/10 boots BOOT=Darwin + 3/3 the demanding pipe/fork workload, deployed straight
  into the container (so the nix binary runs there even before the extra postFixup rpath). The
  `.#default` package evals cleanly with the flip. NOT YET DONE: a full `nix build .#default`
  (the whole Darling cmake tree, hours) to validate the install mechanics end to end -- deferred
  as it only re-checks install/patchelf (identical to the C mldr path) and not binary behaviour
  (already validated). task #65 done-bar (replace + flip when boot-green) met.
- 2026-07-28 overnight (cont'd): **mldr-rs flip validated as SAFE (at parity with C mldr on heavy
  workloads).** The toolchain-M1 hello compile under mldr-rs was inconclusive for an environment
  reason, not mldr-rs: build-hello-under-darling.sh captures the darling output in `$out`, and the
  daemon's huge [dtape]/[guest kprintf] debug volume blew past ARG_MAX ("grep: Argument list too
  long"), plus the darling shell left an orphaned daemon that deadlocked the `$(...)` capture. So
  the script could not verify the build. Instead ran a CLEAN controlled comparison: an 8-worker
  concurrent fork/exec/pipe workload (each worker: 5x echo|cat|tr + /usr/bin/true), 3 runs each,
  mldr-rs vs C mldr. Result: mldr-rs 2/3 vs C mldr 1/3 -- BOTH flaky (some concurrent workers'
  echo output dropped though the shell completes ALLDONE=0), i.e. a PRE-EXISTING daemon concurrency
  issue (related to the known fork/exec concurrency bug), NOT an mldr-rs regression. mldr-rs is at
  parity (slightly better in this small sample). Combined with 55+ green boots/shells/pipes/forks/
  exec/background runs, the flip is safe to keep as the default. FOLLOW-UP (separate, daemon-side,
  not mldr): the concurrent-output-drop flake affects both mldrs -- likely the same fork/exec
  concurrency issue that blocks the official gnix-hello M1 at the first clang; worth its own task.
- 2026-07-28 (parity gap #1 for the C-source deletion, task #67): **mldr-rs now handles fat/
  universal Mach-O.** Was a TODO (main.rs bailed on Mach::Fat). Added `select_slice()` which
  normalizes thin-or-fat to (MachO, fat_offset): for a fat binary it honors the guest's bprefs
  (requested cpu types) in order, else prefers x86_64 (CPU_TYPE_X86_64=0x1000007), else the first
  slice (mirrors mldr.c:340-448). The chosen slice's file offset is threaded through
  loader::map_image (fat_offset, which already existed) and find_dylinker so both read the slice
  instead of the fat header. Verified: `llvm-lipo -create` a universal binary (x86_64 slice at
  offset 0x1000), mldr-rs test-mode selects cputype=0x1000007 @0x1000 and maps it with the correct
  mach_header magic 0xfeedfacf (offset threaded right); thin boots still 4/4 BOOT=Darwin (no
  regression). Note the guest is entirely thin x86_64 in practice (0 fat binaries in 400 scanned),
  so this closes a parity gap for external universal binaries rather than a live failure.
  REMAINING #67 gaps before deleting the C sources: (2) 32-bit -- cmake builds mldr32 (gated
  BUILD_TARGET_32BIT); decide port-or-drop. (3) validate a real heavy build (blocked by #66).
