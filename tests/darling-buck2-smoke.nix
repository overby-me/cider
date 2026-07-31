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
        # More than the 2 cores and 2 GB the other VM tests use. The daemon runs the guest
        # on microthreads and the boot is timing-sensitive -- it flakes about one run in six
        # even on the host -- so a starved VM is the wrong place to find that out.
        memorySize = 4096;
        diskSize = 8192;
        cores = 4;
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
              # `log` is the test driver's OWN logger object, so binding it here fails the
              # driver's type check before the VM ever starts. Distinct names throughout.
              st_a, dslog = machine.execute("cat /tmp/ds.log 2>&1")
              st_b, procs = machine.execute("ps aux | grep -E 'darling|mldr' | grep -v grep")
              st_c, envinfo = machine.execute("sysctl kernel.unprivileged_userns_clone 2>&1; id")
              raise Exception(
                  f"status={status}\noutput={out!r}\n"
                  f"--- daemon log ---\n{dslog}\n--- processes ---\n{procs}\n"
                  f"--- env ---\n{envinfo}"
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
