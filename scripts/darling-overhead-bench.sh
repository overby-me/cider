#!/usr/bin/env bash
# Measure Darling's runtime overhead vs native, using bash as the workload.
# Two cost classes (see plan/darling-overhead-bench.md):
#   compute = pure bash arithmetic loop  -> per-operation runtime/libSystem cost
#   spawn   = fork+exec `bash -c :` loop -> process-creation cost (darlingserver+dyld)
#
# The spawn number is optimization-independent and is the build-time-relevant tax.
# The compute number is sensitive to how bash was compiled, so for a fair ratio
# build the Darling bash and a native bash with the SAME -O level (the Darling
# bash from build-bash-under-darling.sh is effectively -O0).
#
# Usage:
#   DARLING=./result/bin/darling DPREFIX=$HOME/.dbash \
#   DARLING_BASH=/Users/root/bbuild/bash-5.3/bash \
#   NATIVE_BASH=bash CN=1000000 SN=30 scripts/darling-overhead-bench.sh
set -u
DARLING="${DARLING:-./result/bin/darling}"
export DPREFIX="${DPREFIX:-$HOME/.dbash}"           # must be warm/populated + short path
DARLING_BASH="${DARLING_BASH:-/Users/root/bbuild/bash-5.3/bash}"  # container path
NATIVE_BASH="${NATIVE_BASH:-bash}"
CN="${CN:-1000000}"; SN="${SN:-30}"
export DARLING_SHELL_STARTUP_TIMEOUT="${DARLING_SHELL_STARTUP_TIMEOUT:-60}"

# The workload, run identically on host and inside the container.
work() { # $1=bash-to-time  $2=bash-to-spawn  $3=CN  $4=SN
	"$1" -c '
		sp="$1"; cn="$2"; sn="$3"; TIMEFORMAT="%R"
		compute(){ i=0; while [ "$i" -lt "$cn" ]; do i=$((i+1)); done; }
		spawn(){   i=0; while [ "$i" -lt "$sn" ]; do "$sp" -c : ; i=$((i+1)); done; }
		printf "COMPUTE(%s) " "$cn"; { time compute; } 2>&1
		printf "SPAWN(%s) "   "$sn"; { time spawn;   } 2>&1
	' _ "$2" "$3" "$4"
}

echo "## native  ($("$NATIVE_BASH" --version | head -1))"
work "$NATIVE_BASH" "$NATIVE_BASH" "$CN" "$SN"

echo "## darling ($DARLING, prefix=$DPREFIX)"
pkill -x darlingserver 2>/dev/null; pkill -x mldr 2>/dev/null; sleep 1
# Same loop, executed inside one warm container boot.
timeout 260 "$DARLING" shell "$DARLING_BASH" -c '
	sp="$1"; cn="$2"; sn="$3"; TIMEFORMAT="%R"
	compute(){ i=0; while [ "$i" -lt "$cn" ]; do i=$((i+1)); done; }
	spawn(){   i=0; while [ "$i" -lt "$sn" ]; do "$sp" -c : ; i=$((i+1)); done; }
	printf "COMPUTE(%s) " "$cn"; { time compute; } 2>&1
	printf "SPAWN(%s) "   "$sn"; { time spawn;   } 2>&1
' _ "$DARLING_BASH" "$CN" "$SN" 2>&1 | grep -viE 'rlimit'
pkill -x darlingserver 2>/dev/null; pkill -x mldr 2>/dev/null
echo "# compute ratio is confounded by bash -O level; spawn ratio is not."
echo "# See plan/darling-overhead-bench.md for the matched-optimization control."
