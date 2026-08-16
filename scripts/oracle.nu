#!/usr/bin/env nu
# oracle.nu - correctness oracle: rebuild a derivation and bit-compare it against the output
# substituted from cache.nixos.org.
#
# nixpkgs 26.05 is a frozen target and cache.nixos.org retains its Hydra-built x86_64-darwin
# outputs permanently, so "does our locally-built output match the official one, byte for byte"
# is a real correctness signal: it catches a shim that lies subtly to the compiler (codegen
# divergence = stop-the-line).
#
# Given an installable, this: (1) substitutes the official output, (2) rebuilds it locally with
# `nix build --rebuild`, (3) emits a JSON verdict. --rebuild itself does the hash comparison and
# fails on mismatch; on mismatch we also run diffoscope if available.
#
# Converted from bash (task #40). An earlier pass wrote this off as untestable, because a real
# run needs the network and a full rebuild. That was wrong: every branch is reachable by putting
# a stub `nix` on PATH, which is how it was checked against the bash version. All four verdicts
# (match, mismatch, build-failure, substitute-failure), their exit codes (0, 3, 1, 1), the JSON
# on stdout and in --json, the usage error and the unknown-flag error were compared, and the
# mismatch branch was driven by a stub that writes "hash mismatch" and fails, which is what
# distinguishes it from a plain build failure.
#
# Usage:
#   scripts/oracle.nu [--flake REF] [--system x86_64-darwin]
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
#   scripts/oracle.nu --flake "github:NixOS/nixpkgs/fd146203..." hello

def say [msg: string] { print -e $msg }

# The same object shape the bash version printed, built field by field: `to json` emits neither
# of the two spacings, and this file is read by whatever consumes the verdict.
def verdict_json [full: string, system: string, verdict: string, detail: string] {
    let fields = ([
        $"\"installable\": ($full | to json --raw)"
        $"\"system\": ($system | to json --raw)"
        $"\"verdict\": ($verdict | to json --raw)"
        $"\"detail\": ($detail | to json --raw)"
    ] | str join ", ")
    $"{($fields)}"
}

def main [
    --flake: string = "."                # flake to resolve <attr> against
    --system: string = "x86_64-darwin"   # build system
    --json: string = ""                  # write the JSON verdict here too
    --diff                               # run diffoscope on mismatch (best-effort)
    installable?: string
] {
    let inst = ($installable | default "")
    if ($inst | is-empty) {
        say "usage: scripts/oracle.nu [opts] <attr|installable>"
        exit 2
    }

    # Resolve a full installable. If it contains a '#', use as-is; else attach the flake and the
    # legacyPackages.<system> path.
    let full = if ($inst | str contains "#") {
        $inst
    } else {
        $"($flake)#legacyPackages.($system).($inst)"
    }

    # One place that prints the verdict and picks the exit code, so a branch cannot report one
    # thing and exit another.
    def emit [v: string, detail: string] {
        let out = (verdict_json $full $system $v $detail)
        print $out
        if ($json | is-not-empty) { $"($out)\n" | save -f $json }
        exit (match $v {
            "match" => 0
            "mismatch" => 3
            _ => 1
        })
    }

    say $"[oracle] resolving ($full)"

    # 1. Ensure the official output is present (substituted from the cache).
    #
    # STDERR TO A FILE THROUGHOUT THIS FUNCTION. `| complete` buffers it, and step 2 below
    # passes -L, which makes nix print the FULL BUILD LOG of whatever derivation it was
    # handed. This tool is pointed at arbitrary nixpkgs derivations, so that can be a
    # compiler building itself. Buffering it is the same defect that killed the suite at
    # 17.3 GB, in the one tool the end goal depends on.
    let errf = (($env.TMPDIR? | default "/tmp") + "/cider-oracle-nix.err")
    let sub = (^nix build $full --system $system --no-link --print-out-paths err> $errf | complete)
    let out_path = ($sub.stdout | lines | last | default "")
    if ($out_path | is-empty) {
        emit "substitute-failure" $"could not substitute or evaluate ($full)"
    }
    say $"[oracle] official output: ($out_path)"

    # 2. Rebuild locally and let nix compare against the substituted output.
    let rbf = (($env.TMPDIR? | default "/tmp") + "/cider-oracle-rebuild.err")
    let rb = (^nix build $full --system $system --rebuild --no-link -L err> $rbf | complete)
    if $rb.exit_code == 0 {
        emit "match" $out_path
    }

    # --rebuild failed: distinguish a hash mismatch from a plain build failure.
    #
    # The log is READ FROM THE FILE, and only the two things this actually needs are taken
    # out of it: whether a mismatch marker appears anywhere, and the last 20 lines to show.
    # Loading the whole -L log into a variable to ask those two questions is what the
    # redirect above exists to avoid, so grep and tail do it instead.
    let marker = (do -i {
        ^grep -E -i -m 1 "hash mismatch|differs from|not deterministic|output.*differ" $rbf
    } | complete | get stdout | str trim)
    let tail20 = (do -i { ^tail -n 20 $rbf } | complete | get stdout | lines)
    if ($marker | is-not-empty) {
        let detail = $"output differs from ($out_path)"
        say $"[oracle] MISMATCH: ($detail)"
        $tail20 | each {|l| say $l }
        if $diff and (which diffoscope | is-not-empty) {
            let check_path = $"($out_path).check"
            if ($check_path | path exists) {
                (^diffoscope $out_path $check_path | complete | get stdout
                    | lines | first 80 | each {|l| say $l })
            }
        }
        emit "mismatch" $detail
    } else {
        say "[oracle] BUILD FAILURE"
        $tail20 | each {|l| say $l }
        emit "build-failure" "local rebuild failed (not a hash mismatch)"
    }
}
