# Development shell for working on Darling.
#
# Provides all build dependencies, debugging tools, and editor
# integration (clangd, nil, nixfmt) so that `nix develop` or
# direnv gives a fully-equipped environment.
pkgs: let
  # Every third-party crate the three Rust crates lock, unpacked into one directory.
  #
  # The buck2 port drives rustc directly, with no cargo anywhere in the build graph, so a
  # rule cannot fetch a dependency: the sources have to be on disk before the build starts,
  # exactly like the pinned upstream trees under buck-src. importCargoLock takes one lock
  # file, so the three are merged crate by crate rather than with symlinkJoin, which would
  # collide on the Cargo.lock each of them ships.
  rustVendor = pkgs.runCommand "darling-rust-vendor" { } ''
    mkdir -p $out
    for d in ${pkgs.rustPlatform.importCargoLock { lockFile = ../linux/server/Cargo.lock; }} \
             ${pkgs.rustPlatform.importCargoLock { lockFile = ../linux/launcher/Cargo.lock; }} \
             ${pkgs.rustPlatform.importCargoLock { lockFile = ../darwin/loader/Cargo.lock; }}; do
      for c in "$d"/*/; do
        ln -sfn "$c" "$out/$(basename "$c")"
      done
    done
  '';
in {
  stdenv = pkgs.clangStdenv;

  packages = with pkgs; [
    # ── Build dependencies ──────────────────────────────────────
    cmake
    ninja
    # Buck2 for the gradual port (plan/buck2-port.md). Same binary the Nix
    # endpoint would use, so the toolchain is pinned from day 1 even while we
    # iterate outside a derivation. watchman is buck2's file watcher here: the
    # default `notify` backend cannot start in this tree (it walks the result-*
    # store symlinks) and fs_hash_crawler re-hashes buck-src on every command.
    buck2
    watchman
    pkg-config
    bison
    flex
    python3
    makeWrapper

    # ── Libraries (needed by cmake at configure time) ──────────
    freetype
    libjpeg
    libpng
    libtiff
    giflib
    libX11
    libXext
    libXrandr
    libXcursor
    libxkbfile
    cairo
    libglvnd
    fontconfig
    dbus
    libGLU
    fuse
    ffmpeg
    pulseaudio
    libbsd
    openssl
    xdg-user-dirs

    # ── Rust, for the buck2 port of the daemon, launcher and loader ──
    # rustc only: buck2 invokes it directly and the crate sources come from
    # rustVendor above, so there is nothing for cargo to do in the build graph.
    rustc

    # ── Debugging & analysis ────────────────────────────────────
    gdb
    strace
    rizin
    file

    # ── Code exploration ────────────────────────────────────────
    ripgrep
    fd
    jq

    # ── Nix tooling (for Zed / editor integration) ─────────────
    nil
    nixfmt

    # ── C/C++ tooling (for Zed / clangd) ───────────────────────
    clang-tools
  ];

  env = {
    # Make cmake produce compile_commands.json so clangd works.
    CMAKE_EXPORT_COMPILE_COMMANDS = "1";
    # Where scripts/buck-rust-vendor.sh materializes the crate sources from.
    DARLING_RUST_VENDOR = "${rustVendor}";
  };

  shellHook = ''
    echo "🍎 darling-nix devShell loaded"
    echo "   clang: $(clang --version | head -1)"
    echo "   cmake: $(cmake --version | head -1)"
    echo ""
    echo "Quick start:"
    echo "  mkdir -p build && cd build"
    echo "  cmake -G Ninja .."
    echo "  ninja -j\$(nproc)"
  '';
}
