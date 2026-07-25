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

      # Darling's in-tree ld64 (cctools Mach-O linker) built standalone and cached
      # -- "Path B" of the cctools de-vendoring (plan/de-vendoring-audit.md). Uses
      # the off-submodules darling-src tree, so no ?submodules=1.
      #   nix build .#darling-ld64
      packages.darling-ld64 =
        pkgs:
        pkgs.callPackage ./nix/cctools-port.nix {
          src = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
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

      # A per-edge nix-ninja build of the darlingserver daemon. Its edges pull in
      # the mig/migcom code generators; unblocking their per-edge scan is the path
      # to a fully per-edge (cacheable, seconds-incremental) Darling build. See
      # plan/nix-ninja-primary.md.
      #   nix build '.?submodules=1#darlingserver-ninja'
      packages.darlingserver-ninja =
        pkgs:
        (import ./nix/lib/darlingNinja.nix {
          inherit pkgs;
          overby = inputs.overby;
        }).buildTarget
          { target = "src/external/darlingserver/darlingserver"; };

      # ── Off git submodules: nix-pinned source tree ───────────────────
      #
      # Darling's 147 vendored trees, assembled from fetchFromGitHub pins in
      # nix/submodules.json instead of git submodules (see plan/off-submodules.md
      # and nix/lib/darling-src.nix). Build WITHOUT ?submodules=1 -- darling-src
      # overlays every pinned submodule onto this flake's own tree and applies
      # patches/<name>/. Partial until every hash is filled
      # (scripts/prefetch-submodule-hashes.sh); passthru.unpinnedPaths lists gaps.
      #   nix build .#darling-src
      packages.darling-src =
        pkgs:
        import ./nix/lib/darling-src.nix {
          inherit pkgs;
          baseSrc = ./.;
        };

      # ── Rust host-side rewrite of darlingserver ──────────────────────
      #
      # The Rust darlingserver (plan/rust-rewrite-eval.md), built reproducibly. It
      # consumes the duct-tape + libsimple static libs exported by the standalone
      # `darlingserver` package (built from committed source), bindgens the dtape
      # hooks, and compiles fast_context.c (the P1 switch). Produces the proof/demo
      # binaries incl. the capstone `daemon_demo`. See nix/darlingserver-rs.nix.
      #   nix build .#darlingserver-rs
      packages.darlingserver-rs =
        pkgs:
        import ./nix/darlingserver-rs.nix {
          inherit pkgs;
          darlingserver = pkgs.darlingserver;
          src = ./.;
        };

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

          # ── Rust darlingserver rewrite: build + run its demos ───────────
          # Builds darlingserver-rs (the Rust host-side rewrite) and runs its
          # proof/demo binaries, asserting each prints its OK marker -- the whole
          # daemon pipeline (link + dtape_init, the microthread scheduler, the
          # byte-parity wire codec, the code-generated dispatch, per-guest routing,
          # the epoll loop) exercised end to end. See plan/rust-rewrite-eval.md.
          #   nix build '.?submodules=1#checks.x86_64-linux.darlingserver-rs' -L
          darlingserver-rs =
            pkgs.runCommand "darlingserver-rs-check"
              { nativeBuildInputs = [ pkgs.darlingserver-rs ]; }
              ''
                export TMPDIR="$(mktemp -d)"
                # Merge stderr into the grep input (2>&1, not 2>/dev/null): some
                # demos print their PROVEN marker on stderr (stage3-spike's "both
                # suspend paths" is an eprintln!). grep -q stays silent, so nothing
                # leaks to the build log on success.
                run() {
                  echo "== $1 =="
                  if "$1" 2>&1 | grep -q "$2"; then echo "  OK"; else echo "  FAIL: $1 did not print '$2'"; exit 1; fi
                }
                # Pure + socketpair-based demos (no filesystem sockets, sandbox-safe).
                run rpc_wire_check     RPC_WIRE_OK
                run dispatch_demo      DISPATCH_OK
                run rpc_loop_demo      RPC_LOOP_OK
                run rpc_roundtrip_demo RPC_ROUNDTRIP_OK
                run registry_demo      REGISTRY_OK
                run stage3-spike       "both suspend paths"
                # Forks a child and reads/writes its memory via process_vm_readv/writev
                # (the task_read_memory/task_write_memory hooks). Parent-child, same uid,
                # so it works under the sandbox's user+pid namespace.
                run mem_hooks_demo     MEM_HOOKS_OK
                # daemon_demo / epoll_demo bind a filesystem unix socket; validated
                # locally + by the reproducible build, but skipped here since the nix
                # build sandbox restricts socket paths.
                echo "darlingserver-rs: demos OK (link, scheduler both paths, wire codec, dispatch, routing, guest memory)"
                touch "$out"
              '';

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
