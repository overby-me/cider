# Vendored cocotron

This directory is **vendored source**, not a fetched pin. It was `vendor/pins/cocotron` in
`nix/submodules.json` with 86 patch files under `vendor/patches/cocotron`; it is now checked in
directly so its sources can be edited in-tree without the patch-file indirection.

## Where it came from

- Upstream: <https://github.com/darlinghq/darling-cocotron>
- Base commit: `c8d38d16a9f613d300157bebbab2b9501bc0c274`
- Taken: 2026-08-15. The upstream head that day was the 2026-06-06 merge of the Fedora 44 build fix.
- Ancestor: <https://github.com/cjwl/cocotron>, last pushed 2015-11-06, which is the dead original.

**Pulling upstream fixes is still a git range.** `git log c8d38d16..origin/master` against
darling-cocotron lists everything that has happened since the fork point, and the 86 patches that
were folded in are in this repository's history under `vendor/patches/cocotron` up to the commit
that removed them.

## Why it is bundled

86 patch files, 8,092 patch lines, 5,044 of them ADDED lines, touching 137 of the 1,327 sources.
That is first-party code living in a patch series where it cannot be read, searched or refactored,
and every commit paid a regeneration tax: build a reference tree from the pristine fetch plus the
whole series, diff against it, verify by re-applying.

The rule this fork wrote down is: patch live Apple upstreams, bundle dead ones. Cocotron is a dead
upstream by that test, and `vendor/pins/ciderd` is the precedent for the shape.

## Local changes on top of the base commit

Everything the 86 patches did, which is roughly: the Wayland-era AppKit behaviour (menus that run
their commands, windows that survive a compositor resize, panels that keep their controls), and the
macOS styling pass (Apple menu metrics, a rounded translucent menu, drawn check boxes and radios,
rounded wells, a stepper that is one control, key equivalents with the real symbols, Inter first for
the interface families, glyphs on a fractional pen). The commit messages are the record.
