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


**B1. DONE 2026-08-12 (4f7e30082b64). Reconnect CI to reality.** Point it at the branch the work is on (or land the work on main),
and name attributes that exist. It should at minimum evaluate every advertised output and build
the one a user is told to build. Both breaks above are exactly what that would have caught.

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
    ld64                 built by buck2 since #65; whether it emits arm64 Mach-O is UNMEASURED
                         and is the first thing to check, because everything else depends on it

**The honest unknown.** Nothing here says what the GUEST side costs: duct-tape, mldr and the
syscall layer all assume x86_64 register layout, and that was not measured today because it needs
reading rather than counting. Budget for that separately.
