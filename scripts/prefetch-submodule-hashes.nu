#!/usr/bin/env nu
# prefetch-submodule-hashes.nu - fill the `hash` field in nix/submodules.json.
#
# The second half of the off-git-submodules move (with nix/lib/darling-src.nix): compute the
# fetchFromGitHub SRI hash for each pinned (owner, repo, rev) by prefetching the GitHub archive,
# and write it back into the manifest so darling-src.nix can fetch it purely.
#
# The manifest itself was first written by a gen-submodule-manifest.sh that no longer exists,
# which is why the file shape below is described here rather than pointed at.
#
# Incremental: by default only fills entries whose hash is still "". Pass paths (submodule
# paths, or basename substrings) to restrict to a subset, or --all to recompute every entry.
# Safe to interrupt and re-run; each success is persisted immediately.
#
# Converted from bash (task #40). The prefetch itself needs the network, so the parts that do
# not were tested against the bash version directly: the no-op run over the real 147-entry
# manifest, the work-list selection (filters, --limit, --all) over a doctored manifest in a
# scratch tree, the FAILED branch, and write_hash, which is exported precisely so the manifest
# rewrite can be diffed BYTE FOR BYTE against the python heredoc it replaces. That rewrite is
# the risky half: the file has a hand-made shape (one object per line, ", " and ": " separators)
# that `to json` does not produce, so it is built field by field here.
#
# That testing found a bug in the bash version, which is the divergence between the two: when a
# RECURSIVE entry failed to prefetch, nix-prefetch-git printed nothing, the empty stdout went
# into a python one-liner that raised JSONDecodeError, and set -o pipefail killed the whole run
# with a traceback. So the FAILED branch was unreachable for exactly the 8 entries that need it
# most, and one unreachable repo aborted a 147-entry run that the header calls safe to re-run.
#
# Usage:
#   scripts/prefetch-submodule-hashes.nu                 # all missing hashes
#   scripts/prefetch-submodule-hashes.nu xnu bootstrap   # only matching subset
#   scripts/prefetch-submodule-hashes.nu --limit 5       # first 5 missing
#   scripts/prefetch-submodule-hashes.nu --all           # recompute everything

# One entry in the manifest's own shape: python's json.dumps with separators=(", ", ": "),
# which is neither of the two shapes `to json` can emit, so the fields are joined by hand.
# `to json --raw` per VALUE still does the escaping.
def obj_line [e: record] {
    let fields = ($e | items {|k, v| $"($k | to json --raw): ($v | to json --raw)" } | str join ", ")
    $"{($fields)}"
}

export def save_manifest [manifest: string, entries: list] {
    let body = ($entries | each {|e| $"  (obj_line $e)" } | str join ",\n")
    $"[\n($body)\n]\n" | save -f $manifest
}

# Persist one hash. Re-read and re-write the whole file each time so an interrupted run leaves
# a complete manifest, which is what makes this safe to re-run.
export def write_hash [manifest: string, idx: int, sri: string] {
    let d = (open --raw $manifest | from json)
    save_manifest $manifest ($d | update $idx {|e| $e | upsert hash $sri })
}

def prefetch [owner: string, repo: string, rev: string, recursive: bool, lfs: bool] {
    if $recursive or $lfs {
        # Neither can come from an archive tarball. Recursive submodules (their own
        # .gitmodules) need fetchSubmodules, or the nested content is missing; an LFS pin needs
        # --fetch-lfs, or every LFS-tracked file is its 132-byte pointer rather than its
        # content. Both are fetchgit on the nix side, so both are nix-prefetch-git here.
        let extra = (
            (if $recursive { ["--fetch-submodules"] } else { [] })
            ++ (if $lfs { ["--fetch-lfs"] } else { [] })
        )
        let r = (^nix-prefetch-git --quiet --url $"https://github.com/($owner)/($repo)"
            --rev $rev ...$extra | complete)
        if $r.exit_code != 0 { return "" }
        try { $r.stdout | from json | get hash? | default "" } catch { "" }
    } else {
        let url = $"https://github.com/($owner)/($repo)/archive/($rev).tar.gz"
        let h = (^nix-prefetch-url --unpack --type sha256 $url | complete)
        if $h.exit_code != 0 { return "" }
        let base32 = ($h.stdout | lines | last | default "")
        if ($base32 | is-empty) { return "" }
        let c = (^nix hash convert --hash-algo sha256 --to sri $base32 | complete)
        if $c.exit_code == 0 {
            $c.stdout | str trim
        } else {
            # Older nix spells it the other way.
            let c2 = (^nix hash to-sri --type sha256 $base32 | complete)
            if $c2.exit_code == 0 { $c2.stdout | str trim } else { "" }
        }
    }
}

def main [
    --all               # recompute every entry, not just the ones with no hash
    --limit: int = 0    # stop after this many entries
    ...filters: string  # only entries whose path or repo contains one of these
] {
    cd ($env.FILE_PWD | path join ".." | path expand)
    let manifest = "nix/submodules.json"

    let selected = (
        open --raw $manifest | from json | enumerate
        | where {|it| $all or (($it.item.hash? | default "") | is-empty) }
        | where {|it|
            ($filters | is-empty) or ($filters | any {|f|
                ($it.item.path | str contains $f) or ($it.item.repo | str contains $f)
            })
        }
    )
    let work = if $limit > 0 { $selected | first $limit } else { $selected }

    print $"prefetching ($work | length) submodule hash\(es)..."
    mut ok = 0
    mut fail = 0
    for it in $work {
        let e = $it.item
        let rec = ($e.recursive? | default false)
        let lfs = ($e.lfs? | default false)
        let tag = if $lfs { " \(lfs)" } else if $rec { " \(recursive)" } else { "" }
        print -n $"  [($it.index)] ($e.owner)/($e.repo) @ ($e.rev | str substring 0..<10)($tag) ... "
        let sri = (prefetch $e.owner $e.repo $e.rev $rec $lfs)
        if ($sri | is-empty) {
            print "FAILED"
            $fail = $fail + 1
        } else {
            write_hash $manifest $it.index $sri
            print $sri
            $ok = $ok + 1
        }
    }
    print $"done: ($ok) ok, ($fail) failed"
}
