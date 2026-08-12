# Every third-party crate the three Rust crates lock, unpacked into one directory.
#
# The buck2 port drives rustc directly, with no cargo anywhere in the build graph, so a rule
# cannot fetch a dependency: the sources have to be on disk before the build starts, exactly
# like the pinned upstream trees under vendor/src. importCargoLock takes one lock file, so the
# three are merged crate by crate rather than with symlinkJoin, which would collide on the
# Cargo.lock each of them ships.
#
# Shared by nix/devShell.nix (which exports it as DARLING_RUST_VENDOR for
# scripts/buck-rust-vendor.nu) and nix/lib/ciderBuck2Graph.nix (which materializes it into
# vendor/rust/ inside the derivation). One definition, because a graph dumped against a
# different set of crate sources than the daemon uses is a graph of a different build.
{pkgs}:
pkgs.runCommand "cider-rust-vendor" {} ''
  mkdir -p $out
  for d in ${pkgs.rustPlatform.importCargoLock {lockFile = ../../linux/server/Cargo.lock;}} \
           ${pkgs.rustPlatform.importCargoLock {lockFile = ../../linux/launcher/Cargo.lock;}} \
           ${pkgs.rustPlatform.importCargoLock {lockFile = ../../darwin/loader/Cargo.lock;}}; do
    for c in "$d"/*/; do
      ln -sfn "$c" "$out/$(basename "$c")"
    done
  done
''
