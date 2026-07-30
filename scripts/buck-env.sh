# Environment for the buck2 daemon. Source this before any buck2 command:
#   source scripts/buck-env.sh
#
# The daemon inherits the PATH of whatever shell starts it, and the port's actions call
# clang, bison, flex, python3 and ar BY NAME. A daemon that restarts from a bare shell
# (an OOM killed one here) comes back without them, and then every action fails with
# "Spawning executable `clang` failed: Failed to spawn a process" -- which reads like a
# build error rather than an environment one.
#
# The dev shell already has all of it, so this reuses direnv's cached profile when there
# is one and falls back to `nix develop`.
_buck_env_repo="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

_buck_env_from_direnv() {
	local rc
	rc=$(ls -1 "$_buck_env_repo"/.direnv/flake-profile-*.rc 2>/dev/null | head -1) || return 1
	[ -n "$rc" ] || return 1
	python3 - "$rc" <<'PY'
import re, sys
rc = open(sys.argv[1]).read()
# The rc records the shell's exported environment; take the longest PATH-shaped value
# and give each store entry its /bin, which the recorded buildInputs list lacks.
cands = re.findall(r"PATH=(['\"]?)((?:/nix/store/[^:'\"\n]+:){3,}[^'\"\n]*)\1", rc)
if not cands:
    raise SystemExit(1)
p = max((c[1] for c in cands), key=len)
print(":".join(e if e.endswith("/bin") or not e.startswith("/nix/store") else e + "/bin"
                for e in p.split(":") if e))
PY
}

if _dev_path=$(_buck_env_from_direnv 2>/dev/null) && [ -n "$_dev_path" ]; then
	export PATH="$_dev_path:$PATH"
else
	echo "buck-env: no direnv cache; falling back to nix develop" >&2
	eval "$(nix develop --command sh -c 'echo export PATH=\"$PATH\"')"
fi
unset _dev_path _buck_env_repo
unset -f _buck_env_from_direnv

# buck2 and watchman come from the dev shell too when it is entered normally; the
# direnv cache records the buildInputs, which is why they can be missing here. Add the
# ones this repo pins if they are not already reachable.
command -v buck2 >/dev/null 2>&1 || {
	_b=$(ls -d /nix/store/*buck2*/bin 2>/dev/null | head -1)
	[ -n "$_b" ] && export PATH="$_b:$PATH"
}
command -v watchman >/dev/null 2>&1 || {
	_w=$(ls -d /nix/store/*watchman*/bin 2>/dev/null | head -1)
	[ -n "$_w" ] && export PATH="$_w:$PATH"
}
unset _b _w

# Sanity: name what is missing rather than letting an action fail obscurely.
for _t in clang bison flex python3 ar buck2 watchman; do
	command -v "$_t" >/dev/null 2>&1 || echo "buck-env: WARNING: $_t not on PATH" >&2
done
unset _t
