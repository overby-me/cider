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

      # THE DEFAULT PACKAGE IS THE BUCK2 BUILD. cmake is gone (#82): the user does not ship
      # it, and it was the only consumer of nix/package.nix, nix/xnu-sys.nix,
      # nix/cctools-port.nix and the darling-graph/base/component/Ninja libs. mkForce is still
      # needed because flakelight autoloads ./nix/package.nix by name if it exists.
      packages.default = inputs.nixpkgs.lib.mkForce (pkgs: pkgs.darling-buck2);

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
          { target = "//src/external/darlingserver/xnu-sys:darlingserver_duct_tape"; };

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
      # allPins, same target list), so it is the way to exercise or debug the
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
        in
        import ./nix/lib/darlingBuck2Graph.nix {
          inherit pkgs darlingSrc;
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
      #            system_dyld_final fail.
      #   4. 539s  THE ACTUAL CAUSE, once the dump stopped truncating buck2 stderr to the last
      #            1500 characters. Inside the BXL step buck2 prints
      #              Waiting on //linux/server:dtape_bindings -- action (bindgen ...)
      #              Waiting on //src/hosttools:darling-coredump -- action (cxx_compile ...)
      #              Action failed: //buck-src:libtrustd_obj (c_compile TrustURLSessionCache.m)
      #            on Foundation/NSAppleEventDescriptor.h "expected a type".
      #
      # SO THE DUMP COMPILES, and that is the blocker rather than the keep list. Widening the
      # list only feeds more real headers to compiles that should not run at all.
      # buck/bxl/materialize.bxl says in its own comment that it stopped ensuring DEFAULT
      # OUTPUTS for exactly this reason, and that part of its code is correct: the loop adds
      # only CcLibInfo.include_dirs and InProcInfo.artifacts. Something in those still reaches
      # objects. For libtrustd_obj specifically, audited: its InProcInfo.artifacts is EMPTY and
      # every CcLibInfo.include_dir is bound to a DIFFERENT target, so it is not being pulled
      # in through its own providers. Unproven hypothesis: the symlinked dependency FARMS that
      # InProcInfo carries link to build outputs, so ensuring a farm builds its contents.
      # Answer it by printing, per ensured artifact, which target it is bound to.
      #
      #   nix build .#darling-buck2-graph-min-skeleton -L
      # The SAME graph from the PROJECT, so the skeleton has something honest to be compared
      # against. Without this the only project-fed graph addressable on its own is the full
      # one, and comparing a minimal skeleton graph to a full project graph would report
      # differences that are just the target list. Identical arguments to the attribute below
      # except skeleton, which is the point.
      #
      #   nix build .#darling-buck2-graph-min -L
      packages.darling-buck2-graph-min =
        pkgs:
        let
          darlingSrc = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
        in
        import ./nix/lib/darlingBuck2Graph.nix {
          inherit pkgs darlingSrc;
          allPins = true;
          targets = import ./nix/lib/buck2-targets-min.nix;
        };

      packages.darling-buck2-graph-min-skeleton =
        pkgs:
        let
          darlingSrc = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
        in
        import ./nix/lib/darlingBuck2Graph.nix {
          inherit pkgs darlingSrc;
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
      # Darling's own ld64, now the buck2 BUILT one (#65), and goes through the
      # firstpass/final pair, which is the shape every one of the port's 132 dylibs has.
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
          in
          import ./nix/lib/darlingBuck2Lower.nix {
            inherit pkgs darlingSrc;
            allPins = true;
            graph = import ./nix/lib/darlingBuck2Graph.nix {
              inherit pkgs darlingSrc;
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
          lowered = import ./nix/lib/darlingBuck2Lower.nix {
            inherit pkgs darlingSrc;
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
              inherit pkgs darlingSrc;
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
        lowered.named."root//buck/prefix:darling_prefix" // { inherit (lowered) stageProject named drvs pinsTree; };

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
      # flake source gives a different darling-src, which moves the graph and with it every
      # lowered derivation, so it rebuilds the world and then compares against a baseline
      # that is not this one. (It used to move ld64 as well, 26k objects; #65 removed that.)
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
      # FIRST REAL EVIDENCE FOR #69, and it cost 340 seconds rather than the 90 minutes the
      # endpoint wants. Two targets through THIS lowering, picked as one of each kind the
      # narrowing has broken before, a compile and a generator:
      #   root//src/libsimple:libsimple_darlingserver   c_compile src/lock.c, then archive
      #   root//src/external/darlingserver:dserver_rpc  script_gen, runs a python3 out of scripts/
      # exit 0, 5 builders, 0 errors. So narrowSources is not obviously wrong, which is all one
      # target can say. The endpoint hash and the default flip are still unverified.
      #
      #   nix build .#darling-buck2-prefix-min-narrow --max-jobs 2 --cores 4
      packages.darling-buck2-prefix-min-narrow =
        pkgs:
        let
          darlingSrc = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
          lowered = import ./nix/lib/darlingBuck2Lower.nix {
            inherit pkgs darlingSrc;
            allPins = true;
            narrowSources = true;
            # THE SAME SETTINGS THE UNNARROWED ENDPOINT USES, and leaving them off is what made
            # the first cascade measurement worthless. narrowSources cannot cut anything while
            # the GRAPH still moves on a source edit, because every lowered derivation is
            # downstream of it. Measured without these: a one line edit to one .m needed 6,502
            # derivations, the whole endpoint, which is the number the unnarrowed endpoint
            # posts too. So the narrowing was measured on an endpoint where it could not
            # possibly show, and the result said nothing about narrowSources at all.
            coarsePins = true;
            extraTools =
              let
                di = pkgs.callPackage ./nix/darlingBuildInputs.nix { };
              in
              di.wrappedLibs ++ di.hostHeaderLibs;
            graph = import ./nix/lib/darlingBuck2Graph.nix {
              inherit pkgs darlingSrc;
              allPins = true;
              skeleton = true;
              targets = import ./nix/lib/buck2-targets-min.nix;
            };
          };
        in
        lowered.named."root//buck/prefix-min:darling_prefix_min"
        // { inherit (lowered) stageProject named drvs pinsTree; };

      # THE MINIMAL ENDPOINT WITH sourceGroups ON (#54), which is the flag with the RIGHT
      # granularity: with it on, editing ACAccount.m and rebuilding libsimple_darlingserver ran
      # 0 builders against 323 with neither flag. What it lacked was a staging that survives a
      # relative escape, and stageGroupsFor now mirrors a group with real directories and one
      # link per file instead of linking the group directory. packages.darling-buck2-prefix-
      # grouped exists already but lowers the FULL target list, so testing the flag there costs
      # a graph this store may not hold; this pairs it with buck2-targets-min.nix, which reuses
      # the graph the minimal endpoint already built, so ONE target can be tried in minutes.
      #
      #   nix build .#darling-buck2-prefix-min-grouped.named.\"root//src/libsimple:libsimple_darlingserver\"
      packages.darling-buck2-prefix-min-grouped =
        pkgs:
        let
          darlingSrc = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
          lowered = import ./nix/lib/darlingBuck2Lower.nix {
            inherit pkgs darlingSrc;
            allPins = true;
            sourceGroups = true;
            coarsePins = true;
            extraTools =
              let
                di = pkgs.callPackage ./nix/darlingBuildInputs.nix { };
              in
              di.wrappedLibs ++ di.hostHeaderLibs;
            graph = import ./nix/lib/darlingBuck2Graph.nix {
              inherit pkgs darlingSrc;
              allPins = true;
              skeleton = true;
              targets = import ./nix/lib/buck2-targets-min.nix;
            };
          };
        in
        lowered.named."root//buck/prefix-min:darling_prefix_min"
        // { inherit (lowered) stageProject named drvs pinsTree; };

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
          lowered = import ./nix/lib/darlingBuck2Lower.nix {
            inherit pkgs darlingSrc;
            # NO ld64 (#65). The darwin toolchain now drives the buck2 BUILT linker through
            # ld_target, so the @LD64@ placeholder is referenced by 0 of 17,552 actions and
            # nothing needs the external one on PATH. Passing it anyway kept
            # nix/cctools-port.nix an input of every lowered derivation, and its src is the
            # ENTIRE assembled project, so it rebuilt on every first party edit: about 15 of
            # the 17.5 minutes such an edit cost.
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
            # SOURCE GROUPS ON BY DEFAULT (#54). The grouped endpoint is verified byte
            # identical to this one: 1,617 builders, 0 root failures, and the prefix hashes to
            # sha256-hkJQ0xJVx6tDzrBt2bsISkYDCvJtNXsQ08NTwxk9ADQ=, the recorded content. With it
            # on, an unrelated source edit no longer rebuilds a target: SecItemShimOSX_obj
            # measured at 2 builders with its output path unchanged, against a full rebuild
            # before.
            sourceGroups = true;
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
              inherit pkgs darlingSrc;
              # NO ld64 here either: it also wrote ld and ld64_dir into the buckconfig the dump
              # uses, which ld_target supersedes.
              allPins = true;
              # THE SKELETON (#56), and this is what stops a C edit rebuilding the graph.
              # The dump gets a tree whose C family is emptied outside buck-src, buck-rust and
              # src/external, keeping the 119 files that feed a generator
              # (scripts/buck-codegen-keep.txt). Editing a .c changes no file NAME, so that
              # tree is byte identical, the dump does not rerun, and about 10 minutes leaves
              # every source edit.
              #
              # SAFE BECAUSE THE GRAPHS ARE IDENTICAL, not merely equivalent. Built both ways
              # from different derivations, they resolve to the same content addressed outputs:
              #   out   8rsv2w3c71rg5iacmw8h205g4lxbq05f-darling-buck2-graph
              #   data  4pybgzfvbrrfkkg1pqkhzcx09a33bdyj-darling-buck2-graph-data
              # See packages.darling-buck2-graph-min, which exists to make that comparison
              # honest, and scripts/buck-graph-equiv.py for the by-meaning check if the two
              # ever stop collapsing.
              skeleton = true;
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
        lowered.named."root//buck/prefix-min:darling_prefix_min" // { inherit (lowered) stageProject named drvs pinsTree; };

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
      # flake source gives a different darling-src, which moves the graph and with it every
      # lowered derivation, so it rebuilds the world and then compares against a baseline
      # that is not this one. (It used to move ld64 as well, 26k objects; #65 removed that.)

      packages.darling-buck2-prefix-narrow =
        pkgs:
        let
          darlingSrc = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
          lowered = import ./nix/lib/darlingBuck2Lower.nix {
            inherit pkgs darlingSrc;
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
              inherit pkgs darlingSrc;
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
        lowered.named."root//buck/prefix:darling_prefix" // { inherit (lowered) stageProject named drvs pinsTree; };

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
          lowered = import ./nix/lib/darlingBuck2Lower.nix {
            inherit pkgs darlingSrc;
            allPins = true;
            sourceGroups = true;
            extraTools =
              let
                di = pkgs.callPackage ./nix/darlingBuildInputs.nix { };
              in
              di.wrappedLibs ++ di.hostHeaderLibs;
            graph = import ./nix/lib/darlingBuck2Graph.nix {
              inherit pkgs darlingSrc;
              allPins = true;
              targets = import ./nix/lib/buck2-targets.nix;
            };
          };
        in
        lowered.named."root//buck/prefix:darling_prefix" // { inherit (lowered) stageProject named drvs pinsTree; };

      packages.darling-buck2-prefix-coarse =
        pkgs:
        let
          darlingSrc = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
          lowered = import ./nix/lib/darlingBuck2Lower.nix {
            inherit pkgs darlingSrc;
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
              inherit pkgs darlingSrc;
              allPins = true;
              targets = import ./nix/lib/buck2-targets.nix;
            };
          };
        in
        lowered.named."root//buck/prefix:darling_prefix" // { inherit (lowered) stageProject named drvs pinsTree; };

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

      # THE SAME PACKAGE OVER THE MINIMAL PREFIX, so there is a runtime gate that can actually
      # finish on this machine. checks.darling-buck2-smoke builds the FULL prefix, and that
      # OOM-kills the nix daemon here: measured twice, 14.6 GB RSS at --max-jobs 5 and 16.1 GB
      # at --max-jobs 2, both times killed by the kernel in the stage-tree phase with zero
      # builder failures. Lower concurrency made it worse, because daemon memory tracks DATA per
      # derivation and not job count (#48).
      #
      # The minimal prefix completes (1,617 builders, prefix hash matching) and carries what a
      # boot needs: bin/darling, bin/darlingserver, libexec/darling/bin/bash and sbin/launchd.
      # That is exactly the surface a darlingserverd change touches, so it is the right gate for
      # #71 and for anything else host-side.
      packages.darling-buck2-min =
        pkgs:
        pkgs.callPackage ./nix/buck2-package.nix {
          prefix = "${pkgs.darling-buck2-prefix-min}/darling_prefix_min__prefix";
        };

      packages.darling-buck2-all-graph =
        pkgs:
        import ./nix/lib/darlingBuck2Graph.nix {
          inherit pkgs;
          darlingSrc = import ./nix/lib/darling-src.nix {
            inherit pkgs;
            baseSrc = ./.;
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
          # The buck2 MINIMAL build: it is the gate that actually finishes on this
          # machine, and the full prefix OOM-kills the daemon (#48).
          darling = pkgs.darling-buck2-min;
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

          # The same VM harness over the MINIMAL prefix. This is the one that can finish on
          # this box; darling-buck2-smoke above needs the full prefix and OOMs the daemon.
          darling-buck2-min-smoke = import ./tests/darling-buck2-smoke.nix {
            inherit pkgs;
            darling = pkgs.darling-buck2-min;
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
