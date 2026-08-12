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

# WRAPGEN IS COMPARED DIFFERENTLY from the other two, because its real output is not stdout: it
# writes a .c and, only when the library exports data symbols, a vars .h. So this hashes both
# files as well as stdout, stderr and the exit code, and it records whether the header was
# written at all, since "absent" against "written" is exactly the kind of difference that would
# otherwise pass unnoticed.
def wrapgen-one [binary: string, dir: string, name: string, soname: string, libdirs: string] {
  mkdir $dir
  let c = ($dir | path join $"($name).c")
  let h = ($dir | path join $"($name)_vars.h")
  let r = (with-env { LD_LIBRARY_PATH: $libdirs } { do -i { ^$binary $soname $c $h } | complete })
  {
    out: ($r.stdout | into binary | encode hex | str downcase)
    err: ($r.stderr | into string)
    rc: $r.exit_code
    c: (if ($c | path exists) { open --raw $c | hash sha256 } else { "NO .c WRITTEN" })
    h: (if ($h | path exists) { open --raw $h | hash sha256 } else { "no vars header" })
    size: (if ($c | path exists) { (ls $c | get 0.size | into int) } else { 0 })
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

  let wg_c = ($b | path join "linux/libelfloader/__wrapgen_c__/wrapgen_c")
  let wg_r = ($b | path join "linux/libelfloader/__wrapgen__/wrapgen")

  let missing = ([...($pairs | each {|p| [$p.c, $p.r] } | flatten), $wg_c, $wg_r]
    | where {|f| not ($f | path exists) })
  if not ($missing | is-empty) {
    print "MISSING, build these first:"
    print "  buck2 build //linux/buildtools:{getuuid,getuuid_c,elfdep,elfdep_c} //linux/libelfloader:{wrapgen,wrapgen_c}"
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

  # === wrapgen ===
  #
  # THIS ONE IS LOAD BEARING, unlike getuuid and elfdep: elf_wrapper() in buck/rules/codegen.bzl
  # runs it at build time and three packages compile the C it writes. So the comparison is over
  # the GENERATED FILES, and the libraries are real ones the build actually wraps.
  #
  # NO no-args CASE HERE, and that is an omission on purpose: the usage line prints argv[0],
  # which is the path of whichever binary ran, so the two can never be equal there and the
  # difference would say nothing about the port.
  #
  # THE LIBRARIES HAVE TO BE PRESENT for this to discriminate. wrapgen dlopen()s them, so it
  # needs the same LD_LIBRARY_PATH the rule passes, which is [cider] elf_lib_dirs written by
  # scripts/buck-setup.nu. If that is empty or the libraries are gone, every case fails
  # identically and the section would go green having compared two error messages. The size
  # assertion at the end is what stops that.
  let cfgline = (if (".buckconfig.local" | path exists) {
    open .buckconfig.local | lines | where {|l| ($l | str starts-with "elf_lib_dirs") } | get 0?
  } else { null })
  let libdirs = (if $cfgline == null { "" } else { $cfgline | split row "=" | skip 1 | str join "=" | str trim })

  let wgroot = (mktemp -d -t "cider-wrapgen-parity.XXXXXX")
  let wg_cases = [
    { label: "libX11.so", soname: "libX11.so" }        # big, and exports data symbols: writes the vars header
    { label: "libGL.so", soname: "libGL.so" }          # the largest at ~538 KB of C, and no data symbols
    { label: "libavutil.so", soname: "libavutil.so" }  # data symbols too, from a different provider
    { label: "libfuse.so", soname: "libfuse.so" }      # the small end, and the first consumer the port had
    { label: "missing library", soname: "nosuchlib.so" }
    { label: "not an ELF", soname: $notmacho }
  ]
  print "=== wrapgen: C against Rust \(generated files, not just stdout\) ==="
  mut biggest = 0
  for case in $wg_cases {
    let n = ($case.label | str replace --all "." "_" | str replace --all " " "_")
    let c = (wrapgen-one $wg_c ($wgroot | path join $"c_($n)") $n $case.soname $libdirs)
    let r = (wrapgen-one $wg_r ($wgroot | path join $"r_($n)") $n $case.soname $libdirs)
    $walked = $walked + 1
    if $c.size > $biggest { $biggest = $c.size }
    if ($c.out == $r.out) and ($c.err == $r.err) and ($c.rc == $r.rc) and ($c.c == $r.c) and ($c.h == $r.h) {
      print $"  ok    ($case.label | fill -a left -w 14) exit=($c.rc) c=($c.size)B (if $c.h == 'no vars header' { 'no vars header' } else { 'vars header written' })"
    } else {
      $bad = $bad + 1
      print $"  DIFF  ($case.label)"
      if $c.rc != $r.rc { print $"    exit   C=($c.rc) R=($r.rc)" }
      if $c.c != $r.c { print $"    .c     C=($c.c) R=($r.c)" }
      if $c.h != $r.h { print $"    vars.h C=($c.h) R=($r.h)" }
      if $c.out != $r.out { print $"    stdout C=($c.out)\n           R=($r.out)" }
      if $c.err != $r.err { print $"    stderr C=(py-repr $c.err)\n           R=(py-repr $r.err)" }
    }
  }
  rm -rf $wgroot
  if $biggest < 10000 {
    print ""
    print $"FAIL: wrapgen generated at most ($biggest) bytes of C, so the libraries were not"
    print "      loadable and only error paths were compared. Run scripts/buck-setup.nu."
    exit 1
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
