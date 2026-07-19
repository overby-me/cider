#!/usr/bin/env bash
# symbol-demand.sh - build the "demand list" for Phase B.
#
# Given a set of store paths (or any directories/files), find every Mach-O
# object and, using its bind tables, extract the symbols it imports *from the
# system libraries* (absolute install names under /usr/lib or /System/...) -
# i.e. exactly the symbols Darling's reimplemented libraries must provide.
# Symbols bound to @rpath/@loader_path/@executable_path dylibs are intra-closure
# (the closure ships them itself) and are excluded.
#
# Output: a ranked table (symbol, expected install-name, #referencing binaries).
# Phase B.3 grinds this in rank order; pair with tbd-diff.py (the supply side).
#
# Runs on Linux against Mach-O binaries using llvm tools (llvm-objdump /
# llvm-otool) - no macOS host needed.
#
# Usage:
#   scripts/symbol-demand.sh [--system x86_64-darwin] [--arch x86_64]
#                            [--json out.json] [--closure]
#                            [--include-bundled] PATH...
#
#   --closure          expand each PATH via `nix path-info -r` first
#   --system           Darwin system double (selects default --arch)
#   --arch             Mach-O slice to inspect (x86_64 | arm64)
#   --json FILE        also write a JSON report
#   --include-bundled  also count @rpath/@loader_path imports (debug)
#
# Example (bootstrap-tools demand list):
#   bt=$(nix eval --raw \
#     "github:NixOS/nixpkgs/<rev>#legacyPackages.x86_64-darwin.stdenv.bootstrapTools.outPath")
#   nix-store -r "$bt"
#   scripts/symbol-demand.sh "$bt" > plan/symbol-gap.md

set -uo pipefail

SYSTEM="x86_64-darwin"
ARCH=""
JSON=""
CLOSURE=0
INCLUDE_BUNDLED=0
declare -a INPUTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --system) SYSTEM="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --json) JSON="$2"; shift 2 ;;
    --closure) CLOSURE=1; shift ;;
    --include-bundled) INCLUDE_BUNDLED=1; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    --) shift; while [[ $# -gt 0 ]]; do INPUTS+=("$1"); shift; done ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) INPUTS+=("$1"); shift ;;
  esac
done

[[ ${#INPUTS[@]} -eq 0 ]] && { echo "usage: $0 [opts] PATH..." >&2; exit 2; }

if [[ -z "$ARCH" ]]; then
  case "$SYSTEM" in
    aarch64-darwin) ARCH="arm64" ;;
    *) ARCH="x86_64" ;;
  esac
fi

OBJDUMP=$(command -v llvm-objdump || true)
OTOOL=$(command -v llvm-otool || true)
[[ -z "$OBJDUMP" || -z "$OTOOL" ]] && {
  echo "error: need llvm-objdump and llvm-otool (nix shell nixpkgs#llvm)" >&2; exit 3; }

if [[ $CLOSURE -eq 1 ]]; then
  mapfile -t INPUTS < <(nix path-info -r "${INPUTS[@]}" 2>/dev/null || printf '%s\n' "${INPUTS[@]}")
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
demand="$workdir/demand"   # <symbol>\t<install-name>\t<binary>
: > "$demand"

is_macho() {
  local magic
  magic=$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$magic" in
    feedface|cefaedfe|feedfacf|cffaedfe|cafebabe|bebafeca|cafebabf|bfbafeca) return 0 ;;
    *) return 1 ;;
  esac
}

# Is this install name a system library Darling must provide?
is_system_lib() {
  case "$1" in
    /usr/lib/*|/System/Library/*) return 0 ;;
    *) return 1 ;;
  esac
}

scan_binary() {
  local bin="$1"

  # leaf-name -> full install name (from the dependent-dylib list). The bind
  # table prints the dylib by its leaf name; correlate back to the install
  # name so we can classify system vs bundled.
  declare -A leaf2name=()
  local line name leaf
  while IFS= read -r line; do
    name=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/ \(compatibility.*$//')
    [[ -z "$name" ]] && continue
    # llvm-objdump's bind table names a dylib by its basename up to the first
    # dot: /usr/lib/libSystem.B.dylib -> "libSystem", libc++.1.0.dylib ->
    # "libc++", a framework's .../CoreFoundation -> "CoreFoundation".
    leaf=${name##*/}; leaf=${leaf%%.*}
    leaf2name["$leaf"]="$name"
  done < <("$OTOOL" -arch "$ARCH" -L "$bin" 2>/dev/null | tail -n +2)

  # All binds (data + lazy + weak). Columns end with: ... dylib symbol
  local -A seen_here=()
  local dylib sym instname
  while read -r dylib sym; do
    [[ -z "$dylib" || -z "$sym" ]] && continue
    instname=${leaf2name[$dylib]:-$dylib}
    if [[ $INCLUDE_BUNDLED -eq 0 ]] && ! is_system_lib "$instname"; then
      continue
    fi
    [[ -n "${seen_here[$sym]:-}" ]] && continue
    seen_here[$sym]=1
    printf '%s\t%s\t%s\n' "$sym" "$instname" "$bin" >> "$demand"
  done < <(
    "$OBJDUMP" --macho --bind --lazy-bind --weak-bind --arch="$ARCH" "$bin" 2>/dev/null \
      | awk 'NF>=2 && $1!="segment" && $1!="Bind" && $1!="Lazy" && $1!="Weak" \
             && $1!="Bind:" && $2!="section" { print $(NF-1)"\t"$NF }'
  )
}

n_bin=0
for input in "${INPUTS[@]}"; do
  while IFS= read -r -d '' f; do
    is_macho "$f" || continue
    scan_binary "$f"
    n_bin=$((n_bin+1))
  done < <(find "$input" -type f -print0 2>/dev/null)
done

# Rank each symbol by number of distinct referencing binaries; keep a
# representative install-name.
ranked="$workdir/ranked"
awk -F'\t' '{ if (!(($1) SUBSEP ($3) in seen)) { seen[$1 SUBSEP $3]=1; cnt[$1]++ }
             name[$1]=$2 }
            END { for (s in cnt) printf "%d\t%s\t%s\n", cnt[s], s, name[s] }' "$demand" \
  | sort -rn -k1,1 > "$ranked"

total_syms=$(wc -l < "$ranked" | tr -d ' ')

# group counts by install name
bylib="$workdir/bylib"
awk -F'\t' '{ c[$3]++ } END { for (l in c) printf "%d\t%s\n", c[l], l }' "$ranked" \
  | sort -rn > "$bylib"

cat <<EOF
# Symbol demand list ($SYSTEM, arch $ARCH)

Generated by \`scripts/symbol-demand.sh\`. Demand side of the Phase B gap:
system-library symbols imported by the scanned Mach-O binaries (bind tables),
excluding intra-closure @rpath imports, ranked by how many distinct binaries
reference each. Cross-check ownership/availability with \`scripts/tbd-diff.py\`.

- Binaries scanned: **$n_bin**
- Distinct system symbols imported: **$total_syms**

## By expected install name

| # symbols | install name |
|---:|:---|
EOF
awk -F'\t' '{ printf "| %s | `%s` |\n", $1, $2 }' "$bylib"

cat <<EOF

## Ranked symbols

| # refs | symbol | install name |
|---:|:---|:---|
EOF
awk -F'\t' '{ printf "| %s | `%s` | `%s` |\n", $1, $2, $3 }' "$ranked"

if [[ -n "$JSON" ]]; then
  {
    printf '{\n  "system": "%s",\n  "arch": "%s",\n  "binaries_scanned": %d,\n  "symbols": [\n' \
      "$SYSTEM" "$ARCH" "$n_bin"
    awk -F'\t' 'NR>1{printf ",\n"} {printf "    {\"refs\": %s, \"symbol\": \"%s\", \"install_name\": \"%s\"}", $1, $2, $3}' "$ranked"
    printf '\n  ]\n}\n'
  } > "$JSON"
  echo "wrote $JSON" >&2
fi
