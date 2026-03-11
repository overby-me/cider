# Phase 5 — Nix Daemon & Multi-User Mode

**Priority**: P2 · **Effort**: M (2–4 weeks) · **Depends on**: Phase 4 (derivation building)

Single-user mode (Phases 0–4) is sufficient for development and testing, but a
production-grade setup benefits from the Nix daemon for concurrent builds,
proper garbage collection, and user isolation. This phase adds multi-user Nix
support inside Darling.

---

## Context

On a real macOS system, the Nix daemon (`nix-daemon`) runs as a LaunchDaemon
managed by `launchd`. It:

1. Listens on a Unix domain socket (`/nix/var/nix/daemon-socket/socket`).
2. Accepts build requests from unprivileged users.
3. Spawns builds as dedicated `_nixbldN` users (members of the `nixbld` group).
4. Manages the Nix store exclusively — only the daemon writes to `/nix/store`.
5. Handles garbage collection, signing, and binary cache downloads.

The multi-user Nix installer on macOS creates:

- A `nixbld` group (GID 30000 by convention).
- 32 build users `_nixbld1` through `_nixbld32` (UIDs 300–331).
- A LaunchDaemon plist at `/Library/LaunchDaemons/org.nixos.nix-daemon.plist`.
- Nix profile scripts in `/etc/profile.d/` and `/etc/bashrc.d/`.

All of this relies on Directory Services (`dscl`, `dseditgroup`, `sysadminctl`)
for user/group management and `launchd`/`launchctl` for service management.
Darling has partial `launchd` support but no Directory Services implementation.

---

## Tasks

### 5.1 — Implement Directory Services Stubs

The Nix installer uses these commands to create build users and groups:

```bash
# Create the nixbld group
dseditgroup -o create -q -i 30000 nixbld

# Create build users
sysadminctl -addUser _nixbld1 -UID 300 -GID 30000 -home /var/empty -shell /usr/bin/false
# ... repeated for _nixbld2 through _nixbld32

# Add users to the group
dseditgroup -o edit -a _nixbld1 -t user nixbld
```

Darling does not implement these commands. We need thin wrappers that translate
to Linux user/group management operating on the prefix's `/etc/passwd` and
`/etc/group` files.

#### `dseditgroup` stub

Create `src/tools/dseditgroup` (or a shell script installed to
`libexec/darling/usr/sbin/dseditgroup`) that handles:

| Invocation | Translation |
|---|---|
| `dseditgroup -o create -q -i <GID> <name>` | `echo "<name>:x:<GID>:" >> /etc/group` (if not exists) |
| `dseditgroup -o edit -a <user> -t user <group>` | Append `<user>` to the group's member list in `/etc/group` |
| `dseditgroup -o delete <name>` | Remove the group from `/etc/group` |
| `dseditgroup -o checkmember -m <user> <group>` | Check if user is in the group; exit 0 if yes, non-zero if no |

Does not need to support the full `dseditgroup` interface — only what the Nix
installer uses.

#### `sysadminctl` stub

Create a stub that handles:

| Invocation | Translation |
|---|---|
| `sysadminctl -addUser <name> -UID <uid> -GID <gid> -home <dir> -shell <shell>` | `echo "<name>:x:<uid>:<gid>::<dir>:<shell>" >> /etc/passwd` |
| `sysadminctl -deleteUser <name>` | Remove the user from `/etc/passwd` |

#### `dscl` stub

The Nix installer may also use `dscl` in some code paths:

| Invocation | Translation |
|---|---|
| `dscl . -read /Groups/<name> PrimaryGroupID` | Parse `/etc/group` and print the GID |
| `dscl . -read /Users/<name> UniqueID` | Parse `/etc/passwd` and print the UID |
| `dscl . -list /Users` | List all usernames from `/etc/passwd` |
| `dscl . -create /Users/<name> ...` | Append to `/etc/passwd` |

**Implementation notes**:

- These stubs modify files within the Darling prefix (`~/.darling/etc/passwd`,
  `~/.darling/etc/group`), not the host's files. This is safe.
- Do NOT use `useradd`/`groupadd` (those operate on the host). Directly
  manipulate the prefix's files.
- Add basic input validation (duplicate detection, numeric ranges).
- Make them idempotent — running the installer twice should not create duplicate
  entries.

**Testing**:

```bash
# Inside darling shell:
dseditgroup -o create -q -i 30000 nixbld
grep nixbld /etc/group
# Expected: nixbld:x:30000:

sysadminctl -addUser _nixbld1 -UID 300 -GID 30000 -home /var/empty -shell /usr/bin/false
grep _nixbld1 /etc/passwd
# Expected: _nixbld1:x:300:30000::/var/empty:/usr/bin/false
```

---

### 5.2 — Get `nix-daemon` Running

Once build users exist, launch the Nix daemon inside Darling.

**Step 1 — Manual launch (for testing)**:

```bash
darling shell nix-daemon &
```

The daemon should:

- Create the socket at `/nix/var/nix/daemon-socket/socket`.
- Listen for connections.
- Fork build processes as `_nixbldN` users (requires working `setuid`/`setgid`
  inside the Darling prefix).

**Step 2 — Verify client connectivity**:

```bash
# In another darling shell, as a non-root user:
darling shell nix-store --version
# This should connect to the daemon over the Unix socket
```

**Requirements for the daemon to function**:

| Requirement | Status in Darling | Notes |
|---|---|---|
| Unix domain sockets | Likely works | Darling maps to Linux AF_UNIX sockets |
| `setuid` / `setgid` | Needs verification | Daemon drops privileges to build users; must work within the namespace |
| `fork` / `posix_spawn` | Partially works | Phase 1/B5 fixes needed for reliability |
| `fcntl` advisory locking | Needs verification | Store database locking; critical for concurrent access |
| `kill` / signal delivery | Likely works | Daemon sends SIGTERM to cancel builds |
| `/var/empty` exists | May need creation | Home directory for build users |

**Potential issues**:

- **`setuid` within namespaces**: Darling uses user namespaces. `setuid` inside a
  user namespace works differently — the process can only switch to UIDs mapped
  in the namespace. The Darling prefix must have the `_nixbldN` UIDs mapped.
  This may require changes to darlingserver's namespace setup.

- **Socket permissions**: The daemon socket must be readable/writable by all
  users who should be able to trigger builds. Check that `chmod 0660` on the
  socket works and that group membership is respected.

- **Process isolation**: The daemon expects to be able to create per-build
  temporary directories under `/tmp` or `$TMPDIR`, owned by the build user.
  Verify that `chown` works for changing file ownership to build users.

**Debugging**:

```bash
# Watch daemon logs:
darling shell nix-daemon --debug 2>&1 | tee daemon.log

# Test socket connectivity:
darling shell ls -la /nix/var/nix/daemon-socket/socket

# Trace daemon syscalls from the host:
strace -f -p $(pgrep -f nix-daemon) -e trace=socket,bind,listen,accept,clone,setuid,setgid 2>&1 | head -200
```

---

### 5.3 — LaunchDaemon Integration

Make the Nix daemon manageable via `launchctl`, as it would be on real macOS.

**Step 1 — Install the plist**:

The Nix installer creates `/Library/LaunchDaemons/org.nixos.nix-daemon.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>org.nixos.nix-daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/nix/var/nix/profiles/default/bin/nix-daemon</string>
    </array>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/var/log/nix-daemon.log</string>
</dict>
</plist>
```

**Step 2 — Load with launchctl**:

```bash
darling shell launchctl load /Library/LaunchDaemons/org.nixos.nix-daemon.plist
```

**Step 3 — Verify**:

```bash
darling shell launchctl list | grep nix
# Expected: org.nixos.nix-daemon with a PID

darling shell launchctl print system/org.nixos.nix-daemon
# Expected: status information
```

**Known risks**: Darling's `launchd` implementation (`src/launchd/`) is
functional for basic service management but may not support all plist keys.
`KeepAlive` (automatic restart) is the most likely to have issues. If launchd
integration is unreliable, fall back to manual daemon startup or a simple
wrapper script.

**Fallback — systemd integration on the host**:

If launchd proves too unreliable, an alternative is to manage the daemon from
the Linux host using systemd:

```ini
# /etc/systemd/system/darling-nix-daemon.service
[Unit]
Description=Nix Daemon inside Darling
After=network.target

[Service]
ExecStart=/usr/bin/darling shell /nix/var/nix/profiles/default/bin/nix-daemon
Restart=on-failure
Type=simple

[Install]
WantedBy=multi-user.target
```

This bypasses launchd entirely while still providing reliable daemon management.

---

### 5.4 — Test Concurrent Builds

Multi-user mode enables parallel builds. Test that multiple derivations can build
simultaneously without interference.

**Test procedure**:

```bash
# Start the daemon
darling shell nix-daemon &

# In parallel, build several independent packages:
darling-nix nix-build '<nixpkgs>' -A hello --system x86_64-darwin &
darling-nix nix-build '<nixpkgs>' -A which --system x86_64-darwin &
darling-nix nix-build '<nixpkgs>' -A yes --system x86_64-darwin &
wait
```

**What to watch for**:

- **Store database locking**: SQLite must handle concurrent reads/writes via
  `fcntl` locking. If locking is broken, you'll see `database is locked` errors
  or silent corruption.

- **Build user contention**: Each concurrent build should use a different
  `_nixbldN` user. Verify with `ps aux | grep nix-build` inside darling shell.

- **`/tmp` isolation**: Each build gets its own `$TMPDIR`. Verify no cross-
  contamination between concurrent builds.

- **File descriptor exhaustion**: Darling's fd table is backed by Linux fds. Many
  concurrent builds can exhaust the per-process limit. Check `ulimit -n` inside
  darling shell and increase if needed.

- **Deadlocks**: If `posix_spawn` or `fork` has race conditions in Darling's
  implementation, concurrent builds may deadlock. Monitor with `strace -f` and
  look for stuck processes.

**Expected outcome**: All three builds complete (possibly via binary
substitution) without errors. If building from source, expect it to be slow but
correct.

---

### 5.5 — Nix Profile Scripts

The multi-user installer sets up profile scripts so Nix is available to all
users. Verify these work:

```bash
# /etc/profile.d/nix.sh should be sourced on login
darling shell bash -l -c 'which nix'
# Expected: /nix/var/nix/profiles/default/bin/nix

# Verify $NIX_PATH is set
darling shell bash -l -c 'echo $NIX_PATH'

# Verify the daemon socket is used (not direct store access)
darling shell bash -l -c 'nix-store --version'
# Should connect via /nix/var/nix/daemon-socket/socket
```

---

## Upgrade Path: Single-User → Multi-User

Users who completed Phase 3 (single-user installation) should be able to
upgrade to multi-user mode. Document a migration procedure:

1. Stop any running Nix processes.
2. Run the Directory Services stubs to create build users (5.1).
3. Update `/etc/nix/nix.conf`:
   ```diff
   - build-users-group =
   + build-users-group = nixbld
   - sandbox = false
   + sandbox = true
   ```
4. Start the daemon (5.2 or 5.3).
5. Verify with `nix-store --version` (should connect to daemon).

The Nix store itself doesn't need migration — it's the same `/nix/store`
regardless of single-user or multi-user mode. Only the access method changes
(direct vs. via daemon).

---

## Verification Checklist

After completing Phase 5, ALL of the following must pass:

- [ ] `dseditgroup -o create -q -i 30000 nixbld` succeeds
- [ ] `sysadminctl -addUser _nixbld1 -UID 300 -GID 30000 -home /var/empty -shell /usr/bin/false` succeeds
- [ ] `/etc/group` and `/etc/passwd` inside the prefix contain the expected entries
- [ ] `nix-daemon` starts without errors
- [ ] `/nix/var/nix/daemon-socket/socket` exists after daemon start
- [ ] `nix-store --version` (as non-root) connects to the daemon
- [ ] A derivation build via the daemon completes successfully
- [ ] The build runs as a `_nixbldN` user (not root)
- [ ] `launchctl load` of the nix-daemon plist starts the service (or the systemd fallback works)
- [ ] Two concurrent `nix-build` invocations complete without database errors
- [ ] `nix-collect-garbage -d` works via the daemon

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `setuid` doesn't work in Darling's namespace | High | Critical — daemon can't use build users | Test early; may need darlingserver namespace mapping changes |
| `fcntl` locking broken → database corruption | Medium | Critical — store becomes unusable | Test with `PRAGMA integrity_check` after concurrent builds |
| launchd can't manage the daemon reliably | Medium | Medium — use systemd fallback | Have the systemd unit file ready as Plan B |
| Build users can't write to `$TMPDIR` | Medium | High — all daemon builds fail | Verify `chown` and directory permissions for build user UIDs |
| Socket permissions prevent non-root access | Low | Medium — only root can build | Check `chmod`/`chgrp` on the socket; may need a `nix-users` group |

---

*[← Phase 4 — Derivation Building](./06-phase4-building.md) | [Phase 6 — CI & Testing →](./08-phase6-ci.md)*