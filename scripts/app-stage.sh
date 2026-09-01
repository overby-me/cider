#!/usr/bin/env bash
# PUT AN APPLICATION IN A PREFIX, from whatever form it came in.
#
# WHY THIS EXISTS. On 2026-09-01 every application in every prefix was found to be an empty shell:
#
#     Swift Publisher 5.app  ->  0 files, 5 directories
#
# systemd sweeps /tmp by AGE, so it had deleted every file older than about eleven days and left the
# directory tree standing. An empty bundle reads as PRESENT to every ordinary check, which is why the
# failure looked in turn like a rendering bug, a loader bug and a container bug. This script notices
# that case, not just an absent one.
#
#   scripts/app-stage.sh --prefix /tmp/cider-mm-1000/prefix --source ~/Downloads/MoneyMoney.pkg
#   scripts/app-stage.sh --prefix /tmp/cider-ia-1000/prefix --source "~/Downloads/iA Writer.app"
#
# Sources may be a .app directory, a .dmg or a .pkg. Nothing is re-extracted if the bundle is already
# there with files in it, so this is cheap to run before every session, which is the point.
set -u

PREFIX=""
SOURCE=""
FORCE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--prefix) PREFIX="$2"; shift 2 ;;
		--source) SOURCE="$2"; shift 2 ;;
		--force) FORCE=1; shift ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done
[ -n "$PREFIX" ] && [ -n "$SOURCE" ] || { echo "usage: $0 --prefix <dir> --source <app|dmg|pkg> [--force]" >&2; exit 2; }
[ -e "$SOURCE" ] || { echo "no such source: $SOURCE" >&2; exit 2; }

say() { echo "STAGE $*" >&2; }

# AN EMPTY BUNDLE IS NOT A STAGED ONE. Count files, not directories.
staged_files() {
	find "$1" -type f 2>/dev/null | wc -l
}

work=""
cleanup() { [ -n "$work" ] && rm -rf "$work"; }
trap cleanup EXIT

case "$SOURCE" in
	*.app)
		app="$SOURCE"
		;;
	*.dmg|*.pkg|*.zip)
		# nix prints EVERY output of a derivation, and taking the first one gets p7zip-man, which
		# has no bin directory at all. Pick the output that actually holds the binary.
		seven=$(command -v 7z || command -v 7zz || true)
		if [ -z "$seven" ]; then
			for out in $(nix build --no-link --print-out-paths nixpkgs#p7zip 2>/dev/null); do
				[ -x "$out/bin/7z" ] && { seven="$out/bin/7z"; break; }
			done
		fi
		[ -x "$seven" ] || { echo "no 7z available to open $SOURCE" >&2; exit 3; }
		work=$(mktemp -d)
		say "extracting $(basename "$SOURCE")"
		"$seven" x -y -o"$work" "$SOURCE" >/dev/null 2>&1 || { echo "extraction failed" >&2; exit 3; }
		# A pkg holds a Payload, which is a second archive; a dmg holds the bundle directly.
		payload=$(find "$work" -maxdepth 3 -name "Payload*" -type f 2>/dev/null | head -1)
		if [ -n "$payload" ]; then
			say "unpacking the package payload"
			mkdir -p "$work/payload"
			"$seven" x -y -o"$work/payload" "$payload" >/dev/null 2>&1
			inner=$(find "$work/payload" -maxdepth 2 -name "*.cpio" -o -maxdepth 2 -name "Payload~" 2>/dev/null | head -1)
			[ -n "$inner" ] && "$seven" x -y -o"$work/payload" "$inner" >/dev/null 2>&1
		fi
		app=$(find "$work" -maxdepth 5 -name "*.app" -type d 2>/dev/null | head -1)
		[ -n "$app" ] || { echo "no .app found inside $SOURCE" >&2; exit 3; }
		;;
	*)
		echo "unsupported source: $SOURCE" >&2; exit 2 ;;
esac

name=$(basename "$app")
dest="$PREFIX/Applications/$name"
have=$(staged_files "$dest")
if [ "$have" -gt 0 ] && [ -z "$FORCE" ]; then
	say "$name already staged, $have files"
	exit 0
fi
[ "$have" -eq 0 ] && [ -d "$dest" ] && say "$name is an EMPTY shell, restaging"

mkdir -p "$PREFIX/Applications"
rm -rf "$dest"
cp -a "$app" "$PREFIX/Applications/"
# An extracted bundle rarely carries the execute bit on its binaries.
find "$dest/Contents/MacOS" "$dest/Contents/Frameworks" "$dest/Contents/PlugIns" \
	-type f -exec chmod u+x {} + 2>/dev/null
say "$name staged, $(staged_files "$dest") files"
