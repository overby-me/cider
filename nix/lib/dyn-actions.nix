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
{
  pkgs,
  # [{ name; builder; args; env ? {}; inputSrcs ? []; }]
  # `name` must be unique across the list: it is both the derivation name and the key the
  # consumer looks the action up by.
  actions,
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

  names = map (a: a.name) actions;
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
  producerOf = a:
    derivation {
      inherit system;
      name = "${a.name}.drv";
      builder = "/bin/sh";
      args = [
        "-c"
        ''
          export PATH=${pkgs.nix}/bin:${pkgs.coreutils}/bin:$PATH
          printf '%s' ${lib.escapeShellArg (specOf a)} > spec.json
          emitted=$(nix --extra-experimental-features \
            "nix-command ca-derivations dynamic-derivations" derivation add < spec.json) \
            || { echo "dyn-actions: derivation add failed for ${a.name}" >&2; exit 1; }
          cp "$emitted" "$out"
        ''
      ];
      __contentAddressed = true;
      outputHashMode = "text";
      outputHashAlgo = "sha256";
      requiredSystemFeatures = ["recursive-nix"];
    };

  producers = lib.listToAttrs (map (a: lib.nameValuePair a.name (producerOf a)) actions);
in
  assertNotOut (assertUnique {
    # The emitted .drv per action, before realisation. Useful for inspection and for tests.
    inherit producers;

    # What a consumer actually binds to: the OUTPUT of the dynamically emitted derivation.
    # This is the string that makes the evaluator not need to know the derivation.
    outputs =
      lib.mapAttrs
      (n: p: builtins.outputOf p.outPath outputName)
      producers;

    inherit outputName;
  })
