# Build a Darling BUCK target through Nix instead of the buck2 daemon: overby's
# nix/lib/buck2 evaluates the project's Starlark at Nix evaluation time and lowers each
# Buck2 ACTION to its own derivation, with no import-from-derivation and no buck2 binary
# in the loop. Same BUCK definitions as the daemon build; see plan/buck2-port.md phase 3.
#
# This is the reason the port's rules are hand-written and prelude-free: overby's
# interpreter implements the surface those rules use (run / write / copy /
# symlinked_dir), and lists the full Meta prelude as an explicit non-goal.
#
# Consumed as a plain source tree through the `overby` flake input, exactly like
# ./ciderNinja.nix does for nix-ninja, so overby's own flake inputs stay out of this
# lock.
{
  pkgs,
  overby,
  # The project root. The default is this repo: BUCK files reference the materialized
  # pins under buck-src/, so a pure copy of the working tree is what the port builds
  # from today (phase 3 step 2 is what makes that hermetic).
  src ? ../..,
}: let
  buildBuck2Project = import "${overby}/nix/lib/buck2/build/buildBuck2Project.nix" {
    inherit pkgs;
  };
in {
  # One target, or several, by label.
  buildTarget = {
    target ? null,
    targets ? null,
  }:
    buildBuck2Project (
      {inherit src;}
      // (
        if targets != null
        then {inherit targets;}
        else {inherit target;}
      )
    );
}
