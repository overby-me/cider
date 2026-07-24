# Official guest-Nix M1: `nix build #hello` from source under Darling

Status (2026-07-24): **the entire guest-Nix build pipeline works end to end;
hello's build reached configure and failed at the first clang invocation. Root
cause found and fixed: a single missing libc++ symbol (`__libcpp_verbose_abort`),
NOT the darlingserver concurrency bug it was first attributed to.** Fix applied
in `patches/libcxx/0001`; monolith rebuild + re-run in progress to confirm
`hello_rc=0`.

The campaign goal (hello builds from source + runs under Darling) was already met
at the toolchain level (M1, `scripts/build-hello-under-darling.sh`: `hello_rc=0`,
"Hello, world!"). This doc is the *official* path -- driving the build through
guest `nix build` rather than hand-run configure/make.

## What works (was "3 sub-projects, not overnight" per 26.05-facts)

The pessimistic 26.05-facts assessment predates a key piece: **darlingserver.cpp
already implements a writable-`/nix` overlay** (host `/nix/store` + `/nix/var`
read-only lowers, tmpfs uppers, unprivileged `userxattr`), opt-in via a
`<prefix>/.enable-writable-nix` marker. With that, a single darling-shell session
(scripts/gnix-hello.sh) gets all the way to compiling hello:

1. **darwin nix runs under Darling** -- `nix (Nix) 2.34.8`.
2. **Writable native `/nix`** -- the overlay gives `nix_store_WRITABLE` +
   `nix_var_WRITABLE`; nix writes build outputs to the tmpfs upper.
3. **Local store, not the daemon** -- `NIX_STATE_DIR=/Users/root/nixstate` (a fresh
   guest-owned state dir; the inherited `/nix/var/nix/db` is owned by the unmapped
   host root in the rootless userns, so unwritable, and it has a daemon socket that
   makes nix auto-pick daemon mode). Also `NIX_LOG_DIR`, `HOME`, `TMPDIR` under
   `/Users/root` (`/tmp` is read-only in the container).
4. **Trust the pre-populated store** -- seed the fresh db with hello's **complete**
   build closure via `nix-store --dump-db` (host side) + `--load-db` (guest). The
   closure must be *complete*: `nix-store -qR --include-outputs` only lists *present*
   outputs, so the missing stdenv output was silently excluded until realised (see
   below). `sandbox = false`, `require-sigs = false`, `substituters = ""` (offline).
5. **No stdenv rebuild** -- on real macOS `nix build #hello` substitutes the whole
   closure (the darwin stdenv output is cached, HTTP 200) and builds only hello. The
   bootstrap intermediates (`bootstrap-stage0-stdenv-darwin`, HTTP 404) are only
   needed to *build* the stdenv, which we don't -- we fetch its output. Fix on the
   host: `nix-store -r` of hello.drv's input drvs (29 paths, 7.5 MiB) so the overlay
   presents the full closure to the guest.
6. **nix builds ONLY hello** -- unpackPhase, patchPhase, configurePhase run; ~15
   configure checks pass, each running nix-substituted tools (coreutils `install`,
   `mkdir`, gawk, gnutar, make) successfully under Darling.

## The blocker: one missing libc++ symbol (`__libcpp_verbose_abort`) -- FIXED

configure's compiler check (`checking whether the C compiler works`) failed at the
first `clang` invocation, two different ways across runs (a fork/exec **stall**
once, a **`SIGABRT`** the next). That variance *looked* like the darlingserver
fork/exec/SIGCHLD concurrency bug, and was first filed as such -- **wrong**.

Running the build with `--keep-failed` and reading clang's own stderr
(`conftest.err`) gave the real, deterministic cause:

```
dyld: Symbol not found: __ZNSt3__122__libcpp_verbose_abortEPKcz
  Referenced from: .../llvm-21.1.8-lib/lib/libLLVM.dylib (built for Mac OS X 14.0)
  Expected in: /usr/lib/libc++.1.dylib
```

That is `std::__1::__libcpp_verbose_abort(char const*, ...)`, the single
verbose-termination entry point libc++ gained in **LLVM 14**. Darling's libcxx is
**LLVM 13** and never exported it, so the nixpkgs LLVM-21 clang/libLLVM cannot be
loaded under Darling -- dyld aborts (the SIGABRT), or the aborting process leaves
the container in the stalled state that masqueraded as the concurrency bug.

**It is the only genuine libc++ gap.** `llvm-nm` over the *entire* nixpkgs clang
closure (every binary + dylib under `clang-21.1.8/{bin,lib}`), filtered to
top-level `std::__1` symbols and diffed against Darling's built
`libc++.1.dylib` + `libc++abi.1.dylib`, yields exactly one missing symbol:
`__ZNSt3__122__libcpp_verbose_abortEPKcz`. The other ~134 `std::__1` symbols
libLLVM imports are all already exported.

### Fix

Add `std::__1::__libcpp_verbose_abort` to Darling's libc++, mirroring the existing
`std::pmr` addition: a self-contained `src/verbose_abort_std.cpp` (standard
behaviour -- `vfprintf` the message to stderr, then `abort()`), forced to default
visibility (libcxx builds `-fvisibility=hidden`) so it is actually exported, and
listed in the libcxx `CMakeLists.txt`. Carried in
`patches/libcxx/0001-build-std-filesystem-into-libcxx.patch`. The compiled object
exports exactly `_ZNSt3__122__libcpp_verbose_abortEPKcz` (verified with `llvm-nm`
before the rebuild).

This was never the concurrency issue; the toolchain-M1 path avoids it only because
the in-tree bootstrap clang (LLVM 13-era) does not reference the LLVM-14 symbol.

## Reproduce

```sh
# host: fetch hello's full build closure + seed dump
nix-store -r $(nix-store -q --references <hello.drv> | grep '\.drv$')
nix-store --dump-db <closure minus hello output> > hello-db.dump
# guest (one darling shell session): scripts/gnix-hello.sh
touch <prefix>/.enable-writable-nix
DPREFIX=<prefix> darling shell sh gnix-hello.sh
```

`scripts/gnix-hello.sh` carries the full recipe; run with `--keep-failed` (already
set) to inspect any future build-dir failure via `conftest.err`.
