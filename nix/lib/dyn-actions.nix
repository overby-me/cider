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
  # Declare every store path the args NAME as a source, in addition to inputSrcs and deps.
  #
  # FOR THE CALLER WHOSE INPUTS LIVE IN A SCRIPT rather than in a list. An action assembled
  # from an existing build script carries its paths inside the string: Nix string context
  # brings them along, the outer Nix substitutes them when the producer runs, and there is no
  # earlier point at which the caller could enumerate them. See the fixup script.
  #
  # OFF BY DEFAULT. Over-declaring is safe and under-declaring is not, so this is the forgiving
  # setting, and a caller that knows its inputs exactly should say so and get an error when it
  # is wrong rather than have the mistake papered over.
  inferSrcs ? false,
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
      # NO deps HANDLING HERE. They are injected by dyn-actions-spec-fixup.py when the producer
      # runs, in BOTH modes, because in specDir mode this function is never called: the spec is
      # a file the producer copies without anyone parsing it. Doing deps in two places would be
      # two implementations of one rule, and they would drift.
      env =
        (a.env or {})
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
        # rather than store paths, and each becomes both a source AND a DYN_DEP_<name> entry in
        # the emitted action's env, so the action can find its dependency without the caller
        # threading outputOf strings through itself. That is what makes specDir mode usable for
        # a DAG, where the spec is a static file nobody parses.
        #
        # deps are appended by dyn-actions-spec-fixup.py rather than here, precisely BECAUSE
        # specDir mode never calls this function.
        srcs = a.inputSrcs or [];
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
  # chmod, BECAUSE A STORE FILE IS 444 AND cp KEEPS THAT. The fixup step below rewrites
  # spec.json in place, so an unwritable copy makes it die with PermissionError.
  #
  # THAT FAILED SILENTLY BEFORE, which is the more useful half of this note. The fixup used to
  # be an inline `python3 -c` with no error check, so in specDir mode it crashed, the shell
  # carried on, and `nix derivation add` read the UNFIXED spec. For actions with no sources
  # that spec is perfectly valid, so the specdir fixture passed while the step it depended on
  # was not running at all. It only surfaced once the step was given `|| exit 1` and an action
  # that actually needed it.
  writeSpec = n:
    if fromDir
    then "cp ${specDir}/${n}.json spec.json && chmod u+w spec.json"
    else "printf '%s' ${lib.escapeShellArg (specOf (actionOf n))} > spec.json";

  actionOf = n:
    lib.findFirst (a: a.name == n)
    (throw "dyn-actions: no action named ${n}")
    actions;

  # WHICH ACTIONS EACH ACTION DEPENDS ON, from whichever mode is in use. In specDir mode it is
  # a deps.json beside the specs, because the spec files themselves are copied without being
  # parsed and so cannot carry it. The file is OPTIONAL: a spec dir of independent actions is
  # perfectly valid and predates this, so its absence means no dependencies rather than an
  # error. One readFile for the whole map, which is the point -- per-action reads out of a
  # deferred output cost about 13 ms each, measured.
  depsMap =
    if fromDir
    then
      (
        if builtins.pathExists "${specDir}/deps.json"
        then builtins.fromJSON (builtins.readFile "${specDir}/deps.json")
        else {}
      )
    else builtins.listToAttrs (map (a: lib.nameValuePair a.name (a.deps or [])) actions);

  depsOf = n: depsMap.${n} or [];

  producerOf = n:
    derivation ({
        inherit system;
        name = "${n}.drv";
        builder = "/bin/sh";
        args = [
          "-c"
          ''
            export PATH=${pkgs.nix}/bin:${pkgs.coreutils}/bin:${pkgs.python3}/bin:$PATH
            ${writeSpec n}
            # Store-dir-relative srcs, and the dependency injection, both of which can only
            # happen HERE. See nix/lib/dyn-actions-spec-fixup.py for why.
            python3 ${./dyn-actions-spec-fixup.py} spec.json || exit 1
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

        # THE DEPENDENCY PATHS REACH THE FIXUP SCRIPT THROUGH THIS ENVIRONMENT, and that is the
        # only route available. Their values are builtins.outputOf placeholders which the outer
        # Nix substitutes when THIS derivation runs, so by the time the script reads them they
        # are real, realised store paths. Putting them in the producer env also declares the
        # dependency, which is what makes Nix realise them first.
        DYN_DEP_NAMES = lib.concatStringsSep " " (depsOf n);
        DYN_INFER_SRCS =
          if inferSrcs
          then "1"
          else "";
      }
      // builtins.listToAttrs (map (d:
        lib.nameValuePair (depVar d) outputs.${d})
      (depsOf n)));

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
        # deps.json, because the spec files are copied without being parsed and cannot carry
        # the dependency edges themselves. A generator writing its own spec dir must write this
        # too, or its DAG silently becomes a set.
        printf '%s' ${lib.escapeShellArg (builtins.toJSON depsMap)} > "$out/deps.json"
      ''));
in
  assertOneSource (assertNotOut (assertUnique {
    # The emitted .drv per action, before realisation. Useful for inspection and for tests.
    inherit producers;

    inherit outputs outputName mkSpecDir depVar;
  }))
