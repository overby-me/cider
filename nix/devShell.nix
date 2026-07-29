# Development shell for working on Darling.
#
# Provides all build dependencies, debugging tools, and editor
# integration (clangd, nil, nixfmt) so that `nix develop` or
# direnv gives a fully-equipped environment.
pkgs: {
  stdenv = pkgs.clangStdenv;

  packages = with pkgs; [
    # ── Build dependencies ──────────────────────────────────────
    cmake
    ninja
    # Buck2 for the gradual port (plan/buck2-port.md). Same binary the Nix
    # endpoint would use, so the toolchain is pinned from day 1 even while we
    # iterate outside a derivation.
    buck2
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
