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
          # execute(), not succeed(): a hang here is the interesting case, and succeed()
          # raises with the output thrown away. The prefix is given explicitly and SHORT --
          # the daemon's control socket lives inside it and a Unix socket path is capped at
          # 108 bytes.
          status, out = machine.execute(
              "DPREFIX=/tmp/dp DARLING_NO_LAUNCHD=1 "
              "darling-buck2 shell /bin/bash -c "
              "'echo BUCK2_BASH_OK $BASH_VERSION $MACHTYPE'",
              timeout=300,
          )
          if "BUCK2_BASH_OK" not in out:
              # Everything a diagnosis needs, in ONE run: a VM test round trip is minutes.
              machine.execute("tail -40 /tmp/dp/darlingserver.log > /tmp/ds.log 2>&1")
              # Not `_`: the test driver already binds that name to its logger, and the
              # type check rejects the assignment before the VM ever starts.
              log_st, log = machine.execute("cat /tmp/ds.log 2>&1")
              ps_st, ps = machine.execute("ps aux | grep -E 'darling|mldr' | grep -v grep")
              ns_st, ns = machine.execute("sysctl kernel.unprivileged_userns_clone 2>&1; id")
              raise Exception(
                  f"status={status}\noutput={out!r}\n"
                  f"--- daemon log ---\n{log}\n--- processes ---\n{ps}\n--- env ---\n{ns}"
              )
          # Darwin's bash is 3.2.57; the host's is 5.x, so the version is also the proof
          # that this is the GUEST binary and not the one that launched it.
          assert "3.2.57" in out, f"not the Darwin bash: {out}"
          assert "darwin" in out, f"not a Darwin machine type: {out}"

      with machine.nested("exit codes propagate out of the container"):
          machine.succeed("darling-buck2 shell /bin/bash -c 'exit 0'")
          machine.fail("darling-buck2 shell /bin/bash -c 'exit 1'")
    '';
  }
