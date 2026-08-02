#!/usr/bin/env bash
# Load every scripting-language extension the prefix ships, inside the buck2-built Darling.
#
# This is the widest runtime probe in the tree by artifact count. python's 54 lib-dynload
# extensions, zsh's 35 loadable modules and perl's XS modules are each a separate Mach-O
# that buck2 built, linked and installed -- and until this ran, every one of them had been
# checked only for "does it link". Loading a module executes its initializer, resolves its
# symbols against the frameworks underneath, and returns something the interpreter can use,
# which is a great deal more than a link check.
#
# Counts rather than pass/fail per module: a handful of extensions can legitimately fail on
# a system without the thing they wrap. What matters is the number, and that it does not
# drop. Thresholds below are the measured floor, not an aspiration.
#
# Usage:  scripts/buck-scripting-check.sh [<scratch dir>]
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '%s\n' "$*" >&2; }

root=${1:-/tmp/darling-script-$(id -u)}
rt="$root/rt"
prefix="$root/prefix"

command -v buck2 >/dev/null || {
	say "missing buck2 -- run inside \`nix develop\`"
	exit 2
}

say "== building the prefix =="
art=$(buck2 build //buck/prefix:darling_prefix --show-output 2>/dev/null | tail -1 | awk '{print $2}')
[ -d "$art" ] || {
	say "the prefix did not build"
	exit 1
}

# Anything still running from a previous run holds the old prefix mounted.
for p in /proc/[0-9]*; do
	ex=$(readlink "$p/exe" 2>/dev/null) || continue
	case "$ex" in "$root"/*) kill -9 "${p#/proc/}" 2>/dev/null || true ;; esac
done

say "== materializing into $rt =="
chmod -R u+w "$rt" 2>/dev/null || true
rm -rf "$rt" "$prefix" "$prefix.workdir"
mkdir -p "$rt" "$prefix"
# `cp -a`, never `cp -aL`: the prefix installs Volumes/DarlingEmulatedDrive -> /.
cp -a "$art"/. "$rt"/
chmod -R u+w "$rt"

run_guest() {
	DPREFIX="$prefix" \
		DARLING_NO_LAUNCHD=1 \
		DSERVER_LIBEXEC_PATH="$rt/libexec/darling" \
		DSERVER_MLDR_PATH="$rt/libexec/darling/usr/libexec/darling/mldr" \
		timeout 300 "$rt/bin/darling" shell "$@" 2>&1
}

fail=0

say "== python: import every lib-dynload extension =="
# Imported by NAME through __import__ rather than by dlopening the file, so this is the
# path a real program takes: python finds the .so, runs its init function and binds the
# module object.
py='
import os, sys
d = "/System/Library/Frameworks/Python.framework/Versions/2.7/lib/python2.7/lib-dynload"
mods = sorted(f.split(".")[0] for f in os.listdir(d) if f.endswith(".so"))
ok, bad = 0, []
for m in mods:
    try:
        __import__(m)
        ok += 1
    except Exception as e:
        bad.append("%s: %s" % (m, e))
print("PY_RESULT %d/%d" % (ok, len(mods)))
for b in bad:
    print("PY_FAIL " + b)
'
out=$(run_guest /usr/bin/python2.7 -c "$py" || true)
printf '%s\n' "$out" | grep -E "^PY_(RESULT|FAIL)" || true
py_ok=$(printf '%s\n' "$out" | sed -n 's|^PY_RESULT \([0-9]*\)/.*|\1|p')
py_tot=$(printf '%s\n' "$out" | sed -n 's|^PY_RESULT [0-9]*/\([0-9]*\)|\1|p')
[ "${py_ok:-0}" -ge 50 ] &&
	say "ok   python imported ${py_ok}/${py_tot} extension modules (floor 50)" ||
	{ say "FAIL python imported ${py_ok:-0}/${py_tot:-?} extension modules, floor is 50"; fail=1; }

say "== zsh: zmodload every module =="
# zmodload is zsh's dlopen. Each module registers builtins or parameters on success.
zs='
setopt no_err_exit 2>/dev/null
ok=0; tot=0
for f in /usr/lib/zsh/5.7.1/zsh/*.so; do
  tot=$((tot+1))
  m="zsh/${f:t:r}"
  if zmodload "$m" 2>/dev/null; then ok=$((ok+1)); else print "ZSH_FAIL $m"; fi
done
print "ZSH_RESULT $ok/$tot"
'
out=$(run_guest /bin/zsh -c "$zs" || true)
printf '%s\n' "$out" | grep -E "^ZSH_(RESULT|FAIL)" || true
z_ok=$(printf '%s\n' "$out" | sed -n 's|^ZSH_RESULT \([0-9]*\)/.*|\1|p')
z_tot=$(printf '%s\n' "$out" | sed -n 's|^ZSH_RESULT [0-9]*/\([0-9]*\)|\1|p')
[ "${z_ok:-0}" -ge 30 ] &&
	say "ok   zsh loaded ${z_ok}/${z_tot} modules (floor 30)" ||
	{ say "FAIL zsh loaded ${z_ok:-0}/${z_tot:-?} modules, floor is 30"; fail=1; }

say "== perl: load the XS modules =="
# The bundled XS modules are the ones with a .bundle behind them, which is what the port
# builds twice (5.18 and 5.28) and what the install used to get wrong.
pl='
my @m = qw(POSIX Socket Fcntl List::Util Storable Encode Data::Dumper Time::HiRes
           Digest::MD5 Digest::SHA MIME::Base64 Compress::Raw::Zlib Cwd File::Glob);
my ($ok, @bad) = (0);
for my $m (@m) { eval "require $m; 1" ? $ok++ : push @bad, "$m: $@"; }
print "PL_RESULT $ok/" . scalar(@m) . "\n";
print "PL_FAIL $_\n" for @bad;
'
out=$(run_guest /usr/bin/perl -e "$pl" || true)
printf '%s\n' "$out" | grep -E "^PL_(RESULT|FAIL)" || true
p_ok=$(printf '%s\n' "$out" | sed -n 's|^PL_RESULT \([0-9]*\)/.*|\1|p')
p_tot=$(printf '%s\n' "$out" | sed -n 's|^PL_RESULT [0-9]*/\([0-9]*\)|\1|p')
[ "${p_ok:-0}" -ge 12 ] &&
	say "ok   perl loaded ${p_ok}/${p_tot} XS modules (floor 12)" ||
	{ say "FAIL perl loaded ${p_ok:-0}/${p_tot:-?} XS modules, floor is 12"; fail=1; }

[ "$fail" = 0 ] && {
	say "PASS: the scripting cones load their extensions"
	exit 0
}
say "FAIL: see above"
exit 1
