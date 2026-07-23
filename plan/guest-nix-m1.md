# Official guest-Nix M1: `nix build #hello` from source under Darling

Status (2026-07-24, overnight autonomous run): **the entire guest-Nix build
pipeline works end to end; hello's build reaches configure and fails only at the
first clang invocation, on the known darlingserver fork/exec concurrency bug.**

The campaign goal (hello builds from source + runs under Darling) was already met
at the toolchain level (M1, `scripts/build-hello-under-darling.sh`, re-confirmed
this run: `hello_rc=0`, "Hello, world!"). This doc is the *official* path -- driving
the build through guest `nix build` rather than hand-run configure/make.

## What now works (was "3 sub-projects, not overnight" per 26.05-facts)

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
   closure (the darwin stdenv output `hqv865az-stdenv-darwin` is cached, HTTP 200)
   and builds only hello. The bootstrap intermediates (`bootstrap-stage0-stdenv`,
   HTTP 404) are only needed to *build* the stdenv, which we don't -- we fetch its
   output. Fix on the host: `nix-store -r` of hello.drv's input drvs (29 paths,
   7.5 MiB) so the overlay presents the full closure to the guest.
6. **nix builds ONLY hello** -- unpackPhase, patchPhase, configurePhase run; ~15
   configure checks pass, each running nix-substituted tools (coreutils `install`,
   `mkdir`, gawk, gnutar, make) successfully under Darling.

## The remaining blocker

configure's compiler check (`checking whether the C compiler works`) fails at the
first `clang` invocation. Across two runs it failed two different ways:
- run 1: the container **fork/exec-stalled** (mldr frozen, no clang spawned);
- run 2: clang **`Abort trap: 6` (SIGABRT, core dumped)**.

Every other tool in configure ran fine, so this is not a broken toolchain per se --
the variance (stall vs abort at the same step, host idle) is the signature of the
**darlingserver / libsystem_kernel fork/exec/SIGCHLD concurrency bug** documented in
plan/blockers.md, hit by the fork-heavy nix-stdenv configure (the lighter
bootstrap-tools configure in the toolchain-M1 path does not trip it as readily).

So the guest-Nix M1 is gated on the **same fork/exec concurrency issue** that the
darlingserver perf work (P-series) and the Rust-rewrite candidate (plan/
rust-rewrite-eval.md) target -- fixing that unblocks this.

### Isolated (2026-07-24 overnight)

- **Unwrapped clang runs fine standalone** under Darling (`clang 21.1.8 --version`
  ok). So the toolchain is not broken.
- The build uses the nix **cc-wrapper** (a bash script that forks to clang), so the
  clang check is `configure -> sh -> cc-wrapper(bash) -> clang` -- an **extra fork
  layer** vs the toolchain-M1 path (direct bootstrap clang, which works). That
  deeper/fork-heavier process tree reliably trips the bug at the clang check.
- A **retry loop does NOT get past** it -- attempts stall at the same step (the
  failure is reliable, though it varies between a fork/exec stall and a SIGABRT).
- Therefore the two ways forward are: (a) fix the darlingserver fork/exec/SIGCHLD
  concurrency (the real fix; a sub-project), or (b) build hello with a **non-wrapper
  CC** (fewer forks) -- which is essentially what the toolchain-M1 path already does.
- **FD exhaustion ruled out**: host limit is 524288 (darlingserver inherits it), no
  EMFILE in any log; the "failed to increase FD rlimit" warning is benign (it tries to
  set nr_open=2e9, fails, stays at 524288). So it is the concurrency race, not a ceiling.

  So **toolchain M1 is the pragmatic "hello from source" answer today**; the official
  guest-`nix build` path is 95% there and waits on the concurrency fix.

## Reproduce

```sh
# host: fetch hello's full build closure + seed dump
nix-store -r $(nix-store -q --references <hello.drv> | grep '\.drv$')
nix-store --dump-db <closure minus hello output> > hello-db.dump
# guest (one darling shell session): scripts/gnix-hello.sh
touch <prefix>/.enable-writable-nix
DPREFIX=<prefix> darling shell sh gnix-hello.sh
```
`scripts/gnix-hello.sh` carries the full recipe.
