# A GENERAL BRIDGE FROM ACTION SPECS TO DYNAMICALLY EMITTED DERIVATIONS.
#
# Nothing here knows about cider. It takes a list of ACTIONS -- name, builder, args, env,
# inputs -- and returns a derivation that EMITS one .drv per action at BUILD time, plus the
# accessors a consumer binds through with builtins.outputOf. That is the whole point: the
# evaluator never computes those derivations, so their cost does not fall on every
# `nix build` invocation.
#
# It is buck2-SHAPED (an action is a command line with declared inputs and one output tree,
# which is what `buck2 log what-ran` gives you) but not buck2-BOUND: anything that can produce
# that list can use it. cider is the first consumer, not the target. See dyn-actions-adapter
# notes in #66 for the cider side, which is deliberately elsewhere.
#
# IT DOES A DAG, not just a set: an emitted action CAN consume another emitted action's
# output. Name the producing action's entry from `outputs` in your args, and DECLARE IT in
# `inputSrcs`. Both halves are required -- naming it alone gets you a build that runs in the
# right ORDER and still cannot see the file. Proven by nix/lib/dyn-actions-dep-probe.nix,
# which prints B-SEES-A with the dependency's contents, and B-BLIND if the declaration is
# dropped.
#
#   { name = "b"; args = ["-c" "... ${a.outputs.a} ..."]; inputSrcs = [a.outputs.a]; }
#
# THE CONSTRAINT THAT SHAPES THE WHOLE DESIGN, and it is not a detail:
#
#   A .drv-named derivation must be a text-hashed CA output with a SINGLE output named "out".
#   Nix enforces both, separately. Meanwhile `builtins.placeholder "out"` is a constant of the
#   OUTPUT NAME rather than of the derivation, so an emitted action whose output is ALSO
#   called "out" embeds the exact string the producer uses for its own output, and text
#   hashing rejects it with "self-reference not allowed with text hashing".
#
#   So EVERY EMITTED ACTION NAMES ITS OUTPUT `outputName` BELOW, never "out". A caller cannot
#   opt out of that, which is why it is not an argument.
#
# See nix/lib/dyn-drv-probe.nix for the minimal worked example and the plumbing traps
# (NIX_REMOTE=daemon BREAKS recursive-nix; nix must come through pkgs or it is absent from the
# sandbox; experimental features are not inherited by the inner nix).
#
# TWO WAYS TO SUPPLY AN ACTION, and the second is the one that scales.
#
#   `actions`   a list of attrsets. Nix serialises each spec at EVAL time. Fine for a handful,
#               and it is what the toy fixture uses.
#   `specDir`   a directory holding one pre-serialised <name>.json per action, plus a
#               `names` file listing them. Nix then does NO per-action serialisation: it only
#               builds a cheap producer pointing at a path.
#
# WHY THAT DISTINCTION EXISTS, measured on cider's own graph 2026-08-11. Its endpoint eval is
# about 15 s and splits into 0.21 s to readFile a 139 MB graph.json, about 2.1 s to fromJSON
# it, and about 12.95 s to COMPUTE its 1,474 derivations. That computing is what #66 removes,
# so an adapter that made Nix re-serialise every action would hand most of it straight back.
# The generator already runs inside the graph derivation and can write the specs itself, which
# is what "emit drvs from the generator" actually means.
#
# ONE CORRECTION TO AN EARLIER NUMBER HERE, since it was quoted in three files: the 12 s is
# the cost of the DERIVATIONS, not of rendering their action scripts. Moving just the script
# rendering out was measured at 2.2 s, and reading it back costs 1.5 s. The derivations
# themselves are where the remaining time is, which is what this file is for.
{
  pkgs,
  # [{ name; builder; args; env ? {}; inputSrcs ? []; }]
  # `name` must be unique across the list: it is both the derivation name and the key the
  # consumer looks the action up by.
  actions ? null,
  # A path holding <name>.json per action and a `names` file, one name per line. Mutually
  # exclusive with `actions`.
  specDir ? null,
  # The output every emitted action uses. NOT "out", for the reason in the header. Exposed so
  # a caller can avoid a collision with something in their own env, not so they can pick "out".
  outputName ? "result",
}: let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;

  assertNotOut =
    lib.throwIf (outputName == "out")
    ''
      dyn-actions: outputName cannot be "out". builtins.placeholder "out" is a constant of the
      output name, so an emitted action using it embeds the producer's own output placeholder
      and Nix rejects the result with "self-reference not allowed with text hashing".
    '';

  assertOneSource =
    lib.throwIf ((actions == null) == (specDir == null))
    "dyn-actions: supply exactly one of `actions` or `specDir`";

  # With specDir the names come off disk and NO spec is serialised in the evaluator, which is
  # the whole reason that mode exists. See the header for the measurement.
  fromDir = specDir != null;
  names =
    if fromDir
    then lib.filter (s: s != "") (lib.splitString "\n" (builtins.readFile "${specDir}/names"))
    else map (a: a.name) actions;

  assertUnique =
    lib.throwIf (lib.length (lib.unique names) != lib.length names)
    "dyn-actions: action names must be unique; they key the consumer lookup";

  # THE ENV VAR AN ACTION READS A DEPENDENCY THROUGH. Names are free-form -- a buck2 label, a
  # path, anything -- and a shell variable name is not: it is [A-Za-z_][A-Za-z0-9_]*. The first
  # version interpolated the name raw, so `dag-alpha-dag1` became $DYN_DEP_dag-alpha-dag1,
  # which the shell reads as $DYN_DEP_dag followed by the literal text "-alpha-dag1". It
  # EXPANDS TO EMPTY rather than failing, so the dependent action ran, produced an empty
  # result, and only a fixture that checked the CONTENT caught it.
  #
  # Exposed as `depVar` in the result so a caller can name the variable it has to read without
  # reimplementing this, which would be the same bug again one file over.
  depVar = name:
    "DYN_DEP_"
    + lib.stringAsChars (c:
      if (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
      then c
      else "_")
    name;

  # One action as the JSON `nix derivation add` accepts. Keep this the ONLY place that knows
  # the on-disk derivation format.
  specOf = a:
    builtins.toJSON {
      inherit system;
      inherit (a) name;
      builder = a.builder;
      args = a.args;
      env =
        (a.env or {})
        // builtins.listToAttrs (map (d:
          lib.nameValuePair (depVar d) outputs.${d})
        (a.deps or []))
        // {
          inherit (a) name;
          builder = a.builder;
          ${outputName} = builtins.placeholder outputName;
          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          inherit system;
        };
      # inputs.drvs STAYS EMPTY and that is not the limitation it looks like. A dependency on
      # another emitted action is expressed through srcs, not drvs: by the time this spec
      # reaches `nix derivation add`, the outer Nix has already substituted the dependency's
      # outputOf placeholder with a real, realised store path, so it is an ordinary source.
      # nix/lib/dyn-actions-dep-probe.nix holds the measurement and the two dead ends.
      inputs = {
        drvs = {};
        # FULL PATHS HERE, TURNED INTO BASENAMES AT BUILD TIME by the producer below, and
        # both halves of that are forced.
        #
        # `nix derivation add` wants `<hash>-<name>` relative to the store directory: given a
        # full path it fails with "contains illegal base-32 character '/'". So inputSrcs could
        # never have worked as written, and nothing noticed because the toy actions declare
        # none. Verified by feeding it both forms; only the basename is accepted.
        #
        # BUT THE CONVERSION CANNOT HAPPEN HERE. An entry may be another action's output,
        # which at eval time is a builtins.outputOf PLACEHOLDER; the outer Nix substitutes the
        # real path only when the producer runs, and it matches the placeholder text exactly.
        # Taking baseNameOf, or discarding the context, mangles that text so the substitution
        # never happens and the emitted drv names a path that "is not valid". Measured both
        # ways 2026-08-11.
        #
        # `deps` is the same mechanism with the plumbing done for you: it names OTHER ACTIONS
        # rather than store paths, and each becomes both a source here and a DYN_DEP_<name>
        # entry in the emitted action's env, so the action can find its dependency without the
        # caller having to thread outputOf strings through itself. It is what makes specDir
        # mode usable for a DAG, where the spec is a static file and the caller has no chance
        # to interpolate anything.
        srcs = (a.inputSrcs or []) ++ map (d: outputs.${d}) (a.deps or []);
      };
      outputs.${outputName} = {
        hashAlgo = "sha256";
        method = "nar";
      };
      version = 4;
    };

  # One producer per action. Deliberately NOT one producer emitting all of them: a single
  # producer would rebuild every .drv whenever any action changed, which throws away the early
  # cutoff that makes this worth doing at all. Per action, a changed action re-emits only its
  # own drv and every other consumer stops at the cutoff.
  # How the builder gets its spec. In specDir mode Nix NEVER reads or serialises it: the
  # interpolation is a store path, so the evaluator's whole job per action is one cheap
  # derivation. That is the difference between this scaling and not.
  writeSpec = n:
    if fromDir
    then "cp ${specDir}/${n}.json spec.json"
    else "printf '%s' ${lib.escapeShellArg (specOf (actionOf n))} > spec.json";

  actionOf = n:
    lib.findFirst (a: a.name == n)
    (throw "dyn-actions: no action named ${n}")
    actions;

  producerOf = n:
    derivation {
      inherit system;
      name = "${n}.drv";
      builder = "/bin/sh";
      args = [
        "-c"
        ''
          export PATH=${pkgs.nix}/bin:${pkgs.coreutils}/bin:${pkgs.python3}/bin:$PATH
          ${writeSpec n}
          # inputs.srcs must be store-dir-relative, and it can only be made so HERE: at eval
          # time an entry may still be an outputOf placeholder that the outer Nix has not
          # substituted yet. See the srcs comment in specOf.
          python3 -c 'import json,sys
p=sys.argv[1]
d=json.load(open(p))
s=d.get("inputs",{}).get("srcs",[])
d["inputs"]["srcs"]=[x.rsplit("/",1)[-1] for x in s]
json.dump(d,open(p,"w"))' spec.json
          emitted=$(nix --extra-experimental-features \
            "nix-command ca-derivations dynamic-derivations" derivation add < spec.json) \
            || { echo "dyn-actions: derivation add failed for ${n}" >&2; exit 1; }
          cp "$emitted" "$out"
        ''
      ];
      __contentAddressed = true;
      outputHashMode = "text";
      outputHashAlgo = "sha256";
      requiredSystemFeatures = ["recursive-nix"];
    };

  producers = lib.listToAttrs (map (n: lib.nameValuePair n (producerOf n)) names);

  # What a consumer binds to: the OUTPUT of the dynamically emitted derivation. This is the
  # string that lets the evaluator not know the derivation.
  #
  # IT LIVES IN THE let, NOT ONLY IN THE RESULT, because specOf needs it: `deps` resolves an
  # action name to this. Nix ties the knot lazily, so an action referring to another action's
  # output is fine as long as the dependency graph is ACYCLIC. A cycle here surfaces as a bare
  # infinite recursion with nothing pointing at the two actions responsible.
  outputs =
    lib.mapAttrs
    (n: p: builtins.outputOf p.outPath outputName)
    producers;

  # A DERIVATION HOLDING THIS ACTION LIST AS A SPEC DIR, in exactly the layout specDir mode
  # reads back: one <name>.json per action plus a `names` index.
  #
  # WHY IT IS HERE rather than in a consumer: specOf is meant to be the only place that knows
  # the on-disk derivation format, and a consumer writing that JSON by hand would be a second
  # place to keep in step. It is also what makes specDir mode TESTABLE at all -- until this
  # existed, nothing in the repo produced a spec dir, so half the bridge's API had been
  # evaluated and never built. nix/lib/dyn-actions-specdir-toy.nix round-trips through it.
  #
  # IT SERIALISES AT EVAL, so it is for reference, tests, and small action lists. Using it for
  # a large one hands back exactly the cost specDir mode exists to avoid: a consumer with
  # thousands of actions should write the same JSON from its own generator, inside a
  # derivation, and pass that directory instead.
  mkSpecDir = drvName:
    lib.throwIf fromDir
    "dyn-actions: mkSpecDir needs `actions`; in specDir mode you already have one"
    (pkgs.runCommand drvName {} (''
        mkdir -p "$out"
      ''
      + lib.concatMapStrings (n: ''
        printf '%s' ${lib.escapeShellArg (specOf (actionOf n))} > "$out"/${lib.escapeShellArg n}.json
      '')
      names
      + ''
        printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep "\n" names)} > "$out/names"
      ''));
in
  assertOneSource (assertNotOut (assertUnique {
    # The emitted .drv per action, before realisation. Useful for inspection and for tests.
    inherit producers;

    inherit outputs outputName mkSpecDir depVar;
  }))
