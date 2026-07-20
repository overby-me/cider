# Blockers

Threads that are stuck pending a human decision, an upstream change, a
licensing question, or >1 day on a single signature. Pick up the next ranked
item and record the blocker here with reproduction steps. (Protocol: PLAN.md §10.)

## Open

- **Guest Nix under Darling: RESOLVED — nix loads, runs and evaluates.**
  After the four fixes below, the x86_64-darwin `nix` 2.34.8 runs under Darling:
  `nix --version` -> `nix (Nix) 2.34.8`, `nix eval --expr "1+2"` -> `3`,
  `builtins.currentSystem` -> `"x86_64-darwin"`. Remaining for the *official*
  `nix build …#hello` (moved to plan/26.05-facts.md M1b): a writable store in
  the prefix + confirm HTTP substitution works. History of the dyld chain:
  Toward the *official* Phase C.3 (drive the hello build through `nix build …#hello`)
  and the Phase D oracle, the nixpkgs x86_64-darwin `nix` (2.34.8) is run under
  Darling (with a `/nix -> /Volumes/SystemRoot/nix` symlink so its absolute
  `/nix/store/…` deps resolve; host `/nix` is only at `/Volumes/SystemRoot`).
  dyld reveals a short chain of gaps, walked to its end this session (each needs
  a full rebuild):
  1. `libc++` exported **0** `std::filesystem` symbols (needs 26). Sources
     shipped but unbuilt -> `patches/libcxx/0001` builds them (now **810**).
  2. Network.framework had **0** of the **39** `nw_*` symbols `libaws-c-io`
     (nix's S3) needs -> `src/frameworks/Network/src/nw_stubs.c` logging stubs
     (now **78**); nix never uses S3 for a local build.
  3. `libc++` had no C++17 `std::pmr` at all (only `std::experimental::pmr`) ->
     `patches/libcxx/0001` also adds a minimal `std::pmr` (memory_resource +
     get_default_resource), exported with `visibility("default")` (libcxx builds
     `-fvisibility=hidden`, so the first cut compiled them hidden and dyld still
     failed).
  4. **The last gap (verified by a full closure scan):** exactly one symbol,
     `vtable for std::pmr::monotonic_buffer_resource`
     (`__ZTVNSt3__13pmr25monotonic_buffer_resourceE`). All **547** other pure-std
     symbols nix's closure imports are now provided by libc++/libc++abi. nix
     constructs a `monotonic_buffer_resource` via the header's inline ctor, so a
     stub won't do: it needs the real class with the **ABI-exact layout + working
     `do_allocate`/`do_deallocate`/`do_is_equal`** so the vtable and member
     offsets match. The matching source isn't in-tree (Darling's libcxx is a
     reduced LLVM-13 without `std::pmr`) and `llvmPackages_13` was removed from
     nixpkgs 26.05, so the next step is to obtain the LLVM-13 (or ABI-equal)
     `monotonic_buffer_resource` source (git `llvmorg-13.0.0` libcxx
     `src/memory_resource.cpp` + `<memory_resource>`) and add it to
     `memory_resource_std.cpp`. Then nix's libc++ needs are met and it should
     load; a framework/other gap could still appear at first run, but the closure
     scan suggests libc++ was the last big one.

  This does **not** block the campaign goal: `hello` already builds and runs
  under Darling via the self-contained bootstrap toolchain (M0 + M1), which needs
  none of this. Trick recorded: the `/nix` symlink lets any nixpkgs Darwin
  binary's absolute store-path deps resolve inside the container. Alternative to
  finishing the port: drop in a modern libc++ (e.g. the bootstrap-tools' LLVM-19
  `libc++.1.dylib`) in place of Darling's reduced one, if the libc++abi
  re-export/ABI can be reconciled -- would provide `monotonic_buffer_resource`
  and everything else in one move.

- **Rootless runs one command per fresh container (no re-join).** A running
  container's init (darlingserver) lives in the user namespace the *first*
  `darling shell` created. A subsequent `darling shell` creates its own
  (sibling) user namespace and then tries `joinNamespace(pidInit, mnt)` =
  `open(/proc/<pidInit>/ns/mnt)`, which fails **EPERM** (no privilege over a
  sibling userns). So each invocation must start a *fresh* container (kill the
  stale darlingserver first). Fine for one-shot runs
  (`scripts/run-darwin-under-darling.sh`, M0), but it breaks the guest-Nix
  installer, which issues many sequential `darling shell` calls expecting a
  persistent container (Phase 0.5 full / Phase C). Fixes to evaluate: (a) run
  the whole install inside one `darling shell` session; (b) teach the launcher
  to *enter* an existing container's userns+mnt+pid via the persistent
  darlingserver instead of creating a new userns when a container is already
  running. Prefer (a) first (simpler, no launcher change).

- **First-boot shellspawn race + un-cleanable rootless prefixes.** A fresh
  prefix's first `darling shell` sometimes returns before `shellspawn.sock`
  appears (`Error connecting to shellspawn … No such file`). The launcher waits
  only `15 * 1s` for the socket (`src/startup/darling.c`), which a slow rootless
  first boot (chown-heavy setup) can exceed, so callers must retry. Separately,
  files the container creates in the prefix are owned by mapped container uids
  the host user cannot `rm` (EPERM), so a stale prefix cannot be cleaned from
  the host and reusing one can wedge later boots. Consequences: the one-shot
  runner/compile scripts (`run-darwin-under-darling.sh`, `cc-under-darling.sh`)
  are timing-sensitive. Fixes to evaluate: widen the shellspawn wait window
  (and/or poll faster); a `darling` subcommand that tears down + removes a
  prefix from inside the container (as container root). The underlying
  compile/run results are solid; only the harness around them is flaky.

- **Rootless prefix path must be short (Unix-socket `sun_path` limit).** The
  shellspawn/darlingserver socket lives at `<prefix>/var/run/…sock`; if the
  prefix path is long the socket path overflows `sockaddr_un.sun_path` (~108
  chars) and boot fails with "darlingserver socket path is too long" (the
  launcher's own 255-char `DPREFIX` check is looser and misses this). Keep
  prefixes short, e.g. the default `~/.darling`. Minor: tighten the launcher's
  check to the socket-path budget, or shorten the socket path. Not a rootless
  issue (affects the setuid path equally).

- **hello `./configure` aborts (SIGABRT) under Darling — the C.3 blocker after
  the mkfifoat fix.** With the `mkfifoat`/`mknodat` gap fixed (commit
  `f9bc5f5b`), the guest `nix build hello --rebuild` clears the dyld wall and
  runs `./configure` from source. It passes ~14 checks (install, sleep, mkdir,
  gawk, make, xargs, ustar, gnutar) then, right after `checking for gcc...
  clang`, several near-simultaneous bash **subshells die with `Abort trap: 6`
  (core dumped)** — e.g. `( for ac_var in \`(set) 2>&1 | sed ...\`; ... )` and
  `( eval "$ac_compiler $ac_option >&5" )` — and the build fails
  (`builder failed due to signal 6`).

  **Ruled out (via `scratchpad/bash-abort-inner{,2,3,4}.sh`, run under Darling
  with the *exact* stdenv bash `avrhwml7…-bash-5.3p9`):**
  - Not the symbol gap — that binds now.
  - Not basic forking: `( … )` subshells, `$(…)` command substitution, fork+exec
    of externals all return 0.
  - Not the line-85 op itself: `(set) 2>&1 | sed -n …` in a subshell → 0, even
    with ~400 exported vars, a 5000-char var, or a malloc-heavy child.
  - Not fd-5/6 logging (`exec 5>log; ( … >&5 )`) → 0.
  - Not clang: `clang --version` and a real conftest compile, each followed by a
    subshell → 0.
  - Not process/port exhaustion: 400 subshells + 400 `$( … | cat )` + 400
    fork+exec loops all complete (the ~133 `ds*`/getpwuid cycles in the trace are
    just per-process `getpwuid`, 132 succeed).
  - No Darling message, no crash report, no backtrace at the abort (silent
    `abort()`); `STUB_VERBOSE` shows only DirectoryService stubs (getpwuid path).

  **So it is specific to the *nix-build process context* under Darling** (how the
  host `nix` — itself running under Darling — spawns the derivation builder with
  `sandbox = false`), not to any operation reproducible in a `darling shell`.
  Next diagnostics (need in-sandbox access): (a) a core-dump backtrace of the
  aborting subshell (enable cores / Darling crash reporting inside the build);
  (b) run hello's real `./configure` directly in a `darling shell` with the
  stdenv tools on PATH — if it aborts there, it is configure-specific, else it is
  the nix-spawn path; (c) bisect configure with `sh -x` to the first aborting
  command + dump its var state. Repro harness + full `STUB_VERBOSE` trace saved
  in `scratchpad/hello-trace.log` / `bash-abort*.sh`.

## Resolved

- **Host privilege for running Darling** → **rootless via unprivileged user
  namespaces**, no setuid, no sudo. `src/startup/darling.c` now enters a
  `CLONE_NEWUSER` namespace mapping the caller to root and re-execs into it
  (`enterUserNamespaceAndReexec`, guarded by `DARLING_USERNS_STAGE2`) when not
  already euid 0; the container's mount/PID unshares and overlayfs mount then
  run as namespaced root. Validated end-to-end on an initialized prefix: a
  mode-555 (non-setuid, root-owned) store `darling` run as uid 1000 boots and
  `darling shell echo ROOTLESS_OK` prints `ROOTLESS_OK` (rc 0); the rebuilt
  macOS-14 build likewise reports its identity via `sw_vers`/`sysctl` rootlessly.
  Requires `kernel.unprivileged_userns_clone=1` and kernel >= 5.11 for
  overlayfs-in-userns (host 7.1.2). `scripts/darling-trampoline.c` remains as a
  setuid fallback for hosts without unprivileged userns. The earlier
  `unshare --map-root-user` failure was the single-uid map; the in-launcher path
  writes uid_map/gid_map itself after denying setgroups, which works. A *fresh*
  prefix also creates and boots rootlessly (validated: `SINGLEID_BOOT_OK` +
  `sw_vers` 14.4.1 on a new short-path prefix). Its `Cannot chown …` messages
  (~4.5k) are for overlayfs lowerdir base files owned by host root (uid 0), which
  is unmapped in the namespace and cannot be chown'd; they are non-fatal (boot
  completes) and identical under a single-id or a subordinate-range map, so no
  range map is needed (a `newuidmap`/`newgidmap` range version was tried and
  reverted: darlingserver chowns to uid 0, which the single-id map already
  covers, and the residual host-0 files no range can touch).

- **Fork submodule URLs unhosted / xnu gitlink orphaned** → `scripts/init-submodules.sh`
  fetches from upstream darlinghq and overrides the xnu gitlink to the reachable
  base; Campaign-1 fixes carried as `patches/xnu/*`.
- **nixpkgs 26.05 pkg-config `Requires.private` gaps** (libsystemd, expat, xau,
  xdmcp) → added the providers to `nix/package.nix` buildInputs.
- **False 18-symbol libSystem gap** → `tbd-diff.py` now reads the exports trie
  (Darling re-exports str/mem funcs; `nm` missed them). Real gap ~0.
