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
      # -- "Path B" of the cctools de-vendoring (PLAN.md). Uses
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

      # ── Nix-lowered Buck2 (plan/buck2-port.md phase 3) ───────────────
      #
      # The same BUCK definitions the buck2 daemon builds, lowered to one Nix
      # derivation per ACTION by overby's nix/lib/buck2 -- no daemon, no IFD,
      # cacheable and shareable. This smoke target is the smallest real one in the
      # port (libsimple's host-tier archive: one C source, one include root, one
      # archive action), so it exercises load/rule/provider/glob and three action
      # kinds without pulling the guest toolchain in:
      #   nix build .#darling-buck2-libsimple
      #
      # Needs the overby-side support this port added (read_root_config,
      # symlinked_dir, copy, ar), which lives on that repo's `nix-lib-buck2`
      # bookmark until it lands on main:
      #   nix build .#darling-buck2-libsimple \
      #     --override-input overby 'git+https://tangled.org/overby.me/overby.me?ref=nix-lib-buck2'
      packages.darling-buck2-libsimple =
        pkgs:
        (import ./nix/lib/darlingBuck2.nix {
          inherit pkgs;
          overby = inputs.overby;
        }).buildTarget
          { target = "//src/libsimple:libsimple_darlingserver"; };

      # The host tier through the same Nix-lowered path: darlingserver's duct-tape
      # archive (real XNU osfmk/bsd sources plus mig codegen, and the artifact the
      # Rust daemon consumes via DUCT_TAPE_LIB). Bigger than the libsimple smoke
      # target by two orders of magnitude, and it exercises a generator TOOL built
      # by the same graph (migcom):
      #   nix build .#darling-buck2-duct-tape
      packages.darling-buck2-duct-tape =
        pkgs:
        (import ./nix/lib/darlingBuck2.nix {
          inherit pkgs;
          overby = inputs.overby;
        }).buildTarget
          { target = "//src/external/darlingserver/duct-tape:darlingserver_duct_tape"; };

      # A mid-size probe for the Nix-lowered path: src/duct's static archive is 8
      # sources in a 165-line BUCK file, between libsimple (80 lines) and duct-tape
      # (1044). Which of size or feature-set the interpreter runs out of road on is
      # what this answers:
      #   nix build .#darling-buck2-duct-static
      packages.darling-buck2-duct-static =
        pkgs:
        (import ./nix/lib/darlingBuck2.nix {
          inherit pkgs;
          overby = inputs.overby;
        }).buildTarget
          { target = "//src/duct:system_duct_static"; };

      # Two probes for where the Nix-lowered path runs out of road. Both are
      # trivial targets; what differs is the FILE the interpreter has to read:
      # darwin/BUCK loads the generated SDK maps (4178 entries), buck-src/BUCK is
      # 32k lines. If a trivial target in a big file overflows, the wall is parsing,
      # not the target -- which is how the interpreter's recursive loops were found.
      #
      # CAP THE MEMORY when running these: an evaluation that runs away takes the
      # machine down otherwise (it did, twice).
      #   systemd-run --user --scope -p MemoryMax=8G \
      #     nix build .#darling-buck2-probe-sdkenv
      packages.darling-buck2-probe-sdkenv =
        pkgs:
        (import ./nix/lib/darlingBuck2.nix {
          inherit pkgs;
          overby = inputs.overby;
        }).buildTarget
          { target = "//darwin:sdk_env"; };

      packages.darling-buck2-probe-bigfile =
        pkgs:
        (import ./nix/lib/darlingBuck2.nix {
          inherit pkgs;
          overby = inputs.overby;
        }).buildTarget
          { target = "//buck-src:mig.sh"; };

      # The port's action graph, dumped by real buck2 in a pure derivation, for the
      # "graph then lower" endpoint (plan/buck2-port.md phase 3). One opt-in IFD: this
      # derivation writes what-ran.json, Nix reads that single file, and each action then
      # becomes its own derivation. Interpreting the Starlark in Nix is what this replaces.
      #
      #   systemd-run --user --scope -p MemoryMax=8G nix build .#darling-buck2-graph
      packages.darling-buck2-graph =
        pkgs:
        import ./nix/lib/darlingBuck2Graph.nix {
          inherit pkgs;
          targets = [ "//src/libsimple:libsimple_darlingserver" ];
        };

      # THE REAL GRAPH, and the reason this is a separate attribute: the one above is a
      # DEMO over a single target and writes 2 command actions. A green build of it says
      # nothing about the port, which is a trap worth naming -- it was read as a passing
      # endpoint once, while the graph the endpoint actually uses was failing.
      #
      # This is byte-identical to the graph darling-buck2-prefix builds (same darlingSrc,
      # same ld64, allPins, same target list), so it is the way to exercise or debug the
      # graph derivation ALONE. That matters because the two halves cost very differently:
      # the graph is one derivation of roughly 40 minutes, the lowering that follows it is
      # hundreds. Every one of tasks #35 to #38 was a graph-stage failure, and each cost a
      # full prefix build to reach.
      #
      #   nix build .#darling-buck2-graph-all -L
      packages.darling-buck2-graph-all =
        pkgs:
        let
          darlingSrc = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
          ld64 = pkgs.callPackage ./nix/cctools-port.nix { src = darlingSrc; };
        in
        import ./nix/lib/darlingBuck2Graph.nix {
          inherit pkgs darlingSrc ld64;
          allPins = true;
          targets = import ./nix/lib/buck2-targets.nix;
        };

      # THE SKELETON EXPERIMENT (#56). The same graph the minimal endpoint uses, dumped from a
      # tree whose C family is emptied rather than from the project, so that editing a .c
      # leaves the dump input byte identical and the 18m34s graph rebuild disappears from that
      # edit. Everything else is identical to what prefix-min lowers.
      #
      # A SEPARATE ATTRIBUTE, and it stays one until the graphs are shown equal. A wrong
      # skeleton does NOT fail loudly: an emptied generator input compiles, links, runs and
      # writes an empty output, so the dump comes out quietly wrong. The check is
      #
      #   scripts/buck-graph-equiv.py <project-graph> <project-data> <skeleton-graph> <data>
      #
      # which compares by MEANING (every action with its argv, env, inputs and outputs; every
      # staged artifact by content hash; every farm by reconstructed links) rather than byte
      # for byte, since the tables have two encodings.
      #
      # THIS DOES NOT BUILD YET, and it is kept because each failure has been worth more than
      # it cost. Three runs so far, each finding a different missing input:
      #   1. 8s    the skeleton itself died, os.stat following a dangling SDK symlink.
      #   2. 374s  bindgen got an emptied linux/server/wrapper.h, wrote nothing, and the
      #            daemon failed with 83 rustc errors on an unresolved crate::bindings. The
      #            codegen closure was rooted only at staged farms and never saw it.
      #   3. 431s  with the closure widened to every generator CATEGORY, a long list of
      #            buck-src _xtrace_mig_obj compiles plus dyld, compiler_rt_final and
      #            system_dyld_final fail. Those targets own sources are intact (buck-src is
      #            never emptied), so what they are missing is emptied darwin/ SDK headers,
      #            and the open question is why materialize.bxl reaches a COMPILE at all when
      #            it deliberately stopped ensuring default outputs. buck2 own error text is
      #            truncated in the nix log, so answering it needs buck2 run directly.
      #
      #   nix build .#darling-buck2-graph-min-skeleton -L
      packages.darling-buck2-graph-min-skeleton =
        pkgs:
        let
          darlingSrc = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
          ld64 = pkgs.callPackage ./nix/cctools-port.nix { src = darlingSrc; };
        in
        import ./nix/lib/darlingBuck2Graph.nix {
          inherit pkgs darlingSrc ld64;
          allPins = true;
          skeleton = true;
          targets = import ./nix/lib/buck2-targets-min.nix;
        };

      # The same graph, LOWERED: one Nix derivation per buck2 action, from the single
      # IFD of graph.json. This is the endpoint the port is aiming at -- per-action
      # caching a binary cache can serve, with buck2 as the definition authority.
      #
      #   systemd-run --user --scope -p MemoryMax=8G nix build .#darling-buck2-lowered
      packages.darling-buck2-lowered =
        pkgs:
        (import ./nix/lib/darlingBuck2Lower.nix {
          inherit pkgs;
          graph = import ./nix/lib/darlingBuck2Graph.nix {
            inherit pkgs;
            targets = [ "//src/libsimple:libsimple_darlingserver" ];
          };
        }).final;

      # The same endpoint on a target that needs the PINS: migcom is the MIG compiler
      # the port's every codegen edge runs, and it lives in buck-src -- so loading its
      # package coerces the SDK maps and all 147 pinned trees have to be there.
      #
      #   systemd-run --user --scope -p MemoryMax=8G nix build .#darling-buck2-migcom
      packages.darling-buck2-migcom =
        pkgs:
        (
          let
            darlingSrc = import ./nix/lib/darling-src.nix {
              inherit pkgs;
              baseSrc = ./.;
            };
          in
          import ./nix/lib/darlingBuck2Lower.nix {
            inherit pkgs darlingSrc;
            allPins = true;
            graph = import ./nix/lib/darlingBuck2Graph.nix {
              inherit pkgs darlingSrc;
              allPins = true;
              targets = [ "//buck-src:migcom" ];
            };
          }
        ).final;

      # The endpoint on a GUEST-tier dylib: libsystem_blocks is small, but its link runs
      # Darling's own ld64 and goes through the firstpass/final pair, which is the shape
      # every one of the port's 132 dylibs has.
      #
      #   systemd-run --user --scope -p MemoryMax=8G nix build .#darling-buck2-blocks
      packages.darling-buck2-blocks =
        pkgs:
        (
          let
            darlingSrc = import ./nix/lib/darling-src.nix {
              inherit pkgs;
              baseSrc = ./.;
            };
            ld64 = pkgs.callPackage ./nix/cctools-port.nix { src = darlingSrc; };
          in
          import ./nix/lib/darlingBuck2Lower.nix {
            inherit pkgs darlingSrc ld64;
            allPins = true;
            graph = import ./nix/lib/darlingBuck2Graph.nix {
              inherit pkgs darlingSrc ld64;
              allPins = true;
              targets = [ "//buck-src:system_blocks_final" ];
            };
          }
        ).final;

      # The whole port through the endpoint, for the scale question: how big the graph
      # gets, how long the dump takes, and how many target derivations come out. The list
      # is the suite's, which spans host tier, guest tier, MIG and the firstpass/final
      # pair, so it exercises everything the endpoint has to handle.
      #
      # And the same graph LOWERED: every target as its own Nix derivation, collected by
      # name. This is the scale test for the endpoint -- 259 target derivations out of
      # 2,066 actions, which is the ratio that made per-target the right unit.
      #
      #   systemd-run --user --scope -p MemoryMax=8G nix build .#darling-buck2-all
      # The targets come from the PREFIX package rather than from a second lowering of the
      # same graph, for the reason spelled out at packages.darling-buck2: a lowering without
      # extraTools produces a disjoint set of derivations AND cannot build the wrap_elf ones.
      packages.darling-buck2-all =
        pkgs:
        pkgs.linkFarm "darling-buck2-all" (
          pkgs.lib.mapAttrsToList (label: drv: {
            name = pkgs.lib.strings.sanitizeDerivationName (pkgs.lib.last (pkgs.lib.splitString ":" label));
            path = drv;
          })
          pkgs.darling-buck2-prefix.named
        );

      #   systemd-run --user --scope -p MemoryMax=8G nix build .#darling-buck2-all-graph
      # The PREFIX, lowered: a Darling install built entirely through the Nix endpoint,
      # one derivation per buck2 target. This is the bash milestone on the Nix side --
      # the same tree scripts/buck-bash-check.nu boots, but assembled from store paths.
      #
      #   nix build .#darling-buck2-prefix
      packages.darling-buck2-prefix =
        pkgs:
        let
          darlingSrc = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
          ld64 = pkgs.callPackage ./nix/cctools-port.nix { src = darlingSrc; };
          lowered = import ./nix/lib/darlingBuck2Lower.nix {
            inherit pkgs darlingSrc ld64;
            allPins = true;
            # The host ELF libraries wrapgen dlopen's, declared for exactly the reason
            # extraTools exists: a wrap_elf action's fifth argument is the elf_lib_dirs
            # string, so the recorded argv carries those store paths as PLAIN TEXT, the
            # dump discards string context, and Nix cannot see the dependency. Undeclared,
            # the sandbox does not have them and the action dies with "Cannot load
            # libX11.so" -- the same failure the graph derivation hit one stage earlier.
            #
            # hostHeaderLibs as well as wrappedLibs, and for the same reason one step over:
            # a compile's argv carries -I into xorgproto, zlib, linux-headers and the rest
            # as plain text, so those store paths are equally invisible to Nix. Declaring
            # only the ELF set is what left fseventsd_obj failing on linux/types.h in the
            # lowering after the graph stage had been fixed.
            #
            # Only here: the libsimple, migcom and blocks endpoints below lower graphs with
            # no wrap_elf in them.
            extraTools =
              let
                di = pkgs.callPackage ./nix/darlingBuildInputs.nix { };
              in
              di.wrappedLibs ++ di.hostHeaderLibs;
            graph = import ./nix/lib/darlingBuck2Graph.nix {
              inherit pkgs darlingSrc ld64;
              allPins = true;
              targets = import ./nix/lib/buck2-targets.nix;
            };
          };
        in
        # `//` rather than overrideAttrs or passthru: this must not touch the derivation. The
        # extra attribute only gives `nix build .#darling-buck2-prefix.stageProject` something
        # to resolve, so scripts/buck-lowering-stage-check.nu can read the staging script in
        # seconds instead of discovering a staging bug 90 minutes into a build.
        # `named` as well as stageProject, so packages.darling-buck2-all can link-farm THESE
        # derivations instead of lowering the graph a second time with different arguments.
        lowered.named."root//buck/prefix:darling_prefix" // { inherit (lowered) stageProject named; };

      # Task #44, the experiment and nothing more: the same lowering with narrowSources on.
      #
      # A DUPLICATE rather than a shared function on purpose. The question the experiment
      # asks is whether the narrowed source union builds, and the only way to be sure the
      # comparison is honest is for the default expression above to stay byte for byte what
      # it was, which a refactor cannot promise without a second evaluation to check it.
      # This block goes away when #44 concludes, either by flipping the default in
      # nix/lib/darlingBuck2Lower.nix or by dropping the narrowing.
      #
      # Do not lower this out of the repo instead: passing baseSrc as a path rather than the
      # flake source gives a different darling-src and therefore a different ld64, so it
      # rebuilds 26k objects and then compares against a baseline that is not this one.
      # THE MINIMAL ENDPOINT WITH narrowSources ON (#54). packages.darling-buck2-prefix-narrow
      # exists already but lowers the FULL target list and the full prefix, so testing the flag
      # there costs a graph this store may not hold plus a two hour build. This pairs the flag
      # with buck2-targets-min.nix, which reuses the graph the minimal endpoint already built,
      # so one target can be tried in seconds and the whole endpoint in about an hour.
      #
      # WHY narrowSources RATHER THAN sourceGroups, measured: splitting the source into
      # per-subtree stores cannot work here. A link farm cannot repair a relative escape, since
      # the kernel resolves .. against the REAL parent once it crosses the farm symlink, and
      # rewriting escapes to absolute paths relocates the problem rather than solving it, 143
      # dangling links becoming 413, because the destination store has escapes of its own. The
      # SDK usr/include extracted alone is 1,987 dangling of 1,987 symlinks against 0 of 2,928
      # inside the assembled tree. A builtins.path union keeps the PROJECT ROOT, so the
      # relative web resolves, and is keyed on FILTERED CONTENT, so a target whose own files
      # did not change keeps its path when the project moves.
      #
      #   nix build .#darling-buck2-prefix-min-narrow --max-jobs 2 --cores 4
      packages.darling-buck2-prefix-min-narrow =
        pkgs:
        let
          darlingSrc = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
          ld64 = pkgs.callPackage ./nix/cctools-port.nix { src = darlingSrc; };
          lowered = import ./nix/lib/darlingBuck2Lower.nix {
            inherit pkgs darlingSrc ld64;
            allPins = true;
            narrowSources = true;
            extraTools =
              let
                di = pkgs.callPackage ./nix/darlingBuildInputs.nix { };
              in
              di.wrappedLibs ++ di.hostHeaderLibs;
            graph = import ./nix/lib/darlingBuck2Graph.nix {
              inherit pkgs darlingSrc ld64;
              allPins = true;
              targets = import ./nix/lib/buck2-targets-min.nix;
            };
          };
        in
        lowered.named."root//buck/prefix-min:darling_prefix_min"
        // { inherit (lowered) stageProject named; };

      # THE PINS, ONE STORE PATH EACH (#54), so the check below can compare them against the
      # assembled tree they replace. The lowering plants pins from darling-src, which is ONE
      # path that moves when any tracked file changes, and that is what made source groups
      # buy nothing: editing one ObjC file moved 588 of the 601 lines in a target's staging
      # script, every one of them a darling-src path.
      #
      #   nix build .#darling-pin-stores
      #   scripts/buck-pin-store-check.nu
      packages.darling-pin-stores =
        pkgs:
        let
          darlingSrc = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
        in
        # Nested at src/external/<pin> because that is where they are staged, so the farm reads
        # like the tree it stands in for. It does NOT fix the escaping links, and the attempt
        # to make it do so is worth recording because it eliminates a whole approach.
        #
        # A LINK FARM CAN NEVER REPAIR A RELATIVE ESCAPE. 14 of the 21 links that reach out of
        # a pin point at a SIBLING pin three levels up, and laying the farm out at
        # src/external/<pin> puts that sibling exactly where the ../../../ says. It still
        # dangles, because the kernel resolves .. against the REAL parent directory once it has
        # crossed the farm symlink, not against the path you typed. Measured:
        #   readlink -f <farm>/src/external/IOKitUser/darling/submodules/xnu
        #   -> /nix/store/xnu
        # three levels up from the PIN STORE, which is /nix/store, while
        # <farm>/src/external/xnu exists and is never consulted.
        #
        # So every one of the 21 needs rewriting to an absolute path, or the pins have to live
        # in one real tree, which is the assembled darling-src they came from.
        #
        # Check with: scripts/buck-escape-check.py resolve <this farm>
        pkgs.linkFarm "darling-pin-stores" (
          pkgs.lib.mapAttrsToList (path: drv: {
            name = path;
            path = drv;
          }) darlingSrc.pinPaths
        );

      # THE MINIMAL PREFIX. The same endpoint restricted to what the goal actually needs -- a
      # prefix that boots, runs bash and can run nix -- by dropping the GUI frameworks, the
      # private frameworks and the scripting languages. Measured on the full graph those are
      # 8,142 + 2,250 + 1,197 of 27,591 actions, about 42 percent, and 1,923 of 4,314 install
      # entries. The full prefix above is untouched and remains the parity target.
      #
      #   nix build .#darling-buck2-prefix-min
      packages.darling-buck2-prefix-min =
        pkgs:
        let
          darlingSrc = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
          ld64 = pkgs.callPackage ./nix/cctools-port.nix { src = darlingSrc; };
          lowered = import ./nix/lib/darlingBuck2Lower.nix {
            inherit pkgs darlingSrc ld64;
            allPins = true;
            # COARSE PINS ON (#67), and THIS endpoint is the one it was verified against.
            # buck-src is 59 percent of the graph and nobody edits a file in it: a pin moves
            # as a whole new upstream release or not at all, so one derivation per target
            # there buys nothing and costs a staging pass each.
            #
            # MEASURED here by evaluation, before anything was built:
            #   derivations in the closure   10,093 -> 9,490   (603 fewer)
            #   of which stage-trees          4,159 -> 4,159   (unchanged)
            #   real target derivations       2,333 -> 1,730   (25.8 percent fewer)
            # The estimate this replaces said about 1,196 fewer and 31 percent fewer staging
            # passes. That number was the FULL prefix, not this one.
            #
            # THEN BUILT AND COMPARED BY CONTENT, which is the only valid check here because
            # the prefix output is deferred and its path moves either way. 1,049 derivations
            # built, zero failures, and the result is byte identical to the fine grained
            # baseline: 9,979 entries and sha256-hkJQ0xJVx6tDzrBt2bsISkYDCvJtNXsQ08NTwxk9ADQ=
            # both ways, at two DIFFERENT store paths.
            #
            # THE FULL PREFIX IS NOT VERIFIED COARSE, which is why this is set here and the
            # default in darlingBuck2Lower.nix stays off. That endpoint carries the GUI and
            # scripting cones this one drops, and packages.darling-buck2-prefix-coarse is the
            # vehicle for checking it the same way. Deleting this one line restores the fine
            # grained baseline.
            coarsePins = true;
            # The host ELF libraries wrapgen dlopen's, declared for exactly the reason
            # extraTools exists: a wrap_elf action's fifth argument is the elf_lib_dirs
            # string, so the recorded argv carries those store paths as PLAIN TEXT, the
            # dump discards string context, and Nix cannot see the dependency. Undeclared,
            # the sandbox does not have them and the action dies with "Cannot load
            # libX11.so" -- the same failure the graph derivation hit one stage earlier.
            #
            # hostHeaderLibs as well as wrappedLibs, and for the same reason one step over:
            # a compile's argv carries -I into xorgproto, zlib, linux-headers and the rest
            # as plain text, so those store paths are equally invisible to Nix. Declaring
            # only the ELF set is what left fseventsd_obj failing on linux/types.h in the
            # lowering after the graph stage had been fixed.
            #
            # Only here: the libsimple, migcom and blocks endpoints below lower graphs with
            # no wrap_elf in them.
            extraTools =
              let
                di = pkgs.callPackage ./nix/darlingBuildInputs.nix { };
              in
              di.wrappedLibs ++ di.hostHeaderLibs;
            # #54 IS OFF AGAIN HERE, and what turning it on bought and cost is worth keeping.
            # It DID cut the cascade: editing one unrelated ObjC file rebuilt 0 compiles rather
            # than 323, verified on libsimple_darlingserver. Then the endpoint build failed
            # 1,194 targets on missing headers, the first being CoreServices/MacTypes.h.
            #
            # The cause is not the group LIST. Accounts_obj does stage
            # darwin/frameworks/CoreServices. It is that a group is staged as ONE SYMLINK to
            # its own store path, while 2,306 of the 2,970 symlinks in this tree are relative
            # and cross a group boundary. darwin/frameworks/CoreServices/include/CoreServices/
            # MacTypes.h is itself a link to ../../../../basic-headers/MacTypes.h: under one
            # shared projectSrc that resolves inside the same store path, and under groups it
            # resolves inside the CoreServices store path and dangles.
            #
            # The escapes are concentrated, which is what makes a fix tractable:
            # darwin/Developer/Platforms 2,189, darwin/frameworks/SystemConfiguration 52,
            # src/opendirectory_internal/include 24, src/startup/mldr 16, src/libm/include 7,
            # and ten groups with three or fewer. Run scripts/buck-escape-check.py groups.
            #
            # 1,989 of them land in the PINS, so the pins have to become self contained first:
            # they are not, 21 links reach out of their own pin, and rewriting group escapes at
            # the assembled tree instead would make the SDK group depend on all of it and hand
            # back the whole cascade.
            #
            # packages.darling-buck2-prefix-grouped below is where that gets tried next, so
            # this endpoint stays buildable meanwhile.
            graph = import ./nix/lib/darlingBuck2Graph.nix {
              inherit pkgs darlingSrc ld64;
              allPins = true;
              targets = import ./nix/lib/buck2-targets-min.nix;
            };
          };
        in
        # `//` rather than overrideAttrs or passthru: this must not touch the derivation. The
        # extra attribute only gives `nix build .#darling-buck2-prefix.stageProject` something
        # to resolve, so scripts/buck-lowering-stage-check.nu can read the staging script in
        # seconds instead of discovering a staging bug 90 minutes into a build.
        # `named` as well as stageProject, so packages.darling-buck2-all can link-farm THESE
        # derivations instead of lowering the graph a second time with different arguments.
        lowered.named."root//buck/prefix-min:darling_prefix_min" // { inherit (lowered) stageProject named; };

      # ONE TARGET, ONE COMMAND, ONE EVAL (task #68). The most common operation in this work is
      # "does this one target still build, and what RAN", and it used to cost TWO evaluations of
      # the same 307 MB graph because named."root//..." is not addressable from the CLI: a
      # nix eval --apply to get the drvPath, then a nix build of that path.
      #
      # libsimple_darlingserver is the canonical probe: one C source, one include root, one
      # archive action, so it exercises load, rule, provider, glob and three action kinds and
      # still builds in seconds.
      #
      # Reached THROUGH the minimal endpoint rather than lowered separately, and that is the
      # whole point. A second lowering with its own arguments would be a different derivation,
      # and checking it would say nothing about the endpoint. This is literally one of the 2,339
      # derivations that .#darling-buck2-prefix-min builds.
      #
      #   nix build .#darling-buck2-one --no-link -L
      #   scripts/buck-quick-check.nu
      packages.darling-buck2-one =
        pkgs: pkgs.darling-buck2-prefix-min.named."root//src/libsimple:libsimple_darlingserver";

      # Task #44, the experiment and nothing more: the same lowering with narrowSources on.
      #
      # A DUPLICATE rather than a shared function on purpose. The question the experiment
      # asks is whether the narrowed source union builds, and the only way to be sure the
      # comparison is honest is for the default expression above to stay byte for byte what
      # it was, which a refactor cannot promise without a second evaluation to check it.
      # This block goes away when #44 concludes, either by flipping the default in
      # nix/lib/darlingBuck2Lower.nix or by dropping the narrowing.
      #
      # Do not lower this out of the repo instead: passing baseSrc as a path rather than the
      # flake source gives a different darling-src and therefore a different ld64, so it
      # rebuilds 26k objects and then compares against a baseline that is not this one.

      packages.darling-buck2-prefix-narrow =
        pkgs:
        let
          darlingSrc = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
          ld64 = pkgs.callPackage ./nix/cctools-port.nix { src = darlingSrc; };
          lowered = import ./nix/lib/darlingBuck2Lower.nix {
            inherit pkgs darlingSrc ld64;
            allPins = true;
            narrowSources = true;
            # The host ELF libraries wrapgen dlopen's, declared for exactly the reason
            # extraTools exists: a wrap_elf action's fifth argument is the elf_lib_dirs
            # string, so the recorded argv carries those store paths as PLAIN TEXT, the
            # dump discards string context, and Nix cannot see the dependency. Undeclared,
            # the sandbox does not have them and the action dies with "Cannot load
            # libX11.so" -- the same failure the graph derivation hit one stage earlier.
            #
            # hostHeaderLibs as well as wrappedLibs, and for the same reason one step over:
            # a compile's argv carries -I into xorgproto, zlib, linux-headers and the rest
            # as plain text, so those store paths are equally invisible to Nix. Declaring
            # only the ELF set is what left fseventsd_obj failing on linux/types.h in the
            # lowering after the graph stage had been fixed.
            #
            # Only here: the libsimple, migcom and blocks endpoints below lower graphs with
            # no wrap_elf in them.
            extraTools =
              let
                di = pkgs.callPackage ./nix/darlingBuildInputs.nix { };
              in
              di.wrappedLibs ++ di.hostHeaderLibs;
            graph = import ./nix/lib/darlingBuck2Graph.nix {
              inherit pkgs darlingSrc ld64;
              allPins = true;
              targets = import ./nix/lib/buck2-targets.nix;
            };
          };
        in
        # `//` rather than overrideAttrs or passthru: this must not touch the derivation. The
        # extra attribute only gives `nix build .#darling-buck2-prefix.stageProject` something
        # to resolve, so scripts/buck-lowering-stage-check.nu can read the staging script in
        # seconds instead of discovering a staging bug 90 minutes into a build.
        # `named` as well as stageProject, so packages.darling-buck2-all can link-farm THESE
        # derivations instead of lowering the graph a second time with different arguments.
        lowered.named."root//buck/prefix:darling_prefix" // { inherit (lowered) stageProject named; };

      # The same endpoint with each buck-src PIN lowered as one derivation instead of one
      # per target (#53). buck-src is 58.9 percent of the actions and only moves when a
      # submodule pin is bumped, so per-target granularity there buys nothing and costs a
      # staging pass per target, which is what limits a full rebuild.
      #
      # A SEPARATE ATTRIBUTE, deliberately, so darling-buck2-prefix stays byte-comparable
      # against the tree that is already built and verified. The comparison is the point:
      #   nix build .#darling-buck2-prefix-coarse --max-jobs 4 --cores 6
      # then diff its prefix against .#darling-buck2-prefix file list and per-file sha256,
      # which is how #52 was proven.
      # The same endpoint with each target staged from ONLY the source groups it reads
      # (#54), instead of one shared project path that every target takes. That shared path
      # is why any edit rebuilds everything: change a byte in it and all 3,225 targets move.
      #
      # A SEPARATE ATTRIBUTE so darling-buck2-prefix stays byte-comparable. The test that
      # matters is not that this builds, it is that an unrelated edit does NOT rebuild:
      #   nix build .#darling-buck2-prefix-grouped   (once)
      #   touch a file under darwin/frameworks/Quartz, which no pin target reads
      #   nix build .#darling-buck2-prefix-grouped   (a pin target must NOT rerun)
      #   touch darwin/basic-headers, which 1,326 pin targets do read
      #   nix build .#darling-buck2-prefix-grouped   (they MUST rerun)
      packages.darling-buck2-prefix-grouped =
        pkgs:
        let
          darlingSrc = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
          ld64 = pkgs.callPackage ./nix/cctools-port.nix { src = darlingSrc; };
          lowered = import ./nix/lib/darlingBuck2Lower.nix {
            inherit pkgs darlingSrc ld64;
            allPins = true;
            sourceGroups = true;
            extraTools =
              let
                di = pkgs.callPackage ./nix/darlingBuildInputs.nix { };
              in
              di.wrappedLibs ++ di.hostHeaderLibs;
            graph = import ./nix/lib/darlingBuck2Graph.nix {
              inherit pkgs darlingSrc ld64;
              allPins = true;
              targets = import ./nix/lib/buck2-targets.nix;
            };
          };
        in
        lowered.named."root//buck/prefix:darling_prefix" // { inherit (lowered) stageProject named; };

      packages.darling-buck2-prefix-coarse =
        pkgs:
        let
          darlingSrc = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
          ld64 = pkgs.callPackage ./nix/cctools-port.nix { src = darlingSrc; };
          lowered = import ./nix/lib/darlingBuck2Lower.nix {
            inherit pkgs darlingSrc ld64;
            allPins = true;
            coarsePins = true;
            # Same reason as the narrow variant above: a wrap_elf argv carries these store
            # paths as PLAIN TEXT, so Nix cannot see the dependency and the sandbox would
            # not have them.
            extraTools =
              let
                di = pkgs.callPackage ./nix/darlingBuildInputs.nix { };
              in
              di.wrappedLibs ++ di.hostHeaderLibs;
            graph = import ./nix/lib/darlingBuck2Graph.nix {
              inherit pkgs darlingSrc ld64;
              allPins = true;
              targets = import ./nix/lib/buck2-targets.nix;
            };
          };
        in
        lowered.named."root//buck/prefix:darling_prefix" // { inherit (lowered) stageProject named; };

      # The buck2-built Darling as something installable: the lowered prefix plus the one
      # launcher script that supplies the two paths the daemon reads from the environment.
      #   nix build .#darling-buck2 && ./result/bin/darling-buck2 shell /bin/bash -c ...
      # The PREFIX package, not a second lowering of the same graph. It used to build its own,
      # with the same arguments EXCEPT extraTools, and extraTools goes into the
      # nativeBuildInputs of every lowered derivation -- so the two entry points produced two
      # disjoint sets of ~671 derivations, and building one did nothing for the other. Worse,
      # the copy without extraTools is the configuration that cannot work: a wrap_elf action
      # dlopens the host libX11 and friends at BUILD time, so without them in the sandbox it
      # dies with "Cannot load libX11.so", which is exactly the failure task #35 fixed on the
      # graph side. The VM test in checks/ consumes THIS package, and it passes: exit 0, the
      # container up in under half a second and the guest bash reporting 3.2.57 and darwin.
      #
      # Measured rather than asserted, since the whole point is that there is only ONE
      # lowering: the built darling-buck2.drv consumes exactly the store path that
      # .#darling-buck2-prefix produces, and the endpoint builds green with extraTools,
      # 3216 derivations and no errors.
      packages.darling-buck2 =
        pkgs:
        pkgs.callPackage ./nix/buck2-package.nix {
          # The lowered target's output holds the tree under its own name.
          prefix = "${pkgs.darling-buck2-prefix}/darling_prefix__prefix";
        };

      packages.darling-buck2-all-graph =
        pkgs:
        import ./nix/lib/darlingBuck2Graph.nix {
          inherit pkgs;
          darlingSrc = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
          ld64 = pkgs.callPackage ./nix/cctools-port.nix {
            src = import ./nix/lib/darling-src.nix {
              inherit pkgs;
              baseSrc = ./.;
            };
          };
          allPins = true;
          targets = import ./nix/lib/buck2-targets.nix;
        };

      # ── Off git submodules: nix-pinned source tree ───────────────────
      #
      # Darling's 147 vendored trees, assembled from fetchFromGitHub pins in
      # nix/submodules.json instead of git submodules (see PLAN.md
      # and nix/lib/darling-src.nix). Build WITHOUT ?submodules=1 -- darling-src
      # overlays every pinned submodule onto this flake's own tree and applies
      # patches/<name>/. Partial until every hash is filled
      # (scripts/prefetch-submodule-hashes.nu); passthru.unpinnedPaths lists gaps.
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

      # The same graph at the CLI component scope. The buck2 port is generated from the
      # system scope, which builds no userland at all: uname, sw_vers, the coreutils,
      # sandbox-exec, diskutil and dscl -- everything tests/darling-smoke.nix exercises
      # besides bash -- are absent from it. This is what says how much bigger cli is.
      #   nix build .#darling-graph-cli
      # And at the STOCK scope, the full build. Needed to size what "Nix running under
      # Darling" costs: the guest has to host a real userland, and cli does not carry
      # everything (libcurl and libsqlite3 among the gaps).
      #   nix build .#darling-graph-stock
      packages.darling-graph-stock =
        pkgs:
        import ./nix/lib/darling-graph.nix {
          inherit pkgs;
          overby = inputs.overby;
          components = "stock";
        };

      packages.darling-graph-cli =
        pkgs:
        import ./nix/lib/darling-graph.nix {
          inherit pkgs;
          overby = inputs.overby;
          components = "cli";
        };

      # And the WHOLE build: `all` is stock plus jsc, webkit, cli_extra and
      # cli_dev_gui_stubs (cmake/darling_parse_components.cmake). This is the last
      # scope, and what full parity with upstream Darling is measured against.
      #   nix build .#darling-graph-all
      packages.darling-graph-all =
        pkgs:
        import ./nix/lib/darling-graph.nix {
          inherit pkgs;
          overby = inputs.overby;
          components = "all";
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

      # The base-filtered, cycle-condensed component DAG as JSON (component-dag.py
      # over the ninja graph): 286 components, 13 base-covered, 186 generated, the
      # 12 genuine cross-component deps. Inspection / driver for the codegen.
      #   nix build .#darling-component-dag && cat result
      packages.darling-component-dag =
        pkgs:
        (import ./nix/lib/darling-components.nix {
          inherit pkgs;
          overby = inputs.overby;
        }).dag;

      # #78 first test of lowerGroupsBy: build migcom (a host tool, small closure,
      # no libSystem) with ALL its edges in ONE group -- validates the emit-a-mini-
      # build.ninja-and-run grouped lowering cheaply before per-component grouping.
      #   nix build .#darling-group-test
      packages.darling-group-test =
        pkgs:
        (import ./nix/lib/darlingNinja.nix {
          inherit pkgs;
          overby = inputs.overby;
        }).buildTarget {
          target = "src/external/bootstrap_cmds/migcom";
          grouping = _: "all";
        };

      # #78 second test: split migcom's closure into TWO groups to exercise
      # EXTERNAL-group staging (a group symlinking another group's outputs). The
      # bison/flex CUSTOM_COMMANDs (lexer.c/parser.c) go in group "gen"; the compiles
      # and link go in "main". "main" consumes gen's generated lexer.c/parser.c, so it
      # depends on the "gen" group's output derivation (acyclic: gen needs only
      # sources). Validates cp -rs of an upstream group before real per-component.
      #   nix build .#darling-group-test2
      packages.darling-group-test2 =
        pkgs:
        (import ./nix/lib/darlingNinja.nix {
          inherit pkgs;
          overby = inputs.overby;
        }).buildTarget {
          target = "src/external/bootstrap_cmds/migcom";
          grouping = e: if (e.rule or "") == "CUSTOM_COMMAND" then "gen" else "main";
        };

      # #78 third test: the REAL per-component grouping (componentGrouping) -- each
      # CMake target is its own input-isolated group, links inherit their compiles'
      # target. On migcom this yields the ::migcom group (compiles+link) depending on
      # the bootstrap_cmds gen group (lexer.c/parser.c). Same engine, real grouping fn.
      #   nix build .#darling-group-test3
      packages.darling-group-test3 =
        pkgs:
        let
          dn = import ./nix/lib/darlingNinja.nix {
            inherit pkgs;
            overby = inputs.overby;
          };
        in
        dn.buildTarget {
          target = "src/external/bootstrap_cmds/migcom";
          grouping = dn.componentGrouping;
        };

      # Task #80: same migcom grouping, but the per-edge lowering runs at BUILD time
      # (lower_group.py) instead of in Nix eval. Proof target for the fast-eval refactor.
      #   nix build .#darling-group-test3-bt
      packages.darling-group-test3-bt =
        pkgs:
        let
          dn = import ./nix/lib/darlingNinja.nix {
            inherit pkgs;
            overby = inputs.overby;
          };
        in
        dn.buildTarget {
          target = "src/external/bootstrap_cmds/migcom";
          grouping = dn.componentGrouping;
          buildTimeLowering = true;
        };

      # #78 core milestone: build libSystem.B.dylib (the core umbrella: ~13 core
      # components with real cross-group deps + heavy Mach/kernel header staging) via
      # per-component grouping. The first grouped build that exercises libSystem-scale
      # cross-component staging, not just a self-contained host tool.
      #   nix build .#darling-libsystem-group
      packages.darling-libsystem-group =
        pkgs:
        let
          dn = import ./nix/lib/darlingNinja.nix {
            inherit pkgs;
            overby = inputs.overby;
          };
        in
        dn.buildTarget {
          target = "src/external/libsystem/libSystem.B.dylib";
          grouping = dn.componentGrouping;
        };

      # Task #80: libSystem via build-time lowering (correctness gate at umbrella scale).
      packages.darling-libsystem-group-bt =
        pkgs:
        let
          dn = import ./nix/lib/darlingNinja.nix {
            inherit pkgs;
            overby = inputs.overby;
          };
        in
        dn.buildTarget {
          target = "src/external/libsystem/libSystem.B.dylib";
          grouping = dn.componentGrouping;
          buildTimeLowering = true;
        };

      # #78 GOAL: the full darling built via per-component grouping. No explicit
      # target -> the manifest's `default` (the `all` phony) -> every final artifact,
      # each materialized from its component group derivation (dependency groups built
      # transitively). This is the "fully build everything via grouping" deliverable.
      #   nix build .#darling-full-group
      packages.darling-full-group =
        pkgs:
        let
          dn = import ./nix/lib/darlingNinja.nix {
            inherit pkgs;
            overby = inputs.overby;
          };
        in
        dn.buildTarget {
          grouping = dn.componentGrouping;
        };

      # Task #80: the full grouped build via build-time lowering. The eval-speed target
      # (~1-2min eval vs the eval-time path's ~15-40min).
      #   nix build .#darling-full-group-bt
      packages.darling-full-group-bt =
        pkgs:
        let
          dn = import ./nix/lib/darlingNinja.nix {
            inherit pkgs;
            overby = inputs.overby;
          };
        in
        dn.buildTarget {
          grouping = dn.componentGrouping;
          buildTimeLowering = true;
        };

      # ── The darling host-side daemon (Rust) ──────────────────────────
      #
      # The Rust `server` (PLAN.md), built reproducibly. It consumes
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
      # See: docs/darwin-builder.md, PLAN.md (Task 7.7)
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
      # See: PLAN.md (Tasks 6.1, 6.2, 7.5)
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

          # ── The Buck2 Nix endpoint ─────────────────────────────────────
          # scripts/buck-test.nu gates the buck2 DAEMON path; nothing gated the
          # Nix one until this. Deliberately the cheap end of it: libsimple needs
          # no pins, so its graph derivation is a small buck2 build rather than
          # the 4 GB pin materialization a guest target pulls in. It still
          # exercises the whole pipeline -- buck2 in a pure derivation, the graph
          # dump, the placeholder round trip, and one derivation per target.
          #   nix build .#checks.x86_64-linux.buck2-endpoint -L
          buck2-endpoint =
            pkgs.runCommand "buck2-endpoint-check"
              { }
              ''
                lib=${
                  (import ./nix/lib/darlingBuck2Lower.nix {
                    inherit pkgs;
                    graph = import ./nix/lib/darlingBuck2Graph.nix {
                      inherit pkgs;
                      targets = [ "//src/libsimple:libsimple_darlingserver" ];
                    };
                  }).final
                }/liblibsimple_darlingserver.a
                test -f "$lib" || { echo "no archive at $lib" >&2; exit 1; }
                ${pkgs.llvmPackages.bintools}/bin/nm "$lib" | grep -q libsimple_lock_lock \
                  || { echo "archive has no libsimple symbols" >&2; exit 1; }
                echo ok > $out
              '';

          # ── Rust darling daemon: build + run its demos ─────────────────
          # Builds `server` (the Rust host-side daemon) and runs its proof/demo
          # binaries, asserting each prints its OK marker -- the whole daemon
          # pipeline (link + dtape_init, the microthread scheduler, the byte-parity
          # wire codec, the code-generated dispatch, per-guest routing, the epoll
          # loop) exercised end to end. See PLAN.md.
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

          # ── The BUCK2-built Darling, in the same harness ───────────────
          # The bash milestone in a VM. darling-smoke above cannot run against the port
          # yet: it exercises a userland the system component scope does not build.
          darling-buck2-smoke = import ./tests/darling-buck2-smoke.nix {
            inherit pkgs;
            darling = pkgs.darling-buck2;
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
