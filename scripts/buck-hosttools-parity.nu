#!/usr/bin/env nu

# Do the Rust host tools behave EXACTLY like the C ones they replace? (#76)
#
# getuuid and elfdep were ported to Rust. Parity here means BYTE parity, not "looks the same":
# stdout compared as HEX, stderr verbatim, exit code compared. A trailing newline appearing or
# disappearing would be a real regression, and getuuid deliberately emits none.
#
# NOTHING IN THE BUCK2 BUILD CONSUMES EITHER TOOL TODAY. The one consumer is cmake/dsym.cmake,
# which belongs to the reference CMake build this port replaces, and it calls getuuid and reads
# its stdout. So the strictness is for that caller and for anyone who wires these up later, not
# for a dependency that exists right now. Said plainly because the opposite claim, that the
# output is consumed in-tree, is easy to assume and was written here first.
#
# WHY BYTES AND NOT EYES. Writing the ports from a reading of the C produced one defect that
# survived review and died here: std::io::Error renders ENOENT as
# "No such file or directory (os error 2)" while the C strerror prints only "No such file or
# directory". Only a byte comparison against the actual C binary catches that.
#
# WHAT THE CASES DO AND DO NOT PROVE, which matters when reading a green run:
#
#   the Mach-O cases (a dylib, an ELF object) DISCRIMINATE. They exercise the magic dispatch,
#   the load command walk and the output format, and they are what would catch a real porting
#   error.
#
#   the error cases (no args, missing file, non Mach-O) verify FORMATTING against the C, and
#   that is worth having, but they do NOT discriminate between the two tools: getuuid and elfdep
#   produce byte identical error output by design. Verified by running the harness across tools,
#   where the missing-file case reports SAME and only the dylib case reports DIFF. A run that
#   exercised only error paths would prove much less than it appears to.
#
# Exit 0 when every pair matches, 1 on any difference, 2 when a binary is missing.
#
# Usage:
#   scripts/buck-hosttools-parity.nu                  # build outputs under buck-out
#   scripts/buck-hosttools-parity.nu --buck-out DIR
#
# PORTED FROM PYTHON, byte identical on the real binaries and under a planted mismatch. THIS IS
# THE CHECK THAT PROVES NUSHELL CAN DO THE BINARY COMPARISONS, which is the part of #98 that
# looked risky, so the findings are recorded rather than left implicit:
#
#   `complete` PRESERVES EVERYTHING. Trailing newlines are kept, and stdout that is not valid
#   UTF-8 comes back as a `binary` value rather than being lossily decoded. Measured against
#   python subprocess on the same three inputs: 610a, 61, and 00fffe, all identical. So
#   `$r.stdout | into binary` is a faithful equivalent of python's `p.stdout`.
#
#   `encode hex` IS UPPERCASE and python's `bytes.hex()` is lowercase, so it needs
#   `| str downcase` to compare or print the same string. Nothing warns about this and the byte
#   content is identical either way, which is precisely why it would survive review.

const DEFAULT_OUT = "buck-out/v2/art/root/1ef78538d8598cb2"

# Python's repr() for the stderr in the DIFF branch. Scoped to what these tools can actually
# emit, which is ASCII error text: backslash, the three whitespace escapes, and the quote.
# Not a general repr, and deliberately not pretending to be one.
def py-repr [s: string] {
  let e = ($s | str replace --all "\\" "\\\\"
             | str replace --all "\n" "\\n"
             | str replace --all "\r" "\\r"
             | str replace --all "\t" "\\t"
             | str replace --all "'" "\\'")
  $"'($e)'"
}

def run-one [binary: string, args: list<string>] {
  let r = (do -i { ^$binary ...$args } | complete)
  {
    out: ($r.stdout | into binary | encode hex | str downcase)
    err: ($r.stderr | into string)
    rc: $r.exit_code
  }
}

def main [--buck-out: string = ""] {
  let b = (if ($buck_out | is-empty) { $DEFAULT_OUT } else { $buck_out })

  let notmacho = "/tmp/buck-hosttools-parity-notmacho.bin"
  "not a mach-o at all\n" | save -f $notmacho

  let dylib = ($b | path join "darwin/libsimple/__libsimple_cider_dylib__/libsimple_cider.dylib")
  let elfobj = ($b | path join "linux/startup/__rtsig__/__objs/rtsig.c.o")

  let pairs = [
    { name: "getuuid", c: ($b | path join "linux/buildtools/__getuuid_c__/getuuid_c"),
      r: ($b | path join "linux/buildtools/__getuuid__/getuuid") }
    { name: "elfdep", c: ($b | path join "linux/buildtools/__elfdep_c__/elfdep_c"),
      r: ($b | path join "linux/buildtools/__elfdep__/elfdep") }
  ]
  let cases = [
    { label: "no args", args: [] }
    { label: "missing file", args: ["/nonexistent/path"] }
    { label: "not mach-o", args: [$notmacho] }
    { label: "dylib", args: [$dylib] }
    { label: "elf object", args: [$elfobj] }
  ]

  let missing = ($pairs | each {|p| [$p.c, $p.r] } | flatten | where {|f| not ($f | path exists) })
  if not ($missing | is-empty) {
    print "MISSING, build //linux/buildtools:{getuuid,elfdep,getuuid_c,elfdep_c} first:"
    for m in $missing { print $"   ($m)" }
    exit 2
  }

  mut bad = 0
  mut walked = 0
  for p in $pairs {
    print $"=== ($p.name): C against Rust ==="
    for case in $cases {
      let c = (run-one $p.c $case.args)
      let r = (run-one $p.r $case.args)
      $walked = $walked + 1
      if ($c.out == $r.out) and ($c.err == $r.err) and ($c.rc == $r.rc) {
        # {label:<14} in python is a LEFT pad to 14; nushell fill is the equivalent.
        print $"  ok    ($case.label | fill -a left -w 14) exit=($c.rc) stdout=(($c.out | str length) // 2)B"
      } else {
        $bad = $bad + 1
        print $"  DIFF  ($case.label)"
        if $c.rc != $r.rc { print $"    exit   C=($c.rc) R=($r.rc)" }
        if $c.out != $r.out { print $"    stdout C=($c.out)\n           R=($r.out)" }
        if $c.err != $r.err { print $"    stderr C=(py-repr $c.err)\n           R=(py-repr $r.err)" }
      }
    }
  }

  # A harness that compared nothing would print a clean sheet, so say what it walked.
  if $walked == 0 {
    print "FAIL: compared nothing, so this proved nothing"
    exit 1
  }
  print ""
  if $bad > 0 {
    print $"FAIL: ($bad) of ($walked) comparisons differ"
    exit 1
  }
  print $"PASS: ($walked) comparisons byte identical \(stdout hex, stderr, exit code\)"
  exit 0
}
