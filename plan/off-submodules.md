# Off git submodules: nix-pinned Darling sources

Goal (task #23): stop materialising Darling's 147 vendored trees with
`git submodule update` / a dirty `nix build .?submodules=1`, and instead pin each
as a content-addressed `fetchFromGitHub` in nix. This makes the source fully
nix-expressed and reproducible (the "off submodules in the long run" the user
asked for), and removes the `?submodules=1` requirement from every build.

## Mechanism (landed, proven)

Three pieces, all in this commit series:

1. `scripts/gen-submodule-manifest.sh` -> `nix/submodules.json`.
   Reads `.gitmodules` (path, URL) and the gitlink revs (`git ls-tree HEAD`,
   works uninitialised). Maps `../X.git` -> `github.com/darlinghq/X` (the mapping
   `scripts/init-submodules.sh` already uses successfully). Applies the same xnu
   gitlink override (base rev + `patches/xnu/`, since the fork rev is unpublished).
   147 entries: `{ path, owner, repo, rev, hash }`.

2. `scripts/prefetch-submodule-hashes.sh` fills each `hash` (fetchFromGitHub SRI)
   via `nix-prefetch-url --unpack`. Incremental, interruptible, persists per
   success; takes path/repo filters, `--limit N`, or `--all`.

3. `nix/lib/darling-src.nix` fetches every *pinned* entry and overlays it onto a
   base tree, then applies `patches/<name>/*.patch`. Partial by design: unpinned
   entries stay as `baseSrc` has them and are listed in `passthru.unpinnedPaths`,
   so it works from the first hash and becomes a full submodule replacement once
   all 147 are pinned. A build needing an unpinned submodule fails loudly.

Proven: `libkqueue`/`zlib`/`bzip2` prefetch cleanly and `darling-src` assembles a
tree with their real content (110/272/72 files) while preserving the base tree.

## Status

- [x] Manifest generator + prefetcher + `darling-src.nix` assembler (proven on
      libkqueue/zlib/bzip2).
- [x] **All 147 hashes pinned** (bulk prefetch: 144 in one run + 3 proof-set, 0
      failures). Every Darling submodule resolves at github.com/darlinghq.
- [x] `packages.darling-src` exposed; builds the complete tree from nix fetches.
- [x] No nested submodule paths, all under `src/external/`, so the overlay needs
      no ordering.
- [x] **Full assembly verified**: `nix build .#darling-src` produces a 3.9G tree
      with 147/147 submodules populated (openssl 2089 files, curl 3030, xnu 6706,
      ...) and the xnu patch applied (`renameatx_np.h` present). The complete
      Darling source builds purely from nix fetches, no git submodules.

## Remaining

- [ ] Wire `darling-src.nix` as the `src` for the darling package and
      `darlingNinja` (baseSrc = this flake's tree), so `nix build .#darling*`
      needs no `?submodules=1`. Keep `?submodules=1` working during migration.
      This is the step that actually retires the git submodules for the build.
- [ ] Flake check that the manifest has no unpinned entries (ratchet: the tree
      stays fully nix-fetched as submodule gitlinks are bumped).
- [ ] On a gitlink bump: re-run `gen-submodule-manifest.sh` (it preserves hashes
      for unchanged revs), then `prefetch-submodule-hashes.sh` for the changed ones.
- [ ] Nested submodules: this handles the 147 top-level `.gitmodules` entries.
      If any submodule has its own submodules the build needs, extend the manifest
      generator to recurse (none observed blocking darlingserver/launcher so far).

## Why this is the real "off submodules" move

`?submodules=1` still runs git submodule fetching under the hood and taints the
flake (dirty tree, non-reproducible). Pinning every tree as `fetchFromGitHub`
with an SRI hash makes the whole source a pure nix derivation: cache-shareable,
bit-reproducible, and decoupled from the git submodule machinery entirely.
