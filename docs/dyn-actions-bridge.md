# The action-graph to dynamic-derivation bridge

`nix/lib/dyn-actions.nix` turns a list of build actions into one Nix derivation per action,
emitted at BUILD time rather than computed by the evaluator, plus the accessors a consumer binds
through with `builtins.outputOf`.

It is buck2-SHAPED, in that an action is a command line with declared inputs and one output
tree, which is what `buck2 log what-ran` gives you. It is not buck2-BOUND: anything that can
produce that list can use it. This repo is its first consumer, not its target, and nothing in
the reusable half references anything outside itself. That is enforced rather than asserted, by
`scripts/buck-bridge-generality-check.py`.

## What you need on the nix side

    --extra-experimental-features "nix-command ca-derivations dynamic-derivations recursive-nix"

`NIX_REMOTE=daemon` BREAKS recursive-nix, which supplies its own socket at
`unix:///build/.nix-socket`. Unset it.

## The constraint that decides the whole design

A `.drv`-named derivation must be text-hashed content addressed with a SINGLE output named
`out`. Meanwhile `builtins.placeholder "out"` is a constant of the OUTPUT NAME rather than of
the derivation, so an emitted action whose output is ALSO called `out` embeds the exact string
its own producer uses for its output, and text hashing rejects that as a self-reference.

So every emitted action names its output something else. The default is `result`, and a caller
cannot opt out. An emitted action therefore writes to `$result`, not `$out`.

`nix/lib/dyn-drv-probe.nix` is the minimal worked example.

## Two ways to supply actions

    actions   a list of attrsets. Nix serialises each spec at EVAL time. Fine for a handful.
    specDir   a directory of <name>.json, a `names` index, and a `deps.json`. Read at BUILD
              time, so a generator can write them and the evaluator never sees them.

`specDir` is the one that scales, and it is the point: a generator can write those files inside
a derivation that already runs, once, instead of the evaluator rebuilding them on every
invocation.

A spec dir needs only `name`, `builder` and `args` per action. The system, the version, the
outputs and the output PLACEHOLDER are filled in when the producer runs, because a generator
cannot honestly supply them: the placeholder is a Nix construction and the system belongs to
whoever is building. `nix/lib/dyn-actions-minimal-spec-toy.nix` is a spec dir written with
`toJSON` and nothing from the bridge.

## Getting values into an action

An emitted action is NOT a `runCommand`. It gets no stdenv: no PATH, no `set -e`, no setup
hooks, and its output variable is `result`. Three ways to give it what it needs:

    deps        names of OTHER ACTIONS. Each becomes a source AND a DYN_DEP_<name> env entry,
                so an action can find its dependency without anyone interpolating a path. This
                is what makes a DAG expressible when the spec is a static file.
    extraEnv    values the CONSUMER knows and the spec cannot name: a toolchain, a staging
                script, a data tree. Either an attrset, applied to every action, or a FUNCTION
                from action name to attrset, which is the general case. Every store path a
                value names is declared as a source.
    inferSrcs   declare every store path the args NAME as a source. For the caller whose inputs
                live in a SCRIPT rather than in a list. Over-declaring is safe and
                under-declaring is not, so this is the forgiving setting and is off by default.

Use `depVar` to build the variable name: action names are free-form and shell variable names
are not, and a mismatch does not fail. The variable is simply never set, expands to EMPTY, and
the action runs against nothing and produces a plausible, wrong result.

## Limits found by a real consumer, which toys did not reach

**A single argument can be too long to pass.** Linux caps one argv or env string at
MAX_ARG_STRLEN, 32 pages, 131,072 bytes. That is NOT `ARG_MAX`, the 2 MB total. In this repo 89
of 1,474 action scripts exceed it and the largest is 5.1 MB. The bridge handles it: specs travel
through a store file rather than through the producer's own command line, and an over-long `-c`
argument is spilled to a store file and becomes `. <path>`, which is equivalent for a shell.
Only a `-c` argument is rewritten, because only there is the argument known to BE a shell
script; any other over-long argument is a named error rather than a guess.

**stdenv's SETUP SCRIPT sets things its derivation does not.** An emitted action has no setup
script, so anything exported there is simply absent, and it is absent invisibly: it does not
appear in the lowered derivation's env either, so comparing the two derivations does not reveal
it. Enumerated from `$stdenv/setup` rather than guessed, the ones that can change build output
are `SOURCE_DATE_EPOCH`, `TZ=UTC`, `GZIP_NO_TIMESTAMPS`, `SHELL` and `CONFIG_SHELL`, and the
`NIX_ENFORCE_*` pair.

Only `SOURCE_DATE_EPOCH` actually mattered here, and that is a measurement rather than an
assumption: a full-graph diff of both routes found three binaries differing and all three by
`__DATE__`. The `NIX_*` variables made no difference because these actions invoke a raw clang
ELF directly rather than the nixpkgs cc-wrapper, which is the script that reads them. Do not
add the rest speculatively, since every one of them rewrites every emitted derivation; add one
when a difference points at it.

**`lib.makeBinPath` is not a PATH.** It adds each package's own `bin` and follows neither setup
hooks nor propagation. `llvm-ar` lives in the unwrapped bintools package and reaches PATH only
through the wrapper's setup hook, which an emitted action never runs. If you want what stdenv
would have supplied, name `stdenv.initialPath` rather than writing the list out: a hand-written
one here was missing `xz`, `bzip2`, `gnumake` and `file`, and the first of those surfaced 981
builders into a full-graph build.

## Checking it

`scripts/buck-dyndrv-check.nu` covers eleven properties over ten fixtures and is controlled
both ways. TEN are asserted; the eleventh, that a substituted output resolves, is reported as a
NOTE because it is not automated, and its by-hand sequence is in the runner header. Counted
from the runner rather than from memory: ten `ok` lines and one `note`.

Several of those properties were FALSE when first checked and none of them had a fixture, so
none could have been noticed: the DAG edge, the whole of `specDir` mode, and `specDir` plus a
DAG. Fixtures must check CONTENT, never path existence, because both of those
bugs produced clean successful builds with empty results.
