# Darling Builder Template

This template sets up a NixOS configuration with a **Darling-based
`x86_64-darwin` remote builder**, allowing your Linux machine to build macOS
packages without Apple hardware.

## Getting Started

### 1. Initialise from the template

```bash
mkdir my-darwin-builder && cd my-darwin-builder
nix flake init -t github:nixie-dev/cider-nix#cider-builder
```

### 2. Customise `flake.nix`

Open `flake.nix` and:

- Replace `"myhost"` with your machine's hostname.
- Uncomment and add your existing NixOS modules (`hardware-configuration.nix`,
  `configuration.nix`, etc.).
- Adjust `services.cider-builder` options to taste (see
  [Options](#module-options) below).

### 3. Apply the configuration

```bash
sudo nixos-rebuild switch --flake .#myhost
```

This will:

1. Install Darling on the host.
2. Create and initialise a Darling prefix at `/var/lib/cider-builder`.
3. Install Nix inside the Darling prefix.
4. Start an SSH server inside the prefix on `127.0.0.1:2222`.
5. Register the Darling instance as a `nix.buildMachines` entry for
   `x86_64-darwin`.

### 4. Verify

```bash
# Built-in connectivity check
cider-builder-test

# Build a Darwin package from your Linux host
nix build nixpkgs#hello --system x86_64-darwin
```

## Module Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable the Darling builder service |
| `package` | package | `pkgs.cider` | Darling package to use |
| `port` | int | `2222` | SSH port inside the Darling prefix |
| `maxJobs` | int | `1` | Maximum concurrent build jobs |
| `speedFactor` | int | `1` | Nix builder speed factor (lower = deprioritised) |
| `shareStore` | bool | `false` | Share `/nix/store` between host and Darling via `/Volumes/SystemRoot` |
| `sshKeyPath` | path | `/etc/nix/cider-builder-key` | SSH private key for the Nix daemon |
| `prefixPath` | path | `/var/lib/cider-builder` | Darling prefix directory |
| `supportedFeatures` | list of str | `[]` | Nix supported features |
| `mandatoryFeatures` | list of str | `[]` | Nix mandatory features |
| `installNix` | bool | `true` | Auto-install Nix inside the prefix on first boot |
| `nixVersion` | str | `"2.24.10"` | Nix version to install inside Darling |

## How It Works

```
┌────────────────────────────────────────────────────────┐
│                  Linux Host (NixOS)                     │
│                                                        │
│  ┌───────────┐   SSH (localhost:2222)   ┌────────────┐ │
│  │ Nix Daemon │ ──────────────────────▶ │   sshd     │ │
│  │           │                         │  (Darling)  │ │
│  │ offloads  │                         │ ┌────────┐  │ │
│  │ x86_64-   │                         │ │  Nix   │  │ │
│  │ darwin    │                         │ │ daemon │  │ │
│  └───────────┘                         │ └────────┘  │ │
│        │                               │             │ │
│        ▼          /Volumes/            │             │ │
│  ┌───────────┐   SystemRoot/nix ──────▶│   /nix     │ │
│  │/nix/store │   (shared store)        │  (symlink) │ │
│  └───────────┘                         └────────────┘ │
│                     Darling Prefix                     │
└────────────────────────────────────────────────────────┘
```

Darling is a macOS compatibility layer that translates macOS system calls into
Linux equivalents. By running Nix inside Darling, the builder reports
`builtins.currentSystem == "x86_64-darwin"` and can execute Darwin derivations.

When `shareStore` is enabled, the host's `/nix/store` is made available inside
the Darling prefix via `/Volumes/SystemRoot`, eliminating the need to copy
store paths over SSH.

## Troubleshooting

### "Connection refused"

The sshd inside Darling isn't running or is on a different port.

```bash
# Check if the service is running
systemctl status cider-builder

# Check if sshd is listening
ss -tlnp | grep 2222

# Restart the service
sudo systemctl restart cider-builder
```

### "Permission denied (publickey)"

SSH key mismatch between the host and Darling prefix.

```bash
# Verify the key exists
ls -la /etc/nix/cider-builder-key

# Verify the public key inside Darling
cider --prefix /var/lib/cider-builder shell cat /var/root/.ssh/authorized_keys

# Test SSH manually
ssh -vvv -i /etc/nix/cider-builder-key -p 2222 root@127.0.0.1 echo ok
```

### Build fails with "Unimplemented syscall"

The derivation uses a macOS syscall that Darling doesn't support yet. This is
expected for complex packages. Check the
[syscall triage table](https://github.com/nixie-dev/cider-nix/blob/main/PLAN.md)
and consider filing an issue upstream.

### Build is very slow

1. **Enable binary substitution** — most `x86_64-darwin` packages are already
   on `cache.nixos.org`. Ensure `builders-use-substitutes = true` is set in
   the host's `nix.conf`.
2. **Enable store sharing** — set `shareStore = true` to avoid copying store
   paths over SSH.
3. **Use fast storage** — put the Darling prefix on SSD/NVMe.

## Further Reading

- [Full setup guide](https://github.com/nixie-dev/cider-nix/blob/main/docs/darwin-builder.md)
- [Project plan](https://github.com/nixie-dev/cider-nix/blob/main/PLAN.md)
- [Darling documentation](https://docs.darlinghq.org/)
- [Nix distributed builds](https://nixos.org/manual/nix/stable/advanced-topics/distributed-builds.html)