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
green. `scripts/buck-escape-roots-check.nu` guards the class, and the suite calls it.

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

**A RUNG 3 BUILD CAN WEDGE, SO WATCH IT:** `scripts/buck-stall-watch.nu <log>`. The endpoint
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
`scripts/buck-pin-paths-check.nu` resolves all 8,332 paths we record INTO a pin;
`scripts/buck-labels-check.nu` resolves all 24,944 labels, `load()` files and symbols, and
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
- **B. THE ADAPTER, done.** `buck-graph-to-specs.py` groups the actions the way the
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

**THE LOWERING NO LONGER ASSEMBLES A BUILDER SCRIPT.** `buck_lowering.py` renders it and
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

**GENERALITY IS ENFORCED NOW, NOT ASSERTED.** `scripts/buck-bridge-generality-check.nu` requires
every path a reusable file names to resolve inside the reusable set, which is the condition for
copying that set into another repo. 13 files, 0 references leaving. The comments saying "nothing
cider-shaped in here" were never a check.


## #95 in detail (2026-08-11)

Moved out of PLAN.md to keep it short.

### #95 - migcom stamps the build time into every stub, so 110 groups never cache

FOUND BY #66's full-graph comparison, which is the only thing that has ever compared two
independent builds of the whole port. 1,364 of 1,474 groups came out identical and 110 differed;
every content difference was the same line:

    * stub generated Tue Aug 11 18:57:26 2026    against    13:19:33 the same day

Those are the wall-clock times the two routes RAN. It is NOT an emitted-route defect: the
lowering is non-reproducible here too, and two lowered builds at different times differ the same
way.

THE CAUSE IS ONE LINE OF UPSTREAM. `buck-src/bootstrap_cmds/migcom.tproj/mig.c:324`

    loc = time((time_t *)0);
    GenerationDate = ctime(&loc);

and `migcom.tproj/utils.c:67` prints it into every generated stub. migcom ignores
`SOURCE_DATE_EPOCH`, which is the standard reproducible-builds knob and is already exported by
stdenv.

WHY IT COSTS SOMETHING RATHER THAN BEING COSMETIC. Under content addressing, a mig group that
reruns for any reason produces new bytes even when nothing about its inputs changed in a way
that matters, so early cutoff cannot stop there and everything downstream of it rebuilds. That
is the property #50 and #55 were built to get.

WHICH COPY: I GOT THIS WRONG FIRST TIME and the check I flagged is what caught it. I recorded
that `buck-src/bootstrap_cmds` was a COMMITTED tree. It is not: `jj file list` reports ZERO
tracked files under it, and `buck-src/.gitignore` says outright that these are materialised
nix-pinned upstream sources, never committed. Editing it would be lost on the next
materialisation.

There is ONE manifest entry, `pins/bootstrap_cmds`, and `scripts/buck-src.nu` copies that same
pinned revision into `buck-src/<basename>`. So the pin feeds both locations, which is the
basename mechanism the pin notes warn about, working as intended here rather than colliding.

SO THE FIX IS A PATCH, not an edit: `patches/bootstrap_cmds/*.patch`. Both consumers apply it,
`nix/lib/cider-src.nix` and `scripts/buck-src.nu:198`, with `patch -p1` inside the tree.

THE FIX IS THE STANDARD ONE: take the epoch from the environment when it is set.

    loc = time((time_t *)0);
  becomes
    const char *sde = getenv("SOURCE_DATE_EPOCH");
    loc = sde ? (time_t) strtoll(sde, NULL, 10) : time((time_t *)0);

DONE AND VERIFIED ON THE ARTIFACT. `patches/bootstrap_cmds/0001-migcom-honour-source-date-epoch.patch`
applies cleanly, the patched file passes `cc -fsyntax-only`, `FORCE=1 scripts/buck-src.nu
pins/bootstrap_cmds` reports applying it, and a freshly built mig group now reads

    * stub generated Tue Jan  1 00:00:00 1980

which is `SOURCE_DATE_EPOCH` 315532800. Before, it read the wall clock.

GUARDED SO IT NEVER COSTS AN HOUR AGAIN. `scripts/buck-mig-epoch-check.nu` builds ONE mig group
and reads one line, and is in `buck-test.nu`. Its control runs FIRST and is the half that
matters: it asserts the `stub generated` line EXISTS before asserting what it says, because a
migcom that stopped emitting the line, or a renamed output, would otherwise make the date
assertion vacuously true.

STILL OPEN: whether the full-graph diff now goes from 110 differing groups to 0. That run is
the confirmation and is hour class.



## What the migcom patch did and did not move (2026-08-11)

A correction, and the mechanism behind it is worth keeping.

I recorded that patching migcom moved the graph, and that the python ports were therefore
re-checked against a NEW one. Neither is true. `graph.json` stayed at `mv46f3p6` and the specs
at `qxrxrsic`, the same store paths as before the patch.

**graph.json records the ACTIONS, not their outputs.** It is command lines and declared inputs.
Patching migcom changes what the mig actions PRODUCE, not what they ARE, so the dump comes out
byte identical and content addressing collapses it to the same path. Everything derived from it
is unchanged with it: the specs, `full.json`, `needs.json` and the `dyn/` spec directory.

**What moved is `cider-buck2-sources`,** which contains `buck-src` and therefore the patched
migcom source. Every lowered derivation stages that source, and every emitted action receives
the staging script through `CIDER_STAGE`, so both routes rebuilt from there.

So the rebuild was real and necessary, but its cause was the source tree rather than the graph,
and a re-run of the port checks after it compares against the same graph as before.

## The stage 1 and stage 2 queue, moved out of PLAN.md 2026-08-12

MOVED RATHER THAN DELETED, and it is 634 lines, which was 45 percent of PLAN.md. Every
numbered item in it is a finished task: the stock switch and the GUI frameworks (#18 to
#22), the nine unported cli edges (#21), the host tools (#8), the NixOS VM (#10, #12), the
daemon growth traps (#48), the relative escape findings (#74, #79, now guarded by
buck-escape-check.py), and a getuuid analysis that ends by measuring that the compile it
worried about actually succeeds. Its own first entry opens with THIS ENTRY IS STALE.

Kept because the measurements in it are real and were expensive to take. Nothing here is
a live instruction.
### Near-term queue (stage 1, cli)

Re-derive before trusting: `scripts/buck-coverage.nu --missing` and
`scripts/gen-install-from-manifests.py`.

1. **The `all` component.** Sized and started; see "Stage 3" above.

   THIS ENTRY IS STALE and was written when three targets were left. What it said, and what
   is true now:

   - JavaScriptCore, recorded as HANGING buck2 with the daemon at 0% CPU. The hang was
     found and fixed, a cyclic symlink; the task list has it, and #23 then ran jsc on a
     script. NOT re-verified here, deliberately: the minimal endpoint's graph does not
     contain JavaScriptCore at all, so it is no evidence either way.
   - MachExceptions_xtrace_mig, recorded as not linking. IT LINKS. The current minimal
     graph carries `MachExceptions_xtrace_mig_obj` AND `_dylib`, counted out of graph.json.
   - the 9 dev-stub frameworks, recorded as hidden behind a basename collision. Ported, and
     the coverage metric was taught to see them.

   Start with the GUI framework dylibs: they are 362 of the 497 missing edges, and
   everything else in stock sits downstream of them. The 16 linux/native ELF wrappers are
   already done, see below; the rest are Darling's own framework implementations under
   darwin/frameworks (101) and darwin/private-frameworks (45), plus 314 in pins which is
   mostly python, ruby, perl and their extension modules.

   Stage 2 is effectively complete: 1354 of 1359 stock link edges. The five that remain
   (DBusKit, iokitd, bsdln, getuuid, elfdep) have their blocks removed and their causes
   written up above. The next item is THE STOCK SWITCH itself, which unlike everything
   else in stage 2 does change buck/prefix/BUCK, so it needs the runtime checks and the
   guest-nix milestone run rather than skipped.

   Beware NAME COLLISIONS when driving the generator by cmake target name across the wider
   graph. `X11` is both the linux/native wrap_elf stub and CoreGraphics' X11 backend in
   darwin/frameworks, and `gen-buck-from-ninja.py --dylibs X11` silently picks the latter.
   cli was small enough that names were unique; stock is not.

2. **The 9 genuinely unported in-scope cli edges**: bsdln, elfdep, getuuid (host tools),
   csparser.bundle, lzfse, ping, vifs, libbind9_isccc.a, libopendirectory_internal.a. None
   is installed by the cli component, which is why UNMAPPED is 0 without them.

2. **launchservicesd** (darwin/frameworks/CoreServices/src/LaunchServices/launchservicesd;
   launchservicesd.m and LSBundle.m; links Foundation CoreServices FMDB sqlite3 z).
3. **hdiutil** (buck-src/darling-dmg; wants fuse, a HOST library, so check how the reference
   supplies it before assuming this is portable).
4. **Make the generators re-runnable** before the reference graph goes away.
   gen-mig-from-ninja.py is the worst case: buck-split-pins.py has since rewritten its
   committed blocks' `defs` to labels and changed `out_base`, so regenerating would clobber
   them and the last fix had to be spliced in by hand.
5. The other four host tools (bsdln, elfdep, getuuid, wrapgen). Not install entries and not
   used by the port, so low priority.
6. Task #11 per-action source filtering; #10/#12 NixOS VM; #63 exec-cross-arch; #57 linker;
   #26/#39 nix-ninja.

---

## Harness traps (read before writing a check or blaming the port)

Every one of these presented as "the port is broken" when it was the harness. The rule that
falls out: when a script and an identical hand-run disagree, the SCRIPT is the suspect. That
has been true six times running, each time a check freshly written.

- **`llvm-nm`, never bare `nm`, for Mach-O.** Inside `nix develop` the bare name is the
  clang wrapper's binutils nm, which answers "file format not recognized" and, with stderr
  discarded, yields an empty symbol list indistinguishable from a library missing
  everything.
- **Capture, then match, in buck-test.nu.** Under the bash suite `cmd | grep -q` reported
  FAILURE on a MATCH (grep exits early, the writer takes SIGPIPE, pipefail propagates it);
  under nushell a non-zero external in a pipeline throws instead. Either way: collect the
  output once with `complete`, then test it.
- **What invalidates the Nix endpoint** (measured from two graph derivations, not
  assumed): the graph takes the staged project as one store path, and that path holds
  the BUILD tree only -- `buck/ src/ darwin/ linux/ tests/ etc/ misc/ patches/
  templates/ tools/ buck-src/ buck-rust/` plus the root dotfiles. (`cmake/` was in this
  list until #82 removed cmake; it no longer exists.) `scripts/`, `nix/`,
  `docs/`, `plan/`, `PLAN.md` and `flake.nix` are NOT in it, with three exceptions that
  are their own inputs: `buck2-graph-dump.py`, `buck-src-normalise.py`,
  and `nix/lib/ciderBuck2{Graph,Lower}.nix`, which ARE the derivations.
  `scripts/buck-endpoint-stale.nu` answers this in a second, and it now takes the rule from
  the two filters rather than from a listing of the result: both drop `tests/**/*.nix`, so
  editing the VM test is NEUTRAL (measured: the prefix derivation did not move, and
  `nix build .#cider-buck2` afterwards consumed the very store path the earlier build had
  produced), while `tests/buck2/**` holds real targets and is not.
- **Evaluating the endpoint: 155s to 58s, measured with the eval profiler.**
  `nix eval --raw .#cider-buck2-prefix.drvPath --eval-profiler flamegraph
  --eval-profile-file <f>` works in nix 2.34 and puts 57 percent of the self time in
  ciderBuck2Lower.nix. Three output-preserving fixes: the staged-tree script escaped the
  same destination TWICE per link (155 to 68), argv escaping now runs once per DISTINCT
  argument since 97.5 percent of 208,515 entries repeat (68 to 60), and staged link targets
  the same way at 45 percent repeats (60 to 58). Each one is safe because the prefix
  derivation does not move; that identity is the check.
  What is left: about 40 percent is still the staged-tree script, which emits two escaped
  shell lines per link. Removing that means emitting a table plus a loop, or having the
  dumper emit it, either of which CHANGES an input or the output and so costs a full
  endpoint rebuild to verify. `lib.unique` is 3 percent and order-sensitive here, so it
  stays.
- **58 seconds is not a regression from the 9 seconds of commit 45098ec. The graph grew.**
  That measurement was 1,115 staged trees; graph.json is now 1.62 GB holding 5,282 trees
  with 3,581,461 links, 27,591 actions and 3,225 targets. Per staged tree the evaluation
  costs 10.7k function calls and 3.9 MB today against 17k and 5.6 MB then, so the work per
  unit of graph went DOWN; the absolute number went up because the port did. Getting under
  10 seconds again at this scale is a structural change, not another micro-fix.
  Section sizes come out of graph.json in under a second, without parsing 1.62 GB, because
  the dump writes it with `indent=2` and `sort_keys=True`: `grep -bn '^  "[a-zA-Z]*":'`
  gives every top-level key with its byte and line offset, and the counts are then line
  arithmetic (`^    "` is an entry, `^      "` is a link).
- **THE NIX ENDPOINT BUILDS A WORKING DARLING, END TO END, FOR THE FIRST TIME.** 8,472
  derivations, zero builder failures. The prefix is 622 MB and 34,126 files with
  `bin/cider`, `bin/ciderd` and `bin/cider-coredump`, and
  `scripts/buck-bash-check.nu --prefix result/cider_prefix__prefix` PASSES: the container
  boots and prints `BUCK2_BASH_OK 3.2.57(1)-release x86_64-apple-darwin19`, which is the
  Darwin bash and not the host's 5.x. Wall time: 29m41s for the graph, then about four
  hours for the lowering, most of it two avoidable problems (#48, #52).
  THREE OPERATIONAL TRAPS, each of which cost a run:
  1. `nix-daemon` forks a worker per CONNECTION that grows 8-9 MB per derivation BUILT
     (11.1 GB at 1,171, 15.3 GB at 1,873, swap to 9.1 GB), which extrapolates past this
     machine's 30 GB and is why the endpoint had never finished. It is all returned on
     disconnect, so CYCLE THE CONNECTION: `timeout 900 nix build ...` in a retry loop, since
     nix resumes from the store. Capping `--max-jobs` does not help, the growth is per
     derivation processed.
  2. BUT A CYCLING WINDOW MUST EXCEED THE LONGEST SINGLE DERIVATION or it livelocks. The 15
     minute window killed `JavaScriptCore_obj` (54 minutes on its own) and restarted it from
     zero, twice, before this was spotted. Drop the timeout for the last few derivations.
  3. The harness KILLS BACKGROUND JOBS THAT GO SILENT. Two runs died that way, one piped
     through `tail` (which buffers to exit, leaving a ZERO BYTE log and nothing to diagnose)
     and one compiling JSC quietly. Run with `-L` AND a heartbeat, and never through `tail`.
- **THE ROOT INVALIDATION CAUSE IS THE GRAPH DERIVATION ITSELF (#56), and #50, #53, #54 and
  #55 are all downstream of it.** `ciderBuck2Graph.nix` takes the project as ONE
  `builtins.path` that excludes only plan, docs, nix, scripts and a few dotfiles, so
  `darwin/`, `pins/`, `linux/` and `buck-src/` are all in it. Edit one C file and the graph
  rebuilds (30-47 min of buck2 analysis), its drv moves, and every lowered derivation moves
  with it, because each binds to the graph's DERIVATION rather than to its output. No amount
  of per-target or per-group granularity can matter beneath that. The comment on that filter
  already said so: keying the graph on the build DEFINITION rather than on file contents is
  the next step. The fix is to split ANALYSIS (BUCK, .bzl, configs, plus a NAME manifest of
  the sources) from MATERIALISATION (real sources, producing staged/ and treelinks/).
  WHAT THIS COSTS IN HINDSIGHT: four mechanisms were built and flagged off before anyone
  measured a one-file-edit rebuild. Measure that FIRST next time; it is the only number the
  work is for.
- **DONE (#53): a buck-src PIN can be lowered as ONE derivation, and the merge is
  byte-identical.** The dump decides WHICH pins, because contracting a DAG can create
  cycles and this graph has them: 43 of 157 pins form one strongly connected component over
  the system cone (Libinfo, cctools, corefoundation), mutually dependent at target level
  though the target graph is acyclic; `coarse_pin_map` runs Tarjan and offers only the 114
  that are clean, covering 1,310 of 3,225 targets. `groupOfLabel` is then a lookup.
  Verified on a real merged pin rather than a full rebuild: `pin-JavaScriptCore` merges five
  targets and its 1,091 files contain all 1,082 of `JavaScriptCore_obj` with ZERO checksum
  differences, the extra nine being exactly the other four targets' objects. 23 minutes.
  STILL OFF BY DEFAULT. Flipping `coarsePins` is a separate decision and wants the full
  coarse prefix built and diffed first; the expected win is ~1,196 fewer derivations and 31
  percent fewer staging passes, NOT less compile work.
- **#44: the narrowing gap was 25 quoted includes, and depfiles were not needed to close it.**
  HISTORICAL as of 2026-08-09: `narrowSources` is deleted, so this gap no longer gates
  anything. The comment it argued with said only depfiles could answer this case, and that
  narrowing waited on a 90 minute build. Both were wrong; it measured on the host in ten
  seconds, which is the transferable part.
  I FIRST REPORTED FIVE, and that was too narrow: I scanned only includes spelled `../`
  and missed the subdirectory form, which is the same problem (`libcxxabi` reaching for
  `include/atomic_support.h` and `demangle/ItaniumDemangle.h`, `fseventsd.m` for
  `linux/fanotify.h`). The closure in the dump always covered both; only the count was
  wrong. `buck-include-closure-check` now measures it properly and is verified
  both ways: 25 against a pre-closure graph, 0 after.
  The narrowing that matters: of 64,903 C-family files, 734 have a quoted `../` include and
  93 are uncovered, but 40 name a file that does not exist (guarded out) and 48 of the
  remaining 53 are vim GUI files this port never compiles (`gui_x11.c`, `gui_motif.c`,
  `gui_gtk.c` have ZERO compile actions, against 1 for `YarrPattern.cpp`). Never judge a
  gap by its raw count; judge it by what is actually compiled.
  #49 is answered too, and the answer is DO NOTHING:
  dropping `indent=2` saves ~0.4s of parse and destroys the `grep -bn` section-offset trick
  used repeatedly to measure this graph, and interning `target-sources.json` only matters
  once narrowing is on, so it belongs with #44.
- **`nix-diff <old.drv> <new.drv>` answers "why did this rebuild", and it is already
  installed.** It walks the derivation tree and names the first real difference, which for a
  content-addressed dependency is the thing that is otherwise hard to see: a consumer binds
  to the producing DERIVATION, not to its output path, so it prints
  `The input derivation named cider-buck2-graph.drv differs` and then `Sources: - old
  buck2-graph-dump.py + new`. That is the whole #55 cascade in one command. It beats
  decoding the `text` env var out of a `.drv` by hand, which is how this was first found.
  Pair the SAME artifact across the two revisions, not two different variants: comparing the
  default prefix against the coarse one just reports pin merging and tells you nothing.
- **VERIFY ON ONE DERIVATION, NOT ON A FULL PREFIX REBUILD.** #50 was proven on
  `.#cider-buck2-lowered` in minutes and #52 on a single target in 10 minutes, both by
  diffing a sorted file list plus per-file sha256 against a known-good output. Queueing #53
  behind a 3 hour rebuild of all ~8,400 derivations tested nothing that
  `nix build /nix/store/<hash>.drv^out` would not have caught, and blocked every other
  increment while it ran. Reach for a whole-endpoint build only to produce the deliverable,
  or when the change really does touch every derivation, and say which it is.
  Two related traps: a CONTENT ADDRESSED drv holds a deferred placeholder, so grepping a
  `.drv` for a store path finds nothing and the derivation has to come from the closure;
  and for the same reason the check is whether nix RERUNS THE BUILDER, not whether a
  drvPath moved.
- **#55 DONE. #54 IS NOT, AND EVERY SHORTCUT TO IT IS NOW CLOSED BY MEASUREMENT.** The goal is
  reachable: with `sourceGroups` on, editing `ACAccount.m` and rebuilding
  `libsimple_ciderd` ran **0 builders**, against 323 with neither flag. What fails is
  every available way of getting there.
  **Splitting the source into per-subtree stores cannot work for this tree.** A group is staged
  as one symlink to its own store path, and **2,306 of the 2,970 symlinks under `darwin`, `src`
  and `linux` are relative and cross a group boundary** (15 groups; `darwin/Developer/Platforms`
  2,189, `frameworks/SystemConfiguration` 52, `darwin/opendirectory_internal/include` 24). The
  endpoint failed 1,194 targets on `CoreServices/MacTypes.h`, which is itself a link to
  `../../../../basic-headers/MacTypes.h`. Two fixes were tried and both fail:
  1. A LINK FARM CANNOT REPAIR A RELATIVE ESCAPE. The kernel resolves `..` against the REAL
     parent once it crosses the farm symlink, so
     `readlink -f <farm>/src/external/IOKitUser/darling/submodules/xnu` gives `/nix/store/xnu`
     while `<farm>/src/external/xnu` exists and is never consulted.
  2. REWRITING ESCAPES TO ABSOLUTE PATHS RELOCATES THE PROBLEM, since the destination store has
     escapes of its own: for the pins it took 143 dangling links to **413**. The SDK
     `usr/include` extracted alone is **1,987 dangling of 1,987 symlinks**, against 0 of 2,928
     inside the assembled tree. It is nothing but relative links into the rest of the project.
  **Neither flag cut it either.** `sourceGroups` has the right granularity and the wrong
  mechanism; `narrowSources`, deleted since, was the reverse, because `projectSrc` was ONE
  union shared by every target (probed: the compile RAN). And their combination was closed at
  evaluation time: one
  `builtins.path` union costs **~4 seconds**, so 3,225 of them is **3.6 hours of eval**.
  **What is left untried** is the same idea at BUILD time: one CONTENT-ADDRESSED SUBSET
  DERIVATION PER TARGET, cut from the shared `projectSrc` and reproducing the project layout.
  One root so the web resolves, one shared input so the daemon does not blow up (147 distinct
  paths per staging script is what took it to 4.9 GB and stalled it), and an output addressed
  by the subset so an unchanged target collapses to the same path.
  `scripts/buck-escape-check.nu` is what measures all of this: `groups`, `pins --root
  <assembled>`, `resolve <dir>`, and it refuses to pass when it walked no symlinks.
  **THE LAYOUT THAT SUBSET DERIVATION HAS TO REPRODUCE IS NOW KNOWN, and it is cheaper than a
  copy: REAL DIRECTORIES PLUS ONE SYMLINK PER FILE.** What broke the link farm was that a GROUP
  was staged as one symlink to a DIRECTORY, so `..` left the tree. Per FILE it does not: the
  containing directory is real and inside our own tree. Tested with clang on a scratch tree,
  both cases that matter and a negative control that really fails:
  `#include "../d.h"` through a per-file link **exit 0**; a staged source that is ITSELF a
  relative symlink **exit 0**; the same include with the destination NOT staged **exit 1**.
  The rule that makes it hold is the one the closure already applies: when a staged path is a
  symlink, stage its DESTINATION too.
  **AND IT HOLDS AGAINST REAL READ-ONLY STORE PATHS**, which the scratch test did not cover:
  the two groups realised with `builtins.path` (mode 444, `dr-xr-xr-x`), staged by the exact
  shell `stageGroupsFor` now emits. 0 staging errors, `MacTypes.h` resolves, 147 symlinks and
  28 real directories, and the store source is unmodified afterwards. The only 2 dangling links
  point at `src/external/...`, which this partial stage deliberately did not plant, because
  pins arrive from the `wantedPins` section rather than from a group.
  **AND THE SDK INVERTS THE WHOLE IDEA FOR A COMPILING TARGET, measured.** Every darwin compile
  needs `darwin/Developer/Platforms`, and that tree is a HUB: 2,633 symlinks reaching TWELVE
  roots (1,898 `src/external`, 444 `darwin/Developer`, 118 `darwin/frameworks`, 57
  `darwin/private-frameworks`, 34 `build/src`, 23 `darwin/basic-headers`, then `darwin/launchd`,
  `darwin/libm`, `darwin/sandbox`, `darwin/CoreAudio`, `darwin/libacm`,
  `darwin/libDiagnosticMessagesClient`). Counted as GROUPS:

  | | |
  |---|---|
  | distinct groups referenced by all 2,339 targets combined | **90** |
  | groups the SDK alone links into | **255** |
  | median groups per target | 24 |

  **CORRECTION, and the conclusion I first drew from those numbers was WRONG.** A compile does
  not read the SDK at its project path at all. Every one of the 58 include roots of
  `SecItemShimOSX_obj` is a `buck-out` STAGED FARM, the SDK among them as
  `.../__sdk_repo_include__/...`, and the lowering stages farms by their own mechanism. So the
  255 counts links INSIDE a tree that is reached through a farm, and staging the SDK as groups,
  or as one pre-assembled artifact, addresses neither. I built that artifact, it was correct
  (it carried the destinations and its internal links resolved), and the target failed exactly
  as before. Removed.

  **THE REAL RULE IS ONE LINE: A STAGED FARM'S LINK DESTINATIONS MUST BE STAGED, TRANSITIVELY.**
  The closure records hop one (the farm's link target). It misses the hops after it, and this
  tree is full of them: `usr/include/os/log_private.h` is a link to
  `src/external/libtrace/...`, and `usr/include/IOKit` is a link to
  `../../System/Library/Frameworks/IOKit.framework/Headers` which does not resolve in the repo
  at all. Every remaining grouped-staging failure has been an instance of this, so the fix is
  the transitive closure and not another destination.

  **THE CLOSURE'S ONE SILENT FAILURE MODE IS MEASURABLY ABSENT HERE (#69).** The per-target file
  list is inferred, and the way that could be wrong WITHOUT a build error is an `#include`
  the regex cannot resolve, i.e. one assembled from a macro. Counted:

  | | files | non-literal `#include` |
  |---|---|---|
  | first-party (`darwin`, `src`, `linux`) | 26,884 | **0** |
  | pins (`buck-src`) | 81,835 | 424 (0.52%) |

  The pin ones cannot bite, because pins are staged WHOLESALE: `pinsTree` carries each pin in
  full, so a macro include inside one always resolves. The inferred list only gates FIRST-PARTY
  groups, and there the count is zero. The regex also over-approximates by ignoring `#if`, which
  is the safe direction. So #69 is about genericity and deleting a pass, NOT about correctness
  risk, and the "silent wrong output" framing was wrong.

  **#54 IS DONE. THE GROUPED ENDPOINT IS BYTE IDENTICAL AND THE CASCADE IS CUT.**

  | | |
  |---|---|
  | `.#cider-buck2-prefix-min-grouped` | 1,617 builders, 0 root failures, 70 min |
  | content hash | `sha256-hkJQ0xJVx6tDzrBt2bsISkYDCvJtNXsQ08NTwxk9ADQ=`, the recorded one |
  | probe: unrelated `.m` edit, `SecItemShimOSX_obj` | **2 builders**, target NOT rebuilt, output path IDENTICAL |

  The probe target is the one that reads through a nested submodule and exposed the per-pin
  store regression, so it is a check that can fail. The two builders that do run are
  `cider-buck2-skeleton` and `cider-buck2-sources`, the graph-side content passes.
  What made it work, after `sourceGroups` had the right granularity and the wrong mechanism for
  months: MIRRORING instead of directory links (groups AND pins), and `pinsTree`, one CA tree of
  all 147 pins whose escape destinations come from their own store paths rather than from the
  project.
  Root failures on the way down, each from a real run: **90** (coarse pins had no group entry)
  to **9** (non-pin `src/external`) to **1** (a `script_gen` needs those too, not just compiles)
  to **0**.

  **AND POINTING pinPath AT THE PER-PIN STORES BROKE THE DEFAULT ENDPOINT. Reverted (#74).**
  Seven pins carry nested submodules, and the per-pin store does not have their content, so the
  pin's own link `darling/include/IOKit/IOReturn.h ->
  ../../../darling/submodules/xnu/iokit/IOKit/IOReturn.h` dangles INSIDE the store.
  `stageProject` uses `pinPath` too, so this was not confined to grouped staging:
  `SecItemShimOSX_obj` failed on `prefix-min`, an endpoint that had built green with a matching
  prefix hash. The revert rebuilt **0 builders**, i.e. it resolved to the cached pre-regression
  output.
  Not pinStore's fault, and not the fetch's either: `src/external/IOKitUser/darling/submodules/
  xnu` IS ITSELF A SYMLINK, to `../../../xnu/`, which resolves to a SIBLING PIN. The "1 entry"
  was that link. In the assembled tree it resolves (23 entries); planted as
  `ln -s <pinStore> src/external/IOKitUser` the kernel takes `../../../xnu` against the STORE,
  so it dangles. THE SAME MECHANISM as the group-directory link that failed 1,194 targets on
  `MacTypes.h`. `scripts/buck-escape-check.nu` documents this exact case, naming this exact
  file, and I walked into it anyway.
  **So the fix is the session's own result applied to pins: ONE CA `pinsTree` holding all 147
  pins MIRRORED (real directories, one link per file) at their `pins/<name>` paths.**
  Self contained, so a sibling escape resolves inside it; input is the frozen pins, so it moves
  only on a pin bump, which is the cascade cut per-pin `pinPath` was reaching for.
  `scripts/buck-pin-store-check.nu` passes throughout, because it compares by NAR HASH and a NAR
  hash records a symlink TARGET as a STRING. `buck-escape-check.py` documents that exact trap,
  for this exact class of bug, and the pin check still uses the method it warns against.

  **THE PIN PATH WAS THE LAST SHARED INPUT, not the groups.** `pinPath` was
  `"${ciderSrc}/${p}"` and `ciderSrc` is the whole project, so every staging script that
  named a pin moved on any edit. Taking pins from `ciderSrc.pinPaths` instead, which the
  GRAPH has done since the per-pin split, is what finally cut it: on one target, an unrelated
  `.m` edit went from 6 builders to **2**, neither of them the target, and the target's output
  is the SAME store path either side of the edit.
- **#54 MEASURED, and per-target granularity is worth a lot: the median edit would rebuild 5
  targets instead of 2,339.** From `target-sources.json`: 2,339 targets, 74,621 distinct files,
  6,419,328 (target, file) pairs. Blast radius of editing ONE file, if each target depended
  only on what it reads:

  | percentile | targets invalidated |
  |---|---|
  | p25 | 2 |
  | **p50** | **5** |
  | p75 | 27 |
  | p90 | 78 |
  | p99 | 1,265 |
  | max | 1,267 |

  22 percent of files are read by exactly ONE target, 58 percent by ten or fewer, 94 percent by
  a hundred or fewer, and **no file is read by more than 1,267 targets**, so even the worst case
  is half the project rather than all of it. Today every edit rebuilds all 2,339.
  The cost side, same source: the median target reads 4,048 files (p90 5,640, max 13,726), so
  2,339 subsets is about 9.5 million entries. That rules out COPYING (tens of GB) and points at
  symlink farms, which work here for the reason group staging did not: every directory is real
  and only the leaves are links, so a relative link inside the subset resolves against the
  subset instead of escaping into another store path. Rough cost is derivation overhead, about
  2,339 builds, not the link creation.
- **#64: ld64 is content addressed, and narrowing its source is NOT possible as scoped.** The
  rebuild no longer propagates (its outputs from a clean tree and from an edited one are bit
  identical), but it still costs 26 to 28 minutes on any first-party edit. The plan was to drop
  `darwin/frameworks` and `darwin/private-frameworks` on the premise that the linker compiles
  nothing in them. **That premise is false**, and two fast experiments show it:
  deleting the trees fails at cmake GENERATE, not on dangling SDK symlinks but on
  `add_dependencies(QuartzCore CoreVideo)` in `src/external/cocotron` reaching a target defined
  under `darwin/frameworks`; and blanking only the implementation files gets past configure and
  then fails at LINK, because CFNetwork needs `_SCNetworkReachabilitySetCallback` and friends
  that `darwin/frameworks/SystemConfiguration` defines.
  One measurement explains both: **this ld64 derivation compiles across 369 distinct
  directories**. It is most of Darling, not a cctools build, which is also why it takes half an
  hour. Reducing it means changing WHAT it depends on in cmake, not which files reach the
  derivation, and that work should start from the ninja graph (26,351 edges) rather than from
  guesses about directories. Both experiments are reverted.
- **#70 CORRECTS THE ABOVE: it was never a property of ld64, it was two wrong target names.**
  Taking #64's own advice and starting from the ninja graph, the transitive closure over
  inputs, implicit inputs and order-only inputs says:

  | target set | edges | compiles | dirs |
  |---|---|---|---|
  | `x86_64-apple-darwin20-ld` alone | 42 | **40** | 7 |
  | ld64 + everything `cctools-port/misc` offers | 82 | **62** | 9 |
  | bare `install_name_tool` | 3,510 | 3,113 | 197 |
  | bare `nmedit` | 3,510 | 3,113 | 197 |
  | **the four names `buildFlags` passed** | 3,515 | **3,114** | **197** |

  `cctools-port/cctools/misc` defines NO `install_name_tool` and NO `nmedit`, only `lipo`, so
  ninja resolved those bare names to the GUEST tools under `darwin/xcselect`. That is where libc
  (635 compiles), icu (446), xnu (415), compiler-rt (139), corefoundation (127) and Libinfo
  (106) came from, and it is the 369 directories.
  **AND THE RESULT WAS DISCARDED**, which is what made the fix safe rather than a trade-off:
  `installPhase` looked for them under `cctools-port/cctools/misc`, where those targets never
  wrote, so its `find` failed and the `note: not built` branch fired. Checked three ways that
  nothing consumed them: the lowering never names them, no action's argv invokes them, and the
  only actions mentioning them BUILD them (precisely the `darwin/xcselect` shims ninja resolved to).
  VERIFIED: dropping the two names reproduces
  `sha256-tHH+BndVNL2V8g9iM7++iD/aGY3Pz5AirmcwEqJSblc=` exactly and collapses onto an EXISTING
  store path, so no consumer moves. The oracle was confirmed live first: three separate ld64
  outputs in the store all carry that hash.
  **THE WALL-CLOCK SAVING IS NOT THE 50x THE COMPILE COUNTS SUGGEST.** It ran in 1,290s (21.5
  min) against a recorded 26 to 28, but it shared the machine with a 1,049-derivation endpoint
  build throughout, and the recorded baseline was taken under unknown load. The compile cut
  (3,114 to 62) is certain; the time saving is not cleanly attributed, because the whole-project
  cmake CONFIGURE that both pay is now the dominant term. A fair number needs an idle re-measure.
- **DONE (#68): one command, one evaluation, and a counter that self-tests.**
  `.#cider-buck2-one` is the endpoint's OWN derivation for `libsimple_ciderd`,
  reached through `cider-buck2-prefix-min` rather than lowered again, so it is the same drv
  the endpoint builds (both evaluate to `jahgjqzjq…`). `scripts/buck-quick-check.nu` builds it
  and counts builders that RAN, with a probe mode that edits, rebuilds, counts and reverts by
  stripping its own marker, so an interrupted run leaves something the next one can clean up.
  IT PROVES ITS COUNTER FIRST, by building a derivation carrying a fresh nonce that must
  report exactly 1; otherwise `ran=0` could mean the log format changed rather than nothing
  rebuilt. Verified both ways: a fresh build reads 1, a rerun reads 0.
  **The 12s evaluation is paid once per change to the FLAKE SOURCE TREE, not per build**:
  rerun unchanged 0.3s, rerun after editing `nix/` 12.3s with ran=0, first build 12.7s. So it
  bites only when iterating on the lowering itself, which is much less of the loop than the
  14.5s one-target figure suggested. #66 IS NOT AN EVAL SAVING HERE, measured rather than
  assumed: forcing 1,474 producer drvPaths against forcing the same 1,474 lowered outPaths
  runs 10.45 / 10.84 / 12.56 against 11.16 / 10.55 / 11.07 interleaved, which is a wash.
  builtins.outputOf needs the producer outPath, so binding through it instantiates one
  derivation per action exactly as the lowering does. What DID come out of the evaluator is
  the script: the lowering reads full.json and needs.json now and computes neither, 12.0 to
  10.6s, and that keeps whichever route wins. The earlier 0.6s figure was for moving the
  action scripts alone, which was a smaller and different change. That probe also
  confirms for the first time what the source filters promise: a `nix/` edit rebuilds nothing.
- **#69 MEASURED: the declaration gap is a PER-TARGET question, and it is 675 files.**
  `scripts/buck-declaration-gap.py` splits each target's source set into what buck2 SAYS (argv
  tokens, staged-tree link targets) and what the closure pass COMPENSATES for (include roots
  taken wholesale, quoted includes), and verifies that partition against
  `buck2-graph-sources.py` on all 2,339 targets. On the current graph, union 74,620 files:
  wholesale include roots are **2 directories, 25 files, 2 targets**; quoted includes are
  **675 files over 693 edges, reached by 1,266 targets**.
  THIS DOES NOT CONTRADICT the 5-then-0 of `buck-include-closure-check`, which asks whether
  the UNION misses a file entirely and only for `../` escapes. A header can be declared for
  one target through its staged tree and be quoted-only for another. Both stand.
  WHY THE PORT WORKS ANYWAY: `cc_objects` declares only `srcs`. `finger_obj` lists five `.c`
  files and no headers, while `lprint.c` includes `finger.h` from its own directory. Compiles
  run IN THE PROJECT TREE against project-relative paths, so that resolves only because every
  target is staged with the whole project. The missing declarations and the #54 cascade are
  one fact seen from two sides.
  THE MECHANICAL ROUTE beats hand-written globs: the reference `build.ninja` carries depfiles
  on **26,198 of 40,014 edges**, so one cmake build with its `.d` files kept states every
  header each object really read, angle-bracket includes included.
  `scripts/gen-buck-from-ninja.py` already generates these targets from that same ninja.
- **#65: the recorded ld64 blocker is WRONG, established by reading and costing no build.**
  `linux/buildtools/BUCK` says the compile dies in cctools' own `mach/machine.h` on
  `<mach/machine/vm_types.h>` and asks for `cctools/include/foreign` on the include path. Four
  facts say otherwise. `mach-o/loader.h` guards ALL its mach includes behind `#ifdef __APPLE__`
  and typedefs `cpu_type_t`, `cpu_subtype_t` and `vm_prot_t` itself in the `#else`, so a host
  compile never reaches `machine.h`, which is why the reference needs nothing, and its real
  `getuuid.c.o` command carries only `darwin/include`, `linux/buildtools/include` and
  `cctools/include`. `cctools/include/mach/machine.h` has NO `#include` lines, so it cannot be
  the file failing, while `foreign/mach/machine.h` includes `<mach/machine/vm_types.h>` at line
  64. `cc_header_root` stages by a plain prefix strip and `cctools_port_include` sets no
  `include_subdirs`, so `foreign/` cannot collide into the root. And `include/mach/` has no
  `vm_prot.h`, so a compile with `__APPLE__` defined would die on that first.
  **THEN MEASURED, and the compile the comment says fails SUCCEEDS.** Run clang directly, no
  buck2 and no Nix, against the same include root the BUCK targets already name:
  `clang -DDARLING -Ibuck-src/cctools-port/cctools/include -c linux/buildtools/getuuid.c` exits
  0, and so does `elfdep.c`. Verified it can fail: drop that one `-I` and it dies on
  `mach-o/loader.h` not found. `-H` says the headers opened are cctools' own `mach-o/loader.h`
  and `fat.h` and that **`mach/machine.h` is never opened at all**, and the host clang defines
  no `__APPLE__`, which is the guard doing its job. So no include path change is needed and
  `foreign` must NOT be added.
  The one remaining doubt was buck2's own staging, since globs do not traverse a symlinked
  directory (the recorded DBusKit trap) and `foreign/` contains one. **Bounded, and it does not
  matter here**: the whole root holds 331 real headers and exactly TWO symlinked directories,
  `foreign/arm` and `foreign/mach/arm`, both pointing at `i386`, together reaching 31 ARM
  headers that x86_64 never needs and that `foreign/` keeps off the include path anyway. The
  two headers these tools do need are real files. So nothing about staging blocks the host
  tools; running buck2 only confirms it.
  The stale comment stays put on purpose: it is a BUCK file, so correcting it alone costs ld64
  plus the graph. Fold it into the next batch.
- **DONE (#50): the graph derivation has two outputs and is content addressed, so a
  dump-format change no longer rebuilds the port.** `graph.json` and `target-sources.json`
  are read only by the EVALUATOR and stay in `out`; `staged/` and `treelinks/` are read only
  by the lowered BUILDERS and move to `data`. Recorded paths are relative, so the split is a
  move. Verified BOTH ways on `.#cider-buck2-lowered`: adding a key to graph.json rebuilt
  only the graph and left the target at the same output with no builder run, while writing
  one file into `treelinks/` moved the data path and did rebuild it; removing the probe
  returned to the identical baseline output.
  THE CHECK IS "DOES IT REBUILD", NOT "DID THE drvPath MOVE". A consumer of a content
  addressed output holds a DEFERRED reference carrying the producing drv, so its drvPath
  always moves and the old plan would have read a false negative. Nix resolves it after the
  dependency builds and reuses the output when the resolution is identical.
- **DONE (#52): a target's independent actions run concurrently. JavaScriptCore 54m to
  10m36s at only `--cores 8`, and the objects are IDENTICAL.** 1,082 files each way, zero
  difference in the file list and zero across all 1,082 sha256 sums, and the 10m36s even
  includes rebuilding the dependency chain that the serial baseline did not pay. The test
  needs no ordering pass: actions are in buck2 topological order, so an action reading none
  of its siblings' outputs cannot depend on anything already launched, which is one set
  membership. `_reap` checks every background job EXPLICITLY, because `set -e` does not
  catch a background failure and an unnoticed one is a target quietly missing an object.
  Bounded by `NIX_BUILD_CORES`, so pair `--cores` with `--max-jobs`: 6 jobs each allowed 22
  cores is 132 compiles. Evaluation is unaffected, 21.4s and 1.76 GB.
  VERIFIED AT FULL BLAST RADIUS, because it changed every builder: a complete rebuild of all
  3,199 target derivations (the 5,282 farms were untouched and reused) ran 4 cycles in
  1h48m with zero failures, and the resulting prefix is BYTE-IDENTICAL to the serial one --
  39,173 entries, no tree difference, no difference across all 34,126 checksums -- and still
  passes `buck-bash-check.nu`. What limits a rebuild is not compile parallelism but
  per-derivation STAGING, paid once per target derivation: concurrency oscillates 0 to 18
  with repeated stretches at zero. That is the argument for #53.
- **DONE (#51, #47): the endpoint evaluation is 22.4s and 2.49 GB, from 58.8s and 9.0 GB.**
  Allocation went 20.6 GB to 5.95 GB, calls 56.5M to 38.5M, and graph.json 1.62 GB to
  481 MB. Two changes, both moving work out of the evaluator: the dump writes the UNION of
  project sources instead of a per-target map that repeated it 85 times (the per-target
  breakdown now lives in target-sources.json, which only narrowing reads), and staged farm
  links travel as `treelinks/*.tsv` plus `*.dirs` tables that a fixed-size read loop
  consumes, so nothing in Nix is proportional to the 3,581,461 links. Together with the
  three escaping fixes earlier the same evaluation has gone 161s to 22.4s. The prefix
  derivation MOVED, by design, so the guard did not apply: verified instead by building
  `.#cider-buck2-lowered` and a real codegen target (dserver_rpc) out of the new graph,
  and by reading an emitted staging script. The diagnosis that led there is kept below.
- **How it was found, since the method transfers and the conclusions above do not.** The
  evaluation split into a PARSE (11.0s, 3.73 GB, `fromJSON` alone) and the LOWERING on top
  (48s, 5.3 GB), so both halves had to be attacked separately. The parse was large because
  the graph repeated itself 85 times, and the instructive part was WHICH branch caused it:
  the `-I` walk fires only 46 times over 3 directories, because 96.4 percent of the
  1,251,596 include roots already point into buck-out. The port therefore HAS the precision
  buck2 normally gives, a declared header farm per target, and the 85x was the dump
  FLATTENING those farms per consumer, recomputable from data already in the same file.
  Depfiles would have been a ninja-shaped answer to a buck2 question. Three source-tree
  include roots remain as rule bugs worth fixing on their own: `darwin/xtrace/include`
  (44 uses), `darwin/launchd/src`, `buck-src/security/OSX/libsecurityd/mig`.
- **IFD is not the problem. The 1.62 GB payload is. Do not bet on an experimental feature
  before fixing the representation.** recursive-nix works here, verified end to end: an
  inner derivation built from inside a build, INNER_OK read back out of the store. The
  gotcha, which cost one failed run, is that the socket is exposed as
  `NIX_REMOTE=unix:///build/.nix-socket` and NOT the daemon path, so exporting
  `NIX_REMOTE=daemon` fails with "cannot connect to socket at
  /nix/var/nix/daemon-socket/socket". Keep that as a FALLBACK. It and dynamic-derivations
  are CppNix-specific and long-experimental, and snix takes IFD as a supported feature
  rather than a wart. After #51 the graph is tens of MB rather than 1.62 GB, an IFD that
  size costs a fraction of a second, and the architecture that exists today becomes
  affordable without any experimental feature. Do #51 and #47, RE-MEASURE, and only then
  decide whether granularity still needs a lever.
- **The OOM was NOT eval, and this bullet used to say it was.** The evaluator holding a
  9.0 GB heap resident for the whole IFD build was a contributor and is now 1.76 GB. The
  cause is `nix-daemon`, which forks a worker per CONNECTION that grows 8-9 MB per
  derivation BUILT: 11.1 GB at 1,171 and 15.3 GB at 1,873, extrapolating past 30 GB for
  8,472. It is all returned on disconnect, so CYCLE THE CONNECTION rather than capping
  memory, and `--max-jobs` does not help because the growth is per derivation PROCESSED.
  Full detail with the endpoint milestone above.
- **nushell traps** (task #40, one increment each): a `(...)` inside `$"..."` is a
  subexpression, so a literal `(Phase 4.1)` calls a command named `Phase` and fails at
  RUNTIME, not at parse time; an `else if` must sit on the closing brace line or it parses
  as a call to `else`; raw strings are `r#'...'#`, never `r#"..."#`; `get` with a computed
  index takes `-o`, not a trailing `?`; `input` reads the terminal, not stdin; a def cannot
  mutate its caller's variables and its `$env` writes do not propagate out.
  **`default` substitutes for NULL, not for an empty string.** A flag declared
  `--scratch: string = ""` is the empty string when omitted, so `$scratch | default <x>`
  keeps the empty string. That made a scratch root empty, and a cleanup loop that killed
  processes whose exe lives under it matched EVERYTHING and killed an unrelated build.
  The older checks take such an argument as an optional POSITIONAL, which really is null.
- **file(1) strings**: `Mach-O 64-bit x86_64 dynamically linked shared library` and
  `Mach-O 64-bit x86_64 executable`. x86_64 comes BEFORE "dynamically". Copy an existing
  case rather than writing it from memory.
- **A whole-tree glob over a vendored pin dies on one dangling symlink**, failing the whole
  package with an error naming a subtree unrelated to what you built. Check with
  `find buck-src/<pin> -xtype l`; fix in `GLOB_EXCLUDE` in gen-buck-from-ninja.py.
- **MIG runs the C preprocessor over the .defs**, so its -D flags decide which routines
  EXIST. A mysteriously absent symbol from a MIG-generated library is a mig_flags question
  first.
- **Confirm a port with a direct `buck2 build <label>`**, never with buck-port.py's verdict.
  It also says "failed (no recognisable error)" when the cause is a package-level file
  error.
- **buck2 runs**: `nix develop --command nu -c 'source scripts/buck-env.nu; buck2 ...'`,
  nu rather than bash now that the file is nushell.
  Sourcing buck-env.nu alone is not enough: the direnv cache goes stale (rustc and bindgen
  went missing that way), and buck2's daemon inherits the client PATH at daemon START, so
  `buck2 killall` after fixing PATH.
- **Never pre-create DPREFIX.** cider treats an existing prefix as already set up, and
  launchd then boots into an unpopulated filesystem and stalls deterministically.
- **`pkill -f <pattern>` matches the command you are about to run** (exit 144). For
  containers use one ERE pattern: `pkill -9 -x 'mldr|cider|ciderd|shellspawn'`.
- **A `jj git push` "Could not read from remote repository" is the remote**, not you
  (`ssh -o BatchMode=yes git@tangled.org` shows an IPv6 connect timeout). Retry.
- **Rebuild costs**: touching buck/generated/sdk_headers.bzl or the ksmig mig_flags rebuilds
  essentially everything, roughly 14,000 actions, about 20 minutes.
- **Known flakes**, re-run before believing a failure: buck-bash-check.nu fails roughly 1 in
  5 with a core dump (shared SIGFPE); buck-smoke-check.sh failed once at 11/31 then passed
  3/3.
- **All three runtime checks failing together is usually the MACHINE, not the tree**, and it
  has had three separate causes so far, so work through them in order before believing a
  regression. (1) Leftover containers, especially after a guest-nix milestone, which leaves
  its own prefix and daemon behind: `pkill -9 -x 'mldr|cider|ciderd|shellspawn'`.
  (2) A wrong ARTIFACT at a right path, which looks identical from outside: read the
  `buck/prefix/BUCK` diff, which is how a dylib landing at usr/bin/login was found. (3) Load.
  Running the checks immediately after a large rebuild fails them; the same scripts pass on
  an idle machine minutes later. Boot the container by hand as the tiebreaker -- it takes
  seconds and tells you at once whether the tree or the harness is at fault:
  `DPREFIX=<fresh> DSERVER_LIBEXEC_PATH=$rt/libexec/cider
  DSERVER_MLDR_PATH=$rt/libexec/cider/usr/libexec/cider/mldr CIDER_NO_LAUNCHD=1
  $rt/bin/cider shell /bin/bash -c 'echo HELLO'`.
- **Measure before attributing slowness**, and revert a fix whose premise turns out wrong.
  gen-install-from-manifests.py's eight minutes were a per-entry repo walk, not the
  backtracking regex I first blamed.

Guest-nix milestone against a buck2 prefix: materialize it to an `rt` dir, then
`DSERVER_LIBEXEC_PATH=$rt/libexec/cider
DSERVER_MLDR_PATH=$rt/libexec/cider/usr/libexec/cider/mldr bash
scripts/build-hello-bypass.nu --mono $rt --prefix /tmp/cider-hello-m1-buck2`. Expect
`build_rc=0` and "Hello, world!".

---

## Working agreements

- **Verification is execution in a clean prefix**, not inspection. A task is done when its
  test runs green from a fresh prefix, not when the code looks right.
- **Small commits**, phase-tagged (`feat(phaseB.3): ...`), tests included, this doc updated
  in the same commit.
- **When blocked** (a nixpkgs-side change seems required, a licensing question, a
  divergence-class stop-the-line, or >1 day stuck on one signature): add a dated entry under
  Blockers with reproduction steps and stop that thread; take the next ranked item.
- **Insurance:** mirror the bootstrap-tools closure + key reference narinfo/nars to our own
  Cachix early (the oracle depends on cache retention past 26.05 EOL, end of 2026).

## Risk register

| Risk | Class | Mitigation |
|---|---|---|
| Silent output divergence (shim lies subtly) | correctness | Phase D oracle + stop-the-line |
| Stalls in event-loop-heavy builds (kqueue/poll) | fidelity | C.4b watchdog + stall triage |
| macOS-14 symbol surface larger than expected | scope | demand-driven ordering; stubs last |
| Mach IPC perf through userspace daemon | perf | measure during E; acceptable for CI |
| Cache retention past 26.05 EOL | infra | mirror reference closures to own Cachix |
| x86-only effort waste | strategy | ARCH tags; Phase F keeps the boundary honest |

---

## Blockers

Active blockers get a dated entry here (repro steps + what's stuck); resolved ones fold into
Gotchas or Open work. The known standing limitations are already tracked above — the launchd
portset deadlock (#47, bypassed by `CIDER_NO_LAUNCHD=1`), the SIGFPE exec-fidelity flake
(#44, retryable), and the nix-ninja full-graph `migHeaderIncsFor` blocker. Nothing else is
currently un-tracked.


The task #80 grouped-build eval-speed analysis moved to `docs/plan-history.md`.

## #66 full entry as it stood when the task closed, moved out of PLAN.md 2026-08-12

The PLAN entry is now a summary. This is what it said in full, kept for the measurements
and for the two claims it records as WRONG, which are the useful part.

### #66 - get the lowering out of the evaluator (DONE 2026-08-11)

BOTH HALVES ARE DONE. A, the bridge, passes fourteen properties over eleven fixtures and is
enforced to reference nothing outside itself. B, the adapter, builds the whole 1,474-group graph
through the emitted route and matches the lowered route on every group. The result to remember
is in the bullet marked B IS DONE below.

KEEP BOTH ROUTES. The recommendation on record, and the reason is empirical rather than
aesthetic: the DIFFERENTIAL between the two routes is what found four real defects, including
two that no single route could expose. A second implementation that agrees is a test; deleting
it converts a working check into an unverified assumption.

A general buck2-graph to dynamic-derivation bridge, worth having for OTHER projects.
GENERALITY IS THE REQUIREMENT; cider is the first consumer, not the target. Nothing in the
reusable half may mention pins, the SDK farm, cider staging or this repo's layout.
Full detail, measurements and traps: docs/plan-history.md, "#66 in detail".

- **A, the bridge, DONE and GENERAL.** `nix/lib/dyn-actions.nix` plus nine fixtures beside it.
  `scripts/buck-dyndrv-check.nu` asserts **ten** properties and PASSES. Three are properties of
  Nix; the rest are of the bridge, and several were false when first checked (the DAG edge, the
  whole of `specDir` mode, specDir-plus-a-DAG). None had a fixture, so none could have been
  noticed. `extraEnv` is asked **per action**, which is the case a consumer actually has; and
  specDir mode now accepts a spec dir the bridge did NOT write, holding only name, builder and
  args, with the fixup supplying the system, version, outputs and the output PLACEHOLDER, since
  none of those is something a generator can know.
- **B, the adapter, and A and B are CONNECTED.** `buck_lowering.py` renders the WHOLE
  builder script and `buck-graph-to-specs.py` writes it, along with `needs.json` and a `dyn/`
  directory of bridge-shaped specs, inside the graph derivation.
  **`.#cider-buck2-dyn-gen` builds a real cider cone from those specs with nothing serialised
  in the evaluator, and `diff -r` against the lowered derivation is clean.** A second cone,
  `-trees`, covers the staged-tree numbering; `-scale` instantiates all **1,474** producers in
  ~13 s, against the lowering's own 10.6 s.
- **THE LOWERING NO LONGER ASSEMBLES A SCRIPT.** It reads the template and supplies five
  consumer values. All 1,474 labels unchanged, endpoint drvPath identical, rung 2 zero
  builders. Verified byte for byte by `scripts/buck-script-check.nu`, which reads the
  generator's own `full.json` out of the store rather than re-rendering, and by
  `scripts/buck-needs-check.nu`, which reads `passthru.definitionNeeds` rather than `deps` so
  it cannot compare the python against itself.
- **THREE FAILURES WORTH THE SPACE, all one shape: a green result over a broken build.** A run
  that passed with `find`/`sed` missing (nativeBuildInputs is only what the lowering ADDS to
  stdenv); the deep cone failing on `llvm-ar`, because **an emitted action runs no setup hooks**
  and `makeBinPath` follows neither hooks nor propagation; and the specDir check reporting OK
  while its diff never ran, because both modes produced a **byte-identical check derivation**.
  Look for the artifact, never the exit code.
- **THE INVARIANCE CHECK IS A TOOL,** `scripts/buck-lowering-invariance-check.nu`. It
  fingerprints every label's `builderScript` and `stageScript` against a saved baseline, which
  is the check a green ladder cannot replace: rung 2 builds ONE target, so a change that moves
  every *other* derivation is invisible to it.
- **THE FULL GRAPH BUILDS THROUGH THE EMITTED ROUTE AND REPRODUCES IT EXACTLY. B IS DONE.**
  Final run, 2026-08-11, 4,516 builders and zero nix-level errors, all 1,474 producers and all
  1,474 emitted actions:

      OK the whole graph emitted, all 1474 group(s) match the lowered route

  **THE CHECK IS KNOWN TO FIRE, which is the only reason that zero is worth anything:** the
  SAME check on the SAME graph reported `identical 1364, differ 110` one run earlier, and named
  every differing group. The 110 were all mig groups differing by one line, `stub generated
  <wall clock>`, which is #95 and is now fixed. So the difference between 110 and 0 is a fix to
  the port, measured by a check that had just demonstrated it can report a non-zero.
- **WHAT THAT MAKES #66.** The emitted route is not a proposal, it is a second independent
  implementation of the whole 1,474-group graph that agrees with the first byte for byte. The
  differential is what found the four real defects listed below; none was visible from either
  route alone.
- **TWO REAL DEFECTS THE FULL-SCALE RUN FOUND FIRST.** `SOURCE_DATE_EPOCH` is set by stdenv's
  SETUP SCRIPT, not as a derivation attribute, so it is invisible when comparing derivations and
  an emitted action never gets it; and the stdenv tool list was hand-picked and missing `xz`,
  which surfaced 981 builders in. Both fixed. An earlier run also reported 57 diff lines that
  were the check following dangling symlinks IDENTICAL in both trees, fixed with
  `--no-dereference`.
- **THE ADAPTER NO LONGER CONSUMES THE LOWERING.** It read `tools`, `stageScript`,
  `treeScripts` and `deps` from `lowered.drvs.<label>.passthru`, which forces a whole
  mkDerivation per group; it now reads top-level accessors. Emitted derivations are unmoved,
  checked against a running build's log. **The claim that this coupling was why the two routes
  cost the same was WRONG**: from eval statistics, which ignore machine load, decoupling moves
  thunks -1.3 percent and sets -8 percent while envs and calls go slightly up. A wash. The real
  reason is that `builtins.outputOf` forces one derivation per action either way. B remains a
  VERIFICATION of the bridge at full scale, not a replacement path.
- **STILL OPEN, and it is the user's call.** Making the adapter standalone means emitting or
  rebuilding the toolchain list, the staging script and the staged tree scripts, which is a
  chunk of the lowering reimplemented. Nothing measured says what that would cost or save.

## #96 as it stood before the measurement, moved 2026-08-12

Kept because it is a worked example of an entry that named a real symptom, attached the
wrong cause to it, and proposed a fix for code no endpoint evaluates. The measurement
that closed it is in the live entry.

### #96 - a first-party source edit still invalidates every group that stages the project

THE CACHING WEAKNESS THAT IS LEFT. Everything else caches: CA early cutoff works, an unrelated
source edit rebuilds the graph and runs ZERO buck2 derivations, no-op rebuilds are about 0.3 s,
and the 4,159 staged-tree scripts did not move at all in the recorded probe. This one does.

THE CAUSE IS NOT THE GRAPH. `graph.json` records action command lines rather than their
outputs, so it stays byte identical across changes that alter what a build produces; the migcom
patch left it at `mv46f3p6`.

**THE CAUSE STATED HERE WAS THE WRONG CODE PATH, and the correction matters because it changes
what the fix would even be.** This entry said the cascade is that the staging script embeds
`${projectSrc}`, the whole filtered project. That is true of `stageProject`,
`ciderBuck2Lower.nix:1282`, and `stageProject` is the **`sourceGroups` = OFF** path. Read off
the code rather than the comments:

    flake.nix:399, :510, :835      sourceGroups = true, all three places it is set
    ciderBuck2Lower.nix:1332       "every endpoint that gets gated has it ON"
    ciderBuck2Lower.nix:1223       so the endpoint takes stageTextFor: groups + pinStageLines
    ciderBuck2Lower.nix:547        pinPath = "${pinsTree}/${p}"
    ciderBuck2Lower.nix:452        pinsTree is assembled from ciderSrc.pinPaths, the per-pin
                                   stores, whose inputs are FROZEN PINS

So on the path the endpoint actually takes, the whole-project reference is already gone: #54
narrowed the groups, #74 gave the pins a self-contained mirrored tree, and #79 gave the escape
destinations their own store paths after an earlier version resolved them against the whole
project and moved on every edit.

**WHICH MAKES THE MEASUREMENT THE WHOLE TASK, not a preliminary to it.** The wide path still
exists and is what this entry described; the endpoint does not take it. Whether anything still
cascades at endpoint scale is genuinely unknown until the probe reports, and if the number comes
back small the work here is to correct this entry, not to implement anything.

**STEP 0 IS A MEASUREMENT, AND THE TARGET DECIDES WHAT IT MEANS.** Two figures are on record
and they differ by sixty times, because they answer different questions:

    5 builders, 97 s      buck-quick-check.nu header, on
                          darwin/frameworks/AVFoundation/constants.m
    323 compiles and      ciderBuck2Lower.nix, one first-party source edited on the minimal
    still climbing        ENDPOINT, with 0 of 4,159 stage-trees and 1 stage-project

Both are right. `buck-quick-check.nu` defaults to `DEFAULT_ATTR = .#cider-buck2-one`, ONE small
target, so it counts only what that target pulls. The cascade this task is about is the endpoint
one. **So the probe must be run with `--attr .#cider-buck2-prefix-min`,** or it will report a
handful of builders and read as "caching is fine" while measuring something else entirely.

THE PROBE EDITS A FIRST-PARTY SOURCE, so it must not run while a build is in flight: `darwin/`
and `linux/` are on the not-safe list precisely because jj auto-snapshots and what nix builds is
the working copy. And if a probe is interrupted it leaves its marker line behind, which the next
build would snapshot; `--revert-only` strips it by tag rather than by whole line, so it recovers
even after a kill.

Re-take it before any work, since 323 predates #95 and the rest of 2026-08-11: edit one leaf
source, rebuild the ENDPOINT, count builders that RAN, revert. The probe proves its counter
first, by building a fresh-nonce derivation that must report exactly 1, and it puts a nonce in
the marker so probing the same file twice cannot reproduce an already-built tree and report a
false zero. If the number is genuinely small at endpoint scale, record it and stop.

THE FIX, if the number justifies it: narrow the staged source per staging KEY. The lowering
already partitions 1,474 groups into 94 staging scripts, so give each key a `projectSrc`
filtered to the source groups it actually stages. Cheaper variant: split `projectSrc` by
top-level directory only, five or six sets, far less risk, and already enough to stop a `linux/`
edit invalidating every `darwin/` group.

THE DANGER IS DOCUMENTED AND HAS BITTEN. #44 is exactly this failure: per-target source
narrowing DROPPED real compile inputs, and it does not fail at evaluation, it fails as a missing
include an hour into a build. #69 records a `narrowSources` mechanism that existed and was
superseded, so read it first. Narrow by source GROUP, the coarse unit that already exists, never
per target.

THE SAFETY NET EXISTS NOW and did not when #44 bit: `buck-lowering-invariance-check.nu`,
the endpoint drvPath, and `.#cider-buck2-dyn-gen-all`, which diffs all 1,474 groups against an
independently built route and would surface a dropped input as a differing group rather than as
a build failure much later.

