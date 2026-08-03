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
# VM-side twin of scripts/buck-bash-check.nu.
#
# EVERY darling invocation here closes stdin. That is not tidiness: the launcher waits on
# the caller's stdin, the driver's control channel never closes it, and the driver in turn
# waits for stdout to be closed (its own docstring warns that a detaching command must
# close it). The result was 124 with the output thrown away, which read as a hang in
# Darling. Measured in four arms over one VM, one variable each: stdin inherited hangs,
# `< /dev/null` returns rc 0, setsid changes nothing, and a backgrounded command works
# because POSIX hands it /dev/null. The guest command had been succeeding the whole time.
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
              "'echo BUCK2_BASH_OK $BASH_VERSION $MACHTYPE' < /dev/null",
              timeout=300,
          )
          if "BUCK2_BASH_OK" not in out:
              # Everything a diagnosis needs, in ONE run: a VM test round trip is minutes.
              machine.execute("tail -40 /tmp/dp/darlingserver.log > /tmp/ds.log 2>&1")
              # `log` is the test driver's OWN logger object, so binding it here fails the
              # driver's type check before the VM ever starts. Distinct names throughout.
              st_a, dslog = machine.execute("cat /tmp/ds.log 2>&1")
              # WHAT IS STILL ALIVE and what it is blocked on. The first dump showed one
              # surviving process and told us nothing about why the caller never returned.
              st_b, procs = machine.execute(
                  "ps -eo pid,ppid,stat,wchan:24,args | "
                  "grep -E 'darling|mldr|shellspawn' | grep -v grep"
              )
              st_c, envinfo = machine.execute(
                  "id; echo ---; ls -la /tmp/dp 2>&1 | head -20; echo ---; "
                  "ls -ld /tmp/dp/Volumes/SystemRoot 2>&1; echo ---; "
                  "mount | grep -E 'overlay|/tmp/dp' 2>&1; echo ---; "
                  "dmesg | tail -15"
              )
              # THE FD TABLES, which is what actually separates the two readings, and the
              # reason the earlier "dtype for fd 2 -> /darlingserver.log" line was written up
              # as a cause and then disproved. On a WORKING host run there are two kinds of
              # guest, and they differ exactly here:
              #
              #   the persistent shellspawn INIT has fd 1/2 on darlingserver.log, by design --
              #   linux/launcher/src/main.rs redirects the daemon's stdio there so a one-shot
              #   command does not pin the caller's stdout open forever;
              #   the guest running the COMMAND has the caller's own fds, passed to it.
              #
              # So a log-file fd 2 is normal for the init and damning for a command guest. If
              # the only mldr here is the init, nothing ever spawned the command and the fd
              # line was never evidence about it; if a command guest exists holding log fds,
              # the fd passing is what broke. One dump answers which, and a VM round trip is
              # minutes, so it is worth taking every time.
              st_d, fdinfo = machine.execute(
                  "for p in $(pgrep -x darlingserver; pgrep -x mldr; pgrep -x darling-buck2); do "
                  "  echo \"== pid $p $(cat /proc/$p/comm 2>/dev/null)"
                  " syscall=$(awk '{print $1}' /proc/$p/syscall 2>/dev/null)"
                  " wchan=$(cat /proc/$p/wchan 2>/dev/null)\"; "
                  "  ls -l /proc/$p/fd 2>/dev/null | awk 'NR>1 && $9 <= 2 {print \"   fd\", $9, $10, $11}'; "
                  "done; echo '--- how many guests exist at all ---'; "
                  "echo \"mldr: $(pgrep -x -c mldr 2>/dev/null || echo 0)\"; "
                  "echo \"darlingserver: $(pgrep -x -c darlingserver 2>/dev/null || echo 0)\""
              )
              raise Exception(
                  f"status={status}\noutput={out!r}\n"
                  f"--- daemon log ---\n{dslog}\n--- processes ---\n{procs}\n"
                  f"--- fds, init versus command guest ---\n{fdinfo}\n"
                  f"--- env ---\n{envinfo}"
              )
          # Darwin's bash is 3.2.57; the host's is 5.x, so the version is also the proof
          # that this is the GUEST binary and not the one that launched it.
          assert "3.2.57" in out, f"not the Darwin bash: {out}"
          assert "darwin" in out, f"not a Darwin machine type: {out}"

      with machine.nested("exit codes propagate out of the container"):
          # The same environment as above, deliberately. This subtest used to set neither
          # DPREFIX nor DARLING_NO_LAUNCHD, so it booted a second prefix through LAUNCHD
          # and returned 1 for a command that exits 0. Arms with an explicit prefix and
          # no-launchd give rc 0 for exit 0 and print for echo, and the default prefix
          # behaves the same, so neither the prefix nor propagation was at fault. The
          # launchd path in a VM is its own question and belongs in its own test.
          env = "DPREFIX=/tmp/dp DARLING_NO_LAUNCHD=1 "
          machine.succeed(env + "darling-buck2 shell /bin/bash -c 'exit 0' < /dev/null")
          machine.fail(env + "darling-buck2 shell /bin/bash -c 'exit 1' < /dev/null")
    '';
  }
