#!/usr/bin/env nu
# Work around the guest libc++ symbol gap that blocks M1 (guest nix building hello):
# clang's libLLVM (LLVM 21, built for macOS 14) references std::__1::__libcpp_verbose_abort
# (__ZNSt3__122__libcpp_verbose_abortEPKcz), which cider's bundled /usr/lib/libc++.1.dylib does
# not export -> dyld abort_with_payload -> the build's clang aborts. (Task #10 territory; the
# daemon itself hosts the build fine.)
#
# Rather than rebuild all of cider's libc++, this links a small WRAPPER libc++.1.dylib that
# (a) defines __libcpp_verbose_abort as a thin abort() and (b) -reexport_library's the original
# (renamed to libc++.2.dylib via a same-length install-name byte patch, so no install_name_tool
# is needed). libc++ already reexports libc++abi the same way. Staged into the runtime SDK;
# re-run after any runtime rebuild that overwrites libc++.1.dylib.
#
# Converted from bash (task #40) and verified by running BOTH versions against separate copies
# of a materialized runtime root and comparing the staged libc++.1.dylib and libc++.2.dylib byte
# for byte, plus the already-wrapped no-op and the three missing-input errors.
#
# Usage: fix-libcxx-verbose-abort.nu [<cider-runtime-root>]   (default: ~/cider-rt)

def say [msg: string] { print $msg }

def main [rt?: string] {
    let rt = ($rt | default ($env.HOME | path join "cider-rt"))
    let sdk = $"($rt)/libexec/cider"
    let libdir = $"($sdk)/usr/lib"

    # cling-unwrapped, not clang-unwrapped: that is what the bash version globbed for, and it
    # resolves to Cling's bundled clang-18, which is unwrapped and can target darwin. Kept
    # exactly as it was rather than "corrected" to a package this machine does not have in the
    # store, because the conversion is not the place to change what tool gets picked.
    # No `first?` in nushell, so the empty case is handled before taking one.
    let clang_hits = (glob "/nix/store/*cling-unwrapped*/bin/clang" | sort)
    let ld_hits = (glob "/nix/store/*cider-ld64*/bin/x86_64-apple-darwin*-ld" | sort)
    let clang = (if ($clang_hits | is-empty) { "" } else { $clang_hits | first })
    let ld = (if ($ld_hits | is-empty) { "" } else { $ld_hits | first })
    if ($clang | is-empty) or (not ($clang | path exists)) {
        say "no darwin-capable clang found"
        exit 1
    }
    if ($ld | is-empty) or (not ($ld | path exists)) {
        say "no cider-ld64 found (nix build .#cider-ld64)"
        exit 1
    }
    if not ($"($libdir)/libc++.1.dylib" | path exists) {
        say $"no libc++.1.dylib under ($libdir)"
        exit 1
    }

    # already fixed?
    let s = (^strings $"($libdir)/libc++.1.dylib" | complete)
    if ($s.stdout | str contains "libc++.2.dylib") {
        say "libc++.1.dylib already wrapped; nothing to do"
        exit 0
    }

    let tmp = (mktemp -d)

    # 1. the missing symbol, as a Mach-O object
    let va = 'extern "C" void abort(void);
namespace std { inline namespace __1 {
__attribute__((visibility("default"))) void __libcpp_verbose_abort(const char*, ...) { abort(); }
}}'
    $"($va)\n" | save -f $"($tmp)/va.cpp"
    ^$clang -target x86_64-apple-macos10.15 -c $"($tmp)/va.cpp" -o $"($tmp)/va.o"

    # 2. rename the original via a same-length install-name byte patch (libc++.1 -> libc++.2).
    # Read whole, patch, write: a pipeline that reads and writes the same path truncates it.
    let patched = (
        open --raw $"($libdir)/libc++.1.dylib"
        | bytes replace --all ("/usr/lib/libc++.1.dylib" | into binary) ("/usr/lib/libc++.2.dylib" | into binary)
    )
    $patched | save -f $"($tmp)/libc++.2.dylib"

    # 3. link the wrapper (defines the symbol, reexports the renamed original)
    ^$ld -dylib -arch x86_64 -platform_version macos 10.15.0 10.15.0 -install_name /usr/lib/libc++.1.dylib -o $"($tmp)/libc++.1.dylib" $"($tmp)/va.o" -reexport_library $"($tmp)/libc++.2.dylib" -lSystem -syslibroot $sdk -L $libdir

    # 4. stage (back up the original once)
    if not ($"($libdir)/libc++.1.dylib.pre-vabort-bak" | path exists) {
        ^cp $"($libdir)/libc++.1.dylib" $"($libdir)/libc++.1.dylib.pre-vabort-bak"
    }
    ^cp $"($tmp)/libc++.2.dylib" $"($libdir)/libc++.2.dylib"
    ^cp $"($tmp)/libc++.1.dylib" $"($libdir)/libc++.1.dylib"
    ^rm -rf $tmp
    say $"staged wrapped libc++.1.dylib \(+ libc++.2.dylib) into ($libdir)"
}
