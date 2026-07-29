#!/usr/bin/env bash
# Materialize nix-pinned upstream sources into buck-src/ for the Buck2 port.
#
# Most of Darling's source is already in this repo, but a few trees are nix pins
# (nix/submodules.json) with no working copy: `nix build` assembles them into the
# store, which a direct `buck2 build` cannot see (buck2 needs its sources inside
# the project root, and a symlink into the store would make it crawl the closure).
#
# So this fetches the SAME pinned revision + hash nix uses, and copies it into
# buck-src/<name>/ (gitignored). The BUCK file that builds these trees is
# buck-src/BUCK, which is committed: a buck2 package owns its subdirectories, so
# one checked-in BUCK file can define targets over all materialized trees without
# putting a BUCK file inside any of them.
#
# Usage:  scripts/buck-src.sh [<submodule-path> ...]
#         scripts/buck-src.sh                      # the port's current needs
#         scripts/buck-src.sh --all                # every pinned tree (~3.8 GB)
#         FORCE=1 scripts/buck-src.sh <path>       # re-fetch even if present
#
# --all copies out of the nix-ASSEMBLED tree (`nix build .#darling-src`) rather
# than fetching 147 pins one at a time: one derivation, and its patches and
# symlink fixups are already applied. It is what the guest tier needs, because a
# Darwin compile's include path is the SDK tree
# (darwin/Developer/.../MacOSX.sdk/usr/include), ~1900 committed symlinks into
# these trees -- with them absent, 1909 of those links dangle.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$repo_root/nix/submodules.json"
dest_root="$repo_root/buck-src"

# What the port needs so far:
#  - bootstrap_cmds: migcom + mig.sh, which every MIG codegen edge runs.
#  - xnu: the Darwin headers migcom's own sources compile against (mach/*.h).
#    The repo's SDK tree reaches these through ~1900 relative symlinks that only
#    resolve in the nix-assembled tree, so the Buck2 port declares the header
#    roots it needs directly from the source trees instead.
default_paths=(src/external/bootstrap_cmds src/external/xnu)

mkdir -p "$dest_root"

if [ "${1:-}" = "--all" ]; then
	echo "buck-src: realizing the assembled tree (nix build .#darling-src) ..."
	assembled="$(nix build "$repo_root#darling-src" --no-link --print-out-paths)"
	echo "buck-src: assembled at $assembled"

	mapfile -t all_paths < <(
		python3 - "$manifest" <<-'PY'
			import json, sys
			for e in json.load(open(sys.argv[1])):
			    if e.get("hash"):
			        print(e["path"])
		PY
	)
	echo "buck-src: copying ${#all_paths[@]} pinned trees ..."
	for sub in "${all_paths[@]}"; do
		name="$(basename "$sub")"
		dest="$dest_root/$name"
		src="$assembled/$sub"
		[ -d "$src" ] || {
			echo "buck-src: WARNING $sub missing from the assembled tree"
			continue
		}
		if [ -z "${FORCE:-}" ] && [ -f "$dest/.buck-src-assembled" ] &&
			[ "$(cat "$dest/.buck-src-assembled")" = "$assembled" ]; then
			continue
		fi
		rm -rf "$dest"
		# Plain copy, NOT hardlinks: hardlinked store files share the store's
		# inode, so any later chmod/write would mutate the nix store itself.
		# Left read-only; nothing here is edited, only compiled.
		cp -a --no-preserve=ownership "$src" "$dest"
		mkdir -p "$dest"
		echo "$assembled" >"$dest/.buck-src-assembled" 2>/dev/null ||
			{ chmod u+w "$dest" && echo "$assembled" >"$dest/.buck-src-assembled"; }
	done
	echo "buck-src: done ($(du -sh "$dest_root" | cut -f1))"
	exit 0
fi

paths=("$@")
if [ ${#paths[@]} -eq 0 ]; then
	paths=("${default_paths[@]}")
fi

for sub in "${paths[@]}"; do
	name="$(basename "$sub")"
	dest="$dest_root/$name"

	read -r owner repo rev hash < <(
		python3 - "$manifest" "$sub" <<-'PY'
			import json, sys
			entries = json.load(open(sys.argv[1]))
			for e in entries:
			    if e["path"] == sys.argv[2]:
			        if not e.get("hash"):
			            sys.exit(f"submodule {e['path']} has no pinned hash yet")
			        print(e["owner"], e["repo"], e["rev"], e["hash"])
			        break
			else:
			    sys.exit(f"no submodule entry for {sys.argv[2]}")
		PY
	)

	stamp="$dest/.buck-src-rev"
	if [ -z "${FORCE:-}" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$rev" ]; then
		echo "buck-src: $name already at $rev"
		continue
	fi

	echo "buck-src: fetching $owner/$repo @ $rev"
	store_path="$(
		nix build --impure --no-link --print-out-paths --expr "
		  let pkgs = (builtins.getFlake \"path:$repo_root\").inputs.nixpkgs.legacyPackages.\${builtins.currentSystem};
		  in pkgs.fetchFromGitHub {
		    owner = \"$owner\"; repo = \"$repo\"; rev = \"$rev\"; hash = \"$hash\";
		  }"
	)"

	rm -rf "$dest"
	cp -a --no-preserve=ownership "$store_path" "$dest"
	chmod -R u+w "$dest"

	# Same patch application as nix/lib/darling-src.nix: patches/<name>/*.patch
	# with `patch -p1` inside the tree. xnu in particular carries the macOS
	# identity patches, so an unpatched tree is not the tree we build.
	patch_dir="$repo_root/patches/$name"
	if [ -d "$patch_dir" ]; then
		for p in "$patch_dir"/*.patch; do
			[ -e "$p" ] || continue
			echo "buck-src:   patch $name: $(basename "$p")"
			patch -p1 -d "$dest" --force <"$p" >/dev/null
		done
	fi

	echo "$rev" >"$stamp"
	echo "buck-src: $name -> $dest"
done
