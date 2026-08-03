#!/usr/bin/env nu
# symbol-demand.nu - build the "demand list" for Phase B.
#
# Given a set of store paths (or any directories/files), find every Mach-O object and, using
# its bind tables, extract the symbols it imports FROM THE SYSTEM LIBRARIES (absolute install
# names under /usr/lib or /System/...), i.e. exactly the symbols Darling's reimplemented
# libraries must provide. Symbols bound to @rpath/@loader_path/@executable_path dylibs are
# intra-closure (the closure ships them itself) and are excluded.
#
# Output: a ranked table (symbol, expected install-name, #referencing binaries). Phase B.3
# grinds this in rank order; pair with tbd-diff.py (the supply side).
#
# Runs on Linux against Mach-O binaries using llvm tools (llvm-objdump / llvm-otool), so no
# macOS host is needed.
#
# Converted from bash (task #40) and checked by diffing the markdown BYTE FOR BYTE against the
# bash version over 54 real dylibs (913 ranked symbols), and the --json report through jq -S,
# since this writes JSON with `to json` rather than by hand.
#
# Two things the walk depends on, both found by measuring rather than by reading:
#
#   glob needs BOTH --no-dir and --no-symlink to equal `find -type f`. Under buck-out, 4447 of
#   6353 entries are symlinks, so --no-dir alone scans each artifact several times over.
#
#   The ranked table is `sort -rn -k1,1` output, and GNU sort breaks a tie on the numeric key
#   by comparing the WHOLE LINE (reversed, here). That is reproduced by sorting one zero-padded
#   key string descending: the count sorts numerically because it is padded, and the rest of
#   the key then breaks ties exactly as the whole-line comparison did.
#
# Usage:
#   scripts/symbol-demand.nu [--system x86_64-darwin] [--arch x86_64]
#                            [--json out.json] [--closure]
#                            [--include-bundled] PATH...
#
#   --closure          expand each PATH via `nix path-info -r` first
#   --system           Darwin system double (selects default --arch)
#   --arch             Mach-O slice to inspect (x86_64 | arm64)
#   --json FILE        also write a JSON report
#   --include-bundled  also count @rpath/@loader_path imports (debug)
#
# Example (bootstrap-tools demand list):
#   let bt = (nix eval --raw "github:NixOS/nixpkgs/<rev>#legacyPackages.x86_64-darwin.stdenv.bootstrapTools.outPath")
#   nix-store -r $bt
#   scripts/symbol-demand.nu $bt | save -f plan/symbol-gap.md

# The Mach-O magics, thin and fat, both byte orders. Compared as binary rather than as a hex
# string: bash needed head -c4 | od | tr, three processes per FILE, to say the same thing.
const MAGICS = [
    0x[feedface] 0x[cefaedfe] 0x[feedfacf] 0x[cffaedfe]
    0x[cafebabe] 0x[bebafeca] 0x[cafebabf] 0x[bfbafeca]
]

# Header rows and section banners in llvm-objdump's three bind tables. A row is data only if it
# is none of these and has at least two fields.
const BIND_NOISE = [segment Bind Lazy Weak "Bind:"]

def say [msg: string] { print -e $msg }

# Is this install name a system library Darling must provide?
def is_system_lib [name: string] {
    ($name | str starts-with "/usr/lib/") or ($name | str starts-with "/System/Library/")
}

def is_macho [f: string] {
    # An unreadable file is not a Mach-O for this purpose, which is what 2>/dev/null bought
    # the bash version.
    let magic = (try { open --raw $f | bytes at 0..<4 } catch { return false })
    $magic in $MAGICS
}

# leaf-name -> full install name (from the dependent-dylib list). The bind table names a dylib
# by its basename up to the first dot, so correlate back to the install name to classify system
# vs bundled: /usr/lib/libSystem.B.dylib -> "libSystem", libc++.1.0.dylib -> "libc++", a
# framework's .../CoreFoundation -> "CoreFoundation".
def dep_names [otool: string, arch: string, bin: string] {
    ^$otool -arch $arch -L $bin
    | complete | get stdout | lines | skip 1
    | each {|l| $l | str trim --left | str replace --regex ' \(compatibility.*$' '' }
    | where {|n| $n != "" }
    | each {|n| {leaf: ($n | path basename | split row "." | first), name: $n} }
}

def bind_rows [objdump: string, arch: string, bin: string] {
    ^$objdump --macho --bind --lazy-bind --weak-bind $"--arch=($arch)" $bin
    | complete | get stdout | lines
    | each {|l| $l | split row --regex '\s+' | where {|w| $w != "" } }
    | where {|w| ($w | length) >= 2 }
    | where {|w| not (($w | first) in $BIND_NOISE) }
    | where {|w| ($w | get 1) != "section" }
    # ... dylib symbol are the last two columns of every table that has a dylib column. The
    # weak table has none, so its rows name the addend instead, which then fails the
    # system-library test and drops out -- the same thing the bash version did.
    | each {|w| {dylib: ($w | get (($w | length) - 2)), sym: ($w | last)} }
}

def scan_binary [objdump: string, otool: string, arch: string, include_bundled: bool, bin: string] {
    let deps = (dep_names $otool $arch $bin)
    bind_rows $objdump $arch $bin
    | each {|r|
        # Last match wins, as the last assignment did in the bash associative array.
        let hits = ($deps | where leaf == $r.dylib)
        {sym: $r.sym, install: (if ($hits | is-empty) { $r.dylib } else { ($hits | last).name })}
    }
    | where {|r| $include_bundled or (is_system_lib $r.install) }
    # Dedup AFTER the filter, exactly as the bash loop did: a symbol bound once from a bundled
    # dylib and once from a system one is still counted, because the bundled row is skipped
    # before it can mark the symbol seen.
    | uniq-by sym
    | each {|r| {symbol: $r.sym, install: $r.install, binary: $bin} }
}

def main [
    --system: string = "x86_64-darwin"  # Darwin system double (selects the default --arch)
    --arch: string = ""                 # Mach-O slice to inspect (x86_64 | arm64)
    --json: string = ""                 # also write a JSON report here
    --closure                           # expand each PATH via nix path-info -r first
    --include-bundled                   # also count @rpath/@loader_path imports (debug)
    ...paths: string
] {
    if ($paths | is-empty) {
        say "usage: scripts/symbol-demand.nu [opts] PATH..."
        exit 2
    }

    let arch = if ($arch | is-not-empty) {
        $arch
    } else if $system == "aarch64-darwin" {
        "arm64"
    } else {
        "x86_64"
    }

    let objdump = (which llvm-objdump | get path.0? | default "")
    let otool = (which llvm-otool | get path.0? | default "")
    if ($objdump | is-empty) or ($otool | is-empty) {
        say "error: need llvm-objdump and llvm-otool (nix shell nixpkgs#llvm)"
        exit 3
    }

    let inputs = if $closure {
        let r = (^nix path-info -r ...$paths | complete)
        if $r.exit_code == 0 { $r.stdout | lines | where {|l| $l != "" } } else { $paths }
    } else {
        $paths
    }

    # find -type f: files only, and NOT symlinks. --no-dir alone is not the same thing.
    let files = (
        $inputs
        | each {|input|
            if ($input | path type) == "file" {
                [$input]
            } else {
                glob $"($input)/**/*" --no-dir --no-symlink
            }
        }
        | flatten
    )

    let bins = ($files | where {|f| is_macho $f })
    let demand = (
        $bins | each {|b| scan_binary $objdump $otool $arch $include_bundled $b } | flatten
    )

    # Rank each symbol by the number of DISTINCT referencing binaries, keeping the last
    # install name seen for it as the representative.
    let ranked = (
        $demand
        | group-by symbol
        | items {|sym, rows| {
            refs: ($rows | get binary | uniq | length)
            symbol: $sym
            install: ($rows | last | get install)
        }}
        | insert key {|r|
            let n = ($"($r.refs)" | fill --width 9 --character "0" --alignment right)
            $"($n)\t($r.symbol)\t($r.install)"
        }
        | sort-by key --reverse
        | reject key
    )

    # Group counts by install name. Same tie-break, one column narrower.
    let bylib = (
        $ranked
        | group-by install
        | items {|name, rows| {n: ($rows | length), install: $name} }
        | insert key {|r|
            let n = ($"($r.n)" | fill --width 9 --character "0" --alignment right)
            $"($n)\t($r.install)"
        }
        | sort-by key --reverse
        | reject key
    )

    print $"# Symbol demand list \(($system), arch ($arch))
"
    print "Generated by `scripts/symbol-demand.nu`. Demand side of the Phase B gap:
system-library symbols imported by the scanned Mach-O binaries \(bind tables),
excluding intra-closure @rpath imports, ranked by how many distinct binaries
reference each. Cross-check ownership/availability with `scripts/tbd-diff.py`.
"
    print $"- Binaries scanned: **($bins | length)**"
    print $"- Distinct system symbols imported: **($ranked | length)**"
    print "
## By expected install name
"
    print "| # symbols | install name |"
    print "|---:|:---|"
    for r in $bylib { print $"| ($r.n) | `($r.install)` |" }
    print "
## Ranked symbols
"
    print "| # refs | symbol | install name |"
    print "|---:|:---|:---|"
    for r in $ranked { print $"| ($r.refs) | `($r.symbol)` | `($r.install)` |" }

    if ($json | is-not-empty) {
        # `to json` rather than the printf the bash version used: same content, and it escapes
        # a symbol that the hand-rolled writer would have emitted as invalid JSON.
        {
            system: $system
            arch: $arch
            binaries_scanned: ($bins | length)
            symbols: ($ranked | each {|r| {refs: $r.refs, symbol: $r.symbol, install_name: $r.install}})
        } | to json | save -f $json
        say $"wrote ($json)"
    }
}
