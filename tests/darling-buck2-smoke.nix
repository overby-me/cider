# NixOS VM test: the BUCK2-built Darling boots and runs bash.
#
# tests/darling-smoke.nix is the endpoint, and it cannot pass yet: it exercises uname,
# sw_vers, the coreutils, sandbox-exec, diskutil, dscl, dseditgroup and sysadminctl, and the
# buck2 port is generated from the SYSTEM component scope, which builds none of them. The
# cli scope adds 626 link edges and still lacks the four DirectoryService tools, so the
# existing test needs cli plus stock -- essentially all of Darling.
#
# This asserts what IS ported, in the same harness: the container comes up and /bin/bash
# runs inside it. Bash builtins only, since there is no userland at this scope. It is the
# VM-side twin of scripts/buck-bash-check.sh.
#
# Usage:
#   nix build .#checks.x86_64-linux.darling-buck2-smoke -L
{
  pkgs,
  darling,
  ...
}: let
  nixos-lib = import (pkgs.path + "/nixos/lib") {};
in
  nixos-lib.runTest {
    name = "darling-buck2-smoke";

    hostPkgs = pkgs;

    nodes.machine = {...}: {
      virtualisation = {
        memorySize = 2048;
        diskSize = 8192;
        cores = 2;
      };

      environment.systemPackages = [darling];

      # Darling enters a user namespace before it does anything else.
      boot.kernel.sysctl."kernel.unprivileged_userns_clone" = 1;
    };

    testScript = ''
      machine.start()
      machine.wait_for_unit("default.target")

      with machine.nested("the launcher is installed"):
          machine.succeed("command -v darling-buck2")

      with machine.nested("the container boots and bash runs"):
          # First run also creates the prefix, which is the slow part.
          out = machine.succeed(
              "darling-buck2 shell /bin/bash -c "
              "'echo BUCK2_BASH_OK $BASH_VERSION $MACHTYPE'",
              timeout=300,
          )
          assert "BUCK2_BASH_OK" in out, f"bash did not run: {out}"
          # Darwin's bash is 3.2.57; the host's is 5.x, so the version is also the proof
          # that this is the GUEST binary and not the one that launched it.
          assert "3.2.57" in out, f"not the Darwin bash: {out}"
          assert "darwin" in out, f"not a Darwin machine type: {out}"

      with machine.nested("exit codes propagate out of the container"):
          machine.succeed("darling-buck2 shell /bin/bash -c 'exit 0'")
          machine.fail("darling-buck2 shell /bin/bash -c 'exit 1'")
    '';
  }
