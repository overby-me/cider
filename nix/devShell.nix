# Development shell for working on Darling.
#
# Provides all build dependencies, debugging tools, and editor
# integration (clangd, nil, nixfmt) so that `nix develop` or
# direnv gives a fully-equipped environment.
pkgs: let
  # Every locked third-party crate, unpacked. Shared with the Nix endpoint's graph
  # derivation, so both see the same crate sources.
  rustVendor = import ./lib/rust-vendor.nix {inherit pkgs;};
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
    # The port's scripting is moving from bash to nushell (task #40), so the checks now run
    # .nu files. DECLARED here rather than inherited: nu happens to be on this machine's PATH
    # from the user profile, so a missing entry would not fail here and would fail for
    # everyone else, which is the worst way for a dependency to be wrong.
    nushell
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
    # bindgen as a TOOL rather than a build dependency. The daemon's build.rs runs it to
    # generate the dtape hooks bindings; building bindgen itself from source would drag
    # about thirty crates and a clang-sys probe through the graph to produce a generator,
    # so the port consumes it the way it already consumes clang and ld64.
    rust-bindgen

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
