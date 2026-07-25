#!/usr/bin/env bash
# Byte-parity gate for the Rust RPC wire codec (Stage 1 of the host-side rewrite).
# Regenerates the C header + Rust structs + both size probes from the ONE `calls`
# source of truth, then asserts the C and Rust structs have identical size+align
# for every message. Needs: python3, clang, cargo/rustc, libclang.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$REPO/src/external/darlingserver/scripts/generate-rpc-wrappers.py"
CRATE="$REPO/src/external/darlingserver-rs"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

python3 "$GEN" "$tmp/pub.h" "$tmp/int.h" "$tmp/lib.c" '<darlingserver/rpc.h>' \
	"$CRATE/src/rpc_wire.rs" "$tmp/probe.c"

clang -std=c11 -o "$tmp/cprobe" "$tmp/probe.c"
"$tmp/cprobe" | sort > "$tmp/c_sizes.txt"

( cd "$CRATE" && cargo run --quiet --bin rpc_wire_sizes ) | sort > "$tmp/rust_sizes.txt"

if diff -u "$tmp/c_sizes.txt" "$tmp/rust_sizes.txt"; then
	echo "RPC_WIRE_PARITY_OK: $(wc -l < "$tmp/c_sizes.txt") message structs byte-identical (size+align) C == Rust"
else
	echo "RPC_WIRE_PARITY_FAIL: C and Rust wire layouts diverge (see diff above)" >&2
	exit 1
fi
