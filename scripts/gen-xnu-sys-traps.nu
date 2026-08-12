#!/usr/bin/env nu

# EMIT THE RUST HALF OF xnu-sys/src/traps.c FROM THE GENERATED RPC HEADER (#71)
#
# traps.c is 29 lines of source and 35 exported symbols, because its last line is
# `DSERVER_XNU_SYS_DEFS`, an object-like macro that the RPC wrapper generator writes into
# ciderd/rpc.internal.h and that expands to 29 more function DEFINITIONS. Each one packs
# its scalar arguments into an XNU trap-args struct and calls the trap:
#
#     int xnu_sys_mach_port_deallocate(uint32_t target, uint32_t name) {
#         struct _kernelrpc_mach_port_deallocate_args args = {
#             .target = target,
#             .name = name,
#         };
#         return _kernelrpc_mach_port_deallocate_trap(&args);
#     };
#
# bindgen binds no macros, so this is the one blocker in the file, and it is the reason traps.c
# sat at the top of the ranking for weeks looking free. Writing those 29 wrappers by hand would
# be transcribing 29 signatures and about 90 field assignments, which is exactly the kind of
# thing that goes wrong quietly: a swapped field between two same-typed arguments compiles, links
# and returns the wrong answer.
#
# SO THEY ARE GENERATED FROM THE SAME PLACE THE C GETS THEM. This parses the expansion of
# DSERVER_XNU_SYS_DEFS out of the built header, so the Rust and the C are two renderings of one
# table. If the RPC generator adds a call, re-running this adds the wrapper.
#
# The output is checked in rather than built by a genrule, matching buck/generated/
# xnu_sys_flags.bzl, and --check re-derives it and fails if the committed file has drifted.
#
# Usage:
#   scripts/gen-xnu-sys-traps.nu             # write linux/server/src/xnu/traps_generated.rs
#   scripts/gen-xnu-sys-traps.nu --check     # fail if the committed file is out of date
#
# PORTED FROM PYTHON (#98). It is one of only THREE python files anything in this repo still
# EXECUTES, measured over 291 candidate files rather than assumed: this one from
# xnu-sys-runtime-check.nu, gen-install-from-manifests.py from the UNMAPPED gate in
# buck-test.nu, and buck-specs-check.py from its own .nu wrapper. Cutting this edge leaves two.
#
# BYTE IDENTICAL, and there is no room to argue about it: the render is compared against the
# COMMITTED traps_generated.rs, which the python wrote. Both --check modes agree on 29 wrappers,
# and the port was also verified to FAIL on a perturbed file, because a checker that cannot fail
# is worth nothing.

const OUT = "linux/server/src/xnu/traps_generated.rs"
const HEADER_GLOB = "buck-out/v2/art/root/*/vendor/pins/ciderd/__dserver_rpc__/*gen_include/ciderd/rpc.internal.h"

# C scalar types the RPC generator emits, mapped to what bindgen calls them in Rust.
# A type NOT in this table is an error rather than a guess: silently mapping an unknown type is
# how an ABI mismatch gets in.
const CTYPE = [["c" "rust"];
  ["uint64_t" "u64"]
  ["uint32_t" "u32"]
  ["uint16_t" "u16"]
  ["uint8_t" "u8"]
  ["int64_t" "i64"]
  ["int32_t" "i32"]
  ["int16_t" "i16"]
  ["int8_t" "i8"]
  ["int" "::std::os::raw::c_int"]
  ["unsigned int" "::std::os::raw::c_uint"]
  # C _Bool and Rust bool are both one byte, and bindgen maps the C one to the Rust one.
  ["bool" "bool"]]

def die [msg: string] {
  print -e $msg
  exit 1
}

def header-path [] {
  let hits = (glob $HEADER_GLOB)
  if ($hits | is-empty) {
    die "rpc.internal.h not built; run: buck2 build //vendor/pins/ciderd:dserver_rpc"
  }
  $hits | first
}

# Every wrapper in DSERVER_XNU_SYS_DEFS, as {name, params, struct, fields, trap}.
#
# THE MACRO IS ONE LOGICAL LINE, continued with backslashes, so the body is taken from the
# #define to the first blank line and the continuations are then removed. Reading it line by
# line instead would split every wrapper across the join.
def parse-header [header: string] {
  let text = (open --raw $header | decode utf-8)
  let m = ($text | parse --regex '(?s)#define DSERVER_XNU_SYS_DEFS \\\n(?<body>.*?)\n\n')
  if ($m | is-empty) {
    die "DSERVER_XNU_SYS_DEFS not found in the header; did the generator change?"
  }
  let body = ($m | get body.0 | str replace --all "\\\n" "\n")

  let defs = ($body | parse --regex
    '(?s)\tint xnu_sys_(?<name>\w+)\((?<raw_params>.*?)\)\s*\{\s*struct (?<struct>\w+) args = \{(?<raw_fields>.*?)\};\s*return (?<trap>\w+)\(&args\);')
  $defs | each {|d|
    let params = ($d.raw_params | split row "," | each {|x| $x | str trim }
      | where {|x| $x != "" } | each {|p|
        let pm = ($p | parse --regex '^(?<ctype>.*?)\s*(?<star>\*?)\s*(?<pname>\w+)$')
        if ($pm | is-empty) { die $"cannot parse parameter '($p)' of xnu_sys_($d.name)" }
        let ctype = ($pm | get ctype.0 | str trim)
        let row = ($CTYPE | where c == $ctype)
        if ($row | is-empty) {
          die $"unknown C type '($ctype)' in xnu_sys_($d.name); add it to CTYPE rather than guessing"
        }
        let base = ($row | get rust.0)
        { name: ($pm | get pname.0), rtype: (if ($pm | get star.0) == "*" { $"*mut ($base)" } else { $base }) }
      })
    let fields = ($d.raw_fields | parse --regex '\.(?<field>\w+)\s*=\s*(?<value>\w+)\s*,')
    { name: $d.name, params: $params, struct: $d.struct, fields: $fields, trap: $d.trap }
  }
}

def render [wrappers: list<any>] {
  mut lines = [
    # THE PROVENANCE LINE NAMES THIS FILE, so porting it changes the generated output by
    # exactly one line, and the committed traps_generated.rs is regenerated in the same commit.
    # Leaving the .py spelling would leave a generated file pointing at a script that no longer
    # exists, which buck-script-refs-check.nu catches by design.
    "//! GENERATED by scripts/gen-xnu-sys-traps.nu. Do not edit."
    "//!"
    "//! The Rust half of `xnu-sys/src/traps.c` (#71): the 29 wrappers that"
    "//! `DSERVER_XNU_SYS_DEFS` expands to in the C. Each packs its scalar arguments into an"
    "//! XNU trap-args struct and calls the trap."
    "//!"
    "//! Generated from the SAME table the C uses, the expansion of that macro in the built"
    "//! `ciderd/rpc.internal.h`, so the two cannot disagree. Writing them by hand"
    "//! would mean transcribing 29 signatures and about 90 field assignments, and a swapped"
    "//! field between two same-typed arguments would compile, link and return the wrong"
    "//! answer."
    ""
    "#![allow(clippy::too_many_arguments)]"
    ""
    "use crate::bindings::*;"
    ""
  ]
  for w in $wrappers {
    let arglist = ($w.params | each {|p| $"($p.name): ($p.rtype)" } | str join ", ")
    $lines = ($lines | append "#[no_mangle]")
    $lines = ($lines | append
      $"pub unsafe extern \"C\" fn xnu_sys_($w.name)\(($arglist)) -> ::std::os::raw::c_int {")
    $lines = ($lines | append $"    let mut args: ($w.struct) = ::std::mem::zeroed\();")
    for f in $w.fields {
      # `as _` reproduces the C's IMPLICIT conversion, with the target inferred from the field.
      # It is needed: the RPC table declares mach_port_mod_refs right as int32_t while the XNU
      # struct field is mach_port_right_t, a u32. C converts silently, Rust will not, and
      # writing the field type out here would be transcribing it.
      $lines = ($lines | append $"    args.($f.field) = ($f.value) as _;")
    }
    $lines = ($lines | append $"    ($w.trap)\(&mut args)")
    $lines = ($lines | append "}")
    $lines = ($lines | append "")
  }
  $lines | str join "\n"
}

def main [--check] {
  cd ($env.CURRENT_FILE | path dirname | path join "..")
  let wrappers = (parse-header (header-path))
  if ($wrappers | is-empty) {
    die "parsed zero wrappers, which cannot be right; the macro shape must have changed"
  }
  let text = (render $wrappers)

  if $check {
    if not ($OUT | path exists) {
      die $"($OUT) does not exist; run scripts/gen-xnu-sys-traps.nu"
    }
    if (open --raw $OUT | decode utf-8) != $text {
      die ($"($OUT) is STALE: the RPC table has moved since it was generated.\n"
        + "Re-run scripts/gen-xnu-sys-traps.nu and commit the result.")
    }
    print $"traps: ($wrappers | length) wrappers, committed file is up to date"
    exit 0
  }

  $text | save -f $OUT
  let nparams = ($wrappers | each {|w| $w.params | length } | math sum)
  let nfields = ($wrappers | each {|w| $w.fields | length } | math sum)
  print $"wrote ($OUT): ($wrappers | length) wrappers, ($nparams) parameters, ($nfields) field assignments"
  exit 0
}
