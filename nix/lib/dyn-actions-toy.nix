# Three toy actions for exercising nix/lib/dyn-actions.nix, with NOTHING cider-shaped in them.
#
# That is the point: the bridge is meant to be reusable, and a test that needed cider's pins,
# SDK farm or staging would prove the opposite. If this file ever has to know about this repo
# to keep passing, the bridge has stopped being general and that is the bug.
#
# `flavour` exists to change ONE action without touching the others, which is how the
# per-action isolation property is tested: changing it must re-emit toy-gamma and leave
# toy-alpha and toy-beta alone. Proven 2026-08-11.
{
  pkgs,
  flavour ? "vanilla",
}:
import ./dyn-actions.nix {
  inherit pkgs;
  actions = [
    {
      name = "toy-alpha";
      builder = "/bin/sh";
      args = ["-c" "echo ALPHA-RAN > $result"];
    }
    {
      name = "toy-beta";
      builder = "/bin/sh";
      args = ["-c" "echo BETA-RAN > $result"];
    }
    {
      # Carries env, because an action that cannot take env is not much of an action, and the
      # env has to survive the round trip through the emitted .drv.
      name = "toy-gamma";
      builder = "/bin/sh";
      args = ["-c" "printf 'GAMMA %s\\n' \"$FLAVOUR\" > $result"];
      env = {FLAVOUR = flavour;};
    }
  ];
}
