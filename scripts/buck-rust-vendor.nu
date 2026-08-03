#!/usr/bin/env nu
# Materialize the locked Rust crate sources into buck-rust/ for the Buck2 port.
#
# The port drives rustc directly, with no cargo in the build graph, so a dependency cannot be
# fetched while the build runs: the sources have to be inside the project root before buck2
# starts, since that is the only place it can read from. nix/devShell.nix unpacks every crate
# in the three Cargo.lock files into $DARLING_RUST_VENDOR, and this copies them here -- the
# same arrangement scripts/buck-src.sh gives the pinned C sources under buck-src/.
#
# Copied, not symlinked: buck2 hashes what it reads, and a glob across a symlinked directory
# into the store either misses files or drags the closure in.
#
# Converted from bash (task #40), checked by running both on the no-op path AND on the copy
# path with a crate removed, then comparing the restored trees file by file.
#
# Usage:  scripts/buck-rust-vendor.nu

def main [] {
    cd ($env.FILE_PWD | path join ".." | path expand)

    let vendor = ($env.DARLING_RUST_VENDOR? | default "")
    if ($vendor | is-empty) {
        print -e "DARLING_RUST_VENDOR is unset -- run inside `nix develop`"
        exit 2
    }

    mkdir buck-rust
    mut n = 0
    # NO trailing slash in the pattern: bash's */ means "directories only", while nushell's
    # glob matches nothing at all with one. And `ls | where type == dir` is not the fix
    # either, because the vendor entries are SYMLINKS into the store and report as symlink.
    for crate in (glob $"($vendor)/*") {
        let name = ($crate | path basename)
        # The vendor entry carries a .cargo-checksum.json that cargo writes and rustc never
        # reads; leaving it out keeps the tree to sources.
        if not ($"buck-rust/($name)/Cargo.toml" | path exists) {
            rm -rf $"buck-rust/($name)"
            mkdir $"buck-rust/($name)"
            ^cp -a --reflink=auto $"($crate)/." $"buck-rust/($name)/"
            ^chmod -R u+w $"buck-rust/($name)"
            do -i { rm -f $"buck-rust/($name)/.cargo-checksum.json" }
        }
        $n = $n + 1
    }
    print $"buck-rust: ($n) crate\(s\) materialized"
}
