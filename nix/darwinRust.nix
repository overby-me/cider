# THE GUEST RUST TOOLCHAIN (#102): a rustc that can build Mach-O, pinned instead of unpacked
# in /tmp by hand.
#
# WHY THIS IS NOT JUST `pkgs.rustc`. nixpkgs cannot cross-compile to darwin FROM linux, and the
# refusal is not about Rust. Asking the pinned nixpkgs for it dies at
#
#   Refusing to evaluate package 'x86_64-apple-darwin-cctools-1010.6' ...
#     hostPlatform.system = "x86_64-linux"
#
# because a darwin cross toolchain needs Apple SDK pieces that cannot be redistributed to
# non-Apple hosts. Rust's OWN prebuilt standard library for darwin is freely downloadable
# though, which is the way in: this fetches it from static.rust-lang.org, the same artifact
# `rustup target add x86_64-apple-darwin` installs.
#
# BOTH HALVES COME FROM THE SAME RELEASE, and that is load bearing rather than tidiness. Crate
# metadata matching is a STRING COMPARE, and the nixpkgs rustc appends a suffix to an otherwise
# identical version, so it cannot read the official std. Re-measured 2026-08-12, both at
# 1.95.0 commit 59807616e:
#
#   error[E0514]: found crate `std` compiled by an incompatible version of rustc
#     found: rustc 1.95.0 (59807616e 2026-04-14)
#     ours:  rustc 1.95.0 (59807616e 2026-04-14) (built from a source tarball)
#
# So the official rustc is pinned too. That is the whole reason for the larger download.
#
# ONLY TWO TARBALLS, MEASURED. The host standard library is NOT needed: compiling
# --crate-type staticlib --target x86_64-apple-darwin against a sysroot holding the darwin
# target and NOTHING else produces the same 17,694,176 byte archive. A third tarball would be
# 40 MB of nothing.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  zlib,
}:

let
  version = "1.95.0";
  target = "x86_64-apple-darwin";
  host = "x86_64-unknown-linux-gnu";
in
stdenv.mkDerivation {
  pname = "cider-darwin-rust";
  inherit version;

  srcs = [
    (fetchurl {
      url = "https://static.rust-lang.org/dist/rustc-${version}-${host}.tar.xz";
      hash = "sha256-hCaj0XClh59WgvX73QJKF3mzlR57q6aFry1twypt/BU=";
    })
    (fetchurl {
      url = "https://static.rust-lang.org/dist/rust-std-${version}-${target}.tar.xz";
      hash = "sha256-K+E8FBIrjU0Jt/fENPyprnIV7HIEmUQYnIjE2RKM5QQ=";
    })
  ];
  sourceRoot = ".";

  # The official binaries are built for a normal FHS distribution, so they ask for
  # /lib64/ld-linux-x86-64.so.2, which does not exist here.
  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [
    zlib
    stdenv.cc.cc.lib
  ];

  # THE OUTPUT IS ITSELF A SYSROOT, which is why nothing needs a merge step or a symlink farm:
  # rustc resolves its own sysroot relative to its binary, so bin/rustc plus
  # lib/rustlib/<target> is a complete installation with the darwin target added. The buck2
  # rule still passes --sysroot explicitly, because being implicit here would make a broken
  # layout look like a compiler bug.
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -a rustc-${version}-${host}/rustc/. $out/
    cp -a rust-std-${version}-${target}/rust-std-${target}/lib/rustlib/${target} $out/lib/rustlib/
    runHook postInstall
  '';

  # The darwin half is Mach-O and the rlibs are ar archives. Stripping them with host binutils
  # would be, at best, a no-op that rewrites a pinned artifact.
  dontStrip = true;

  meta = {
    description = "Official rustc plus the official ${target} standard library, for building guest Mach-O binaries on Linux";
    homepage = "https://static.rust-lang.org/dist/";
    license = with lib.licenses; [
      mit
      asl20
    ];
    platforms = [ "x86_64-linux" ];
  };
}
