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
