{
  description = "Darling - macOS compatibility layer for Linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flakelight = {
      url = "github:nix-community/flakelight";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { flakelight, ... }@inputs:
    flakelight ./. {
      inherit inputs;

      systems = [ "x86_64-linux" ];

      pname = "darling";

      # Disable builtin formatters — the repo has 100+ submodules with
      # broken symlinks when not checked out, which causes the formatting
      # check to fail on `diff` of missing files.
      flakelight.builtinFormatters = false;

      # Default package is autoloaded from ./nix/package.nix
      # Default devShell is autoloaded from ./nix/devShell.nix
      # NixOS module is autoloaded from ./nix/nixosModule.nix

      packages.darling-sdk = pkgs: pkgs.darling.sdk;
    };
}
