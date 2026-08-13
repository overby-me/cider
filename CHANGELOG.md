# Changelog

Cider is a fork of [Darling](https://github.com/darlinghq/darling). Entries here start at the
fork; Darling's own history is in the git log.

## Unreleased

The first release has not been made. [docs/release-readiness.md](docs/release-readiness.md) lists
what stands in the way, measured rather than estimated.

### Build system

- **Buck2 is the only build.** cmake and nix-ninja are gone. A Nix endpoint lowers the Buck2
  action graph into one derivation per target, so a build is incremental across Nix.
- The build no longer depends on the whole project source: a first-party edit rebuilds two
  derivations rather than everything.
- ld64, the Mach-O linker, is built by Buck2 rather than taken from elsewhere.

### Rewritten in Rust

- The daemon. The C++ `darlingserver` is deleted; `ciderd` replaces it.
- The Mach-O loader (`mldr`) and the launcher.
- duct-tape, the kernel-emulation glue: 16 files, 8,525 lines. The copied XNU subset stays C.
- The host tools `getuuid`, `elfdep` and `wrapgen`, each gated on byte-identical output
  against the C it replaced.
- The guest tools `xcrun` and `PlistBuddy`, gated the same way but inside the container.

### Guest Rust

- The build can produce Mach-O Rust binaries on Linux, using a pinned upstream rustc and the
  official macOS standard library. Two shipped tools are built this way.

### Renamed

- Darling became Cider. Copyright headers and upstream attribution are unchanged.

### Known issues

- The container fails to start roughly once in sixty attempts.
- `cider` is the command. The package renames the raw launcher to `bin/cider-launcher` and puts a small script at `bin/cider` that supplies the two paths a moved prefix cannot bake in.
- Most GUI applications do not run.
