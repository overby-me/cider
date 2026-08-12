#!/usr/bin/env bash
# Run from the repo root: scripts/buck-xcrun-parity.sh
# Byte gate: the C xcrun against the Rust one, BOTH RUN IN THE GUEST.
#
# THE COMPARISON HAS TO HAPPEN INSIDE cider. xcrun is a Mach-O binary whose entire job is to call
# libxcselect, so there is nothing to test on the host: the host cannot even load it. So the
# prefix is materialized ONCE, both binaries are staged into the guest root under their own
# names, and every case runs both against the same container.
#
# THE NAME IS AN INPUT, not a detail, and the first version of this gate got it wrong in a way
# worth recording. xcrun reads getprogname() and passes the result STRAIGHT THROUGH as the tool to
# invoke, so staging the two binaries as xcrun_c and xcrun_rs made every case differ: the C one
# asked for a tool called xcrun_c and the Rust one asked for xcrun_rs. Five red cases, and the
# port was correct in all five. So each binary is staged under the REAL name inside its own
# directory instead, and both names, xcrun and cc, are exercised, because a copy called cc takes
# the branch where the tool is passed through rather than NULLed.
set -u
R=$(cd "$(dirname "$0")/.." && pwd)
B=$R/buck-out/v2/art/root/1ef78538d8598cb2
ART=$B/buck/prefix/__cider_prefix__/cider_prefix__prefix
ROOT=/tmp/cider-xcrun-gate-$(id -u)
RT=$ROOT/rt
PREFIX=$ROOT/prefix
O=${GATE_OUT:-$(mktemp -d -t cider-parity.XXXXXX)}
CBIN=$B/darwin/xcselect/__xcrun_c__/xcrun_c
RBIN=$B/darwin/xcselect/__xcrun__/xcrun
fail=0
rm -rf "$O"; mkdir -p "$O"

for f in "$CBIN" "$RBIN" "$ART"; do
  [ -e "$f" ] || { echo "MISSING $f"; exit 2; }
done

# Leftovers from a previous run of THIS gate only: matched by the scratch root we own, read from
# /proc/N/exe, which is the method the repo already uses. Never by process name.
for p in /proc/[0-9]*; do
  exe=$(readlink "$p/exe" 2>/dev/null) || continue
  case "$exe" in "$ROOT"/*) kill -9 "$(basename "$p")" 2>/dev/null ;; esac
done

if [ -x "$RT/libexec/cider/bin/bash" ]; then
  echo "reusing the prefix already materialized at $RT"
  rm -rf "$PREFIX"; mkdir -p "$PREFIX"
else
  echo "materializing the prefix once (about 600 MB)"
  chmod -R u+w "$RT" 2>/dev/null
  rm -rf "$ROOT"; mkdir -p "$RT" "$PREFIX"
  cp -a "$ART/." "$RT/"
  chmod -R u+w "$RT"
fi

# ONE DIRECTORY PER IMPLEMENTATION, so both run under the SAME program name.
G=$RT/libexec/cider
rm -rf "$G/bin/gatec" "$G/bin/gater"
mkdir -p "$G/bin/gatec" "$G/bin/gater"
for n in xcrun cc; do
  cp "$CBIN" "$G/bin/gatec/$n"; chmod +x "$G/bin/gatec/$n"
  cp "$RBIN" "$G/bin/gater/$n"; chmod +x "$G/bin/gater/$n"
done

export DPREFIX=$PREFIX
export CIDER_NO_LAUNCHD=1
export DSERVER_LIBEXEC_PATH=$G
export DSERVER_MLDR_PATH=$G/usr/libexec/cider/mldr

run () { # outfile, guest program, args...
  local out=$1; shift
  local prog=$1; shift
  timeout 240 "$RT/bin/cider" shell "$prog" "$@" > "$O/$out.out" 2> "$O/$out.err"
  echo $? > "$O/$out.rc"
}

# THE CASES. Each is a shape the program can actually take, not a variation on one shape:
#   no arguments        tool = NULL and argc becomes 0
#   --find <tool>       the ordinary lookup path
#   --show-sdk-path     a query that reads the developer dir
#   an unknown tool     the failure path, which is where error text differs
#   invoked as cc       getprogname is NOT xcrun, so tool is passed through instead of NULLed
i=0
while IFS='|' read -r label prog args; do
  [ -z "$label" ] && continue
  i=$((i + 1))
  # word splitting on $args is WANTED here: they are argv words, not a path.
  # shellcheck disable=SC2086
  run "c$i" "/bin/gatec/${prog}" $args
  # shellcheck disable=SC2086
  run "r$i" "/bin/gater/${prog}" $args
  ok=1
  cmp -s "$O/c$i.out" "$O/r$i.out" || ok=0
  cmp -s "$O/c$i.err" "$O/r$i.err" || ok=0
  [ "$(cat "$O/c$i.rc")" = "$(cat "$O/r$i.rc")" ] || ok=0
  if [ $ok = 1 ]; then
    printf "OK    %-28s rc %s, %s bytes out, %s bytes err\n" "$label" \
      "$(cat "$O/c$i.rc")" "$(wc -c < "$O/c$i.out")" "$(wc -c < "$O/c$i.err")"
  else
    echo "FAIL  $label"
    echo "  rc C=$(cat "$O/c$i.rc") R=$(cat "$O/r$i.rc")"
    diff "$O/c$i.out" "$O/r$i.out" | head -6
    diff "$O/c$i.err" "$O/r$i.err" | head -6
    fail=1
  fi
done <<'CASES'
no arguments|xcrun|
--find clang|xcrun|--find clang
--show-sdk-path|xcrun|--show-sdk-path
an unknown tool|xcrun|--find nosuchtool-xyzzy
invoked as cc|cc|--version
CASES

# THE CONTROL. If every case produced empty output, the comparisons above would all pass while
# proving nothing, so at least one case must have said something, and two cases must differ from
# each other.
bytes=0
for n in $(seq 1 $i); do bytes=$((bytes + $(wc -c < "$O/c$n.out") + $(wc -c < "$O/c$n.err"))); done
if [ "$bytes" -lt 20 ]; then
  echo "CONTROL FAILED: the C binary produced $bytes bytes in total, so this gate compared silence"
  fail=1
else
  echo "OK    control A: the C binary produced $bytes bytes across $i cases"
fi
if cmp -s "$O/c1.out$(:)" "$O/c2.out" && cmp -s "$O/c1.err" "$O/c2.err"; then
  echo "CONTROL FAILED: two different invocations produced identical output, so cmp cannot fail"
  fail=1
else
  echo "OK    control B: two invocations differ, so cmp can fail"
fi
echo "GATE_FAIL=$fail"
exit $fail
