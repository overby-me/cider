#!/usr/bin/env bash
# Regenerate vendor/prebuilt/swift-5.5.3/*.dylib from the official toolchain.
#
# Not part of any build: the two files are committed. This exists so their provenance is executable
# rather than a claim, and so the version can be moved.
set -euo pipefail

VERSION=${VERSION:-5.5.3}
PKG_SHA256=609df4e77bea489028f26e1cd6efbf84a04b66c2c8fa47778fd98b96cd94ad3d
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT="$REPO/vendor/prebuilt/swift-$VERSION"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

url="https://download.swift.org/swift-$VERSION-release/xcode/swift-$VERSION-RELEASE/swift-$VERSION-RELEASE-osx.pkg"
echo "fetching $url (about 850 MB)"
curl -sS -4 -o "$WORK/source.pkg" "$url"

got=$(sha256sum "$WORK/source.pkg" | cut -d' ' -f1)
if [ "$VERSION" = 5.5.3 ] && [ "$got" != "$PKG_SHA256" ]; then
	echo "package sha256 is $got, expected $PKG_SHA256" >&2
	exit 1
fi

# xar is not on PATH in this devshell and is not worth adding to it for one command.
( cd "$WORK" && nix shell nixpkgs#xar --command xar -x -f source.pkg )

# One decompression pass, both files. Their LC_ID_DYLIB is already the absolute /usr/lib/swift path,
# so nothing has to be rewritten afterwards.
( cd "$WORK" && gunzip < "swift-$VERSION-RELEASE-osx-package.pkg/Payload" \
	| cpio -id --quiet \
		"./usr/lib/swift/macosx/libswiftCore.dylib" \
		"./usr/lib/swift/macosx/libswift_Concurrency.dylib" )

mkdir -p "$OUT"
for lib in libswiftCore libswift_Concurrency; do
	llvm-lipo "$WORK/usr/lib/swift/macosx/$lib.dylib" -thin x86_64 -output "$OUT/$lib.dylib"
	chmod 644 "$OUT/$lib.dylib"
done

sha256sum "$OUT"/*.dylib
