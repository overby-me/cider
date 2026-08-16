#!/usr/bin/env bash
# run-darwin-under-cider.sh — run a host Nix-store x86_64-darwin binary under
# rootless Darling, mapping the host store path through Darling's host-root
# mount (/Volumes/SystemRoot). Used to demonstrate milestone M0: a substituted
# nixpkgs `hello` (from cache.nixos.org) executes under Darling.
#
# The host /nix is NOT visible at /nix inside the container, but the whole host
# root is mounted at /Volumes/SystemRoot, so /nix/store/… maps to
# /Volumes/SystemRoot/nix/store/… .
#
# Each `cider shell` runs in its own fresh container: rootless can create a
# container but cannot join an existing one from a sibling user namespace (see
# docs/changelog.md), and a fresh prefix's first boot races the shellspawn
# socket, so we kill any stale ciderd and retry.
#
# Usage:
#   scripts/run-darwin-under-cider.sh [--cider <cider-bin>] \
#       [--prefix <short-path>] <host-store-binary> [args...]
#
# Example (M0):
#   nix copy --from https://cache.nixos.org \
#     /nix/store/lf0dyrrs5n95jrlakax3d2p6ycp1jrdv-hello-2.12.3 --no-check-sigs
#   scripts/run-darwin-under-cider.sh \
#     /nix/store/lf0dyrrs5n95jrlakax3d2p6ycp1jrdv-hello-2.12.3/bin/hello
#   # -> Hello, world!
#
# STAYS BASH (task #40). This forwards ARBITRARY argv to another program, and a nushell
# script cannot receive that: nu parses a script's arguments against main's signature, so the
# first argument starting with a dash becomes an unknown flag and the script exits 1 before
# running. `--` does not help, in either `script.nu -- -la` or `nu script.nu -- -la` form; both
# are parsed as a flag with an empty name. Measured, not assumed.
set -euo pipefail

DARLING="${CIDER:-${DARLING:-cider}}"
# Keep the prefix path short: the shellspawn Unix socket lives at
# <prefix>/var/run/… and must fit sockaddr_un.sun_path (~108 chars).
PREFIX="${CIDERPREFIX:-/tmp/dh}"
RETRIES="${RETRIES:-1}"  # boot is reliable under the Rust daemon (#44); set RETRIES>1 to re-enable the old busy-spin retry

while [ $# -gt 0 ]; do
	case "$1" in
		--cider) DARLING="$2"; shift 2 ;;
		--prefix) PREFIX="$2"; shift 2 ;;
		--) shift; break ;;
		-*) echo "unknown option: $1" >&2; exit 2 ;;
		*) break ;;
	esac
done

[ $# -ge 1 ] || { echo "usage: $0 <host-store-binary> [args...]" >&2; exit 2; }

hostbin="$1"; shift
[ -x "$hostbin" ] || { echo "not executable on host: $hostbin" >&2; exit 2; }

# Rewrite a host path into Darling's view of the host root.
guestbin="/Volumes/SystemRoot${hostbin}"

marker="=DARWIN_RUN_$$="
for i in $(seq 1 "$RETRIES"); do
	# Fresh container each try; also reap leftover mldr workers from prior boots
	# (they accumulate as zombies and eventually slow the shellspawn handshake).
	pkill -9 -x ciderd 2>/dev/null || true
	pkill -9 -x mldr 2>/dev/null || true
	sleep 1
	out=$(CIDERPREFIX="$PREFIX" timeout 150 "$DARLING" shell \
		sh -c "echo $marker; exec \"$guestbin\" \"\$@\"" _ "$@" 2>&1) || true
	if printf '%s\n' "$out" | grep -q "$marker"; then
		# Strip the marker and Darling's non-fatal boot noise.
		printf '%s\n' "$out" \
			| sed "0,/$marker/d" \
			| grep -avE 'Cannot chown|failed to increase FD rlimit|semaphore_timedwait failed|dserver_rpc|mach_msg_overwrite'
		pkill -9 -x ciderd 2>/dev/null || true
		exit 0
	fi
done

echo "failed to get a working Darling shell after $RETRIES tries" >&2
pkill -9 -x ciderd 2>/dev/null || true
exit 1
