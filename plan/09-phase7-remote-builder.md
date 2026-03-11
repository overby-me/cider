# Phase 7 — Nixpkgs `x86_64-darwin` Remote Builder

**Priority**: P2 · **Effort**: L (4–8 weeks) · **Depends on**: Phase 4 (derivation building), Phase 5 (Nix daemon)

The ultimate goal of this project: use Darling as a **remote builder** so that a
Linux host's Nix daemon can offload `x86_64-darwin` builds to a Darling
instance — just as it would offload to a real macOS machine over SSH.

This unlocks the ability for any NixOS machine to build and test Darwin packages
without Apple hardware.

---

## Context

Nix supports remote builds via two mechanisms:

1. **SSH-based remote builders** (`nix.buildMachines`): The local Nix daemon
   connects to a remote machine over SSH, copies the derivation closure, runs
   the build remotely, and copies the result back. The remote machine must run
   `nix-daemon` and accept SSH connections.

2. **Build hooks**: A custom `build-hook` program that Nix invokes when it
   encounters a derivation for a system it can't build locally. The hook decides
   where and how to build it.

For Darling, the SSH approach is the most natural: run `sshd` inside Darling,
configure the host's Nix daemon to treat it as a remote builder for
`x86_64-darwin`, and let the standard Nix remote-build protocol handle the rest.

An alternative is a custom build hook that calls `darling shell` directly,
avoiding SSH overhead. Both approaches are covered below.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    Linux Host (NixOS)                     │
│                                                          │
│  User runs: nix build .#myPackage --system x86_64-darwin │
│      │                                                   │
│      ▼                                                   │
│  ┌──────────────────────────────────┐                    │
│  │  Nix Daemon (Linux)              │                    │
│  │  system = x86_64-linux           │                    │
│  │  buildMachines includes:         │                    │
│  │    { hostName = "darling-vm";    │                    │
│  │      systems = ["x86_64-darwin"];│                    │
│  │      sshKey = "..."; }           │                    │
│  └──────────┬───────────────────────┘                    │
│             │ SSH (or darling-exec)                       │
│             ▼                                            │
│  ┌──────────────────────────────────┐                    │
│  │  Darling Container               │                    │
│  │  ┌────────────────────────────┐  │                    │
│  │  │  sshd (port 2222)         │  │                    │
│  │  │  nix-daemon                │  │                    │
│  │  │  sandbox-exec stub         │  │                    │
│  │  │  /nix/store (shared)       │──┼── bind mount ──┐  │
│  │  └────────────────────────────┘  │                │  │
│  └──────────────────────────────────┘                │  │
│                                                      │  │
│  /nix/store ◄────────────────────────────────────────┘  │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

The key insight is the **shared `/nix/store`**: by bind-mounting or symlinking
the host's `/nix/store` into the Darling prefix, we avoid the expensive step of
copying store paths back and forth over SSH. The SSH connection is still used for
the build protocol (derivation transfer, build log streaming, result
registration) but the actual store content is shared via the filesystem.

---

## Tasks

### 7.1 — Run `sshd` Inside Darling

Set up an SSH server inside the Darling prefix so the host's Nix daemon can
connect to it as a remote builder.

**Steps**:

1. **Install sshd**: Darling ships OpenSSH (`src/external/openssh/`). Verify
   that `/usr/sbin/sshd` exists in the prefix and is functional.

2. **Generate host keys**:
   ```bash
   darling shell ssh-keygen -A
   ```

3. **Configure sshd** (`/etc/ssh/sshd_config` inside the prefix):
   ```
   Port 2222
   ListenAddress 127.0.0.1
   PermitRootLogin yes
   PubkeyAuthentication yes
   AuthorizedKeysFile .ssh/authorized_keys
   PasswordAuthentication no
   UsePAM no
   Subsystem sftp /usr/libexec/sftp-server
   ```

   Using port 2222 avoids conflict with the host's sshd on port 22.

4. **Set up SSH keys**: Generate a keypair for the Nix daemon to use:
   ```bash
   ssh-keygen -t ed25519 -N "" -f /etc/nix/darling-builder-key
   darling shell mkdir -p /var/root/.ssh
   cat /etc/nix/darling-builder-key.pub | darling shell tee /var/root/.ssh/authorized_keys
   darling shell chmod 600 /var/root/.ssh/authorized_keys
   ```

5. **Start sshd**:
   ```bash
   darling shell /usr/sbin/sshd -f /etc/ssh/sshd_config
   ```

6. **Verify connectivity**:
   ```bash
   ssh -i /etc/nix/darling-builder-key -p 2222 root@127.0.0.1 echo ok
   # Expected: ok
   ```

**Potential issues**:

- **Network stack**: Darling's network layer needs to support `bind()` on
  `127.0.0.1:2222` and `accept()` incoming connections. Since Darling maps to
  Linux sockets, this should work, but verify.

- **PTY allocation**: SSH uses pseudo-terminals. Darling needs working `/dev/ptmx`
  and `openpty()`. Non-interactive commands (which is what Nix uses) may not need
  a PTY, but the SSH handshake might still require basic PTY support.

- **`sshd` privilege separation**: OpenSSH's privilege separation uses `fork`,
  `setuid`, and `chroot`. If these don't work inside Darling, configure sshd
  with `UsePrivilegeSeparation no` (deprecated but functional).

- **PAM**: Set `UsePAM no` since Darling doesn't implement PAM.

---

### 7.2 — Configure the Host as a Remote Build Client

Add the Darling instance as a remote builder in the host's Nix configuration.

**NixOS configuration**:

```nix
nix.buildMachines = [{
  hostName = "127.0.0.1";
  port = 2222;
  systems = [ "x86_64-darwin" ];
  sshUser = "root";
  sshKey = "/etc/nix/darling-builder-key";
  maxJobs = 4;
  speedFactor = 1;  # lower than native builders; adjust based on benchmarks
  supportedFeatures = [ ];
  mandatoryFeatures = [ ];
}];

nix.distributedBuilds = true;

# Optional: only use the Darling builder for Darwin, not for Linux
nix.settings.extra-platforms = [ "x86_64-darwin" ];
```

**Verification**:

```bash
# Test that Nix can connect to the builder
nix store ping --store ssh://root@127.0.0.1:2222

# Test a remote build
nix build --expr 'derivation { name = "test"; builder = "/bin/bash"; args = ["-c" "echo ok > $out"]; system = "x86_64-darwin"; }' -L

# The build should be offloaded to the Darling instance
```

**Troubleshooting**:

```bash
# Check if the Nix daemon can reach sshd
sudo -u nix-daemon ssh -i /etc/nix/darling-builder-key -p 2222 root@127.0.0.1 nix --version

# Check the Nix daemon logs for builder connection errors
journalctl -u nix-daemon -f

# Verify the Darling sshd is listening
ss -tlnp | grep 2222
```

---

### 7.3 — Shared `/nix/store`

The naive remote-build setup copies store paths over SSH, which is extremely slow
for large closures. Since the Darling instance runs on the same machine, we can
share the store filesystem directly.

**Mechanism**: Darling mounts the host's root filesystem at `/Volumes/SystemRoot`
inside the prefix. The host's `/nix/store` is therefore accessible at
`/Volumes/SystemRoot/nix/store` from within Darling.

**Setup**:

```bash
# Inside the Darling prefix, symlink /nix to the host's /nix
darling shell ln -sf /Volumes/SystemRoot/nix /nix
```

Or, if that conflicts with Darling's overlayfs:

```bash
# Bind mount the host's /nix into the prefix
# This may need to be done during prefix initialization in darlingserver
mount --bind /nix ~/.darling/nix
```

**Benefits**:

- **No copy overhead**: Store paths don't need to be transferred over SSH. The
  Nix daemon on both sides sees the same physical files.
- **Shared garbage collection**: The host's GC manages the shared store.
- **Instant result availability**: After a Darwin build completes, its output is
  immediately available on the host without copying.

**Caveats**:

- **Store database**: Nix's SQLite database (`/nix/var/nix/db/db.sqlite`) must
  not be shared between the host and Darling Nix daemons — they're different
  Nix instances with potentially different database schemas. Each needs its own
  database.

  Solution: Configure the Darling Nix instance to use a different database
  location:
  ```
  # In /etc/nix/nix.conf inside Darling:
  store = /nix
  state = /var/nix  # Darling-local state, not shared
  ```
  Or use a local overlay for `/nix/var` while sharing `/nix/store`.

- **Concurrent writes**: If both the host and Darling write to `/nix/store`
  simultaneously, there's a risk of corruption. Mitigate by:
  - Making the Darling Nix daemon the exclusive writer for `x86_64-darwin` paths.
  - Using Nix's content-addressed store paths (which are safe for concurrent
    writes since paths are determined by content).
  - Using file-level locking (`fcntl`) which works across the shared mount.

- **Permission mapping**: Darling's UID/GID namespace may differ from the host's.
  Ensure that files written by Darling's `_nixbldN` users are readable by the
  host's Nix daemon. This may require mapping UIDs or using a shared `nixbld`
  group.

**Fallback**: If shared store proves too complex, fall back to SSH-based copying.
It's slower but simpler and guaranteed correct. Use Nix's `--builders` flag with
`ssh-ng://` protocol which has optimised store path transfer.

---

### 7.4 — Alternative: Custom Build Hook (No SSH)

Instead of SSH, implement a custom Nix build hook that invokes `darling shell`
directly. This avoids the SSH setup entirely and may have lower overhead.

**How Nix build hooks work**:

1. Nix calls the `build-hook` program (configured in `nix.conf`) when a build
   can't be performed locally.
2. The hook reads the derivation path and system type from stdin.
3. The hook decides whether to accept the build. If yes, it outputs the builder
   machine specification.
4. Nix then proceeds to run the build on that machine.

**Custom hook — `darling-build-hook`**:

```bash
#!/usr/bin/env bash
# darling-build-hook — Nix build hook that offloads x86_64-darwin builds to Darling

set -euo pipefail

# Read build request from Nix
# Protocol: https://nixos.org/manual/nix/stable/advanced-topics/distributed-builds
read -r drv_path system

if [[ "$system" != "x86_64-darwin" ]]; then
    echo "# decline"  # Not a Darwin build, let Nix handle it
    exit 0
fi

echo "# accept"
echo "darling-builder x86_64-darwin /etc/nix/darling-builder-key 4 1"

# Nix will now SSH to "darling-builder" (which must resolve, or use the
# machines file). Alternatively, this hook could run the build directly:
#
# darling shell nix-store --realise "$drv_path"
# echo "$drv_path"
```

**Note**: The build hook protocol is somewhat complex and version-dependent. The
SSH approach (7.1/7.2) is more battle-tested and recommended for initial
implementation. The custom hook is an optimisation for later.

**Nix configuration for the hook**:

```nix
nix.settings.build-hook = "/path/to/darling-build-hook";
```

---

### 7.5 — NixOS Module for the Darling Builder

Wrap all the setup (sshd, keys, store sharing, `nix.buildMachines`) into a
reusable NixOS module.

**Module file**: `nixosModules/darling-builder.nix`

```nix
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.darling-builder;
in {
  options.services.darling-builder = {
    enable = mkEnableOption "Darling-based x86_64-darwin remote builder";

    port = mkOption {
      type = types.port;
      default = 2222;
      description = "SSH port for the Darling builder";
    };

    maxJobs = mkOption {
      type = types.int;
      default = 4;
      description = "Maximum concurrent builds on the Darling builder";
    };

    speedFactor = mkOption {
      type = types.int;
      default = 1;
      description = "Speed factor (lower = deprioritised vs native builders)";
    };

    shareStore = mkOption {
      type = types.bool;
      default = true;
      description = "Share /nix/store between host and Darling (avoids copying)";
    };

    sshKeyPath = mkOption {
      type = types.str;
      default = "/etc/nix/darling-builder-key";
      description = "Path to the SSH private key for connecting to the builder";
    };
  };

  config = mkIf cfg.enable {
    # Ensure Darling is available
    programs.darling.enable = true;

    # Generate SSH keys if they don't exist
    system.activationScripts.darling-builder-keys = ''
      if [ ! -f ${cfg.sshKeyPath} ]; then
        ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -N "" -f ${cfg.sshKeyPath}
        chown root:root ${cfg.sshKeyPath}
        chmod 600 ${cfg.sshKeyPath}
      fi
    '';

    # Set up the Darling prefix with sshd and Nix
    systemd.services.darling-builder = {
      description = "Darling x86_64-darwin Nix builder";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStartPre = [
          # Initialize prefix and install Nix if needed
          "${pkgs.writeShellScript "darling-builder-init" ''
            darling shell test -x /usr/sbin/sshd || exit 1
            darling shell test -x /usr/bin/sandbox-exec || exit 1

            # Set up SSH authorized keys
            darling shell mkdir -p /var/root/.ssh
            cat ${cfg.sshKeyPath}.pub | darling shell tee /var/root/.ssh/authorized_keys > /dev/null
            darling shell chmod 600 /var/root/.ssh/authorized_keys

            # Generate host keys if needed
            darling shell test -f /etc/ssh/ssh_host_ed25519_key || darling shell ssh-keygen -A

            ${optionalString cfg.shareStore ''
              # Symlink /nix to host's /nix via /Volumes/SystemRoot
              darling shell ln -sf /Volumes/SystemRoot/nix /nix 2>/dev/null || true
            ''}
          ''}"
        ];
        ExecStart = "${pkgs.darling}/bin/darling shell /usr/sbin/sshd -D -f /etc/ssh/sshd_config -p ${toString cfg.port}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # Register as a Nix remote builder
    nix.buildMachines = [{
      hostName = "127.0.0.1";
      port = cfg.port;
      systems = [ "x86_64-darwin" ];
      sshUser = "root";
      sshKey = cfg.sshKeyPath;
      maxJobs = cfg.maxJobs;
      speedFactor = cfg.speedFactor;
      supportedFeatures = [ ];
      mandatoryFeatures = [ ];
    }];

    nix.distributedBuilds = true;
  };
}
```

**Usage** (in a NixOS configuration):

```nix
{
  imports = [ ./path/to/darling-nix/nixosModules/darling-builder.nix ];

  services.darling-builder = {
    enable = true;
    maxJobs = 8;
    shareStore = true;
  };
}
```

After `nixos-rebuild switch`, the user can immediately build Darwin packages:

```bash
nix build nixpkgs#hello --system x86_64-darwin
```

---

### 7.6 — Test Top Nixpkgs Packages

Once the builder is operational, systematically test building the most
commonly-used `x86_64-darwin` packages from Nixpkgs.

**Tier 1 — Must pass** (fetch from binary cache, minimal building):

| Package | Why It Matters |
|---|---|
| `hello` | Simplest C program; validates full stdenv pipeline |
| `which` | Trivial utility; shell script install |
| `coreutils` | Foundation of every build; exercises many syscalls |
| `bash` | Builder shell; must work perfectly |
| `gnugrep` | Used in stdenv setup scripts |
| `gnused` | Used in stdenv setup scripts |
| `gawk` | Used in stdenv setup scripts |

**Tier 2 — Should pass** (moderate complexity):

| Package | Why It Matters |
|---|---|
| `curl` | Needed for fetching; exercises TLS + network |
| `git` | Needed for `fetchgit` in derivations |
| `python3` | Common build dependency; complex build |
| `jq` | Used in many CI scripts |
| `openssl` | Crypto library; exercises many low-level APIs |
| `pkg-config` | Build tool; should be straightforward |
| `cmake` | Build tool; complex but well-tested |

**Tier 3 — Stretch** (complex, many dependencies):

| Package | Why It Matters |
|---|---|
| `nodejs` | Large build; JavaScript ecosystem foundation |
| `go` | Self-hosting compiler; stresses the runtime |
| `rustc` | Very large build; exercises many syscalls |
| `llvm` | Compiler infrastructure; tests C++ heavily |
| `ghc` | Haskell compiler; extremely complex build |

**Tracking**: Use the compatibility matrix from [Phase 6](./08-phase6-ci.md)
(task 6.5) to track pass/fail rates. Run this as a nightly CI job and publish
results to a dashboard or markdown file in the repo.

**When something fails**: For each failure:

1. Capture the full build log.
2. Identify the first error (often buried under cascading failures).
3. Determine if it's a syscall issue (→ Phase 1), a sandbox issue (→ Phase 2),
   a coreutils issue (→ Phase 4.6), or a new category.
4. File an issue with the `[compat]` label.
5. Add it to `plan/syscall-triage.md` if it's a new syscall.

---

### 7.7 — Documentation and Templates

Create user-facing documentation so others can set up their own Darling builders.

**Deliverables**:

1. **NixOS wiki page**: Step-by-step guide for setting up a Darling-based Darwin
   builder on NixOS. Cover both the NixOS module approach and the manual setup.

2. **Flake template** (`templates/darling-builder`):
   ```bash
   nix flake init -t github:user/darling-nix#darling-builder
   ```
   Generates a minimal `flake.nix` + NixOS configuration that sets up the
   builder.

3. **Troubleshooting guide**: Common issues and their solutions:
   - "Connection refused" → sshd not running or wrong port
   - "Permission denied" → SSH key mismatch
   - "Build failed with signal 11" → unimplemented syscall → file an issue
   - "Store path not valid" → shared store database mismatch
   - "builder for '...' failed with exit code 1" → check the build log

4. **Performance tuning guide**: Tips for getting the best performance:
   - Use binary substitution aggressively (`substituters` in `nix.conf`)
   - Set `max-jobs` based on available CPU cores
   - Use `--cores N` to limit per-build parallelism
   - Enable store sharing to avoid copy overhead
   - Put the Nix store on fast storage (SSD/NVMe)

---

## Security Considerations

Running sshd inside Darling on `127.0.0.1:2222` is relatively safe:

- **Loopback only**: The SSH server only listens on localhost. It's not reachable
  from the network.
- **Key-based auth only**: Password authentication is disabled. Only the specific
  key generated for the builder can connect.
- **Contained environment**: The Darling prefix is isolated from the host via
  namespaces. Even if an attacker gains access to the Darling sshd, they're
  inside a container with limited host access.
- **Shared store risk**: If `/nix/store` is shared, a compromised builder could
  write malicious store paths. Mitigate by:
  - Only sharing the store read-only from the host side.
  - Using Nix's content-addressing to verify outputs.
  - Running the Darling builder with minimal host capabilities.

For production use, consider running the Darling builder inside an additional
isolation layer (systemd-nspawn, VM, or dedicated user namespace) to defense-in-
depth against container escapes.

---

## Performance Expectations

With store sharing enabled:

| Operation | Expected Overhead vs Native macOS |
|---|---|
| Binary substitution | ~1.2–1.5× (NAR unpack syscall overhead) |
| Nix evaluation | ~2–5× (CPU-bound, translation overhead) |
| C compilation (clang) | ~3–8× (many syscalls, process spawning) |
| Linking (ld64) | ~2–4× (I/O bound, moderate syscall count) |
| Full `hello` build | ~3–5× (mostly substitution + simple compile) |
| Full `python3` build | ~5–10× (complex build, many phases) |

Without store sharing (SSH copy):

- Add ~30 seconds per 100 MB of closure for each copy direction.
- A typical stdenv closure is ~500 MB, so expect ~2.5 minutes overhead per build
  just for copying.

**Recommendation**: Always enable store sharing for local Darling builders. SSH
copy mode is only useful for remote machines running Darling (future work).

---

## Verification Checklist

After completing Phase 7, ALL of the following must pass:

- [ ] `sshd` runs inside Darling and accepts SSH connections from the host
- [ ] `ssh -p 2222 root@127.0.0.1 nix --version` returns a Nix version string
- [ ] Host's `nix.buildMachines` includes the Darling builder
- [ ] `nix build --expr '...' --system x86_64-darwin` offloads to the Darling builder
- [ ] Build log is streamed back to the host in real time
- [ ] Build output is available in the host's `/nix/store` after completion
- [ ] `/nix/store` is shared (no SSH copy overhead) when `shareStore = true`
- [ ] `nix build nixpkgs#hello --system x86_64-darwin` succeeds (Tier 1 package)
- [ ] At least 5/7 Tier 1 packages build successfully
- [ ] At least 3/7 Tier 2 packages build successfully
- [ ] The NixOS module (`services.darling-builder`) works end-to-end
- [ ] Documentation exists for manual and module-based setup

---

## What This Enables

Once Phase 7 is working, any NixOS user can:

```nix
# flake.nix
{
  outputs = { self, nixpkgs }: {
    packages.x86_64-darwin.myApp = nixpkgs.legacyPackages.x86_64-darwin.callPackage ./. {};
  };
}
```

```bash
# Build a Darwin package on a Linux machine
nix build .#packages.x86_64-darwin.myApp
```

This is the same workflow they'd use with a real macOS remote builder, but
without needing Apple hardware. The Darling builder is transparent to the user —
they don't need to know or care that it's running inside a compatibility layer.

---

*[← Phase 6 — CI & Testing](./08-phase6-ci.md) | [Phase 8 — Stretch Goals →](./10-phase8-stretch.md)*