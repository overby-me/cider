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

      # Default devShell is autoloaded from ./nix/devShell.nix
      # NixOS module is autoloaded from ./nix/nixosModule.nix

      # The default package (the full Darling) is built from the off-submodules
      # darling-src tree (nix-fetched submodule pins) rather than git submodules, so a
      # plain `nix build` needs no ?submodules=1. mkForce overrides flakelight's autoload
      # of ./nix/package.nix (which injects the raw ./. flake source -- submodule dirs
      # empty without ?submodules=1). The build is identical; only the source assembly
      # differs. See nix/lib/darling-src.nix (147/147 pins).
      packages.default = inputs.nixpkgs.lib.mkForce (
        pkgs:
        pkgs.callPackage ./nix/package.nix {
          src = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
        }
      );

      packages.darling-sdk = pkgs: pkgs.darling.sdk;

      # Darling's duct-tape + libsimple static libs (the kernel-emulation glue the Rust
      # `server` daemon links), built standalone and cached (~5-10 min vs ~40 min for the
      # whole darling). Builds from the off-submodules darling-src tree + package.nix's
      # exact configure; see nix/duct-tape.nix.
      #   nix build .#duct-tape
      packages.duct-tape =
        pkgs:
        pkgs.callPackage ./nix/duct-tape.nix {
          # Off-submodules darling-src tree so a pure `nix build .#duct-tape`
          # (and the `server` build that depends on this) resolves libcxx +
          # every other submodule without ?submodules=1.
          src = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
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
      # (The nix-ninja darling-launcher-ninja / darling-launcher-spliced targets were removed:
      # they built the C src/startup/darling, which is deleted. The launcher is now the Rust
      # `launcher` crate (packages.launcher, installed as bin/darling). task #67.)

      # A per-edge nix-ninja build of the darlingserver duct-tape static lib (the
      # kernel-emulation glue: real XNU osfmk/bsd sources + mig/migcom generators).
      # A mig-exercising subgraph smaller than the full build -- the fast validation
      # target for the per-edge lowering. (The old target was the C++ darlingserver
      # daemon executable, obsolete since the daemon became the Rust `server` crate,
      # task #50; its CMake add_executable lingers but nothing installs it.) See PLAN.md.
      #   nix build .#darlingserver-ninja
      packages.darlingserver-ninja =
        pkgs:
        (import ./nix/lib/darlingNinja.nix {
          inherit pkgs;
          overby = inputs.overby;
        }).buildTarget
          { target = "src/external/darlingserver/duct-tape/libdarlingserver_duct_tape.a"; };

      # The FULL per-edge nix-ninja build of Darling's CLI userland (the `all`
      # default of the `cli` component graph, ~tens of thousands of edges), each
      # edge its own cached derivation. This is task #39's keystone. It evaluates
      # thousands of derivations, so it is NOT wired into `nix flake check`; build
      # it directly:
      #   nix build .#darling-ninja
      packages.darling-ninja =
        pkgs:
        (import ./nix/lib/darlingNinja.nix {
          inherit pkgs;
          overby = inputs.overby;
        }).buildTarget
          { };

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

      # Darling's Ninja build graph as JSON, for the component-granularity build
      # (#26): group by CMakeFiles/<target>.dir/ to get the per-subproject DAG.
      # Cheap -- configure + graph parse, no compilation. COMPONENTS=system default.
      #   nix build .#darling-graph
      packages.darling-graph =
        pkgs:
        import ./nix/lib/darling-graph.nix {
          inherit pkgs;
          overby = inputs.overby;
        };

      # darling-base (#26): the shared foundation (toolchain + SDK header staging
      # + core libSystem runtime) as ONE cached derivation, the Darling `core`
      # COMPONENT scope. Per-component derivations layer on top of this.
      #   nix build .#darling-base
      packages.darling-base =
        pkgs:
        import ./nix/lib/darling-base.nix {
          inherit pkgs;
        };

      # Proof of #26: build ONE component (the leaf `bsdln`, which links libSystem)
      # on top of cached darling-base, reusing its toolchain + core + headers. Should
      # run only bsdln's own edges, not the ~4700-edge monolith.
      #   nix build .#darling-component-bsdln
      packages.darling-component-bsdln =
        pkgs:
        import ./nix/lib/darling-component.nix {
          inherit pkgs;
          base = import ./nix/lib/darling-base.nix { inherit pkgs; };
          target = "src/bsdln/bsdln";
        };

      # Second proof: a system-level (non-core) component whose only DAG dep is
      # migcom -- which lives in darling-base -- so it should also build base-only,
      # exercising the mig codegen path. Confirms base covers the migcom-dep majority.
      #   nix build .#darling-component-memberd
      packages.darling-component-memberd =
        pkgs:
        import ./nix/lib/darling-component.nix {
          inherit pkgs;
          base = import ./nix/lib/darling-base.nix { inherit pkgs; };
          target = "src/external/OpenDirectory/memberd-21.1/libmemberd_xtrace_mig.dylib";
          name = "memberd-xtrace-mig";
        };

      # ── The darling host-side daemon (Rust) ──────────────────────────
      #
      # The Rust `server` (plan/rust-rewrite-eval.md), built reproducibly. It consumes
      # the duct-tape + libsimple static libs exported by the standalone `duct-tape`
      # package (built from committed source), bindgens the dtape hooks, and compiles
      # fast_context.c (the P1 switch). Produces the daemon `darlingserverd` + the
      # proof/demo binaries. Its lib crate is named `darling`. See nix/server.nix.
      #   nix build .#server
      packages.server =
        pkgs:
        pkgs.callPackage ./nix/server.nix {
          ductTape = pkgs.duct-tape;
          src = ./.;
        };

      # The Rust launcher (src/startup/darling.c rewrite), task #64.
      #   nix build .#launcher
      packages.launcher =
        pkgs:
        pkgs.callPackage ./nix/launcher.nix {
          src = ./.;
        };

      # The Rust guest Mach-O loader (src/startup/mldr rewrite), task #65.
      #   nix build .#loader
      packages.loader =
        pkgs:
        pkgs.callPackage ./nix/loader.nix {
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

          # ── Rust darling daemon: build + run its demos ─────────────────
          # Builds `server` (the Rust host-side daemon) and runs its proof/demo
          # binaries, asserting each prints its OK marker -- the whole daemon
          # pipeline (link + dtape_init, the microthread scheduler, the byte-parity
          # wire codec, the code-generated dispatch, per-guest routing, the epoll
          # loop) exercised end to end. See plan/rust-rewrite-eval.md.
          #   nix build '.?submodules=1#checks.x86_64-linux.server' -L
          server =
            pkgs.runCommand "server-check"
              { nativeBuildInputs = [ pkgs.server ]; }
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
                # Serves the special-port Mach traps (task_self/host_self/thread_self/
                # mach_reply_port) through real XNU on a guest task. Fully in-process.
                run mach_traps_demo    MACH_TRAPS_OK
                # A guest thread blocks mid-call, persists addressable by tid, and is
                # resumed by the daemon on the same stack (the mach_msg receive shape).
                run persistent_threads_demo PERSISTENT_THREADS_OK
                # Real Mach port-right ops on a guest task: mach_port_allocate copies the
                # name out to guest memory (the write_memory hook) + mach_port_deallocate.
                run mach_port_demo     MACH_PORT_OK
                # A full port-name lifecycle: allocate a receive right, query its type
                # (mach_port_type copyout), destroy via mach_port_mod_refs, verify invalid.
                run mach_port_lifecycle_demo MACH_PORT_LIFECYCLE_OK
                # The mach IPC core: a mach_msg send+receive loopback on a self-port
                # (copyin via read_memory, ipc_mqueue routing, copyout via write_memory).
                run mach_msg_demo      MACH_MSG_OK
                # The async IPC pattern: a thread BLOCKS on mach_msg(RCV), a second
                # thread's send wakes it, and its continuation completes via the
                # current_thread_syscall_return hook.
                run blocking_msg_demo  BLOCKING_MSG_OK
                # The persistent-thread doWork loop: one long-lived guest thread serves
                # multiple RPC calls via dispatch, parking between them (state preserved).
                run thread_call_loop_demo THREAD_LOOP_OK
                # The minimal working daemon: a real client PROCESS makes Mach calls over
                # a SEQPACKET socketpair; the daemon routes each to the client's task and
                # serves it via the shared Handler + dispatch, replying over the socket.
                run daemon_mach_demo   DAEMON_MACH_OK
                # Cross-process copyout over the socket: a client process calls
                # mach_port_allocate; the daemon writes the allocated name into the
                # CLIENT's memory (process_vm_writev to the client's pid).
                run daemon_alloc_demo  DAEMON_ALLOC_OK
                # The culmination: a client process runs a mach_msg send/receive loopback
                # OVER THE SOCKET; the daemon copies the message in from and out to the
                # CLIENT's memory (cross-process) and routes it through XNU.
                run daemon_msg_demo    DAEMON_MSG_OK
                # A full guest SESSION over the socket on ONE persistent doWork thread:
                # checkin -> task_self_trap -> mach_port_allocate -> mach_msg -> checkout.
                run daemon_session_demo DAEMON_SESSION_OK
                # daemon_demo / epoll_demo bind a filesystem unix socket; validated
                # locally + by the reproducible build, but skipped here since the nix
                # build sandbox restricts socket paths.
                echo "server: demos OK (link, scheduler both paths, wire codec, dispatch, routing, guest memory, mach traps, persistent threads, mach port ops, mach_msg send/recv, blocking recv, doWork loop, real-socket serving, cross-process copyout, mach_msg over socket, full session)"
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
