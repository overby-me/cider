#!/usr/bin/env nu
# Load every scripting-language extension the prefix ships, inside the buck2-built Darling.
#
# This is the widest runtime probe in the tree by artifact count. python's 56 lib-dynload
# extensions, zsh's 35 loadable modules and perl's XS modules are each a separate Mach-O
# that buck2 built, linked and installed -- and until this ran, every one of them had been
# checked only for "does it link". Loading a module executes its initializer, resolves its
# symbols against the frameworks underneath, and returns something the interpreter can use,
# which is a great deal more than a link check.
#
# Counts rather than pass/fail per module: a handful of extensions can legitimately fail on
# a system without the thing they wrap. What matters is the number, and that it does not
# drop. Thresholds below are the measured floor, not an aspiration.
#
# Usage:  scripts/buck-scripting-check.nu [<scratch dir>]
#
# Converted from bash (task #40). The five GUEST scripts below stay python, zsh and perl and are
# embedded verbatim, lifted out of the .sh programmatically rather than retyped; only the
# host-side harness is nushell. Verified by running BOTH versions against a real container and
# diffing the whole output, which is five per-cone results plus the verdict.

def say [msg: string] { print -e $msg }

# One container invocation. out+err> into a file rather than `complete`, so the guest and daemon
# lines keep their order, which is what 2>&1 gave the bash version.
def run_guest [rt: string, prefix_dir: string, argv: list] {
    let log = (mktemp --tmpdir buck-scripting-check.XXXXXX)
    with-env {
        DPREFIX: $prefix_dir
        DARLING_NO_LAUNCHD: "1"
        DSERVER_LIBEXEC_PATH: $"($rt)/libexec/cider"
        DSERVER_MLDR_PATH: $"($rt)/libexec/cider/usr/libexec/cider/mldr"
    } {
        do -i { ^timeout 300 $"($rt)/bin/cider" shell ...$argv out+err> $log }
    }
    let out = (open --raw $log | str trim --right --char "\n")
    rm -f $log
    $out
}

# "<TAG> <ok>/<total>" out of a transcript, defaulting to 0 and ? the way the sed did.
def parse_result [out: string, tag: string] {
    let hit = ($out | lines | where {|l| $l starts-with $"($tag) " })
    if ($hit | is-empty) {
        {ok: 0, tot: "?"}
    } else {
        let parts = ($hit | first | str replace $"($tag) " "" | split row "/")
        {ok: (($parts | get 0? | default "0") | into int), tot: ($parts | get 1? | default "?")}
    }
}

def main [scratch?: string] {
    cd ($env.FILE_PWD | path join ".." | path expand)

    let root = ($scratch | default $"/tmp/cider-script-(^id -u | str trim)")
    let rt = $"($root)/rt"
    let prefix_dir = $"($root)/prefix"

    if (which buck2 | is-empty) {
        say "missing buck2 -- run inside `nix develop`"
        exit 2
    }

    say "== building the prefix =="
    let b = (^buck2 build //buck/prefix:cider_prefix --show-output | complete)
    let art = ($b.stdout | lines | last | default "" | split row " " | get 1? | default "")
    if ($art | path type) != "dir" {
        say "the prefix did not build"
        exit 1
    }

    # Anything still running from a previous run holds the old prefix mounted.
    for p in (ls /proc | get name | where {|n| ($n | path basename) =~ '^[0-9]+$' }) {
        let exe = (do -i { ^readlink $"($p)/exe" | str trim } | default "")
        if ($exe | str starts-with $"($root)/") {
            do -i { ^kill -9 ($p | path basename) }
        }
    }

    say $"== materializing into ($rt) =="
    do -i { ^chmod -R u+w $rt }
    # GNU rm: the overlay workdir holds a `work` directory at mode 000.
    ^rm -rf $rt $prefix_dir $"($prefix_dir).workdir"
    mkdir $rt $prefix_dir
    # `cp -a`, never `cp -aL`: the prefix installs Volumes/DarlingEmulatedDrive -> /.
    ^cp -a $"($art)/." $"($rt)/"
    ^chmod -R u+w $rt

    mut fail = false

    say "== python: import every lib-dynload extension =="
    let out_py = (run_guest $rt $prefix_dir ["/usr/bin/python2.7" "-c" '
import os, sys
d = "/System/Library/Frameworks/Python.framework/Versions/2.7/lib/python2.7/lib-dynload"
mods = sorted(f.split(".")[0] for f in os.listdir(d) if f.endswith(".so"))
ok, bad = 0, []
for m in mods:
    try:
        __import__(m)
        ok += 1
    except Exception as e:
        bad.append("%s: %s" % (m, e))
print("PY_RESULT %d/%d" % (ok, len(mods)))
for b in bad:
    print("PY_FAIL " + b)
'])
    $out_py | lines | where {|l| $l =~ '^PY_(RESULT|FAIL)' } | each {|l| print $l }
    let py = (parse_result $out_py "PY_RESULT")
    # 55 of 56, and the one that fails is the reference own _sqlite.so, whose init symbol is
    # init_sqlite3 rather than init_sqlite -- left in place deliberately so nothing the
    # reference ships disappears, with the working copy installed alongside as _sqlite3.so.
    if $py.ok >= 55 {
        say $"ok   python imported ($py.ok)/($py.tot) extension modules \(floor 55)"
    } else {
        say $"FAIL python imported ($py.ok)/($py.tot) extension modules, floor is 55"
        $fail = true
    }

    say "== python: sqlite3 actually works =="
    let out_sq = (run_guest $rt $prefix_dir ["/usr/bin/python2.7" "-c" '
import sqlite3
c = sqlite3.connect(":memory:")
c.execute("create table t (a int, b text)")
c.execute("insert into t values (?, ?)", (42, "hello"))
print("SQLITE_OK lib=%s row=%r" % (sqlite3.sqlite_version, c.execute("select * from t").fetchone()))
'])
    $out_sq | lines | where {|l| $l =~ '^SQLITE_OK' } | each {|l| print $l }
    if ($out_sq | str contains "SQLITE_OK") and ($out_sq | str contains "(42, u'hello')") {
        say "ok   python sqlite3 opens a database and round-trips a row"
    } else {
        say $"FAIL python sqlite3 did not work: ($out_sq)"
        $fail = true
    }

    say "== zsh: zmodload every module =="
    let out_zs = (run_guest $rt $prefix_dir ["/bin/zsh" "-c" '
setopt no_err_exit 2>/dev/null
ok=0; tot=0
for f in /usr/lib/zsh/5.7.1/zsh/*.so; do
  tot=$((tot+1))
  m="zsh/${f:t:r}"
  if zmodload "$m" 2>/dev/null; then ok=$((ok+1)); else print "ZSH_FAIL $m"; fi
done
print "ZSH_RESULT $ok/$tot"
'])
    $out_zs | lines | where {|l| $l =~ '^ZSH_(RESULT|FAIL)' } | each {|l| print $l }
    let z = (parse_result $out_zs "ZSH_RESULT")
    if $z.ok >= 30 {
        say $"ok   zsh loaded ($z.ok)/($z.tot) modules \(floor 30)"
    } else {
        say $"FAIL zsh loaded ($z.ok)/($z.tot) modules, floor is 30"
        $fail = true
    }

    say "== perl: load the XS modules =="
    let out_pl = (run_guest $rt $prefix_dir ["/usr/bin/perl" "-e" '
my @m = qw(POSIX Socket Fcntl List::Util Storable Encode Data::Dumper Time::HiRes
           Digest::MD5 Digest::SHA MIME::Base64 Compress::Raw::Zlib Cwd File::Glob);
my ($ok, @bad) = (0);
for my $m (@m) { eval "require $m; 1" ? $ok++ : push @bad, "$m: $@"; }
print "PL_RESULT $ok/" . scalar(@m) . "\n";
print "PL_FAIL $_\n" for @bad;
'])
    $out_pl | lines | where {|l| $l =~ '^PL_(RESULT|FAIL)' } | each {|l| print $l }
    let p = (parse_result $out_pl "PL_RESULT")
    if $p.ok >= 14 {
        say $"ok   perl loaded ($p.ok)/($p.tot) XS modules \(floor 14)"
    } else {
        say $"FAIL perl loaded ($p.ok)/($p.tot) XS modules, floor is 14"
        $fail = true
    }

    say "== perl: Storable actually round-trips =="
    let out_st = (run_guest $rt $prefix_dir ["/usr/bin/perl" "-e" '
use Storable qw(freeze thaw);
my $d = thaw(freeze({a => 1, b => [2, 3]}));
print "STORABLE_OK $Storable::VERSION b1=$d->{b}[1]\n";
'])
    $out_st | lines | where {|l| $l =~ '^STORABLE_OK' } | each {|l| print $l }
    if ($out_st | str contains "STORABLE_OK 2.41 b1=3") {
        say "ok   perl Storable freezes and thaws a nested structure"
    } else {
        say $"FAIL perl Storable did not round-trip: ($out_st)"
        $fail = true
    }

    if not $fail {
        say "PASS: the scripting cones load their extensions"
        exit 0
    }
    say "FAIL: see above"
    exit 1
}
