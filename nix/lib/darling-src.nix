# darling-src.nix - assemble Darling's source tree from nix-pinned submodules
# instead of git submodules (task #23, the "off git submodules" move).
#
# Darling vendors 147 trees as git submodules. Building today needs either
# `git submodule update --recursive` or a dirty `nix build .?submodules=1`, both
# of which fetch outside nix and are not content-addressed. This function instead
# reads nix/submodules.json (produced by scripts/gen-submodule-manifest.sh) and
# for every entry with a pinned `hash` fetches it with fetchFromGitHub, then
# overlays it onto a base tree and applies patches/<name>/*.patch. The result is
# a complete, content-addressed Darling source tree with no git submodule step.
#
# Incremental by design: entries whose `hash` is still "" (not yet prefetched)
# are left as they are in `baseSrc`, and their paths are reported in
# `passthru.unpinned`. So this is usable the moment the first hash is filled and
# becomes a full replacement once scripts/prefetch-submodule-hashes.sh has pinned
# them all. A build that needs an unpinned submodule fails loudly (empty dir),
# never silently.
{
  pkgs,
  # The superproject tree WITHOUT submodule contents (this flake's own source;
  # the submodule paths are empty dirs / gitlinks). Overlaid, not mutated.
  baseSrc,
  manifest ? ../submodules.json,
  # patches/<basename-of-submodule-path>/*.patch, applied with `patch -p1` under
  # the submodule dir, mirroring scripts/init-submodules.sh.
  patchesDir ? ../../patches,
}:
let
  inherit (pkgs) lib;
  entries = builtins.fromJSON (builtins.readFile manifest);

  pinned = builtins.filter (e: e.hash or "" != "") entries;
  unpinned = builtins.filter (e: e.hash or "" == "") entries;

  fetchOne = e:
    pkgs.fetchFromGitHub {
      inherit (e) owner repo rev;
      hash = e.hash;
      # Deterministic, path-derived name so two submodules that share a repo
      # basename still get distinct store paths.
      name = "darling-sub-${lib.strings.sanitizeDerivationName e.path}";
    };

  # Shell to overlay one fetched submodule and apply its patches.
  overlayOne = e: let
    base = baseNameOf e.path;
    patchSub = patchesDir + "/${base}";
    hasPatches = builtins.pathExists patchSub;
  in ''
    rm -rf "$out/${e.path}"
    mkdir -p "$out/$(dirname "${e.path}")"
    cp -r --no-preserve=mode,ownership ${fetchOne e} "$out/${e.path}"
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
    cp -r --no-preserve=mode,ownership ${baseSrc} $out
    chmod -R u+w $out
    echo "assembling darling-src: ${toString (builtins.length pinned)}/${toString (builtins.length entries)} submodules pinned"
    ${lib.concatMapStringsSep "\n" overlayOne pinned}
  ''
