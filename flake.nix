{
  description = "Darling - macOS compatibility layer for Linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flakelight = {
      url = "github:nix-community/flakelight";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # nix-ninja: per-edge Nix builds of Darling (nix/lib/darlingNinja.nix).
    # Consumed as a plain source tree so none of the monorepo's ~30 transitive
    # flake inputs enter this lock; its rust-ninja tool is built with nixpkgs'
    # rustPlatform. Tracks the monorepo's default branch, where the nix-ninja
    # library now lives.
    overby = {
      url = "git+https://tangled.org/overby.me/overby.me?ref=main";
      flake = false;
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

      # Just the darlingserver daemon (Linux ELF), built standalone for fast perf
      # iteration (~5-10 min vs ~40 min for the whole darling). Reuses the darling
      # package's submodule-aware source and exact configure; see nix/darlingserver.nix.
      #   nix build '.?submodules=1#darlingserver'
      packages.darlingserver =
        pkgs:
        pkgs.callPackage ./nix/darlingserver.nix {
          src = pkgs.darling.src;
          # For the splice loop, bake LIBEXEC_PATH to the splice dir (needs --impure);
          # unset -> a normal build, so `nix flake check` (pure) stays green.
          installPrefix =
            let
              e = builtins.getEnv "DARLING_SPLICE_PREFIX";
            in
            if e == "" then null else e;
        };

      # ── nix-ninja incremental build (per-edge Nix) ───────────────────
      #
      # The Darling launcher (src/startup/darling) built edge-by-edge via
      # nix-ninja, reusing package.nix's exact configure inputs
      # (nix/darlingBuildInputs.nix). A demonstration/entry point for the
      # incremental per-edge build path; see nix/lib/darlingNinja.nix.
      #   nix build .#darling-launcher-ninja
      packages.darling-launcher-ninja =
        pkgs:
        (import ./nix/lib/darlingNinja.nix {
          inherit pkgs;
          overby = inputs.overby;
        }).buildTarget
          { target = "src/startup/darling"; };

      # The launcher, baked to exec a spliced runtime's darlingserver (see
      # scripts/splice-darlingserver.sh). The install prefix comes from the
      # DARLING_SPLICE_PREFIX env var (needs --impure); unset -> a normal launcher,
      # so `nix flake check` (pure) still builds it fine.
      #   DARLING_SPLICE_PREFIX=$HOME/darling-rt nix build --impure \
      #     '.?submodules=1#darling-launcher-spliced'
      packages.darling-launcher-spliced =
        pkgs:
        (import ./nix/lib/darlingNinja.nix {
          inherit pkgs;
          overby = inputs.overby;
        }).buildTarget
          {
            target = "src/startup/darling";
            installPrefix =
              let
                e = builtins.getEnv "DARLING_SPLICE_PREFIX";
              in
              if e == "" then null else e;
          };

      # NOTE: a nix-ninja `darlingserver` target for fast daemon iteration is not
      # exposed as a package: its edges pull in the mig/migcom code generators,
      # whose per-edge scan derivations hit the monorepo scan-toolchain blocker
      # (see plan/nix-ninja-primary.md). darlingserver perf changes are validated
      # via a full `nix build` for now.

      # A per-edge nix-ninja build of a whole libSystem sublibrary,
      # src/.../libsystem_kernel/libsystem_kernel.dylib, works end to end and
      # produces a valid Mach-O x86_64 dylib (its full closure — mig codegen,
      # libc, the two-pass dylib link — builds from source per edge). It is not
      # exposed as a package because its lowering evaluates thousands of
      # derivations, which `nix flake check` would force. Build it directly with:
      #   nix build '.?submodules=1' \
      #     --expr '(import ./nix/lib/darlingNinja.nix { pkgs = <nixpkgs>; overby = <overby>; }).buildTarget
      #             { target = "src/external/xnu/darling/src/libsystem_kernel/libsystem_kernel.dylib"; }'

      # ── Flake Templates ──────────────────────────────────────────────
      #
      # Initialise a new project with:
      #   nix flake init -t github:nixie-dev/darling-nix#darling-builder
      #
      # See: docs/darwin-builder.md, plan/09-phase7-remote-builder.md (Task 7.7)
      templates.darling-builder = {
        path = ./templates/darling-builder;
        description = "NixOS configuration with a Darling-based x86_64-darwin remote builder";
      };

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
