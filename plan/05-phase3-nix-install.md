# Phase 3 — Nix Installation Inside Darling

**Priority**: P0 · **Effort**: M (2–3 weeks) · **Depends on**: Phase 1 (syscall fixes), Phase 2 (sandbox stub)

With the syscall fixes from Phase 1 and the `sandbox-exec` stub from Phase 2,
the Nix package manager should be installable inside a Darling prefix. This
phase covers automating that installation, verifying core Nix commands, and
providing convenient wrappers for host-side usage.

---

## Context

The official Nix installer for macOS (`nix-*-x86_64-darwin`) has several
assumptions that conflict with Darling's environment:

1. **Forces multi-user mode on Darwin.** The installer detects `uname -s` =
   `Darwin` and refuses single-user installation. Multi-user mode requires
   `dseditgroup`, `sysadminctl`, and a working `launchd` — none of which are
   fully functional in Darling yet.

2. **Requires `diskutil info /`** to check the root filesystem type (APFS vs
   HFS+). Darling's `diskutil` is a shell script that only supports `eject`.

3. **Requires `xmllint`** for parsing plists. Not shipped in Darling.

4. **Requires Directory Services** (`dseditgroup`, `dscl`) for creating the
   `nixbld` group and build users.

5. **Calls `lchflags`** during profile installation (fixed in Phase 1).

6. **Root user quirks.** Nix defaults `build-users-group = nixbld` when running
   as root. In single-user mode as root, this must be overridden to empty.

All of these are solvable with a patched installer script and pre-configured
`nix.conf`.

---

## Tasks

### 3.1 — Create Automated Nix-in-Darling Installer

Create a script at `scripts/install-nix-in-darling.sh` (run from the Linux
host) that automates the entire Nix installation inside a Darling prefix.

**Steps the script should perform**:

1. **Verify prerequisites**:
   - Darling is installed and `darling shell echo ok` works.
   - The prefix is initialized (`~/.darling` or `$DPREFIX` exists).
   - Phase 1 and Phase 2 fixes are in place (check for `/usr/bin/sandbox-exec`
     inside the prefix).

2. **Pre-configure Nix**:
   ```bash
   darling shell mkdir -p /etc/nix
   darling shell tee /etc/nix/nix.conf <<'EOF'
   # Single-user mode: no build users group
   build-users-group =
   # Disable macOS sandbox (we use the sandbox-exec stub)
   sandbox = false
   # Use the Nix binary cache
   substituters = https://cache.nixos.org
   trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
   EOF
   ```

3. **Download the Nix installer**:
   - Fetch the latest `nix-*-x86_64-darwin` installer tarball from
     `https://releases.nixos.org/nix/`.
   - Verify its signature / hash.
   - Extract it into a temporary directory inside the prefix.

4. **Patch the installer**:
   - Remove or bypass the `uname`-based multi-user enforcement.
   - Remove the `diskutil info` check.
   - Remove the `xmllint` dependency (or provide a stub).
   - Suppress the "installing as root is not supported" warning.
   - Force `--no-daemon` mode.

   The patching should be done with `sed` or a patch file applied to the
   extracted `install` script. Keep the patch minimal and well-documented so it
   can be updated when Nix releases new installer versions.

5. **Run the patched installer**:
   ```bash
   darling shell /tmp/nix-installer/install --no-daemon
   ```

6. **Post-install verification**:
   - Run each command from the verification checklist (see below).
   - Source the Nix profile: `. /Users/root/.nix-profile/etc/profile.d/nix.sh`
   - Print the installed Nix version.

7. **Clean up**:
   - Remove the temporary installer files.
   - Optionally run `nix-collect-garbage` to free space.

**Error handling**: The script should `set -euo pipefail` and provide clear
error messages at each step, indicating which phase/blocker is likely the cause
if something fails.

---

### 3.2 — Pre-Built Darling Prefix with Nix

Create a Nix derivation (`packages.x86_64-linux.darling-nix-prefix`) that
produces a Darling prefix tarball with Nix pre-installed. This lets users skip
the installation process entirely.

**Approach**:

1. Build Darling in a Nix sandbox.
2. Initialize a fresh prefix.
3. Run the installer script from 3.1 inside the prefix (this requires a
   working Darling at build time — may need to be done in a NixOS VM test
   context rather than a pure derivation, since Darling needs namespace
   capabilities).
4. Snapshot the prefix as a tarball.
5. Users restore with:
   ```bash
   mkdir -p ~/.darling
   tar xf /nix/store/...-darling-nix-prefix.tar -C ~/.darling
   ```

**Alternative**: If building inside a Nix sandbox is too complex (due to
namespace requirements), provide a script that generates the prefix on the
user's machine and document it as a one-time setup step.

---

### 3.3 — Verify Core Nix Commands

After installation, the following commands must work without errors inside
`darling shell`. Each one exercises a different subsystem:

| Command | What It Tests |
|---|---|
| `nix --version` | Binary loads, `dyld` resolves all libraries |
| `nix-env --version` | Same, plus `libnixstore` loads correctly |
| `nix-store --verify` | Store database access, file system operations |
| `nix-instantiate --eval -E '1 + 1'` | Nix evaluator, no build needed |
| `nix eval --expr '1 + 1'` | Flake-enabled CLI, evaluator |
| `nix-store --dump-db` | SQLite database access in `/nix/var/nix/db/` |
| `nix-env -qa hello` | Channel/registry querying, HTTP fetching |

**Known potential issues at this stage**:

- **SQLite**: Nix's store database uses SQLite. If Darling's `fcntl` locking
  (via `F_SETLK` / `F_GETLK`) is buggy, database operations will fail or hang.
  Add SQLite lock testing to the verification.

- **curl / TLS**: `nix-env -qa` and binary substitution need working HTTPS.
  Darling ships its own curl and SSL certificates. If they're outdated or the
  TLS handshake uses unimplemented syscalls, fetching will fail. Verify with:
  ```bash
  darling shell curl -sI https://cache.nixos.org/nix-cache-info
  ```

- **`/nix` path**: By default, Nix installs to `/nix`. Inside Darling, this is
  within the prefix overlay at `~/.darling/nix`. This is fine for isolated
  usage. For shared-store mode (Phase 7), we'll need to symlink this to the
  host's `/nix` via `/Volumes/SystemRoot/nix`.

---

### 3.4 — Host-Side Wrapper: `darling-nix`

Create a convenience wrapper script (installed as part of the Darling Nix
package) that runs Nix commands inside Darling from the Linux host:

```bash
#!/usr/bin/env bash
# darling-nix — run Nix commands inside a Darling prefix
set -euo pipefail

# Source Nix profile and run the command
exec darling shell bash -lc '
    . /Users/root/.nix-profile/etc/profile.d/nix.sh
    exec "$@"
' -- "$@"
```

**Usage examples**:

```bash
# Evaluate an expression
darling-nix nix-instantiate --eval -E '1 + 1'

# Build a trivial derivation
darling-nix nix-build --expr 'derivation { name = "test"; builder = "/bin/bash"; args = ["-c" "echo ok > $out"]; system = "x86_64-darwin"; }'

# Install a package
darling-nix nix-env -iA nixpkgs.hello

# Interactive Nix repl
darling-nix nix repl
```

**Install location**: `$out/bin/darling-nix` in the Darling Nix package.

**Enhancements for later**:

- Support `--prefix <path>` to use a non-default Darling prefix.
- Support `--store <path>` to configure the Nix store location.
- Capture and forward exit codes correctly.
- Handle signals (SIGINT, SIGTERM) and propagate them to the Darling process.

---

### 3.5 — Nix Channel / Registry Setup

After Nix is installed, set up a usable channel or flake registry so users can
immediately start building packages:

```bash
# Add the nixpkgs channel (for nix-env / nix-shell)
darling shell nix-channel --add https://nixos.org/channels/nixpkgs-unstable nixpkgs
darling shell nix-channel --update

# Or, for flakes:
darling shell nix registry add nixpkgs github:NixOS/nixpkgs/nixpkgs-unstable
```

This should be part of the installer script (3.1) as an optional post-install
step.

**Potential issue**: `nix-channel --update` downloads and unpacks a tarball,
which exercises `curl`, `xz`, `tar`, and filesystem operations. Any crash here
points to remaining syscall gaps from Phase 1.

---

## Shared Store Considerations

For Phase 3, Nix runs with its own store inside the Darling prefix
(`~/.darling/nix/store`). This is the simplest setup and avoids any
interaction with the host's Nix store.

For later phases (especially Phase 7 — Remote Builder), we'll want to share the
host's `/nix/store` with the Darling prefix. The mechanism:

```bash
# Inside the Darling prefix, /Volumes/SystemRoot is the host's /
# So /Volumes/SystemRoot/nix/store is the host's /nix/store

# Option A: Symlink
darling shell ln -sf /Volumes/SystemRoot/nix /nix

# Option B: Bind mount (if overlayfs allows it)
# Configured in darlingserver / prefix init
```

This is NOT part of Phase 3 — just documented here so the installation script
doesn't make assumptions that would conflict with shared-store mode later. In
particular:

- Don't hardcode paths that assume `/nix` is local to the prefix.
- Make the store location configurable in `nix.conf`.
- Ensure the installer doesn't fail if `/nix` is a symlink.

---

## Debugging Tips

If installation fails, here are the most useful debugging techniques:

**Trace the installer script**:
```bash
darling shell bash -x /tmp/nix-installer/install --no-daemon 2>&1 | tee install.log
```

**Trace Nix binary startup**:
```bash
# On the host, trace darlingserver while running a Nix command:
strace -f -p $(pidof darlingserver) -e trace=openat,stat,fstat,lstat,readlink 2>&1 | head -200 &
darling shell /nix/store/.../bin/nix --version
```

**Trace inside Darling with xtrace**:
```bash
DARLING_XTRACE=1 darling shell /nix/store/.../bin/nix-env --version 2>&1 | head -500
```

**Check for unimplemented syscalls**:
```bash
darling shell /nix/store/.../bin/nix --version 2>&1 | grep -i "unimplemented\|STUB\|not.implemented"
```

**Inspect the store database**:
```bash
darling shell sqlite3 /nix/var/nix/db/db.sqlite ".tables"
darling shell sqlite3 /nix/var/nix/db/db.sqlite "SELECT count(*) FROM ValidPaths;"
```

---

## Verification Checklist

After completing Phase 3, ALL of the following must pass:

- [ ] `scripts/install-nix-in-darling.sh` completes without errors
- [ ] `darling shell nix --version` prints the Nix version
- [ ] `darling shell nix-env --version` prints the Nix version
- [ ] `darling shell nix-store --verify` reports no errors
- [ ] `darling shell nix-instantiate --eval -E '1 + 1'` prints `2`
- [ ] `darling shell nix eval --expr '1 + 1'` prints `2`
- [ ] `darling shell curl -sI https://cache.nixos.org/nix-cache-info` returns HTTP 200
- [ ] `darling-nix nix --version` works from the Linux host
- [ ] `darling-nix nix-instantiate --eval -E 'builtins.currentSystem'` prints `"x86_64-darwin"`
- [ ] No "Unimplemented syscall" messages during any of the above
- [ ] No segfaults during any of the above

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| SQLite locking doesn't work | Medium | High — store operations fail | Test `fcntl` locking early; if broken, use `PRAGMA locking_mode=EXCLUSIVE` |
| curl/TLS fails | Medium | High — no binary substitution | Test HTTPS early; fall back to `--option substitute false` for offline mode |
| Nix installer changes break our patches | Medium | Medium — need to update patches | Pin a specific Nix version; provide a patch file rather than inline sed |
| `/nix` path conflicts with shared store | Low | Medium — need reconfiguration | Keep store location configurable from the start |
| Nix evaluator hits unimplemented syscalls | Low | Medium — eval works but slowly | Phase 1 triage (1.7) should catch these |

---

*[← Phase 2 — Sandbox](./04-phase2-sandbox.md) | [Phase 4 — Derivation Building →](./06-phase4-building.md)*