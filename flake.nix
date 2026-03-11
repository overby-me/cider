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

      # ── NixOS Modules ────────────────────────────────────────────────
      #
      # The base module (programs.darling) is autoloaded from
      # ./nix/nixosModule.nix by flakelight.
      #
      # The darling-builder module (services.darling-builder) is exported
      # separately so users can import it alongside the base module.
      #
      # Usage in a NixOS configuration:
      #   {
      #     imports = [
      #       darling-nix.nixosModules.nixos        # programs.darling
      #       darling-nix.nixosModules.darling-builder  # services.darling-builder
      #     ];
      #     services.darling-builder.enable = true;
      #   }
      nixosModules.darling-builder = import ./nix/darlingBuilderModule.nix;

      # ── Checks (Phase 6.2) ───────────────────────────────────────────
      #
      # NixOS VM integration tests and lightweight validation checks.
      # Run with:
      #   nix flake check              # all checks
      #   nix build .#checks.x86_64-linux.darling-smoke -L
      #   nix build .#checks.x86_64-linux.nix-in-darling -L
      #   nix build .#checks.x86_64-linux.darling-builder -L
      #
      # See: plan/08-phase6-ci.md (Tasks 6.1, 6.2)
      #      plan/09-phase7-remote-builder.md (Task 7.5)
      checks = pkgs:
        let
          darling = pkgs.darling;
          darlingBuilderModule = import ./nix/darlingBuilderModule.nix;
        in
        {
          # ── Build check ─────────────────────────────────────────────────
          # Ensure the package builds successfully.  This is redundant with
          # `packages.default` but makes `nix flake check` self-contained.
          darling-build = darling;

          # ── Darling smoke test (Phase 6.6) ──────────────────────────────
          # Lightweight NixOS VM test: boots Darling, verifies shell,
          # sandbox-exec, diskutil, and Directory Services stubs.
          # No network access required — completes in a few minutes.
          darling-smoke = import ./tests/darling-smoke.nix {
            inherit pkgs darling;
          };

          # ── Nix-in-Darling integration test (Phase 6.1) ────────────────
          # Full end-to-end test: installs Nix inside Darling, verifies
          # core commands, evaluator, currentSystem, and trivial builds.
          # Requires network access (downloads Nix installer + store paths).
          nix-in-darling = import ./tests/nix-in-darling.nix {
            inherit pkgs darling;
          };

          # ── Darling builder test (Phase 7.5) ────────────────────────────
          # NixOS VM test for the remote builder module: verifies the
          # systemd service starts, sshd inside the prefix is reachable,
          # SSH key auth works, and Darling identity is correct via SSH.
          darling-builder = import ./tests/darling-builder.nix {
            inherit pkgs darling darlingBuilderModule;
          };

          # ── Directory Services stubs unit test ──────────────────────────
          # Runs the shell-based test suite for dseditgroup, sysadminctl,
          # and dscl stubs on the host (no Darling needed — pure shell).
          dirserv-stubs = pkgs.runCommandLocal "dirserv-stubs-test" {
            nativeBuildInputs = with pkgs; [
              coreutils
              gawk
              gnugrep
              gnused
              findutils
            ];
          } ''
            # The test script uses sed to rewrite /etc/passwd and /etc/group
            # paths to temp files, so it's safe to run outside Darling.
            # We create a directory layout that matches what the test expects:
            #   <workdir>/tests/dirserv/test_dirserv.sh
            #   <workdir>/src/dirserv/{dseditgroup,sysadminctl,dscl}
            workdir=$(mktemp -d)
            mkdir -p "$workdir/tests/dirserv" "$workdir/src/dirserv"
            cp ${./tests/dirserv/test_dirserv.sh} "$workdir/tests/dirserv/test_dirserv.sh"
            cp ${./src/dirserv/dseditgroup} "$workdir/src/dirserv/dseditgroup"
            cp ${./src/dirserv/sysadminctl} "$workdir/src/dirserv/sysadminctl"
            cp ${./src/dirserv/dscl} "$workdir/src/dirserv/dscl"
            chmod +x "$workdir/src/dirserv"/*
            export HOME=$(mktemp -d)
            sh "$workdir/tests/dirserv/test_dirserv.sh"
            touch $out
          '';
        };
    };
}
