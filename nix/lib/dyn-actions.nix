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
  # Store paths the CONSUMER knows and the spec cannot name. Either {NAME = path;}, applied to
  # every action, or a FUNCTION from action name to that attrset, which is the general case:
  #
  #   extraEnv = name: { TOOLCHAIN = tc; STAGE = stageFor name; };
  #
  # Each entry becomes an env entry on the emitted action and, if it is a store path, a source.
  #
  # WHY specDir NEEDS THIS. A spec read from a file is static: the generator that wrote it ran
  # long before any consumer path existed, so it cannot interpolate one. `deps` already solves
  # that for other ACTIONS, and this is the same route for everything else a consumer supplies:
  # a toolchain, a staging script, a data tree. The generator writes ${NAME} in the script and
  # the value arrives at build time.
  #
  # PER ACTION IS THE POINT, not a refinement of it. The uniform case is real but small: what a
  # generator usually cannot name is something computed per action, and a consumer forced to
  # give every action the union would declare thousands of sources it does not use and rebuild
  # all of them whenever any one changed.
  #
  # THE VALUES MAY CARRY STRING CONTEXT, and should: putting them in the producer's env is what
  # makes Nix realise them before the producer runs, which is what makes the path real by the
  # time the fixup reads it. Same mechanism as deps, which is why they share the code.
  extraEnv ? {},
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
      # NO deps HANDLING HERE. They are injected by cider-spec-fixup when the producer
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
        # deps are appended by cider-spec-fixup rather than here, precisely BECAUSE
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
  # THROUGH A FILE IN BOTH MODES, and the printf this replaced could not carry a large action.
  # An `args` entry is one argv string, and Linux caps a single one at MAX_ARG_STRLEN, 32 pages,
  # 131,072 bytes. That is not ARG_MAX, the 2 MB total: a producer well under the total still
  # dies with "executing /bin/sh: Argument list too long" before the fixup ever runs, because
  # the spec was embedded in the producer's OWN command line.
  #
  # FOUND BY A CONSUMER WITH REAL ACTIONS. 89 of one consumer's 1,474 are over the limit and
  # the largest is 5.1 MB. Every fixture here except nix/lib/dyn-actions-bigarg-toy.nix has a
  # script of a few kilobytes, so nothing could have reached it.
  #
  # writeText puts the spec in the store and the producer copies it, which is the same shape
  # specDir mode already had and is why that mode was never affected.
  writeSpec = n:
    if fromDir
    then "cp ${specDir}/${n}.json spec.json && chmod u+w spec.json"
    else "cp ${pkgs.writeText "dyn-action-spec-${n}.json" (specOf (actionOf n))} spec.json && chmod u+w spec.json";

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

  # Accepts either form of `extraEnv`. An attrset is the uniform case spelled shortly, and is
  # exactly `_: attrs`; a function is asked per action.
  extraEnvFor =
    if lib.isFunction extraEnv
    then extraEnv
    else (_: extraEnv);

  # RUST, NOT PYTHON, since #99, and the reason python3 has left the producer's PATH: the fixup
  # was the only thing using it there. Built by nix rather than by buck2, like every other tool
  # in linux/buildtools.
  specFixup = pkgs.callPackage ../spec-fixup.nix { src = ../..; };

  producerOf = n:
    derivation ({
        inherit system;
        name = "${n}.drv";
        builder = "/bin/sh";
        args = [
          "-c"
          ''
            export PATH=${pkgs.nix}/bin:${pkgs.coreutils}/bin:$PATH
            ${writeSpec n}
            # Store-dir-relative srcs, and the dependency injection, both of which can only
            # happen HERE. See cider-spec-fixup for why.
            ${specFixup}/bin/cider-spec-fixup spec.json || exit 1
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
        # The same route as the dependency paths, for values the CONSUMER supplies. Named
        # separately so the fixup can tell them apart: a dep is also an edge, this is not.
        DYN_EXTRA_NAMES = lib.concatStringsSep " " (lib.attrNames (extraEnvFor n));

        # WHAT A GENERATOR CANNOT KNOW, filled in by the fixup rather than demanded of the
        # spec. A spec dir written by some other tool has no way to produce these: the output
        # placeholder is a Nix construction, and the system belongs to whoever is building.
        # Requiring them made specDir mode usable only by mkSpecDir, which is this bridge
        # writing files for itself and is not the point of the mode.
        #
        # A SPEC THAT DOES SUPPLY THEM IS LEFT ALONE, so mkSpecDir output and everything
        # already written keeps working unchanged.
        DYN_SYSTEM = system;
        DYN_OUTPUT_NAME = outputName;
        DYN_OUTPUT_PLACEHOLDER = builtins.placeholder outputName;
      }
      // extraEnvFor n
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
      # SAME REASON AS writeSpec: a printf of the spec puts it in this derivation's argv, and a
      # single argv string is capped at 131,072 bytes.
      + lib.concatMapStrings (n: ''
        cp ${pkgs.writeText "dyn-action-spec-${n}.json" (specOf (actionOf n))} "$out"/${lib.escapeShellArg n}.json
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
