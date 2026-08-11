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
# 14.36 s and splits into 0.21 s to readFile a 139 MB graph.json, about 2.1 s to fromJSON it,
# and about 12 s to COMPUTE 8,704 derivations from the result. The computing is what #66
# removes, so an adapter that made Nix re-serialise every action would hand most of that cost
# straight back. The generator already runs inside the graph derivation and can write the
# specs itself, which is what "emit drvs from the generator" actually means.
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
        // {
          inherit (a) name;
          builder = a.builder;
          ${outputName} = builtins.placeholder outputName;
          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          inherit system;
        };
      inputs = {
        drvs = {};
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
          export PATH=${pkgs.nix}/bin:${pkgs.coreutils}/bin:$PATH
          ${writeSpec n}
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
in
  assertOneSource (assertNotOut (assertUnique {
    # The emitted .drv per action, before realisation. Useful for inspection and for tests.
    inherit producers;

    # What a consumer actually binds to: the OUTPUT of the dynamically emitted derivation.
    # This is the string that makes the evaluator not need to know the derivation.
    outputs =
      lib.mapAttrs
      (n: p: builtins.outputOf p.outPath outputName)
      producers;

    inherit outputName;
  }))
