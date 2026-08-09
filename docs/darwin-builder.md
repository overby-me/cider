# Setting Up a Darling-Based Darwin Builder

> Build `x86_64-darwin` Nix packages on Linux — no Apple hardware required.

This guide walks you through setting up [Darling](https://www.darlinghq.org/)
as a Nix remote builder so your Linux machine can build macOS (`x86_64-darwin`)
derivations. This is analogous to how Wine enables running Windows binaries on
Linux, but for macOS build toolchains.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start (NixOS Module)](#quick-start-nixos-module)
- [Manual Setup](#manual-setup)
- [Shared /nix/store](#shared-nixstore)
- [Verifying the Builder](#verifying-the-builder)
- [Alternative: Custom Build Hook (No SSH)](#alternative-custom-build-hook-no-ssh)
- [Performance Tuning](#performance-tuning)
- [Troubleshooting](#troubleshooting)
- [Security Considerations](#security-considerations)
- [Architecture](#architecture)

---

## Overview

Darling is a macOS compatibility layer for Linux that translates macOS system
calls into Linux equivalents. By running Nix inside Darling, we get a builder
that:

- Reports `builtins.currentSystem == "x86_64-darwin"`
- Executes Darwin derivations using macOS-compatible toolchains
- Integrates with Nix's remote builder infrastructure over SSH
- Can optionally share `/nix/store` with the host for zero-copy builds

**Two approaches are available:**

| Approach | Pros | Cons |
|----------|------|------|
| **NixOS Module** (SSH-based) | Declarative, integrates with `nix.buildMachines`, works with any Nix client | Requires sshd inside Darling |
| **Custom Build Hook** (no SSH) | Simpler setup, lower overhead | Only works locally, less standard |

---

## Prerequisites

- **Linux x86_64** host (NixOS recommended, but any Linux with Nix works)
- **Nix** with flakes enabled (`experimental-features = nix-command flakes`)
- **Kernel support**: unprivileged user namespaces and overlayfs
  ```bash
  # Check user namespace support
  sysctl kernel.unprivileged_userns_clone
  # Should be: kernel.unprivileged_userns_clone = 1

  # If not, enable it (NixOS handles this automatically):
  sudo sysctl kernel.unprivileged_userns_clone=1
  ```

---

## Quick Start (NixOS Module)

The fastest path on NixOS is the declarative module. Add this to your
NixOS configuration:

```nix
# /etc/nixos/flake.nix (or wherever your system flake is)
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    cider-nix = {
      url = "github:user/cider-nix";       # adjust to actual repo
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, cider-nix, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix

        # Base Darling support (programs.cider)
        cider-nix.nixosModules.nixos

        # Darling builder service (services.cider-builder)
        cider-nix.nixosModules.cider-builder

        {
          services.cider-builder = {
            enable = true;
            maxJobs = 4;
            shareStore = true;    # share /nix/store between host and Darling
          };
        }
      ];
    };
  };
}
```

Then rebuild and test:

```bash
# Apply the configuration
sudo nixos-rebuild switch

# Test connectivity to the Darling builder
cider-builder-test

# Build a Darwin package from your Linux host!
nix build nixpkgs#hello --system x86_64-darwin
```

### Module Options Reference

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable the Darling builder service |
| `package` | package | `pkgs.cider` | Darling package to use |
| `port` | int | `2222` | SSH port for the builder (inside Darling) |
| `maxJobs` | int | `1` | Maximum concurrent build jobs |
| `speedFactor` | int | `1` | Nix speed factor (lower = deprioritised vs native builders) |
| `shareStore` | bool | `false` | Share `/nix/store` between host and Darling via `/Volumes/SystemRoot` |
| `sshKeyPath` | path | `/etc/nix/cider-builder-key` | Path to the SSH private key for the Nix daemon |
| `prefixPath` | path | `/var/lib/cider-builder` | Path to the Darling prefix directory |
| `supportedFeatures` | list of str | `[]` | Nix supported features for this builder |
| `mandatoryFeatures` | list of str | `[]` | Nix mandatory features for this builder |
| `installNix` | bool | `true` | Automatically install Nix inside the Darling prefix |
| `nixVersion` | str | `"2.24.10"` | Nix version to install inside Darling |

---

## Manual Setup

If you're not on NixOS or prefer manual control, follow these steps.

### 1. Install Darling

```bash
# Using the flake
nix profile install github:user/cider-nix

# Or build from source
git clone https://github.com/user/cider-nix
cd cider-nix
nix build
export PATH="$(pwd)/result/bin:$PATH"
```

### 2. Initialise the Darling Prefix

```bash
# Boot Darling (creates the prefix at ~/.cider by default)
cider shell echo "Darling is working"

# Verify macOS identity
cider shell uname -s    # → Darwin
cider shell sw_vers      # → macOS 14.4.1 (Sonoma), build 23E224
```

### 3. Install Nix Inside Darling

Use the automated installer script:

```bash
./scripts/install-nix-in-cider.nu
```

Or install manually:

```bash
# Download the Nix installer inside Darling
cider shell bash -lc '
  curl -L https://nixos.org/nix/install -o /tmp/install-nix
  chmod +x /tmp/install-nix
  /tmp/install-nix --no-daemon
'
```

Verify:

```bash
./scripts/verify-nix.nu

# Or manually:
cider shell bash -lc "nix --version"
cider shell bash -lc "nix eval --raw --expr 'builtins.currentSystem'"
# → x86_64-darwin
```

### 4. Set Up sshd Inside Darling

```bash
# Generate host keys
cider shell ssh-keygen -A

# Write sshd config
cider shell tee /etc/ssh/sshd_config << 'EOF'
Port 2222
ListenAddress 127.0.0.1
PermitRootLogin yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM no
Subsystem sftp /usr/libexec/sftp-server
EOF

# Generate an SSH keypair for the Nix daemon
sudo ssh-keygen -t ed25519 -N "" -f /etc/nix/cider-builder-key

# Install the public key inside Darling
cider shell mkdir -p /var/root/.ssh
sudo cat /etc/nix/cider-builder-key.pub | cider shell tee /var/root/.ssh/authorized_keys
cider shell chmod 700 /var/root/.ssh
cider shell chmod 600 /var/root/.ssh/authorized_keys

# Start sshd
cider shell /usr/sbin/sshd -f /etc/ssh/sshd_config

# Verify connectivity
ssh -i /etc/nix/cider-builder-key -p 2222 -o StrictHostKeyChecking=no root@127.0.0.1 echo ok
# → ok
```

### 5. Register the Builder with Nix

Add to `/etc/nix/machines` (or use `nix.buildMachines` on NixOS):

```
ssh://root@127.0.0.1 x86_64-darwin /etc/nix/cider-builder-key 4 1 - - -
```

The fields are: `store-uri system ssh-key max-jobs speed-factor supported-features mandatory-features public-host-key`

Or in `nix.conf`:

```ini
builders = ssh://root@127.0.0.1:2222 x86_64-darwin /etc/nix/cider-builder-key 4 1 - - -
```

Enable distributed builds:

```ini
# In /etc/nix/nix.conf
builders-use-substitutes = true
```

### 6. Test a Build

```bash
# Ping the builder
nix store ping --store ssh://root@127.0.0.1:2222

# Build a trivial derivation
nix build --expr 'derivation {
  name = "hello-darwin";
  builder = "/bin/bash";
  args = ["-c" "echo hello from darwin > $out"];
  system = "x86_64-darwin";
}' -L

# Build a real package
nix build nixpkgs#hello --system x86_64-darwin -L
```

---

## Shared /nix/store

By default, Nix copies store paths over SSH to the builder and back. Since
Darling runs on the same machine, this is wasteful. You can share
`/nix/store` directly.

### How It Works

Darling mounts the host's root filesystem at `/Volumes/SystemRoot` inside the
prefix. This means the host's `/nix/store` is accessible at
`/Volumes/SystemRoot/nix/store` from within Darling.

### Setup

```bash
# Inside Darling, symlink /nix to the host's /nix
cider shell ln -sf /Volumes/SystemRoot/nix /nix
```

Or, if there's a conflict with Darling's overlay filesystem:

```bash
# Bind mount the host's /nix into the prefix
sudo mount --bind /nix ~/.cider/nix
```

### Important Caveats

1. **Separate databases**: The Nix SQLite database
   (`/nix/var/nix/db/db.sqlite`) must NOT be shared between the host and
   Darling. Each Nix instance needs its own database. Configure the Darling
   Nix instance to use separate state:

   ```ini
   # In /etc/nix/nix.conf inside Darling:
   store = /nix
   state = /var/nix
   ```

2. **Concurrent writes**: If both host and Darling write to `/nix/store`
   simultaneously, use content-addressed store paths (which are safe for
   concurrent writes) or ensure the Darling builder is the exclusive writer
   for `x86_64-darwin` paths.

3. **Permission mapping**: Darling's UID/GID namespace may differ from the
   host's. Ensure files written by Darling's `_nixbldN` users are readable
   by the host's Nix daemon.

### NixOS Module

If you're using the NixOS module, just set:

```nix
services.cider-builder.shareStore = true;
```

The module handles the symlink and state directory separation automatically.

---

## Verifying the Builder

### Automated Checks

```bash
# NixOS module: use the built-in connectivity test
cider-builder-test

# Manual setup: use the build hook check
./scripts/cider-build-hook --check

# Standalone Nix health-check
./scripts/verify-nix.nu
./scripts/verify-nix.nu --online   # also test network/cache access

# Run the compatibility matrix (after Nix builds work)
./tests/nix/compatibility-matrix.sh --tier 1
```

### Progressive Build Tests

The `build-trivial.nu` script tests derivation building at five increasing
levels of complexity:

```bash
# Run all five levels
./scripts/build-trivial.nu

# Target a specific level with debug output
./scripts/build-trivial.nu --level 1 --debug

# Levels:
#   1. Echo to $out — minimal: sandbox-exec → bash → file creation
#   2. Multi-line builder — mkdir, chmod, loops, multiple output files
#   3. Input transformation — builtins.toFile, sort, wc
#   4. Derivation dependency — one derivation consumes another's output
#   5. Binary substitution — fetch pre-built package from cache.nixos.org
```

### NixOS VM Tests

Run the full test suite without needing a live Darling instance:

```bash
# Smoke test (no network, fast)
nix build .#checks.x86_64-linux.cider-smoke -L

# Full Nix integration test (needs network)
nix build .#checks.x86_64-linux.nix-in-cider -L

# Remote builder test (sshd, SSH auth, service lifecycle)
nix build .#checks.x86_64-linux.cider-builder -L

# Directory Services stubs (pure shell, no Darling needed)
nix build .#checks.x86_64-linux.dirserv-stubs -L

# Run everything
nix flake check
```

---

## Alternative: Custom Build Hook (No SSH)

If you don't want to run sshd inside Darling, you can use the custom build
hook. This invokes `cider shell` directly instead of going through SSH.

### Setup

```bash
# Verify the hook environment is ready
./scripts/cider-build-hook --check

# Build a single derivation directly
./scripts/cider-build-hook --build /nix/store/...-foo.drv

# Print the machine spec line
./scripts/cider-build-hook --machine-spec
```

### Configure Nix to Use the Hook

In `nix.conf`:

```ini
builders = /path/to/cider-build-hook x86_64-darwin - 4 1 - - -
```

Or on NixOS:

```nix
nix.settings.builders = [
  "/path/to/cider-build-hook x86_64-darwin - 4 1 - - -"
];
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DARLING_BUILD_HOOK_DARLING` | `cider` | Path to the cider binary |
| `DARLING_BUILD_HOOK_PREFIX` | auto | Darling prefix path |
| `DARLING_BUILD_HOOK_NIX_PROFILE` | `/Users/root/.nix-profile/etc/profile.d/nix.sh` | Nix profile to source inside Darling |
| `DARLING_BUILD_HOOK_MAX_JOBS` | `4` | Maximum concurrent jobs |
| `DARLING_BUILD_HOOK_VERBOSE` | `0` | Verbosity level (0=quiet, 1=debug) |
| `DPREFIX` | auto | Fallback for prefix path |

---

## Performance Tuning

### Binary Substitution

The single most important performance optimization is to use binary
substitution aggressively. Most `x86_64-darwin` packages in Nixpkgs are
already built by Hydra and available from `cache.nixos.org`.

```ini
# In /etc/nix/nix.conf inside Darling:
substituters = https://cache.nixos.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
```

On the host:

```ini
# In /etc/nix/nix.conf on the host:
builders-use-substitutes = true
```

This tells Nix to let the builder download substitutes directly from the
cache, instead of building everything from source.

### Job Parallelism

```nix
services.cider-builder = {
  maxJobs = 4;       # concurrent derivations
};
```

Also limit per-build parallelism to avoid oversubscription:

```ini
# In /etc/nix/nix.conf inside Darling:
cores = 4
```

A good rule of thumb: `maxJobs × cores ≤ number of CPU cores`.

### Store Sharing

If you're building many packages, enable store sharing to eliminate the
SSH copy overhead:

```nix
services.cider-builder.shareStore = true;
```

This makes build outputs instantly available on the host without any
network transfer.

### Storage

Put the Darling prefix and Nix store on fast storage (SSD/NVMe). Nix builds
are I/O-heavy, and spinning disks will be a significant bottleneck.

### Speed Factor

If you have native Darwin builders (e.g., a Mac mini), set the Darling
builder's speed factor lower so Nix prefers the native machine:

```nix
services.cider-builder.speedFactor = 1;
# Native builder would be speedFactor = 10 or higher
```

---

## Troubleshooting

### "Connection refused" when connecting to the builder

**Cause**: sshd is not running inside the Darling prefix, or it's listening
on a different port.

```bash
# Check if sshd is listening
ss -tlnp | grep 2222

# Check if the Darling prefix is running
cider shell echo ok

# Restart sshd inside Darling
cider shell /usr/sbin/sshd -f /etc/ssh/sshd_config

# Check sshd logs
cider shell cat /var/log/sshd.log 2>/dev/null
```

### "Permission denied (publickey)"

**Cause**: SSH key mismatch between the host and the Darling prefix.

```bash
# Verify the key exists
ls -la /etc/nix/cider-builder-key

# Verify the public key is installed in Darling
cider shell cat /var/root/.ssh/authorized_keys

# Regenerate keys
sudo ssh-keygen -t ed25519 -N "" -f /etc/nix/cider-builder-key
sudo cat /etc/nix/cider-builder-key.pub | cider shell tee /var/root/.ssh/authorized_keys

# Test manually
ssh -vvv -i /etc/nix/cider-builder-key -p 2222 root@127.0.0.1 echo ok
```

### "builder for '...' failed with exit code 1"

**Cause**: The derivation build itself failed. Check the build log.

```bash
# Get the full build log
nix log /nix/store/...-failed.drv

# Or build with verbose output
nix build ... -L --keep-failed

# Check for unimplemented syscalls
cider shell bash -lc 'nix-build ...' 2>&1 | grep -i "unimplemented\|STUB"
```

### "Unimplemented syscall" errors

**Cause**: The derivation uses a macOS syscall that Darling doesn't implement yet.

```bash
# Run the syscall triage tool to identify the issue
./scripts/triage-syscalls.nu --output /tmp/triage.md

# Check the known triage table
cat PLAN.md
```

If you discover a new unimplemented syscall, please
[file an issue](https://github.com/darlinghq/darling/issues) with:

1. The exact syscall name and number
2. The derivation that triggered it
3. The full error message

### "Store path not valid" / database errors

**Cause**: When using shared `/nix/store`, the host and Darling Nix instances
may have different database states.

```bash
# Verify the store inside Darling
cider shell bash -lc 'nix-store --verify --check-contents'

# Re-register a missing path
cider shell bash -lc 'nix-store --register-validity <<< "..."'

# If all else fails, repair the store
cider shell bash -lc 'nix-store --verify --repair'
```

### "sandbox-exec: not found" or sandbox errors

**Cause**: The sandbox-exec stub is not installed in the prefix.

```bash
# Check if sandbox-exec is present
cider shell test -x /usr/bin/sandbox-exec && echo ok || echo missing

# Rebuild Darling with sandbox stubs
nix build .#cider
```

### Darling prefix won't start / crashes

```bash
# Check if ciderd is running
pgrep ciderd

# Try shutting down and re-initialising
cider shutdown
cider shell echo ok

# Check system requirements
sysctl kernel.unprivileged_userns_clone  # must be 1
```

### Build is extremely slow

See [Performance Tuning](#performance-tuning) above. The most common causes are:

1. **No binary substitution**: The builder is compiling everything from source.
   Make sure `substituters` and `builders-use-substitutes` are configured.
2. **No store sharing**: Large closures are being copied over SSH. Enable
   `shareStore = true`.
3. **Slow storage**: The Nix store is on a spinning disk. Move it to SSD.
4. **Oversubscription**: Too many concurrent jobs for available CPU cores.

---

## Security Considerations

- **sshd inside Darling**: The SSH server only listens on `127.0.0.1` (loopback),
  so it's not accessible from the network. Only key-based authentication is
  allowed — no passwords.

- **Root inside Darling**: The builder runs as root inside the Darling prefix,
  but this is a *virtual* root. Darling uses Linux user namespaces, so the
  "root" inside Darling maps to an unprivileged user on the host.

- **Store integrity**: When sharing `/nix/store`, Nix's content-addressed paths
  provide integrity guarantees — a path's name includes a hash of its contents,
  so tampering is detectable.

- **Network access**: Derivations built inside Darling can access the network
  unless the Nix sandbox restricts it. Fixed-output derivations (fetchers)
  need network access by design; regular builds should not.

- **Upstream trust**: This is an experimental project. It should not be used as
  a trusted builder for production deployments without thorough security review.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    Linux Host (NixOS)                     │
│                                                          │
│  ┌─────────────┐    SSH (localhost:2222)    ┌──────────┐ │
│  │  Nix Daemon  │ ──────────────────────── │  sshd    │ │
│  │             │    or build-hook pipe     │ (Darling)│ │
│  │  Offloads   │                           │          │ │
│  │  x86_64-    │                           │ ┌──────┐ │ │
│  │  darwin     │                           │ │ Nix  │ │ │
│  │  builds     │                           │ │daemon│ │ │
│  └─────────────┘                           │ └──────┘ │ │
│         │                                  │          │ │
│         │              ┌───────────────────┤          │ │
│         ▼              │ /Volumes/         │          │ │
│  ┌─────────────┐       │ SystemRoot/nix ──▶│ /nix    │ │
│  │ /nix/store  │◀──────┘ (shared store)   │ (symlink)│ │
│  │             │                           │          │ │
│  └─────────────┘                           └──────────┘ │
│                      Darling Prefix                      │
│                    (~/.cider or                         │
│                     /var/lib/cider-builder)             │
└──────────────────────────────────────────────────────────┘
```

**Key components:**

| Component | Role |
|-----------|------|
| **ciderd** | Userspace daemon that translates macOS syscalls to Linux |
| **Darling prefix** | Virtual macOS filesystem tree (overlayfs-based) |
| **sandbox-exec stub** | Passes through commands without sandboxing (Darling provides Linux-level isolation) |
| **Directory Services stubs** | `dscl`, `dseditgroup`, `sysadminctl` — translate macOS user/group commands to `/etc/passwd` + `/etc/group` |
| **diskutil stub** | Returns expected filesystem info for the Nix installer |
| **cider-build-hook** | Alternative to SSH — invokes `cider shell` directly |
| **ciderBuilderModule.nix** | NixOS module that wires everything together declaratively |

For more technical details, see [PLAN.md](../PLAN.md).

---

## Further Reading

- [Project plan](../PLAN.md) — development plan, known blockers and the syscall triage table
- [Darling documentation](https://docs.darlinghq.org/) — upstream Darling docs
- [Nix remote builders](https://nixos.org/manual/nix/stable/advanced-topics/distributed-builds.html) — Nix manual on distributed builds
- [Blog: Nix All The Way Down](https://ersei.net/en/blog/nix-all-the-way-down) — early exploration of Nix-in-Darling