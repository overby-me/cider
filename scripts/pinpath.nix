{ pin }:
let
  pkgs = import <nixpkgs> {};
  s = import /home/overby.me/Work/darling-nix/nix/lib/cider-src.nix {
    inherit pkgs;
    baseSrc = builtins.toFile "dummy-basesrc" "";
  };
in s.pinPaths.${pin}
