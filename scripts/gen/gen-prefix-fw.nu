#!/usr/bin/env nu

# DERIVE THE FRAMEWORK-TIER PREFIX FROM THE GENERATED FULL ONE.
#
# Sibling of gen-prefix-min.nu, and derived the same way (drop-by-exclusion from buck/prefix/BUCK),
# but for the NEXT milestone: guest nix builds a package. That needs the CoreFoundation/CoreServices/
# SystemConfiguration/Foundation stack and its ~210-dylib re-export closure, which prefix-min drops.
# So this tier KEEPS System/Library/Frameworks and PrivateFrameworks (and src/darwin/frameworks),
# and drops only the two framework dylibs that do not build for arm64 (JavaScriptCore, DBusKit --
# pass 31: 210/212 build, nix needs neither) plus the same scripting/docs/unneeded-tool cones
# prefix-min drops. It exists so the framework closure can be built OMD-immune through the nix
# endpoint (nix-daemon's cgroup), instead of the host buck2 overlay systemd-oomd kills.
#
# The goal the MINIMAL sibling serves is narrower: a prefix that boots and runs bash. Everything the
# full prefix installs for GUI, ObjC frameworks and scripting languages is dead weight for THAT, and
# it is most of the build:
#
#   src/darwin/frameworks          8,142 actions   29.5% of the graph
#   src/darwin/private-frameworks  2,250 actions    8.2%
#   perl python pyobjc ruby    1,197 actions    4.3%
#
# buck/prefix/BUCK is GENERATED from the reference build cmake manifests by
# cider-install-from-manifests, so it is not edited by hand and neither is this
# sibling. This reads it, drops the entries whose target lives in an excluded package, drops the
# symlinks those entries orphan, and writes buck/prefix-fw/BUCK.
#
# The exclusion tables are gen-prefix-min.nu's, minus the framework exclusions (this tier keeps
# frameworks) and plus the two non-building framework dylibs (JavaScriptCore, DBusKit).
#
# THE EXCLUSION TABLES WERE NOT RETYPED from scratch. They are many values across four lists, and hand
# copying them is exactly where a silent one-character error would live, so they were emitted
# mechanically from the python literals with their comments kept, and then checked by dumping
# both sides to JSON and diffing: 8, 101, 6 and 15 values, equal.

const EXCLUDE_PKGS = [
    # Frameworks are KEPT in this tier (its whole purpose) -- unlike prefix-min, //src/darwin/frameworks
    # and //src/darwin/private-frameworks are NOT excluded here.
    "//vendor/src/python"
    "//vendor/src/python_modules"
    "//vendor/src/pyobjc"
    "//vendor/src/perl"
    "//vendor/src/ruby"
    # zsh's 35 loadable modules. Removing the zsh BINARY by label left these installed at
    # usr/lib/zsh/5.7.1/zsh/*.so, orphaned: nothing can load them. This is also the omission
    # docs/changelog.md recorded from the start, that the prose claimed the scripting languages were
    # excluded while the list omitted //vendor/src/zsh. Closed at the package level.
    "//vendor/src/zsh"
]

const EXCLUDE_LABELS = [
    # The swift and swiftc launchers, which select a toolchain that is not installed. Same
    # reasoning as the runtime dylibs under EXCLUDE_DEST: nix does not need Swift to start.
    "//src/darwin/xcselect:swift_shim"
    "//src/darwin/xcselect:swiftc_shim"

    "//vendor/src:jsc"

    # The two FRAMEWORK dylibs that do not build for arm64 (pass 31: 210/212 build, only these two
    # fail), and nix needs neither. Every other framework dylib under System/Library/Frameworks and
    # PrivateFrameworks stays; their framework-structure symlinks orphan-drop in the second pass.
    "//vendor/src:JavaScriptCore_dylib"
    "//vendor/src:DBusKit_dylib"

    # Userland tools nix can FETCH once it runs. The prefix exists to get nix up; anything
    # nix could install afterwards is being paid for twice, once here and once in the store.
    # None of these participates in booting the container or in running bash.
    #
    # Editors, pagers, shells other than bash, terminal multiplexers.
    "//vendor/src:vim"
    "//vendor/src:nano"
    "//vendor/src:less"
    "//vendor/src:tcsh"
    "//vendor/src:zsh"
    "//vendor/src:ash"
    "//vendor/src/screen:screen"
    # Archivers and compressors.
    "//vendor/src:gnutar"
    "//vendor/src:zip"
    "//vendor/src:unzip"
    "//vendor/src:unzipsfx"
    "//vendor/src:xz"
    "//vendor/src:pax"
    # Network clients and daemons.
    "//vendor/src:sshd"
    "//vendor/src:rsync"
    "//vendor/src:netstat"
    "//vendor/src:cupsd"
    # Misc userland.
    "//vendor/src:top"
    "//vendor/src:mail"
    "//vendor/src:patch"
    "//vendor/src/file:file"
    "//vendor/src:otool"
    "//vendor/src:hdiutil"
    "//vendor/src:installer"
    "//vendor/src/groff:eqn"
    "//vendor/src:cal"
    "//vendor/src:ncal"
    "//vendor/src:latency"
    "//vendor/src:sc_usage"

    # The GUI cone, reached through three small tools. pbcopy, pbpaste and open are the ONLY
    # prefix entries that reach AppKit or CoreImage (checked by walking every entry's cone),
    # and between them they pull 752 actions of framework into a prefix defined as having no
    # GUI frameworks. Same shape as jsc: a small tool carrying a large cone.
    "//src/darwin/pboard:pbcopy"
    "//src/darwin/pboard:pbpaste"
    "//src/darwin/tools:open"

    # The SUPERSEDED libcrypto/libssl/libtls versions. Darling ships five libcrypto builds for
    # binary compatibility with guest software linking a specific versioned dylib. Only
    # crypto44 has real consumers -- curl_dylib, curlexe, openssl, scp, sftp -- and the other
    # four are self-contained islands, each linked solely by its own ssl/tls sibling:
    #   crypto098 505 + ssl098 44                = 549
    #   crypto35  543 + ssl35  43 + tls6      6  = 592
    #   crypto41  544 + ssl43  38 + tls15    10  = 592
    #   crypto42  539 + ssl44  38 + tls16    10  = 587
    # 2,320 actions for versions nothing in this prefix links. nix carries its own openssl in
    # its store closure, so it needs none of them; the system curl needs crypto44/ssl46/tls18,
    # which stay.
    "//vendor/src:crypto098_dylib"
    "//vendor/src:ssl098_dylib"
    "//vendor/src:crypto35_dylib"
    "//vendor/src:ssl35_dylib"
    "//vendor/src:tls6_dylib"
    "//vendor/src:crypto41_dylib"
    "//vendor/src:ssl43_dylib"
    "//vendor/src:tls15_dylib"
    "//vendor/src:crypto42_dylib"
    "//vendor/src:ssl44_dylib"
    "//vendor/src:tls16_dylib"

    # The security DAEMONS and the security CLI. Together about 1,390 actions: secd alone is
    # 738 exclusive and additionally pulls CloudKit 257 and AppleAccount 235, and with
    # securitytool it pulls SecurityFoundation 161.
    #
    # The question is not what nix NEEDS, it is what nix needs TO START; once installed it
    # pulls anything else from nixpkgs. Read tests/nix-in-cider.nix for what the guest
    # actually does: the HOST downloads and extracts the installer tarball and copies it in,
    # then the guest runs `bash -x install --no-daemon` followed by nix --version,
    # nix-instantiate --eval, nix eval, nix-store --verify and a trivial derivation. NONE of
    # that does network I/O, so there is no TLS, no trust evaluation and no keychain on the
    # bootstrap path.
    #
    # This cannot regress anything currently verified, and that is checkable rather than
    # hopeful: nix-in-cider runs against the cmake-built FULL `cider`, not this prefix, so
    # no existing test exercises nix here. And Security.framework itself is ALREADY absent from
    # this prefix (0 entries reach Security_dylib; it lives under System/Library/Frameworks,
    # which EXCLUDE_DEST drops), so if nix needed it the minimal prefix was already unable to
    # run nix, independently of these four.
    #
    # If nix-in-guest is ever pointed at this prefix and turns out to need Security, the fix is
    # the Security DYLIB, which is a different and much smaller thing than these daemons.
    "//vendor/src:secd"
    "//vendor/src:securityd_exe"
    "//vendor/src:trustd"
    "//vendor/src:securitytool_macos"

    # The OpenSSH suite, and with it openbsd_compat (82 actions, reached by nothing else).
    "//vendor/src:ssh"
    "//vendor/src:scp"
    "//vendor/src:sftp"
    "//vendor/src:sftp-server"
    "//vendor/src:ssh-add"
    "//vendor/src:ssh-agent"
    "//vendor/src:ssh-keygen"
    "//vendor/src:ssh-keyscan"
    "//vendor/src:ssh-keysign"
    "//vendor/src:ssh-pkcs11-helper"
    "//vendor/src:sshd-keygen-wrapper"

    # curl, openssl and the LAST libcrypto. Keeping crypto44 was justified earlier by "curl
    # needs it", which was the wrong question: the bootstrap does no network I/O, so CURL is
    # not needed either, and the whole chain goes. crypto44_obj alone is 543 actions, the
    # single largest item left in the prefix, plus curl_obj 135.
    "//vendor/src:curlexe"
    "//vendor/src:curl_dylib"
    "//vendor/src:openssl"
    "//vendor/src:crypto44_dylib"
    "//vendor/src:ssl46_dylib"
    "//vendor/src:tls18_dylib"

    # The Berkeley DB command line tools: 225 actions of berkeley_db_obj reached by these
    # twelve and nothing else.
    "//vendor/src:db_archive"
    "//vendor/src:db_checkpoint"
    "//vendor/src:db_codegen"
    "//vendor/src:db_deadlock"
    "//vendor/src:db_dump"
    "//vendor/src:db_hotbackup"
    "//vendor/src:db_load"
    "//vendor/src:db_printlog"
    "//vendor/src:db_recover"
    "//vendor/src:db_stat"
    "//vendor/src:db_upgrade"
    "//vendor/src:db_verify"

    # The BIND DNS diagnostic tools: bind9_dns_obj 84 and bind9_isc_obj 82 are reached by
    # these six and nothing else. Resolution itself is libnetwork/libc, not these.
    "//vendor/src:dig"
    "//vendor/src:host"
    "//vendor/src:nslookup"
    "//vendor/src:nsupdate"
    "//vendor/src:delv"
    "//vendor/src:ddns-confgen"

    # libarchive's tools (archive_obj 115) and the Apache Portable Runtime (apr_obj 82).
    # I flagged these as a residual risk on the grounds that the nix installer might shell out
    # to tar. It does not, and the evidence was already in tests/nix-in-cider.nix when I
    # wrote that: EVERY extraction step is on the HOST. The host curls the tarball, the host
    # runs `tar -xf`, the host `cp -a`s the extracted directory into the prefix, and the guest
    # then runs `install --no-daemon` over plain files. That installer copies $self/store into
    # /nix/store with `cp -RPp` and loads the DB from .reginfo; there is no archive left to
    # unpack guest-side. No tar is needed in the guest.
    "//vendor/src:bsdtar"
    "//vendor/src:cpio"
    # and libarchive itself, which after those two is installed for its own sake
    # with nothing left consuming it.
    "//vendor/src:archive_dylib"
    "//vendor/src:apr_dylib"
    "//vendor/src:aprutil_dylib"

    # The ncurses ADD-ON libraries. libform, libmenu and libpanel are the form, menu and
    # panel toolkits; their consumers were vim, less, top and screen, all removed. ncurses
    # itself stays, since 60-odd entries still reach it.
    "//vendor/src:form_dylib"
    "//vendor/src:menu_dylib"
    "//vendor/src:panel_dylib"

    # launchd plists whose Program no longer exists, orphaned by the removals above. launchd
    # would try to spawn each of these at boot and fail. THE SMOKE TEST CANNOT CATCH THIS: it
    # runs with DARLING_NO_LAUNCHD=1, so the job graph is never exercised. Found by reading
    # each plist Program/ProgramArguments and checking it against the install destinations.
    "//vendor/src:security_OSX_sec_ipc_com.apple.secd.plist"
    "//vendor/src:security_securityd_etc_com.apple.securityd.plist"
    "//vendor/src:security_trust_trustd_macOS_com.apple.trustd.plist"
    "//vendor/src:security_trust_trustd_macOS_com.apple.trustd.agent.plist"
    "//vendor/src:openssh_com.openssh.ssh-agent.plist"
    "//vendor/src:openssh_com.openssh.sshd.plist"
    "//vendor/src:cups_cups_scheduler_org.cups.cupsd.plist"
    # and cups-lpd, whose Program lives under the usr/libexec/cups tree that
    # EXCLUDE_DEST now drops. Caught by buck-prefix-consistency.nu, not by hand.
    "//vendor/src:cups_cups_scheduler_org.cups.cups-lpd.plist"
]

const EXCLUDE_SRC = [
    # frameworks/ and private-frameworks/ sources are KEPT in this tier.
    "vendor/src/python"
    "vendor/src/pyobjc/"
    "vendor/src/perl/"
    "vendor/src/ruby/"
]

const EXCLUDE_DEST = [
    # System/Library/Frameworks and PrivateFrameworks destinations are KEPT in this tier.
    "libexec/cider/usr/lib/python"
    "libexec/cider/System/Library/Perl/"

    # Documentation. 810 entries, 44 percent of everything the prefix still installs, and
    # ZERO build actions: they are file copies. They cost prefix SIZE and assembly time, not
    # compile time, and a prefix whose job is to get nix started has no reader for them.
    "libexec/cider/usr/share/man/"

    # DATA ORPHANED BY THE BINARY REMOVALS. Each of these is config or runtime support for a
    # program that is no longer installed, so it is unreachable rather than merely unused.
    # Same class as the dangling symlinks and the launchd plists, just without a reference to
    # make it detectable.
    "libexec/cider/usr/share/cups/",       # cupsd is gone
    "libexec/cider/usr/libexec/cups/",     # 85 actions, the only one of these that compiles
    "libexec/cider/private/etc/cups/"
    "libexec/cider/usr/share/vim/",        # vim is gone
    "libexec/cider/private/etc/ssh/",      # the ssh suite is gone
    "libexec/cider/private/etc/ssl/",      # openssl is gone
    "libexec/cider/usr/share/file/",       # file(1) is gone
    "libexec/cider/usr/lib/sasl2/",        # SASL plugins, for the mail and ssh world
    "libexec/cider/System/Library/Components/",  # the CoreAudio component

    # THE SWIFT RUNTIME, 44 dylibs. Zero build actions, since they are file copies, so this is
    # not a speed removal, it is a correctness one, and it is the safest removal in this file.
    # Every one of those dylibs is a 131-byte GIT LFS POINTER rather than a library (task #39).
    # So a 131-byte text file named libswiftCoreGraphics.dylib is either never loaded, in which
    # case dropping it changes nothing, or it IS loaded and fails, in which case it is already
    # broken. There is no state in which it currently works, so removal cannot regress anything.
    # On the standing criterion it would go anyway: nix does not need Swift to start, and once
    # nix runs it can pull a real Swift from nixpkgs rather than a pointer file.
    "libexec/cider/usr/lib/swift/"
]

def say [msg: string] { print $msg }
def say-err [msg: string] { print -e $msg }

const LABEL_RE = '"\s*:\s*"(//[^"]+)"'
const DEST_RE = '^\s*"([^"]+)"\s*:'
const VALUE_RE = ':\s*"([^"]+)"'

def starts-any [s: string, prefixes: list<string>] {
  $prefixes | any {|p| $s | str starts-with $p }
}

def excluded [line: string] {
  let m = ($line | parse --regex $LABEL_RE)
  if ($m | is-not-empty) {
    let label = ($m | get capture0.0)
    if (starts-any $label $EXCLUDE_PKGS) { return true }
    if ($label in $EXCLUDE_LABELS) { return true }
  }
  let d = ($line | parse --regex $DEST_RE)
  if ($d | is-not-empty) and (starts-any ($d | get capture0.0) $EXCLUDE_DEST) { return true }
  # `files` and `trees` map a destination to a repo-relative SOURCE, not a label.
  if ($m | is-empty) {
    let v = ($line | parse --regex $VALUE_RE)
    if ($v | is-not-empty) and (starts-any ($v | get capture0.0) $EXCLUDE_SRC) { return true }
  }
  false
}

def main [] {
  # Two levels: this script lives in scripts/gen/, and buck/prefix/BUCK is at the repo root.
  cd ($env.CURRENT_FILE | path dirname | path join ".." "..")
  let src = "buck/prefix/BUCK"
  if not ($src | path exists) {
    say-err $"no generated prefix at ($src)"
    exit 1
  }
  mkdir buck/prefix-fw

  # SPLIT ON \n AND KEEP IT, because the python iterates a file object, so every element still
  # carries its newline and the join is a plain concatenation. Losing that would move every
  # line ending in the output.
  let all = (open --raw $src | decode utf-8 | split row "\n")
  mut kept = []
  mut dropped = 0
  for line in $all {
    if (($line | str trim --left) | str starts-with '"') and (excluded $line) {
      $dropped = $dropped + 1
      continue
    }
    $kept = ($kept | append $line)
  }

  # SECOND PASS: drop symlinks whose target is no longer installed.
  #
  # Removing a binary silently orphans its aliases, because a multi-call binary is shipped once
  # and symlinked under its other names. Dropping `installer` left lsbom, pkgutil and
  # uninstaller pointing at nothing; dropping `less` left `more`; dropping `unzip` left
  # `zipinfo`. Five dangling links, and the prefix would have installed every one of them.
  #
  # That is #41 all over again (eight krb5 .dylib symlinks that dangled), so it is fixed here
  # rather than by naming the five: any future exclusion gets the same treatment for free.
  mut body = ($kept | str join "\n")
  mut installed = []
  for sec in ["entries" "files" "trees"] {
    let re = '(?ms)^\s+' + $sec + ' = \{(.*?)^\s+\},'
    let m = ($body | parse --regex $re)
    if ($m | is-not-empty) {
      $installed = ($installed | append (($m | get capture0.0)
        | parse --regex '(?m)^\s*"([^"]+)"\s*:' | get capture0))
    }
  }
  let installed = ($installed | uniq)

  let sm = ($body | parse --regex '(?ms)^\s+symlinks = \{(.*?)^\s+\},')
  if ($sm | is-not-empty) {
    let orphans = (($sm | get capture0.0) | split row "\n" | where {|line|
      let m = ($line | parse --regex '^\s*"([^"]+)"\s*:\s*"([^"]+)"')
      ($m | is-not-empty) and (not (($m | get capture1.0) in $installed))
    })
    if ($orphans | is-not-empty) {
      # THE TRAILING NEWLINE GOES WITH IT. python iterates splitlines(True), so its `line`
      # still carries the "\n" and removing it removes the whole line; splitting on "\n" here
      # does not, so replacing the text alone left five EMPTY LINES in the output.
      for line in $orphans { $body = ($body | str replace ($line + "\n") "") }
      $dropped = $dropped + ($orphans | length)
      let names = ($orphans | each {|o|
        ($o | parse --regex '^\s*"([^"]+)"' | get capture0.0 | split row "/" | last)
      } | str join ", ")
      say-err $"prefix-fw: dropped ($orphans | length) symlink\(s) orphaned by an excluded target: ($names)"
    }
  }
  $body = ($body | str replace 'name = "cider_prefix"' 'name = "cider_prefix_fw"')
  let header = ("# GENERATED by scripts/gen/gen-prefix-fw.nu from buck/prefix/BUCK -- do not edit.\n"
    + "#\n"
    + "# The full prefix minus the scripting languages, docs and userland tools nix does not\n"
    + "# need to build a package, and minus the two framework dylibs that do not build for arm64\n"
    + "# (JavaScriptCore, DBusKit). Unlike prefix-min it KEEPS the framework stack, so guest nix\n"
    + "# can load CoreFoundation/CoreServices/SystemConfiguration/Foundation. Parity lives in\n"
    + "# //buck/prefix:cider_prefix, which is unchanged.\n"
    + $"# Entries dropped from the full prefix: ($dropped).\n")
  $body = ($body | str replace ("# GENERATED from the reference build's cmake_install.cmake manifests by\n"
    + "# cider-install-from-manifests -- review before committing.\n") $header)

  # THE PATH python PRINTS, which is os.path.join(scripts/.., ...) and keeps the "/.." in it.
  # Cosmetic, and reproduced anyway: the two outputs are compared line for line.
  let dst = "buck/prefix-fw/BUCK"
  let dst_printed = (($env.CURRENT_FILE | path dirname) + "/../../buck/prefix-fw/BUCK")
  $body | save -f $dst

  let total = ($all | where {|l| ($l | str trim --left) | str starts-with '"' } | length)
  say $"prefix-fw: dropped ($dropped) of ($total) entries \(((100 * $dropped) // ([$total 1] | math max)) percent), wrote ($dst_printed)"
  if $dropped == 0 {
    say-err "prefix-fw: nothing was dropped, the exclusion list is wrong"
    exit 1
  }

  # A generated prefix that REFERS to something it does not install is a defect, and both kinds
  # of reference have already bitten: five symlinks orphaned by removing a multi-call binary,
  # then seven launchd plists whose Program went with the daemon. The symlink half is fixed
  # above by construction; the plist half cannot be, because a plist Program lives in its source
  # file rather than in this BUCK file. So the check runs HERE, and generation fails rather than
  # emitting a prefix someone would only find broken at boot.
  let checker = "scripts/buck-prefix-consistency.nu"
  if ($checker | path exists) {
    let r = (do -i { ^nu $checker --prefix "buck/prefix-fw/BUCK" } | complete)
    if $r.exit_code != 0 {
      say-err $r.stdout
      say-err "prefix-fw: the generated prefix refers to something it does not install; exclude the referring entry too (see the FAIL lines above)"
      exit 1
    }
  }
  exit 0
}
