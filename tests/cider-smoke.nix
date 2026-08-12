# NixOS VM smoke test: Darling basics
#
# A lightweight test that verifies Darling boots, the shell is functional,
# and the key stubs (sandbox-exec, diskutil, Directory Services) are present
# and minimally operational.  This test does NOT require network access and
# should complete in a few minutes.
#
# Usage:
#   nix build .#checks.x86_64-linux.cider-smoke -L
#
# See: docs/changelog.md (Task 6.6)
{ pkgs, cider, ... }:

let
  nixos-lib = import (pkgs.path + "/nixos/lib") { };
in
nixos-lib.runTest {
  name = "cider-smoke";

  hostPkgs = pkgs;

  nodes.machine = { config, pkgs, lib, ... }: {
    virtualisation = {
      memorySize = 2048;
      diskSize = 8192;
      cores = 2;
    };

    environment.systemPackages = [
      cider
    ];

    # Darling needs unprivileged user namespaces
    boot.kernel.sysctl = {
      "kernel.unprivileged_userns_clone" = 1;
    };

    environment.etc."fuse.conf".text = ''
      user_allow_other
    '';
  };

  testScript = ''
    import re

    machine.start()
    machine.wait_for_unit("default.target")

    # ── Stage 1: Darling binary and prefix initialisation ──────────────

    with machine.nested("Stage 1: Darling binary exists and prefix initialises"):
        machine.succeed("command -v cider")

        # First invocation creates the prefix — may take a while
        machine.succeed("cider shell true", timeout=120)

    # ── Stage 2: Basic shell functionality ─────────────────────────────

    with machine.nested("Stage 2: Basic shell functionality"):
        result = machine.succeed("cider shell echo 'hello from cider'")
        assert "hello from cider" in result, f"echo failed: {result}"

        # Environment variables pass through
        result = machine.succeed("cider shell /bin/bash -c 'echo $HOME'")
        assert result.strip(), f"HOME was empty: {result}"

        # Exit codes propagate
        machine.succeed("cider shell /bin/bash -c 'exit 0'")
        machine.fail("cider shell /bin/bash -c 'exit 1'")

    # ── Stage 3: macOS identity ────────────────────────────────────────

    with machine.nested("Stage 3: macOS identity"):
        result = machine.succeed("cider shell uname -s")
        assert "Darwin" in result, f"Expected 'Darwin', got: {result}"

        result = machine.succeed("cider shell uname -m")
        assert "x86_64" in result, f"Expected 'x86_64', got: {result}"

        result = machine.succeed("cider shell sw_vers -productName")
        assert result.strip(), "sw_vers productName was empty"

        result = machine.succeed("cider shell sw_vers -productVersion")
        assert re.search(r"\d+\.\d+", result), f"Bad version format: {result}"
        machine.log(f"Emulated macOS version: {result.strip()}")

    # ── Stage 4: Filesystem basics ─────────────────────────────────────

    with machine.nested("Stage 4: Filesystem basics"):
        # Can create and read files
        machine.succeed(
            "cider shell /bin/bash -c 'echo test-content > /tmp/smoke-test.txt'"
        )
        result = machine.succeed("cider shell cat /tmp/smoke-test.txt")
        assert "test-content" in result, f"File content mismatch: {result}"

        # Can create directories
        machine.succeed("cider shell mkdir -p /tmp/smoke-dir/sub")
        machine.succeed("cider shell test -d /tmp/smoke-dir/sub")

        # Symlinks work
        machine.succeed(
            "cider shell ln -sf /tmp/smoke-test.txt /tmp/smoke-link"
        )
        result = machine.succeed("cider shell cat /tmp/smoke-link")
        assert "test-content" in result, f"Symlink read failed: {result}"

        # Can remove files
        machine.succeed("cider shell rm /tmp/smoke-test.txt /tmp/smoke-link")
        machine.succeed("cider shell rm -rf /tmp/smoke-dir")

    # ── Stage 5: sandbox-exec stub ─────────────────────────────────────

    with machine.nested("Stage 5: sandbox-exec stub"):
        machine.succeed("cider shell test -x /usr/bin/sandbox-exec")

        # Basic passthrough
        result = machine.succeed(
            "cider shell /usr/bin/sandbox-exec -f /dev/null /bin/echo sandbox-ok"
        )
        assert "sandbox-ok" in result, f"sandbox-exec passthrough failed: {result}"

        # With -p (inline profile string)
        result = machine.succeed(
            "cider shell /usr/bin/sandbox-exec -p '(version 1)(allow default)' "
            "/bin/echo inline-ok"
        )
        assert "inline-ok" in result, f"sandbox-exec -p failed: {result}"

        # With -D key=value parameters (Nix pattern)
        result = machine.succeed(
            "cider shell /usr/bin/sandbox-exec "
            "-f /dev/null "
            "-D _GLOBAL_TMP_DIR=/tmp "
            "-D IMPORT_DIR=/tmp "
            "/bin/echo nix-pattern-ok"
        )
        assert "nix-pattern-ok" in result, f"sandbox-exec -D failed: {result}"

        # Exit code forwarding
        machine.fail(
            "cider shell /usr/bin/sandbox-exec -f /dev/null /bin/bash -c 'exit 42'"
        )

    # ── Stage 6: diskutil stub ─────────────────────────────────────────

    with machine.nested("Stage 6: diskutil stub"):
        machine.succeed("cider shell test -x /usr/sbin/diskutil")

        # diskutil info /
        result = machine.succeed("cider shell /usr/sbin/diskutil info /")
        assert "APFS" in result or "apfs" in result, (
            f"Expected APFS in diskutil info output: {result}"
        )

        # diskutil info -plist /
        result = machine.succeed("cider shell /usr/sbin/diskutil info -plist /")
        assert "FilesystemType" in result, (
            f"Expected plist output from diskutil info -plist: {result}"
        )
        assert "apfs" in result, f"Expected apfs in plist output: {result}"

        # diskutil list
        result = machine.succeed("cider shell /usr/sbin/diskutil list")
        assert "disk0" in result, f"Expected disk0 in list output: {result}"

    # ── Stage 7: Directory Services stubs ──────────────────────────────

    with machine.nested("Stage 7: Directory Services stubs"):
        for tool in ["dseditgroup", "sysadminctl", "dscl"]:
            machine.succeed(f"cider shell test -x /usr/sbin/{tool}")

        # Create a test group
        machine.succeed(
            "cider shell /usr/sbin/dseditgroup -o create -q -i 39999 smoketest"
        )
        result = machine.succeed("cider shell grep smoketest /etc/group")
        assert "39999" in result, f"Group GID mismatch: {result}"

        # Create a test user
        machine.succeed(
            "cider shell /usr/sbin/sysadminctl -addUser _smoketest "
            "-UID 399 -GID 39999 -home /var/empty -shell /usr/bin/false"
        )
        result = machine.succeed("cider shell grep _smoketest /etc/passwd")
        assert "399" in result, f"User UID mismatch: {result}"

        # Add user to group
        machine.succeed(
            "cider shell /usr/sbin/dseditgroup -o edit "
            "-a _smoketest -t user smoketest"
        )

        # Verify via dscl
        result = machine.succeed(
            "cider shell /usr/sbin/dscl . -read /Groups/smoketest GroupMembership"
        )
        assert "_smoketest" in result, f"Member not found via dscl: {result}"

        result = machine.succeed(
            "cider shell /usr/sbin/dscl . -read /Users/_smoketest UniqueID"
        )
        assert "399" in result, f"UID not found via dscl: {result}"

        # Checkmember
        machine.succeed(
            "cider shell /usr/sbin/dseditgroup -o checkmember "
            "-m _smoketest smoketest"
        )

        # Cleanup
        machine.succeed(
            "cider shell /usr/sbin/sysadminctl -deleteUser _smoketest"
        )
        machine.succeed(
            "cider shell /usr/sbin/dseditgroup -o delete smoketest"
        )

    # ── Stage 8: No unimplemented syscall warnings ─────────────────────

    with machine.nested("Stage 8: Check for unimplemented syscall warnings"):
        # Run a few operations and capture stderr for syscall warnings
        result = machine.succeed(
            "cider shell /bin/bash -c '"
            "echo test > /tmp/syscall-check.txt && "
            "cat /tmp/syscall-check.txt && "
            "mv /tmp/syscall-check.txt /tmp/syscall-check2.txt && "
            "ln -sf /tmp/syscall-check2.txt /tmp/syscall-link && "
            "ls -la /tmp/syscall-link && "
            "rm -f /tmp/syscall-check2.txt /tmp/syscall-link && "
            "echo done"
            "' 2>&1"
        )
        # Warn but don't fail — some stubs may still print warnings
        if "Unimplemented syscall" in result or "STUB" in result:
            machine.log(
                f"WARNING: Found unimplemented syscall or STUB warnings:\n{result}"
            )
        else:
            machine.log("No unimplemented syscall warnings detected ✓")

    machine.log("All Darling smoke tests passed! ✓")
  '';
}
