#!/usr/bin/env bash
# TEAR DOWN EVERY GUEST PROCESS OF ONE PREFIX, so the prefix can be written to.
#
# A prefix is an overlayfs UPPER layer, and changing a layer under a live mount is undefined:
# the guest keeps the view it had, so a directory staged from the host while a container is up
# simply does not exist inside it. That is how the test harness lost its staging directory and
# reported nine failures whose message was "cd: /private/var/tmp/cider-nix-tests: No such file
# or directory" -- the files were there, on the host, in the same path.
#
# TWO SIGNALS, both required. The exe says what the process IS: only a guest runtime binary is
# mldr or ciderd, and no shell can be, so matching the command line alone kills the caller. The
# command line says which PREFIX it belongs to: containers of different prefixes share one
# runtime, so no guest process of /tmp/cider-mm-1000/prefix has that prefix in its exe path.
set -u
PREFIX=${1:?usage: kill-cider-container.sh /tmp/cider-mm-1000/prefix}
ME=$$
killed=0
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  [ "$pid" = "$ME" ] && continue
  exe=$(readlink "$p/exe" 2>/dev/null) || continue
  case "$exe" in
    */mldr|*/ciderd) ;;
    *) continue ;;
  esac
  cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null) || continue
  case "$cmd" in
    *"$PREFIX"*)
      kill -9 "$pid" 2>/dev/null && killed=$((killed+1))
      ;;
  esac
done
echo "container down: killed $killed guest processes of $PREFIX"
