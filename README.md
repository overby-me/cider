<img src="docs/cider.svg" alt="" width="88" align="right">

# Cider

**Cider Isn't Darwin Emulation, Really.**

Cider is a runtime environment for macOS applications on Linux. It runs Mach-O binaries directly
on the Linux kernel through its own dyld, libSystem and kernel-emulation layer. There is no
virtual machine and no Apple kernel.

Cider is a fork of [Darling](https://github.com/darlinghq/darling) and is licensed under the
GPL, version 3 or later. See [LICENSE](LICENSE).

## Status

**Early. Command line software works; most GUI applications do not.**

What follows is what an automated check in this repository actually exercises, not a wish list.
Each one boots a container and runs a real program:

| Works | Checked by |
|---|---|
| A shell: `cider shell` and bash inside it | `scripts/checks/buck-bash-check.nu` |
| Booting through launchd | `scripts/checks/buck-launchd-check.nu` |
| Nix, running inside the container | `scripts/checks/buck-nix-bash-check.nu` |
| JavaScriptCore running a script | `scripts/checks/buck-jsc-check.nu` |
| libdispatch, Security, CoreAudio, scripting bridges | `buck-{dispatch,security,audio,scripting}-check.nu` |
| A trivial AppKit window under X11 | `scripts/checks/buck-appkit-check.nu` |

Anything not in that table is unverified here. In particular Cider has **not** been shown to
install `.pkg` files, mount Xcode disk images, or run Xcode or its toolchain. Darling documents
those; this fork does not currently test them, so it does not claim them.

## Build

Cider builds with [Nix](https://nixos.org) and [Buck2](https://buck2.build). Nix is the only
supported packaging: there is no distribution package, and no tarball.

```
nix build .#cider
```

That is the full build and it is large. On a machine that cannot finish it, the minimal build
drops the GUI frameworks, the private frameworks and the scripting languages, which is about 42
percent of the work, and still boots, runs a shell and runs Nix:

```
nix build .#cider-min
```

Everything else in `flake.nix` is internal: the graph, the lowering, the prefixes and the
`cider-buck2-*` attributes are stages of the build rather than things to install.

## Install and run

On NixOS, through the module:

```nix
{
  inputs.cider.url = "git+https://tangled.org/overby.me/cider";
  # ...
  programs.cider.enable = true;
}
```

Otherwise install the package and use the entry point it provides:

```
nix profile install .#cider
cider shell echo Hello world
```

## Prefixes

Cider has CIDERPREFIXes, which are close to WINEPREFIXes: virtual chroot-like environments with a
macOS-shaped filesystem, where software can be installed safely. The default is `~/.cider`,
changed by exporting `CIDERPREFIX`. A prefix is created and initialized on first use.

Prefixes use `overlayfs`, so a prefix cannot live on NFS or eCryptfs. The default location will
not work with an encrypted home directory.

## Known issues

**The container sometimes fails to start.** Measured at roughly one start in sixty, with two
signatures: a `SIGFPE` at startup, and

```
[mldr] start-stack mmap at 0x7fffff600000 failed
```

Both kill the process before the program inside it runs. Re-running usually succeeds. The cause
is not yet known.

**A full build can be very large.** Use `.#cider-min` on a constrained machine.

## Development

Where things live:

```
src/darwin/     the guest side: frameworks, dylibs and tools that run INSIDE the container
src/linux/      the host side: the ciderd daemon, the launcher, the Mach-O loader, build tools
buck/       our Buck2 rules, toolchains and the prefix definition
vendor/     everything that is not ours, in three parts:
              src/   upstream C sources, materialized from pins rather than committed
              rust/  vendored Rust crates, materialized the same way
              pins/  upstream components committed on purpose, each with VENDORED.md
nix/        the Nix side: the flake library, the graph and lowering, the NixOS module
scripts/    the developer loop, in nushell, split three ways:
              checks/  41 checks, the ones buck-test.nu and buck-runtime-check.nu run
              gen/     3 generators
              build/   5 build drivers
            the 42 that stay flat are tools, plus the 8 shell scripts that have to be bash
```

`vendor/src/` and `vendor/rust/` hold about 260,000 and 3,000 files respectively and are almost
entirely gitignored; only their generated `BUCK` files are committed. Only 4 of the 148 pins are
materialized on a working checkout: `scripts/buck-src.nu` fetches what the port currently needs,
not the whole 3.8 GB.

### Building without Nix, which is how you should iterate

**Nix is the packaging, not the build.** The build is Buck2, and you can drive it directly. A
Nix-built prefix takes an hour; a Buck2 rebuild after editing one file takes seconds, and this is
the loop to use while working.

```
nix develop                 # the toolchain only: clang, rustc, buck2, nushell
scripts/buck-setup.nu       # writes .buckconfig.local with the store paths of those tools
buck2 build //...           # or a single target, which is the point
```

`scripts/buck-setup.nu` is what connects the two: it resolves the compiler, the guest toolchain,
the host library directories that `wrapgen` dlopens, and the guest Rust toolchain, and writes
them into a machine-local `.buckconfig.local` that is gitignored. Rerun it after a nixpkgs bump
moves any of those store paths.

You still need Nix to GET the toolchain, and to produce an installable package. You do not need
it to compile, link, or run the checks.

Run the checks with:

```
scripts/buck-test.nu
```

[docs/changelog.md](docs/changelog.md) is the working record: what is being done, what was measured, and what was
tried and rejected. [docs/release-readiness.md](docs/release-readiness.md) is what stands between
this and a first release.
