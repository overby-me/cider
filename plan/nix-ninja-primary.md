# Make nix-ninja the primary incremental darling build

Goal: a small source change (e.g. `src/startup/darling.c`) rebuilds in **seconds**
with cached component/edge outputs, instead of the ~40-min monolithic
`nix/package.nix` (one derivation, ~26,000 ninja edges) that rebuilds everything
on any source change. This is the fix for the iteration pain that dominated the
watchdog work (every 3-line launcher change = a full rebuild).

## Milestone (2026-07-23): full libSystem umbrella builds per-edge

`libSystem.B.dylib` -- the whole umbrella (mig codegen, libc, the two-pass
circular link, all 31 sublibraries) -- now builds end-to-end via nix-ninja, one
derivation per edge, as a valid `Mach-O 64-bit x86_64` dylib. Target
`src/external/libsystem/libSystem.B.dylib` via `darlingNinja.buildTarget`. Two
fixes cleared the last blockers past the `ninja-scan` third-party-header work:

- **Undeclared mig-header includes** (`nix/lib/nix-ninja/build/lower.nix`, darling-nix
  `5da8054e`): a compile can `#include <foo.h>` a mig-generated header from a sibling
  dir of its own source module without the graph declaring it and without a literal
  `-I` to the mig output (cmake wires it via object-library includes). Neither
  `generatedHeaderIncs` (excludes mig headers to avoid an eval cycle) nor per-edge
  `genIncs` (declared producers only) resolved it -- e.g. syslog `asl.c` ->
  `<asl_ipc.h>` in `aslcommon`. Fix: a precomputed `migHeadersByModule` map gives each
  compile the mig-header dirs from mig producers in its own source module, scoped
  per-module and cycle-safe. Cleared asl.c; advanced 1954 -> 5036 edges.

- **`$in_newline`** (rust-ninja, overby `205668b8`; lock bumped here in `4d5bb8d0`):
  cmake puts a link's objects only in a response file (`rspfile_content = $in_newline
  ...`) once the object list is large; rust-ninja expanded `$in`/`$out` but not
  `$in_newline`, so the one ~900-object link in Darling (libsystem_kernel firstpass +
  finalpass -- the only two `$in_newline` rsp edges graph-wide) got an empty rsp and
  failed "ld: no object files specified". Fixed in all three duplicate
  `expand_in_edge` copies -- the graph-json tool's copy is the one that feeds
  lowering. Verified: 877 objects now emitted, `libSystem.B.dylib` links, and
  `darlingserver-ninja` stays green.

### Full-graph frontier (`buildTarget {}` = the phony `all`)

Building the whole graph revealed two more nix-ninja items:

- **Phony aggregate targets (FIXED).** `target = null` resolves to the manifest
  `default`, which for Darling is the phony `all`. `buildOne` treated it as a real
  output and ran `cp <edge>/all` (nonexistent) -- so it silently resolved `all` to
  a single head producer (bsdln) and never built the closure. Fixed: `lower.nix`
  gains `isPhonyTarget` + `realOutputsForTarget` (a phony expands to every declared
  output of every real edge it transitively names), and `buildOne` stages those
  into one tree. Single real targets keep the identical prior path.

- **`migHeaderIncsFor` is scope-sensitive (OPEN, the current blocker).** With the
  phony fix, `all` now attempts the true closure and stops at exactly one hard
  failure: the `asl.c` header scan cannot find generated `<asl_ipc.h>`. Root cause
  pinned: the passing libSystem-*subgraph* scan drv carries
  `-I<asl_ipc-producer>/src/external/syslog/aslcommon` (where the generated header
  is), but the full-graph scan drv does **not** -- that `-I` comes only from
  `migHeaderIncsFor`, which returns it for the subgraph configure and `[]` for the
  full one. The producer *is* mounted and *does* contain `asl_ipc.h`; only the `-I`
  is missing. Next: determine whether `migToolDepAttr` wrongly excludes asl.c's
  edge in the full graph, or `migHeadersByModule.<mod>` is empty for it (module-key
  or `dependsOnCompileMemo` differs at full-graph scope). Then re-run the phony
  staging, which has not yet executed end-to-end (gated by this blocker).

- **Tolerated i386 mig noise.** `all` pulls in 32-bit mig codegen edges
  (`*-i386-User.c`) whose `build-mig` uses `/bin/rmdir` (91x) and hit a `cp`
  dir-vs-nondir collision (34x); none is fatal (the mig script forces exit 0), and
  0 appear as `Cannot build`. Left as-is unless they become load-bearing.

## Fast darlingserver iteration WITHOUT nix-ninja (shipped)

nix-ninja's per-edge build of `darlingserver` is blocked (its mig/migcom header-scan
derivations fail — see the darlingserver-ninja note in flake.nix). A coarser split
sidesteps that: **`packages.darlingserver` (nix/darlingserver.nix)** reuses
package.nix's exact configure but runs `ninja darlingserver` only (regular ninja
builds mig fine). It builds just the Linux daemon + its duct-tape/RPC deps —
**~5-6 min idle (9m19s measured under load ~20) vs ~40 min for the monolith**, a
4-8× cut for the component where all the perf work lives. The daemon is
byte-size-identical to the full build's. Splice it into a full runtime for testing
with `scripts/splice-darlingserver.sh` (+ the `darling-launcher-spliced` package,
which bakes INSTALL_PREFIX to the spliced dir from `$DARLING_SPLICE_PREFIX`).
**The splice loop is proven end-to-end** (P2 was built this way in ~9 min, spliced,
booted, and passed a 150-spawn stress run). The key gotcha: the daemon compiles
`LIBEXEC_PATH` (overlay lowerdir + mldr path) from `CMAKE_INSTALL_PREFIX`, so
`nix/darlingserver.nix` must bake it to the splice dir too (via
`DARLING_SPLICE_PREFIX`), else the daemon's overlay lowerdir points at its own
bin-only output and the container fails to mount. Also: boot against a *warm*
prefix (a fresh one hits the separate first-boot launchd stall). This is the
practical fast loop for P2/P6/P8; nix-ninja per-edge (seconds, not minutes) would
still be better but needs the monorepo mig-scan fix.

## Why not "genuine nixpkgs packages"

The submodules are compiled as **Darwin / Mach-O** (`-target x86_64-apple-darwin`,
in-tree `ld64`, linked against Darling's *own* libSystem). nixpkgs' Linux packages
can't replace them (platform + ABI), and nixpkgs' x86_64-darwin variants assume
real macOS and create a **bootstrap cycle** (they'd need the libSystem Darling is
building). So the runtime core can't become upstream nixpkgs packages. The caching
win comes from **per-edge Nix derivations (nix-ninja)**, not upstream nixpkgs. Only
the host build-tools (mig/bootstrap_cmds, cctools, cmake, python) are cleanly
de-vendorable to nixpkgs (task #23) — that trims the tool portion, not the big
Darwin-compile chunk.

## Current infra (reuse)

- `nix/lib/darlingNinja.nix` → `buildTarget { target|targets }`: cmake-configures
  the tree (shared `darlingBuildInputs.nix`, cc-wrapper bypass) and lowers each
  Ninja edge to its own content-addressed Nix derivation via the monorepo's
  `buildNinjaProject` (`overby` flake input, source-only). Proven on
  `src/startup/darling` (launcher) and the `libsystem_kernel.dylib` closure
  (~8,000 edges — builds green).
- Not the default because a full-graph lowering's **evaluation** (thousands of
  derivations) would force/hang `nix flake check`. So the kernel target is built
  manually, kept out of checks.

## Plan

1. **Full-darling nix-ninja package** (`packages.darling-ninja`): call `buildTarget`
   with the install/`all` targets that `package.nix` builds (find them from the
   cmake `install` / the `DESTDIR` layout). Each of the ~26k edges becomes a cached
   derivation. Keep it OUT of `nix flake check` (as the kernel target already is).
2. **Install/fixup wrapper**: `buildTarget` yields the compiled artifacts, not the
   runnable install tree. Add a thin derivation that assembles them into the same
   layout `package.nix` produces (mirror its `install` + `fixupPhase` + SDK
   processing), consuming the nix-ninja outputs. A source change → only changed
   edges recompile (cached) → this wrapper re-runs cheaply.
3. **Iteration vs release**: `darling-ninja` = fast incremental (slow first eval of
   ~26k derivations, then seconds per small change, fully cache-reusable /
   binary-cacheable). `default` (`package.nix`) stays the clean/release build (fast
   eval, one big build). Document when to use which.
4. **(Later) de-vendor host build-tools to nixpkgs** (#23): trims the tool builds.

## Validation

- `nix build .#darling-ninja` once (populate the cache); confirm the result runs
  (`darling shell` boots, `hello`/bash still work).
- Touch `src/startup/darling.c`; rebuild — assert only the launcher edge(s) + the
  install wrapper rebuild (seconds), everything else a cache hit. Compare
  wall-clock vs the monolithic rebuild (the win).
- Ensure `nix flake check` still terminates (darling-ninja excluded).

## Findings (investigation) + refined approach

Concrete facts gathered:
- `buildNinjaProject` (monorepo) copies the requested **target artifact(s)** to
  `$out/<build-path>` (e.g. `$out/src/startup/darling`); default target = the
  manifest's `default` outputs. It does **not** produce an install tree.
- `nix/package.nix` produces the runnable tree via the cmake install hook
  (`ninja install` → `$out/libexec/darling/…`), then `postInstall` (SDK → the
  `$sdk` output + cctools `ld64`/`ar`/`ranlib`) and `postFixup` (fail on any
  `/nix/store` ref under the darling root except `mldr`; `patchelf --add-rpath`
  on `mldr`).
- The launcher bakes `INSTALL_PREFIX` = `CMAKE_INSTALL_PREFIX`
  (`src/startup/CMakeLists.txt:15`) and `execl(INSTALL_PREFIX "/bin/darlingserver")`
  (`darling.c:962`). So a spliced launcher must be compiled with
  `INSTALL_PREFIX` pointing at wherever the rest of the runtime lives.

**The crux = reproducing the install layout from per-edge outputs.** The
build→install path mapping lives in cmake's generated `cmake_install.cmake`;
nix-ninja gives raw build artifacts. Two ways:
- **(A) reconstruct-and-install wrapper** — a derivation that stages the
  configured cmake build dir + all nix-ninja edge outputs into one tree and runs
  `cmake --install` (+ `postInstall`/`postFixup`). Clean; needs the full edge set
  as inputs. The `install` ninja edge itself isn't a file-producing edge, so it
  doesn't fit `buildNinjaProject`'s copy-target model directly — either enhance
  `buildNinjaProject` (monorepo) with an install mode, or drive the install in
  this wrapper.
- **(B) launcher-fast-path (80/20)** — build only `src/startup/darling` via the
  existing `darling-launcher-ninja` with `-DCMAKE_INSTALL_PREFIX=<runtime>`
  pointing at a monolithic `result`, and swap the launcher in. Fast wins for the
  common launcher-iteration case (which was most of this session's rebuild pain);
  not the full solution.

## Concrete next steps (ordered)

1. **Measure eval feasibility**: time `buildTarget {}` (default = full graph) with
   `nix build --dry-run`. ~26k derivations vs the kernel target's ~8k that already
   hangs `flake check`. If eval is impractical (time/memory), coarsen into
   per-library sub-targets. (Do on a less-contended host — the current concurrent
   build sweep saturates CPU/IO.)
2. If eval is OK: build the **(A) reconstruct-and-install wrapper**; diff its
   `result/libexec/darling` tree against the monolithic build's until identical;
   confirm it boots + `hello`/bash run.
3. Ship **(B)** first as an immediate iteration win if (A) proves large.
4. Wire the winner as `packages.darling-ninja`, kept OUT of `flake check`.

## Status (investigation this session)

- **Eval feasibility: CONFIRMED.** `buildTarget {}` (full default graph) evaluates
  past the graph-json IFD into per-edge lowering (~100 s before hitting a build
  error) — it is *not* an evaluation/memory wall. The first full build will be
  expensive (per-edge header-scan + compile), but incremental rebuilds are cached.
- **Blocker found: the per-edge header-SCAN derivation lacks the configure
  `buildInputs`.** The full graph (unlike the launcher/kernel targets) has edges
  that `#include` third-party headers — first hit: `src/bsdln/ln.c` →
  `<bsd/string.h>` (libbsd). libbsd *is* in `darlingBuildInputs.buildInputs`, and I
  added `di.buildInputs` to the nix-ninja **build-edge** `toolchain`
  (`nix/lib/darlingNinja.nix`), but the failure is in a separate `ninja-scan-*`
  (header-discovery) derivation whose inputs are set by the **monorepo** lowering
  (`overby:nix/lib/ninja/build/`), not reachable from this repo. **Fix needs a
  monorepo change:** the scan phase must run with the configure `buildInputs` /
  their `-I` paths so it can resolve third-party headers. Then likely a few more
  such edges (iterate-fix, as the launcher/kernel each needed).
- So completing approach A spans **two repos** (monorepo scan fix + this repo's
  install wrapper) + an expensive first build. Recommended sequencing given that:
  1. **Interim (this repo only): the launcher-fast-path** — `darling-launcher-ninja`
     with `-DCMAKE_INSTALL_PREFIX=<a monolithic result store path>` so the fast-built
     launcher execs that runtime's `darlingserver`; swap it in for seconds-fast
     launcher iteration (covers most of this session's rebuild pain).
  2. **Then approach A** once the monorepo scan-toolchain fix lands and a
     less-contended host is available for the first full build.

**Approach B FULLY VALIDATED (build + wiring + runtime).** `buildTarget` gained an
optional `installPrefix` param that appends `-DCMAKE_INSTALL_PREFIX`. Building the
launcher with `installPrefix = $(readlink -f result)` produced a 63.5 KB launcher
with `INSTALL_PREFIX/bin/darlingserver` correctly baked to the monolithic runtime
(verified via `strings`). **Runtime confirmed** once the host went idle: the
fast-built launcher, pointed at a warm prefix, booted the monolithic runtime and
ran commands end-to-end — `uname` returned `Darwin 23.4.0` and `/bin/echo
NINJA_OK_boot_marker` came back rc=0. (Two gotchas learned: the AF_UNIX socket
path caps at ~108 chars, so the prefix must be short — e.g. `~/.dfx`, not a deep
scratchpad path; and a *fresh* prefix hits the separate first-boot launchd stall,
so validate against a warm/populated prefix.) Fast-iteration workflow (seconds,
not 40 min): `FAST_PREFIX=$(readlink -f result) nix build --impure --out-link
result-launcher-fast --expr '(import ./nix/lib/darlingNinja.nix { pkgs=…;
overby=…; src=…; }).buildTarget { target = "src/startup/darling"; installPrefix =
builtins.getEnv "FAST_PREFIX"; }'` then `DPREFIX=~/.dbash
result-launcher-fast/src/startup/darling shell <cmd>`.

## Risks

- Eval cost of ~26k derivations (memory/time) — measure; may need to coarsen
  (per-library sub-targets) if eval is impractical.
- The install/fixup wrapper must exactly match `package.nix`'s output layout or
  Darling won't boot — diff the two `result` trees.
- nix-ninja lowering edge-cases on the full graph (the launcher/kernel needed
  several fixes in `lower.nix`); expect a few more on the whole tree.
