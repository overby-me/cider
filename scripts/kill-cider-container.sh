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
# mldr, ciderd or the cider launcher, and no shell can be, so matching the command line alone kills
# the caller. The second signal says which PREFIX it belongs to: containers of different prefixes
# share one runtime, so no guest process of /tmp/cider-mm-1000/prefix has that prefix in its exe
# path.
#
# THIS REAPED NOTHING FOR A WHOLE SESSION, and seventeen processes had piled up by the end of it,
# each one a candidate cause of the intermittency being measured around them. Three reasons, all
# found by listing what was actually running:
#
#   1. readlink appends " (deleted)" once the binary has been REBUILT, so */mldr stopped matching
#      exactly the processes left over from an earlier build, which is the set this exists for.
#   2. The cider launcher was not in the list at all.
#   3. The launcher does not carry the prefix on its command line. It is "cider shell <app>", and
#      the prefix is in its ENVIRONMENT as CIDERPREFIX, so it could never match either.
set -u
PREFIX=${1:?usage: kill-cider-container.sh /tmp/cider-mm-1000/prefix}
ME=$$
killed=0
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  [ "$pid" = "$ME" ] && continue
  exe=$(readlink "$p/exe" 2>/dev/null) || continue
  exe=${exe% (deleted)}
  case "$exe" in
    */mldr|*/ciderd|*/cider) ;;
    *) continue ;;
  esac
  cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null) || continue
  env=$(tr '\0' '\n' < "$p/environ" 2>/dev/null | grep '^CIDERPREFIX=' || true)
  case "$cmd$env" in
    *"$PREFIX"*)
      kill -9 "$pid" 2>/dev/null && killed=$((killed+1))
      ;;
  esac
done
echo "container down: killed $killed guest processes of $PREFIX"
