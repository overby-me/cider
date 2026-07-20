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

## Addendum 2026-07-20 — runtime-confirmed gap (the `hello` *build* closure)

The headline above analyzed `stdenv.bootstrapTools`. The **actual `nix build
hello` closure is larger** — it pulls the full `stdenv` toolchain incl.
`coreutils-9.11` (a macOS-14 build not in bootstrap-tools). Running the
from-source build under Darling surfaced a real, strong (non-lazy) dyld failure
that the bootstrap-tools scan could not see:

```
dyld: Symbol not found: _mkfifoat
  Referenced from: .../coreutils-9.11/bin/coreutils (built for Mac OS X 14.0)
  Expected in: /usr/lib/libSystem.B.dylib
```

**Full-closure demand-vs-supply** (methodology below), over the 323 realized
build-input paths / 490 Mach-O of `hello-2.12.3.drv`:

- undefined system symbols: 10383; Darling supply (nm-defined ∪ export-trie
  re-exports over 478 dylibs/frameworks): 140254 → **16 genuinely missing**.
- Of the 16, **9 are weak/optional sanitizer hooks** (`___lsan_*`,
  `___sanitizer_symbolize_*`) present only in `libclang_rt.*san*.dylib`, which a
  plain `hello` build never loads.
- **7 real libSystem functions.** By referrer:
  | symbol | referrer(s) | for hello? |
  |---|---|---|
  | `_mkfifoat`, `_mknodat` | `coreutils-9.11` (strong) | **yes — the blocker** |
  | `__os_log_error_impl`, `__os_log_debug_impl` | `libutil-73` + 7 | maybe (libutil) |
  | `_freadlink`, `_OSAtomicFifoEnqueue/Dequeue` | only ASan/TSan runtimes | no |

**Fix (this repo):**
- `mkfifoat`/`mknodat` are *not* Darwin syscalls (absent from
  `syscalls.master`) — on macOS they're libSystem entries. Added emulation
  handlers `sys_mkfifoat`/`sys_mknodat` (mirror `sys_mkdirat`: `atfd(fd)` +
  Linux `__NR_mknodat`) at **private BSD slots 546/547** (first free past
  `SYS_MAXSYSCALL`), with hand-written `bsdsyscalls/_mkfifoat.S`/`_mknodat.S`
  stubs (`gen/syscall.h` gains `SYS_mkfifoat`/`SYS_mknodat`). The x86_64
  dispatcher indexes `__bsd_syscall_table[600]` with no bound check, so 546/547
  are valid.
- `_os_log_error_impl`/`_os_log_debug_impl`: type-fixed thin wrappers over
  `_os_log_impl` in `libtrace` (`os_log.c` + `os/log.h`).

Carried as `patches/xnu/*` and `patches/libtrace/*`.

**Methodology note (supersedes the trie-only supply used above).** The
`_memcpy`/`_strlcpy` "misses" in a first cut were false positives: `libSystem.B`
re-exports `libsystem_c` wholesale via `LC_REEXPORT_DYLIB`, and `libsystem_c`
re-exports the str/mem funcs *renamed* (`[re-export] _memcpy (__platform_memmove
from libsystem_platform)`). Accurate supply must be **`nm --defined-only` ∪ all
export-trie names (incl. `[re-export]` entries) over every dylib** — trie-only or
nm-only each undercount. See `scratchpad/` gap scripts.

