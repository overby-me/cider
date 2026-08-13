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
    # Buck2 for the gradual port (plan/buck2-port.md). Same binary the Nix
    # endpoint would use, so the toolchain is pinned from day 1 even while we
    # iterate outside a derivation. watchman is buck2's file watcher here: the
    # default `notify` backend cannot start in this tree (it walks the result-*
    # store symlinks) and fs_hash_crawler re-hashes vendor/src on every command.
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

    # DECLARED HERE SO scripts/buck-setup.nu CAN REGENERATE WITHOUT THEM BEING LOST.
    # All four were hand written into .buckconfig.local, a file whose first line says
    # GENERATED, so regenerating it on 2026-08-10 silently dropped every one and
    # //src/darwin/frameworks:fseventsd_obj stopped compiling with
    # "src/linux/fanotify.h: 'src/linux/types.h' file not found". buck-setup.nu harvests the dev
    # shell's own -isystem list, so declaring them here is what puts them back and keeps
    # them there. pkg-config alone is not enough: it knows nothing about xdmcp, which is
    # why the script warns about that one by name.
    expat
    # libxdmcp, NOT xorg.libXdmcp: the xorg set is deprecated and evaluating the old path
    # prints a warning on every nix command in this tree.
    libxdmcp
    linuxHeaders
    systemdLibs

    # ── Rust, for the buck2 port of the daemon, launcher and loader ──
    # rustc only: buck2 invokes it directly and the crate sources come from
    # rustVendor above, so there is nothing for cargo to do in the build graph.
    rustc
    # bindgen as a TOOL rather than a build dependency. The daemon's build.rs runs it to
    # generate the xnu_sys hooks bindings; building bindgen itself from source would drag
    # about thirty crates and a clang-sys probe through the graph to produce a generator,
    # so the port consumes it the way it already consumes clang and ld64.
    rust-bindgen

    # ── The port's own nix-built tools ──────────────────────────
    # cider-src-normalise, which scripts/buck-src.nu invokes once per pin. DECLARED HERE for
    # the same reason nushell is: since #99 it is a binary rather than a script in the tree,
    # so nothing would find it by path, and the local vendor/src would silently keep the
    # symlinks buck2 refuses to load.
    #
    # src = ../. copies ONLY src/linux/buildtools/src-normalise into the store, because the
    # derivation appends that subpath, so an edit anywhere else in the project does not
    # rebuild the dev shell.
    (pkgs.callPackage ./src-normalise.nix { src = ../.; })

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

  # THE SAME hardeningDisable THE TWO LOWERING DERIVATIONS ALREADY SET, and it has to be
  # here too or buck2 compiles differently depending on who launched it. nixpkgs' cc
  # wrapper appends -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 AFTER the argv, so the
  # -D_FORTIFY_SOURCE=0 the port passes is overridden, and libc's secure/_stdio.h then
  # rewrites the DEFINITION of snprintf into __builtin___snprintf_chk and fails to parse.
  # Measured 2026-08-10: with the wrapper's default NIX_HARDENING_ENABLE, clang -dM -E
  # reports _FORTIFY_SOURCE 2 even when -D_FORTIFY_SOURCE=0 is on the command line,
  # //vendor/src/libc:libc-stdio_obj does not compile, and 227 of the 659 dylib targets
  # produce no output at all. The Nix endpoint stayed green throughout because its
  # derivations disable hardening, which is exactly how the gap hid.
  hardeningDisable = ["all"];

  env = {
    # Make cmake produce compile_commands.json so clangd works.
    CMAKE_EXPORT_COMPILE_COMMANDS = "1";
    # Where scripts/buck-rust-vendor.nu materializes the crate sources from.
    CIDER_RUST_VENDOR = "${rustVendor}";
    # Compat: dropped when the DARLING_ fallbacks go.
    DARLING_RUST_VENDOR = "${rustVendor}";
  };

  shellHook = ''
    echo "🍎 cider-nix devShell loaded"
    echo "   clang: $(clang --version | head -1)"
    echo ""
    echo "Quick start:"
    echo "  nix build .#cider-buck2-prefix-min --max-jobs 6 --cores 2"
    echo "  buck2 build //..."
  '';
}
