# Two things to upstream to buck2

**STATUS: PREPARED, NOT FILED.** Nothing here has been sent anywhere, no issue or pull request
has been opened against facebook/buck2, and nobody has been contacted. This is the write-up that
would have to exist first, held to the standard that a maintainer reading it cold can reproduce
every claim without knowing what Cider is.

Both findings are about the same thing: **buck2 can build the graph but cannot hand it to you as
data.** That matters here because the Nix endpoint does not run buck2 at build time. It reads the
action graph once and replays it as one derivation per target, so every fact buck2 will not state
in machine-readable form has to be reconstructed by us, and each reconstruction is an assumption
that can be wrong.

Measured 2026-08-12 against **buck2 unstable-2026-04-15**, the nixpkgs binary this repo builds
with. Re-measure before filing: the release is four months old and either of these may have moved.

The one command behind everything below:

```
buck2 aquery --output-all-attributes --json 'deps(//darwin/libsimple:libsimple_ciderd)'
```

`//darwin/libsimple:libsimple_ciderd` is the small probe target: one C source, one include root,
one archive action. Four action nodes come back.

---

## Finding 1: aquery renders an action command as a string, so the argv cannot be recovered

`--output-all-attributes --json` returns `cmd` as a JSON **string**, holding the argv joined with
`", "` inside square brackets, which is the Rust debug rendering of a list rather than a list:

```json
"cmd": "[clang, -DLIBSIMPLE_LINUX=1, -Ibuck-out/v2/art/root/.../libsimple_ciderd__include, -c, darwin/libsimple/src/lock.c, -o, buck-out/...]"
```

Asking for JSON therefore buys nothing over the plain output: it is the identical rendering
wrapped in quotes, separator and all. There is no other attribute carrying the argv.

**THIS IS LOSSY, AND IT HAS BEEN LOSSY IN PRACTICE, ONCE.** Splitting that string back apart is
sound only while no single argument contains `", "`. In this port one did: perl's `versions.h`
generation passed the C initializer

```
 "5.18", "5.28",
```

as ONE argument, it came back as TWO, and the replayed command died in the consuming script. The
signature is worth naming because it is what makes this class expensive to find: **buck2 itself
built it correctly the entire time.** Only the consumer that round-trips through the rendering
ever saw a different command, so the bug is invisible from inside buck2 and looks like a bug in
the consumer.

**THE OTHER ROUTES WERE TRIED AND DO NOT REPLACE IT.**

| Route | Why it does not answer |
|---|---|
| BXL, `ctx.aquery().all_actions()` | An `ActionQueryNode` exposes `["action", "analysis", "attrs", "rule_type"]`. Its `attrs.cmd` is the same debug string, and `.action` is an opaque handle whose `dir()` is empty. Recorded in `buck/bxl/probe.bxl`, which exists to print exactly this. |
| `buck2 log what-ran --format json` | Does carry the real argv, as a list, at `.reproducer.details.command`. But the log is per invocation and lists only actions that **executed**. Analysis executes nothing, so using it as the source means compiling the whole graph before you can learn what the graph is, which is the thing the endpoint exists to avoid. |

**THE ASK:** in `--output-all-attributes --json`, emit `cmd` as a JSON array of the argv elements,
or add a second attribute (`argv`) that is one. The information is present, unambiguous, and
already flows through `what-ran` in list form; only the query rendering discards its structure.

**PRIOR ART: none found.** No upstream issue found for the command rendering as of 2026-08-12.

**WHAT WE DO MEANWHILE**, so this is a robustness request rather than an outage report: the
dumper splits on `", "` (`unjoin` in `linux/buildtools/graph-specs/src/dump.rs`), and
`scripts/buck-argv-roundtrip-check.nu` guards the assumption in two halves. One compares the
recovered argv against `what-ran`'s real list, importing `unjoin` rather than reimplementing it so
that the check tests the shipping code path. The other, which the test suite runs and which needs
no build, asserts that no string literal anywhere in the tree that becomes an argv element
contains the separator. Exactly one ever did, and the rule that produced it now passes its values
through a file, so that one is safe by construction rather than by vigilance.

---

## Finding 2: aquery states no inputs and no outputs for any action

The four nodes returned for the probe target carry these attributes, and this is the complete
list, counted over the nodes that have each:

```
kind                                  4
category                              3
identifier                            3
buck.executor_configuration           3
buck.all_outputs_are_content_based    3
buck.all_inputs_are_eligible_for_dedupe  3
cmd                                   2
executor_preference, always_print_stderr, weight, dep_files, metadata_param,
no_outputs_cleanup, allow_cache_upload, allow_dep_file_cache_upload,
buck.all_ineligible_for_dedup_inputs  2
```

There is **no `inputs` field and no `outputs` field at all.** Not empty ones: absent. So aquery
will tell you an action exists, what kind it is and what it runs, but not one artifact it reads
or writes.

**THE WORST CASE IS THE ACTION THAT HAS NO COMMAND EITHER.** buck2 performs some actions in
process, and for those the argv cannot stand in for the inputs, because there is no argv. A staged
include root comes back complete, as:

```json
{"kind": "symlinkeddir", "category": "symlinked_dir", "identifier": "libsimple_ciderd__include",
 "buck.executor_configuration": "Local + use persistent workers true",
 "buck.all_outputs_are_content_based": "false",
 "buck.all_inputs_are_eligible_for_dedupe": "true"}
```

That is the entire node. A directory of headers that every compile in the target points `-I` at,
and the query does not name a single file in it, nor the tree it was made from. Nothing computed
from argvs alone would stage one header, because no argv mentions one.

**WHAT WE HAD TO BUILD INSTEAD**, which is the measure of the gap:

* `buck2 audit output <path>` per artifact, to learn which action produced a `buck-out` path.
  That is what separates an action's own outputs from the artifacts it consumes, and no argv
  makes the distinction.
* A custom BXL script (`buck/bxl/materialize.bxl`) that walks the configured dep graph, reads our
  own providers, and ensures the artifacts they carry, because `buck2 build <target>` materializes
  only the target's default output. An artifact reachable through no subtarget is simply absent
  otherwise: `darling-config.h`, produced by action id 2 of one target, is the case that proved
  it, and dropping the provider walk silently lost 18 staged artifacts and 11 farms while the
  dump still exited 0.
* Walking the materialized `buck-out` tree on disk afterwards to recover what is in each staged
  directory, and recording it as a link table beside the graph. The filesystem is the only place
  that answer exists.

There is a second-order cost worth stating, since it is what convinces a maintainer this is not
cosmetic: **a hidden input cannot be detected, so the build definition has to be distorted to
avoid having any.** Guest Rust crates in this port must be a single file, with submodules inlined
as `mod x { ... }`, because a `mod` in its own file is an input that appears in no argv, in no
attribute, and in no query output. If it were missed, the action would be replayed without it.

**PRIOR ART: this is already reported and got no answer.**
[facebook/buck2#475](https://github.com/facebook/buck2/issues/475), "`buck2 aquery` doesn't seem
to list inputs or outputs", opened 2 November 2023, **closed with no maintainer reply, no label
and no linked change.** The reporter described the fields as empty; on unstable-2026-04-15 they
are not present at all. So a new report should not restate the question, it should supply what
that one lacked: a reproducer, the in-process case above, which is strictly worse than the case
that was reported, and a concrete ask.

**THE ASK:** expose each action's declared input and output artifacts in aquery output, including
for in-process kinds (`symlinked_dir`, `write`, `copy`) where they are the only description of the
action that can exist. buck2 holds them; the action cannot be scheduled otherwise.

---

## Before filing

1. **Re-measure on current buck2.** Everything above is unstable-2026-04-15. Both findings must be
   re-confirmed against the newest release, and the claim "no upstream issue" re-checked.
2. **Write a reproducer that is not Cider.** A maintainer should not have to clone this. Both
   findings reproduce on a project of two files:

   ```
   # BUCK
   cxx_binary(name = "hello", srcs = ["hello.c"])
   ```
   ```
   buck2 aquery --output-all-attributes --json 'deps(//:hello)'
   ```

   The compile node shows `cmd` as a string; no node has `inputs` or `outputs`. Finding 2 wants
   one more line in the reproducer, a rule with a `symlinked_dir` or a `write`, to show the action
   that has no `cmd` to fall back on.
3. **File them separately.** They have different asks and different prior art. Finding 1 is a
   rendering change; finding 2 is a data-model gap with a three-year-old closed issue behind it.
4. **Lead with the reproducer and the ask, not with the port.** What this repo does with the graph
   is motivation, and it is unusual enough to be a distraction.

Not a precondition, but worth knowing: buck2's own crates are not vendored here, buck2 arrives as
a nixpkgs binary, so a patch would mean pinning and building an external Rust workspace against
the exact binary this repo runs. Reporting is cheap; fixing it ourselves is not.
