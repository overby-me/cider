{
  description = "Darling - macOS compatibility layer for Linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flakelight = {
      url = "github:nix-community/flakelight";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # nix-ninja: per-edge Nix builds of Darling (nix/lib/ciderNinja.nix).
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

      pname = "cider";

      # Disable builtin formatters — the repo has 100+ submodules with
      # broken symlinks when not checked out, which causes the formatting
      # check to fail on `diff` of missing files.
      flakelight.builtinFormatters = false;

      # Default devShell is autoloaded from ./nix/devShell.nix
      # NixOS module is autoloaded from ./nix/nixosModule.nix

      # THE DEFAULT PACKAGE IS THE BUCK2 BUILD. cmake is gone (#82): the user does not ship
      # it, and it was the only consumer of nix/package.nix, nix/xnu-sys.nix,
      # nix/cctools-port.nix and the cider-graph/base/component/Ninja libs. mkForce is still
      # needed because flakelight autoloads ./nix/package.nix by name if it exists.
      packages.default = inputs.nixpkgs.lib.mkForce (pkgs: pkgs.cider-buck2);

      # ── Nix-lowered Buck2 (plan/buck2-port.md phase 3) ───────────────
      #
      # The same BUCK definitions the buck2 daemon builds, lowered to one Nix
      # derivation per ACTION by overby's nix/lib/buck2 -- no daemon, no IFD,
      # cacheable and shareable. This smoke target is the smallest real one in the
      # port (libsimple's host-tier archive: one C source, one include root, one
      # archive action), so it exercises load/rule/provider/glob and three action
      # kinds without pulling the guest toolchain in:
      #   nix build .#cider-buck2-libsimple
      #
      # Needs the overby-side support this port added (read_root_config,
      # symlinked_dir, copy, ar), which lives on that repo's `nix-lib-buck2`
      # bookmark until it lands on main:
      #   nix build .#cider-buck2-libsimple \
      #     --override-input overby 'git+https://tangled.org/overby.me/overby.me?ref=nix-lib-buck2'
      packages.cider-buck2-libsimple =
        pkgs:
        (import ./nix/lib/ciderBuck2.nix {
          inherit pkgs;
          overby = inputs.overby;
        }).buildTarget
          { target = "//src/libsimple:libsimple_ciderd"; };

      # The host tier through the same Nix-lowered path: ciderd's xnu-sys
      # archive (real XNU osfmk/bsd sources plus mig codegen, and the artifact the
      # Rust daemon consumes via XNU_SYS_LIB). Bigger than the libsimple smoke
      # target by two orders of magnitude, and it exercises a generator TOOL built
      # by the same graph (migcom):
      #   nix build .#cider-buck2-xnu-sys
      packages.cider-buck2-xnu-sys =
        pkgs:
        (import ./nix/lib/ciderBuck2.nix {
          inherit pkgs;
          overby = inputs.overby;
        }).buildTarget
          { target = "//src/external/ciderd/xnu-sys:ciderd_xnu_sys"; };

      # A mid-size probe for the Nix-lowered path: src/duct's static archive is 8
      # sources in a 165-line BUCK file, between libsimple (80 lines) and xnu-sys
      # (1044). Which of size or feature-set the interpreter runs out of road on is
      # what this answers:
      #   nix build .#cider-buck2-duct-static
      packages.cider-buck2-duct-static =
        pkgs:
        (import ./nix/lib/ciderBuck2.nix {
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
      #     nix build .#cider-buck2-probe-sdkenv
      packages.cider-buck2-probe-sdkenv =
        pkgs:
        (import ./nix/lib/ciderBuck2.nix {
          inherit pkgs;
          overby = inputs.overby;
        }).buildTarget
          { target = "//darwin:sdk_env"; };

      packages.cider-buck2-probe-bigfile =
        pkgs:
        (import ./nix/lib/ciderBuck2.nix {
          inherit pkgs;
          overby = inputs.overby;
        }).buildTarget
          { target = "//buck-src:mig.sh"; };

      # The port's action graph, dumped by real buck2 in a pure derivation, for the
      # "graph then lower" endpoint (plan/buck2-port.md phase 3). One opt-in IFD: this
      # derivation writes what-ran.json, Nix reads that single file, and each action then
      # becomes its own derivation. Interpreting the Starlark in Nix is what this replaces.
      #
      #   systemd-run --user --scope -p MemoryMax=8G nix build .#cider-buck2-graph
      packages.cider-buck2-graph =
        pkgs:
        import ./nix/lib/ciderBuck2Graph.nix {
          inherit pkgs;
          targets = [ "//src/libsimple:libsimple_ciderd" ];
        };

      # THE REAL GRAPH, and the reason this is a separate attribute: the one above is a
      # DEMO over a single target and writes 2 command actions. A green build of it says
      # nothing about the port, which is a trap worth naming -- it was read as a passing
      # endpoint once, while the graph the endpoint actually uses was failing.
      #
      # This is byte-identical to the graph cider-buck2-prefix builds (same ciderSrc,
      # allPins, same target list), so it is the way to exercise or debug the
      # graph derivation ALONE. That matters because the two halves cost very differently:
      # the graph is one derivation of roughly 40 minutes, the lowering that follows it is
      # hundreds. Every one of tasks #35 to #38 was a graph-stage failure, and each cost a
      # full prefix build to reach.
      #
      #   nix build .#cider-buck2-graph-all -L
      packages.cider-buck2-graph-all =
        pkgs:
        let
          ciderSrc = import ./nix/lib/cider-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
        in
        import ./nix/lib/ciderBuck2Graph.nix {
          inherit pkgs ciderSrc;
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
      #              Waiting on //linux/server:xnu_sys_bindings -- action (bindgen ...)
      #              Waiting on //linux/hosttools:cider-coredump -- action (cxx_compile ...)
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
      #   nix build .#cider-buck2-graph-min-skeleton -L
      # The SAME graph from the PROJECT, so the skeleton has something honest to be compared
      # against. Without this the only project-fed graph addressable on its own is the full
      # one, and comparing a minimal skeleton graph to a full project graph would report
      # differences that are just the target list. Identical arguments to the attribute below
      # except skeleton, which is the point.
      #
      #   nix build .#cider-buck2-graph-min -L
      packages.cider-buck2-graph-min =
        pkgs:
        let
          ciderSrc = import ./nix/lib/cider-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
        in
        import ./nix/lib/ciderBuck2Graph.nix {
          inherit pkgs ciderSrc;
          allPins = true;
          targets = import ./nix/lib/buck2-targets-min.nix;
        };

      packages.cider-buck2-graph-min-skeleton =
        pkgs:
        let
          ciderSrc = import ./nix/lib/cider-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
        in
        import ./nix/lib/ciderBuck2Graph.nix {
          inherit pkgs ciderSrc;
          allPins = true;
          skeleton = true;
          targets = import ./nix/lib/buck2-targets-min.nix;
        };

      # The same graph, LOWERED: one Nix derivation per buck2 action, from the single
      # IFD of graph.json. This is the endpoint the port is aiming at -- per-action
      # caching a binary cache can serve, with buck2 as the definition authority.
      #
      #   systemd-run --user --scope -p MemoryMax=8G nix build .#cider-buck2-lowered
      packages.cider-buck2-lowered =
        pkgs:
        (import ./nix/lib/ciderBuck2Lower.nix {
          inherit pkgs;
          graph = import ./nix/lib/ciderBuck2Graph.nix {
            inherit pkgs;
            targets = [ "//src/libsimple:libsimple_ciderd" ];
          };
        }).final;

      # The same endpoint on a target that needs the PINS: migcom is the MIG compiler
      # the port's every codegen edge runs, and it lives in buck-src -- so loading its
      # package coerces the SDK maps and all 147 pinned trees have to be there.
      #
      #   systemd-run --user --scope -p MemoryMax=8G nix build .#cider-buck2-migcom
      packages.cider-buck2-migcom =
        pkgs:
        (
          let
            ciderSrc = import ./nix/lib/cider-src.nix {
              inherit pkgs;
              baseSrc = ./.;
            };
          in
          import ./nix/lib/ciderBuck2Lower.nix {
            inherit pkgs ciderSrc;
            allPins = true;
            graph = import ./nix/lib/ciderBuck2Graph.nix {
              inherit pkgs ciderSrc;
              allPins = true;
              targets = [ "//buck-src:migcom" ];
            };
          }
        ).final;

      # The endpoint on a GUEST-tier dylib: libsystem_blocks is small, but its link runs
      # Darling's own ld64, now the buck2 BUILT one (#65), and goes through the
      # firstpass/final pair, which is the shape every one of the port's 132 dylibs has.
      #
      #   systemd-run --user --scope -p MemoryMax=8G nix build .#cider-buck2-blocks
      packages.cider-buck2-blocks =
        pkgs:
        (
          let
            ciderSrc = import ./nix/lib/cider-src.nix {
              inherit pkgs;
              baseSrc = ./.;
            };
          in
          import ./nix/lib/ciderBuck2Lower.nix {
            inherit pkgs ciderSrc;
            allPins = true;
            graph = import ./nix/lib/ciderBuck2Graph.nix {
              inherit pkgs ciderSrc;
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
      #   systemd-run --user --scope -p MemoryMax=8G nix build .#cider-buck2-all
      # The targets come from the PREFIX package rather than from a second lowering of the
      # same graph, for the reason spelled out at packages.cider-buck2: a lowering without
      # extraTools produces a disjoint set of derivations AND cannot build the wrap_elf ones.
      packages.cider-buck2-all =
        pkgs:
        pkgs.linkFarm "cider-buck2-all" (
          pkgs.lib.mapAttrsToList (label: drv: {
            name = pkgs.lib.strings.sanitizeDerivationName (pkgs.lib.last (pkgs.lib.splitString ":" label));
            path = drv;
          })
          pkgs.cider-buck2-prefix.named
        );

      #   systemd-run --user --scope -p MemoryMax=8G nix build .#cider-buck2-all-graph
      # The PREFIX, lowered: a Darling install built entirely through the Nix endpoint,
      # one derivation per buck2 target. This is the bash milestone on the Nix side --
      # the same tree scripts/buck-bash-check.nu boots, but assembled from store paths.
      #
      #   nix build .#cider-buck2-prefix
      packages.cider-buck2-prefix =
        pkgs:
        let
          ciderSrc = import ./nix/lib/cider-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
          lowered = import ./nix/lib/ciderBuck2Lower.nix {
            inherit pkgs ciderSrc;
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
                di = pkgs.callPackage ./nix/ciderBuildInputs.nix { };
              in
              di.wrappedLibs ++ di.hostHeaderLibs;
            graph = import ./nix/lib/ciderBuck2Graph.nix {
              inherit pkgs ciderSrc;
              allPins = true;
              targets = import ./nix/lib/buck2-targets.nix;
            };
          };
        in
        # `//` rather than overrideAttrs or passthru: this must not touch the derivation. The
        # extra attribute only gives `nix build .#cider-buck2-prefix.stageProject` something
        # to resolve, so scripts/buck-lowering-stage-check.nu can read the staging script in
        # seconds instead of discovering a staging bug 90 minutes into a build.
        # `named` as well as stageProject, so packages.cider-buck2-all can link-farm THESE
        # derivations instead of lowering the graph a second time with different arguments.
        lowered.named."root//buck/prefix:cider_prefix" // { inherit (lowered) stageProject stageProjectUsed named drvs pinsTree; };


      # THE MINIMAL ENDPOINT WITH sourceGroups ON (#54), which is the flag with the RIGHT
      # granularity: with it on, editing ACAccount.m and rebuilding libsimple_ciderd ran
      # 0 builders against 323 with neither flag. What it lacked was a staging that survives a
      # relative escape, and stageGroupsFor now mirrors a group with real directories and one
      # link per file instead of linking the group directory. packages.cider-buck2-prefix-
      # grouped exists already but lowers the FULL target list, so testing the flag there costs
      # a graph this store may not hold; this pairs it with buck2-targets-min.nix, which reuses
      # the graph the minimal endpoint already built, so ONE target can be tried in minutes.
      #
      #   nix build .#cider-buck2-prefix-min-grouped.named.\"root//src/libsimple:libsimple_ciderd\"
      packages.cider-buck2-prefix-min-grouped =
        pkgs:
        let
          ciderSrc = import ./nix/lib/cider-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
          lowered = import ./nix/lib/ciderBuck2Lower.nix {
            inherit pkgs ciderSrc;
            allPins = true;
            sourceGroups = true;
            coarsePins = true;
            extraTools =
              let
                di = pkgs.callPackage ./nix/ciderBuildInputs.nix { };
              in
              di.wrappedLibs ++ di.hostHeaderLibs;
            graph = import ./nix/lib/ciderBuck2Graph.nix {
              inherit pkgs ciderSrc;
              allPins = true;
              skeleton = true;
              targets = import ./nix/lib/buck2-targets-min.nix;
            };
          };
        in
        lowered.named."root//buck/prefix-min:cider_prefix_min"
        // { inherit (lowered) stageProject stageProjectUsed named drvs pinsTree; };

      # THE PINS, ONE STORE PATH EACH (#54), so the check below can compare them against the
      # assembled tree they replace. The lowering plants pins from cider-src, which is ONE
      # path that moves when any tracked file changes, and that is what made source groups
      # buy nothing: editing one ObjC file moved 588 of the 601 lines in a target's staging
      # script, every one of them a cider-src path.
      #
      #   nix build .#cider-pin-stores
      #   scripts/buck-pin-store-check.nu
      packages.cider-pin-stores =
        pkgs:
        let
          ciderSrc = import ./nix/lib/cider-src.nix {
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
        # in one real tree, which is the assembled cider-src they came from.
        #
        # Check with: scripts/buck-escape-check.py resolve <this farm>
        pkgs.linkFarm "cider-pin-stores" (
          pkgs.lib.mapAttrsToList (path: drv: {
            name = path;
            path = drv;
          }) ciderSrc.pinPaths
        );

      # THE MINIMAL PREFIX. The same endpoint restricted to what the goal actually needs -- a
      # prefix that boots, runs bash and can run nix -- by dropping the GUI frameworks, the
      # private frameworks and the scripting languages. Measured on the full graph those are
      # 8,142 + 2,250 + 1,197 of 27,591 actions, about 42 percent, and 1,923 of 4,314 install
      # entries. The full prefix above is untouched and remains the parity target.
      #
      #   nix build .#cider-buck2-prefix-min
      packages.cider-buck2-prefix-min =
        pkgs:
        let
          ciderSrc = import ./nix/lib/cider-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
          lowered = import ./nix/lib/ciderBuck2Lower.nix {
            inherit pkgs ciderSrc;
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
            # default in ciderBuck2Lower.nix stays off. That endpoint carries the GUI and
            # scripting cones this one drops, and packages.cider-buck2-prefix-coarse is the
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
                di = pkgs.callPackage ./nix/ciderBuildInputs.nix { };
              in
              di.wrappedLibs ++ di.hostHeaderLibs;
            # #54 IS OFF AGAIN HERE, and what turning it on bought and cost is worth keeping.
            # It DID cut the cascade: editing one unrelated ObjC file rebuilt 0 compiles rather
            # than 323, verified on libsimple_ciderd. Then the endpoint build failed
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
            # src/opendirectory_internal/include 24, linux/startup/mldr 16, src/libm/include 7,
            # and ten groups with three or fewer. Run scripts/buck-escape-check.py groups.
            #
            # 1,989 of them land in the PINS, so the pins have to become self contained first:
            # they are not, 21 links reach out of their own pin, and rewriting group escapes at
            # the assembled tree instead would make the SDK group depend on all of it and hand
            # back the whole cascade.
            #
            # packages.cider-buck2-prefix-grouped below is where that gets tried next, so
            # this endpoint stays buildable meanwhile.
            graph = import ./nix/lib/ciderBuck2Graph.nix {
              inherit pkgs ciderSrc;
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
              #   out   8rsv2w3c71rg5iacmw8h205g4lxbq05f-cider-buck2-graph
              #   data  4pybgzfvbrrfkkg1pqkhzcx09a33bdyj-cider-buck2-graph-data
              # See packages.cider-buck2-graph-min, which exists to make that comparison
              # honest, and scripts/buck-graph-equiv.py for the by-meaning check if the two
              # ever stop collapsing.
              skeleton = true;
              targets = import ./nix/lib/buck2-targets-min.nix;
            };
          };
        in
        # `//` rather than overrideAttrs or passthru: this must not touch the derivation. The
        # extra attribute only gives `nix build .#cider-buck2-prefix.stageProject` something
        # to resolve, so scripts/buck-lowering-stage-check.nu can read the staging script in
        # seconds instead of discovering a staging bug 90 minutes into a build.
        # `named` as well as stageProject, so packages.cider-buck2-all can link-farm THESE
        # derivations instead of lowering the graph a second time with different arguments.
        lowered.named."root//buck/prefix-min:cider_prefix_min" // { inherit (lowered) stageProject stageProjectUsed named drvs pinsTree; };

      # ONE TARGET, ONE COMMAND, ONE EVAL (task #68). The most common operation in this work is
      # "does this one target still build, and what RAN", and it used to cost TWO evaluations of
      # the same 307 MB graph because named."root//..." is not addressable from the CLI: a
      # nix eval --apply to get the drvPath, then a nix build of that path.
      #
      # libsimple_ciderd is the canonical probe: one C source, one include root, one
      # archive action, so it exercises load, rule, provider, glob and three action kinds and
      # still builds in seconds.
      #
      # Reached THROUGH the minimal endpoint rather than lowered separately, and that is the
      # whole point. A second lowering with its own arguments would be a different derivation,
      # and checking it would say nothing about the endpoint. This is literally one of the 2,339
      # derivations that .#cider-buck2-prefix-min builds.
      #
      #   nix build .#cider-buck2-one --no-link -L
      #   scripts/buck-quick-check.nu
      packages.cider-buck2-one =
        pkgs: pkgs.cider-buck2-prefix-min.named."root//src/libsimple:libsimple_ciderd";


      # The same endpoint with each buck-src PIN lowered as one derivation instead of one
      # per target (#53). buck-src is 58.9 percent of the actions and only moves when a
      # submodule pin is bumped, so per-target granularity there buys nothing and costs a
      # staging pass per target, which is what limits a full rebuild.
      #
      # A SEPARATE ATTRIBUTE, deliberately, so cider-buck2-prefix stays byte-comparable
      # against the tree that is already built and verified. The comparison is the point:
      #   nix build .#cider-buck2-prefix-coarse --max-jobs 4 --cores 6
      # then diff its prefix against .#cider-buck2-prefix file list and per-file sha256,
      # which is how #52 was proven.
      # The same endpoint with each target staged from ONLY the source groups it reads
      # (#54), instead of one shared project path that every target takes. That shared path
      # is why any edit rebuilds everything: change a byte in it and all 3,225 targets move.
      #
      # A SEPARATE ATTRIBUTE so cider-buck2-prefix stays byte-comparable. The test that
      # matters is not that this builds, it is that an unrelated edit does NOT rebuild:
      #   nix build .#cider-buck2-prefix-grouped   (once)
      #   touch a file under darwin/frameworks/Quartz, which no pin target reads
      #   nix build .#cider-buck2-prefix-grouped   (a pin target must NOT rerun)
      #   touch darwin/basic-headers, which 1,326 pin targets do read
      #   nix build .#cider-buck2-prefix-grouped   (they MUST rerun)
      packages.cider-buck2-prefix-grouped =
        pkgs:
        let
          ciderSrc = import ./nix/lib/cider-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
          lowered = import ./nix/lib/ciderBuck2Lower.nix {
            inherit pkgs ciderSrc;
            allPins = true;
            sourceGroups = true;
            extraTools =
              let
                di = pkgs.callPackage ./nix/ciderBuildInputs.nix { };
              in
              di.wrappedLibs ++ di.hostHeaderLibs;
            graph = import ./nix/lib/ciderBuck2Graph.nix {
              inherit pkgs ciderSrc;
              allPins = true;
              targets = import ./nix/lib/buck2-targets.nix;
            };
          };
        in
        lowered.named."root//buck/prefix:cider_prefix" // { inherit (lowered) stageProject stageProjectUsed named drvs pinsTree; };

      packages.cider-buck2-prefix-coarse =
        pkgs:
        let
          ciderSrc = import ./nix/lib/cider-src.nix {
            inherit pkgs;
            baseSrc = ./.;
          };
          lowered = import ./nix/lib/ciderBuck2Lower.nix {
            inherit pkgs ciderSrc;
            allPins = true;
            coarsePins = true;
            # extraTools exists because a wrap_elf argv carries these store
            # paths as PLAIN TEXT, so Nix cannot see the dependency and the sandbox would
            # not have them.
            extraTools =
              let
                di = pkgs.callPackage ./nix/ciderBuildInputs.nix { };
              in
              di.wrappedLibs ++ di.hostHeaderLibs;
            graph = import ./nix/lib/ciderBuck2Graph.nix {
              inherit pkgs ciderSrc;
              allPins = true;
              targets = import ./nix/lib/buck2-targets.nix;
            };
          };
        in
        lowered.named."root//buck/prefix:cider_prefix" // { inherit (lowered) stageProject stageProjectUsed named drvs pinsTree; };

      # The buck2-built Darling as something installable: the lowered prefix plus the one
      # launcher script that supplies the two paths the daemon reads from the environment.
      #   nix build .#cider-buck2 && ./result/bin/cider-buck2 shell /bin/bash -c ...
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
      # lowering: the built cider-buck2.drv consumes exactly the store path that
      # .#cider-buck2-prefix produces, and the endpoint builds green with extraTools,
      # 3216 derivations and no errors.
      packages.cider-buck2 =
        pkgs:
        pkgs.callPackage ./nix/buck2-package.nix {
          # The lowered target's output holds the tree under its own name.
          prefix = "${pkgs.cider-buck2-prefix}/cider_prefix__prefix";
        };

      # THE SAME PACKAGE OVER THE MINIMAL PREFIX, so there is a runtime gate that can actually
      # finish on this machine. checks.cider-buck2-smoke builds the FULL prefix, and that
      # OOM-kills the nix daemon here: measured twice, 14.6 GB RSS at --max-jobs 5 and 16.1 GB
      # at --max-jobs 2, both times killed by the kernel in the stage-tree phase with zero
      # builder failures. Lower concurrency made it worse, because daemon memory tracks DATA per
      # derivation and not job count (#48).
      #
      # The minimal prefix completes (1,617 builders, prefix hash matching) and carries what a
      # boot needs: bin/cider, bin/ciderd, libexec/cider/bin/bash and sbin/launchd.
      # That is exactly the surface a ciderd change touches, so it is the right gate for
      # #71 and for anything else host-side.
      packages.cider-buck2-min =
        pkgs:
        pkgs.callPackage ./nix/buck2-package.nix {
          prefix = "${pkgs.cider-buck2-prefix-min}/cider_prefix_min__prefix";
        };

      packages.cider-buck2-all-graph =
        pkgs:
        import ./nix/lib/ciderBuck2Graph.nix {
          inherit pkgs;
          ciderSrc = import ./nix/lib/cider-src.nix {
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
      # and nix/lib/cider-src.nix). Build WITHOUT ?submodules=1 -- cider-src
      # overlays every pinned submodule onto this flake's own tree and applies
      # patches/<name>/. Partial until every hash is filled
      # (scripts/prefetch-submodule-hashes.nu); passthru.unpinnedPaths lists gaps.
      #   nix build .#cider-src
      packages.cider-src =
        pkgs:
        import ./nix/lib/cider-src.nix {
          inherit pkgs;
          baseSrc = ./.;
        };

      # The Rust launcher (linux/startup/cider.c rewrite), task #64.
      #   nix build .#launcher
      packages.launcher =
        pkgs:
        pkgs.callPackage ./nix/launcher.nix {
          src = ./.;
        };

      # The Rust guest Mach-O loader (linux/startup/mldr rewrite), task #65.
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
      #     --expr '(import ./nix/lib/ciderNinja.nix { pkgs = <nixpkgs>; overby = <overby>; }).buildTarget
      #             { target = "src/external/xnu/darling/src/libsystem_kernel/libsystem_kernel.dylib"; }'

      # ── Flake Templates ──────────────────────────────────────────────
      #
      # Initialise a new project with:
      #   nix flake init -t github:nixie-dev/cider-nix#cider-builder
      #
      # See: docs/darwin-builder.md, PLAN.md (Task 7.7)
      templates.cider-builder = {
        path = ./templates/cider-builder;
        description = "NixOS configuration with a Darling-based x86_64-darwin remote builder";
      };

      # ── NixOS Modules ────────────────────────────────────────────────
      #
      # The base module (programs.cider) is autoloaded from
      # ./nix/nixosModule.nix by flakelight.
      #
      # The cider-builder module (services.cider-builder) is exported
      # separately so users can import it alongside the base module.
      #
      # Usage in a NixOS configuration:
      #   {
      #     imports = [
      #       cider-nix.nixosModules.nixos        # programs.cider
      #       cider-nix.nixosModules.cider-builder  # services.cider-builder
      #     ];
      #     services.cider-builder.enable = true;
      #   }
      nixosModules.cider-builder = import ./nix/ciderBuilderModule.nix;

      # ── Checks (Phase 6.2) ───────────────────────────────────────────
      #
      # NixOS VM integration tests and lightweight validation checks.
      # Run with:
      #   nix flake check              # all checks
      #   nix build .#checks.x86_64-linux.cider-smoke -L
      #   nix build .#checks.x86_64-linux.nix-in-cider -L
      #   nix build .#checks.x86_64-linux.cider-builder -L
      #
      # See: PLAN.md (Tasks 6.1, 6.2, 7.5)
      checks = pkgs:
        let
          # The buck2 MINIMAL build: it is the gate that actually finishes on this
          # machine, and the full prefix OOM-kills the daemon (#48).
          cider = pkgs.cider-buck2-min;
          ciderBuilderModule = import ./nix/ciderBuilderModule.nix;
        in
        {
          # ── Build check ─────────────────────────────────────────────────
          # Ensure the package builds successfully.  This is redundant with
          # `packages.default` but makes `nix flake check` self-contained.
          cider-build = cider;

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
                  (import ./nix/lib/ciderBuck2Lower.nix {
                    inherit pkgs;
                    graph = import ./nix/lib/ciderBuck2Graph.nix {
                      inherit pkgs;
                      targets = [ "//src/libsimple:libsimple_ciderd" ];
                    };
                  }).final
                }/liblibsimple_ciderd.a
                test -f "$lib" || { echo "no archive at $lib" >&2; exit 1; }
                ${pkgs.llvmPackages.bintools}/bin/nm "$lib" | grep -q libsimple_lock_lock \
                  || { echo "archive has no libsimple symbols" >&2; exit 1; }
                echo ok > $out
              '';

          # ── Darling smoke test (Phase 6.6) ──────────────────────────────
          # Lightweight NixOS VM test: boots Darling, verifies shell,
          # sandbox-exec, diskutil, and Directory Services stubs.
          # No network access required — completes in a few minutes.
          cider-smoke = import ./tests/cider-smoke.nix {
            inherit pkgs cider;
          };

          # ── The BUCK2-built Darling, in the same harness ───────────────
          # The bash milestone in a VM. cider-smoke above cannot run against the port
          # yet: it exercises a userland the system component scope does not build.
          cider-buck2-smoke = import ./tests/cider-buck2-smoke.nix {
            inherit pkgs;
            cider = pkgs.cider-buck2;
          };

          # The same VM harness over the MINIMAL prefix. This is the one that can finish on
          # this box; cider-buck2-smoke above needs the full prefix and OOMs the daemon.
          cider-buck2-min-smoke = import ./tests/cider-buck2-smoke.nix {
            inherit pkgs;
            cider = pkgs.cider-buck2-min;
          };

          # ── Nix-in-Darling integration test (Phase 6.1) ────────────────
          # Full end-to-end test: installs Nix inside Darling, verifies
          # core commands, evaluator, currentSystem, and trivial builds.
          # Requires network access (downloads Nix installer + store paths).
          nix-in-cider = import ./tests/nix-in-cider.nix {
            inherit pkgs cider;
          };

          # ── Darling builder test (Phase 7.5) ────────────────────────────
          # NixOS VM test for the remote builder module: verifies the
          # systemd service starts, sshd inside the prefix is reachable,
          # SSH key auth works, and Darling identity is correct via SSH.
          cider-builder = import ./tests/cider-builder.nix {
            inherit pkgs cider ciderBuilderModule;
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
