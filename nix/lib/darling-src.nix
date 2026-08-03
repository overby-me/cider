# darling-src.nix - assemble Darling's source tree from nix-pinned submodules
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
  # whole darling-src derivation (and thus every darling build). nix/ holds the
  # build graph's Nix expressions -- evaluated, never read by the C build; the pin
  # manifest reaches this function via the `manifest` arg, not baseSrc -- and
  # docs/flake are not read by the build either. src/ darwin/ cmake/ CMakeLists.txt
  # etc. are kept. This is a build-iteration speedup, orthogonal to per-component
  # input isolation (#26/#78).
  baseSrcClean = builtins.path {
    name = "darling-superproject-src";
    path = baseSrc;
    filter =
      path: _type:
      let
        rel = lib.removePrefix (toString baseSrc + "/") (toString path);
        base = baseNameOf rel;
      in
      # The port's BUCK files live INSIDE this tree -- darwin/frameworks/BUCK,
      # src/CoreAudio/BUCK and 56 others -- because darwin/ and src/ are what cmake needs,
      # so the top-level exclusions below cannot reach them. cmake never opens one.
      #
      # Left in, editing any of them rehashes this tree, and ld64 is built from it
      # (nix/cctools-port.nix), so a one-line BUCK edit rebuilds ld64 from source: 26,351
      # compile steps before the thing being tested can even start. That is measurable in
      # the store, where darling-cmake-src paths carry 46, 60, 61 and 62 BUCK files -- one
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
        # darling-src (and therefore every darling build) on every buck2 run.
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
      name = "darling-sub-${lib.strings.sanitizeDerivationName e.path}";
    in
    # Submodules that themselves declare nested submodules (a `.gitmodules` of
    # their own -- corefoundation, libxpc, IOKitUser, openpam, ...) can't use
    # fetchFromGitHub: a GitHub archive tarball omits submodule content, so an
    # add_subdirectory into the nested path fails at configure. fetchgit with
    # fetchSubmodules recurses and resolves the nested repos' relative URLs
    # against the parent (../darling-X.git -> github.com/darlinghq/darling-X).
    # A pin whose content is in git LFS cannot come from an archive tarball either: GitHub
    # serves the 132-byte POINTER files, not the objects. src/external/swift is the one, and
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

  # Shell to overlay one fetched submodule and apply its patches.
  overlayOne = e: let
    base = baseNameOf e.path;
    patchSub = patchesDir + "/${base}";
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
pkgs.runCommand "darling-src"
  {
    nativeBuildInputs = [ pkgs.coreutils pkgs.gnupatch ];
    passthru = {
      inherit entries pinned;
      unpinnedPaths = map (e: e.path) unpinned;
      pinnedCount = builtins.length pinned;
      totalCount = builtins.length entries;
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
    echo "assembling darling-src: ${toString (builtins.length pinned)}/${toString (builtins.length entries)} submodules pinned"
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
    find "$out" -path "$out/darwin" -prune -o -type l -print | while read -r l; do
      t=$(readlink "$l") || continue
      case "$t" in
        *darwin/Developer/Platforms/*) : ;;
        *Developer/Platforms/MacOSX.platform*)
          nt=$(printf '%s' "$t" | sed 's#Developer/Platforms/MacOSX.platform#darwin/Developer/Platforms/MacOSX.platform#')
          rm -f "$l"; ln -s "$nt" "$l" ;;
      esac
    done
  ''
