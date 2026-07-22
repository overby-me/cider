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

## Risks

- Eval cost of ~26k derivations (memory/time) — measure; may need to coarsen
  (per-library sub-targets) if eval is impractical.
- The install/fixup wrapper must exactly match `package.nix`'s output layout or
  Darling won't boot — diff the two `result` trees.
- nix-ninja lowering edge-cases on the full graph (the launcher/kernel needed
  several fixes in `lower.nix`); expect a few more on the whole tree.
