# Darling runtime overhead: bash under Darling vs native

Question (user): *benchmark bash under Darling vs the system, to evaluate the
overhead of Darling.*

Two workloads isolate the two cost classes Darling adds:

- **compute** — a pure bash arithmetic loop (`i=0; while [ $i -lt N ]; do
  i=$((i+1)); done`). No `fork`/`exec`; almost no syscalls. Measures the
  **per-operation runtime/libSystem overhead** of executing bash code under
  Darling. (Darling is *not* a CPU emulator — instructions run native — so a
  naive expectation is "near-native"; the measurement tests that.)
- **spawn** — `bash -c :` in a loop, N fork+exec of a fresh shell. Each spawn
  routes through **darlingserver** (Mach/BSD emulation) + **dyld** re-mapping the
  libSystem re-export closure. Measures Darling's **process-creation overhead** —
  the number that maps directly to build time (configure/make fork thousands of
  short-lived processes).

## Method

Single warm container boot (`DPREFIX=~/.dbash`, already populated — a *fresh*
prefix hits the first-boot launchd stall). Both loops run inside that one boot, so
the container-boot cost is excluded and we measure the marginal per-iteration /
per-spawn wall-clock. `time` (bash keyword, `TIMEFORMAT=%R`). Native side runs the
identical `scratchpad/wl.sh` loops on the host. Numbers below are the mean of 2
reps; the two reps agreed to within a few %.

## Environment

- Host: this Linux box, ~22 cores, load ~2.5 during the run (the concurrent build
  sweep had drained). Native bash **5.3.9(1)**, nixpkgs build (**-O2**).
- Darling: monolithic `result` runtime (`…-darling-unstable-2025`), macOS 14.4.1 /
  Darwin 23.4.0 identity, after the ucred perf fix. Darling bash **5.3.0(1)
  x86_64-apple-darwin23.4.0**, built in-prefix by `build-bash-under-darling.sh`.

## Results

| workload | native -O2 | native -O0 (control) | Darling (bash 5.3.0, -O0) | **Darling overhead** |
|---|---|---|---|---|
| compute (per iter, n=1e6) | 2.32 µs | 5.54 µs | ~42.0 µs | **~7.6×** (matched -O0) |
| spawn (per proc) | 2.44 ms | 2.27 ms | ~27.9 ms | **~11–12×** (opt-independent) |

Darling compute reps: 42.576 s, 41.412 s (n=1e6). Darling spawn reps: 0.806 s,
0.869 s (n=30). Native -O2: compute 2.323 s (n=1e6), spawn 0.487 s (n=200).
Native -O0 control: compute 5.623/5.460 s (n=1e6), spawn 0.068 s (n=30).

The headline: **process spawn is ~11–12× slower under Darling** (the build-time
tax), and even **pure computation is ~7.6× slower** once build flags are
controlled for.

### The compute ratio is confounded by build flags — controlled

The Darling bash was built with `CFLAGS="-isysroot … -fcommon"` and **no `-O`**,
so it is effectively **-O0**, while native bash is nixpkgs **-O2**. A bash
interpreter loop is very sensitive to that: most of the raw 18× is the -O0/-O2
gap, not Darling. Matched-optimization control — native bash rebuilt **-O0** from
the **same bash-5.3.0 source** (`x86_64-pc-linux-gnu`): native -O0 compute =
**5.54 µs/iter** (5.623, 5.460 s at n=1e6). So the raw ratio decomposes cleanly:

> **18× ≈ 2.4× (build flags, -O0 vs -O2) × 7.6× (Darling runtime).**

The **true Darling compute overhead is ≈ 7.6×** (42.0 µs ÷ 5.54 µs), matched
version + matched optimization on both sides.

The **spawn ratio is optimization-independent — confirmed by the control**: the
native -O0 bash spawned at **2.27 ms/proc**, essentially identical to native -O2's
2.44 ms (spawn is dominated by fork/exec + darlingserver RPC + dyld image loading,
not the interpreter). So **~11–12× is a robust figure for Darling's
process-creation overhead**, independent of how bash itself was compiled.

## Attribution: where the ~28 ms/spawn goes (dyld vs darlingserver)

`DYLD_PRINT_STATISTICS=1` on one spawn under Darling (it *is* honored):

```
Total pre-main time:   6.24 ms (100%)
  dylib loading:       1.35 ms (21.7%)
  rebase/binding:      0.44 ms (7.1%)
  ObjC setup:          0.39 ms (6.3%)
  initializer time:    4.04 ms (64.7%)   <- libSystem constructors
```

So the split of the ~28 ms marginal spawn is roughly:

| bucket | time | what it is | lever |
|---|---|---|---|
| dyld image mapping | ~1.8 ms | dylib loading + rebase/binding | **P0.5** dyld shared cache |
| libSystem initializers | ~4.0 ms | constructors; many RPC to darlingserver | daemon RPC path |
| fork/exec + darlingserver registration + RPC + teardown | **~22 ms** | the Mach/BSD emulation round-trips | **P1/P2/P6** |

**This partly refutes the earlier P0.5 hypothesis** (`perf-improvements.md` guessed
dyld mapping was "the bulk of the tens-of-ms per spawn"). The data says dyld image
mapping is only ~6% of the spawn; a shared cache saves ~1.8 ms, not ~20 ms. **The
dominant cost (~78%) is the darlingserver fork/exec/RPC path** — so the highest
wall-clock lever is cutting spawn-path RPC round-trips and context-switch overhead
(P1 sigmask-free context switch, P2 epoll re-arm), not the dyld cache. Caveat: one
dyld sample on a lightly-loaded host; the ~22 ms "other" is inferred (28 − 6.2) and
includes daemon-side work `DYLD_PRINT_STATISTICS` cannot see. The `-111`
(semaphore/mach_msg) lines during init/teardown corroborate that initializers and
teardown are bouncing through darlingserver.

## Interpretation → where the overhead lives

- **Spawn ~11× (≈25 ms/proc absolute).** This is the build-time tax and it lines
  up with the perf catalog: every exec re-maps and re-relocates the 31-sublibrary
  libSystem re-export closure from scratch because the prefix ships **no
  `dyld_shared_cache`** — see `plan/perf-improvements.md` **P0.5** (the biggest
  wall-clock lever), plus the darlingserver RPC round-trips per fork/exec (P1/P2
  signal-mask + epoll re-arm).
- **Compute overhead (the controlled figure).** That even a no-fork loop is
  measurably slower than native -O0 means per-operation libSystem cost (bash
  touches signal masks, locale, small malloc per command) is heavier under
  Darling. Smaller lever than spawn, but it means the tax is not confined to
  process creation.

## Reproduce

```
# native baselines
bash scratchpad/wl.sh bash 1000000 200
# darling (warm prefix, workload file at prefix-root => container /bench.sh)
DPREFIX=~/.dbash result/bin/darling shell \
  /Users/root/bbuild/bash-5.3/bash /bench.sh /Users/root/bbuild/bash-5.3/bash 1000000 30
```
