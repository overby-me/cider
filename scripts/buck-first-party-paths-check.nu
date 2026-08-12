#!/usr/bin/env nu

# A first-party path quoted in a build file must resolve to something that exists.
#
# WHY THIS EXISTS. #87 moved 52 directories out of src/ into darwin/ and linux/, and 44 literal
# "src/xtrace/include" strings did not move with them, in buck-src/BUCK (23), buck-src/xnu/BUCK
# (19), buck-src/syslog/BUCK (1) and buck-src/OpenDirectory/BUCK (1). Nothing complained. buck2
# takes a missing include dir as an empty one, so the targets loaded, the graph built, the
# lowering staged, and gate11 died an hour later with 118 errors that named base.h, memory.h and
# string.h rather than the path that was wrong. 44 stale strings, 44 failing MIG stubs.
#
# THE RULE IS DELIBERATELY NARROW, because a path in a build file lives in one of FOUR spaces and
# they are spelled identically:
#
#   1. repo-relative and CURRENT, an include dir, a root =, a src. This is the only class that
#      must resolve, and the only class this checks.
#   2. pin-relative, openssl/src/tools/c_hash. Recorded in buck/generated/exports_<pin>.bzl
#      against the PIN root, so it does not resolve from the repo root and must not be expected
#      to. buck-pin-paths-check.nu owns this class and resolves it against the right root.
#   3. FROZEN REFERENCE, a buck-registry: KEY, a "# cmake target: X ->" line. Still spells the
#      pre-move layout on purpose, because the reference build.ninja is frozen. Comments only,
#      so quoting is what keeps them out of here.
#   4. cmake BINARY-DIR, everything under "# TODO these include dirs are GENERATED (codegen
#      output):". Also comments only.
#
# So: quoted literals only, which excludes 3 and 4; and the two exclusions below, which exclude
# 2 and the outputs.
#
# THE EXCLUSIONS, both measured rather than assumed:
#
#   buck/generated/exports_*.bzl   93 hits, every one pin-root-relative (libcxx's src/any.cpp and
#                                  friends). Class 2, owned by buck-pin-paths-check.nu.
#   pins/**                        a pin that has not been materialized is absent from disk, so
#                                  its own BUCK file cannot resolve its own sources.
#   out_base = "..."               a mig_gen OUTPUT base, not an input. buck-src/BUCK declares
#                                  out_base = "src/firehose" for libdispatch's firehose
#                                  protocols; nothing of that name exists or should.
#
# A package-relative spelling is accepted too (resolved against the build file's own directory),
# because both forms appear and both are correct.
#
# PORTED FROM PYTHON, byte identical on the real repo and under a planted stale path. THE SCOPE
# IS UNCHANGED AND MUST STAY UNCHANGED: the four path spaces above are spelled identically, so
# widening the regex or dropping an exclusion does not make this check stronger, it makes it
# report classes 2 to 4 as failures and get silenced.
#
# THE NUSHELL TRAP HERE IS THE EXISTENCE TEST. python asks os.path.lexists, which is TRUE for a
# DANGLING SYMLINK; nushell `path exists` follows the link and answers false. The equivalent is
# `path exists --no-symlink`. Getting that wrong would make a quoted path that points at a broken
# link read as unresolved, which is a different check from the one documented above.
#
# It walks per LINE rather than over the whole file text, because that is what gives the line
# number for free; python computed it by counting newlines before the match offset. The quoted
# literals and the out_base attributes are all single-line, so the two are equivalent. Cost on
# this repo: 194 build files, 205,024 lines, about 2s against python's 0.8s.

const SKIP_DIRS = [".jj" ".git" "buck-out" "target" "outputs" "build" "__pycache__" "buck-rust"]
const LITERAL = '"(?<q>(?:src|darwin|linux)/[\w./+-]+)"'
const OUTPUT_ATTR = '\bout_base\s*=\s*"[^"]*"'

# NAME THE THREE PATTERNS AND PASS --exclude. Both halves of that are load bearing and both were
# measured on this repo, which carries buck-src and the pins:
#
#   `glob "**/*"` then filtering by extension does NOT FINISH IN TWO MINUTES, because the filter
#   is applied to results and the result set is the whole tree.
#
#   `glob "**/BUCK"` with no --exclude is 11.5s, and each of the three patterns pays it again,
#   so the naive three-glob version costs 35s against python's 0.78s. WITH --exclude it is
#   737ms per pattern. So --exclude PRUNES THE WALK rather than filtering results, which is the
#   opposite of what the post-filter above does and is worth knowing before reaching for glob
#   anywhere else in this port.
#
# The exclusions mirror python's `dn[:] = [d for d in dn if d not in SKIP_DIRS]`, and main
# re-applies the same list per path so the two can never drift apart silently.
def build-files [repo: string] {
  let ex = ($SKIP_DIRS | each {|d| $"**/($d)/**" })
  [ $"($repo)/**/BUCK" $"($repo)/**/*.bzl" $"($repo)/**/*.bxl" ]
    | each {|g| glob $g --no-dir --exclude $ex } | flatten | uniq | sort
}

# False for the two path spaces this rule cannot judge. See the header.
def in-scope [rel: string] {
  if ($rel | str starts-with "pins/") { return false }
  ($rel =~ 'buck/generated/exports_.*\.bzl$') == false
}

def main [
  --root: string = ""   # exists for the negative control, which has to run against a tree where
                        # the path is genuinely absent. Pointing it at the real repo cannot
                        # demonstrate the failing direction without editing a BUCK file, and a
                        # control that edits projectSrc cannot run beside a build.
] {
  # The bounds test is not pedantry: a check that raises is a check that FAILS, and a suite
  # reading only the exit code cannot tell a crash from a real finding. Say what is wrong and
  # exit 2, which is the convention the other checks use for cannot-run as against found-a-problem.
  mut r = ($env.FILE_PWD | path dirname)
  if not ($root | is-empty) {
    $r = ($root | path expand)
    if (not ($r | path exists)) or (($r | path type) != "dir") {
      print -e $"FAIL: --root ($r) is not a directory"
      exit 2
    }
  }
  let repo = $r

  let files = (build-files $repo)

  mut bad = []
  mut seen = 0
  mut nfiles = 0
  for p in $files {
    let rel = ($p | str replace $"($repo)/" "")
    if ($rel | split row "/" | any {|c| $c in $SKIP_DIRS }) { continue }
    if ($p | path type) == "symlink" { continue }
    if not (in-scope $rel) { continue }
    let text = (try { open --raw $p | decode utf-8 } catch { null })
    if $text == null { continue }
    $nfiles = $nfiles + 1
    let dir = ($p | path dirname)
    # PREFILTER, and it is the difference between seconds and never finishing. Running the
    # out_base substitution and the literal parse on all 205,024 lines does not complete in two
    # minutes; a line can only produce a match if it already contains one of the three quoted
    # prefixes, and filtering on that first takes the expensive work down to about 700 lines.
    # 105k lines of the four biggest build files go from a timeout to 162ms.
    for row in ($text | lines | enumerate | where {|r| $r.item =~ '"(src|darwin|linux)/' }) {
      # Blank the output attributes rather than skipping the line, so a real path sharing a
      # line with an out_base is still checked.
      let line = ($row.item | str replace --all --regex $OUTPUT_ATTR " ")
      for m in ($line | parse --regex $LITERAL) {
        $seen = $seen + 1
        if ($"($repo)/($m.q)" | path exists --no-symlink) { continue }
        if ($"($dir)/($m.q)" | path exists --no-symlink) { continue }
        $bad = ($bad | append $"($rel):($row.index + 1): ($m.q)")
      }
    }
  }

  print $"first-party paths  ($seen) quoted in ($nfiles) build file\(s\), ($bad | length) unresolved"
  if not ($bad | is-empty) {
    for b in $bad { print $"    - ($b)" }
    print $"\nFAIL: ($bad | length) quoted first-party path\(s\) resolve to nothing. buck2 reads a missing include dir as an EMPTY one, so this does not fail the build where it is written; it fails a compile somewhere else, much later."
    exit 1
  }
  print "PASS: every quoted first-party path resolves"
  exit 0
}
