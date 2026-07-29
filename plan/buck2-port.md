# Buck2 port plan (gradual, direct-first then nix-integrated)

## Why, and what "done" means

`nix-ninja` (now upstreamed to overby.me) consumes Darling's existing CMake/ninja
graph and reconstructs isolation with heuristics. That is the right tool for
*building* the whole tree once and caching it, and it stays the build of record
for the stable upstream frameworks (Security, CoreFoundation, Foundation, the
CLI tools) that we never edit.

Buck2 is the right tool for the code we *iterate on*: it gets clean isolation by
construction (deps are declared and enforced), a persistent daemon for genuinely
fast incremental rebuilds, and it makes the `nix-ninja` "wall #1" (a source
`endian.h` shadowing the system header on a globbed `-I` path) impossible,
because every target's headers are declared, not globbed.

"Done" is NOT "all of Darling in Buck2." It is: **the subtree we actively
develop (first-party host/guest + the libSystem boundary + whatever framework we
happen to be patching) builds under Buck2 with a fast daemon loop, and that
build is reproducible under Nix for CI/sharing.** Everything else keeps using the
cached dense/nix-ninja build. The port is gradual and demand-driven: a project
enters Buck2 when we start iterating on it, not before.

Endpoint for Nix integration already exists: overby.me `nix/lib/buck2`
(`buildBuck2Project`, per-action lowering, sibling to `nix/lib/ninja`). Phase 3
points it at Darling.

## Guiding constraints (learned from the nix-ninja grind)

- The whole graph already builds green on the dense path, so there are **no
  source bugs to find** — only build-definition work. A Buck2 port is about
  expressing Darling's build *correctly and explicitly*, not fixing Darling.
- The genuinely hard parts to express in ANY system are: (1) MIG codegen, (2) the
  firstpass two-pass link that breaks the libSystem umbrella cycle, (3)
  reexport / `install_name` machinery, (4) the darwin SDK sysroot + cross-arch
  (`x86_64-apple-darwin20`) toolchain, (5) the darling header shims. Spike these
  before mass porting (Phase 1) — they decide feasibility.
- Hand-written BUCK for upstream code **drifts** on every Darling bump. Mitigate
  with a CMake/ninja -> BUCK *generator* (reuse `rust-ninja -t graph-json`) to
  bootstrap targets, then hand-refine the ones we own. Generated where it drifts,
  hand-authored where we iterate.

---

## Phase 0 — Buck2 stands up, builds one real library, directly (no Nix)

Goal: prove the toolchain end-to-end on one leaf, fast, outside Nix.

1. **Get buck2 + a prelude.** Use `buck2` from nixpkgs (`pkgs.buck2`) via a
   devshell so it is on `PATH` — no need to vendor a binary. Add a minimal
   prelude (or fork the prelude's cxx rules), a `.buckconfig` at the repo root,
   and iterate with `buck2 build` directly. The nixpkgs binary is the same
   `buck2` Phase 3 reuses under Nix, so the toolchain is reproducible from day 1
   even while we iterate outside a derivation.
2. **Define the Darling toolchain as Buck2 rules.** This is where wall #1 dies.
   - the cross clang targeting `x86_64-apple-darwin20`, with the darwin SDK as an
     explicit `--sysroot`/`-isysroot` (NOT a globbed `-I`), so system `<endian.h>`
     resolves to the SDK, never a project header;
   - `system_lib`/`exported_headers` boundaries so project headers are visible
     only to declared consumers;
   - the darling `-D` defines + the platform/arch selects.
3. **Port ONE leaf target by hand** to exercise the toolchain. Candidate:
   `libsimple` or a small `system_cmds` tool (few files, no MIG, no firstpass).
   Write its `BUCK` (`cxx_library`/`cxx_binary`, `srcs`, `headers`,
   `exported_headers`, `deps`). Get `buck2 build //path:target` green from source.

Deliverable: `buck2 build` produces one real Darling artifact from source, and
the toolchain + header-scoping model is proven. This is the go/no-go gate.

## Phase 1 — Spike the hard machinery (feasibility before scale)

Each is a focused, throwaway-ok spike proving Buck2 can express the pattern.
Do them in this order (increasing risk):

1. **MIG codegen.** A `genrule` (or custom rule) running `build-mig` over a
   `.defs` to emit `*_user.c`/`*_server.c`/headers; wire the outputs as `srcs` +
   `exported_headers` of the consuming library. Verify a duct-tape-style consumer
   compiles against the generated `mach/notify.h` (note: keep the hand-written
   source `notify.h` and the mig user header at DISTINCT header roots — Buck2's
   per-target header maps make this natural, unlike nix-ninja's merged `$out`).
2. **Reexport / install_name.** Prove `-reexport_library`, `-install_name`,
   `-umbrella` flow through `cxx_library` linker_flags (or a thin linker
   wrapper). Small: one lib reexporting one other.
3. **Firstpass two-pass link (HIGHEST RISK).** The libSystem umbrella cycle:
   express `X_firstpass.dylib` stubs (link with stubbed/`-undefined
   dynamic_lookup` symbols), the umbrella `libSystem.B.dylib` reexporting all
   firstpass libs, and final `X.dylib` linking the umbrella. This is a real DAG
   once firstpass != final are distinct targets, so Buck2 should handle it — but
   it is the thing most likely to need a custom rule. Spike with libSystem +
   2-3 sub-libs (libc, libnotify) before trusting the pattern.
4. **Cross-arch + SDK.** Confirm the toolchain select builds `x86_64` (and later
   `arm64`) with the right sysroot and codesign/lipo steps if needed.

Deliverable: a documented Buck2 idiom for each of MIG, reexport, firstpass, and
cross-arch. If firstpass cannot be expressed cleanly, that is the signal to keep
libSystem on nix-ninja and start Buck2 above it.

## Phase 2 — Gradual project porting, iterating with Buck2 directly

Port demand-first, dependency-order within each demand.

1. **Bootstrap with a generator, refine by hand.** Write a `graph-json -> BUCK`
   emitter (reuse `rust-ninja -t graph-json`, already in overby) that produces a
   first-cut `BUCK` per CMake target (srcs, the declared deps, the command's real
   `-I`/link flags). It will be imperfect (the same undeclared deps nix-ninja
   guesses), but it turns "author 100 files" into "review + fix N files."
   Hand-refine the targets we own into clean, explicit `cxx_library`s.
2. **Order:** the libSystem tier first (it is everyone's dep and the boundary we
   care about), then only the projects we actually develop. Leave the rest on the
   dense build.
3. **Keep the fallback.** Everything not yet in Buck2 keeps building via
   dense/nix-ninja; the two coexist (Buck2 artifacts can consume nix-built
   prebuilt dylibs as `prebuilt_cxx_library` at the boundary). This is what makes
   the port gradual instead of all-or-nothing.
4. **Fast loop:** `buck2 build` with the daemon; edit a `.c`, rebuild only its
   action + dependents. This is the payoff — validate it feels fast on the
   first-party subtree before widening.

Deliverable: the actively-developed subtree (first-party + libSystem) builds and
rebuilds fast under a direct `buck2` daemon; the boundary to the cached dense
build is a set of `prebuilt_cxx_library` targets.

## Phase 3 — Integrate with Nix

Now make the Buck2 build reproducible/cacheable without giving up the daemon.

1. **Point overby `buildBuck2Project` at Darling.** overby's `nix/lib/buck2`
   already lowers Buck2 actions to per-action Nix derivations (the Buck2 analog
   of what we just upstreamed for ninja). Feed it Darling's BUCK targets ->
   `nix build .#darling-buck2` yields the same artifacts, per-action cached +
   shared via Cachix, no `buck2` daemon needed in CI.
2. **Two-mode dev:** local = `buck2` daemon (fast, incremental); CI/shared =
   Nix-lowered (hermetic, cached). Same BUCK definitions feed both.
3. **Retire nix-ninja for the ported subtree**, keep it for the un-ported dense
   tail until (if ever) that tail is worth porting.

Deliverable: one BUCK source of truth; `buck2` for local iteration, Nix-lowered
Buck2 for reproducible/cached builds; nix-ninja scoped to the unported remainder.

---

## Sequencing summary

| Phase | Outcome | Gate |
|---|---|---|
| 0 | Toolchain + one leaf lib green under `buck2`, direct | header-scoping model works |
| 1 | MIG / reexport / firstpass / cross-arch idioms proven | firstpass expressible? |
| 2 | Actively-developed subtree fast under `buck2` daemon | daemon loop feels fast |
| 3 | Same BUCK reproducible/cached via overby `buildBuck2Project` | parity with dense artifacts |

## Explicit non-goals

- Porting the stable upstream framework tier (Security/CF/Foundation/CLI tools)
  wholesale. Cache the dense build for those; port on demand only.
- Maintaining a hand-written BUCK definition for code we do not edit (it drifts).
  Generated-and-refined only.
- Replacing the dense `.#default` build, which stays the whole-tree build of
  record until the Buck2 port demonstrably covers what we need.

## Biggest risk

The **firstpass two-pass link** (Phase 1.3). It is the one Darling idiom that is
genuinely awkward in any explicit build system. Spike it before committing to the
port; if it resists a clean Buck2 expression, draw the Buck2/nix-ninja boundary
*above* libSystem and port only the tiers that iterate.
