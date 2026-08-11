# A WORKING DYNAMIC DERIVATION, kept because getting one took five dead ends.
#
# #66 wants the lowering out of the evaluator: the generator emits derivations instead of Nix
# computing ~3,225 of them during eval. Dynamic derivations are the only mechanism that
# actually does that, and the task's own pre-check was "does builtins.outputOf work at all,
# and does EARLY CUTOFF survive it". This file is that pre-check, and on 2026-08-11 with Nix
# 2.35.1 the answer to both was YES. A third property, substitution, was also verified.
#
# WHAT IT DEMONSTRATES, measured rather than argued:
#
#   outputOf works        the consumer below builds through builtins.outputOf.
#   early cutoff survives `knob` changes the PRODUCER's input and nothing the inner
#                         derivation sees, so the emitted .drv is byte identical either way.
#                         Flipping it re-runs the producer and STOPS: the consumer is not
#                         rebuilt and keeps the same output path.
#   substitution survives with the dynamic output deleted locally and present only in a
#                         file:// cache, Nix COPIED it rather than rebuilding, despite
#                         warning "Ignoring dynamic derivation ...^out while querying missing
#                         paths; not yet implemented". That warning is about the PLANNING
#                         pass, not the build, and it does not cost substitution. This
#                         matters because the whole point of #50/#55 is a per-action cache
#                         that a binary cache can serve.
#
# THE ONE STRUCTURAL CONSTRAINT, which nothing announces and which reads like a bug:
#
#   A .drv-named derivation must be a text-hashed CA output with a SINGLE output named "out".
#   Nix enforces both, separately: name the producer's output anything else and it says
#   "derivation names are allowed to end in '.drv' only if they produce a single derivation
#   file". Meanwhile `builtins.placeholder "out"` is a constant of the OUTPUT NAME, not of
#   the derivation, so a floating-CA inner derivation whose output is ALSO called "out"
#   embeds the byte-identical string the producer uses for its own output, and text hashing
#   rejects it with "self-reference not allowed with text hashing".
#
#   So: NAME THE INNER OUTPUT ANYTHING BUT "out". Here it is called "inner". That single
#   choice is the difference between this working and not, and no error message points at it.
#
# PLUMBING TRAPS, each of which cost a build:
#
#   NIX_REMOTE=daemon BREAKS recursive-nix. recursive-nix supplies its OWN socket at
#     unix:///build/.nix-socket and sets the variable itself; overriding it sends the inner
#     nix to the ordinary daemon socket, which is not mounted, and it fails with
#     "cannot connect to socket at '/nix/var/nix/daemon-socket/socket'".
#   Reference nix and coreutils through pkgs so they enter the sandbox. A hardcoded string
#     path is not a dependency, and the builder fails with "nix: not found".
#   Experimental features are NOT inherited by the inner nix; pass them explicitly.
#
# Usage:
#   nix build --impure --expr '(import ./nix/lib/dyn-drv-probe.nix { pkgs = import <nixpkgs> {}; }).consumer'
# and see scripts/buck-dyndrv-check.nu, which asserts all three properties.
{
  pkgs,
  # Changes the PRODUCER's input WITHOUT changing the derivation it emits. That is the whole
  # experiment: flip it and nothing downstream may rebuild.
  knob ? "a",
}: let
  system = pkgs.stdenv.hostPlatform.system;

  # The derivation the producer emits, as JSON for `nix derivation add`. Its output is called
  # "inner" and NOT "out", for the placeholder reason in the header.
  spec = builtins.toJSON {
    name = "dyn-drv-probe-inner";
    inherit system;
    builder = "/bin/sh";
    args = ["-c" "echo INNER-RAN > $inner"];
    env = {
      builder = "/bin/sh";
      name = "dyn-drv-probe-inner";
      inner = builtins.placeholder "inner";
      outputHashAlgo = "sha256";
      outputHashMode = "recursive";
      inherit system;
    };
    inputs = {
      drvs = {};
      srcs = [];
    };
    outputs.inner = {
      hashAlgo = "sha256";
      method = "nar";
    };
    version = 4;
  };

  # Emits a derivation FILE. This is what makes the graph dynamic: the .drv does not exist at
  # evaluation time, so nothing about the inner build is computed by the evaluator.
  producer = derivation {
    inherit system;
    name = "dyn-drv-probe.drv";
    builder = "/bin/sh";
    args = [
      "-c"
      ''
        echo "PRODUCER RAN knob=${knob}" >&2
        export PATH=${pkgs.nix}/bin:${pkgs.coreutils}/bin:$PATH
        printf '%s' '${spec}' > spec.json
        emitted=$(nix --extra-experimental-features "nix-command ca-derivations dynamic-derivations" \
          derivation add < spec.json) || { echo "derivation add FAILED" >&2; exit 1; }
        echo "emitted $emitted" >&2
        cp "$emitted" "$out"
      ''
    ];
    __contentAddressed = true;
    outputHashMode = "text";
    outputHashAlgo = "sha256";
    requiredSystemFeatures = ["recursive-nix"];
  };

  # Binds to an output of a derivation that did not exist during evaluation.
  consumer = derivation {
    inherit system;
    name = "dyn-drv-probe-consumer";
    builder = "/bin/sh";
    args = [
      "-c"
      ''
        echo "CONSUMER RAN" >&2
        export PATH=${pkgs.coreutils}/bin:$PATH
        cp "${builtins.outputOf producer.outPath "inner"}" "$out"
      ''
    ];
    __contentAddressed = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
  };
in {
  inherit producer consumer;
}
