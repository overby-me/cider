# Environment for the buck2 daemon. Source this before any buck2 command:
#   source scripts/buck-env.nu
#
# The daemon inherits the PATH of whatever shell starts it, and the port's actions call clang,
# bison, flex, python3 and ar BY NAME. A daemon that restarts from a bare shell (an OOM killed
# one here) comes back without them, and then every action fails with
# "Spawning executable `clang` failed: Failed to spawn a process" -- which reads like a build
# error rather than an environment one.
#
# The dev shell already has all of it, so this reuses direnv's cached profile when there is one
# and falls back to `nix develop`.
#
# Converted from bash (task #40). It was scheduled LAST because every other bash script sourced
# it; by the time its turn came, none did -- that was re-tested rather than assumed. Verified by
# sourcing BOTH versions in their own shells and diffing the resulting PATH entry by entry, on
# the direnv-cache path and with the cache hidden so the nix develop fallback runs.
#
# SOURCED, not executed: nushell runs `source` in the caller's scope, so the assignments below
# land in the interactive session the same way the bash export did.

# nushell has no $BASH_SOURCE; a sourced file gets its own directory in $env.FILE_PWD.
let _buck_env_repo = ($env.FILE_PWD | path join ".." | path expand)

# The rc records the shell's exported environment; take the longest PATH-shaped value and give
# each store entry its /bin, which the recorded buildInputs list lacks. Still python: this is a
# regex over a shell rc file, and the two versions have to agree on the SAME parse.
let _buck_env_parse = 'import re, sys
rc = open(sys.argv[1]).read()
cands = re.findall(r"PATH=([\x27\x22]?)((?:/nix/store/[^:\x27\x22\n]+:){3,}[^\x27\x22\n]*)\1", rc)
if not cands:
    raise SystemExit(1)
p = max((c[1] for c in cands), key=len)
print(":".join(e if e.endswith("/bin") or not e.startswith("/nix/store") else e + "/bin"
                for e in p.split(":") if e))'

let _rc = (glob $"($_buck_env_repo)/.direnv/flake-profile-*.rc" | sort | get 0? | default "")
let _dev_path = if ($_rc | is-empty) {
    ""
} else {
    # try, because a base shell without python3 must fall through to nix develop the way the
    # bash version did rather than aborting: an external that is not on PATH RAISES in nushell.
    let r = (try { $_buck_env_parse | ^python3 - $_rc | complete } catch { {exit_code: 1, stdout: ""} })
    if $r.exit_code == 0 { $r.stdout | str trim } else { "" }
}

if ($_dev_path | is-not-empty) {
    $env.PATH = ($_dev_path | split row ":" | append $env.PATH)
} else {
    print -e "buck-env: no direnv cache; falling back to nix develop"
    # The LAST line only. `nix develop` runs the shellHook first, so its stdout starts with the
    # banner; the bash version eval-ed all of it and printed a run of "command not found" for
    # every banner word. Taking one line is both quieter and safer.
    let p = (^nix develop --command sh -c 'echo $PATH' | complete | get stdout | lines
        | where {|l| $l =~ '(^|:)/' } | last | default "")
    if ($p | is-not-empty) { $env.PATH = ($p | split row ":") }
}

# buck2 and watchman come from the dev shell too when it is entered normally; the direnv cache
# records the buildInputs, which is why they can be missing here. Add the ones this repo pins if
# they are not already reachable.
if (which buck2 | is-empty) {
    let b = (glob "/nix/store/*buck2*/bin" --no-file | sort | get 0? | default "")
    if ($b | is-not-empty) { $env.PATH = ([$b] | append $env.PATH) }
}
if (which watchman | is-empty) {
    let w = (glob "/nix/store/*watchman*/bin" --no-file | sort | get 0? | default "")
    if ($w | is-not-empty) { $env.PATH = ([$w] | append $env.PATH) }
}

# Sanity: name what is missing rather than letting an action fail obscurely.
#
# rustc and bindgen are on this list because the direnv cache goes STALE: it records the
# buildInputs of the shell as it was when direnv last evaluated the flake, so a tool added to the
# dev shell afterwards is simply absent, and the fallback to `nix develop` never fires because
# there IS a cache. The failure then arrives from buck2 as "exec: rustc: not found" on an action,
# several minutes into a build, which reads like a toolchain bug rather than a stale environment.
# If these warn, run the command under `nix develop --command bash -c '...'` (or re-enter the
# direnv shell to refresh the cache).
for _t in [clang bison flex python3 ar buck2 watchman rustc bindgen] {
    if (which $_t | is-empty) { print -e $"buck-env: WARNING: ($_t) not on PATH" }
}
