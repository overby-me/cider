# Make nix-ninja the primary incremental darling build

Goal: a small source change (e.g. `src/startup/darling.c`) rebuilds in **seconds**
with cached component/edge outputs, instead of the ~40-min monolithic
`nix/package.nix` (one derivation, ~26,000 ninja edges) that rebuilds everything
on any source change. This is the fix for the iteration pain that dominated the
watchdog work (every 3-line launcher change = a full rebuild).

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

## Risks

- Eval cost of ~26k derivations (memory/time) — measure; may need to coarsen
  (per-library sub-targets) if eval is impractical.
- The install/fixup wrapper must exactly match `package.nix`'s output layout or
  Darling won't boot — diff the two `result` trees.
- nix-ninja lowering edge-cases on the full graph (the launcher/kernel needed
  several fixes in `lower.nix`); expect a few more on the whole tree.
