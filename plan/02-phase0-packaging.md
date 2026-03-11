# Phase 0 — Nix Packaging + DevShell

**Priority**: P0 · **Effort**: S (1–2 weeks) · **Depends on**: Nothing

This is the foundation phase. Before any Darling hacking begins, we need a
reproducible build, a developer shell with all required tools, and editor
integration so that contributors (human and AI) can be productive immediately.

---

## Tasks

### 0.1 — Add `flake.nix`

Create a `flake.nix` at the repo root that exposes:

- `packages.x86_64-linux.darling` — the main Darling binary + prefix
- `packages.x86_64-linux.darling-sdk` — macOS SDK + cctools (`ld64`, `ar`,
  `ranlib`) for cross-compilation

Use the [nixie-dev/darling-nix](https://github.com/nixie-dev/darling-nix)
packaging as a reference. Their `packages/darling/default.nix` demonstrates:

- Building with `clangStdenv`
- A `ccWrapperBypass` that detects `-target *darwin*` and calls the unwrapped
  compiler to avoid `cc-wrapper` interfering with Darwin cross-compilation
- Splitting the SDK into a separate output
- Post-fixup checks that ensure no `/nix/store` paths leak into the Darling
  root (which would break the prefix overlay)

Key decisions:

- Pin `nixpkgs` input to a recent stable release.
- Use `fetchFromGitHub` with `fetchSubmodules = true` to get all submodules
  (there are 100+ in `.gitmodules`).
- Strip large test directories from the source to stay under Hydra output limits
  (see the `postFetch` in the reference packaging).

### 0.2 — Add NixOS Module

Create `nixosModules.darling` that:

- Ensures the Darling binary is installed.
- Configures darlingserver's userspace-only mode (no kernel module required on
  modern kernels with `overlayfs` + user namespaces).
- Sets up `/etc/darling` configuration if needed.
- Optionally provides a `darling-prefix.service` systemd unit for persistent
  prefixes.

### 0.3 — Set Up Binary Cache

- Create a [Cachix](https://cachix.org/) cache (or equivalent) for CI-built
  artifacts.
- Add `nixConfig.extra-substituters` and `nixConfig.extra-trusted-public-keys`
  to `flake.nix` so users automatically use the cache.
- Document the cache setup in the repo README.

### 0.4 — Pin Submodules

The `darlingserver` submodule (at `src/external/darlingserver/`) is empty in a
shallow checkout. Ensure the flake's `fetchFromGitHub` with
`fetchSubmodules = true` captures it, so the build is fully reproducible from
a single source fetch.

Verify all 100+ submodules listed in `.gitmodules` are resolved. If any fail,
pin their commits explicitly.

### 0.5 — Add `devShell`

Add `devShells.x86_64-linux.default` to the flake. This shell must provide
every tool needed to build Darling, debug issues, and work comfortably in Zed.

**Build dependencies** (same as `nativeBuildInputs` for the Darling package):

- `clang` / `clangStdenv.cc`
- `cmake`
- `ninja`
- `pkg-config`
- `bison`
- `flex`
- `python3`
- `makeWrapper`

**Runtime & library dependencies** (same as `buildInputs`):

- `freetype`, `libjpeg`, `libpng`, `libtiff`, `giflib`
- `libX11`, `libXext`, `libXrandr`, `libXcursor`, `libxkbfile`
- `cairo`, `libglvnd`, `fontconfig`, `dbus`, `libGLU`
- `fuse`, `ffmpeg`, `pulseaudio`
- `libbsd`, `openssl`
- Linux headers (`stdenv.cc.libc.linuxHeaders`)

**Debugging & analysis tools**:

- `gdb` — for debugging crashes inside Darling / darlingserver
- `strace` — for tracing Linux syscalls made by darlingserver
- `rizin` — for binary analysis / patching (used in the blog post to patch
  `libnixstore.dylib`)
- `file` — for identifying binary types (Mach-O vs ELF)

**Code exploration**:

- `ripgrep` — fast grep across the large codebase
- `fd` — fast find
- `jq` — JSON processing (useful for Nix evaluation debugging)

**Nix tooling** (critical for Zed integration):

- `nil` or `nixd` — Nix language server, so Zed provides completions,
  diagnostics, and go-to-definition for `.nix` files
- `nixfmt-rfc-style` — Nix formatter

**C/C++ tooling** (critical for Zed integration):

- `clang-tools` — provides `clangd` for C/C++ language server support in Zed
- `bear` or `cmake`'s `CMAKE_EXPORT_COMPILE_COMMANDS` — for generating
  `compile_commands.json` so `clangd` understands the build

**Example structure**:

```nix
devShells.x86_64-linux.default = pkgs.mkShell.override { stdenv = pkgs.clangStdenv; } {
  packages = with pkgs; [
    # Build
    cmake ninja pkg-config bison flex python3 makeWrapper

    # Libraries (for cmake to find)
    freetype libjpeg libpng libtiff giflib
    libX11 libXext libXrandr libXcursor libxkbfile
    cairo libglvnd fontconfig dbus libGLU
    fuse ffmpeg pulseaudio
    libbsd openssl

    # Debug
    gdb strace rizin file

    # Code exploration
    ripgrep fd jq

    # Nix tooling (for Zed)
    nil nixfmt-rfc-style

    # C/C++ tooling (for Zed)
    clang-tools
  ];

  CMAKE_EXPORT_COMPILE_COMMANDS = "1";
};
```

### 0.6 — Add `.envrc`

Create a `.envrc` at the repo root:

```bash
use flake
```

This single line is all that's needed. When `direnv` is installed (which it
should be on any NixOS or nix-with-direnv setup), entering the project directory
will:

1. Evaluate the flake's `devShell`.
2. Export all environment variables (paths to tools, library paths, etc.).
3. Make tools available to the shell **and** to Zed (which reads direnv state).

**Why this matters for Zed**: Zed discovers language servers, formatters, and
other tools through the environment. Without `.envrc` + direnv, Zed won't find
`clangd`, `nil`, or `nixfmt` — meaning no LSP support, no inline errors, and
no formatting. With it, everything works automatically the moment you open the
project.

Add `.envrc` to `.gitignore` exclusions (make sure it's NOT ignored) and add
`.direnv/` to `.gitignore` (the cache directory should be ignored).

---

## Verification Checklist

After completing Phase 0, the following should all work:

- [ ] `nix build .#darling` produces a working Darling installation
- [ ] `nix build .#darling-sdk` produces the SDK with `ld64`, `ar`, `ranlib`
- [ ] `nix develop` drops into a shell with `cmake`, `clang`, `gdb`, `nil`, etc.
- [ ] `cd`-ing into the repo with direnv enabled loads the devShell automatically
- [ ] Opening the repo in Zed shows Nix LSP working (completions in `.nix` files)
- [ ] Opening a `.c` file in Zed shows `clangd` providing diagnostics
- [ ] `darling shell echo Hello` works from the built package
- [ ] `nix flake check` passes

---

## Notes

- The devShell is intentionally **large**. This is a complex C/C++/Objective-C
  project with 100+ submodules, and developers need the full toolkit available
  without hunting for dependencies.
- `CMAKE_EXPORT_COMPILE_COMMANDS=1` is set in the devShell so that any cmake
  configure run produces `compile_commands.json`, which `clangd` needs.
  Alternatively, contributors can run `bear -- cmake --build build/` to
  generate it.
- The `.envrc` should be committed to the repo (not gitignored) so every
  contributor gets the same experience. Only `.direnv/` (the cache) is ignored.

---

*[← Known Blockers](./01-blockers.md) | [Phase 1 — Syscall Fixes →](./03-phase1-syscalls.md)*