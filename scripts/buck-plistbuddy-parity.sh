#!/usr/bin/env bash
# Run from the repo root: scripts/buck-plistbuddy-parity.sh
# Byte gate: the C PlistBuddy against the Rust one, BOTH RUN IN THE GUEST.
#
# THE WRITTEN PLIST IS COMPARED, AND IT IS IN THE OVERLAY, NOT WHERE THE SEED WAS WRITTEN.
#
# The guest root is a union: DSERVER_LIBEXEC_PATH is the read-only base and CIDERPREFIX is the
# writable layer. Reads come from the base, writes land in the prefix. The first version of this
# gate compared the base and concluded that PlistBuddy could not save at all under cider, which
# was FALSE and would have been a fabricated project bug: the files were sitting in $PREFIX,
# 1,181 bytes each against a 524 byte seed. Control B caught the symptom, and looking for the
# file rather than believing the symptom found the cause. Compare the overlay.
#
# THE SEED THEREFORE HAS TO CLEAR THE OVERLAY between cases, or case N reads what case N-1 wrote.
#
# MUTATIONS ARE ALSO OBSERVED THROUGH INTERACTIVE MODE, phase 2 below, which shows the in-memory
# result independently of the file.
#
# THE CONTAINER TALKS ON STDERR AND THE PROGRAM BARELY DOES, so stderr is compared with the
# container lines removed. This is not a way to hide differences, it is the difference between
# the program under test and the harness around it: PlistBuddy writes to stdout through printf
# and puts, and reaches stderr only through CFShow, which is still compared. What is filtered is
# the prefix population noise (cp: ...) and the loader (
# [mldr] ...). Both appear NONDETERMINISTICALLY: one run had
# "[mldr] start-stack mmap at 0x7fffff600000 failed" on one side only, which failed a case whose
# stdout, exit code and written plist were all identical.
#
# TWO SPURIOUS FAILURES WERE SEEN AND BOTH WERE ENVIRONMENTAL, which is worth knowing before
# reading a red run as a port bug: one case came back rc 136, SIGFPE with a core dump, and did
# not reproduce in 10 runs against either binary; another was the mldr line above. A DIFFERENT
# case failed each time, which is the signature.
#
# EACH CASE STARTS FROM THE SAME SEED. The two implementations get their own copy of a freshly
# written seed plist, so no case can be contaminated by the previous one.
#
# IT SHARES THE MATERIALIZED PREFIX WITH gate-xcrun.sh on purpose: that is 600 MB per copy.
set -u
R=$(cd "$(dirname "$0")/.." && pwd)
B=$R/buck-out/v2/art/root/1ef78538d8598cb2
ART=$B/buck/prefix/__cider_prefix__/cider_prefix__prefix
ROOT=/tmp/cider-xcrun-gate-$(id -u)
RT=$ROOT/rt
PREFIX=$ROOT/prefix
O=${GATE_OUT:-$(mktemp -d -t cider-parity.XXXXXX)}
CBIN=$B/darwin/PlistBuddy/__PlistBuddy_c__/PlistBuddy_c
RBIN=$B/darwin/PlistBuddy/__PlistBuddy__/PlistBuddy
fail=0
rm -rf "$O"; mkdir -p "$O"

for f in "$CBIN" "$RBIN" "$ART"; do
  [ -e "$f" ] || { echo "MISSING $f"; exit 2; }
done

for p in /proc/[0-9]*; do
  exe=$(readlink "$p/exe" 2>/dev/null) || continue
  case "$exe" in "$ROOT"/*) kill -9 "$(basename "$p")" 2>/dev/null ;; esac
done

if [ -x "$RT/libexec/cider/bin/bash" ]; then
  echo "reusing the prefix already materialized at $RT"
  rm -rf "$PREFIX"; mkdir -p "$PREFIX"
else
  echo "materializing the prefix once (about 600 MB)"
  rm -rf "$ROOT"; mkdir -p "$RT" "$PREFIX"
  cp -a "$ART/." "$RT/"
  chmod -R u+w "$RT"
fi

G=$RT/libexec/cider
rm -rf "$G/bin/gatec" "$G/bin/gater" "$G/pbwork"
mkdir -p "$G/bin/gatec" "$G/bin/gater" "$G/pbwork/c" "$G/pbwork/r"
cp "$CBIN" "$G/bin/gatec/PlistBuddy"; chmod +x "$G/bin/gatec/PlistBuddy"
cp "$RBIN" "$G/bin/gater/PlistBuddy"; chmod +x "$G/bin/gater/PlistBuddy"

# The seed. A dict with one of most things in it, so entry resolution, arrays, nesting and each
# printed type are all reachable from one file.
# Writes the seed into the read-only base AND removes any copy the previous case left in the
# writable overlay, which is what makes each case start from the same file.
write_seed () {
  case "$1" in *pbwork/c/*) rm -f "$PREFIX/pbwork/c/test.plist" ;; *) rm -f "$PREFIX/pbwork/r/test.plist" ;; esac
  cat > "$1" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.example.seed</string>
	<key>Count</key>
	<integer>7</integer>
	<key>Ratio</key>
	<real>1.5</real>
	<key>Flag</key>
	<true/>
	<key>Items</key>
	<array>
		<string>first</string>
		<string>second</string>
	</array>
	<key>Nested</key>
	<dict>
		<key>Inner</key>
		<string>value</string>
	</dict>
</dict>
</plist>
PLIST
}

export CIDERPREFIX=$PREFIX
export CIDER_NO_LAUNCHD=1
export DSERVER_LIBEXEC_PATH=$G
export DSERVER_MLDR_PATH=$G/usr/libexec/cider/mldr

# The container's own stderr, removed so the comparison is of the PROGRAM. Defined here, and the
# absence of this definition is what once made all 61 cases fail at once while every control still
# passed: an undefined function meant the .clean files were never written and cmp compared
# nothing. A total failure with healthy controls means the harness, not the program.
clean_err () { grep -vE "^cp: |^\\[mldr\\] " "$1" > "$1.clean" 2>/dev/null; return 0; }

i=0
retries=0
# ONE RETRY PER CASE, AND HERE IS WHY IT IS NOT A WAY TO HIDE A DIFFERENCE.
#
# The container faults nondeterministically at startup: measured over three full runs, three
# cases failed, a DIFFERENT one each time, and each was the harness rather than either program.
# One was rc 136, SIGFPE with a core dump, which did not reproduce in 10 runs against either
# binary. Two were "[mldr] start-stack mmap at 0x7fffff600000 failed", where the LOADER died
# before PlistBuddy ran, once on the Rust side and once on the C side.
#
# A retry is safe against THAT and only that: a real behavioural difference is deterministic and
# fails both attempts. To keep it honest the count is reported, and more than a handful of
# retries fails the gate, because that would mean the environment is too unstable to conclude
# anything from a green run.
run_case () { # label, then the PlistBuddy arguments (the plist path is appended)
  local label=$1; shift
  i=$((i + 1))
  local attempt ok note=""
  for attempt in 1 2; do
    ok=1
    write_seed "$G/pbwork/c/test.plist"
    write_seed "$G/pbwork/r/test.plist"
    timeout 240 "$RT/bin/cider" shell /bin/gatec/PlistBuddy "$@" /pbwork/c/test.plist \
      > "$O/c$i.out" 2> "$O/c$i.err"; echo $? > "$O/c$i.rc"
    timeout 240 "$RT/bin/cider" shell /bin/gater/PlistBuddy "$@" /pbwork/r/test.plist \
      > "$O/r$i.out" 2> "$O/r$i.err"; echo $? > "$O/r$i.rc"
    # THE OVERLAY COPY IS THE RESULT when the command saved; the base is what it started from.
    cp "${PREFIX}/pbwork/c/test.plist" "$O/c$i.plist" 2>/dev/null \
      || cp "$G/pbwork/c/test.plist" "$O/c$i.plist"
    cp "${PREFIX}/pbwork/r/test.plist" "$O/r$i.plist" 2>/dev/null \
      || cp "$G/pbwork/r/test.plist" "$O/r$i.plist"
    clean_err "$O/c$i.err"; clean_err "$O/r$i.err"
    cmp -s "$O/c$i.out" "$O/r$i.out" || ok=0
    cmp -s "$O/c$i.err.clean" "$O/r$i.err.clean" || ok=0
    [ "$(cat "$O/c$i.rc")" = "$(cat "$O/r$i.rc")" ] || ok=0
    cmp -s "$O/c$i.plist" "$O/r$i.plist" || ok=0
    [ $ok = 1 ] && break
  done
  if [ $ok = 1 ]; then
    if [ "$attempt" = 2 ]; then retries=$((retries + 1)); note="  (retried once)"; fi
    printf "OK    %-34s rc %s, %4s bytes out, plist %5s bytes%s\n" "$label" \
      "$(cat "$O/c$i.rc")" "$(wc -c < "$O/c$i.out")" "$(wc -c < "$O/c$i.plist")" "$note"
  else
    echo "FAIL  $label  (failed TWICE, so this is not the container)"
    echo "  rc C=$(cat "$O/c$i.rc") R=$(cat "$O/r$i.rc")"
    diff "$O/c$i.out" "$O/r$i.out" | head -8
    diff "$O/c$i.err.clean" "$O/r$i.err.clean" | head -4
    diff "$O/c$i.plist" "$O/r$i.plist" | head -8
    fail=1
  fi
}

# READING AND PRINTING
run_case "Print whole file"            -c "Print"
run_case "Print -x whole file"      -x -c "Print"
run_case "Print one entry"             -c "Print :CFBundleIdentifier"
run_case "Print an integer"            -c "Print :Count"
run_case "Print a real"                -c "Print :Ratio"
run_case "Print a bool"                -c "Print :Flag"
run_case "Print an array"              -c "Print :Items"
run_case "Print a nested dict"         -c "Print :Nested"
run_case "Print an array element"      -c "Print :Items:1"
run_case "Print a missing entry"       -c "Print :NoSuchKey"
run_case "ls alias"                    -c "ls :Nested"

# WRITING, which is what makes the plist comparison matter
run_case "Add a string"                -c "Add :NewString string hello"
run_case "Add a quoted string"         -c "Add :Quoted string \"two words\""
run_case "Add an escaped string"       -c "Add :Esc string \"a\\tb\\nc\""
run_case "Add an integer"              -c "Add :NewInt integer 42"
run_case "Add a hex integer"           -c "Add :Hex integer 0x1f"
run_case "Add a real"                  -c "Add :NewReal real 2.75"
run_case "Add a bool yes"              -c "Add :NewBool bool yes"
run_case "Add a bool nonsense"         -c "Add :NewBool2 bool wibble"
run_case "Add data"                    -c "Add :NewData data abcd"
run_case "Add a dict"                  -c "Add :NewDict dict"
run_case "Add an array"                -c "Add :NewArray array"
run_case "Add into an array"           -c "Add :Items:1 string inserted"
run_case "Add past the array end"      -c "Add :Items:99 string appended"
run_case "Add a nested autocreated"    -c "Add :A:B:C string deep"
run_case "Add an existing key"         -c "Add :Count integer 9"
run_case "Add an unknown type"         -c "Add :X wibble 1"
run_case "Set a string"                -c "Set :CFBundleIdentifier com.example.set"
run_case "Set an integer"              -c "Set :Count 99"
run_case "Set a real"                  -c "Set :Ratio 0.125"
run_case "Set an array element"        -c "Set :Items:0 changed"
run_case "Set a container"             -c "Set :Nested x"
run_case "Set a missing entry"         -c "Set :NoSuchKey x"
run_case "Delete a key"                -c "Delete :Count"
run_case "Delete an array element"     -c "Delete :Items:0"
run_case "Delete a missing entry"      -c "Delete :NoSuchKey"
run_case "Copy an entry"               -c "Copy :CFBundleIdentifier :CopiedId"
run_case "Copy a container"            -c "Copy :Nested :CopiedDict"
run_case "Copy onto an existing key"   -c "Copy :Count :Ratio"
run_case "Copy from a missing entry"   -c "Copy :NoSuchKey :Dst"

# ENTRY PATH SHAPES, where the tokenizer decides the answer
run_case "path with no leading colon"  -c "Print CFBundleIdentifier"
run_case "path with doubled colons"    -c "Print ::Nested::Inner"
run_case "path with a trailing colon"  -c "Print :Nested:"
run_case "the empty path"              -c "Print :"

# ERRORS AND USAGE
run_case "an unrecognized command"     -c "Frobnicate"
run_case "missing arguments"           -c "Add"
run_case "Save"                        -c "Save"
run_case "Clear"                       -c "Clear dict"

# THE ONE DELIBERATE DIFFERENCE, asserted rather than skipped.
#
# `Add "unterminated` makes the C CRASH. getWord returns NULL, the C does not check it, passes it
# to the next getWord and then to parseType, and strcasecmp dereferences NULL. The crash also eats
# the message it had already printed, because stdout is block buffered into a pipe. Verified by
# running it interactively: the session dies before the following command runs and NOTHING is
# printed, not even the first prompt.
#
# The port prints Unterminated Quotes once and abandons the command. Reproducing a null
# dereference would be absurd, so this asserts the difference is exactly the expected one.
write_seed "$G/pbwork/c/test.plist"; write_seed "$G/pbwork/r/test.plist"
timeout 240 "$RT/bin/cider" shell /bin/gatec/PlistBuddy -c 'Add ":oops string x' /pbwork/c/test.plist \
  > "$O/uq-c.out" 2>&1; echo $? > "$O/uq-c.rc"
timeout 240 "$RT/bin/cider" shell /bin/gater/PlistBuddy -c 'Add ":oops string x' /pbwork/r/test.plist \
  > "$O/uq-r.out" 2>&1; echo $? > "$O/uq-r.rc"
if [ "$(cat "$O/uq-c.rc")" != "$(cat "$O/uq-r.rc")" ] && grep -q "Unterminated Quotes" "$O/uq-r.out"; then
  echo "OK    unterminated quotes: EXPECTED difference (C rc $(cat "$O/uq-c.rc") and silent, Rust rc $(cat "$O/uq-r.rc") and says so)"
else
  echo "FAIL  unterminated quotes: the expected divergence did not happen"
  echo "  C rc $(cat "$O/uq-c.rc"), Rust rc $(cat "$O/uq-r.rc")"; fail=1
fi

# ------------------------------------------------------------------------------------------
# PHASE 2: INTERACTIVE SESSIONS, which is where the mutations are actually observed.
j=0
session () { # label, then the command lines
  local label=$1; shift
  j=$((j + 1))
  local attempt ok note=""
  printf '%s\n' "$@" Exit > "$O/s$j.in"
  for attempt in 1 2; do
    ok=1
    write_seed "$G/pbwork/c/test.plist"
    write_seed "$G/pbwork/r/test.plist"
    timeout 240 "$RT/bin/cider" shell /bin/gatec/PlistBuddy /pbwork/c/test.plist \
      < "$O/s$j.in" > "$O/sc$j.out" 2> "$O/sc$j.err"; echo $? > "$O/sc$j.rc"
    timeout 240 "$RT/bin/cider" shell /bin/gater/PlistBuddy /pbwork/r/test.plist \
      < "$O/s$j.in" > "$O/sr$j.out" 2> "$O/sr$j.err"; echo $? > "$O/sr$j.rc"
    clean_err "$O/sc$j.err"; clean_err "$O/sr$j.err"
    cmp -s "$O/sc$j.out" "$O/sr$j.out" || ok=0
    cmp -s "$O/sc$j.err.clean" "$O/sr$j.err.clean" || ok=0
    [ "$(cat "$O/sc$j.rc")" = "$(cat "$O/sr$j.rc")" ] || ok=0
    [ $ok = 1 ] && break
  done
  if [ $ok = 1 ]; then
    if [ "$attempt" = 2 ]; then retries=$((retries + 1)); note="  (retried once)"; fi
    printf "OK    session %-27s rc %s, %4s bytes out%s\n" "$label" \
      "$(cat "$O/sc$j.rc")" "$(wc -c < "$O/sc$j.out")" "$note"
  else
    echo "FAIL  session $label  (failed TWICE, so this is not the container)"
    diff "$O/sc$j.out" "$O/sr$j.out" | head -10
    diff "$O/sc$j.err.clean" "$O/sr$j.err.clean" | head -4
    fail=1
  fi
}

session "add a string then print"     "Add :NewString string hello" "Print"
session "add each scalar then print"  "Add :S string s" "Add :I integer 5" "Add :R real 1.25" \
                                      "Add :B bool true" "Add :D data raw" "Print"
session "add containers then print"   "Add :Dct dict" "Add :Arr array" "Add :Arr:0 string zero" \
                                      "Add :Dct:k string v" "Print"
session "autocreate a deep path"      "Add :A:B:C string deep" "Print :A"
session "insert into an array"        "Add :Items:1 string inserted" "Print :Items"
session "append past the array end"   "Add :Items:99 string appended" "Print :Items"
session "set then print"              "Set :CFBundleIdentifier changed" "Set :Count 123" "Print"
session "delete then print"           "Delete :Count" "Delete :Items:0" "Print"
session "copy then print"             "Copy :Nested :CopiedDict" "Print :CopiedDict"
session "a bad copy then print"       "Copy :NoSuchKey :Dst" "Print"
session "print xml after a change"    "Add :Late string x" "Print"
session "unknown command mid session" "Frobnicate" "Add :After string y" "Print :After"
session "help and print"              "Help" "Print :Count"

# THE CONTROLS.
bytes=0
for n in $(seq 1 $i); do bytes=$((bytes + $(wc -c < "$O/c$n.out"))); done
if [ "$bytes" -lt 200 ]; then
  echo "CONTROL FAILED: $bytes bytes of stdout across $i cases, so this gate compared silence"
  fail=1
else
  echo "OK    control A: $bytes bytes of stdout across $i cases"
fi
# CONTROL B, AND IT IS THE ONE THAT EARNED ITS KEEP. It asserts that a case which adds a key
# wrote a DIFFERENT file from one that only prints. When it failed, the cause was that the gate
# was reading the wrong layer, not that saving was broken.
if cmp -s "$O/c1.plist" "$O/c12.plist"; then
  echo "CONTROL FAILED: a case that adds a key wrote the same file as one that only prints,"
  echo "                so the plist comparison is looking at the wrong path again"
  fail=1
else
  echo "OK    control B: an Add really rewrote the file ($(wc -c < "$O/c12.plist") bytes vs $(wc -c < "$O/c1.plist") for a plain Print)"
fi
# And a mutating session must print differently from one whose command failed.
if cmp -s "$O/sc1.out" "$O/sc10.out"; then
  echo "CONTROL FAILED: a session that adds a key printed the same as one whose copy failed"
  fail=1
else
  echo "OK    control D: a mutating session prints differently, so the session compare can fail"
fi
# And the comparison must be able to see a difference at all.
if cmp -s "$O/c1.out" "$O/c4.out"; then
  echo "CONTROL FAILED: two different Print commands produced identical output"
  fail=1
else
  echo "OK    control C: two Print commands differ, so cmp can fail"
fi
if [ "$retries" -gt 6 ]; then
  echo "FAIL  $retries of $((i + j)) cases needed a retry, which is too unstable to conclude from"
  fail=1
else
  echo "OK    container flakiness: $retries of $((i + j)) cases needed one retry"
fi
echo "GATE_FAIL=$fail  ($i argument cases, $j interactive sessions, $retries retried)"
exit $fail
