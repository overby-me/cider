#!/usr/bin/env bash
# Materialize the locked Rust crate sources into buck-rust/ for the Buck2 port.
#
# The port drives rustc directly, with no cargo in the build graph, so a dependency cannot be
# fetched while the build runs: the sources have to be inside the project root before buck2
# starts, since that is the only place it can read from. nix/devShell.nix unpacks every crate
# in the three Cargo.lock files into $DARLING_RUST_VENDOR, and this copies them here -- the
# same arrangement scripts/buck-src.sh gives the pinned C sources under buck-src/.
#
# Copied, not symlinked: buck2 hashes what it reads, and a glob across a symlinked directory
# into the store either misses files or drags the closure in.
#
# Usage:  scripts/buck-rust-vendor.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${DARLING_RUST_VENDOR:-}" ]; then
	echo "DARLING_RUST_VENDOR is unset -- run inside \`nix develop\`" >&2
	exit 2
fi

mkdir -p buck-rust
n=0
for crate in "$DARLING_RUST_VENDOR"/*/; do
	name=$(basename "$crate")
	# The vendor entry carries a .cargo-checksum.json that cargo writes and rustc never
	# reads; leaving it out keeps the tree to sources.
	if [ ! -e "buck-rust/$name/Cargo.toml" ]; then
		rm -rf "buck-rust/$name"
		mkdir -p "buck-rust/$name"
		cp -a --reflink=auto "$crate"/. "buck-rust/$name/"
		chmod -R u+w "buck-rust/$name"
		rm -f "buck-rust/$name/.cargo-checksum.json"
	fi
	n=$((n + 1))
done
echo "buck-rust: $n crate(s) materialized"
