#!/usr/bin/env bash
# cider-host.sh - run Darling on the host via a setuid-root copy.
#
# This Darling build requires euid 0 (it creates mount/PID namespaces and does
# mounts); rootless user namespaces are disabled in src/linux/startup/cider.c. On a
# non-NixOS host without the programs.cider module, the supported way to run
# it is a setuid-root copy of the cider binary. The binary bakes an absolute
# INSTALL_PREFIX, so a setuid copy anywhere still execs the correct
# ciderd in the nix store; only the cider binary itself needs setuid.
#
# This wrapper resolves the current build, checks that the setuid copy matches
# it, and (if stale/missing) prints the one sudo command needed to refresh it -
# it never calls sudo itself. Rebuilding Darling (new store path) requires
# re-running that command once.
#
# Env:
#   CIDER_OUT            override the cider out path (else `nix build`)
#                        (DARLING_OUT is still honoured)
#   CIDER_C2_SETUID      setuid copy location (default /opt/cider-c2/cider)
#                        (DARLING_C2_SETUID is still honoured)
#   CIDERPREFIX              prefix location (default ~/.cider-c2)
#
# Usage: scripts/cider-host.sh <cider args...>
#        scripts/cider-host.sh --refresh-cmd   # just print the sudo command
#
# Exit 3 = setuid copy missing/stale (refresh command printed to stderr).
#
# STAYS BASH (task #40). This forwards ARBITRARY argv to another program, and a nushell
# script cannot receive that: nu parses a script's arguments against main's signature, so the
# first argument starting with a dash becomes an unknown flag and the script exits 1 before
# running. `--` does not help, in either `script.nu -- -la` or `nu script.nu -- -la` form; both
# are parsed as a flag with an empty name. Measured, not assumed.

set -uo pipefail

SETUID=${CIDER_C2_SETUID:-${DARLING_C2_SETUID:-/opt/cider-c2/cider}}
export CIDERPREFIX=${CIDERPREFIX:-$HOME/.cider-c2}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

OUT=${CIDER_OUT:-${DARLING_OUT:-}}
if [[ -z "$OUT" ]]; then
  OUT=$(cd "$repo_root" && nix build ".?submodules=1#default" --no-link --print-out-paths 2>/dev/null | tail -1)
fi
if [[ -z "$OUT" || ! -x "$OUT/bin/cider" ]]; then
  echo "[cider-host] cannot resolve the cider build (set CIDER_OUT)" >&2
  exit 2
fi

refresh_cmd="sudo install -D -o root -g root -m 4755 $OUT/bin/cider $SETUID"

if [[ "${1:-}" == "--refresh-cmd" ]]; then
  echo "$refresh_cmd"
  exit 0
fi

# Stale if the setuid copy is missing, not setuid, or baked with a different
# ciderd path than the current build.
stale=0
if [[ ! -u "$SETUID" ]]; then
  stale=1
elif ! strings "$SETUID" 2>/dev/null | grep -q "$OUT/bin/ciderd"; then
  stale=1
fi

if [[ $stale -eq 1 ]]; then
  echo "[cider-host] setuid Darling is missing or stale for build:" >&2
  echo "               $OUT" >&2
  echo "[cider-host] run this once (needs sudo), then re-run:" >&2
  echo "               $refresh_cmd" >&2
  exit 3
fi

exec "$SETUID" "$@"
