#!/usr/bin/env nu
# Run the Security cone inside the buck2-built Darling.
#
# Security is the largest cone the port builds that had never executed a single instruction: 38
# static archives, 5 dylibs and a 9.3MB framework binary. Its exported symbols list is what
# pulls the archive members onto the link at all -- nothing in Security_obj references SSLRead,
# so without the list ld drops libsecurity_ssl entirely -- which puts "it links" and "its code
# runs" further apart here than anywhere else.
#
# tests/buck2/guest/sec_probe.c is self-contained on purpose: a published digest and a
# certificate embedded as DER, so it needs no network, no keychain on disk and no clock that
# agrees with anybody. It walks up from the smallest thing in the cone to the largest:
#
#   CC_SHA256                       libcommonCrypto
#   SecRandomCopyBytes              Security's own entry points
#   CFDataCreate                    CoreFoundation underneath it
#   SecCertificateCreateWithData    the ASN.1 and x509 archives
#   SecCertificateCopySubjectSummary   decoding a name back out of the parsed cert
#
# Converted from bash (task #40) and verified by running BOTH versions against a real container
# and comparing every per-assertion line, the verdict and the exit code.
#
# Usage:  scripts/buck-security-check.nu [<scratch dir>]

def say [msg: string] { print -e $msg }

# --show-output prints one "<target> <path>" line per target, so the artifact is picked by which
# target names it rather than by position. One row per pattern, hence first: asking for the
# SECOND row is what made this report an empty missing-build-output the first time.
def artifact_for [rows: list, pat: string] {
    let hit = ($rows | where {|w| ($w | first) =~ $pat })
    if ($hit | is-empty) { "" } else { ($hit | first | get 1) }
}

def main [scratch?: string] {
    cd ($env.FILE_PWD | path join ".." | path expand)

    let root = ($scratch | default $"/tmp/darling-sec-(^id -u | str trim)")
    let rt = $"($root)/rt"
    let prefix_dir = $"($root)/prefix"

    if (which buck2 | is-empty) {
        say "missing buck2 -- run inside `nix develop`"
        exit 2
    }

    say "== building the prefix and the probe =="
    let b = (^buck2 build //buck/prefix:darling_prefix //tests/buck2/guest:sec_probe
        --show-output | complete)
    let rows = ($b.stdout | lines | each {|l| $l | split row " " } | where {|w| ($w | length) >= 2 })
    let art = (artifact_for $rows 'darling_prefix')
    let bin = (artifact_for $rows 'sec_probe')
    for f in [$art $bin] {
        if ($f | is-empty) or (not ($f | path exists)) {
            say $"missing build output: ($f)"
            exit 1
        }
    }

    for p in (ls /proc | get name | where {|n| ($n | path basename) =~ '^[0-9]+$' }) {
        let exe = (do -i { ^readlink $"($p)/exe" | str trim } | default "")
        if ($exe | str starts-with $"($root)/") {
            do -i { ^kill -9 ($p | path basename) }
        }
    }

    say $"== materializing into ($rt) =="
    do -i { ^chmod -R u+w $rt }
    # GNU rm: the overlay workdir holds a `work` directory at mode 000 that nushell's
    # remove_dir_all cannot enter.
    ^rm -rf $rt $prefix_dir $"($prefix_dir).workdir"
    mkdir $rt $prefix_dir
    # `cp -a`, never `cp -aL`: the prefix installs Volumes/DarlingEmulatedDrive -> /.
    ^cp -a $"($art)/." $"($rt)/"
    ^chmod -R u+w $rt
    ^cp $bin $"($rt)/libexec/darling/usr/bin/sec_probe"
    ^chmod +x $"($rt)/libexec/darling/usr/bin/sec_probe"

    say "== running the probe inside the container =="
    let r = (
        with-env {
            DPREFIX: $prefix_dir
            DARLING_NO_LAUNCHD: "1"
            DSERVER_LIBEXEC_PATH: $"($rt)/libexec/darling"
            DSERVER_MLDR_PATH: $"($rt)/libexec/darling/usr/libexec/darling/mldr"
        } {
            ^timeout 200 $"($rt)/bin/darling" shell /usr/bin/sec_probe | complete
        }
    )
    let out = ($"($r.stdout)($r.stderr)" | str trim --right --char "\n")
    $out | lines | where {|l| $l =~ "SEC_PROBE" } | each {|l| print $l }

    # Each step is asserted separately, so a regression says WHICH layer broke rather than that
    # the cone stopped working.
    let checks = [
        ["SEC_PROBE sha256=correct", "libcommonCrypto computes the published SHA-256 of abc"]
        ["SEC_PROBE random rc=0 nonzero=1", "SecRandomCopyBytes returns entropy"]
        ["SEC_PROBE cfdata=801", "CoreFoundation wraps the DER bytes"]
        ["SEC_PROBE certificate=parsed", "SecCertificateCreateWithData parses a real certificate"]
        ["SEC_PROBE subject=darling-buck2-probe", "the certificate's subject decodes back out"]
        ["SEC_PROBE_DONE", "the probe ran to completion"]
    ]
    mut fail = false
    for c in $checks {
        if ($out | str contains ($c | first)) {
            say $"ok   ($c | last)"
        } else {
            say $"FAIL ($c | last)"
            $fail = true
        }
    }

    if not $fail {
        say "PASS: the Security cone runs"
        exit 0
    }
    say "FAIL: see above"
    exit 1
}
