# cider-src.nix - assemble Darling's source tree from nix-pinned submodules
# instead of git submodules (task #23, the "off git submodules" move).
#
# Darling vendors 147 trees that used to be git submodules; they were removed
# (task #71) so nix is the sole source path -- no `git submodule update`, no dirty
# `nix build .?submodules=1`, both of which fetch outside nix and are not content-
# addressed. This function reads nix/submodules.json (the hand-maintained pin
# manifest; its `hash` fields are filled by scripts/prefetch-submodule-hashes.nu)
# and for every entry with a pinned `hash` fetches it with fetchFromGitHub, then
# overlays it onto a base tree and applies patches/<name>/*.patch. The result is
# a complete, content-addressed Darling source tree with no git submodule step.
#
# Incremental by design: entries whose `hash` is still "" (not yet prefetched)
# are left as they are in `baseSrc`, and their paths are reported in
# `passthru.unpinned`. So this is usable the moment the first hash is filled and
# becomes a full replacement once scripts/prefetch-submodule-hashes.nu has pinned
# them all. A build that needs an unpinned submodule fails loudly (empty dir),
# never silently.
{
  pkgs,
  # The superproject tree WITHOUT submodule contents (this flake's own source;
  # the submodule paths are empty dirs / gitlinks). Overlaid, not mutated.
  baseSrc,
  manifest ? ../submodules.json,
  # patches/<basename-of-submodule-path>/*.patch, applied with `patch -p1` under
  # the submodule dir, the way the retired init-submodules checkout script did.
  patchesDir ? ../../patches,
}:
let
  inherit (pkgs) lib;

  # Filter the superproject source so nix-expression / doc edits do NOT rehash the
  # whole cider-src derivation (and thus every cider build). nix/ holds the
  # build graph's Nix expressions -- evaluated, never read by the C build; the pin
  # manifest reaches this function via the `manifest` arg, not baseSrc -- and
  # docs/flake are not read by the build either. src/ darwin/ cmake/ CMakeLists.txt
  # etc. are kept. This is a build-iteration speedup, orthogonal to per-component
  # input isolation (#26/#78).
  baseSrcClean = builtins.path {
    name = "cider-superproject-src";
    path = baseSrc;
    filter =
      path: _type:
      let
        rel = lib.removePrefix (toString baseSrc + "/") (toString path);
        base = baseNameOf rel;
      in
      # The port's BUCK files live INSIDE this tree -- darwin/frameworks/BUCK,
      # darwin/CoreAudio/BUCK and 56 others -- because darwin/ and src/ are what cmake needs,
      # so the top-level exclusions below cannot reach them. cmake never opens one.
      #
      # Left in, editing any of them rehashes this tree, and ld64 is built from it
      # (nix/cctools-port.nix), so a one-line BUCK edit rebuilds ld64 from source: 26,351
      # compile steps before the thing being tested can even start. That is measurable in
      # the store, where cider-cmake-src paths carry 46, 60, 61 and 62 BUCK files -- one
      # rebuild of everything per BUCK edit, all campaign.
      #
      # BUCK.tmp.* too: scripts/gen-buck-from-ninja.py writes one next to the file it is
      # rewriting, so a build racing a regenerate would otherwise capture it.
      base != "BUCK"
      && !(lib.hasPrefix "BUCK.tmp" base)
      && !(builtins.elem rel [
        "nix"
        "flake.nix"
        "flake.lock"
        "docs"
        "PLAN.md"
        "README.md"
        "CONTRIBUTORS.md"
        ".git"
        ".jj"
        # Buck2 port scratch (plan/buck2-port.md): `buck-src` holds pinned
        # upstream trees materialized for a direct `buck2 build` (the same pins
        # this file fetches, so they are redundant here), and `buck-out` is
        # buck2's output tree. Both are gitignored, machine-local, and hundreds
        # of MB -- without this they would land in the store and rehash
        # cider-src (and therefore every cider build) on every buck2 run.
        "buck-src"
        "buck-out"
        # The Buck2 port's own definitions and tooling, which the cmake/ninja build
        # never reads: the rules and toolchains under buck/, the generators and the
        # suite under scripts/, the port's log under plan/, and buck2's configs. They
        # change constantly while the port is being worked on, and without this every
        # one of those edits re-assembles this 4 GB tree before anything can build.
        "buck"
        "scripts"
        "plan"
        "tests"
        ".buckconfig"
        ".buckconfig.local"
        ".buckroot"
      ]);
  };

  entries = builtins.fromJSON (builtins.readFile manifest);

  pinned = builtins.filter (e: e.hash or "" != "") entries;
  unpinned = builtins.filter (e: e.hash or "" == "") entries;

  fetchOne = e:
    let
      # Deterministic, path-derived name so two submodules that share a repo
      # basename still get distinct store paths.
      name = "cider-sub-${lib.strings.sanitizeDerivationName e.path}";
    in
    # Submodules that themselves declare nested submodules (a `.gitmodules` of
    # their own -- corefoundation, libxpc, IOKitUser, openpam, ...) can't use
    # fetchFromGitHub: a GitHub archive tarball omits submodule content, so an
    # add_subdirectory into the nested path fails at configure. fetchgit with
    # fetchSubmodules recurses and resolves the nested repos' relative URLs
    # against the parent (../cider-X.git -> github.com/darlinghq/darling-X).
    # A pin whose content is in git LFS cannot come from an archive tarball either: GitHub
    # serves the 132-byte POINTER files, not the objects. pins/swift is the one, and
    # its 44 runtime dylibs were installed into the prefix as those pointers -- text where a
    # Mach-O belongs, which is why all 44 fail to load and nothing else in the sweep does.
    if e.lfs or false
    then
      pkgs.fetchgit {
        url = "https://github.com/${e.owner}/${e.repo}";
        inherit (e) rev;
        hash = e.hash;
        fetchLFS = true;
        fetchSubmodules = e.recursive or false;
        inherit name;
      }
    else if e.recursive or false
    then
      pkgs.fetchgit {
        url = "https://github.com/${e.owner}/${e.repo}";
        inherit (e) rev;
        hash = e.hash;
        fetchSubmodules = true;
        inherit name;
      }
    else
      pkgs.fetchFromGitHub {
        inherit (e) owner repo rev;
        hash = e.hash;
        inherit name;
      };

  # The symlink rewrite the assembled tree does after overlaying, for the per-pin stores.
  #
  # A DELIBERATE COPY of the loop at the bottom of the assembled tree, not a shared binding,
  # and the reason is measured: factoring the two into one fragment changes the assembled
  # builder text by whitespace alone, which moves cider-src, which rebuilds ld64 and then
  # the graph. An hour of machine time for a tidier let block. scripts/buck-pin-store-check.nu
  # is what keeps the two honest instead, by diffing a real pin store against the real
  # assembled tree, which a shared string could not have proven anyway.
  # THE ../ COUNT IS COMPUTED FROM THE PIN'S DESTINATION DEPTH, not preserved from upstream.
  #
  # This used to sed `darwin/` into the target and leave the leading ../ run alone. That was
  # right only while the pin root was TWO components: libnotify ships
  # darling/src/notify.defs -> ../../../../../Developer/..., and five ups from
  # src/external/libnotify/darling/src landed exactly on the repo root. #87 stage 2 made the
  # root ONE component, so the same five ups overshoot and the link resolves to ../darwin/...,
  # outside the tree.
  #
  # $out here IS the pin, so there is no repo root to be relative to and realpath cannot help:
  # the target has to be written for where the pin will be PLANTED. That is pinPath, hence the
  # argument. Nothing failed where the mistake was, because the graph derivation's normaliser
  # repaired the link in passing; rung 1 and rung 2 were both green and exactly ONE lowered
  # target of 4,563 died an hour later on "cannot read file
  # buck-src/libnotify/notifyd/notify.defs".
  repointSdkLinks = pinPath: findArgs: let
    pinDepth = builtins.length (lib.splitString "/" pinPath);
  in ''
    find ${findArgs} | while read -r l; do
      t=$(readlink "$l") || continue
      case "$t" in
        *darwin/Developer/Platforms/*) : ;;
        *Developer/Platforms/MacOSX.platform*)
          tail=''${t#"''${t%%[!./]*}"}          # drop the leading ../ and ./ run
          rel=''${l#"$out/"}
          reldir=$(dirname "$rel")
          n=${toString pinDepth}
          if [ "$reldir" != "." ]; then
            n=$(( n + $(printf '%s' "$reldir" | tr -cd / | wc -c) + 1 ))
          fi
          up=""; i=0
          while [ "$i" -lt "$n" ]; do up="../$up"; i=$((i+1)); done
          # darwin/ IS the point of the rewrite (task #68 moved the SDK there); the ../ count
          # is only how you reach it. Dropping it while fixing the count produced a link with
          # the right depth and the wrong destination, which the first artifact check caught.
          rm -f "$l"; ln -s "''${up}darwin/$tail" "$l" ;;
      esac
    done
  '';

  # ONE STORE PATH PER PIN (#54). The assembled cider-src is a single path that moves when
  # any tracked file changes, and the lowering plants the pins from it -- so a one line edit
  # to a framework moved all 295 pin symlinks in every target's staging script, which is what
  # made source groups buy nothing. MEASURED on libsimple_ciderd: 588 of the 601 lines
  # in its grouped staging script changed after editing one unrelated ObjC file, and every
  # changed line was a cider-src path, while the two group paths it actually reads did not
  # move at all.
  #
  # Same three steps the assembled tree applies, in the same order, so the result is the same
  # bytes: fetch, patch, repoint. scripts/buck-pin-store-check.nu diffs one against the
  # assembled tree rather than trusting that sentence.
  pinStore = e: let
    base = baseNameOf e.path;
    # THE PATCH DIRECTORY IS KEYED BY BASENAME, WHICH IS NOT UNIQUE. Two pins can share a
    # basename and would then silently share a patch set: de-vendoring the duct-tape XNU
    # subset puts a second xnu at pins/ciderd/xnu-sys/xnu, whose basename is also
    # "xnu", so it would have patches/xnu applied to it -- and those are the GUEST SYSCALL
    # patches for the OTHER xnu, which touch darling/src/libsystem_kernel/emulation only.
    # An entry can therefore name its own directory. Defaulting to the basename keeps every
    # existing pin bit for bit identical, which was verified by evaluating all 146 pin store
    # paths before and after this change and diffing the lists.
    patchSub = patchesDir + ("/" + (e.patches or base));
    hasPatches = builtins.pathExists patchSub;
    needsWork = hasPatches;
  in
    pkgs.runCommand "cider-pin-${lib.strings.sanitizeDerivationName e.path}"
      {
        nativeBuildInputs = [ pkgs.coreutils ] ++ lib.optional needsWork pkgs.gnupatch;
        passthru = { inherit (e) path rev; };
      }
      (''
        cp -a --no-preserve=ownership ${fetchOne e} "$out"
        chmod -R u+w "$out"
      ''
      + lib.optionalString hasPatches ''
        for p in ${patchSub}/*.patch; do
          [ -e "$p" ] || continue
          echo "  patch ${base}: $(basename "$p")"
          patch -p1 -d "$out" --force < "$p"
        done
      ''
      + repointSdkLinks e.path "\"$out\" -type l -print");

  # Shell to overlay one fetched submodule and apply its patches.
  overlayOne = e: let
    base = baseNameOf e.path;
    # Same override as pinStore above, and it has to be BOTH places or the assembled tree
    # and the per-pin store would apply different patches to the same submodule.
    patchSub = patchesDir + ("/" + (e.patches or base));
    hasPatches = builtins.pathExists patchSub;
  in ''
    rm -rf "$out/${e.path}"
    mkdir -p "$out/$(dirname "${e.path}")"
    cp -a --no-preserve=ownership ${fetchOne e} "$out/${e.path}"
    chmod -R u+w "$out/${e.path}"
  ''
  + lib.optionalString hasPatches ''
    for p in ${patchSub}/*.patch; do
      [ -e "$p" ] || continue
      echo "  patch ${base}: $(basename "$p")"
      patch -p1 -d "$out/${e.path}" --force < "$p"
    done
  '';

in
pkgs.runCommand "cider-src"
  {
    nativeBuildInputs = [ pkgs.coreutils pkgs.gnupatch ];
    passthru = {
      inherit entries pinned;
      unpinnedPaths = map (e: e.path) unpinned;
      pinnedCount = builtins.length pinned;
      totalCount = builtins.length entries;
      # {"pins/libdispatch" = <store path>; ...}, so a consumer can name ONE pin
      # instead of the assembled tree. See pinStore above for why that matters.
      pinPaths = lib.listToAttrs (map (e: lib.nameValuePair e.path (pinStore e)) pinned);
    };
  }
  ''
    # cp -a (not --no-preserve=mode) preserves the +x bit on scripts the build
    # later runs (generate-rpc-wrappers.py, mig.sh); a mode-stripping copy makes
    # them non-executable and the rpc.h generator fails "Permission denied". Drop
    # only ownership (unsettable as non-root); chmod -R u+w then adds write for the
    # submodule overlays and patches without clearing the execute bits.
    cp -a --no-preserve=ownership ${baseSrcClean} $out
    chmod -R u+w $out
    echo "assembling cider-src: ${toString (builtins.length pinned)}/${toString (builtins.length entries)} submodules pinned"
    ${lib.concatMapStringsSep "\n" overlayOne pinned}

    # task #68: the guest SDK tree moved to darwin/Developer, but several pinned
    # submodules (e.g. bootstrap_cmds/darling/include/{mach,machine,i386,...}) carry
    # relative symlinks into the OLD superproject Developer/ SDK path, which the
    # working-tree move can't reach (pins are fetched here, not committed). Re-point
    # any such symlink into `Developer/Platforms/MacOSX.platform` -> `darwin/Developer/...`.
    #
    # PRUNE $out/darwin: the working-tree move already recomputed every committed
    # symlink there. The darwin/-internal indexes (framework-include/*, ...) point at
    # `../Developer/...`, which resolves WITHIN darwin/ (framework-include and Developer
    # moved together); blindly inserting `darwin/` turns them into `../darwin/Developer`
    # = darwin/darwin/... and dangles them -- this silently broke all 141 framework-include
    # links (and thus <CoreFoundation/...> et al.). Only the fetched pins outside darwin/
    # carry stale root-relative Developer/ targets that actually need the rewrite.
    # THE ../ COUNT IS RECOMPUTED, NOT PRESERVED, and #87 stage 2 is why. This used to
    # sed `darwin/` into the target and leave the leading ../ run alone, which was right
    # only because the pin root was TWO components: libnotify's
    # darling/src/notify.defs ships ../../../../../Developer/..., and five ups from
    # src/external/libnotify/darling/src landed exactly on the repo root. Under a
    # ONE-component pins/ root the same five ups overshoot by one, the link resolves to
    # ../darwin/... outside the tree, and it dangles.
    #
    # Nothing failed where the mistake was: the graph derivation's normaliser repaired it
    # in passing, so rung 1 and rung 2 were both green and ONE lowered target out of 4,563
    # died an hour later with "cannot read file buck-src/libnotify/notifyd/notify.defs".
    #
    # These targets are ROOT-RELATIVE by construction (that is what the leading ../ run
    # means here), so the honest fix is to say where the file actually is and let realpath
    # work out how to get there from this particular link. Depth-independent, so the next
    # root move does not need to find this line.
    find "$out" -path "$out/darwin" -prune -o -type l -print | while read -r l; do
      t=$(readlink "$l") || continue
      case "$t" in
        *darwin/Developer/Platforms/*) : ;;
        */Developer/Platforms/MacOSX.platform*)
          tail=''${t#"''${t%%[!./]*}"}          # drop the leading ../ and ./ run
          nt=$(realpath -m --relative-to="$(dirname "$l")" "$out/darwin/$tail")
          rm -f "$l"; ln -s "$nt" "$l" ;;
        Developer/Platforms/MacOSX.platform*)
          nt=$(realpath -m --relative-to="$(dirname "$l")" "$out/darwin/$t")
          rm -f "$l"; ln -s "$nt" "$l" ;;
      esac
    done
  ''
