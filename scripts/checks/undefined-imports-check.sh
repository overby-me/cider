#!/usr/bin/env bash
#
# WHAT EVERY ROSTER APPLICATION IMPORTS THAT NOTHING DEFINES.
#
# A function that is declared and never defined is not a stub. A stub gives a wrong answer that can
# be measured and corrected; an undefined symbol kills the process on the lazy bind the first time
# the application reaches it, which may be a long way into a session and nowhere near the code that
# matters. Money Manager Ex died that way on the first keystroke into its transaction dialog
# (CGEventSourceKeyState), and had four HITheme draws waiting behind it.
#
# This answers the question BEFORE an application does: for each bundle, the STRONG undefined
# imports that neither the prefix nor the bundle itself defines.
#
# TWO BLIND SPOTS, both deliberate:
#   - the C library. Nothing in the prefix exports _memcpy or _strlen, yet every application calls
#     them and runs, so they are resolved by the loader rather than by a prefix dylib. They are
#     filtered out by name rather than pretended to be found.
#   - weak imports. A weak undefined symbol is allowed to be missing at runtime, which is how an
#     application links a framework it may not have; those are excluded, and they are the bulk of
#     what a Swift application imports.
#
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PREFIX=${CIDER_PREFIX_TREE:-}
BASELINE="$ROOT/scripts/checks/undefined-imports-baseline.txt"
LIBC='^_(mem[a-z]*|str[a-z]*|b(zero|copy|cmp)|__(mem|str|sprintf|snprintf|stack)[a-z_]*_chk)$'

if [ -z "$PREFIX" ]; then
    PREFIX=$(find "$ROOT/buck-out" -type d -name cider -path '*cider_prefix__prefix/libexec/*' 2>/dev/null | head -1)
fi
if [ ! -d "$PREFIX" ]; then
    echo "no built prefix tree; run buck2 build //buck/prefix:cider_prefix first" >&2
    exit 2
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

machos() {
    python3 - "$1" <<'PY'
import os, sys
magics = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
for dp, dirs, files in os.walk(sys.argv[1]):
    for fn in files:
        p = os.path.join(dp, fn)
        if os.path.islink(p):
            continue
        try:
            with open(p, 'rb') as f:
                head = f.read(4)
        except OSError:
            continue
        if head in magics:
            print(p)
PY
}

# PER FILE, NOT DOWN ONE PIPE. Sixteen parallel writers into a single pipe interleave their
# output once a write exceeds PIPE_BUF, and a symbol torn in half is a symbol this check will
# report as undefined. It invented _objc_setProperty_atomic_copy across four applications that way,
# and that symbol is defined and always was.
exported() {
    local list=$1 out=$2 dir
    dir=$(mktemp -d)
    local i=0
    while read -r f; do
        i=$((i + 1))
        llvm-nm --defined-only --extern-only --arch=x86_64 "$f" 2>/dev/null \
            | awk 'NF>=2 {print $NF}' > "$dir/$i" &
        if [ $((i % 16)) -eq 0 ]; then wait; fi
    done < "$list"
    wait
    cat "$dir"/* 2>/dev/null | sort -u > "$out"
    rm -rf "$dir"
}

echo "prefix: $PREFIX"
machos "$PREFIX" > "$WORK/prefix-libs.txt"
exported "$WORK/prefix-libs.txt" "$WORK/prefix-defined.txt"
echo "prefix mach-o files: $(wc -l < "$WORK/prefix-libs.txt"), exported symbols: $(wc -l < "$WORK/prefix-defined.txt")"

: > "$WORK/found.txt"
status=0

for prefixdir in /tmp/cider-*-1000/prefix; do
    [ -d "$prefixdir/Applications" ] || continue
    tag=$(basename "$(dirname "$prefixdir")")
    tag=${tag#cider-}
    tag=${tag%-1000}
    for bundle in "$prefixdir"/Applications/*.app; do
        [ -d "$bundle" ] || continue
        bin=$(ls "$bundle"/Contents/MacOS/* 2>/dev/null | head -1)
        [ -f "$bin" ] || continue

        machos "$bundle" > "$WORK/bundle-libs.txt"
        exported "$WORK/bundle-libs.txt" "$WORK/bundle-defined.txt"
        sort -u "$WORK/prefix-defined.txt" "$WORK/bundle-defined.txt" > "$WORK/all-defined.txt"

        llvm-nm -m --undefined-only --arch=x86_64 "$bin" 2>/dev/null \
            | grep -v 'weak external' \
            | sed 's/.*external //; s/ (from .*//' | sort -u > "$WORK/imports.txt"
        comm -23 "$WORK/imports.txt" "$WORK/all-defined.txt" | grep -Ev "$LIBC" > "$WORK/undef.txt"

        n=$(wc -l < "$WORK/undef.txt")
        echo "$tag: strong imports $(wc -l < "$WORK/imports.txt"), UNDEFINED $n  ($(basename "$bundle"))"
        while read -r sym; do
            [ -n "$sym" ] && echo "$tag $sym" >> "$WORK/found.txt"
            [ -n "$sym" ] && echo "    $sym"
        done < "$WORK/undef.txt"
    done
done

sort -u "$WORK/found.txt" -o "$WORK/found.txt"

if [ ! -f "$BASELINE" ]; then
    echo
    echo "no baseline at $BASELINE; writing what was found"
    cp "$WORK/found.txt" "$BASELINE"
    exit 0
fi

grep -v '^#' "$BASELINE" | grep -v '^$' | sort -u > "$WORK/base.txt"
NEW=$(comm -23 "$WORK/found.txt" "$WORK/base.txt")
GONE=$(comm -13 "$WORK/found.txt" "$WORK/base.txt")

echo
if [ -n "$GONE" ]; then
    echo "FIXED since the baseline:"
    echo "$GONE" | sed 's/^/    /'
fi
if [ -n "$NEW" ]; then
    echo "NEW undefined imports, each one an application that will die when it reaches them:"
    echo "$NEW" | sed 's/^/    /'
    status=1
else
    echo "PASS: no undefined import outside the baseline"
fi
exit $status
