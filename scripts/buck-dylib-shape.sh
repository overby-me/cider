#!/usr/bin/env bash
# Is every file the prefix installs as a .dylib actually a Mach-O?
#
# Found by scripts/buck-loadall-check.sh, which dlopens what the prefix ships: 44 of the 227
# dylibs would not load, and all 44 turned out to be 131-byte GIT LFS POINTERS --
#
#   version https://git-lfs.github.com/spec/v1
#   oid sha256:018c53767605d9daa7cbb3bd49bba3ec04e7ecc942e4d7389640a0a9e87fb327
#   size 6718752
#
# -- because the Swift runtime binaries live in LFS and the checkout never fetched them. The
# port then installs the pointer as though it were a library. Not a buck2 bug: the reference
# copies the same bytes. But nothing anywhere said the prefix contained text files named
# .dylib, and "it linked" cannot catch it because nothing links against them.
#
# This asserts the shape rather than the count of failures: every .dylib is Mach-O, except a
# named set that is a pointer for a known reason. If the LFS objects are ever fetched these
# become Mach-O and the check says so, which is the signal to delete the exception.
#
# Usage:
#   scripts/buck-dylib-shape.sh <prefix root>     # the directory holding usr/ and System/
set -uo pipefail

root=${1:-}
[ -d "$root" ] || {
	printf 'usage: %s <prefix root>\n' "$0" >&2
	exit 2
}

# The only place a non-Mach-O .dylib is currently expected, and only as an LFS pointer.
EXPECTED_DIR="usr/lib/swift"

macho=0
pointer=0
declare -a wrong=()
declare -a stray=()

while IFS= read -r f; do
	rel=${f#"$root"/}
	kind=$(file -bL "$f" 2>/dev/null)
	case "$kind" in
	*Mach-O*)
		macho=$((macho + 1))
		case "$rel" in "$EXPECTED_DIR"/*) stray+=("$rel") ;; esac
		continue
		;;
	esac
	# Not Mach-O. An LFS pointer is a known state; anything else is not.
	if head -c 45 "$f" 2>/dev/null | grep -q "^version https://git-lfs.github.com/spec/v1"; then
		pointer=$((pointer + 1))
		case "$rel" in
		"$EXPECTED_DIR"/*) ;;
		*) wrong+=("$rel (LFS pointer outside $EXPECTED_DIR)") ;;
		esac
	else
		wrong+=("$rel ($kind)")
	fi
done < <(find "$root" -type f -name '*.dylib' | sort)

printf 'installed .dylib files: %d\n' "$((macho + pointer))"
printf '  Mach-O:               %d\n' "$macho"
printf '  git LFS pointers:     %d  (all under %s)\n' "$pointer" "$EXPECTED_DIR"

if [ "${#stray[@]}" -ne 0 ]; then
	printf '\nGOOD NEWS, and this check now needs updating: %d file(s) under %s are real\n' \
		"${#stray[@]}" "$EXPECTED_DIR"
	printf 'Mach-O, so the LFS objects have been fetched. Drop the exception.\n'
	printf '  %s\n' "${stray[@]:0:5}"
	exit 1
fi

if [ "${#wrong[@]}" -ne 0 ]; then
	printf '\nFAIL: %d file(s) installed as .dylib are not Mach-O and are not the known\n' \
		"${#wrong[@]}"
	printf 'Swift LFS pointers. A file that is not a library cannot be loaded, and nothing\n'
	printf 'else here would notice, because nothing links against it:\n'
	printf '  %s\n' "${wrong[@]:0:10}"
	exit 1
fi

printf '\nok: every installed .dylib is Mach-O, except %d known Swift LFS pointers\n' "$pointer"
