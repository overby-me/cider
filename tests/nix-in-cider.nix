# NixOS VM integration test: Nix-in-Darling
#
# This test exercises the full Nix-inside-Darling pipeline end-to-end
# in a NixOS VM, which provides the kernel namespace support Darling needs.
#
# Test stages:
#   1. Darling boots and `cider shell` is functional
#   2. sandbox-exec stub is present and works
#   3. Directory Services stubs are present
#   4. Nix installs successfully inside the Darling prefix
#   5. Core Nix commands work (version, eval, store)
#   6. builtins.currentSystem reports x86_64-darwin
#   7. Trivial derivation builds successfully
#
# Usage:
#   nix build .#checks.x86_64-linux.nix-in-cider -L
#
# See: PLAN.md (Task 6.1)
{ pkgs, cider, ... }:

let
  nixos-lib = import (pkgs.path + "/nixos/lib") { };

  # Write derivation expressions to files so we avoid nested quoting
  # nightmares inside the Nix ''..'' / Python f-string / shell layers.
  trivialDrvFile = pkgs.writeText "trivial-drv.nix" ''
    derivation {
      name = "cider-test";
      builder = "/bin/bash";
      args = [ "-c" "echo ok > $out" ];
      system = "x86_64-darwin";
    }
  '';

  multistepDrvFile = pkgs.writeText "multistep-drv.nix" ''
    derivation {
      name = "cider-multistep";
      builder = "/bin/bash";
      args = [ "-c" "mkdir -p $out/bin; echo hello > $out/bin/greeting; chmod 755 $out/bin" ];
      system = "x86_64-darwin";
    }
  '';

  # Helper script that sources the Nix profile and runs a command.
  # Installed into the VM so tests can just call "nix-run <cmd>".
  nixRunHelper = pkgs.writeShellScript "nix-run" ''
    # Source whichever Nix profile script exists
    for p in \
      /root/.nix-profile/etc/profile.d/nix.sh \
      /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
      /nix/var/nix/profiles/default/etc/profile.d/nix.sh; do
      if [ -e "$p" ]; then
        . "$p"
        break
      fi
    done
    exec "$@"
  '';
in
nixos-lib.runTest {
  name = "nix-in-cider";

  hostPkgs = pkgs;

  # The test runs inside a NixOS VM that has Darling installed.
  nodes.machine =
    { config, pkgs, lib, ... }:
    {
      # Give the VM enough resources — Darling + Nix store are disk/RAM hungry.
      virtualisation = {
        memorySize = 4096;
        diskSize = 20480; # 20 GB for Darling prefix + Nix store + builds
        cores = 4;
        writableStore = true;
      };

      # Install Darling and basic tools
      environment.systemPackages = [
        cider
        pkgs.curl
        pkgs.jq
        pkgs.sqlite
      ];

      # Darling needs unprivileged user namespaces and overlayfs
      boot.kernel.sysctl = {
        "kernel.unprivileged_userns_clone" = 1;
      };

      # FUSE support for cider-dmg
      environment.etc."fuse.conf".text = ''
        user_allow_other
      '';

      # Generous timeout — Darling operations are slow
      systemd.services."getty@tty1".enable = false;
    };

  testScript = ''
    import re

    machine.start()
    machine.wait_for_unit("default.target")

    # ── Stage 1: Darling boots and shell is functional ─────────────────

    with machine.nested("Stage 1: Darling boots and shell is functional"):
        # Verify cider binary is present
        machine.succeed("command -v cider")

        # Initialize the prefix (first run is slow)
        machine.succeed("cider shell true", timeout=120)

        # Basic shell functionality
        result = machine.succeed("cider shell echo 'Hello from Darling'")
        assert "Hello" in result, f"Expected 'Hello' in output, got: {result}"

        # Verify macOS version detection
        result = machine.succeed("cider shell sw_vers -productVersion")
        assert re.search(r"\d+\.\d+", result), f"Expected version string, got: {result}"
        machine.log(f"macOS version: {result.strip()}")

        # Verify uname reports Darwin
        result = machine.succeed("cider shell uname -s")
        assert "Darwin" in result, f"Expected 'Darwin', got: {result}"

    # ── Stage 2: sandbox-exec stub is present and works ────────────────

    with machine.nested("Stage 2: sandbox-exec stub is present and works"):
        # Check the binary exists
        machine.succeed("cider shell test -x /usr/bin/sandbox-exec")

        # Run a command through sandbox-exec (should pass through)
        result = machine.succeed(
            "cider shell /usr/bin/sandbox-exec -f /dev/null /bin/echo sandbox-ok"
        )
        assert "sandbox-ok" in result, f"Expected 'sandbox-ok', got: {result}"

        # Test with -D parameters (like Nix uses)
        result = machine.succeed(
            "cider shell /usr/bin/sandbox-exec "
            "-f /dev/null "
            "-D _GLOBAL_TMP_DIR=/tmp "
            "-D IMPORT_DIR=/tmp "
            "/bin/echo nix-pattern-ok"
        )
        assert "nix-pattern-ok" in result, f"sandbox-exec with -D failed: {result}"

    # ── Stage 3: Directory Services stubs are present ──────────────────

    with machine.nested("Stage 3: Directory Services stubs are present"):
        # Verify the stubs exist and are executable
        for tool in ["dseditgroup", "sysadminctl", "dscl"]:
            machine.succeed(f"cider shell test -x /usr/sbin/{tool}")

        # Quick smoke test: create a group and user, then verify
        machine.succeed(
            "cider shell /usr/sbin/dseditgroup -o create -q -i 30000 nixbld"
        )
        result = machine.succeed("cider shell grep nixbld /etc/group")
        assert "30000" in result, f"Expected GID 30000 in group entry, got: {result}"

        machine.succeed(
            "cider shell /usr/sbin/sysadminctl -addUser _nixbld1 "
            "-UID 300 -GID 30000 -home /var/empty -shell /usr/bin/false"
        )
        result = machine.succeed("cider shell grep _nixbld1 /etc/passwd")
        assert "300" in result, f"Expected UID 300 in passwd entry, got: {result}"

        # Add user to group
        machine.succeed(
            "cider shell /usr/sbin/dseditgroup -o edit -a _nixbld1 -t user nixbld"
        )

        # Verify with dscl
        result = machine.succeed(
            "cider shell /usr/sbin/dscl . -read /Groups/nixbld GroupMembership"
        )
        assert "_nixbld1" in result, f"Expected _nixbld1 in membership, got: {result}"

    # ── Stage 4: Pre-configure and install Nix ─────────────────────────

    with machine.nested("Stage 4: Pre-configure and install Nix"):
        # Write nix.conf directly via the prefix filesystem (avoids shell quoting)
        machine.succeed("mkdir -p ~/.cider/etc/nix")
        machine.succeed(
            "cat > ~/.cider/etc/nix/nix.conf << 'CONF'\n"
            "build-users-group =\n"
            "sandbox = false\n"
            "experimental-features = nix-command flakes\n"
            "substitute = false\n"
            "CONF"
        )

        # Create /nix directory
        machine.succeed("cider shell mkdir -p /nix")

        # Download the Nix installer on the host side and copy it in.
        # We use a known-good version to keep the test deterministic.
        nix_version = "2.24.12"
        installer_name = f"nix-{nix_version}-x86_64-darwin"
        installer_url = (
            f"https://releases.nixos.org/nix/nix-{nix_version}/{installer_name}.tar.xz"
        )

        machine.succeed(
            f"curl -fsSL -o /tmp/nix-installer.tar.xz {installer_url}",
            timeout=300,
        )
        machine.succeed(
            "mkdir -p /tmp/nix-install && "
            "tar -xf /tmp/nix-installer.tar.xz -C /tmp/nix-install"
        )

        # Find the extracted directory and patch the installer
        installer_dir = machine.succeed(
            "find /tmp/nix-install -maxdepth 1 -type d -name 'nix-*' | head -1"
        ).strip()
        assert installer_dir, "Could not find extracted installer directory"

        # Patch: force single-user mode
        machine.succeed(
            f"sed -i 's/INSTALL_MODE=daemon/INSTALL_MODE=no-daemon/g' "
            f"{installer_dir}/install"
        )

        # Copy installer into the Darling prefix
        machine.succeed("mkdir -p ~/.cider/private/tmp/nix-installer")
        machine.succeed(
            f"cp -a {installer_dir}/* ~/.cider/private/tmp/nix-installer/"
        )
        machine.succeed("chmod +x ~/.cider/private/tmp/nix-installer/install")

        # Copy the nix-run helper into the prefix
        machine.succeed(
            "cp ${nixRunHelper} ~/.cider/private/tmp/nix-run && "
            "chmod +x ~/.cider/private/tmp/nix-run"
        )

        # Run the patched installer inside Darling
        machine.succeed(
            "cider shell env NIX_INSTALLER_NO_MODIFY_PROFILE=0 "
            "bash -x /tmp/nix-installer/install --no-daemon",
            timeout=600,
        )

    # ── Stage 5: Core Nix commands work ────────────────────────────────

    with machine.nested("Stage 5: Core Nix commands work"):
        nix_run = "/tmp/nix-run"

        # nix --version
        result = machine.succeed(
            f"cider shell {nix_run} nix --version"
        )
        assert "nix" in result.lower(), (
            f"Expected 'nix' in version output, got: {result}"
        )
        machine.log(f"Nix version: {result.strip()}")

        # nix-env --version
        result = machine.succeed(
            f"cider shell {nix_run} nix-env --version"
        )
        assert "nix-env" in result.lower(), (
            f"Expected 'nix-env' in output, got: {result}"
        )

        # nix-instantiate --eval
        result = machine.succeed(
            f"cider shell {nix_run} nix-instantiate --eval -E '1 + 1'"
        )
        assert "2" in result, f"Expected '2', got: {result}"

        # nix eval (flake-style)
        result = machine.succeed(
            f"cider shell {nix_run} nix eval --expr '1 + 1'"
        )
        assert "2" in result, f"Expected '2', got: {result}"

        # Verify store database is accessible
        machine.succeed(
            f"cider shell {nix_run} nix-store --verify --no-build",
            timeout=120,
        )

    # ── Stage 6: builtins.currentSystem reports x86_64-darwin ──────────

    with machine.nested("Stage 6: builtins.currentSystem reports x86_64-darwin"):
        nix_run = "/tmp/nix-run"

        result = machine.succeed(
            f"cider shell {nix_run} nix eval --raw --expr builtins.currentSystem"
        )
        assert result.strip() == "x86_64-darwin", (
            f"Expected 'x86_64-darwin', got: '{result.strip()}'"
        )
        machine.log("builtins.currentSystem = x86_64-darwin  OK")

    # ── Stage 7: Trivial derivation builds ─────────────────────────────

    with machine.nested("Stage 7: Trivial derivation builds"):
        nix_run = "/tmp/nix-run"

        # Copy derivation expression files into the prefix to avoid
        # nested quoting nightmares (Nix string -> Python -> shell -> Nix).
        machine.succeed(
            "cp ${trivialDrvFile} ~/.cider/private/tmp/trivial-drv.nix"
        )
        machine.succeed(
            "cp ${multistepDrvFile} ~/.cider/private/tmp/multistep-drv.nix"
        )

        # Level 1: minimal derivation — echo to $out
        out_path = machine.succeed(
            f"cider shell {nix_run} nix-build --no-out-link /tmp/trivial-drv.nix",
            timeout=300,
        ).strip()
        assert out_path.startswith("/nix/store/"), (
            f"Expected /nix/store/... path, got: '{out_path}'"
        )
        machine.log(f"Built trivial derivation at: {out_path}")

        # Verify the output content
        result = machine.succeed(f"cider shell cat {out_path}")
        assert "ok" in result, f"Expected 'ok' in build output, got: {result}"

        # Level 2: multi-step builder
        out_path2 = machine.succeed(
            f"cider shell {nix_run} nix-build --no-out-link /tmp/multistep-drv.nix",
            timeout=300,
        ).strip()
        assert out_path2.startswith("/nix/store/"), (
            f"Expected /nix/store/... path, got: '{out_path2}'"
        )
        result = machine.succeed(f"cider shell cat {out_path2}/bin/greeting")
        assert "hello" in result, f"Expected 'hello', got: {result}"
        machine.log(f"Built multistep derivation at: {out_path2}")

    machine.log("All Nix-in-Darling integration tests passed! OK")
  '';
}
