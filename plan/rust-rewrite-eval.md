# Evaluation: which parts of Darling could meaningfully be rewritten in Rust

Grounding: LOC/language measured on this tree (2026-07); architecture from the
darlingserver + libSystem + nix-ninja work this session.

## The dividing line

Darling has two kinds of code, and Rust fits exactly one of them:

- **The Linux "host" side** -- code Darling is *free to implement however it wants*,
  as long as it speaks the right protocol to the emulated processes. This is the
  daemon, the loader, the launcher, and the build tooling. **Rust fits here.**
- **The macOS "guest" ABI side** -- code that must *match Apple's binary interface
  exactly*: Mach-O dylibs targeting `x86_64-apple-darwin`, exporting the precise
  macOS symbol set, linked with classic ld64, mostly derived from Apple open source
  (libc, xnu, objc4) and validated against cache.nixos.org. **Rust does NOT fit
  here** -- rewriting means diverging from upstream (losing the correctness oracle
  and the ability to track Apple releases) plus ABI risk, for no safety win that a
  C ABI surface can even express.

The clean seam between them is the **darlingserver RPC** (a wire protocol generated
by `scripts/generate-rpc-wrappers.py`), *not* a dylib ABI. So the host side can be
rewritten in any language without touching the guest side.

## Provenance is the same line

The host/guest split is also the **origin** split, and this is not a coincidence:
you rewrite what Darling *owns and designed*, never what it *tracks from Apple*.
Verified by copyright headers + `nix/submodules.json`:

- **Strictly Darling-original** (no upstream to track): **darlingserver** (a dir in
  the main repo, "Copyright Darling developers"), **mldr** and **`darling.c`**
  (`src/startup`, "Copyright Lubos Dolezel", Darling's lead), and the **duct-tape
  glue** (Darling's own shim -- though it wraps forked XNU).
- **Forks** (carry `Copyright ... Apple Inc.`, track upstream): **libc, objc4,
  Foundation, dyld, the libSystem sublibs, the XNU duct-tape wraps**, and
  **mig/migcom** (submodule `darlinghq/darling-bootstrap_cmds`).

So "which components are strictly Darling's, not forks?" has the **same answer** as
"which are worth a Rust rewrite?": darlingserver, mldr, darling.c (+ the duct-tape
glue). Rewriting a fork would mean diverging from the source Darling deliberately
tracks -- losing the upstream and, for the ABI dylibs, the cache.nixos.org oracle.

## Candidates, measured

| Component | Own code | Lang | Origin | Rust verdict |
|---|---:|---|---|---|
| **darlingserver** (daemon) | ~7.4k | C++ | **Darling-original** | **Top candidate** |
| **mldr** (loader) | ~2.9k | C + asm | **Darling-original** | **Strong** |
| build tooling | (mixed) | C / Python | mixed (`generate-rpc-wrappers.py` Darling; mig = Apple fork) | **Easy win** |
| **duct-tape** glue | ~8.8k | C | Darling glue over ~750k **forked XNU** | Later / coupled |
| **launcher** (`darling.c`) | ~1.4k | C | **Darling-original** | Minor |
| libSystem sublibs, Foundation, dyld, objc4, ... | very large | C/C++/ObjC/asm | **Apple forks** | **No** |

(Roles: darlingserver = Mach IPC routing + microthread scheduler + epoll loop;
mldr = parse & map Mach-O, set up process, jump to entry; launcher = container/
namespace setup + exec mldr; libSystem/frameworks = the emulated macOS ABI.)

## Ranked recommendation

### 1. darlingserver -- the daemon. Highest payoff.
Only ~7.4k lines of Darling's own C++, and it is the single best fit:
- **Linux-native**, no macOS ABI constraint; the client boundary is the RPC wire
  protocol, so a Rust daemon is a drop-in as long as it speaks it.
- **The perf hot path.** Server-side levers dominate the profiling backlog (P1
  microthread context switch, P2 epoll re-arm, P8 scheduler futex, P0.7 spawn-path,
  P7 cold-start). This is concurrency- and scheduler-heavy code -- Rust's fearless
  concurrency and ownership model directly attack the data-race and lifetime
  hazards that make these hard/risky in C++ today (78 raw new/delete/malloc + 23
  thread/mutex/atomic sites in the daemon core).
- **Self-contained process** = a clean rewrite boundary.
- *Path:* stand up a Rust daemon shell that FFIs into the existing C **duct-tape**
  for XNU emulation, keep the RPC protocol byte-identical, migrate internals
  (scheduler, epoll loop, port tables) incrementally. Not a big-bang rewrite.

### 2. mldr -- the Mach-O loader. Strong, and small.
~2.9k lines. It **parses an untrusted binary format** (Mach-O) and does the
mmap/thread setup -- the classic memory-safety hazard, and Rust has mature Mach-O
crates (`goblin`, `object`). Small and self-contained (process bootstrap). Caveat:
the register/stack setup and the jump-to-entry are inline **assembly** and stay
`unsafe`/`asm!` in Rust too -- but the parsing and load-command handling, which is
where the bugs live, become safe. Good second target precisely because it is small.

### 3. Build tooling (mig, `generate-rpc-wrappers.py`, stub generators). Easy, safe.
Build-time only -- no ABI, no runtime, no correctness oracle. Same spirit as the
already-done **rust-ninja**. `generate-rpc-wrappers.py` (Python) -> Rust is a clean,
low-risk win and keeps the toolchain in one language family. Opportunistic, not
blocking anything.

### 4. duct-tape glue. Only alongside a Rust daemon; keep the XNU it wraps in C.
The ~8.8k of glue is Darling's own, but it wraps ~750k lines of **vendored XNU**
(osfmk/bsd Mach + kernel structs). Rewriting the glue standalone means an enormous
C-FFI surface into XNU internals and re-implementing kernel semantics -- high effort,
high correctness risk. Right move: leave it C, call it via FFI from a Rust
darlingserver, and migrate leaf pieces later if ever. The vendored XNU itself is
**never** a candidate (it tracks Apple).

### 5. launcher (`darling.c`). Minor.
~1.4k lines of namespace/mount setup + exec. Could be Rust (the `nix` crate covers
the syscalls), and the spawn path *is* perf-sensitive (P0.7), but the payoff is
small on its own. Best folded into a startup-path rewrite if #1 happens.

### 6. libSystem sublibraries + the macOS frameworks. Do not rewrite.
libsystem_kernel/libc/libpthread/dyld, Foundation, CoreFoundation, objc4, Security,
... These *are* the emulated macOS. They must be Mach-O with the exact Apple symbol
set, are largely ports of Apple open source (so C keeps them trackable against
upstream and against the cache.nixos.org oracle), and their syscall stubs are
mig/asm-generated. Rust buys nothing here and costs the upstream-tracking + ABI
guarantees. Note the *client-side* perf levers (P3 mach_msg, P4 signal-mask, P5
psynch, P6 RPC copies) live in this ABI-constrained layer -- so they are **not** a
Rust opportunity; the Rust perf story is server-side only.

## Bottom line

**Yes, meaningfully -- but only on the Linux host side, and darlingserver is the
one with real leverage.** Rank: darlingserver (do this, incrementally, FFI'ing
duct-tape) > mldr (small, safety win on Mach-O parsing) > build tooling (easy) >
duct-tape/launcher (later, coupled) >> the macOS ABI layer (never). The guest ABI
(libSystem + frameworks) stays C by necessity, which also means the client-side
perf work can't be a Rust play.
