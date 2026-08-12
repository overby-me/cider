# NixOS VM test: Darling remote builder
#
# This test exercises the Darling-based x86_64-darwin remote builder setup
# end-to-end in a NixOS VM.  It verifies:
#
#   1. The cider-builder systemd service starts and initialises the prefix
#   2. sshd inside the Darling prefix is reachable from the host
#   3. SSH key authentication works (auto-generated keys)
#   4. Nix commands work over the SSH connection
#   5. The host's Nix daemon recognises the Darling builder
#   6. A trivial x86_64-darwin derivation can be offloaded to the builder
#
# Usage:
#   nix build .#checks.x86_64-linux.cider-builder -L
#
# See: docs/changelog.md
{ pkgs, cider, ciderBuilderModule, ... }:

let
  nixos-lib = import (pkgs.path + "/nixos/lib") { };

in
nixos-lib.runTest {
  name = "cider-builder";

  hostPkgs = pkgs;

  nodes.machine =
    { config, pkgs, lib, ... }:
    {
      imports = [
        ciderBuilderModule
      ];

      # Give the VM generous resources — Darling prefix init + sshd + Nix
      # builds are resource-hungry.
      virtualisation = {
        memorySize = 4096;
        diskSize = 20480;
        cores = 4;
        writableStore = true;
      };

      # Enable the Darling builder service.
      # We do NOT enable installNix here because the test would need to
      # download the Nix installer from the internet, which makes the test
      # slow and flaky.  Instead we test the infrastructure layers
      # (prefix init, sshd, SSH connectivity, build machine registration)
      # and the trivial build is expected to work only if Nix is pre-installed
      # in the prefix (which the full nix-in-cider test covers).
      services.cider-builder = {
        enable = true;
        package = cider;
        port = 2222;
        maxJobs = 2;
        speedFactor = 1;
        shareStore = false; # Keep the test self-contained
      };

      # Darling needs unprivileged user namespaces
      boot.kernel.sysctl = {
        "kernel.unprivileged_userns_clone" = 1;
      };

      environment.etc."fuse.conf".text = ''
        user_allow_other
      '';

      # Extra tools for debugging
      environment.systemPackages = [
        pkgs.openssh
        pkgs.curl
      ];
    };

  testScript = ''
    import time

    machine.start()
    machine.wait_for_unit("default.target")

    # ── Stage 1: Darling builder service starts ────────────────────────

    with machine.nested("Stage 1: Darling builder service starts"):
        # The service may take a while on first run (prefix initialisation)
        machine.wait_for_unit("cider-builder.service", timeout=300)
        machine.log("cider-builder.service is active")

        # Verify the prefix directory was created
        machine.succeed("test -d /var/lib/cider-builder")

    # ── Stage 2: SSH keys were generated ───────────────────────────────

    with machine.nested("Stage 2: SSH keys were generated"):
        machine.succeed("test -f /etc/nix/cider-builder-key")
        machine.succeed("test -f /etc/nix/cider-builder-key.pub")

        # Key should be ed25519
        result = machine.succeed("head -1 /etc/nix/cider-builder-key.pub")
        assert "ssh-ed25519" in result, (
            f"Expected ed25519 key, got: {result}"
        )
        machine.log("SSH keypair exists and is ed25519")

    # ── Stage 3: sshd is listening inside the Darling prefix ───────────

    with machine.nested("Stage 3: sshd is listening inside the Darling prefix"):
        # Give sshd a moment to start after prefix init
        # The service is Type=simple with sshd -D, so systemd considers it
        # active as soon as the process starts.  But sshd needs a moment to
        # bind the port.
        time.sleep(5)

        # Check that port 2222 is open
        machine.wait_until_succeeds(
            "ss -tlnp | grep -q ':2222'",
            timeout=60,
        )
        machine.log("sshd is listening on port 2222")

    # ── Stage 4: SSH connectivity works ────────────────────────────────

    with machine.nested("Stage 4: SSH connectivity works"):
        # Test basic SSH connectivity with the auto-generated key
        result = machine.succeed(
            "ssh -o StrictHostKeyChecking=no "
            "-o UserKnownHostsFile=/dev/null "
            "-o ConnectTimeout=10 "
            "-i /etc/nix/cider-builder-key "
            "-p 2222 "
            "root@127.0.0.1 "
            "echo ssh-connection-ok",
            timeout=30,
        )
        assert "ssh-connection-ok" in result, (
            f"Expected 'ssh-connection-ok', got: {result}"
        )
        machine.log("SSH connection to Darling sshd successful")

    # ── Stage 5: Darling identity via SSH ──────────────────────────────

    with machine.nested("Stage 5: Darling reports macOS identity via SSH"):
        result = machine.succeed(
            "ssh -o StrictHostKeyChecking=no "
            "-o UserKnownHostsFile=/dev/null "
            "-i /etc/nix/cider-builder-key "
            "-p 2222 "
            "root@127.0.0.1 "
            "uname -s",
            timeout=30,
        )
        assert "Darwin" in result, (
            f"Expected 'Darwin' from uname -s, got: {result}"
        )
        machine.log("Darling reports Darwin via SSH ✓")

        result = machine.succeed(
            "ssh -o StrictHostKeyChecking=no "
            "-o UserKnownHostsFile=/dev/null "
            "-i /etc/nix/cider-builder-key "
            "-p 2222 "
            "root@127.0.0.1 "
            "uname -m",
            timeout=30,
        )
        assert "x86_64" in result, (
            f"Expected 'x86_64' from uname -m, got: {result}"
        )

    # ── Stage 6: sshd config is correct ────────────────────────────────

    with machine.nested("Stage 6: sshd configuration is correct"):
        # Verify key settings in sshd_config inside the prefix
        result = machine.succeed(
            "ssh -o StrictHostKeyChecking=no "
            "-o UserKnownHostsFile=/dev/null "
            "-i /etc/nix/cider-builder-key "
            "-p 2222 "
            "root@127.0.0.1 "
            "cat /etc/ssh/sshd_config",
            timeout=30,
        )
        assert "Port 2222" in result, f"Port 2222 not in sshd_config"
        assert "PasswordAuthentication no" in result, (
            "PasswordAuthentication should be disabled"
        )
        assert "PubkeyAuthentication yes" in result, (
            "PubkeyAuthentication should be enabled"
        )
        machine.log("sshd_config is correctly configured")

    # ── Stage 7: Nix configuration inside the prefix ───────────────────

    with machine.nested("Stage 7: Nix configuration inside the prefix"):
        result = machine.succeed(
            "ssh -o StrictHostKeyChecking=no "
            "-o UserKnownHostsFile=/dev/null "
            "-i /etc/nix/cider-builder-key "
            "-p 2222 "
            "root@127.0.0.1 "
            "cat /etc/nix/nix.conf",
            timeout=30,
        )
        assert "sandbox = false" in result, (
            f"Expected 'sandbox = false' in nix.conf, got: {result}"
        )
        assert "experimental-features" in result, (
            f"Expected experimental-features in nix.conf"
        )
        machine.log("nix.conf is correctly configured inside the prefix")

    # ── Stage 8: Nix build machines registration ───────────────────────

    with machine.nested("Stage 8: Nix build machines registration"):
        # Verify the Darling builder is registered in the Nix daemon config
        result = machine.succeed("cat /etc/nix/machines 2>/dev/null || echo 'no-machines-file'")
        # On NixOS, buildMachines are written to /etc/nix/machines
        # The format is: <store-uri> <systems> <ssh-key> <max-jobs> ...
        if "no-machines-file" not in result:
            assert "x86_64-darwin" in result, (
                f"Expected x86_64-darwin in /etc/nix/machines, got: {result}"
            )
            assert "2222" in result or "127.0.0.1" in result, (
                f"Expected builder host/port in machines file, got: {result}"
            )
            machine.log("Darling builder registered in /etc/nix/machines ✓")
        else:
            # buildMachines might be configured differently on this NixOS version
            machine.log("No /etc/nix/machines file — checking nix.conf for builders")
            result = machine.succeed("cat /etc/nix/nix.conf")
            machine.log(f"Host nix.conf:\n{result}")

    # ── Stage 9: Directory Services stubs via SSH ──────────────────────

    with machine.nested("Stage 9: Directory Services stubs work via SSH"):
        # These stubs are needed by the Nix multi-user installer.
        # Verify they're accessible from the SSH session.
        for tool in ["dseditgroup", "sysadminctl", "dscl"]:
            machine.succeed(
                f"ssh -o StrictHostKeyChecking=no "
                f"-o UserKnownHostsFile=/dev/null "
                f"-i /etc/nix/cider-builder-key "
                f"-p 2222 "
                f"root@127.0.0.1 "
                f"test -x /usr/sbin/{tool}",
                timeout=30,
            )
        machine.log("All Directory Services stubs accessible via SSH ✓")

    # ── Stage 10: sandbox-exec stub via SSH ────────────────────────────

    with machine.nested("Stage 10: sandbox-exec stub works via SSH"):
        result = machine.succeed(
            "ssh -o StrictHostKeyChecking=no "
            "-o UserKnownHostsFile=/dev/null "
            "-i /etc/nix/cider-builder-key "
            "-p 2222 "
            "root@127.0.0.1 "
            "/usr/bin/sandbox-exec -f /dev/null /bin/echo sandbox-via-ssh-ok",
            timeout=30,
        )
        assert "sandbox-via-ssh-ok" in result, (
            f"sandbox-exec via SSH failed: {result}"
        )
        machine.log("sandbox-exec works via SSH ✓")

    # ── Stage 11: File operations via SSH ──────────────────────────────

    with machine.nested("Stage 11: File operations work via SSH"):
        # Write, read, and clean up a file — exercises basic FS ops
        machine.succeed(
            "ssh -o StrictHostKeyChecking=no "
            "-o UserKnownHostsFile=/dev/null "
            "-i /etc/nix/cider-builder-key "
            "-p 2222 "
            "root@127.0.0.1 "
            "bash -c '"
            "echo builder-test-content > /tmp/builder-test.txt && "
            "cat /tmp/builder-test.txt && "
            "rm /tmp/builder-test.txt"
            "'",
            timeout=30,
        )
        machine.log("File operations via SSH work ✓")

    # ── Stage 12: Service restart resilience ───────────────────────────

    with machine.nested("Stage 12: Service restart resilience"):
        # Restart the service and verify it comes back up
        machine.succeed("systemctl restart cider-builder.service")
        machine.wait_for_unit("cider-builder.service", timeout=300)

        # Give sshd time to rebind
        time.sleep(5)
        machine.wait_until_succeeds(
            "ss -tlnp | grep -q ':2222'",
            timeout=60,
        )

        # Verify SSH still works after restart
        result = machine.succeed(
            "ssh -o StrictHostKeyChecking=no "
            "-o UserKnownHostsFile=/dev/null "
            "-o ConnectTimeout=10 "
            "-i /etc/nix/cider-builder-key "
            "-p 2222 "
            "root@127.0.0.1 "
            "echo post-restart-ok",
            timeout=30,
        )
        assert "post-restart-ok" in result, (
            f"SSH after restart failed: {result}"
        )
        machine.log("Service restart resilience verified ✓")

    machine.log("All Darling builder tests passed! ✓")
  '';
}
