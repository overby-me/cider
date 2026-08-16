# Upstreaming the buck2 Nix integration to the overby.me monorepo

**STATUS: MEASURED AND PREPARED. NOTHING PUSHED, AND THE MONOREPO CHECKOUT WAS ONLY READ.**
Landing needs one command in a repository this one does not own, so it is the user's to run.
Everything below is the work that has to exist before that command is safe.

## Where the integration lives

`nix/lib/buck2` in the monorepo is **nix-buck2**: a Nix builder for Buck2 projects that parses
`.buckconfig` and the `BUCK`/`.bzl` Starlark at EVALUATION time and lowers each Buck2 action to
its own derivation, with no import-from-derivation and no `buck2` binary in the loop. It stands
on the reusable Starlark interpreter in `nix/lib/skylark`.

Cider consumes it through `nix/lib/ciderBuck2.nix`, from five attributes in `flake.nix`, and
pins the monorepo at `main`, revision `bc895a2d`.

**IT IS PINNED AS `flake = false`, WHICH IS THE FACT THAT MAKES THIS SMALL.** The monorepo is
consumed as a plain SOURCE TREE and instantiated with Cider's own `pkgs`, so none of its roughly
30 transitive flake inputs enter this lock. The consequence is worth stating because it removes
an entire class of risk from the landing below: the 621 commits `main` has taken since this work
branched, and any nixpkgs bump among them, **cannot reach Cider through this input.** Only the
files under `nix/lib/buck2` and `nix/lib/skylark` can.

## What has not landed: four commits

They are on the monorepo bookmark `nix-lib-buck2`, and `flake.nix:76` in this repo still tells a
reader to reach them with `--override-input`.

| Commit | What it does | Why this port needed it |
|---|---|---|
| `feat(nix/lib): Teach buck2 read_root_config, symlinked_dir, copy and ar` | Four missing primitives | A real project configures its toolchain through `read_root_config`, and `symlinked_dir`, `copy` and `ar` are three of the action kinds Cider's graph is made of |
| `fix(nix/lib): Make skylark iterate where it recursed, so big files parse` | Parser recursion to iteration | Cider's generated `BUCK` files are large enough to overflow the parser |
| `fix(nix/lib): Materialize a source when it is the target's own output` | `export_file`'s default output IS its source, so no action produces it, and asking which one did failed before it could say why | Every `export_file` Cider uses to hand a file across a package boundary |
| `fix(nix/lib): Fold the interpreter's loops so real BUCK files do not overflow` | `for` and comprehensions recursed once per ITERATION, and Nix has no tail-call elimination, so a loop was a max-call-depth error rather than a slow evaluation. Now `foldl'`, with a done flag for early exit and forcing of the accumulated list and env | Iterating the SDK header maps (4,178 entries) and one `export_file` per entry of a per-pin list (xnu: 1,252) |

**NONE OF THE FOUR IS CIDER-SPECIFIC**, which is the case for landing them rather than carrying
them. `read_root_config`, `symlinked_dir`, `copy` and `ar` are core Buck2; the loop folding is
about any project with a generated map; the `export_file` fix is about any cross-package file
handoff. Cider is the evidence that they are needed, not the reason they exist.

## Landing is conflict free, and that is measured rather than assumed

    jj log -r 'main..nix-lib-buck2'                          4 commits
    jj log -r 'nix-lib-buck2..main'                          621 commits, all web and wiki work
    jj log -r 'nix-lib-buck2..main & files("nix/lib/buck2" | "nix/lib/skylark")'
                                                             NOTHING

The branch is 621 behind, which normally means a stale branch is a rebase problem. Here it does
not: **no commit on `main` since the branch has touched either directory**, so the rebase has
nothing to conflict with. The eleven changed files (`nix/lib/buck2/{build/lower.nix,
build/toolchains.nix,lib/actions.nix,lib/analyze.nix,lib/globals.nix,lib/loader.nix,
lib/serialize.nix}` and `nix/lib/skylark/{eval,lexer,parser,values}.nix`, 451 insertions and 140
deletions) are the branch's alone.

The procedure, to be run IN THE MONOREPO, by its owner:

    jj rebase -b nix-lib-buck2 -d main
    jj bookmark set main -r nix-lib-buck2
    jj git push --bookmark main

Then in this repository: update the `overby` input, and delete the `--override-input` paragraph
at `flake.nix:76`, which stops being true the moment this lands.

## What has to be re-verified, and what was actually verified here

The last commit's message states "skylark-lib and buck2-build-cpp pass". That was true 621
`main` commits ago, and those are the monorepo's own checks, so they are the owner's to re-run
after the rebase.

What could be checked from this side, and was:

    nix build .#cider-buck2-libsimple --override-input overby <the local branch>

That is the real end-to-end consumer test of all four commits: the smallest Buck2 target in this
port (one C source, one include root, one archive action) taken through the Nix-lowered path,
which exercises load, rule, provider, glob and three action kinds. Because the input is a source
tree rather than a flake, this result carries over to the landed state unchanged.

**RESULT, 2026-08-12 22:50: EXIT 0.** It lowered and built four derivations, and their names are
the evidence that the four commits are the thing under test rather than something cached around
them:

    buck2---darwin-libsimple-libsimple_ciderd-symlinked_dir0
    buck2---darwin-libsimple-libsimple_ciderd-run1
    buck2---darwin-libsimple-libsimple_ciderd-run2
    buck2---darwin-libsimple-libsimple_ciderd

`symlinked_dir` is one of the four primitives the first commit adds, and the run actions are
reached through the toolchain the same commit taught to read `read_root_config`. Run with
`--option substituters ""`, so nothing here was substituted.

This does NOT cover the whole library: it is one small target, and `select()` and `//...`
discovery are unimplemented upstream anyway. It covers the consumer path this repo depends on.

## Appendix: two buck2 limitations that shaped this integration

Measured first-hand on 2026-08-12 against buck2 unstable-2026-04-15, the nixpkgs binary this repo
builds with, using one command:

    buck2 aquery --output-all-attributes --json 'deps(//src/darwin/libsimple:libsimple_ciderd)'

These are recorded because they explain why the integration is shaped the way it is, not as a
plan to file anything.

**`cmd` comes back as a JSON string, not an array.** The argv is joined with `", "` inside
brackets, which is a debug rendering of a list:

    "cmd": "[clang, -DLIBSIMPLE_LINUX=1, -Ibuck-out/v2/art/root/.../libsimple_ciderd__include, -c, src/darwin/libsimple/src/lock.c, -o, buck-out/...]"

Asking for JSON therefore buys nothing over the plain output, and splitting it back apart is
sound only while no argument contains the separator. One did: perl's `versions.h` passed the C
initializer `"5.18", "5.28",` as ONE argument and it came back as TWO. The signature of the class
is that **buck2 itself built it correctly the whole time**; only a consumer that round-trips
through the rendering ever saw a different command. `scripts/checks/buck-argv-roundtrip-check.nu` guards
both halves of that assumption, and one half needs no build.

**No action states its inputs or outputs.** On this release the fields are not empty, they are
absent. The complete attribute set is `kind`, `category`, `identifier`, `cmd` and executor knobs.
It is worst for the kinds buck2 performs in process, where there is no argv to fall back on: a
staged include root, which every compile in the target points `-I` at, comes back as

    {"kind": "symlinkeddir", "category": "symlinked_dir", "identifier": "libsimple_ciderd__include",
     "buck.executor_configuration": "Local + use persistent workers true",
     "buck.all_outputs_are_content_based": "false",
     "buck.all_inputs_are_eligible_for_dedupe": "true"}

and that is the entire node. Nothing computed from argvs alone would stage a single header, which
is why the endpoint reads the materialized tree from disk and records a link table beside the
graph, and why `buck2 audit output` is needed to tell an action's own outputs from what it
consumes. It also has a design consequence in this repo: **a guest Rust crate must be ONE FILE**,
with submodules inlined, because a `mod` in its own file is an input that appears in no argv and
in no attribute, and would be silently missing when the action is replayed.

For the record, since it was checked: the inputs half is already reported upstream as
[facebook/buck2#475](https://github.com/facebook/buck2/issues/475), opened 2 November 2023 and
closed with no maintainer reply. Nothing was filed, and nobody was contacted.
