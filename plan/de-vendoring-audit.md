# De-vendoring audit: src/external submodules vs nixpkgs x86_64-darwin (task #23)

Question: for each of Darling's 147 vendored submodules, is there a prebuilt
nixpkgs `x86_64-darwin` package that could replace building it from vendored
source? Method: mapped each submodule repo (minus the `darling-` prefix) to a
candidate nixpkgs attr and evaluated it against the flake's pinned nixpkgs
`legacyPackages.x86_64-darwin` (`scripts`-free, one `nix eval`). Results below;
raw data in the audit run.

## Summary

| Category | Count | Substitute? |
|---|---:|---|
| Apple system / emulation | 72 | No -- these ARE macOS / the emulation layer |
| Generic third-party | ~54 | Yes -- nixpkgs ships a darwin build |
| Apple CLI-tool bundles | 18 | Case-by-case (GNU equivalents, not drop-in) |
| Review | 3 | cctools/-port (build tooling), TextEdit (demo app) |

## The gate (applies to ALL substitutions)

A nixpkgs `x86_64-darwin` dylib is Mach-O built against the macOS SDK's libSystem.
To *load and run under Darling* it needs Darling's libSystem to supply every symbol
it imports -- i.e. the Campaign-2 symbol-gap work (task #10, still open; `hello`
does not run under Darling yet). So this de-vendoring is **downstream of** that,
not a shortcut around it. It becomes real per-lib as the symbol gap closes and each
candidate is proven to dyld-load under Darling. Two more wrinkles for category 1:
- **Install names**: nixpkgs dylibs carry `/nix/store/...` install names; apps and
  the Darling system expect `/usr/lib/libX.dylib`. Needs `install_name_tool` or a
  Darling-side mapping. (Version-agnostic install names like `libssl.dylib` help.)
- **Version/ABI**: Darling pins versions to a macOS release; nixpkgs pins its own.
  Notably Darling vendors **four** libressl versions (2.2.9/2.5.5/2.6.5/2.8.3) for
  per-release compat; nixpkgs has one.

## Category 1 -- generic third-party (de-vendor targets)

Direct nixpkgs darwin attr (evaluated OK):
`openssl curl zlib bzip2 libxml2 libxslt icu(icu4c) sqlite pcre expat libffi
libarchive libedit libiconv ncurses nghttp2 apr OpenLDAP(openldap) openpam openssh
less groff man(man-db) nano vim screen tcsh zsh bash bc perl ruby rsync zip gnutar
file lzfse xar(xar-minimal) libressl(x4) openjdk(zulu-ca-jdk)`

Substitutable but need the correct attr name (literal name had no attr):
`awk->gawk  grep->gnugrep  python->python3  liblzma->xz  bind9->bind
BerkeleyDB->db  gpatch->gnupatch  gnudiff->diffutils`  (`top` has no darwin attr.)

Flag for extra care (macOS /usr/lib system libs -- install-name/ABI sensitive, or
Apple-owned upstream): `libiconv ncurses libedit libxml2 libarchive cups xar`.
`cups` is Apple-owned; verify Darling's is not a fork with private additions.
`netcat` mapped to `libressl` (its `nc`) -- verify that is the intended tool.

## Category 2 -- Apple system / emulation (NO substitute)

72 submodules that are the macOS userland or the Mach/BSD emulation, or an
Apple-specific fork whose same-named nixpkgs attr is a *different* project
(`libcxx`/`compiler-rt` = LLVM's, not Apple's). Must stay Darling's own build:

`libSystem libc libsystem_* dyld objc4 libdispatch libclosure libpthread
libplatform libmalloc libunwind libstdcxx(Apple) libcxx(Apple) libcxxabi
compiler-rt(Apple) foundation corefoundation cfnetwork coretls Security
SecurityTokend SmartCardServices OpenDirectory DirectoryService DSTools
commoncrypto corecrypto libauto IOKitUser IOStorageFamily IONetworkingFamily
iokitd IOKitTools libxpc configd syslog libnotify Libinfo librpcsvc csu
architecture AvailabilityVersions copyfile keymgr libresolv libutil removefile
mDNSResponder libnetwork WTF WebCore JavaScriptCore bmalloc metal xnu
libkqueue(Darling) cocotron Heimdal(Apple) MITKerberosShim passwordserver_sasl
openssl_certificates pyobjc dtrace OpenAL glut energytrace dbuskit
coreservices swift(Darling) libtelnet` (plus a few misc).

## Category 3 -- Apple CLI-tool bundles (review case-by-case)

`shell_cmds file_cmds text_cmds adv_cmds basic_cmds patch_cmds misc_cmds doc_cmds
mail_cmds system_cmds network_cmds remote_cmds diskdev_cmds bootstrap_cmds(mig)
files crontabs darling-dmg installer usertemplate`

nixpkgs has GNU/BSD equivalents (coreutils, gnugrep, ...) but these are Apple's
specific implementations with macOS-specific flags/behaviour; some (`bootstrap_cmds`
= mig) are build tools, not runtime. Substitute only where behaviour matches.

## Review (3)

- `cctools`, `cctools-port` -- the Mach-O toolchain (ld64/ar/...). nixpkgs ships
  `cctools`/`cctools-port` for darwin (its stdenv uses them). This is the "host
  tooling" half of task #23: Darling builds an in-tree ld64 for the
  cc-wrapper-bypass; evaluate replacing it with nixpkgs' cctools/ld64. Build-time
  only, so it dodges the runtime libSystem gate.

  **Prototype result (checked).** nixpkgs `pkgsCross.x86_64-darwin` uses a *classic
  cctools* linker (`x86_64-apple-darwin-cctools-binutils-darwin`, i.e. `ld64-956.6`
  + `cctools-1010.6`), not lld -- so it accepts the classic `-Z` / `-dylib_file` /
  `-sdk_version` flags `use_ld64.cmake` relies on. Architecturally the swap is
  sound. BUT building that ld64 on **x86_64-linux fails**: `ld64-956.6` needs macOS
  SDK headers the cross sandbox lacks (`fatal error: libkern/OSByteOrder.h` /
  `mach/vm_prot.h`), and cross-built darwin tools are **not** on cache.nixos.org.
  So this is *not* the free/lowest-risk win I first called it. Two real paths:
  - **A.** Provide SDK headers to the nixpkgs `ld64` build (an overlay adding
    `apple-sdk` / Darling's own `libkern`+`mach` headers to its `buildInputs`),
    then use its `x86_64-apple-darwin-ld` in `use_ld64.cmake` via `-fuse-ld=`.
  - **B (pragmatic).** Keep Darling's `cctools-port` sources (they build on Linux
    because Darling supplies the darwin headers) but build it as a *standalone nix
    derivation* instead of an in-tree cmake subtree -- cached + incremental, and
    `use_ld64.cmake` points `-fuse-ld` at that store path. De-vendors the build
    without depending on nixpkgs' broken cross-ld64. Likely the better first step.

  **Path B IMPLEMENTED.** `nix/cctools-port.nix` + `packages.darling-ld64` build
  Darling's `x86_64-apple-darwin20-ld` (+ `lipo`) standalone off the off-submodules
  `darling-src` -- verified a working classic ld64 (`PROJECT:ld64`). `use_ld64.cmake`
  now reads `-DDARLING_LD64_DIR` (default: in-tree; override: the darling-ld64 store
  `bin/`), and skips the in-tree ld64 build/dependency when external. Two sandbox
  fixes were needed for the stdenv build the nix-ninja path hides: mig's `/bin/mkdir`
  -> absolute coreutils path (a bare `mkdir` binds to Darling's own `mkdir` target
  and cycles `emulation->mkdir->libSystem`), and `/bin/rmdir` -> PATH. TODO: fold in
  `install_name_tool`/`nmedit` (their cmake target names differ from the install
  path), and validate an actual darwin dylib link with `-DDARLING_LD64_DIR` set.
- `TextEdit` -- Apple demo app; no substitute, low value.

## Recommended sequencing

1. **cctools/ld64 (build tooling)** -- no runtime gate; try nixpkgs' cctools for
   the Mach-O link step first.
2. As the symbol gap (task #10) closes, de-vendor **leaf runtime libs** in
   dependency order, each proven to dyld-load under Darling: start with the
   self-contained ones (`zlib bzip2 xz libffi pcre expat sqlite`), then the
   larger (`openssl/libressl curl icu libxml2`). Keep the off-submodules
   `fetchFromGitHub` pin as the fallback for anything not yet substituted.
3. Leave categories 2 and most of 3 vendored -- they have no equivalent.
