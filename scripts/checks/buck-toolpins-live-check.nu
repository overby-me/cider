#!/usr/bin/env nu
# EVERY /nix/store PATH PINNED IN .buckconfig.local MUST STILL EXIST.
#
# buck2 reports a garbage collected tool as
#
#     Spawning executable `/nix/store/...-wayland-scanner-.../bin/wayland-scanner` failed:
#     Failed to spawn a process
#
# which names no cause and reads like a sandbox or permissions problem. It is nix GC: the config
# pins absolute store paths and nothing holds a gcroot for them. It has now happened twice, to the
# guest rust toolchain and to wayland-scanner, and both times the message sent me looking in the
# wrong place first.
#
# The fix is one line per missing path, so this reports ALL of them rather than the first.

def main [] {
  let cfg = ([$env.FILE_PWD ".." ".." ".buckconfig.local"] | path join)
  if not ($cfg | path exists) {
    print $"toolpins: no .buckconfig.local, nothing pinned"
    return
  }

  # The whole path, not just the hash: two outputs of one derivation (wayland-1.25.0 and
  # wayland-scanner-1.25.0-bin) are separate store paths and only one of them went away.
  let pins = (
    open --raw $cfg
    | parse --regex '(?P<p>/nix/store/[a-z0-9]{32}-[^\s:"]+)'
    | get p
    | each {|p| $p | str trim --right --char '/' }
    | uniq
    | sort
  )

  let missing = ($pins | where {|p| not ($p | path exists) })

  print $"toolpins: ($pins | length) store paths pinned in .buckconfig.local"
  if ($missing | is-empty) {
    print "PASS: every pinned tool path still exists"
    return
  }

  print $"FAIL: ($missing | length) pinned path\(s) have been garbage collected:"
  for p in $missing { print $"  ($p)" }
  print ""
  # --realise takes the STORE ROOT, never a path inside it, so cut back to /nix/store/<hash>-<name>.
  print "Restore them, which pulls from the binary cache when it can:"
  let roots = ($missing | each {|p| $p | parse --regex '(?P<r>/nix/store/[a-z0-9]{32}-[^/]+)' | get r.0 } | uniq)
  for r in $roots { print $"  nix-store --realise ($r)" }
  exit 1
}
