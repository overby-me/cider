# Upstream Darling: what this fork is based on, and where everything went

This project is a **fork of [darlinghq/darling](https://github.com/darlinghq/darling)**, not a
reimplementation. Its purpose is to record exactly which upstream commit it diverged from and
how the directory layout was rearranged, so upstream changes can be located, judged and
applied rather than guessed at.

Everything below was derived from the repository, not from memory. The commands that produced
each number are given so they can be re-run when they go stale.

## The fork point

| | |
|---|---|
| upstream remote | `up` -> `https://github.com/darlinghq/darling` |
| **fork point (merge base)** | **`f39a29489fc630cb9b46af7ae2df1a3b603725d3`** |
| fork point date | 2026-03-08 |
| fork point subject | *Merge pull request #1702 from sirnacnud/skanalysis-symbols* |
| upstream tip last fetched | `e947f0d5a3c6`, 2026-06-08, *Merge pull request #1758 from darlinghq/fedora_44_fix* |

As of 2026-08-05:

- **36 upstream commits are not in this fork** (2026-03-11 .. 2026-06-08)
- **619 commits here are not upstream**

Recompute after a fetch:

```bash
jj git fetch --remote up
jj log -r 'heads(::@ & ::master@up)'          # the fork point
jj log -r '::master@up ~ ::@'                 # upstream commits we lack
jj log -r '::@ ~ ::master@up'                 # our commits
```

## Upstream changes arrive in TWO places

This is the thing to internalise before trying to pull anything across.

1. **The superproject** (`darlinghq/darling`) -- build glue, `src/**` first-party code, the
   SDK tree, headers. That is what the 36 commits above are.
2. **147 separate submodule repositories** (`darlinghq/darling-libdispatch`,
   `cider-libc`, ...), each pinned by revision in **`nix/submodules.json`**:

   ```json
   { "path": "vendor/pins/libdispatch", "owner": "darlinghq",
     "repo": "cider-libdispatch", "rev": "380f03c1...", "hash": "sha256-..." }
   ```

   Upstream advances these with "Update Submodules" commits (e.g. `7276777e`). Those commits
   change *pointers*, so applying one here means **bumping `rev` and `hash` in
   `nix/submodules.json`**, not merging a diff. The 147 pinned `vendor/pins/<pin>`
   directories are **empty mount points** in this tree; content is fetched by
   `nix/lib/cider-src.nix` and materialised into `vendor/src/<pin>` at build time.

   **But `vendor/pins/` is not only pins.** Three trees there are vendored first-party
   content, tracked in this repo and NOT in `nix/submodules.json`, so they take patches
   directly:

   | path | files | note |
   |---|---|---|
   | `vendor/pins/ciderd/xnu-sys/` | 2,164 | the XNU shim, still built (`ciderd_xnu_sys`) |
   | `vendor/pins/libpthread_workqueue-0.8.2/` | 40 | vendored |
   | `vendor/pins/libtrace/` | 28 | vendored, see its `VENDORED.md` |

## Directory mapping

### Moved wholesale into `src/darwin/` (guest-side)

| upstream | here | files |
|---|---|---|
| `basic-headers/` | `src/darwin/basic-headers/` | 10 |
| `Developer/` | `src/darwin/Developer/` | 2,818 |
| `framework-include/` | `src/darwin/framework-include/` | 141 |
| `framework-private-include/` | `src/darwin/framework-private-include/` | 59 |
| `src/frameworks/` | `src/darwin/frameworks/` | 17,462 -> 17,464 |
| `src/private-frameworks/` | `src/darwin/private-frameworks/` | 4,850 -> 4,851 |

The framework trees moved essentially file-for-file (the small surplus is added `BUCK`
files), so an upstream diff there needs only its paths rewritten.

### Unchanged paths

`src/**` (everything not listed above), `tests/`, `cmake/`, `CMakeLists.txt`, `etc/`,
`misc/`, `LICENSE`, `CONTRIBUTORS.md`, `.gdbinit`. **A patch touching these usually applies
directly.**

### Rewritten in Rust -- a patch will NOT apply

| upstream | here | note |
|---|---|---|
| `src/linux/startup/mldr/` | `src/darwin/loader/` | the Mach-O loader, rewritten (`mldr-rs`) |
| `src/linux/startup/cider.c` | `src/linux/launcher/` | the `cider` binary, rewritten |
| `vendor/pins/ciderd` (was a submodule) | `src/linux/server/` | the DAEMON rewritten in Rust; no longer a submodule. Its `xnu-sys/` (2,164 files) stays in `vendor/pins/ciderd/` and is still built unchanged |

An upstream fix to any of these must be **re-implemented**, not cherry-picked. Read the
upstream change for its *intent* and apply that intent to the Rust.

### Present upstream, absent here

- `src/configd/` -- dead vendored copy, deleted deliberately
- `ci/`, `debian/`, `rpm/`, `.github/` -- upstream packaging and CI, not carried

### Here only (no upstream counterpart)

- `src/darwin/dirserv/`, `src/darwin/sandbox-exec/` -- first-party additions
- `buck/`, `vendor/src/`, `vendor/rust/` -- the buck2 build (the point of this fork)
- `nix/`, `flake.nix`, `flake.lock` -- the Nix endpoints
- `scripts/`, `docs/`, `plan/`, `changelog.md`, `templates/`, `tools/`, `patches/`

## Applying an upstream change

1. `jj git fetch --remote up`, then list what is new:
   `jj log -r '::master@up ~ ::@'`
2. Decide whether it lands in a **moved**, **unchanged**, or **rewritten** area using the
   tables above. Rewritten means re-implement; moved means rewrite the paths in the diff.
3. **The build is not upstream's.** Upstream is cmake; here cmake still exists but the live
   build is buck2. A change that adds a source file, a define or a link flag must be mirrored
   into the relevant `BUCK` file, or it silently will not take effect. `buck/prefix/BUCK` and
   `buck/generated/` are GENERATED -- regenerate rather than edit
   (`cider-install-from-manifests`).
4. Verify with the port's own checks rather than by inspection: `scripts/buck-test.nu`,
   `scripts/checks/buck-bash-check.nu`, and for anything on the guest path
   `scripts/checks/buck-runtime-check.nu`.

## Triage of the 36 commits behind (2026-08-05)

Done once, so it need not be redone from scratch:

| group | n | verdict |
|---|---|---|
| Fedora 44 build fixes | 5 | **all already present** -- the fork converged independently, because clang 21 under Nix surfaces the same strictness Fedora 44's toolchain does (libaks `int*`, OpenDirectory Foundation import, ImageIO, DiskArbitration, SecurityFoundation) |
| `dnsinfo.h` symlink (`27dd667e`) | 1 | **was genuinely missing -- applied**, see the fix for #59 |
| submodule bumps | 5 | **the real remaining work**: bump `rev`/`hash` in `nix/submodules.json`, selectively |
| configd removal / SystemConfiguration | 4 | already converged; we deleted vendored configd and pin `vendor/pins/configd` |
| **`3d9752422d5e` "Add symbol for rustls crate"** | 1 | **MISSING and goal-relevant** -- it is not a symbol list, it adds `SCDynamicStore.c` defining `SCDynamicStoreCreateWithOptions` and `kSCDynamicStoreUseSessionKeys`, which the rustls crate resolves. Neither exists here |
| stub frameworks, symbol lists, `.github` | ~14 | parity only, or not carried here: WebKit (Bibdesk), InstantMessage and AddressBook Xcode symbols, SDK stub headers for PubSub/QuickTime/Message |

So **two** of 36 carried a change this fork needed.

**Do not triage by commit subject.** "Add symbol for rustls crate" reads like the other symbol
commits and is not: it adds a real source file for a Rust TLS dependency. Read what each
commit *touches* before grouping it.

**How to check "is this one already here" without being fooled**: diff our file against
upstream's file *after* the commit --
`jj file show -r <commit> <upstream/path> > /tmp/a && diff /tmp/a <our/path>`.
Grepping for an added line out of the diff is fragile to whitespace and to which line you
pick, and it produced one false "missing" during this triage.

## What "up to date with upstream" means here

Build parity is measured against the **reference cmake build at the fork point**: 151 of 151
link edges. That number says nothing about the 36 upstream commits since. See changelog.md, *What
100 percent does NOT mean*, for the standing exclusions (32-bit, cctools from Nix, runtime
parity unmeasured past dlopen).
