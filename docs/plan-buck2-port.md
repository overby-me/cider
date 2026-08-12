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
  source bugs to find** -- only build-definition work. A Buck2 port is about
  expressing Darling's build *correctly and explicitly*, not fixing Darling.
- The genuinely hard parts to express in ANY system are: (1) MIG codegen, (2) the
  firstpass two-pass link that breaks the libSystem umbrella cycle, (3)
  reexport / `install_name` machinery, (4) the darwin SDK sysroot + cross-arch
  (`x86_64-apple-darwin20`) toolchain, (5) the cider header shims. Spike these
  before mass porting (Phase 1) -- they decide feasibility.
- Hand-written BUCK for upstream code **drifts** on every Darling bump. Mitigate
  with a CMake/ninja -> BUCK *generator* (reuse `rust-ninja -t graph-json`) to
  bootstrap targets, then hand-refine the ones we own. Generated where it drifts,
  hand-authored where we iterate.

---

## Explicit non-goals

- Porting the stable upstream framework tier (Security/CF/Foundation/CLI tools)
  wholesale. Cache the dense build for those; port on demand only.
- Maintaining a hand-written BUCK definition for code we do not edit (it drifts).
  Generated-and-refined only.
- Replacing the dense `.#default` build, which stays the whole-tree build of
  record until the Buck2 port demonstrably covers what we need.

## What is left of the plan

Nothing, at build level. The phases below used to run to Phase 3; the port is at
1452 of 1452 in-scope link edges, `buck2 build //...` is green over ~12k targets and
the Nix endpoint lowers the same graph. The phase plan, the sequencing summary and the
risk register were removed once they described finished work, along with the writeups
of the coverage blind spot, the install rules, the four boot failures and the endpoint
milestone: each of those is the commit that made the change.

What is still true and current lives in the root `changelog.md`. The two things below are
kept here because they are neither current status nor finished history.

## Profiling the evaluation: 152s of CPU down to 9s

Nix 2.34 has a sampling eval profiler (`--eval-profiler flamegraph`), and pointing it at
`nix eval .#cider-buck2-prefix.drvPath` answered in one run what had been guesswork.

Before: 2m08s wall, 152s CPU, 200M thunks, 376M function calls, 28.8 GB allocated -- to
compute ONE derivation path. After: 14s wall, 9.3s CPU, 19M function calls, 6.3 GB.

Three costs, in the order the profile ranked them:

**Path normalisation, ~25% directly plus most of the 21% the profiler charged to
`primop isString`.** `linkTargets` resolved every relative symlink value by hand: split on
"/", fold away each "..", join back. `lib.splitString` is `filter isString (builtins.split
...)`, which is where the isString time came from, and `lib.init` copies, so the fold was
quadratic in the path depth. It ran over every link in every staged tree -- the SDK farm
alone is 3,591 -- once per consuming target. It is now one `os.path.normpath` per link in
the dumper, recorded as `stagedTreeDeps`, and Nix just reads the list.

**A scan where an index belonged.** `declaredStaged` tested all ~1,230 staged paths against
the declared-inputs list for every target. `stagedByTarget` inverts it once.

**The same script text, rebuilt per consumer.** A staged farm is consumed by many targets,
and `stagedTreeScript` rebuilt its shell script -- two `escapeShellArg` calls per link,
across 1,115 trees -- every time. Memoised per tree.

### A wrong turn worth recording

Midway I concluded the memoisation had changed behaviour, because the derivation hash moved
between a memo-off and a memo-on evaluation. It had not. The lowering interpolates
`${src}/...`, so every lowered derivation depends on the whole project source, and I had
edited that very file between the two runs. Appending a bare comment to
ciderBuck2Lower.nix changes the hash too; two evaluations with no edit between them are
identical. The memo was reverted on that bad reading and then restored.

The misreading exposed something real: **editing any byte of the project invalidated every
lowered target derivation**, a comment included. For an endpoint whose whole purpose is that
other people do not rebuild what they did not touch, that was its most expensive bug.

Half fixed since. `nix/lib/ciderBuck2Lower.nix` filters the lowering source, so plan/,
docs/, nix/, scripts/, the VM tests, changelog.md and the other documentation no longer relower
anything -- which matters because editing generators and changelog.md is most of what this port
consists of. The precise fix is still open and is task #11: depend on the SOURCES THE
ACTIONS NAME, which the graph already records per action, rather than on a filtered
whole-project path.

## The VM harness: Darling does not run in a NixOS test VM at all

Task #10 was meant to be the easy one: run the bash milestone in the same harness
tests/cider-smoke.nix uses. tests/cider-buck2-smoke.nix boots the VM, finds the
launcher, and then `cider-buck2 shell /bin/bash -c ...` times out with no output, where
the identical command takes seconds on the host through both endpoints.

The test dumps the daemon log, the process list and the uid/userns state on failure, and the
log says the container BOOTS: full xnu_sys init, `execve expand /usr/libexec/shellspawn`,
`cider_sigexc_self()`. Then it hangs.

The lead recorded here used to be a one-line difference in the daemon log -- `dtype for fd 2`
resolving to a pipe on the host and to `/ciderd.log` in the VM. **That was a
correlation written up as a cause, and it is now disproved.** Two host tests, seconds each:

  * binding the container's stderr to a regular FILE instead of a pipe runs fine (rc=0);
  * so does the NixOS driver's exact command shape, `( set -euo pipefail; CMD ) |
    (base64 --wrap 0; echo)` with stdin closed.

What the fd tables show instead, from a working host run: the persistent shellspawn INIT has
fd 1/2 on `ciderd.log` -- by design, `linux/launcher/src/main.rs:490` redirects the
daemon's stdio there so a one-shot command does not pin the caller's stdout open forever --
while the guest running the actual command gets the CALLER's fds passed to it. So
`/ciderd.log` is what the init legitimately reports, and the VM log line is most
likely the init's rather than the command guest's, i.e. evidence that the command guest is
never spawned at all. STILL UNVERIFIED: the interactive VM that was going to settle it could
not be built, because the Nix endpoint turned out to be broken in four separate ways (see
below). Treat the paragraph above as the most plausible reading, not as a finding.

Cheaper explanations already eliminated: running without a TTY reproduces fine on the host,
and giving the VM 4 cores and 4 GB instead of 2 and 2 changes nothing.

**It is not the port.** The REFERENCE Nix-built Darling fails the same way in the same
harness: `nix build .#checks.x86_64-linux.cider-smoke` gets to `cider shell true` and
times out with exit code 124, at the same place. (That check also had to be repaired first
to run at all -- it fails its own linter on an f-string with no placeholders, which says it
has not been run in a while.)

So two things are now known that were not:

  * the buck2 port's Darling is fine -- it boots and runs bash on the host, from the daemon
    path and from the Nix endpoint, repeatedly;
  * `tests/cider-smoke.nix` does not pass on this machine with the reference build, so
    task #5 was never "port more components until it goes green". Whatever is wrong with
    Darling inside a NixOS test VM has to be fixed first, and it belongs to Darling's
    container plumbing rather than to this port.

## The Nix endpoint keeps breaking in ways the host build cannot see

The line above -- "it boots and runs bash from the Nix endpoint" -- was true when written and
then quietly stopped being true. Getting an interactive VM to diagnose #12 meant building
`pkgs.cider-buck2`, and that turned up four independent faults at once. The count is not the
point and is deliberately not kept here, because it went on growing: an argv-splitting bug in
`configure_file` after these four, and then the staging regression below. What they have in
common is that the host build passes throughout.

  * **A cyclic symlink wrecked the tree.** `expand_dir_links` in
    `buck-src-normalise.py` followed JavaScriptCore's
    `DerivedSources/JavaScriptCore/JavaScriptCore -> ../..` into the tree it was creating:
    13 directories became 1147 at 266 levels deep, `except OSError` swallowed the
    ENAMETOOLONG, and buck2 then died crawling the wreckage. Invisible on the host, whose
    `vendor/src` still held the plain symlink.
  * **wrapgen could not dlopen anything.** The generated `.buckconfig.local` had no
    `elf_lib_dirs`, so all 22 `wrap_elf` targets failed. The lowering needed the same
    libraries declared separately, via `extraTools`, because a wrap action carries them as
    plain text in its argv and the dump discards string context.
  * **Host headers were never named.** The reference gives 5,945 compiles an absolute `-I`
    into X11, freetype, cairo, ffmpeg and the rest; the port named none of them and got away
    with it because `darwin_cc` defaults to the bare name `clang`, which in the dev shell is
    the WRAPPED clang injecting the same dirs through `NIX_CFLAGS_COMPILE`.
  * **fseventsd needs kernel UAPI headers**, which are not a library and so were in no list.
  * **The lowering symlinked `src/` into the store**, so the pins could not be planted at
    `vendor/pins/<pin>` and every one of the 1798 lowered targets died on "Permission
    denied". One word: the top-level exclusion list had `name != "src"` rewritten to
    `name != "projectSrc"`, which is a Nix binding name and matches no directory.

Three checks now hold the line, all verified to fail when the invariant is broken:
`scripts/buck-host-includes.nu` (in `buck-test.nu`) requires every target the reference gives
a host `-I` to declare `//linux/native:host_headers`; `scripts/buck-nix-includes-check.nu`
(standalone) compiles those targets with clang-unwrapped and ONLY the dirs the Nix derivation
declares, which is the divergence that hid two of the four; and
`scripts/buck-lowering-stage-check.nu` reads the generated staging script, which is how a
staging bug becomes a five second answer rather than a 90 minute one.

**The lesson worth keeping**: each of these cost about an hour to find in a Nix build and
seconds to reproduce on the host once the condition was named -- an emptied config value, a
forced `clang-unwrapped`, one include dir removed. Name the condition, reproduce it on the
host, then fix.
