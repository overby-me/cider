#!/usr/bin/env nu

# HOW MUCH OF THE REFERENCE BUILD DOES THE PORT ACTUALLY BUILD?
#
# The reference is the cmake build's own build.ninja, frozen at result-graph-ref. Every link
# edge in it is one artifact the port has to be able to produce, and this counts how many it
# declares a target for. It is a COVERAGE metric, not a build: nothing is compiled here.
#
# CLASSIFY BY THE NINJA RULE, which is cmake's own statement of what an edge is, rather than by
# guessing from the output name. Guessing went wrong twice: .so outputs fell through every
# branch, and requiring LINK_FLAGS to recognise an executable dropped the host tools, which
# cmake links without any.
#
# KEYED BY PATH, NOT BY BASENAME. An artifact name does not identify a library: the reference
# builds 79 names at more than one path, and collapsing those answered "ported" for a pair as
# soon as EITHER half was, which is how nine unported frameworks sat inside a metric that read
# 100 percent. The port says which target builds which reference PATH through the
# `buck-registry: <path> = <target>` pragma, so paths resolve first and the artifact name is
# only a fallback for blocks that predate the pragma.
#
# NOTHING IS SILENT. An edge that matches no category is COUNTED AND NAMED, because silence is
# how 70 module edges came to be missing from a metric that read 100 percent, and an ambiguous
# name resolved on the name alone is reported separately as the size of what this still takes
# on trust.
#
#   scripts/buck-coverage.nu
#   scripts/buck-coverage.nu --missing     # and name every gap
#
# PORTED FROM PYTHON (#98), byte identical. It carried the reference parser and three registries
# with it, which is what the user's split means by "buck-coverage reads the reference but is a
# LIVE check and belongs in #98": the reference PARSE moves here, the generator that also used
# it stays frozen.
#
# THE PARSE IS CHEAP AND WAS MEASURED BEFORE THE PORT: build.ninja is 131 MB and 362,663 lines,
# and one nushell pass over it is 0.73 s. It is regex PER LINE that is expensive in nushell, not
# the loop, so this parser splits on strings only.

const OURS_SKIP = ["buck-out" ".git" ".jj" ".direnv" "build"]

# THE REFERENCE PREDATES THE CIDER RENAME, so three edges look unported while the port builds
# them under new names. A MAP rather than a re-frozen reference on purpose: refreshing the
# reference would make these pass by moving the denominator, which also silently absorbs any
# REAL regression present at the moment of refreshing.
const RENAMED = [["from" "to"];
  ["darling-coredump" "cider-coredump"]
  ["liblibsimple_darling.a" "liblibsimple_cider.a"]
  ["liblibsimple_darlingserver.a" "liblibsimple_ciderd.a"]]

# Deliberately not ported, WITH THE REASON. Counted separately so "what is left" stays an honest
# number rather than a permanent three, and the reasons travel with the names: --missing prints
# them, and the first version of this port dropped them, which the detailed comparison caught.
const OUT_OF_SCOPE_TABLE = [["name" "why"];
  ["libdarlingserver_duct_tape.a" "duct-tape was ported to Rust in #71, all 16 glue files, so the C archive no longer exists as a link edge. Not a gap: the functionality lives in the Rust daemon and the XNU subset it wraps is a pin. Structural, unlike the three RENAMED entries."]
  ["x86_64-apple-darwin20-ld" "Darling's ld64 and cctools come from Nix (nix/lib/cider-ld64.nix, the ld64 input to ciderBuck2Graph); the port CONSUMES them through [cider] ld and ld64_dir rather than building them"]
  ["x86_64-apple-darwin20-ar" "same as x86_64-apple-darwin20-ld: supplied by the Nix-built cctools"]
  ["x86_64-apple-darwin20-ranlib" "same as x86_64-apple-darwin20-ld: supplied by the Nix-built cctools"]
  ["pins/cctools-port/cctools/misc/lipo" "the second lipo: only cctools' copy is installed, and cctools-port's is a build-time tool supplied by the Nix-built cctools like ld, ar and ranlib"]
  ["libsystem_kernel_static32.a" "the i386 slice: its libsyscall_32 compiles the -i386-User.c mig stubs, and this port targets x86_64 only"]]
const OUT_OF_SCOPE = ["libdarlingserver_duct_tape.a" "x86_64-apple-darwin20-ld"
  "x86_64-apple-darwin20-ar" "x86_64-apple-darwin20-ranlib"
  "pins/cctools-port/cctools/misc/lipo" "libsystem_kernel_static32.a"]

const ARCHIVE_ALIASES = [["artifact" "label"];
  ["liblibsimple_cider.a" "//darwin/libsimple:libsimple_cider"]
  ["libciderd_xnu_sys.a" "//pins/ciderd/xnu-sys:ciderd_xnu_sys"]
  ["liblibsimple_ciderd.a" "//darwin/libsimple:libsimple_ciderd"]]

# Parse build.ninja into rows of {outs, rule, inputs, link_flags}.
#
# STRING SPLITS ONLY. The python does the same and for the same reason; a `parse --regex` per
# line over 362,663 lines is minutes, and the loop itself is under a second.
#
# NINJA ESCAPES ITS OWN $, writing a literal one as $$, and CoreFoundation's link carries
# -Wl,-alias,_OBJC_CLASS_$___NSCFConstantString: passing the escape through hands ld64 a symbol
# that does not exist. Only LINK_FLAGS is read here, and it is unescaped the same way.
def read-edges [graph: string] {
  mut edges = []
  # A FLAG, NOT null, FOR "no current edge": a mut binding takes the type of its initial value,
  # so starting at null and assigning a record is a type error rather than a fresh binding.
  mut cur = { outs: [], rule: "", inputs: [], link_flags: "" }
  mut have = false
  for line in (open --raw $graph | decode utf-8 | lines) {
    if ($line | str starts-with "build ") {
      if $have { $edges = ($edges | append $cur) }
      let rest0 = ($line | str substring 6..)
      let parts = ($rest0 | split row ": ")
      let head = ($parts | first)
      let rest = ($parts | skip 1 | str join ": ")
      let toks = ($rest | split row " ")
      $cur = { outs: ($head | split row " | " | first | split row " " | where {|o| $o != "" }),
               rule: ($toks | first),
               inputs: ($toks | skip 1 | where {|i| $i != "" and $i != "|" and $i != "||" }),
               link_flags: "" }
      $have = true
    } else if $have and ($line | str starts-with "  ") and ($line | str contains " = ") {
      let kv = ($line | str trim | split row " = ")
      if ($kv | first) == "LINK_FLAGS" {
        $cur = ($cur | upsert link_flags (($kv | skip 1 | str join " = ")
          | str replace --all '$$' '$' | str replace --all '$:' ':'))
      }
    } else if ($line | str trim) == "" {
      if $have { $edges = ($edges | append $cur); $have = false }
    }
  }
  if $have { $edges = ($edges | append $cur) }
  $edges
}

# Every BUCK file in the repo, with its package path.
def buck-files [] {
  let found = (do -i { ^find . -type d -name buck-out -prune -o -type d -name .git -prune -o -type d -name .jj -prune -o -type d -name .direnv -prune -o -type d -name build -prune -o -type f -name BUCK -print } | complete)
  $found.stdout | lines | where {|p| $p != "" } | each {|p|
    { path: $p, pkg: ($p | path dirname | str replace --regex '^\./' "") }
  }
}

# A reference path in the spelling the TREE uses. The reference is frozen and predates #87, so
# it names a pin src/external/<pin>/...; OUT_OF_SCOPE is written in the current spelling because
# that is how its reasons read. Without this the second lipo entry never matched, the edge fell
# through to the by-name bucket, and the suite ceiling of 0 failed on a 1 that was a SPELLING
# and not a gap. Same class as the install manifests, which said "is in no package" 2,182 times.
def tree-path [p: string] {
  if ($p | str starts-with "src/external/") {
    $"pins/($p | str substring 13..)"
  } else { $p }
}

def main [--missing] {
  cd ($env.CURRENT_FILE | path dirname | path join "..")
  let graph = ("result-graph-ref" | path expand | path join "build.ninja")
  if not ($graph | path exists) {
    print -e $"no reference graph at ($graph)"
    exit 2
  }
  let edges = (read-edges $graph)
  let files = (buck-files)

  # THE REGISTRIES, read out of the committed BUCK files rather than assumed. Each is a TEXT
  # scan, so a block that builds its targets from a Starlark table is invisible to it and
  # declares what it produces with a `buck-registry:` pragma instead.
  mut firstpass = {}
  mut final_reg = {}
  mut arch_reg = ($ARCHIVE_ALIASES | reduce --fold {} {|r, acc| $acc | upsert $r.artifact $r.label })
  mut exe_names = []
  mut module_names = []
  for f in $files {
    let text = (open --raw $f.path | decode utf-8)
    # firstpass, keyed by BOTH the target stem and the artifact stem, because they diverge:
    # Security_firstpass builds libSecurity_x86_64_firstpass.dylib.
    for m in ($text | parse --regex 'name = "(?<t>[A-Za-z0-9_.-]+)_firstpass",\s*\n\s*dylib_name = "(?<d>[^"]+)"') {
      let label = $"//($f.pkg):($m.t)_firstpass"
      $firstpass = ($firstpass | upsert $m.t $label)
      let stem = ($m.d | str replace --regex '^lib' "" | str replace --regex '\.dylib$' ""
        | str replace --regex '_firstpass$' "")
      $firstpass = ($firstpass | upsert $stem $label)
    }
    for m in ($text | parse --regex 'name = "(?<t>[A-Za-z0-9_.-]+)_firstpass"') {
      if ($firstpass | get -o $m.t) == null {
        $firstpass = ($firstpass | upsert $m.t $"//($f.pkg):($m.t)_firstpass")
      }
    }
    # final, keyed by ARTIFACT name, plus the pragma which keys by reference PATH.
    mut stubs = []
    for m in ($text | parse --regex '#\s*buck-registry:\s*(?<p>\S+)\s*=\s*(?<t>\S+)') {
      $final_reg = ($final_reg | upsert $m.p $"//($f.pkg):($m.t)")
      if ($m.p | str contains "/dev-stubs/") { $stubs = ($stubs | append $m.t) }
    }
    for m in ($text | parse --regex 'name = "(?<t>[A-Za-z0-9_.-]+)_(?<k>final|dylib)",\s*\n\s*dylib_name = "(?<d>[^"]+)"') {
      if $"($m.t)_($m.k)" in $stubs { continue }
      let label = $"//($f.pkg):($m.t)_($m.k)"
      $final_reg = ($final_reg | upsert $m.d $label)
      let stripped = ($m.d | str replace --regex '_(x86_64|i386|arm64|arm64e)(\.dylib)?$' '$2')
      if $stripped != $m.d and ($final_reg | get -o $stripped) == null {
        $final_reg = ($final_reg | upsert $stripped $label)
      }
    }
    for m in ($text | parse --regex 'cc_static_lib\(\s*\n\s*name = "(?<t>[A-Za-z0-9_.-]+)",(?:\s*\n\s*lib_name = "(?<l>[^"]+)",)?') {
      let artifact = (if ($m.l | is-empty) { $"lib($m.t).a" } else { $m.l })
      $arch_reg = ($arch_reg | upsert $artifact $"//($f.pkg):($m.t)")
    }
    # Buck target names, so executables can be looked up by name. cc_binary as well as
    # darwin_binary: the HOST tools the reference links are built by the port too.
    for m in ($text | parse --regex '(?:darwin_binary|cc_binary)\(\s*\n\s*name = "(?<n>[A-Za-z0-9_.-]+)"') {
      $exe_names = ($exe_names | append $m.n)
    }
    # ALSO the exe_name a rule installs under, which is often not its target name: curl is the
    # target curlexe, and clang, git, bison and the Carbon tools are xcselect SHIMS.
    for m in ($text | parse --regex 'exe_name = "(?<n>[A-Za-z0-9_.+-]+)"') {
      $exe_names = ($exe_names | append $m.n)
    }
    for m in ($text | parse --regex 'dylib_name = "(?<n>[A-Za-z0-9_.+-]+\.so)"') {
      $module_names = ($module_names | append $m.n)
    }
  }
  let exe_names = ($exe_names | uniq)
  let module_names = ($module_names | uniq)

  # An artifact name the reference builds at more than one path. Resolving such an edge by NAME
  # cannot distinguish the two, so it is counted but reported separately.
  let link_edges = ($edges | where {|e|
    let has_o = ($e.inputs | any {|i| $i | str ends-with ".o" })
    let kind = ($e.rule | split row "__" | first)
    $has_o and $kind != "phony"
  })
  mut paths_by_name = {}
  for e in $link_edges {
    let kind = ($e.rule | split row "__" | first)
    for o in $e.outs {
      if not ($o | str contains "/") { continue }
      let key = $"($kind)\u{1f}($o | path basename)"
      $paths_by_name = ($paths_by_name | upsert $key (($paths_by_name | get -o $key | default []) | append $o | uniq))
      break
    }
  }
  let ambiguous = ($paths_by_name | transpose k v | where {|r| ($r.v | length) > 1 } | get k)

  mut kinds = { dylib: [], exe: [], archive: [], module: [] }
  mut soft = []
  mut unclassified = []
  let renamed = ($RENAMED | reduce --fold {} {|r, acc| $acc | upsert $r.from $r.to })
  for e in $link_edges {
    let kind = ($e.rule | split row "__" | first)
    for o in $e.outs {
      if not ($o | str contains "/") { continue }
      let base = ($o | path basename)
      let alias = ($renamed | get -o $base)
      if ($kind | str ends-with "STATIC_LIBRARY_LINKER") {
        let ported = (($arch_reg | get -o $o) != null) or (($arch_reg | get -o $base) != null) or ($alias != null and ($arch_reg | get -o $alias) != null)
        $kinds = ($kinds | upsert archive ($kinds.archive | append { path: $o, name: $base, ported: $ported }))
      } else if ($kind | str ends-with "SHARED_LIBRARY_LINKER") {
        if ($base | str ends-with ".so") {
          # A loadable MODULE: -shared, no -dylib_install_name. zsh's 35.
          let ported = (($final_reg | get -o $o) != null) or ($base in $module_names)
          $kinds = ($kinds | upsert module ($kinds.module | append { path: $o, name: $base, ported: $ported }))
        } else {
          let stem = ($base | str replace --regex '^lib' "" | str replace --regex '\.dylib$' "" | str replace --regex '_firstpass$' "")
          let ported = (($final_reg | get -o $o) != null) or (($final_reg | get -o $base) != null) or (($firstpass | get -o $stem) != null)
          $kinds = ($kinds | upsert dylib ($kinds.dylib | append { path: $o, name: $base, ported: $ported }))
        }
      } else if ($kind | str ends-with "EXECUTABLE_LINKER") {
        let ported = (($final_reg | get -o $o) != null) or ($base in $exe_names) or ($alias != null and $alias in $exe_names)
        $kinds = ($kinds | upsert exe ($kinds.exe | append { path: $o, name: $base, ported: $ported }))
      } else {
        $unclassified = ($unclassified | append $"($base) \(($kind)\)")
      }
      let key = $"($kind)\u{1f}($base)"
      if ($key in $ambiguous) and (($final_reg | get -o $o) == null) and (($arch_reg | get -o $o) == null) and (not ($o in $OUT_OF_SCOPE)) and (not ((tree-path $o) in $OUT_OF_SCOPE)) and (not ($base in $OUT_OF_SCOPE)) {
        $soft = ($soft | append $o)
      }
      break
    }
  }

  mut total = 0
  mut done = 0
  for kind in ["dylib" "exe" "archive" "module"] {
    mut items = {}
    mut label = {}
    for r in ($kinds | get $kind) {
      $items = ($items | upsert $r.path ((($items | get -o $r.path) | default false) or $r.ported))
      $label = ($label | upsert $r.path $r.name)
    }
    # OUT_OF_SCOPE is written by artifact name, since that is how the reasons read. Keyed by
    # PATH as well as by name: where two artifacts share a name and only one is out of scope, a
    # name-only check would drop both.
    let skipped = ($items | columns | where {|k| ($k in $OUT_OF_SCOPE) or ((tree-path $k) in $OUT_OF_SCOPE) or (($label | get $k) in $OUT_OF_SCOPE) })
    let kept = ($items | columns | where {|k| not ($k in $skipped) })
    let n = ($kept | length)
    let d = ($kept | where {|k| ($items | get $k) } | length)
    $total = $total + $n
    $done = $done + $d
    let note = (if ($skipped | is-not-empty) { $"   \(($skipped | length) out of scope\)" } else { "" })
    print $"(($kind + 's') | fill --alignment left --width 10) ($d | fill --alignment right --width 4) / ($n | fill --alignment right --width 4)($note)"
    if $missing {
      for m in ($kept | where {|k| not ($items | get $k) } | sort) { print $"    - ($m)" }
    }
  }
  let pct = (if $total > 0 { (100 * $done) // $total } else { 0 })
  print $"('total' | fill --alignment left --width 10) ($done | fill --alignment right --width 4) / ($total | fill --alignment right --width 4)  \(($pct)%\)"
  if ($soft | is-not-empty) {
    print $"('by-name' | fill --alignment left --width 10) ($soft | length | fill --alignment right --width 4)       \(ambiguous artifact name, no `buck-registry: <path>` pragma: counted on the NAME alone\)"
    if $missing {
      for s in ($soft | sort) { print $"    ~ ($s)" }
    }
  }
  if $missing {
    print "out of scope:"
    for r in ($OUT_OF_SCOPE_TABLE | sort-by name) { print $"    - ($r.name): ($r.why)" }
  }
  if ($unclassified | is-not-empty) {
    # Not fatal, but never silent: an edge nothing recognises is an edge nobody is counting.
    let names = ($unclassified | uniq | sort)
    print $"UNCLASSIFIED link outputs \(counted nowhere\): ($names | length)"
    for n in ($names | first 10) { print $"    ? ($n)" }
  }
  exit 0
}
