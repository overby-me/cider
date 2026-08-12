# What Cider needs before a first release

Written 2026-08-12, from measurements taken on the tree at that date, not from impressions. Every
number below came from running something; where a thing was checked but not proven, it says so.

The next release after this one is aarch64, so the last section is separate: it is not release
work, it is what the aarch64 work will hit, measured now while it is cheap to measure.

---

## The finding that matters most: nothing verifies this project

Two independent breaks in the flake's DEFAULT output were found today by evaluating it by hand.
Neither is exotic and both had been sitting there:

    1. buck2 aquery over the whole graph died in ANALYSIS on root//buck/prefix:cider_prefix,
       because making the Rust xcrun and PlistBuddy the installed binaries put a
       darwin_rust_staticlib into the prefix and the graph derivation did not supply the
       toolchain. Introduced 2026-08-12 (#102 flip), fixed the same day (4d190e633201).
    2. The lowering staged src/<name> for every entry of projectSrc/src. #87 stage 2 emptied
       src/ into darwin/ and linux/, so builtins.readDir hit a directory that does not exist,
       which is an EVAL ERROR rather than a no-op. Dead since #87, fixed 2026-08-12
       (e2f268e59a0d). The same file already carried a comment about the FIRST instance of
       exactly this, and this was the second.

**Why nobody saw them.** CI exists, at `.tangled/workflows/ci.yml`, and it is disconnected in two
independent ways:

    when: branch: main            main is at f70d5b60, "#80", which is 22 tasks behind. All
                                  work is on buck2-port, so CI has not run on any of it.
    nix build .#cider             NOT DEFINED in flake.nix.
    nix build .#cider-sdk         NOT DEFINED in flake.nix.

So even if it fired it would fail on a missing attribute. Effective automated verification of
this repository is currently zero. Everything green today is green because a human ran it.

**This is the first release blocker, and it is structural rather than a bug.** A release is a
promise that the thing builds for someone else; right now nothing but a person at this keyboard
has ever checked that, and the two breaks above are what that costs.

---

## Blockers

**B0. The command the README gives a user did not complete.** This is the most user-visible item
on the page and it was measured today, not recalled.

    started   nix build .#cider-buck2-prefix-min -L --no-link
    16:40     last log line, after the sources stage:
              "sources: 58506 distinct project source(s), from 5483827 per-target entries"
    16:51     no log output for 11 minutes. The nix client had used 12 SECONDS of CPU in 16
              minutes and had ZERO children; the nix-daemon worker serving it also had zero
              children; and no compiler, linker or buck2 build process existed anywhere on the
              machine. The only buck2 processes were three IDLE daemons left over from earlier
              sessions, at 15, 11 and 10 hours elapsed.
    16:55     killed.

Not computing, not building, not waiting on a child: wedged. This matches the recorded
"endpoint builds freeze" entry whose mechanism is UNKNOWN and for which the harness reaper,
general daemon reaping and CA derivations have already been ruled out.

**WHAT THIS DOES NOT ESTABLISH, and the distinction matters before anyone hunts it.** It was one
run on a machine that also had three stale buck2 daemons and an unrelated process pinning a core.
It does not show the freeze is deterministic, nor that it is the same freeze as the recorded one,
nor that a clean machine would hit it. What it does establish is that nobody can currently promise
a stranger that the documented command finishes, which is the thing a release is.

**The first move is not a fix, it is a reproduction on a clean machine**, which is also what B1
buys: CI is a clean machine that runs the documented command every time.

### B0 reproduced 2026-08-12 19:22, with the evidence the first observation lacked

Same command, same stall point: immediately after `cider-buck2-sources` completes. What the
instrument caught, which the 16:55 observation did not:

    client 3239272   wchan unix_stream_read_generic, blocked on
                     /nix/var/nix/daemon-socket/socket. 3 CPU ticks in 45 s, so 0.07 percent.
                     Its 17 threads are Boehm GC markers parked in futex_do_wait: the
                     evaluator is idle, not thinking.
    daemon 3239326   about 0.5 percent, steady: 22 ticks in 60 s, 41 in 90 s, 44 in 75 s.
                     ZERO children. Root owned, so its wchan and io are unreadable without
                     privilege, which is the one hole left in this picture.
    the build graph  NOTHING started since. /nix/var/log/nix/drvs shows
                     cider-buck2-sources.drv.bz2 at 19:22:41 as the newest, and a .bz2 there
                     means that derivation FINISHED. No builder process exists on the machine.
    competition      none. One client, one worker, no other nix process, any user.

**THE RECORDED "unreaped zombies" HYPOTHESIS IS REFUTED for this case.** There ARE zombies on
the box and they are `sd_espeak-ng`, `sd_festival`, `sd_voxin` and five more: speech-dispatcher
modules under one unrelated parent. None belongs to nix or to a builder.

**STARVATION WAS THE OBVIOUS ANSWER AND IT IS WRONG, which is why it was tested rather than
assumed.** The machine was saturated: `xscreensaver` at **1993 percent CPU**, roughly 20 of 22
cores, load 22.10. SIGSTOP on it dropped load to 9.15 within 75 seconds and freed the cores; the
daemon tick rate did not change and the log did not advance. It was resumed afterwards. So the
machine being busy is a real and separate problem, not this one.

**A METHOD ERROR THAT COST TWO WRONG CONCLUSIONS IN ONE SESSION.** `ps -o pcpu` reports a
LIFETIME AVERAGE, not current usage. It made an idle daemon look like it was working at 12.3
percent, and it hid the screensaver behind processes with longer histories. Sample
`/proc/PID/stat` fields 14 and 15 across an interval instead, which is what produced every number
above.

### B0 ROOT CAUSE, 2026-08-12 19:47: it is binary-cache querying, and it is invisible

Re-running with `-vv` answered it in one line, repeated eleven hundred times:

    downloading 'https://zed.cachix.org/<hash>.narinfo'...

The daemon is not stuck. It is asking four substituters, one narinfo at a time, whether each
output already exists:

    substituters     overby-me.cachix.org, nix-community.cachix.org, zed.cachix.org,
                     cache.nixos.org
    queries seen     1,116 in the first minutes, about 279 paths times four caches
    RATE             4 to 5 queries per MINUTE

At that rate a graph with thousands of paths takes hours, and **nix prints nothing about it at
default verbosity**, which is the entire reason this looked like a freeze. Every earlier
observation is consistent with it: no builder process, no new derivation, a client blocked on the
daemon socket, empty socket queues, and a daemon ticking at half a percent because it is waiting
on the network rather than computing.

**THE PROOF IS A CONTROL, not the log.** Re-run with substituters disabled:

    nix build .#cider-buck2-prefix-min --option substituters ""

It moved IMMEDIATELY: 4,653 log lines in 90 seconds and real compilation
(`building '...buck2-security_ssl_obj.drv'`). Same tree, same machine, same daemon.

**THE CACHES THEMSELVES ARE FAST, which is what makes this a nix-side problem rather than a
network one.** curl against all four: 0.06 s, 0.08 s, 0.16 s, 0.59 s total, all HTTP 200. So four
healthy caches answering in under a second somehow yield four lookups a minute.

**AND MY EARLIER "STARVATION IS RULED OUT" WAS NOT SOUND.** That test watched the build log, which
only prints on derivation events, over 75 seconds. At four queries a minute the log could not have
moved whatever the answer was. The observable could not respond to the intervention, so the test
proved nothing. The substituter finding stands on its own control, above.

**WHAT B0 IS NOT:** not a deadlock, not zombies, not the disk. It is a throughput problem in
substituter querying that presents as a hang.

### B0 CONCLUDED 2026-08-12 20:52: the build completes

With substituters disabled and the two bugs below fixed:

    nix build .#cider-buck2-prefix-min --no-link --print-out-paths --option substituters ""
    EXIT=0
    /nix/store/51nlpdb0xl04kxhxhkrmr3h3ywv0nvjl-buck2-cider_prefix_min-out

A full end-to-end run took 7 minutes 22 seconds with ZERO errors, and produced a 125 MB prefix at
`cider_prefix_min__prefix`. A confirming re-run returned exit 0 in 19 seconds against the cache.
So this is one full build plus a confirming realisation, not three from scratch, and it is stated
that way on purpose.

**WHY THE QUERIES ARE SLOW IS STILL NOT EXPLAINED, and that matters for how much this generalises.**
The caches answer in under a second and IPv6 is not the problem: curl over both protocols to
cache.nixos.org and zed.cachix.org returns HTTP 200 in 0.05 to 0.08 s, and the box has a working
default IPv6 route. So four healthy caches, two healthy protocols, and nix still manages four
lookups a minute. Candidates not yet tested: connection reuse and the http-connections limit, the
narinfo disk cache, and contention from the machine being saturated at the time.

**THIS MAY BE MACHINE-LOCAL RATHER THAN A CIDER DEFECT.** The substituter list is in this
developer's nix.conf, not in the repo, and nothing Cider ships can fix a user's cache
configuration.

**AND CI CANNOT SETTLE IT, which retracts what this section said before.** The earlier version
argued that a clean CI machine running the documented command was the measurement that decides
whether B0 generalises. It is not, because CI can never finish that build: Darling is too large,
and a hosted runner will hit its limit long before the prefix exists. An argument that depends on
a machine nobody has is not an argument.

So the honest statement for a release is unchanged and unhedged: the build completes on a
developer machine, and a slow substituter set can make it look like it has hung, with no output
to say so. Whether that slowness happens elsewhere is unmeasured, and the way to measure it is
someone else running the build, not automation.

### What the stall was HIDING: the two guest Rust tools do not build in the endpoint

The moment the build got past it, both failed:

    /nix/store/...-cider-darwin-rust-1.95.0/bin/rustc: No such file or directory
    buck2 lower: an action of root//darwin/xcselect:xcrun_rs_lib failed

The lowered derivation replays a recorded argv that names the toolchain by ABSOLUTE store path,
and that path was not among the derivation's inputs, so the sandbox did not have it. Fixed by
adding it to the lowering's tool set in `nix/lib/ciderBuck2Lower.nix`, beside `pkgs.rustc`, but
for a different reason: the others are bare command names needing PATH, this one needs to exist.


**B1. DONE 2026-08-12 (4f7e30082b64), then NARROWED.** CI was disconnected twice over and is now
pointed at the branch the work is on, naming attributes that exist.

**BUT IT DOES NOT BUILD, and that is deliberate.** Darling is too large for a hosted runner to
finish, so a CI that tries is a CI that always fails and therefore gets ignored. What CI keeps is
the half that is both cheap and load bearing: EVALUATING every advertised flake output. That is
not a consolation prize. Both breaks that started this document, the analysis failure and the dead
src/ readDir, were EVAL errors: neither needed a single compile to surface, and evaluation alone
would have caught both in seconds.

**B2. DONE 2026-08-12 (4dfbeeaf7d33). Decide and signpost what the product IS.** `flake.nix` exposes **51** package attributes.
Almost all are development probes: `cider-buck2-dyn-gen-scale`, `cider-buck2-blocks`,
`cider-buck2-probe-bigfile`, `cider-buck2-graph-min-skeleton`. A newcomer cannot tell which one is
Cider. `packages.default` is `cider-buck2`. The README tells people to build
`.#cider-buck2-prefix-min`, which is the MINIMAL prefix, not the product. Pick the user-facing
name, make `default` be it, and mark the rest internal.

**B3. DONE 2026-08-12. The README promised Darling's features, not Cider's measured ones.** It is largely inherited
prose and it currently claims `installer -pkg`, `hdiutil attach` of an Xcode DMG, `unxip`, and
compiling with Apple's clang inside the prefix. Those are Darling's claims. **None of them is
covered by any check in this repo**, and the runtime checks that do exist cover bash, AppKit under
X11, JSC, dispatch, security, scripting, launchd and audio. Either verify each claim or remove it.
Shipping a README that overstates is worse than shipping a short one.

**B4. PARTLY DONE 2026-08-12: VERSION and CHANGELOG.md added, no tag yet.** `ls CHANGELOG* VERSION*` returns nothing and
flake.nix carries no version string. A release needs a number, a dated summary of what works, and
an explicit statement of what does not.

**B5. State the licence position in the README, not just in the file.** DONE 2026-08-12: the
README now says plainly that Cider is a fork of Darling licensed GPL v3 or later, and points at
LICENSE. Compare `#101`, where dockur/macos was measured pushing exactly this question onto its
users.

---

## Should fix, not blocking

**S1. DONE 2026-08-12 (040911576041), and the user widened it to .vscode, outputs/, plan/, .gdbinit and CONTRIBUTORS.md. `tools/` was a museum.** Four items with no live caller:

    tools/generate-xcode-stubs.py    24 KB, python3, upstream Darling
    tools/cider-stub-gen            10 KB, python3, renamed by #84 so it LOOKS first-party,
                                     referenced by nothing in the tree
    tools/i386-map                   python2 (#!/usr/bin/env python), which will not run
    tools/debian/                    make-deb, ppa-build-source: Darling's Debian packaging,
                                     and Cider builds with Nix

The python campaign cleared `scripts/`, and these are outside it. Deleting the dead ones is
minutes and removes an obvious "is this project maintained" signal.

**S2. The container faults at startup about once per 61 runs.** Measured across four full runs of
the PlistBuddy parity gate: one `rc 136` SIGFPE with a core dump that did not reproduce in 10
attempts against either binary, and two `[mldr] start-stack mmap at 0x7fffff600000 failed`, once
killing the process before its program ran. A user will hit this and report it as "cider is
flaky", so it needs either a fix or a known-issues entry with that exact string in it.

**S3. DONE 2026-08-12. Say how to actually RUN it.** The README shows `cider shell echo Hello world` but the build
instruction produces a prefix. There is a NixOS module (`programs.cider`, in `nix/nixosModule.nix`)
and it is not mentioned. Add the install path: module, `nix profile install`, or a wrapper.

---

## What is genuinely in good shape

Worth stating, because the blockers above are about packaging rather than substance.

    developer-machine leakage   ONE line in the whole tracked tree, in a doc. Checked across
                                27,355 tracked files.
    the build system            buck2 only since #82; cmake and nix-ninja are gone
    python                      zero in scripts/, and the remaining four are in tools/ (S1)
    host tools                  getuuid, elfdep, wrapgen in Rust with byte-parity gates the
                                suite runs
    guest tools                 xcrun and PlistBuddy in Rust, gated inside the container,
                                61 cases plus 13 interactive sessions
    the suite                   163 checks, last full run 0 failed
    licence hygiene             GPL headers kept through the #84 rename, provenance of
                                header-less files proven by blob identity (#76)

---

## aarch64, which is the NEXT release, measured now

Not release work. Measured while the tree is in front of me so the estimate is not a guess.

**The build-system surface is small.** 18 first-party files name `x86_64-apple-darwin`, and after
removing docs and PLAN prose the real change list is about a dozen:

    buck/toolchains/BUCK            5 mentions      buck/rules/codegen.bzl      2
    buck/rules/darwin.bzl           1               buck/rules/rust.bzl         1
    buck/toolchains/cc.bzl          1               nix/lib/ciderBuck2Graph.nix 1 (the triplet)
    nix/darwinRust.nix              4               scripts/buck-coverage.nu    8
    scripts/buck-setup.nu           1               scripts/buck-rpath-check.nu 2
    scripts/buck-darwin-rust-build.nu 3             scripts/buck-darwin-rust-symcheck.nu 2

**Our own assembly is almost nothing.** Of 115 files with assembly or inline asm, 112 are under
`darwin/` and are vendored Apple content (CoreAudio utility classes, SDK headers, libm). The
first-party ones are three: `linux/server/src/xnu/memory.rs` and the two wrapgen files, whose asm
is a `.section` directive rather than instructions. The deep porting cost people expect from
"aarch64" is not in our code.

**libm already ships ARM.** `darwin/libm/Source/ARM/` exists upstream alongside `Source/Intel/`.

**Three concrete things will need widening, and one is new today:**

    nix/darwinRust.nix   pins rust-std for x86_64-apple-darwin ONLY. Guest Rust binaries are
                         now INSTALLED (xcrun, PlistBuddy), so aarch64 needs the matching std
                         pinned or those two do not build at all on the new target.
    the triplet          x86_64-apple-darwin20 in nix/lib/ciderBuck2Graph.nix, which also names
                         the ld64 binary
    ld64                 MEASURED 2026-08-12 AND IT WORKS. This was the first thing to check
                         because everything depends on it, and the answer is yes: clang built
                         a trivial arm64-apple-macos11 object and our buck2-built ld64 linked
                         it into "Mach-O 64-bit arm64 executable, flags:<NOUNDEFS>". The
                         binary is named x86_64-apple-darwin20-ld and handles arm64 anyway,
                         which is ordinary for cctools ld64.
                         WHAT IT DOES NOT SHOW: that was a static link of one object with
                         -e _main. It does not prove linking against arm64 dylibs or an arm64
                         libSystem, because we have neither yet.

**The honest unknown.** Nothing here says what the GUEST side costs: duct-tape, mldr and the
syscall layer all assume x86_64 register layout, and that was not measured today because it needs
reading rather than counting. Budget for that separately.

---

## Directory consolidation: what was done, and what was measured and rejected

Asked for 2026-08-12. The project has **1,833 tracked directories**, and **1,646 are under
`darwin/`**: `darwin/Developer` alone is 761 directories, 2,806 files and 1,982 headers, and it is
load-bearing (`buck/generated/sdk_headers.bzl`, `sdk_framework_darwin_Developer.bzl`, `darwin/BUCK`
and `buck-src/BUCK` all name it). `darwin/frameworks` is 86 components and `private-frameworks`
56. That is the macOS surface Cider implements, so the count there is the product, not clutter.

**DONE.** Deleted `tools/` (22 files, all verified unreferenced by path), `.vscode/`, `outputs/`,
`misc/` (one logo, zero references, moved to `docs/`), `plan/` (retired into `docs/`), `.gdbinit`
(broken: it imports `gdb_maloader` from a `tools/` that does not exist), `CONTRIBUTORS.md`, three
empty directories (`build/`, `plan/`, and one named `<ciderd`) and a stray `.dfx-boot.log`.
`etc/` became `darwin/etc/`, which needed a `SOURCE_RENAMES` entry in the install generator and
was verified by regeneration rather than by inspection.

**REJECTED: `patches/` into `pins/`.** `pins/` is not a container, it is a NAMESPACE OF PIN NAMES,
and two places enumerate it: `nix/lib/ciderBuck2Lower.nix:1326` does
`builtins.readDir (projectSrc + "/pins")` and symlinks every entry as a pin, and
`scripts/buck-escape-roots-check.nu:24` computes "a readDir of pins minus the pin names" and
reports what is left. A `pins/patches/` would appear to both as a pin called `patches`. Moving it
to `nix/` instead would fit the applier in `nix/lib/cider-src.nix` but mischaracterise it, since
`scripts/buck-src.nu` applies patches too and is not Nix. It stays at the top level.

**NOT DONE, AND THE REASON IS VERIFICATION RATHER THAN EFFORT: `buck-src` + `buck-rust` + `pins`
into one `vendor/`.** Measured cost:

    buck-src   14,424 occurrences in 173 files   (11,818 of them under buck/)
    buck-rust      94 occurrences in  31 files
    pins/         418 occurrences in  48 files

Most of that is inside GENERATED files (`buck-src/BUCK` is 63,424 lines, `buck/prefix/BUCK` 4,336)
and the generators hardcode the prefix: `installgen.rs:840` and `:845` build labels as
`//buck-src/{pin}:` and `//buck-src:`. So the honest form of this change is to update the
generators, the materialization scripts, `.gitignore` and `.buckconfig`, then REGENERATE, which is
tractable and mechanical.

**What stops it today is that it cannot be proven.** A rename of this size is exactly the kind
that fails somewhere only a full build reaches, and the full build is blocker B0: it wedged. CI,
which would be the other way to prove it, has never run. Doing it now would mean making 14,424
edits and hoping. Sequence it after B0 has a clean-machine reproduction and CI is green, and the
same change becomes routine.

---

## Item 5, why the substituter queries are slow: three explanations killed, one left

Investigated 2026-08-12 at the user's request. No answer yet, but the field is much narrower and
the eliminations are each backed by a measurement rather than an argument.

**RATE LIMITING: REFUTED.** A sample build-trace URL returns a plain `404` in 0.13 s from
Cloudflare with no `429`, no `Retry-After` and no rate-limit headers of any kind.

**IPv6: REFUTED.** curl over BOTH protocols to cache.nixos.org and zed.cachix.org returns HTTP 200
in 0.05 to 0.08 s, and the box has a working default IPv6 route. This mattered enough to test
because the repo already records tangled.org timing out over IPv6.

**CPU STARVATION: REFUTED, properly this time.** An A-B-A with 24 CPU hogs against a live query
stream: **144 queries per 30 s, then 139 under load, then 146 after.** No effect. The earlier
"ruling out" of starvation was invalid because it watched the build log, which only prints on
derivation events and could not have responded within the window; this one watches the query
count, which can.

**QUERYING AT SCALE IS FAST HERE.** A `--dry-run` of nixpkgs#texliveFull enumerated **5,271 paths
to fetch** in under three minutes, and Cider's own build-trace lookups run at about 5 per SECOND.
So nothing about this machine makes nix queries slow in general.

**WHAT IS LEFT** is that the slow case was narinfo lookups DURING a Cider build, at 4 to 5 per
minute, while everything else measured is 60 to 3,600 times faster. Two candidates remain
untested: something specific to substituting CONTENT-ADDRESSED outputs, which is what Cider's
lowered derivations are (#55), and the narinfo disk cache, which was 40 KB, i.e. empty, so every
lookup was a network miss and a fresh insert.

**WHY IT IS NOT SETTLED: each attempt costs 15 minutes and my own commits invalidate the graph.**
Reaching the query phase needs the graph derivation, which takes 11 minutes 20 seconds to rebuild,
and any commit touching a non-excluded path forces that rebuild. Two attempts were spent this way.

## A NEW failure found while chasing item 5: the FULL prefix does not evaluate

`nix build .#cider-buck2-prefix` now dies in evaluation, before any building:

    error: attribute '"root//buck-src:pin-bootstrap_cmds"' missing
    at nix/lib/ciderBuck2Lower.nix:1483:46
      builderScript = builderScriptWith (d: "${drvs.${d}}");

A lowered derivation names a dependency for which no lowered derivation exists. `.#cider-buck2-
prefix-min` is unaffected and completes, which is what was verified for B0; the full prefix was
NOT re-verified today, so this went unseen. It is unknown whether it predates today's work or was
introduced by it, and that question is the first step rather than a guess.
