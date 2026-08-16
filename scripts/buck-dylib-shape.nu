#!/usr/bin/env nu
# Is every file the prefix installs as a .dylib actually a Mach-O?
#
# Found by scripts/checks/buck-loadall-check.nu, which dlopens what the prefix ships: 44 of the 227
# dylibs would not load, and all 44 turned out to be 131-byte GIT LFS POINTERS --
#
#   version https://git-lfs.github.com/spec/v1
#   oid sha256:018c53767605d9daa7cbb3bd49bba3ec04e7ecc942e4d7389640a0a9e87fb327
#   size 6718752
#
# -- because the Swift runtime binaries live in LFS and the checkout never fetched them. The
# port then installs the pointer as though it were a library. Not a buck2 bug: the reference
# copies the same bytes. But nothing anywhere said the prefix contained text files named
# .dylib, and "it linked" cannot catch it because nothing links against them.
#
# This asserts the shape rather than the count of failures: every .dylib is Mach-O, except a
# named set that is a pointer for a known reason. If the LFS objects are ever fetched these
# become Mach-O and the check says so, which is the signal to delete the exception.
#
# The first script converted from bash to nushell (task #40). Its output is byte-identical to
# the bash version it replaced, on the real prefix and on a crafted failing one, which is how
# the conversion was checked rather than by reading it.
#
# Usage:
#   scripts/buck-dylib-shape.nu <prefix root>     # the directory holding usr/ and System/

# The only place a non-Mach-O .dylib is currently expected, and only as an LFS pointer.
const EXPECTED_DIR = "usr/lib/swift"

def main [root?: string] {
    if ($root | is-empty) or (not ($root | path exists)) {
        print -e $"usage: buck-dylib-shape.nu <prefix root>"
        exit 2
    }

    # ABSOLUTE, because glob returns absolute paths whatever it is given, so stripping a
    # RELATIVE root off them matches nothing and every path stays absolute -- which then
    # fails the "is it under usr/lib/swift" test and reports 44 good files as misplaced.
    # buck-test.nu passes a relative prefix, so this is the shape that matters, and an
    # equivalence test run only with an absolute path will not see it.
    let base = ($root | path expand)

    # REGULAR FILES ONLY, which is not incidental: glob returns symlinks too, and the prefix
    # is full of compatibility links, so counting them would double most libraries. bash's
    # find -type f excluded them and the conversion is only faithful if this does too.
    # 309 glob hits, 227 regular files.
    #
    # Eight of those links look BROKEN from here and are not. usr/lib/libkrb5.dylib and its
    # seven siblings point at /System/Library/Frameworks/Kerberos.framework/Kerberos, an
    # absolute GUEST path: it resolves inside the container, where that is the framework, and
    # cannot resolve on the host, where /System/Library does not exist. The target is real --
    # the port builds it as vendor/src:Kerberos_dylib and the prefix carries 174KB of it. A
    # host-side existence test on an absolute guest path answers a question nobody asked.
    #
    # Sorted, so the report is stable between runs and between machines.
    let files = (glob $"($base)/**/*.dylib" | where {|f| ($f | path type) == "file" } | sort)

    let classified = ($files | each {|f|
        let rel = ($f | str replace $"($base)/" "")
        let kind = (^file -bL $f | complete | get stdout | str trim)
        if ($kind =~ "Mach-O") {
            {rel: $rel, class: "macho", kind: $kind}
        } else {
            # Not Mach-O. An LFS pointer is a known state; anything else is not.
            let head = (do -i { open --raw $f | first 45 | decode utf-8 } | default "")
            if ($head | str starts-with "version https://git-lfs.github.com/spec/v1") {
                {rel: $rel, class: "pointer", kind: $kind}
            } else {
                {rel: $rel, class: "other", kind: $kind}
            }
        }
    })

    let macho = ($classified | where class == "macho")
    let pointers = ($classified | where class == "pointer")

    # A Mach-O where a pointer was expected means the LFS objects arrived.
    let stray = ($macho | where {|r| $r.rel | str starts-with $"($EXPECTED_DIR)/" })
    # A pointer outside the expected directory, or anything that is neither.
    let wrong = (
        ($pointers | where {|r| not ($r.rel | str starts-with $"($EXPECTED_DIR)/") }
            | each {|r| $"($r.rel) \(LFS pointer outside ($EXPECTED_DIR)\)" })
        ++ ($classified | where class == "other" | each {|r| $"($r.rel) \(($r.kind)\)" })
    ) | sort
    # SORTED, because the two categories are gathered separately here while the bash version
    # appended them as it walked the sorted file list. Same set, different order, and a
    # report that reorders itself between implementations is a diff nobody can read.

    print $"installed .dylib files: ($macho | length | $in + ($pointers | length))"
    print $"  Mach-O:               ($macho | length)"
    print $"  git LFS pointers:     ($pointers | length)  \(all under ($EXPECTED_DIR)\)"

    if ($stray | is-not-empty) {
        print ""
        print $"GOOD NEWS, and this check now needs updating: ($stray | length) file\(s\) under ($EXPECTED_DIR) are real"
        print "Mach-O, so the LFS objects have been fetched. Drop the exception."
        $stray | first 5 | each {|r| print $"  ($r.rel)" }
        exit 1
    }

    if ($wrong | is-not-empty) {
        print ""
        print $"FAIL: ($wrong | length) file\(s\) installed as .dylib are not Mach-O and are not the known"
        print "Swift LFS pointers. A file that is not a library cannot be loaded, and nothing"
        print "else here would notice, because nothing links against it:"
        $wrong | first 10 | each {|w| print $"  ($w)" }
        exit 1
    }

    print ""
    print $"ok: every installed .dylib is Mach-O, except ($pointers | length) known Swift LFS pointers"
}
