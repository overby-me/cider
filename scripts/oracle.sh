#!/usr/bin/env bash
# oracle.sh - correctness oracle: rebuild a derivation and bit-compare it
# against the output substituted from cache.nixos.org.
#
# nixpkgs 26.05 is a frozen target and cache.nixos.org retains its Hydra-built
# x86_64-darwin outputs permanently, so "does our locally-built output match the
# official one, byte for byte" is a real correctness signal - it catches a shim
# that lies subtly to the compiler (codegen divergence = stop-the-line).
#
# Given an installable, this: (1) substitutes the official output, (2) rebuilds
# it locally with `nix build --rebuild`, (3) emits a JSON verdict. `--rebuild`
# itself does the hash comparison and fails on mismatch; on mismatch we also run
# diffoscope if available.
#
# Usage:
#   scripts/oracle.sh [--flake REF] [--system x86_64-darwin]
#                     [--json out.json] [--diff] <attr|installable>
#
#   --flake REF   flake to resolve <attr> against (default: current dir)
#   --system      build system (default: x86_64-darwin)
#   --json FILE   write the JSON verdict here (always also printed)
#   --diff        run diffoscope on mismatch (best-effort)
#
# Verdicts: match | mismatch | build-failure | substitute-failure
#
# Example:
#   scripts/oracle.sh --flake "github:NixOS/nixpkgs/fd146203..." hello

set -uo pipefail

FLAKE="."
SYSTEM="x86_64-darwin"
JSON=""
DODIFF=0
INSTALLABLE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flake) FLAKE="$2"; shift 2 ;;
    --system) SYSTEM="$2"; shift 2 ;;
    --json) JSON="$2"; shift 2 ;;
    --diff) DODIFF=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) INSTALLABLE="$1"; shift ;;
  esac
done

[[ -z "$INSTALLABLE" ]] && { echo "usage: $0 [opts] <attr|installable>" >&2; exit 2; }

# Resolve a full installable. If it contains a '#', use as-is; else attach the
# flake and the legacyPackages.<system> path.
if [[ "$INSTALLABLE" == *"#"* ]]; then
  FULL="$INSTALLABLE"
else
  FULL="${FLAKE}#legacyPackages.${SYSTEM}.${INSTALLABLE}"
fi

emit() {  # verdict, detail
  local verdict="$1" detail="${2:-}"
  local out
  out=$(printf '{"installable": "%s", "system": "%s", "verdict": "%s", "detail": "%s"}\n' \
    "$FULL" "$SYSTEM" "$verdict" "${detail//\"/\\\"}")
  echo "$out"
  [[ -n "$JSON" ]] && echo "$out" > "$JSON"
  case "$verdict" in
    match) exit 0 ;;
    mismatch) exit 3 ;;
    *) exit 1 ;;
  esac
}

echo "[oracle] resolving $FULL" >&2

# 1. Ensure the official output is present (substituted from the cache).
out_path=$(nix build "$FULL" --system "$SYSTEM" --no-link --print-out-paths 2>/dev/null | tail -1)
if [[ -z "$out_path" ]]; then
  emit "substitute-failure" "could not substitute or evaluate $FULL"
fi
echo "[oracle] official output: $out_path" >&2

# 2. Rebuild locally and let nix compare against the substituted output.
log=$(mktemp)
if nix build "$FULL" --system "$SYSTEM" --rebuild --no-link -L >"$log" 2>&1; then
  rm -f "$log"
  emit "match" "$out_path"
fi

# --rebuild failed: distinguish a hash mismatch from a plain build failure.
if grep -qiE "hash mismatch|differs from|not deterministic|output.*differ" "$log"; then
  detail="output differs from $out_path"
  echo "[oracle] MISMATCH: $detail" >&2
  tail -20 "$log" >&2
  if [[ $DODIFF -eq 1 ]] && command -v diffoscope >/dev/null; then
    check_path="${out_path}.check"
    [[ -e "$check_path" ]] && diffoscope "$out_path" "$check_path" 2>&1 | head -80 >&2 || true
  fi
  rm -f "$log"
  emit "mismatch" "$detail"
else
  detail="local rebuild failed (not a hash mismatch)"
  echo "[oracle] BUILD FAILURE" >&2
  tail -20 "$log" >&2
  rm -f "$log"
  emit "build-failure" "$detail"
fi
