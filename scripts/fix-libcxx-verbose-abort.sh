#!/usr/bin/env bash
# Work around the guest libc++ symbol gap that blocks M1 (guest nix building hello):
# clang's libLLVM (LLVM 21, built for macOS 14) references std::__1::__libcpp_verbose_abort
# (__ZNSt3__122__libcpp_verbose_abortEPKcz), which darling's bundled /usr/lib/libc++.1.dylib
# does not export -> dyld abort_with_payload -> the build's clang aborts. (Task #10 territory;
# the daemon itself hosts the build fine.)
#
# Rather than rebuild all of darling's libc++, this links a small WRAPPER libc++.1.dylib that
# (a) defines __libcpp_verbose_abort as a thin abort() and (b) -reexport_library's the
# original (renamed to libc++.1.2.dylib via a same-length install-name byte patch, so no
# install_name_tool is needed). libc++ already reexports libc++abi the same way. Staged into
# the runtime SDK; re-run after any runtime rebuild that overwrites libc++.1.dylib.
#
# Usage: fix-libcxx-verbose-abort.sh [<darling-runtime-root>]   (default: ~/darling-rt)
set -eu
RT="${1:-$HOME/darling-rt}"
SDK="$RT/libexec/darling"
LIBDIR="$SDK/usr/lib"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CLANG="$(ls /nix/store/*cling-unwrapped*/bin/clang 2>/dev/null | head -1)"
LD="$(ls /nix/store/*darling-ld64*/bin/x86_64-apple-darwin*-ld 2>/dev/null | head -1)"
[ -x "$CLANG" ] || { echo "no darwin-capable clang found"; exit 1; }
[ -x "$LD" ] || { echo "no darling-ld64 found (nix build .#darling-ld64)"; exit 1; }
[ -f "$LIBDIR/libc++.1.dylib" ] || { echo "no libc++.1.dylib under $LIBDIR"; exit 1; }

# already fixed?
if strings "$LIBDIR/libc++.1.dylib" 2>/dev/null | grep -q "libc++.2.dylib"; then
  echo "libc++.1.dylib already wrapped; nothing to do"; exit 0
fi

# 1. the missing symbol, as a Mach-O object
cat > "$TMP/va.cpp" <<'EOF'
extern "C" void abort(void);
namespace std { inline namespace __1 {
__attribute__((visibility("default"))) void __libcpp_verbose_abort(const char*, ...) { abort(); }
}}
EOF
"$CLANG" -target x86_64-apple-macos10.15 -c "$TMP/va.cpp" -o "$TMP/va.o"

# 2. rename the original via a same-length install-name byte patch (libc++.1 -> libc++.2)
cp "$LIBDIR/libc++.1.dylib" "$TMP/libc++.2.dylib"
python3 - "$TMP/libc++.2.dylib" <<'EOF'
import sys
p = sys.argv[1]
d = open(p, "rb").read()
open(p, "wb").write(d.replace(b"/usr/lib/libc++.1.dylib", b"/usr/lib/libc++.2.dylib"))
EOF

# 3. link the wrapper (defines the symbol, reexports the renamed original)
"$LD" -dylib -arch x86_64 -platform_version macos 10.15.0 10.15.0 \
  -install_name /usr/lib/libc++.1.dylib \
  -o "$TMP/libc++.1.dylib" \
  "$TMP/va.o" \
  -reexport_library "$TMP/libc++.2.dylib" \
  -lSystem -syslibroot "$SDK" -L "$LIBDIR"

# 4. stage (back up the original once)
[ -f "$LIBDIR/libc++.1.dylib.pre-vabort-bak" ] || cp "$LIBDIR/libc++.1.dylib" "$LIBDIR/libc++.1.dylib.pre-vabort-bak"
cp "$TMP/libc++.2.dylib" "$LIBDIR/libc++.2.dylib"
cp "$TMP/libc++.1.dylib" "$LIBDIR/libc++.1.dylib"
echo "staged wrapped libc++.1.dylib (+ libc++.2.dylib) into $LIBDIR"
