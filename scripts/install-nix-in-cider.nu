#!/usr/bin/env nu
# install-nix-in-cider.nu: automated Nix installer for Darling prefixes
#
# This script installs the Nix package manager inside a Darling (macOS compatibility layer)
# prefix, working around the various incompatibilities between Darling's environment and the
# official Nix Darwin installer.
#
# Converted from bash (task #40) and verified against it with curl, tar and cider stubbed on
# PATH, no container and no network: a full install, an existing /nix/store answered n and then
# y, a download that fails, an extraction with no install script, an installer run that fails,
# --offline, --no-channel, --no-verify, and a verification with a failing check. Output, the
# files written into the prefix, the PATCHED installer script and the exit code all match.
#
# The five installer patches stay as external sed invocations, verbatim. One of them is a RANGE
# address carrying four delete commands, scoped between --no-daemon) and its fi, and rewriting
# that in nushell would be a reimplementation rather than a conversion. The patched installer is
# compared byte for byte in the harness, which is the check that matters.
#
# Usage:
#   ./scripts/install-nix-in-cider.nu [OPTIONS]
#
# Options:
#   --prefix <path>       Darling prefix path (default: ~/.cider)
#   --nix-version <ver>   Nix version to install (default: latest stable)
#   --no-channel          Skip channel setup after installation
#   --no-verify           Skip post-install verification
#   --offline             No binary substitution, no channel setup
#
# --help prints nushell's own signature help rather than this header, and an unknown option is
# rejected by nushell's parser with exit 1 where bash printed its own message and exited 1 too.

def say [c: record, msg: string] { print $"($c.green)[cider-nix]($c.reset) ($msg)" }
def warn [c: record, msg: string] { print -e $"($c.yellow)[cider-nix] WARNING:($c.reset) ($msg)" }
def err_ [c: record, msg: string] { print -e $"($c.red)[cider-nix] ERROR:($c.reset) ($msg)" }

def colours [] {
    if (is-terminal --stdout) {
        {red: (ansi red), green: (ansi green), yellow: (ansi yellow), blue: (ansi blue)
         bold: (ansi attr_bold), reset: (ansi reset)}
    } else {
        {red: "", green: "", yellow: "", blue: "", bold: "", reset: ""}
    }
}

# A LIST, not rest arguments: nushell parses a def's rest arguments against its signature, so a
# guest flag like -productVersion would be rejected as a flag on this command.
def dsh [argv: list<string>] {
    ^cider shell ...$argv | complete
}

# Run a command inside the Darling prefix with bash -lc (for the Nix profile).
def dsh_bash [cmd: string] {
    ^cider shell bash -lc $cmd | complete
}

def main [
    --prefix: string = ""       # Darling prefix path (default: ~/.cider)
    --nix-version: string = ""  # Nix version to install (default: latest stable)
    --no-channel                # skip channel setup after installation
    --no-verify                 # skip post-install verification
    --offline                   # no binary substitution, no channel setup
] {
    let c = (colours)
    let cider_prefix = if ($prefix | is-not-empty) {
        $prefix
    } else {
        ($env | get -o DPREFIX | default ($env.HOME | path join ".cider"))
    }
    let url_base = "https://releases.nixos.org/nix"

    # -- Step 0: prerequisite checks -----------------------------------------
    say $c $"($c.bold)Step 0: Checking prerequisites...($c.reset)"

    if (which cider | is-empty) {
        err_ $c "cider is not installed or not in PATH.\n   Install it with: nix build .#cider"
        exit 1
    }

    if ($cider_prefix | path type) != "dir" {
        say $c $"Prefix ($cider_prefix) does not exist; initialising..."
        do -i { ^cider shell true } | ignore
        sleep 2sec
    }
    if ($cider_prefix | path type) != "dir" {
        err_ $c $"Failed to initialise Darling prefix at ($cider_prefix)"
        exit 1
    }

    if (dsh ["echo" "ok"]).exit_code != 0 {
        err_ $c "cider shell is not functional.\n   Try: cider shell echo ok"
        exit 1
    }

    say $c $"  Darling prefix: ($cider_prefix)"
    let sv = (dsh ["sw_vers" "-productVersion"])
    say $c $"  cider shell:  (if $sv.exit_code == 0 { $sv.stdout | str trim } else { 'unknown' })"

    if (dsh ["test" "-x" "/usr/bin/sandbox-exec"]).exit_code != 0 {
        warn $c "/usr/bin/sandbox-exec not found in Darling prefix."
        warn $c "Nix builds will fail without it. Install Phase 2 fixes first."
        warn $c "Continuing anyway (Nix installation may still work)..."
    }

    if (dsh ["test" "-e" "/nix/store"]).exit_code == 0 {
        warn $c "/nix/store already exists in the prefix."
        # input reads the terminal, not stdin, and errors outright when stdin is a pipe. bash got
        # both cases from read -r -p, whose prompt is printed ONLY when stdin is a terminal, so
        # the piped branch must stay silent to match.
        let answer = if (is-terminal --stdin) {
            (input "  Reinstall? [y/N] ")
        } else {
            (^head -n 1 | str trim)
        }
        if not ($answer =~ '^[Yy]') {
            say $c "Aborted."
            exit 0
        }
    }

    # -- Step 1: pre-configure Nix -------------------------------------------
    say $c $"($c.bold)Step 1: Pre-configuring Nix...($c.reset)"
    dsh ["mkdir" "-p" "/etc/nix"] | ignore

    let stamp = (date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ")
    let nix_conf = ([
        $"# Nix configuration for Darling"
        $"# Generated by install-nix-in-cider.nu on ($stamp)"
        ""
        "# Single-user mode: no build users group needed"
        "build-users-group ="
        ""
        "# Disable the macOS sandbox \u{2014} Darling provides Linux-level isolation"
        "# via namespaces and ciderd instead."
        "sandbox = false"
        ""
        "# Accept flake commands and the nix3 CLI"
        "experimental-features = nix-command flakes"
        ""
    ] | str join "\n") + (if $offline {
        "\n# Offline mode -- no binary substitution\nsubstitute = false\n"
    } else {
        "\n# Binary cache\nsubstituters = https://cache.nixos.org\ntrusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=\n"
    })

    # Written through the prefix filesystem directly, which is more reliable than piping into
    # the guest. The directory is created here rather than assumed: a prefix that has never had
    # nix in it has no etc/nix, and the redirect then fails before anything useful happens.
    mkdir $"($cider_prefix)/etc/nix"
    $"($nix_conf)\n" | save -f $"($cider_prefix)/etc/nix/nix.conf"
    say $c "  Wrote /etc/nix/nix.conf"

    # -- Step 2: download the Nix installer ----------------------------------
    say $c $"($c.bold)Step 2: Downloading Nix installer...($c.reset)"
    let version = if ($nix_version | is-not-empty) {
        $nix_version
    } else {
        say $c "  Detecting latest Nix version..."
        # https://nixos.org/nix/install, not releases.nixos.org/nix/latest/install: the latter
        # is a 404 now, and the failure was invisible -- detection just fell through to the
        # fallback and installed a 2024-era Nix.
        let page = (do -i { ^curl -fsSL https://nixos.org/nix/install } | complete | get stdout)
        let hit = ($page | parse --regex 'nix-(?P<v>[0-9]+\.[0-9]+\.[0-9]+)' | get v | get 0?
            | default "")
        if ($hit | is-empty) {
            # The version this project has actually run inside Darling (M1). Not simply some
            # older release: 2.24.12 was the previous fallback and it dies with SIGILL in the
            # guest, under the reference build as much as this one.
            warn $c "Could not detect latest version, falling back to 2.34.8"
            "2.34.8"
        } else {
            $hit
        }
    }
    say $c $"  Nix version: ($version)"

    let installer_name = $"nix-($version)-x86_64-darwin"
    let installer_url = $"($url_base)/nix-($version)/($installer_name).tar.xz"
    let host_tmp = (mktemp --directory --tmpdir-path ($env | get -o TMPDIR | default "/tmp")
        nix-cider-install.XXXXXX)

    say $c $"  Downloading ($installer_url) ..."
    let dl = (do -i { ^curl -fSL -o $"($host_tmp)/installer.tar.xz" $installer_url } | complete)
    if $dl.exit_code != 0 {
        err_ $c $"Failed to download Nix installer.\n   URL: ($installer_url)\n   Check that the version ($version) exists for x86_64-darwin."
        ^rm -rf $host_tmp
        exit 1
    }

    say $c "  Extracting..."
    do -i { ^tar -xf $"($host_tmp)/installer.tar.xz" -C $host_tmp } | ignore

    # -mindepth 1: without it find matches the START directory too, and the temp dir is itself
    # called nix-cider-install.XXXXXX, so head -1 picked the temp dir, whose install does not
    # exist, and a perfectly good extraction was reported as a failure.
    let installer_dir = (^find $host_tmp -mindepth 1 -maxdepth 1 -type d -name "nix-*"
        | complete | get stdout | lines | get 0? | default "")
    if ($installer_dir | is-empty) or (not ($"($installer_dir)/install" | path exists)) {
        err_ $c "Installer extraction failed \u{2014} cannot find install script."
        ^rm -rf $host_tmp
        exit 1
    }
    say $c $"  Installer extracted to: ($installer_dir)"

    # -- Step 3: patch the installer -----------------------------------------
    say $c $"($c.bold)Step 3: Patching installer for Darling compatibility...($c.reset)"
    let script = $"($installer_dir)/install"
    let body = (open --raw $script)
    mut patches = 0

    # Patch 1: remove the multi-user enforcement on Darwin. The installer detects uname -s ==
    # Darwin and forces multi-user mode; single-user is what Darling can do, because Directory
    # Services are not available.
    if ($body | str contains 'case "$(uname -s)"') or ($body | str contains "Darwin") {
        ^sed -i.bak -e 's/INSTALL_MODE=daemon/INSTALL_MODE=no-daemon/g' $script
        $patches = $patches + 1
    }

    # Patch 1b: drop the installer REFUSAL of --no-daemon on Darwin. Since 2.24 the installer
    # does not merely default to multi-user there, it rejects the flag outright, inside the
    # --no-daemon case. Patch 1 only rewrites INSTALL_MODE, so the flag still reaches this and
    # exits 1. The edit is scoped to the lines BETWEEN --no-daemon) and its fi, so it cannot
    # disturb the rest of the script.
    if (open --raw $script | str contains "no-longer supported on Darwin") {
        ^sed -i.bak -e '/--no-daemon)/,/^ *fi$/{/uname -s/d; /no-longer supported/d; /exit 1/d; /^ *fi$/d}' $script
        $patches = $patches + 1
    }

    # Patch 2: diskutil. Not removed -- the stub handles it; this only reports.
    if (open --raw $script | str contains "diskutil") {
        say $c "  diskutil references found \u{2014} our stub should handle them"
    }

    # Patch 3: remove xmllint dependency checks.
    if (open --raw $script | str contains "xmllint") {
        ^sed -i.bak -e '/xmllint/d' $script
        $patches = $patches + 1
    }

    # Patch 4: relax the root-user check. Inside Darling we always run as root.
    let b4 = (open --raw $script)
    if ($b4 | str contains "running as root is not supported") or ($b4 | str contains "do not run this script as root") {
        ^sed -i.bak -e '/running as root is not supported/d' -e '/do not run this script as root/d' $script
        $patches = $patches + 1
    }

    # Patch 5 and 6: reporting only.
    let b5 = (open --raw $script)
    if ($b5 =~ 'dseditgroup|sysadminctl') {
        say $c "  Directory Services references found \u{2014} should be skipped in no-daemon mode"
    }
    if ($b5 | str contains "NIX_INSTALLER_NO_MODIFY_PROFILE") {
        say $c "  Standard Nix installer detected"
    }
    say $c $"  Applied ($patches) patches to installer script"

    # -- Step 4: copy the installer in and run it ----------------------------
    say $c $"($c.bold)Step 4: Installing Nix inside Darling...($c.reset)"
    let cider_tmp = $"($cider_prefix)/private/tmp"
    mkdir $cider_tmp
    let guest_installer = $"($cider_tmp)/nix-installer"
    ^rm -rf $guest_installer
    ^cp -a $installer_dir $guest_installer
    dsh ["mkdir" "-p" "/nix"] | ignore
    ^chmod +x $"($guest_installer)/install"

    say $c "  Running Nix installer (this may take a few minutes)..."
    let log_file = $"($host_tmp)/install.log"
    # Redirected to the log and then printed, rather than piped through tee: a nushell pipeline
    # reports the LAST command status, so tee would mask a failing installer, and wrapping the
    # pipeline in complete would capture the transcript instead of showing it. bash got the
    # first behaviour from pipefail and the second from tee.
    let run_rc = (try {
        ^cider shell env NIX_INSTALLER_NO_MODIFY_PROFILE=0 bash -ex /tmp/nix-installer/install --no-daemon out+err> $log_file
        0
    } catch { $env.LAST_EXIT_CODE })
    if ($log_file | path exists) { print -n (open --raw $log_file) }
    if $run_rc != 0 {
        err_ $c $"Nix installer failed. Log saved to: ($log_file)"
        err_ $c ""
        err_ $c "Common causes:"
        err_ $c "  - Missing syscall fixes (Phase 1): check for 'Unimplemented syscall' in the log"
        err_ $c "  - Missing sandbox-exec (Phase 2): check for 'Bad file descriptor'"
        err_ $c "  - Installer script incompatibility: the patches may need updating"
        err_ $c ""
        err_ $c "Debug tips:"
        err_ $c "  strace -f -p $(pidof ciderd) -e trace=openat,stat 2>&1 | head -200"
        err_ $c "  env DYLD_INSERT_LIBRARIES=/usr/lib/cider/libxtrace.dylib cider shell ..."
        # The temp dir is deliberately NOT removed here, so the log can be inspected.
        err_ $c $"Installation failed. Temp files preserved at: ($host_tmp)"
        exit 1
    }
    say $c "  \u{2713} Nix installer completed successfully"

    # -- Step 5: post-install configuration ----------------------------------
    say $c $"($c.bold)Step 5: Post-install configuration...($c.reset)"
    let profile_main = "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
    let profile_alt = "/root/.nix-profile/etc/profile.d/nix.sh"
    if (dsh ["test" "-f" $profile_main]).exit_code == 0 {
        say $c $"  Nix profile script: ($profile_main)"
    } else if (dsh ["test" "-f" $profile_alt]).exit_code == 0 {
        say $c $"  Nix profile script: ($profile_alt)"
    } else {
        warn $c "Could not find Nix profile script \u{2014} Nix may not be on PATH in new shells"
    }

    let conf = $"($cider_prefix)/etc/nix/nix.conf"
    if ($conf | path type) == "file" {
        if not (open --raw $conf | str contains "build-users-group =") {
            say $c "  Restoring nix.conf (installer overwrote it)..."
            $"($nix_conf)\n" | save -f $conf
        }
    }

    let profile_d = $"($cider_prefix)/etc/profile.d"
    mkdir $profile_d
    # The guest sources this, so it stays sh and is written verbatim.
    let profile_body = '# Source Nix profile if available
if [ -e \'/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh\' ]; then
    . \'/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh\'
elif [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi
'
    $profile_body | save -f $"($profile_d)/nix-cider.sh"
    say $c "  Wrote /etc/profile.d/nix-cider.sh"

    # -- Step 6: channel setup -----------------------------------------------
    if (not $no_channel) and (not $offline) {
        say $c $"($c.bold)Step 6: Setting up Nix channels...($c.reset)"
        if (dsh_bash "nix-channel --add https://nixos.org/channels/nixpkgs-unstable nixpkgs").exit_code == 0 {
            say $c "  Added nixpkgs-unstable channel"
            say $c "  Updating channels (this downloads ~20 MB)..."
            if (dsh_bash "nix-channel --update").exit_code == 0 {
                say $c "  \u{2713} Channels updated"
            } else {
                warn $c "Channel update failed \u{2014} this exercises curl/TLS, which may have issues."
                warn $c "You can retry later with: cider shell nix-channel --update"
            }
        } else {
            warn $c "Failed to add channel \u{2014} Nix may not be on PATH yet."
            warn $c "Try: cider shell bash -lc 'nix-channel --add https://nixos.org/channels/nixpkgs-unstable nixpkgs'"
        }
    } else {
        say $c $"($c.bold)Step 6: Skipping channel setup($c.reset) \(--no-channel or --offline)"
    }

    # -- Step 7: verification ------------------------------------------------
    if not $no_verify {
        say $c $"($c.bold)Step 7: Verifying installation...($c.reset)"
        mut pass = 0
        mut fail = 0
        mut probes = [
            ["nix --version", "nix --version"]
            ["nix-env --version", "nix-env --version"]
            ["nix-store --verify (may take a moment)", "nix-store --verify --no-build 2>/dev/null || nix-store --verify"]
            ["nix-instantiate --eval -E '1 + 1'", "nix-instantiate --eval -E '1 + 1'"]
            ["nix eval --expr '1 + 1'", "nix eval --expr '1 + 1'"]
            ["builtins.currentSystem == x86_64-darwin", "test \"$(nix eval --expr 'builtins.currentSystem' --raw)\" = 'x86_64-darwin'"]
        ]
        for p in $probes {
            if (dsh_bash ($p | last)).exit_code == 0 {
                say $c $"  ($c.green)\u{2713}($c.reset) ($p | first)"
                $pass = $pass + 1
            } else {
                err_ $c $"  \u{2717} ($p | first)"
                $fail = $fail + 1
            }
        }
        if not $offline {
            let name = "curl to cache.nixos.org"
            if (dsh ["bash" "-c" "curl -sfI https://cache.nixos.org/nix-cache-info >/dev/null 2>&1"]).exit_code == 0 {
                say $c $"  ($c.green)\u{2713}($c.reset) ($name)"
                $pass = $pass + 1
            } else {
                err_ $c $"  \u{2717} ($name)"
                $fail = $fail + 1
            }
        }
        print ""
        say $c $"Verification: ($c.green)($pass) passed($c.reset), ($c.red)($fail) failed($c.reset)"
        if $fail > 0 {
            warn $c "Some checks failed. Nix may be partially functional."
            warn $c "See docs/changelog.md for debugging tips."
        }
    } else {
        say $c $"($c.bold)Step 7: Skipping verification($c.reset) \(--no-verify)"
    }

    # -- Step 8: clean up ----------------------------------------------------
    say $c $"($c.bold)Step 8: Cleaning up...($c.reset)"
    ^rm -rf $guest_installer
    say $c "  Removed installer files from prefix"
    ^rm -rf $host_tmp

    let bar = "═══════════════════════════════════════════════════════"
    print ""
    say $c $"($c.bold)($c.green)($bar)($c.reset)"
    say $c $"($c.bold)($c.green)  Nix installation inside Darling is complete!($c.reset)"
    say $c $"($c.bold)($c.green)($bar)($c.reset)"
    print ""
    let nv = (dsh_bash "nix --version")
    say $c $"Nix version: (if $nv.exit_code == 0 { $nv.stdout | str trim } else { 'unknown' })"
    say $c $"Prefix:      ($cider_prefix)"
    say $c $"Store:       ($cider_prefix)/nix/store"
    print ""
    say $c "Quick start:"
    say $c $"  ($c.blue)cider shell bash -lc 'nix --version'($c.reset)"
    say $c $"  ($c.blue)cider shell bash -lc 'nix eval --expr 1+1'($c.reset)"
    # A raw string: this line is four levels of quoting deep in bash, and every backslash in it
    # is literal output rather than an escape.
    let qs = r##'cider shell bash -lc 'nix-build --expr "derivation { name = \"test\"; builder = \"/bin/bash\"; args = [\"-c\" \"echo ok > \\$out\"]; system = \"x86_64-darwin\"; }"''##
    say $c $"  ($c.blue)($qs)($c.reset)"
    print ""
    say $c "Or use the wrapper script:"
    say $c $"  ($c.blue)./scripts/cider-nix nix --version($c.reset)"
    say $c $"  ($c.blue)./scripts/cider-nix nix eval --expr '1 + 1'($c.reset)"
}
