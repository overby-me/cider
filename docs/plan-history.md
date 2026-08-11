# PLAN.md history: per-task post-mortems, archived 2026-08-11

Moved out of PLAN.md verbatim so that file can be navigated. NOTHING HERE IS DELETED and
nothing is summarised: several of the fixes made on 2026-08-11 came out of post-mortems
written weeks earlier, so the detail is the point. What PLAN.md keeps is status,
architecture, the invariants, the open queue and the harness traps; what moved here is the
per-task narrative of how each one was reached.

The durable RULES that were embedded in these narratives were hoisted back into PLAN.md
rather than left only here, so this file is provenance rather than something to consult
before working.


---

## Archived from PLAN.md lines 28 to 634

## Buck2 port: the order to work in

**DONE and no longer in this list:** #54 (cascade cut, per-file staging into mirrored real
directories), #55 (lowered derivations content-addressed), #71 (xnu-sys ported to Rust, 16 of
16), #73 (closed by re-testing it: no host target compiles a `DARLING`-guarded source, so there
was nothing behind it), #83 (the vendored XNU subset is a pin, not committed source: 1,974
files deleted, 51 local deltas became a patch dir). Their detail is further down and in the
commit history.

**#83 SHIPPED WITH A LATENT BREAK, AND THE GREEN RUN THAT CERTIFIED IT NEVER TESTED IT.** This
used to cite an endpoint green at 1,185 builders and 0 errors as the proof. That run REUSED
`cider-buck2-graph` from before the de-vendoring, so the tree it staged still held the vendored
copy: the green covered the old staging. Check any gate with

```
grep -c "building '/nix/store/[a-z0-9]*-cider-buck2-graph.drv'" <gatelog>
```

Zero means reused, which is fine for a change that cannot reach the graph and worthless for one
that moves it. What it hid: `escapeSrc` read every escape root out of `srcRaw` behind a
`pathExists` guard, de-vendoring turned that root into a pin, the guard went false, and the
carry was dropped IN SILENCE, leaving the security pin link to `duct-tape/xnu` dangling until
`security_codesigning_obj` died on a missing `security/mac.h` an hour into a later gate. Fixed
in `d51dfbc7` by falling back to the pin store, and now proven by that same target building
green. `scripts/buck-escape-roots-check.py` guards the class, and the suite calls it.

The general rule, since this will recur: **moving a tree from the repo into a pin changes its
CATEGORY, and every `pathExists` guard that named it silently stops contributing.** Note that
`os.path.exists` still says the tree is there, because `buck-src.nu` materializes the pin at
that path; `jj file list` is the honest test.

**THE STAGING FAULTS OF #83 CANNOT BE CAUGHT BY BUILDING ANYTHING.** The generated staging
script has no `set -e`, and both faults succeed at the shell level: `ln -sfn X dir/` creates
`dir/X`, and a failed `rm -f` is never looked at. So the tree is wrong and the script still
exits 0, and it surfaces later as an unrelated compile error. Even libsimple stages the pin
(3 of its 8 staging scripts in the store do, and 2 carry the duplicate alias); it just
compiles nothing that reads the tree that went wrong. `scripts/buck-lowering-stage-check.nu`
READS the script, which is the only thing that works, and it now reads the one the gated
endpoint actually runs.

**THE UPPERCASE HALF OF THE RENAME IS SETTLED.** Of the 83 all-caps `DARLING` names our tree
uses, **46 are referenced by the pins and keep their names** (`DARLING_NW_STUB` 1861,
`__DARLING__` **772 in 188 pin files** (579 in buck-src plus 193 in the nested xnu pin, which a buck-src-only count misses), the `DARLING_CONVERSION_*` family, the
`_DARLING_EMULATION_*` guards, `__PTK_DARLING_KEY0..9`). The provably-ours subset is renamed:
20 include guards and 5 build-time or internal names. Everything still outstanding is an
interface a person types, so it is a user decision: the six runtime env vars,
`DARLINGSERVER_INIT_PROCESS`, and the bare `DARLING` shell override. Bare `DARLING` in C is
NOT renameable either: it is `#ifdef DARLING` in bundled Apple launchd, and patch content.

**CLIMB THE LADDER FROM THE BOTTOM.** Three hours went on 2026-08-10 chasing a shell-script
fault with two endpoint runs. In cost order:

| rung | command | measured 2026-08-10 |
| --- | --- | --- |
| 1 | `scripts/buck-lowering-stage-check.nu` | **7 s** warm, 329 s on a cold graph |
| 2 | `nix build .#cider-buck2-one` | **18 s**, 3 builders |
| 3 | `nix build .#cider-buck2-prefix-min` | **hours** (1,185 builders, but see the #83 note: that run reused the graph) |

Rung 1 is only cheap against the endpoint that is actually gated: pointed at
`.#cider-buck2-prefix`, whose graph nothing else builds, the same check measured **917
seconds** because it rebuilt that graph first. Naming the wrong endpoint does not fail, it
just silently costs a graph build. Never start at rung 3.

**A RUNG 3 BUILD CAN WEDGE, SO WATCH IT:** `scripts/buck-stall-watch.py <log>`. The endpoint
reproducibly hits a nix-daemon stall where the worker holds max-jobs unreaped children with
none live and nothing moves again; the cause is unknown and needs root to chase. Recovery is
`kill -TERM` the CLIENT, never the daemon, then relaunch, which resumes from the store with no
work lost. Do not judge it by `ps` %CPU: that is a lifetime average and reads ~42 percent for
a worker doing 0.35.

**CMAKE IS GONE (#82), buck2 is the only build.** Removed 2026-08-09 on the user's word that
they do not ship it: 13 cmake package outputs, 8 nix-ninja group outputs, 8 nix libs
(`package.nix`, `xnu-sys.nix`, `cctools-port.nix`, `cider-{graph,base,component,components}
.nix`, `ciderNinja.nix`), 258 CMakeLists and `cmake/`, plus cmake and ninja from the dev shell
and the toolchain. About 21,700 lines. `packages.default` is now `cider-buck2` and the checks
build `cider-buck2-min`. VERIFIED: the minimal endpoint builds with zero cmake files present,
exit 0, 4,574 builders, 0 errors. Nothing in the buck2 path ever invoked ninja, so ninja went
with it; the `overby` input STAYS, because `ciderBuck2.nix` uses its `buildBuck2Project.nix`.

**THE ONE-WAY DOOR, stated plainly:** FIVE generators are now unrunnable and marked FROZEN in
place rather than deleted. Four read a reference `build.ninja` that nothing can regenerate
(`gen-buck-from-ninja.py`, `gen-mig-from-ninja.py`, `buck-host-includes.py`, `buck-port.py`) and
stop working entirely once a store GC collects `result-graph-ref`; `gen-xnu-sys-buck.py` reads
`xnu-sys/CMakeLists.txt` and so cannot run at all. Everything they produced is committed.

**RUN THESE TWO BEFORE ANY LONG BUILD. One second together, and each already saved an hour.**
`scripts/buck-pin-paths-check.py` resolves all 8,332 paths we record INTO a pin;
`scripts/buck-labels-check.py` resolves all 24,944 labels, `load()` files and symbols, and
config sections. Both verified BOTH ways against real damage.

They exist because the Cider rename broke eight things no compiler could see, five of which
each cost a failed hour-long launch. Every `buck-src/<pin>` is an upstream darlinghq repo and
43 of them carry their OWN `darling/` subdirectory, so the boundary is not the directory:
**upstream keeps the old name in its paths, patch headers, repo and org; only first-party names
become Cider, and `buck-src/BUCK` is first-party even though it sits among pins.** The classes:
the fetch manifest (`owner`, `repo` AND `path`); upstream URLs; `patches/` headers, which must
match paths like `a/darling/src/...`; 1,700 paths plus 433 labels into pins; a plist renamed on
disk but not in its BUCK; `buck-src/BUCK` keeping 185 references to renamed first-party targets;
a `load()` whose reference moved but whose FILE did not; `read_root_config("darling", ...)`,
which returns the DEFAULT silently and gave wrapgen an empty `elf_lib_dirs`; and 2,078 SYMLINK
TARGETS.

**The symlink one is the one no sweep can ever catch, and it is worth remembering past this
rename: a link TARGET is not file content, so grep does not read it.** The security pin ships
2,078 links naming `src/external/darlingserver/duct-tape/xnu`, upstream's own layout, and they
surfaced only as a package load failure naming a path that appears NOWHERE in the tree.
`buck-src-normalise.py` now translates them through `FIRST_PARTY_RENAMES`: 2,092 dangling links
under `buck-src` before, 13 after, and those 13 predate this work. **After any rename run
`find . -type l -printf '%l\n' | grep <old name>`.**

There was a NINTH, and it is the same symlink class in a second place, which is the lesson:
`buck-src-normalise.py` runs only in `ciderBuck2Graph.nix`, so it never saw the lowering's own
staging. `pinsTree` walks its assembled tree for dangling relative links and carries the
destination in from `escapeSrc`, but it resolved `security/darling/submodules/xnu` against the
pre-rename `src/external/darlingserver/duct-tape/xnu`, failed its `lexists` test, and **skipped
the carry in silence.** Gate run 11 proved it at builder 3,618 as the ONLY root cause in the
whole endpoint: `reqinterp.cpp:46: fatal error: security/mac.h file not found`. The carry loop
now translates through the same table, translating the SOURCE while the destination keeps the
name the dangling link points at. **A rename table has to reach every place that resolves a
path, not just the one that stages the pins.**

Verified on ONE derivation rather than another endpoint: `nix build
.#cider-buck2-prefix-min.pinsTree` needs only 2 derivations, and in the result the link
resolves and `security/mac.h` is present. It still POINTS at the pre-rename name, which is the
design working: the destination keeps the name the link uses and the carry fills that path from
the translated source. Both directions rest on real artifacts, the run 11 failure without the
fix and this tree with it.

Two limits worth stating. The label check does NOT verify target existence generally: 105
distinct targets are synthesised by `elf_wrapper` as `<n>_wrap` and `<n>_dylib` from lists local
to a BUCK file, so reporting them would be noise. And the pin check tests `lexists`, because
`darwin/Developer` is written for the STAGED layout and 2,002 of its 2,636 links dangle in a
checkout by design.

**NORMALISATION HAPPENS IN THE GRAPH DERIVATION AND NOWHERE ELSE, AND THAT IS A REAL GAP.**
Found 2026-08-10 when `security_codesigning_obj` failed on `security/mac.h file not found`,
which is NOT rename fallout. In the pin store, `security/darling/submodules/xnu` is a SYMLINK
to `../../../darlingserver/duct-tape/xnu/`, upstream's own path for that tree. Locally that
link gets retargeted and expanded into per-file links by `buck-src-normalise.py`. But a compile
derivation stages its own tree from the pin STORE, and the normaliser only ever runs inside
`ciderBuck2Graph.nix`, so what a compile sees is the dangling upstream link.
`recursive` is NOT the differentiator: `security` has it false and `IOKitUser` true, and BOTH
stores hold exactly one entry there, the symlink itself.
**THE FIX CANNOT LIVE IN `pinStore`, and that corrects what this entry said an hour ago.**
Measured on a copy: put the security pin store next to a tree containing
`pins/ciderd/xnu-sys/xnu`, run the normaliser, and the dangling upstream link becomes a
real directory of per-file links with `security/mac.h` resolving. It reported
`expanded 17 symlinked directories, re-pointed 7 symlinks`. So the fix NEEDS the xnu tree
beside the pin, and a pin store is self-contained: normalising at fetch cannot see it.
**AND THE LOWERING ALREADY NAMES THIS EXACT LINK.** A compile stages pins through
`pinPath p = "${pinsTree}/${p}"`, and `pinsTree` is built from the ASSEMBLED tree precisely
because per-pin stores are incomplete. But the assembled tree carries the dangling link too,
since normalisation runs only in `ciderBuck2Graph.nix`. The comment listing the 21 links that
escape a pin store already spells ours out: seven leave `pins` entirely, six into
`darwin/Developer`, and **`security -> ciderd/xnu-sys/xnu`, which is first-party vendored and
not a pin at all**, needing rewriting to an absolute store path, the same treatment #54 needs
for group escapes. So the fix is to normalise when `pinsTree` is built, not at fetch, and it is
the already-identified work rather than something new. Latent for as long as a warm store satisfied those targets; the rename forced a
rebuild and exposed it.

**THE DAEMON RUNTIME GATE IS 23 CHECKS, 140 to 152 s** (four consecutive runs on the renamed
tree; the older 115 s figure predates the Rust demos being restored). **It is INDEPENDENT of
the nix endpoint**, because it builds through buck2 in the dev shell, and it stayed green
through every one of the endpoint failures above. Use it as the fast signal that the
first-party code is coherent; an endpoint failure on its own says nothing about the daemon.
`scripts/xnu-sys-runtime-check.nu` covers the
six ported xnu-sys files plus the 17 proofs that `checks.server` used to run: Mach ports,
`mach_msg`, blocking receive, the guest-memory hooks, the generated RPC dispatch, per-guest
routing, persistent threads and four daemon capstones. Those 17 were orphaned by the cmake
removal, because cargo built them through `nix/server.nix` and they had no buck2 target; they
have one now. Run this after ANY xnu-sys or linux/server change.

**THE BUCK2 REGRESSION SUITE RUNS AGAIN: `scripts/buck-test.nu`, 149 passed, 0 failed, 905 s.**
It was previously unfinishable, because two sections spawned one buck2 client PER TARGET (568
dylibs, then the executables) at 15 to 30 s each while printing nothing. `out_map` now builds
each set in ONE `buck2 build --show-output --keep-going`. That run is the broad check on the
cmake removal and the xnu module move: both green.

**THE MINIMAL ENDPOINT COMPLETES, and that is new.** 2026-08-09: `.#cider-buck2-prefix-min`
at `--max-jobs 6 --cores 2 --keep-going` ran **1,551 buck2 builders to exit 0 with 0 errors in
about 56 minutes**, then a no-op rebuilt **0** in 18 s onto the same output,
`b4yvk9hh...-buck2-cider_prefix_min-out`. Earlier runs that looked like an unfixable daemon
stall are not reproducible: the one real failure was a staging regression, now fixed. Do not
plan around the endpoint being unrunnable.

**#79 DONE: the cascade is cut, 1,558 builders to 44.** Measured on the endpoint by builders
that RAN, each probe with its own restore control that came back 0 onto the identical baseline:

| edit | builders | time |
| --- | --- | --- |
| none (control) | **0** | 16 s |
| `libaccessibility/src/Accessibility.m`, a leaf | **7** | 165 s |
| `linux/startup/rtsig.c`, a header generator | **570** | 19 min |
| `xnu-sys/src/*.c` BEFORE | **1,558** | 61 min |
| `xnu-sys/src/*.c` AFTER | **44** | 2.5 min |

Only the last row was ever a leak. `nix-diff` named its sole cause: the ciderd GROUP
STORE interpolated as `_g` into every target stage script, with no dependency edge behind it.
`rtsig.c` is legitimate, it is a `host_gen` that GENERATES `rtsig.h`. The fix is `groupSplit` in
`nix/lib/ciderBuck2Lower.nix`: a blanket cut starves the compiles, because
`buck2-graph-sources.py` keeps `pins` out of the grouping and the whole-directory group
is its only supplier, so every target gets the headers and `scripts/` while only labels under
`root//pins/ciderd/xnu-sys` also get `xnu-sys/src`.

**A BUCK EDIT IS NOT A FULL REBUILD ANY MORE.** The standing advice was to batch BUCK edits
because each costs a full rebuild. Measured 2026-08-09 with a control either side:

| run | builders | time | prefix output |
| --- | --- | --- | --- |
| none (control) | **0** | 18 s | `6fx01v8p...` |
| one leaf BUCK edit (`darwin/libaccessibility/BUCK`) | **3** | 7.5 min | `6fx01v8p...` UNCHANGED |
| restore | **0** | 1 s | `6fx01v8p...` |

The 3 are the graph pipeline itself, skeleton then graph then sources. Nothing downstream moves,
because a BUCK file is read by buck2 to PRODUCE the graph and is never staged into a target, so
when the graph output comes out byte identical CA cuts the whole endpoint off.

**AND THE REAL TARGET CHANGE IS ALSO NOT A FULL REBUILD.** The caveat above said a comment is
not the interesting case. Adding one compiler flag to a leaf `cc_objects` costs **7 builders**,
and they are exactly the right ones:

    skeleton, graph, sources          the graph pipeline
    Accessibility_obj                 recompiled, the flag changed it
    Accessibility_dylib               relinked
    cider_prefix_min, -out          the prefix

Control 0 either side, and the restore lands back on `6fx01v8p...`. So a BUCK edit costs the
same as an ordinary leaf source edit, 7 builders. **Batching BUCK edits is no longer required.**

**COUNT `^building`, NEVER the "these N derivations will be built" list.** `dserver_rpc` appears
in that list in both runs and produced ZERO builder lines. Counting the listing would have
reported a rebuild that never happened. That is CA early cutoff, visible where it is easiest to
misread.

**#69 CLOSED as superseded by #54, verification finished on the way.** The narrowed endpoint had
never been run to completion; doing so found ONE defect:
`scripts/buck2-graph-sources.py` recorded only the CRATE ROOT for a `rust_library`, so of 77,709
recorded sources the whole server crate contributed one file and it died with
`error[E0583]: file not found for module`. rustc argv names `lib.rs` and finds the rest through
`mod`, which an `#include` scanner cannot see. The generator now takes a rustc crate directory
wholesale. The endpoint then went green, exit 0, 1,466 builders, and its prefix is BYTE
IDENTICAL to the unnarrowed one.

The flag never flipped, and that was measured: `narrowSources` was INERT for the shipping
endpoint, which gave the SAME drvPath either way, because `stageProjectFor` under #54 stages
ONLY groups plus pins and never reads `projectSrc`. Both flags narrowed the same thing and #54
won. **DELETED 2026-08-09 on the user decision**: the flag, the `srcUnion` builder and the two
`-narrow` flake outputs are gone. `projectSrc` STAYS and is now simply `src`; it is the shared
staged tree every non-grouped target uses, and an earlier note claiming it could go with the
flag was wrong.

1. **#66 / dynamic derivations: TRIGGER CHECKED AFTER #54, AND IT HAS NOT FIRED.** Measured
   with the cascade cut and `sourceGroups` on: **6.5 s** to evaluate one target, **18.8 s** for
   the whole endpoint, against a ~70 s edit loop, so eval is about **9%** of it. The threshold
   was a third. Also corrects two stale numbers: `sourceGroups` eval is **18.8 s**, not the
   32.6 s recorded, so it is now CHEAPER than the 22.6 s figure it used to be compared against.
   Not now: eval is about 9% of the loop. Triggers, any one: eval exceeds roughly a third of the edit loop once #54 lands;
   per-target data is forced into the evaluator (`target-sources.json` is 588 MB and takes eval
   21.4 s to 75.6 s); the full prefix hits an eval memory wall; or a #5805 instance appears
   that cannot be worked around. Cheap pre-check first, on a toy: does `builtins.outputOf` work
   at all on 2.34.x, and does early cutoff SURVIVE it, given a consumer binds to the producing
   derivation rather than its content.
2. **#71, DONE (16 of 16). Kept only for the numbers, which were wrong when the task was
   written.**
   19 first-party glue `.c` (12,415 lines), not 17; **300** XNU `.c` behind the `-sys` crate,
   not 49; and the FFI surface is **189 distinct `xnu_sys_*` symbols** referenced from Rust.
   Re-counted: `xnu-sys/src/*.c` is **16 files, 8,525 lines** (the 19/12,415 above also swept
   in `pthread/kern_synch.c` 2,805 and `kern_support.c` 1,020, which sit outside that dir).
   `thread.c` 2,072, `task.c` 1,766 and `memory.c` 1,554 are 63% of it.

   **THE ORDERING ABOVE WAS WRONG, and `scripts/xnu-sys-portability.py` now measures it**
   instead of arguing it. Only two things are hard blockers: a C VARIADIC DEFINITION (stable
   Rust cannot write `extern "C" fn(...)`) and a MACRO CALL (bindgen binds no macros).
   * `misc.c` was named a first candidate. It ranked **last of sixteen** because it DEFINES
     three variadic functions (`xnu_sys_log`, `kprintf`, `scnprintf`), which Rust cannot express.
     That verdict was too strong and it went twelfth: see the variadic note below.
   * `timer.c` was the other. It calls `mpqueue_init`, a MACRO, so it needs a shim either way.
   * `traps.c` is not blocker-free either: its last line is `DSERVER_XNU_SYS_DEFS`, a generated
     object-like macro. (It is still a thin FFI shim that buys little.)
   * `init.c` (137) has the best BLOCKER profile: no variadics, one macro (`xnu_sys_log_debug`).

   **BLOCKERS ARE NOT THE ONLY AXIS, and the two disagree.** The tool also reads the FFI
   surface off each compiled object, which is the truth the linker sees: symbols the port must
   EXPORT, and symbols it must CALL OUT to. `semaphore.c`, which went first and worked, was
   5 exports / 7 calls. By that measure `init.c` is the WORST of the small files at 4 / **40**,
   and `traps.c` (fewest blockers) is 35 / 36 because `DSERVER_XNU_SYS_DEFS` expands to so much.
   **`condvar.c` is 3 / 7**, the closest match to the file that worked, and its five macros are
   `TAILQ_*` and `__container_of`, all trivial intrusive-list operations to write in Rust.
   So `condvar.c` is the next one, not `init.c`.

   `init.c` is still worth doing, and its one real unknown is already retired: it defines the
   `xnu_sys_hooks` GLOBAL that every other C glue file dereferences, and a C archive reading a
   Rust-defined global was verified to link and run (negative control: removing it fails the
   link with undefined reference).

   **`condvar.c` IS PORTED TOO**, and both ported files have a runtime demo.

   **THE PREFIX GATE ALSO PASSED WITH `condvar.c` IN** (gate4: 1,875 builders, zero failures,
   `NIX_EXIT=0`, `/nix/store/m8nihyc7s2pr3p9095830msxq4ql6p4w-vm-test-run-cider-buck2-smoke`;
   same VM assertions, `exit 0` in 0.31 s and the `exit 1` arm correctly failing).
   **`timer.c` is NOT covered by it**: gate4 was launched at `c3e2e26f` and the timer port
   landed two commits later, so timer still rests on symbols, a unit test and the demos.

   **THE PREFIX GATE PASSED ON THE SEMAPHORE PORT** (`cider-buck2-min-smoke`, 1,875 builders,
   **zero** builder failures, `NIX_EXIT=0`,
   `/nix/store/f0h9xzhq7qfmc393s4sqzm0cdrn7fkw4-vm-test-run-cider-buck2-smoke`). Not a
   vacuous pass: inside the VM, `command -v cider-buck2` succeeded, `cider-buck2 shell
   /bin/bash -c 'exit 0'` succeeded in 0.17 s, the `exit 1` arm correctly FAILED, and exit
   codes propagated out of the container. So a buck2-built Darling whose `xnu_sys_semaphore_*`
   come from Rust boots a container and runs bash in the guest.
   **That run was launched on the semaphore-only commit, so it validates `semaphore.c` and NOT
   `condvar.c`**; condvar's prefix gate is a separate run.

   The stress number, for whatever changes this path next: **500,000 suspend/resume round-trips
   in 5.79 s, 11,587 ns each**, no assertion. There is no pre-port figure to compare against.

   **`timer.c` IS PORTED**, and the reason it was skipped twice was WRONG.
   The claim was that reopening the `queue_.*`, `_?lck_.*` and `priority_queue.*` opaque types
   for `mpqueue_init` would drag most of osfmk into the shared bindings. That was asserted,
   never measured. **Measured: +9 structs and +7 KB** (49 structs / 40,546 B to 58 / 47,749 B),
   and the daemon plus all three demos still build. Adding the timer headers took the total to
   61 structs / 49,304 B. Never cite that cost again without the number.

   **`host.c` IS PORTED.** The reason it had been backed off was real but was
   answered rather than avoided: every export is a MIG SERVER ROUTINE reached through generated
   dispatch, so a mismatched signature is not a compile error but silent corruption. Answer: do
   not transcribe any of them. All twelve signatures are written in GENERATED types, including
   the two structs passed BY VALUE (`security_token_t` 8 bytes in a register, `audit_token_t` 32
   in memory), which are exactly the shapes a hand mirror gets wrong quietly.
   Cost of reopening: **+11 structs, +7.8 KB** (61 / 49,304 B to 72 / 57,134 B).
   `vm_statistics` stays OPAQUE: those paths only zero it, so only its SIZE is needed.

   **The verification had to be a different KIND**, and that generalises to the rest of the
   file set. semaphore, condvar and timer fail LOUDLY, so finishing at all is most of the proof.
   `host.c` hands NUMBERS to the guest, and a wrong offset crashes nothing. So `host_demo`
   checks against `/proc/meminfo` and `/proc/cpuinfo`, which share no code path with the
   `sysinfo`/`sysconf` calls the port uses. Exact, not close: max_mem 33072345088 both ways,
   22 CPUs both ways. Comparing sysconf against sysconf would have agreed with itself however
   wrong the layout was.

   **THE PREFIX AND SIX PORTS ARE GATE-VERIFIED (gate7, head 85841249).** 1,577 builders, ZERO
   errors, zero failed builders, NIX_EXIT=0, 1 h 15 m, and the VM assertions held: exit codes
   propagate out of the container, script finished in 14.50 s,
   `/nix/store/y0nq738fh7acsgims1w2r5pja5jsdwpq-vm-test-run-cider-buck2-smoke`.
   That covers the minimal prefix at 853 entries (jsc and Swift removed), the timer, host,
   processor, init, debug and locks ports, twelve shims, and the ipc, host and processor
   reopenings. NOT covered, because they were committed after it launched: `kqchan.c` and
   `traps.c`.

   **#71 IS COMPLETE: 16 OF 16 PORTED.** semaphore, condvar, timer, host, processor, init,
   debug, locks, kqchan, traps, psynch, misc, stubs, task, memory, thread.

   **Verified by the archive, not by assertion:** every one of the sixteen `.c.o` is gone from
   `libciderd_xnu_sys.a`, and `task_xnu.c.o`, `memory_xnu.c.o` and `thread_xnu.c.o`
   remain, which is the boundary the task set. (`host.c.o` in that archive is XNU
   `osfmk/kern/host.c`, not xnu-sys's; `host_info` is undefined there.) ciderd links
   and `scripts/xnu-sys-runtime-check.nu` passes.

   **THE THREE BIG FILES WERE SPLIT along the XNU boundary they already marked**, rather than
   translating lifted kernel code:

   | file | was | glue ported | copied XNU left in C |
   |---|---|---|---|
   | `task.c` | 1766 | 763 | 1003 |
   | `memory.c` | 1554 | 1170 | 384 |
   | `thread.c` | 2072 | 1383 | 689 |

   Each split was proved by the archive SYMBOL SET being unchanged apart from the new member.
   `thread.c` did not split cleanly: `LockTimeOutUsec` and `thread_handoff_internal` crossed the
   boundary, and the second is glue the copied code calls, so it lost its `static` and Rust
   provides the symbol now.

   **26 shims**, each because Rust genuinely cannot reach the thing: macros, `static inline`,
   statement expressions, a file-static lock group, and an intrusive red-black tree that
   `RB_PROTOTYPE_SC` makes entirely file-local.

   **Reopening beat shimming for the big three types, and the recorded REFUSALS were reversed on
   evidence:** `task` at +21 structs and 91 KB for 12 fields, `thread` at +13 and 58 KB for 18,
   and the `vm_.*` blanket removed for +3 and 1,780 B. `linux/server/src/layout.rs` is what made
   that safe: it asserts sizes and container offsets against the C compiler at BUILD time, and a
   perturbed expectation fails the build.

   **THE VARIADIC BLOCKER IS CLOSED.** `stubs.c` and `misc.c` were called blocked on 1 and 3
   variadic DEFINITIONS. All four are pure forwarders to a `v`-variant, so all four stay in C in
   `xnu-sys/src/xnu_sys_rs_shims.c` beside the macro shims, and everything else in both files is
   Rust. Rust can CALL a variadic even though it cannot define one, so the ported code formats
   with `format!` and passes a plain `%s`, which is safer than the C it replaces: a specifier
   that disagrees with its argument is now a compile error. No remaining file is blocked.

   **THE SHIM IS THE MAIN TOOL, and it is what made the second half tractable.**
   `xnu-sys/src/xnu_sys_rs_shims.c` exports twelve macro-only or inline-only operations as real
   symbols, with a header so bindgen generates the signatures. Each exists because Rust cannot
   reach the thing, never for convenience: `kalloc` and `kheap_alloc` expand to statement
   expressions holding a static `vm_allocation_site_t`; `io_release` is `static inline` so
   there is no symbol at all; `MACH_PORT_MAKE` has two definitions selected by `NO_PORT_GEN`;
   `ip_object_to_port` is a `__container_of`.

   **REOPENING IS THE ALTERNATIVE, AND IT IS USUALLY THE WRONG ONE. Measured, every time:**

   | reopen | cost | verdict |
   |---|---|---|
   | `ipc_.*` | +16 structs, +34.5 KB | DONE, debug.c genuinely walks those fields |
   | `processor` + `processor_set` | +15 structs, +8.2 KB | DONE |
   | `host` | +2 structs, +767 B | DONE, cheaper than a shim |
   | `thread` + `waitq` | +17 structs, +68 KB | refused THEN, revisit: `thread.c` reaches 18 fields |
   | `task` | +21 structs, **+91 KB** | refused THEN, revisit: `task.c` reaches 12 fields |

   **The last two verdicts were taken when reopening would have saved ONE shim, and the files
   that need them tell a different story:** `task.c` reaches **12** distinct fields through the
   opaque `struct task` and `thread.c` reaches **18** through `struct thread`. `memory.c`
   reaches **zero** of either, so it needs neither reopening. Re-measured 2026-08-08 at +21 and
   91,372 B, close to the original figure.

   **The reason to hesitate was that reopening might lay the fields out differently from C, and
   that is now measured rather than feared.** `linux/server/src/layout.rs` asserts Rust against
   the C compiler at BUILD time (sizes and container offsets for task and thread; `wrapper.h`
   supplies the C answers as enumerators). It holds both with `task` opaque and with it
   reopened: 1616 bytes, `xnu_task` at offset 112 either way. Perturbing an expected size by 8
   fails the build, so the check is not vacuous. bindgen ran with `--no-layout-tests`, so before
   this **nothing at all** checked the invariant that every `container_of` port depends on.

   **FOUR RANKING BUGS, all the same shape: the measurement was right and the SUMMARY of it
   misled.** The tool preprocessed files with a missing generated header and reported the
   partial result (`traps.c` ranked first with zero blockers for weeks because its one blocker
   lives in the header that was not found); it counted function names as opaque TYPES; its type
   probe stopped at clang's 20-error limit; and it counted macros that expand to nothing or
   forward to a real symbol. Run `--file` before starting a port, and read GLUE, not LINES.

   **WHAT ELSE COULD GO TO RUST AFTER #71, measured rather than guessed.** All first-party
   C/C++ outside the vendored trees, by lines:

   | subsystem | lines | origin | verdict |
   |---|---|---|---|
   | `darwin/CoreAudio` | 73,619 | **MIXED, mostly Apple** | 233 of 316 files are Apple: `CoreAudioUtilityClasses` (195) is Apple's published sample library, `AudioFileTools` (38) is Apple's. Darling's own is ~83 files, the component and toolbox glue plus the ffmpeg bridge |
   | `darwin/libm` | 61,868 | Apple Libm, containing Sun 1993 fdlibm | NO, upstream |
   | `darwin/launchd` | 26,842 | **Apple** | NO, bundled upstream |
   | `darwin/OpenDirectoryOld` | 7,354 | Apple-era | NO |
   | `darwin/xtrace` | 4,391 | Darling | syscall tracer, guest-side |
   | `linux/hosttools` + `linux/buildtools` | 1,509 | Darling | **BEST FIRST TARGET**, see below |
   | `linux/libelfloader` | 864 | Darling | mldr is already Rust and consumes this |
   | `darwin/xcselect` | 679 | Darling | |
   | `darwin/shellspawn` | 634 | Darling | load-bearing: it is what `cider shell` uses, and it is in the minimal prefix |
   | `darwin/libsimple` | 562 | Darling | the lock and log layer xnu-sys sits on; the Rust daemon ALREADY links it as a C archive |

   **THERE ARE NO SUBMODULES IN THIS REPO.** No `.gitmodules`, and `git ls-files` tracks
   `pins/...` directly, so EVERYTHING is plain vendored content. "Bundled" is therefore
   not a decision anyone made about `libm` in particular; it is how the whole tree works. The
   distinction that matters for porting is ORIGIN, not how the content arrived.

   **TWO EXCLUSIONS THAT ARE NOT ABOUT EFFORT.** The 10,104 `.m` files under `darwin/` are
   reimplementations of Apple's ObjC frameworks and have to stay ObjC, since they implement ObjC
   runtime APIs. And Apple-origin bundled code (`launchd`, `libm`) should NOT be ported at all:
   it is upstream code this project tracks rather than owns, and rewriting it forfeits the
   ability to take upstream fixes. That is the same de-vendoring rule as everywhere else here.

   **THE HOST TOOLS ARE THE BEST FIRST TARGET, and the argument is risk profile rather than
   size.** `coredump` (1,153 lines), `elfdep` (182) and `getuuid` (174) run on the BUILD
   MACHINE: no guest ABI, no Mach semantics, no microthreads, and a mistake fails loudly at
   build time. That is the exact inverse of xnu-sys, where the recurring hazard has been the
   silent wrong answer: a mis-filled `host_info` field, or an `always_inline` that linked
   everywhere except the daemon. A first port outside xnu-sys should buy experience without
   buying that failure mode.

   `darwin/libsimple` is the other one worth naming, for a different reason: the Rust daemon
   already links it, so porting it would remove a C archive from that link entirely. It stays
   C-ABI either way, since the still-C glue calls it too.

   `scripts/xnu_sys_stub.rs` now provides `xnu_sys_stub`, `xnu_sys_stub_safe` and
   `xnu_sys_stub_unsafe` as Rust macros over the real `xnu_sys_stub_log` symbol, so the seven
   remaining files that use them do not each re-derive it.

   Two mechanisms were proven by experiment before any port code, both with negative controls:
   bindgen PARSES the XNU internal headers given xnu-sys's own flags (`-fblocks` is load
   bearing), and a C ARCHIVE RESOLVES against a Rust rlib, which is the direction the port needs
   since `kqchan.c` stays C and calls `xnu_sys_semaphore_up`.

   **The runtime check for a port is `scripts/xnu-sys-runtime-check.nu`, about a minute**,
   not the hour-long minimal-prefix gate. It builds `//linux/server:scheduler_demo` and blocks
   a microthread on a xnu-sys semaphore, so `xnu_sys_semaphore_create`, `down_simple` and `up`
   all run for real, down through XNU and back out through the suspend/resume hooks. It asserts
   on the OUTPUT (`SCHED_DEMO_OK`), never the exit code: breaking `down_simple` to report every
   successful wait as interrupted prints `SCHED_DEMO_DOWN_FAILED` and STILL EXITS 0, because the
   demo's own asserts (did it suspend, did it finish) both still hold.

   **`semaphore.c` IS PORTED** (60 lines, one macro, and it exercises the whole seam). Proof it
   is not vacuous: in `libciderd_xnu_sys.a` the four `xnu_sys_semaphore_*` are `U` and
   `semaphore.o` is gone; in the linked daemon they are `T`. Types and the `xnu_task` offset come
   from bindgen, not transcription: `linux/server/wrapper.h` binds the internal structs, and
   `flags.bzl` (generated) keeps the buck2 and cargo include sets identical.

   Keep the existing `xnu_sys_*` symbol names so the Rust daemon links unchanged.
   **THE VERIFICATION IS ITSELF A PROBLEM, and this was checked before writing any port code.**
   `checks.cider-buck2-smoke` builds the FULL prefix, and at `--max-jobs 5` it ran 106 minutes,
   2,212 builders, **zero builder failures**, and then died with
   `error: Nix daemon disconnected unexpectedly (maybe it crashed?)` in the stage-tree phase.
   **THE FULL PREFIX CANNOT COMPLETE ON THIS BOX. The kernel OOM-killed nix-daemon, twice,
   and LOWER parallelism made it worse:**

   | run | `--max-jobs` | daemon RSS at kill |
   |---|---|---|
   | first | 5 | **14.6 GB** |
   | retry | 2 | **16.1 GB** |

   `oom-kill: constraint=CONSTRAINT_NONE, global_oom, task=nix-daemon` on a 30 GB machine, both
   times in the stage-tree phase, both times with ZERO builder failures. This is #48 with exact
   numbers: daemon memory tracks DATA per derivation, NOT concurrency, which is why halving the
   jobs did not help. Two attempts is the limit; not relaunching a third time.

   **So #71 must gate on the MINIMAL endpoint**, which completes (1,617 builders, verified this
   session, prefix hash matching). A xnu-sys change lands in `ciderd`, so the gate it
   needs is a boot against the minimal prefix, not a full-prefix VM.
   NOT `kern_synch.c` first: it is the psynch path, where this daemon already had a silent
   SIGSEGV from a null `pthread_list_mlock`.

**CLOSED, AND IT WAS A FALSE ALARM OF MY OWN MAKING: comparing pin counts across two gate logs
counts RESOLVED and UNRESOLVED derivations as if they were different builds.** The scare was
that 117 pin derivations, `buck2-pin-JavaScriptCore` among them, appeared to re-run on a change
that cannot reach them (gate3, semaphore only: 1,875 builders / 202 pins; gate4, plus condvar
and timer: 572 / 117).

The two JSC pin `.drv`s are **the same build**. Diffing their build environments with store
hashes AND CA placeholders normalised leaves **2 differing lines out of 37**, and both are
representation, not content:
* one has a CA `/PLACEHOLDER` where the other has the realised
  `/nix/store/...-buck2-stage-project-grouped`;
* `"out": ""` against a concrete output path.

That is Nix's RESOLVED DERIVATION: before building a CA derivation it substitutes realised
inputs and builds that instead, under a different store path. It is also why one side's
`--query --references` ends in `.drv` and the other's does not, and why a build failure earlier
in this work was reported as `build of resolved derivation ... failed`.

**So there is no cascade leak here, and the 572 against 1,875 remains the cut working.**
The lesson is narrower than the scare: **counting derivations across two logs is not a
measurement**, because the same build appears under two paths. Judge by builders that RAN
WITHIN ONE run, which is the standing rule, and if two runs must be compared, compare the
normalised build environment rather than the paths.

**THE MINIMAL PREFIX IS 62.1% OF WHAT IT WAS, measured on the cone, not the clock**
(the box has a concurrent session running builds, so wall time is not comparable):

| | targets | actions | share |
|---|---|---|---|
| original | 4,324 | 17,532 | 99.9% |
| minus `jsc` | 4,293 | 16,234 | 92.5% |
| minus userland nix can fetch | 4,194 | 15,399 | 87.7% |
| minus the GUI cone and 4 superseded libcryptos | 4,080 | 12,051 | 68.7% |
| minus the security daemons | 3,993 | 10,902 | 62.1% |
| minus ssh, curl, openssl, the LAST libcrypto, BerkeleyDB, BIND, libarchive, APR | 3,776 | **9,003** | **51.3%** |

**8,549 actions gone, 48.7%: the minimal endpoint is now under half what it was.**

**CONFIRMED IN A REAL BUILD, not only in the cone.** Two gate logs, same endpoint, before and
after the `jsc` removal: **167,477 JavaScriptCore mentions and 2 build lines become 4 mentions
and ZERO build lines.** JavaScriptCore is not compiled at all any more. Wall clock is not
quotable on this box (a concurrent session runs its own nix builds), which is exactly why the
check is "did the derivation run", not "how long did it take". The principle that got there: the prefix carries what nix needs
TO START, and nix pulls the rest from nixpkgs once it runs. `tests/nix-in-cider.nix` shows
the bootstrap does no network I/O at all -- the HOST fetches and extracts the installer and
copies it in, and the guest runs `bash -x install --no-daemon` then local eval/store commands.
So TLS, trust and keychain are off the bootstrap path.

`scripts/buck-prefix-cost.py` is what finds these. Two modes, because there are two questions:
`--top` ranks entries by EXCLUSIVE cost (which single line is safe to delete) and
`--expensive` ranks TARGETS with their pullers (what is costly and who asks for it). The
second is not derivable from the first: AppKit and CoreImage were 752 actions pulled by four
tools, and no single one of them showed in the exclusive ranking. `--check` guards it at 150
exclusive actions per non-exempt entry, verified to catch both `jsc` and `secd`.

**`--graph` IS REQUIRED, and that is the interesting part.** It used to default to the "newest"
dump in the store, which was never a choice: Nix pins store mtimes to the epoch, so all 27
tie and `max()` returns whatever the glob yields first. All four graph attributes (the
single-target demo, `-all`, `-min`, `-min-skeleton`) also build a derivation with the SAME
NAME, so the path cannot distinguish a 5,709 action demo from the 17,552 action minimal graph.
It drew a small one and printed a ranking that looked entirely sensible. Two changes: the tool
now lists the candidates with action counts and refuses to pick, and it asserts LABEL COVERAGE
on every run. The correct min graph resolves 601 of the prefix's 899 labels (67 percent; the
other 298 are action-less `export_file` targets, plists and conf files, legitimately absent
from an ACTION graph); the wrong one resolved 128 (14 percent). Floor is 50 percent.

Re-measured on a pinned graph, so the shrink table is like-for-like rather than against a
graph total: **17,532 actions / 4,324 targets / 2,016 labels becomes 8,696 / 3,485 / 853.**
Half the actions, 50.4 percent.

**THIS LEVER IS NOW SPENT, which is worth stating so nobody spends another day on it.** The
three costliest entries are exactly the three EXEMPT ones, dyld 644, bash 182 and
ciderd 136, which are the goal rather than dead weight. The worst non-exempt entry is
`iokitd` at **32**. Everything still large is shared base that no entry owns: libsyscall 453
pulled by 547 entries, icucore 446 by 178, XNU emulation 288 by 546, compiler-rt 138 by 540.
Nothing sizeable can be removed by dropping entries any more, so `--check` (budget tightened
150 to **60**) is now a ratchet against regression rather than a search tool. Further build-time
work has to come from the invalidation cascade, not from the prefix.

Worth doing in the next INVALIDATING batch, not on its own: give each graph attribute a
distinct derivation name. That is the root cause of the store ambiguity, but renaming a
derivation rebuilds everything downstream of it.

Out of this thread: #39 (Swift LFS pointers).

#61 IS DONE AND THE CLAIM HERE WAS STALE. It used to say configd needed upstream
SystemConfiguration rewiring rather than a bump. Re-measured 2026-08-10: that blocker was
gone (the cmake it depended on had been removed), and configd and xnu both landed as an
ordinary revision bump in c99441f1, verified on both bisect targets plus rungs 1 and 2.

---



---

## Archived from PLAN.md lines 1759 to 1858

## Grouped build: eval speed (done) vs incremental rebuild (open) — task #80

The grouped lowering (task #78) built every ninja edge's command + staging script as a Nix
string DURING EVAL, so whole-Darling eval was ~15-40 min, paid on every build (the graph-json
IFD busts Nix's eval cache). Fixed by **build-time lowering** (`nix/lib/nix-ninja/build/lower_group.py`,
flag `buildTimeLowering`): Nix eval now computes only each group's `{edge list, external-group
drvs}`; the tool reads the shared `graph.json` in the sandbox and does the rewrite/stage/run.
Measured: `cider-full-group-bt` eval **~58 s** (was ~35 min); migcom + libSystem green through
it. `cider-{group-test3,libsystem-group,full-group}-bt` exercise it; the legacy eval-time
`mkGroup` path is untouched behind the flag.

**Incremental rebuild is a separate, still-open problem, and it is NOT just source staging.**
A small source edit currently triggers a ~full recompile, because of a chain of store-path
couplings that all rehash on any source change:
- `cmakeSrcStore` (whole source tree) rehashes → CMake **re-configures** (~min) →
- `build.ninja` bakes absolute `cmake-src` / `cmake-ninja-configured` paths → the **graph-json
  (`graphDrv`) rehashes** (confirmed: `graphDrv` contains those store paths) →
- every bt group derivation reads `graphDrv` (and mounts the rewrite roots) → **all ~900 groups
  rebuild**.

So per-component source staging alone cannot deliver incrementality — `graphDrv` is the dominant
blocker. The full fix is three pieces, in order:
1. **Relativise the graph** so `graphDrv` is content-stable across source edits (strip the
   rewrite-root prefixes in the graph-json derivation; make it content-addressed so a re-config
   that yields byte-identical relative content keeps the same store path). This is the key
   enabler — without it (2)/(3) are moot.
2. **Per-component source subtrees** (`builtins.path` slice of `cmakeSrcStore/<component>`,
   content-addressed): a group depends only on its component's subtree, so editing one `.c`
   re-keys just that component. Keeps eval fast (no per-file `indivOf`/`readDir` in eval).
3. **Configure decoupling**: feed the configure derivation only CMake-relevant files so a
   `.c`-content edit does not re-run cmake at all.

Honest architectural note: this is exactly where the nix-ninja + IFD approach hits its
structural ceiling. Even done perfectly, it re-evaluates every build (~58 s) and its
incrementality is per-*derivation* (whole component recompiles), never per-*action* (one `.o` +
relink). **Buck2's persistent daemon avoids all of these store-path-rehash couplings by design**
(no configure/eval per build, per-action deps) — so the fast edit->rebuild inner loop is the
genuine case FOR a Buck2 port, distinct from the eval-speed problem (which was a fixable Nix
issue, now fixed). Recommendation: finish the full-green grind (#2) + implement (1)-(3) to get a
~1-3 min component-incremental loop with no port; treat Buck2 as the deliberate next step only if
that loop proves too slow for how Darling actually gets developed.

### Full-green grind (#2): where it stands (branch `wip-mega-group-unwind`)

The build-time path (`cider-full-group-bt`) grinds green through migcom -> libSystem -> xnu-sys
-> libc -> and reaches the `security/*` / openssh tier. Mechanical gaps fixed along the way (all
committed): skip CMake housekeeping targets, shebang rewrites on staged sources AND generated script
outputs, rspfiles, ext-dir de-symlink before cp, command-referenced source staging, srcHeaders
non-header include-chain data (`.exp`/`.exp-in`/`.list`/`.ipp`), cctools ar+ranlib co-grouping by
OUTPUT tool dir.

Wall #2 from the earlier note (the `build-mig` dense-staging mega-SCC) is now UNWOUND, and the
xnu-sys `notify.h` wall is FIXED. Committed on the branch (`639e374e`, `c723f265`):
- **notify.h source-restore** (`lower_group.py`): `mach/notify.h` exists as BOTH a hand-written
  source header (defines `MACH_NOTIFY_*` + the notify structs) and a mig re-emission (routine stubs
  only). The merged `$out` cannot hold both; mig's copy shadowed the source and broke every
  `<mach/notify.h>` kernel consumer. Fix: after a source-backed generated header is produced, restore
  the authoritative source copy over it (the mig `.c` consumers only need the structs, also in source).
- **mega-SCC unwind** (`lower.nix`): `rawHeaderProducerGroups` is now GROUP-LEVEL pure -- a mixed
  pure-gen + compile-dependent group no longer becomes a universal dep, so `build-mig` no longer
  absorbs xnu-sys/bootstrap_cmds/... Mixed-group header producers retarget per-component via
  `migByCompDir` (which skips source-backed headers).
- **Tarjan SCC topo** (`lower_group.py`): the old Kahn fallback dumped a blocked SCC's edges in
  list order, mis-ordering acyclic producer->consumer pairs riding on the SCC (libc's dylib link ran
  before the `notify_firstpass` it links). Replaced with iterative Tarjan condensation (producers
  first; only genuine cycles emit as a block). Fixed libc.

Remaining `cider-full-group-bt` failures (18, taxonomised), in priority order:

1. **Source header shadows a SYSTEM header for a C compile (WALL #1, ~14 failures, dominant).**
   Confirmed via the compiler's `In file included from` chain (NOT a plain libcxx-on-`-I` issue):
   a C compile in `security/*` (e.g. `Security_x86_64_only_stuff`, `SecLogging.c`; `-std=gnu99`, no
   `-isysroot`) includes the SDK's `corecrypto/ccdigest.h` -> `cc.h` -> `cc_config.h:429`, which does
   `#include <endian.h>`. That resolves to `src/external/security/OSX/libsecurity_utilities/lib/
   endian.h` -- a SOURCE header shadowing the system `<endian.h>` because security's lib dir is on the
   compile's `-I` list -- and it drags in the security_utilities C++ chain (`utilities.h` -> `errors.h`
   -> `<exception>` -> libcxx `<cstddef>`), which is C++-only and explodes in C mode (`unknown type
   name 'using'`). So the trigger is `-I` precedence over SYSTEM headers, not libcxx per se. The
   reference build avoids it (some mix of `-isysroot`, `-iquote` vs `-I`, or not having that lib dir on
   the C compile's search path); our flat merged-`$out` + broad `-I` list does not. Fix needs deliberate
   header-search scoping so source-tree dirs do NOT shadow toolchain/SDK system headers for a compile
   that only asked for `<endian.h>` -- e.g. move project header dirs to `-iquote`/`-idirafter`, or add
   `-isysroot <SDK>` AND ensure system-name includes prefer the sysroot. This is the genuinely DEEP
   design wall (same class the eval-time `mkGroup` path would hit); needs a header-search decision, not
   a one-line strip. UNVERIFIED fix.
2. **libbsm cross-group `libSystem.B.dylib` staging (1 failure, foundational).** `libbsm` links the
   final umbrella `libSystem.B.dylib`; at BUILD time it is missing from libbsm's group sandbox. Ground
   truth (instrumented): libbsm's group ran but did NOT contain the libSystem.B producer edge, and the
   umbrella dylib was not ext-dir-staged in -- yet an eval probe reported the two edges in the SAME
   group with the producer in `extGids`. That **eval-vs-build grouping inconsistency** is the bug to
   chase next (idsInGroup vs the `--edges` actually passed, or a realProducers path-form mismatch).
3. **Generated data files not staged (2 failures).** openssh `ge25519_base.data`, libsecurity_cssm
   `derived_src/funcnames.gen` -- generated non-header data a compile reads, not reaching the sandbox.

Status: the eval floor is fixed+committed; the notify.h wall + mega-SCC are fixed+committed; libc
green. `main` stays green on the default (eval-time) path and `cider-{group-test3,libsystem-group}
-bt`; `libSystem-group-bt` is green on the build-time path too (re-verified). `full-group-bt` green
through libc; the dominant remaining blocker is WALL #1 (root-separation). The generic `nix-ninja`
lib is upstreamable to overby.me (sibling to its buck2/cargo libs; rust-ninja extractor already
lives there) -- root-separation is the main pre-upstream item.

## #66 in detail (2026-08-11)

READ THE ADDENDUM AT THE END OF THIS SECTION FIRST if you want current state. What follows
below it was written earlier the same day and its counts are of that moment: the property count
in particular has moved from six to eleven, and the sentence saying so is left as written
rather than edited, because this file is a record of what was known when.

Moved out of PLAN.md to keep it short. This is the working record: what was measured, what
turned out false, and the traps that cost time.

### #66 — get the lowering out of the evaluator

A general buck2-graph to dynamic-derivation bridge, worth having for OTHER projects.
GENERALITY IS THE REQUIREMENT; cider is the first consumer, not the target. Nothing in the
reusable half may mention pins, the SDK farm, cider staging or this repo's layout.

- **A. THE BRIDGE, done.** `nix/lib/dyn-actions.nix` turns action specs into one emitted
  `.drv` per action plus `builtins.outputOf` accessors. THE CONSTRAINT THAT SHAPES IT: a
  `.drv`-named derivation must be text-hashed CA with a single output named `out`, and
  `builtins.placeholder "out"` is a constant of the OUTPUT NAME, so every emitted action must
  name its output something else or the producer rejects its own drv as a self-reference.
  `NIX_REMOTE=daemon` breaks recursive-nix, which supplies its own socket.
  `scripts/buck-dyndrv-check.nu` asserts **six** properties over four fixtures
  (`dyn-drv-probe`, `dyn-actions-toy`, `-dep-probe`, `-specdir-toy`, `-dag-toy`). Two of the
  six were FALSE when first checked and neither had a fixture, so neither could have been
  noticed: the DAG edge (`inputSrcs` went to `nix derivation add` as a full store path, which
  it rejects, so no declared source had ever worked) and the whole of `specDir` mode (nothing
  had ever produced a spec directory, so half the API was evaluated and never built).
  An action may declare `deps = [names]`; each becomes a source AND a `DYN_DEP_<name>` env
  entry, so a spec read from a FILE can find its dependencies without interpolating anything.
  Use `depVar` to name the variable: action names are free-form, shell variable names are not,
  and the mismatch expands to EMPTY rather than failing. Likewise `"$${x}"` is a Nix escape
  for a literal `${` -- concatenate instead. Both bugs produced clean successful builds with
  empty results, so fixtures must check CONTENT, never path existence.
- **B. THE ADAPTER, done.** `scripts/buck-graph-to-specs.py` groups the actions the way the
  lowering does and renders each group's command sequence, inside the graph derivation.
  `ciderBuck2Lower.nix` reads the result; `escArgCache`, `escArg`, `fill`, `ownOutputs` and
  `readsSibling` are gone from it. Checked by `scripts/buck-specs-check.nu`, which
  re-derives the answer from graph.json instead of asking the generator, with four negative
  controls that must fire.
- **WHAT IT WAS WORTH, measured old against new on the same tree and graph:** 15.1s → 14.5s,
  against a 12.95s floor if the scripts cost nothing at all. So 0.6s, not the ~12s first
  claimed. The ~12.95s that remains is computing 1,474 DERIVATIONS, and that is what A is
  for. Kept for what it enables, not for the 0.6s.
- **GATE16 GREEN, which is the verification the wiring owed.** 1,463 builders, zero
  nix-level failures, 2,874s, and the prefix is **byte identical to gate15 across all 5,563
  regular files**. Zero differ, which was the stated expectation: the wiring changes where
  the action script is computed, not what it says.
  IDENTIFY THE REFERENCE BY CONTENT, never by picking the newest directory: store paths carry
  epoch mtimes and seven prefixes sit in the store with identical file SETS. gate16 differs
  from `hnsbi7v08ypk` in exactly `.prefix-manifest.tsv`, `bin/ciderd`, `usr/lib/dyld` and
  `libsystem_kernel.dylib`, the recorded four-file gate15-against-pre-stage-2 signature, which
  is what identifies `pzc39fn070qj` as gate15's.
  TWO TRAPS, both of which look like failure and are not: `grep -ci 'error:'` on the log
  returns 221 and every one is an Objective-C selector (`error:(NSError **)error`) or warning
  text, so count nix-level failures instead; and this endpoint spends about **17 minutes**
  between launch and its first `building` line, with zero children and a near-idle daemon,
  which is the CA resolution pass and is indistinguishable from a hang while it runs.
- **THE ENDGAME COSTS ABOUT 55s OF BUILD, so it is worth building.** Every emitted action
  needs a producer derivation running `nix derivation add` in a recursive-nix sandbox, and
  `nix/lib/dyn-actions-scale-toy.nix` prices it: quiet, 22 cores, n=64/128/256 gives 0.039 and
  0.036s per producer, so ~55s at 1,474 groups against the ~12.95s of evaluation removed. Paid
  once per graph change, not per invocation, so it breaks even after four or five evaluations.
  THE FIRST MEASUREMENT SAID 0.57s AND 14 MINUTES and argued the opposite. It was taken beside
  a running gate with every core busy, so the producers could not overlap and it priced
  contention; it came out convincingly LINEAR, which is what made it credible. The tell was in
  the data before the re-run: n=4 measured slower than n=16, which only happens if they were
  overlapping. **Never price a parallel thing on a busy machine.**
- **specDir PLUS A DAG WORKS, which was the last gap in A.** `actions` mode could always
  express a DAG because the caller is writing Nix; `specDir` could not, since the spec is a
  file nobody parses. Edges travel in a `deps.json` beside the specs; the bridge puts each
  dependency's `outputOf` string in the PRODUCER's env and `dyn-actions-spec-fixup.py` writes
  it into the spec as a source AND a `DYN_DEP_<name>` entry once Nix has substituted the real
  path. Stripping `deps.json` degrades to a SET **silently, exit zero**, so fixtures check
  content. A silent failure this uncovered: the fixup was an inline `python3 -c` with no error
  check, and in specDir mode the spec is `cp`d from the store at mode 444, so it died with
  PermissionError, the shell carried on, and `derivation add` read the unfixed spec.
- **B HAS STARTED: the adapter emits the edges.** 1,474 groups, 925 with dependencies, 22,473
  edges, biggest fan-in 128, **no cycle** -- also the first group-level confirmation that the
  coarse-pin contraction held, since the dump only ever ran Tarjan at pin level. The generator
  refuses to emit a cycle. `buck-specs-check.py` checks `deps.json` against the graph AND
  against buck2's action ORDER, which is an independent property; seven controls, all firing.
- **EARLY CUTOFF MEASURED ON A REAL CHANGE.** Adding `deps.json` moved the specs store path and
  **zero** target derivations rebuilt; `cider-buck2-one` is at the identical out path. That is
  the embed-not-source decision paying off: had the lowering sourced the script from
  `graph.specs`, all 1,474 would have re-run.
- **STILL OPEN, and A and B DO NOT YET MEET.** Tested 2026-08-11: `nix derivation add`
  rejects the adapter's `<name>.json` with "Expected JSON object to contain key 'name'".
  `specDir` mode wants a DERIVATION; the adapter writes the action data a derivation would be
  built from. The conversion needs the consumer's store paths (builder, staged tree,
  toolchain), which neither the graph derivation nor the generator has, so it is a third
  derivation's job. After that, the endpoint binds through `outputOf` and the evaluator stops
  computing 1,474 derivations, which is where the ~12.95s actually is.
- **The readFile trap, because it cost a wrong turn:** reading the 1,474 rendered scripts as
  separate files makes evaluation 32.6s, WORSE than computing them. The specs output is
  deferred (the graph it reads is CA), so its real path is unknown until realised and every
  `readFile` resolves that again, ~13ms each; the same files from a plain store path are
  0.10s total. Hoisting the path does not help (it hoists the placeholder, and fails in pure
  mode); input-addressing the specs derivation does not help (the deferral comes from its
  input). One `scripts.json` read once is the fix.

### The edge set was checked against the REALISED derivation graph (2026-08-11)

deps.json is derived from graph.json, so comparing it back to graph.json would only prove the
generator ran. The independent evidence is the drv graph the LOWERING already builds, which
comes from Nix rather than from the adapter.

Taking the biggest group, root//buck-src/libc:system_c_final, and reading its drv references
straight out of the gate16 log so it is provably the current graph rather than a store-wide
glob mixing two:

    my deps                 128 groups, 128 distinct drv names
    drv target references   129
    only in the drv           1   x86_64-apple-darwin20-ld
    only in mine              0

THAT CONCLUSION WAS WRONG AND IS CORRECTED BELOW. What was written here first: the extra is
not a missing edge, because the artifact overlap is zero and no argv names ld64, so it must be
the nativeBuildInputs entry. Both observations were true and the conclusion did not follow.

IT WAS A MISSING EDGE. needsOf has TWO sources and the adapter reproduced one. Besides the
artifact rule it uses `declaredWithActions`, from each action's input_targets, and the
lowering's own comment says why: AN ACTION THAT READS ITS INPUTS FROM A FILE NAMES NONE OF
THEM IN ITS ARGV. So zero artifact overlap and zero argv mentions are exactly what a declared
edge looks like, and they were read as evidence against it.

THE OMISSION WAS NOT SMALL: 1,292 edges across 715 groups, and the prefix target alone was
missing 527 of them, since it passes one manifest argument standing for thousands of inputs.
The same comment records that mishandling this path is how the first coarse build died, an
hour in, on a cp that could not stat a .o.

With input_targets included the adapter matches needsOf exactly: 14 groups sampled from 527
deps down to 0, ZERO mismatches either way, system_c_final 129 against 129.

TWO HARNESS BUGS ON THE WAY, both of which made a correct map look broken:
  - the drv name is sanitizeDerivationName of the LAST COLON COMPONENT of the label, not
    anything recoverable by splitting the safe name on underscores. Comparing on the wrong tail
    reported 130 of 130 mismatching.
  - a CA derivation has two forms in the log, and the RESOLVED one has no drv references at
    all, because resolution replaces input drvs with their content-addressed outputs. Reading
    that one reports zero references and looks like a total mismatch.

### Where the endpoint's remaining evaluation actually goes (2026-08-11)

#66 removed the action-script rendering from the evaluator, worth 0.6 s. The obvious next move
was to emit the WHOLE builderScript from the generator. Measured first, and the measurement
says that would be a poor trade.

Endpoint evaluation, `nix eval .#cider-buck2-prefix-min.drvPath`, three runs each, warm:

    baseline                      14.85  15.08  15.05
    staging reference removed     11.89   9.17   9.37   (first is cold after the edit)

SO THE STAGING DERIVATIONS ARE ABOUT 5.7 s OF ~15 s, roughly 38 percent, and they are the
largest single remaining chunk. Emitting the builderScript from the generator does NOT remove
them: `stageProjectFor label` builds a Nix DERIVATION per group, and the script text is only
one line of the builder that names its store path and executes it.

THE REDUNDANCY IS THE INTERESTING PART. gate16 built 65 buck2-stage-project-grouped
derivations, so 1,474 labels produce 65 distinct scripts. stageGroupsFor keys on the label's
source GROUPS and shallow list, both small sets, so labels sharing those share the script
entirely. Computing it per label is about 22x redundant.

WHAT THAT MEANS FOR #66. The remaining eval cost is not mostly script assembly, so porting the
builder text to the generator is worth less than it looks. Memoising the staging derivation on
(groups, shallow) is a smaller change aimed at a bigger number, and it is independent of the
dynamic-derivation work.

THE RISK IF IT IS DONE. A memo key that misses something the script depends on makes two groups
SHARE a script that should differ, which is wrong staging: it does not fail at eval, it fails
much later as a missing file in somebody else's compile. The check is to compare the per-label
stage script store path before and after and require every one to be unchanged, not to run the
ladder and see green.

### The staging cost, start to finish (2026-08-11)

Four probes, each three warm runs of `nix eval .#cider-buck2-prefix-min.drvPath`. The first two
were taken on a quiet box, the last two at load ~3.5, so compare WITHIN a pair and not across.

    quiet:  baseline                              15.0 s
            staging reference removed              9.3 s     staging = ~5.7 s, 38 pct
            staging DERIVATION memoised           14.6 s     the derivation was 0.4 s

    loaded: derivation memo only            13.08 13.72 14.95
            + staging TEXT memoised         11.87 12.03 11.83   ~1.3 to 2.0 s
            + staging bypassed ENTIRELY     11.80 11.44 (15.11 cold)

SO THE REMAINING STAGING COST IS ABOUT 0.3 s, from 5.7. Bypassing it completely now buys
almost nothing, which is the only fair way to say the work is done rather than quoting a
before-and-after taken at two different loads.

WHERE IT WENT, and this is the part worth keeping. Building the DERIVATION was never the cost
(0.4 s). Computing the group and shallow LISTS is not either (~0.3 s, what is left). The cost
was FORMATTING those lists into shell, because the per-group body carries a thirty-line comment
block and concatMapStrings ran it across every label's groups: 1,474 labels producing 94
distinct strings.

THE FIX IS A SPLIT, NOT A CACHE. stageGroupsDataFor stays per label, because members, the group
union and its pathExists probes genuinely depend on it. stageGroupsTextOf is a function of that
data alone, and every term in it is a pure function of an element of one of the two lists, so
two labels with equal data produce byte-identical text and the memo cannot share wrongly.

AND THE ONE THAT DID NOT WORK, which is why the check matters. Hoisting the label-INDEPENDENT
tail (the rust vendor loop, pinStageLines across 148 pins) out of the per-label text moved ALL
1,474 staging scripts: a nested indented string gets its own common-indent stripping, so the
text differed by whitespace alone. Same 94 distinct scripts, every path different, every target
would rebuild. A green ladder saw nothing wrong with it.



### #66 addendum, later on 2026-08-11: the generator, and four things measurement corrected

**THE LOWERING NO LONGER ASSEMBLES A BUILDER SCRIPT.** `scripts/buck_lowering.py` renders it and
`buck-graph-to-specs.py` writes `full.json`, `needs.json` and a `dyn/` directory of bridge-shaped
specs, all inside the graph derivation. The lowering reads them and supplies the five values only
a consumer can know. All 1,474 labels unchanged, endpoint drvPath identical, rung 2 zero builders.

**A AND B ARE CONNECTED.** `.#cider-buck2-dyn-gen` builds real cider cones from those specs with
nothing serialised in the evaluator, `diff -r` clean against the lowered derivation. Cones run to
ciderd, 51 groups and 146 actions. All 1,474 producers instantiate in about 13 s.

**FOUR THINGS THAT WERE WRONG UNTIL MEASURED.**

- `lib.escapeShellArg` DOES NOT ALWAYS QUOTE. It leaves a string alone when every character is in
  `[A-Za-z0-9,._+:@%/-]`, and the SLASH is in that class, so ordinary buck-out paths come through
  bare. A renderer that quoted them looked right and matched nothing.
- A NIX INDENTED STRING CONTRIBUTES ITS OWN NEWLINE after an interpolation. Two bytes out of
  5,662, in two places, and only a byte-for-byte comparison against a real script finds them.
- `CIDER_TREE_<i>` MUST COUNT SCRIPTS EMITTED, not position in `fromStaged`: an entry with no
  links emits nothing. 730 of 1,474 labels matched anyway, because a group whose staged entries
  all have links has the two numberings agree. A one-label check would have passed.
- `builtins.seq` FORCES A LIST TO WHNF AND NOT ITS ELEMENTS. A 5.2 s probe was read as the cost
  of the read-only path and was not one: the staging script, tree scripts and dependency paths
  were never evaluated. The honest interleaved figures are 12.0 s for the old assembly, 12.3 s
  for the template, and 10.6 s once `needs.json` removed `needsOf`.

**`replaceStrings` IS THE WRONG SHAPE AT THIS SIZE.** `full.json` first held finished text with
`"$VAR"` in it, which meant substituting by scanning every byte against every pattern: 77 MB
against up to 130 patterns took 28.0 s against the old 12.0 s. It is an alternating template now,
literal and variable by index parity, joined rather than scanned.

**A CHECK WENT CIRCULAR AND HAD TO BE UNPICKED.** `passthru.deps` now comes from `needs.json`,
which the python generator wrote, so comparing the python against it would have compared the
python against itself. `passthru.definitionNeeds` calls `needsOf` and the check reads that.
Proven by discriminating rather than by reading code: a generator planted to drop each group's
first dependency makes the lowering fail to evaluate outright, while the needs check passes
1,474 of 1,474 unmoved.

**AN ARGUMENT CAN BE TOO LONG TO PASS, AND 89 OF 1,474 ARE.** Linux caps ONE argv or env string
at MAX_ARG_STRLEN, 32 pages, 131,072 bytes. That is not ARG_MAX, the 2 MB total, which was never
reached. The largest action script here is 5,132,916 bytes and three exceed even the total. BOTH
halves of the bridge were broken and only one was obvious: the emitted action carried its script
as a `-c` argument, and the PRODUCER embedded the whole spec in its own command line through a
printf, so it died before the fixup ever ran. Specs go through a store file in both modes now,
and an over-long `-c` argument spills to one and becomes `. <path>`. Only a `-c` argument is
rewritten, because only there is the argument known to BE a shell script. THIS COULD NOT HAVE
BEEN FOUND ON TOYS: every other fixture script is a few kilobytes.

**GENERALITY IS ENFORCED NOW, NOT ASSERTED.** `scripts/buck-bridge-generality-check.py` requires
every path a reusable file names to resolve inside the reusable set, which is the condition for
copying that set into another repo. 13 files, 0 references leaving. The comments saying "nothing
cider-shaped in here" were never a check.
