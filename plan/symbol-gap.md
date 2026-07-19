# Phase B symbol gap — x86_64-darwin, nixpkgs 26.05 bootstrap-tools

Generated 2026-07-19 by `scripts/symbol-demand.sh` (demand) + `scripts/tbd-diff.py`
(supply), against:
- demand: the 26.05 `stdenv.bootstrapTools` closure
  (`/nix/store/v6wk45fap70cgcw88x4ilzkiwzhwq6r0-bootstrap-tools`, 152 Mach-O),
  substituted from cache.nixos.org.
- SDK supply: `apple-sdk-14.4` `libSystem.tbd` re-export closure (7988 symbols).
- Darling supply: this repo's built dylibs + frameworks
  (`libexec/darling/{usr/lib,System/Library/Frameworks}`), read from the
  **exports trie** (not `nm` — see methodology).

## Headline

**The libSystem symbol surface that 26.05 bootstrap-tools imports is already
covered by Darling.** The demand-driven gap for the `hello` milestone is 6
lazy-bound FSEvents functions, which a compiler building `hello` almost
certainly never calls.

| Bucket | Count | Status |
|---|---:|---|
| Distinct system symbols imported by bootstrap-tools | 728 | — |
| ...owned by libSystem (`/usr/lib/libSystem.B.dylib` closure) | 707 | **all provided** by Darling |
| ...`dyld_stub_binder` | 1 | dyld intrinsic (lazy-bind resolver), not a real export gap |
| ...owned by CoreFoundation.framework | 14 | **all provided** |
| ...owned by SystemConfiguration.framework | 1 | **provided** (`_SCDynamicStoreCopyProxies`) |
| ...owned by CoreServices.framework (FSEvents) | 6 | **MISSING** (see below) |

## The genuine gap: 6 FSEvents symbols (CoreServices)

Imported by exactly one bootstrap binary each; missing from Darling's
`CoreServices.framework`:

```
_FSEventStreamCreate
_FSEventStreamStart
_FSEventStreamStop
_FSEventStreamRelease
_FSEventStreamInvalidate
_FSEventStreamSetDispatchQueue
```

These are **lazy-bound** (functions, two-level namespace), so a missing symbol
faults only on first *call*, not at load. Clang/coreutils building `hello` do
not exercise file-system-event watching, so this is very unlikely to block the
`hello` milestone. Deferred to Phase B.3 as a small set of loudly-logging
stubs (`FSEventStream*` returning NULL / no-op) *only if* a real binary calls
them; tracked, not yet implemented.

## Methodology notes (load-bearing)

1. **Supply must be read from the exports trie, not `nm`.** Darling exports the
   plain C string/memory functions (`_memcpy`, `_memset`, `_memmove`,
   `_memcmp`, `_strlen`, ...) as **re-exports** in `libsystem_c`
   (`[re-export] _memcpy (__platform_memmove from libsystem_platform)`). These
   never appear in `nm -gU`. An early `nm`-based scan falsely reported 18
   missing str/mem symbols; `llvm-objdump --macho --exports-trie` (which shows
   re-exports) corrected the gap to 0. `scripts/tbd-diff.py` now uses the trie.
2. **`dyld_stub_binder`** is supplied by dyld itself, not a normal dylib export;
   ignore it in gap counts.
3. **Static ≠ runtime.** This static analysis is a planning aid. The
   authoritative demand-gap is the **empirical dyld load test**: run each
   bootstrap binary under Darling and capture real missing-symbol / dyld errors
   (Phase C.2, via `scripts/triage-syscalls.sh` + `DYLD_PRINT_*`). Darling may
   resolve or fail symbols in ways static trie analysis does not capture
   (flat-namespace fallbacks, darlingserver, shared-cache behavior). Confirm
   there before trusting these counts as final.

## Implication for the campaign

Phase B was scoped as "the highest-value arch-independent work". For the
`hello`/bootstrap-tools target it is **nearly a no-op** — Darling's
Big-Sur-era libSystem already exports the macOS-14 surface these binaries use.
Effort reprioritizes to Phase A (identity) and Phase C (runtime: syscalls,
stalls, actual execution), where failures will surface. Re-run this analysis as
the package set widens (Phase E) — larger C++/Swift packages will import a
broader surface and may reopen a real gap.

## Reproduce

```sh
bt=/nix/store/v6wk45fap70cgcw88x4ilzkiwzhwq6r0-bootstrap-tools   # nix-store -r first
scripts/symbol-demand.sh --json demand.json "$bt" > /dev/null
sdk=$(nix eval --raw 'github:NixOS/nixpkgs/fd1462031fdee08f65fd0b4c6b64e22239a77870#legacyPackages.x86_64-darwin.apple-sdk.outPath')
darling=$(nix build '.?submodules=1#default' --no-link --print-out-paths)
scripts/tbd-diff.py --sdk "$sdk" \
  --darling-root "$darling/libexec/darling/usr/lib" \
  --demand demand.json --out plan/symbol-gap.md
```
