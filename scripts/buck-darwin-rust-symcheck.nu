#!/usr/bin/env nu

# CAN CIDER libSystem SATISFY WHAT OFFICIAL DARWIN RUST std REFERENCES? (task #96 step 0)
#
# THE QUESTION. Official rust-std for x86_64-apple-darwin is built expecting APPLE libSystem.
# cider links guest binaries against its OWN reimplementation. So before anyone wires a
# toolchain, measure the gap: undefined symbols the std rlibs cannot satisfy among themselves,
# minus what cider exports.
#
# FOUR WAYS TO GET THIS WRONG, ALL OF WHICH WERE DONE BEFORE THE NUMBER WAS TRUSTWORTHY:
#
#   1. llvm-nm and GNU nm ERROR on the big rlibs and succeed on the small ones, so a total that
#      looks plausible can be missing std entirely. First run said 1,246 undefined. Garbage.
#   2. ar x with a RELATIVE path and cwd set extracts nothing, and capturing output hides it.
#      That produced 0 defined, 0 undefined, 0 unreadable, which reads as a clean pass.
#   3. llvm-objdump --syms lists LOCAL symbols too, which a linker cannot bind to. Counting those
#      gave 18,218 cider exports against a true 7,508.
#   4. THE MACH-O SYMBOL TABLE IS NOT THE EXPORT LIST. Exports live in the EXPORT TRIE. For the
#      cider side use: llvm-objdump --macho --exports-trie
#
# USE llvm-objdump, NOT nm. Both llvm-nm and GNU nm REFUSE these objects:
#
#     Unknown attribute kind (105) (Producer: LLVM22.1.2-rust-1.95.0-stable, Reader: LLVM 21.1.8)
#
# They prefer the EMBEDDED BITCODE section over the Mach-O symbol table, and official 1.95.0 was
# built with a newer LLVM than the local one. That error is about the bitcode, NOT about the code:
# `file` reports each rlib member as a native "Mach-O 64-bit x86_64 object", and llvm-objdump reads
# its symbol table fine. This distinction is the whole feasibility question for route A, because
# native objects link without LLVM agreement while bitcode would not.
#
# Usage: scripts/buck-darwin-rust-symcheck.nu <rlib-dir> <cider-exports.txt>
#
# PORTED FROM PYTHON (#98), BYTE IDENTICAL on the real corpus: the 27 rust-std rlibs for
# x86_64-apple-darwin and the 7,508 line cider export list. STATUS recorded this check as
# unverifiable for lack of rlibs; that was stale, the rust-std tarball route B downloaded has
# them, so the port was gated on the real thing rather than on a synthetic stand-in.
#
# THE 27 UNREADABLE MEMBERS ARE EXPECTED AND ARE PART OF THE OUTPUT: each rlib carries a
# __.SYMDEF archive index, which is not a Mach-O object, so llvm-objdump errors on exactly one
# member per rlib. Hiding those would hide a real reader failure with them.

def say [msg: string] { print $msg }

# (defined, undefined) from one Mach-O object. A reader that ERRORED is not an empty result:
# it is reported, because a silent zero here is measurement 2 in the list above.
def syms [path: string] {
  # THROUGH env, so argv[0] is the BARE NAME. llvm-objdump prints its own argv[0] in an error,
  # and nushell execs the resolved absolute path, so the sampled failure lines came out as
  # /etc/profiles/per-user/.../llvm-objdump: error: ... where the python, which execs with
  # argv[0]="llvm-objdump", printed the short form. Same tool, same failure, different text in
  # the one place this script quotes it.
  let r = (do -i { ^env llvm-objdump --syms $path } | complete)
  if $r.exit_code != 0 or ($r.stderr | str contains "error:") {
    return { err: $"llvm-objdump failed on ($path): ($r.stderr | str trim | str substring 0..<200)" }
  }
  mut d = []
  mut u = []
  for line in ($r.stdout | lines) {
    # An undefined symbol line carries *UND* and ends with the name.
    if ($line | str contains "*UND*") {
      let m = ($line | parse --regex '^\S+\s+.*\*UND\*\s+(?<name>\S+)\s*$')
      if ($m | is-not-empty) { $u = ($u | append ($m | get name.0)) }
      continue
    }
    let parts = ($line | split row --regex '\s+' | where {|x| $x != "" })
    if ($parts | length) >= 2 and (($parts | last) | str starts-with "_") {
      $d = ($d | append ($parts | last))
    }
  }
  { d: $d, u: $u }
}

def main [libdir?: string, exports_path?: string] {
  if ($libdir | is-empty) or ($exports_path | is-empty) {
    say "Usage: scripts/buck-darwin-rust-symcheck.nu <rlib-dir> <cider-exports.txt>"
    exit 2
  }
  let rlibs = (ls $libdir | get name | each {|p| $p | path basename }
    | where {|f| $f | str ends-with ".rlib" } | sort)
  say $"rlibs: ($rlibs | length)"

  # THE SAME SHAPE python's tempfile.TemporaryDirectory() makes, /tmp/tmp + 8 characters, and it
  # is not cosmetic: the failure messages are truncated at a FIXED 120 characters and they quote
  # this path, so a longer temp name moves the cut and the two implementations disagree on where
  # the last message ends. Same length, same cut, and the only residue is the random characters.
  # --tmpdir with a SEPARATOR-FREE template: nushell mktemp rejects a template containing a
  # directory separator, so the path cannot be written out whole here.
  let td = (mktemp -d --tmpdir tmpXXXXXXXX)
  mut defined = []
  mut undefined = []
  mut failures = []
  for r in $rlibs {
    # ABSOLUTE. ar runs with cwd=sub, so a relative rlib path silently extracts nothing and the
    # captured error is thrown away: the first run of the python reported 0 undefined, 0 defined
    # and 0 unreadable members, which looks like a clean pass and is a measurement that never
    # happened.
    let full = ([$libdir $r] | path join | path expand)
    let sub = ([$td $r] | path join)
    mkdir $sub
    let ar = (do -i { cd $sub; ^ar x $full } | complete)
    if $ar.exit_code != 0 {
      $failures = ($failures | append
        $"ar x failed on ($r): ($ar.stderr | str trim | str substring 0..<120)")
      continue
    }
    let members = (ls $sub | get name | each {|p| $p | path basename } | sort)
    if ($members | is-empty) {
      $failures = ($failures | append $"ar x produced no members for ($r)")
      continue
    }
    for m in $members {
      let res = (syms ([$sub $m] | path join))
      if ($res | get -o err) != null {
        $failures = ($failures | append ($res.err | str substring 0..<120))
        continue
      }
      $defined = ($defined | append $res.d)
      $undefined = ($undefined | append $res.u)
    }
  }
  ^rm -rf $td

  let defined = ($defined | uniq)
  let undefined = ($undefined | uniq)
  say $"members that could not be read: ($failures | length)"
  for f in ($failures | first 5) { say $"    ($f)" }
  say $"defined by the rlibs   : ($defined | length)"
  say $"undefined referenced   : ($undefined | length)"

  # SET DIFFERENCE THROUGH grep -Fxv, not through `where ... in`, which is O(n*m) over lists:
  # 618 undefined against 3,831 defined and then 240 against 7,508 exports is small enough to
  # survive either way, but the same shape at graph scale is what cost buck-include-closure
  # 127 seconds, so the habit is the one that scales.
  let df = (mktemp -t --suffix .txt)
  let uf = (mktemp -t --suffix .txt)
  $defined | str join "\n" | save -f $df
  $undefined | str join "\n" | save -f $uf
  let ext = (^bash -c $"grep -Fxv -f ($df) ($uf) || true" | complete)
  let external = ($ext.stdout | lines | where {|x| $x != "" })
  say $"EXTERNAL needs \(undefined and not self-satisfied): ($external | length)"

  let cider = (open --raw $exports_path | decode utf-8 | lines
    | each {|l| $l | str trim } | where {|l| $l != "" } | uniq)
  say $"cider libSystem exports: ($cider | length)"

  let cf = (mktemp -t --suffix .txt)
  let ef = (mktemp -t --suffix .txt)
  $cider | str join "\n" | save -f $cf
  $external | str join "\n" | save -f $ef
  let miss = (^bash -c $"grep -Fxv -f ($cf) ($ef) || true" | complete)
  let missing = ($miss.stdout | lines | where {|x| $x != "" } | sort)
  rm -f $df $uf $cf $ef

  say ""
  say $"=== MISSING FROM CIDER: ($missing | length) of ($external | length) ==="
  for s in $missing { say $"    ($s)" }
  exit 0
}
