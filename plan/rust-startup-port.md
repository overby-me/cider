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
