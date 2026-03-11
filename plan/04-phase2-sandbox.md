# Phase 2 — Sandbox & Build Isolation

**Priority**: P0 · **Effort**: S (1 week) · **Depends on**: Nothing (can be done in parallel with Phase 1)

Nix on Darwin relies heavily on `/usr/bin/sandbox-exec` for build isolation.
Every derivation builder is wrapped with it. Since Darling doesn't ship this
binary and the entire sandbox API is stubbed, this is a hard blocker for any
`nix-build` invocation.

The good news: this is one of the **quickest wins** in the entire plan. A simple
passthrough stub is sufficient because Darling already runs inside a Linux-level
container with namespace isolation.

---

## Context

When Nix builds a derivation on Darwin, it does roughly this:

```
posix_spawn(NULL, "/usr/bin/sandbox-exec",
    { attributes = POSIX_SPAWN_SETEXEC, file_actions = {} },
    {"sandbox-exec", "-f", "/tmp/nix-build-foo.drv-0/.sandbox.sb",
     "-D", "_GLOBAL_TMP_DIR=/tmp",
     "/bin/bash", "-e", "/nix/store/...-builder.sh"},
    {env...})
```

The sandbox profile (`.sb` file) is a Scheme-based DSL that restricts file
access, network access, and process operations. Example from Nix:

```scheme
(version 1)
(allow default)
; Disallow creating setuid/setgid binaries
(deny file-write-setugid)
```

Nix generates these profiles dynamically per-build. The `sandbox-exec` binary
reads the profile, applies the restrictions via macOS's `sandbox_init` API, then
`exec`s the builder.

Internally, Nix checks for `_NIX_TEST_NO_SANDBOX` to bypass this entirely, but
that's a testing escape hatch, not a supported configuration.

---

## Tasks

### 2.1 — Create `/usr/bin/sandbox-exec` Stub

Create a stub `sandbox-exec` binary that lives in the Darling prefix at
`/usr/bin/sandbox-exec`. This is the **MVP approach**.

**Behavior**:

1. Parse command-line arguments matching the real `sandbox-exec` interface:
   - `-f <profile-path>` — path to a `.sb` sandbox profile (ignored)
   - `-p <profile-string>` — inline sandbox profile (ignored)
   - `-D <key>=<value>` — parameter definitions for the profile (ignored)
   - `-n <name>` — predefined profile name (ignored)
   - Everything after the flags is the command to execute.
2. Ignore all sandbox-related arguments.
3. `exec` the remaining arguments (the builder command).

**Implementation options** (pick one):

#### Option A — Shell script (simplest)

```sh
#!/bin/sh
# sandbox-exec stub for Darling
# Ignores sandbox profiles and exec's the builder directly.
# Darling provides Linux-level isolation via namespaces/darlingserver.

while [ $# -gt 0 ]; do
    case "$1" in
        -f) shift 2 ;;  # skip -f <profile>
        -p) shift 2 ;;  # skip -p <profile-string>
        -n) shift 2 ;;  # skip -n <name>
        -D) shift 2 ;;  # skip -D key=value
        -D*) shift ;;   # skip -Dkey=value (no space)
        *)  break ;;
    esac
done

exec "$@"
```

Pros: trivial, no compilation needed.
Cons: requires `/bin/sh` to be working (it is in Darling); slight overhead from
shell parse.

#### Option B — Small C program (more robust)

```c
#include <unistd.h>
#include <string.h>
#include <stdio.h>

int main(int argc, char *argv[]) {
    int i = 1;
    while (i < argc) {
        if ((strcmp(argv[i], "-f") == 0 ||
             strcmp(argv[i], "-p") == 0 ||
             strcmp(argv[i], "-n") == 0 ||
             strcmp(argv[i], "-D") == 0) && i + 1 < argc) {
            i += 2;  /* skip flag + argument */
        } else if (strncmp(argv[i], "-D", 2) == 0) {
            i += 1;  /* skip -Dkey=value */
        } else {
            break;
        }
    }

    if (i >= argc) {
        fprintf(stderr, "sandbox-exec: no command specified\n");
        return 1;
    }

    execvp(argv[i], &argv[i]);
    perror("sandbox-exec: exec");
    return 127;
}
```

Pros: no shell dependency, handles edge cases better, tiny binary.
Cons: needs to be compiled as a Mach-O binary and installed into the prefix.

**Recommendation**: Start with Option A (shell script) for speed. Replace with
Option B later if any issues arise.

**Installation**: The stub must be installed during Darling's build/prefix setup.
Add it to the CMake install step or to the prefix initialization script.

**Location in build system**: Create `src/sandbox-exec/` with the stub and a
`CMakeLists.txt` that installs it to `libexec/darling/usr/bin/sandbox-exec`.

---

### 2.2 — Fix Sandbox API Stubs

**Current state** (`src/sandbox/sandbox.c`):

```c
int sandbox_init(const char *profile, uint64_t flags, char **errorbuf)
{
    *errorbuf = strdup("Not implemented");
    return 0;
}
```

This is subtly wrong: it returns 0 (success) but also sets `*errorbuf` to an
error string. Callers that check `errorbuf != NULL` after a "successful" call
may be confused, or may leak memory expecting `errorbuf` to be NULL on success.

**Fix**: Set `*errorbuf = NULL` on success:

```c
int sandbox_init(const char *profile, uint64_t flags, char **errorbuf)
{
    if (errorbuf)
        *errorbuf = NULL;
    return 0;
}
```

Apply the same fix to:

- `sandbox_init_with_parameters`
- `sandbox_init_with_extensions`
- `sandbox_wakeup_daemon` (currently returns -1; change to return 0 if callers
  expect success, or leave as-is if it's genuinely optional)

**Files to modify**: `src/sandbox/sandbox.c`

**Also verify**: `src/libsandbox/src/sandbox.c` (the `libsandbox.1.dylib` shim)
doesn't have the same issue.

---

### 2.3 — Ensure `sandbox_check` Always Permits

**Current state** (`src/sandbox/sandbox.c`):

```c
int sandbox_check(pid_t pid, const char *operation,
                  enum sandbox_filter_type type, ...)
{
    return 0;
}
```

This is correct — returning 0 means "allowed". Verify that the `_by_audit_token`
variant behaves the same (it does, based on code analysis). No changes needed
unless testing reveals issues.

---

### 2.4 — (Stretch) Basic Sandbox Profile Language Parsing

> **This is NOT required for Nix support.** It's documented here for
> completeness and for future contributors who want proper sandbox parity.

Implement basic parsing of Apple's Sandbox Profile Language (`.sb` files) and
translate deny rules to Linux isolation mechanisms:

| macOS Sandbox Rule | Linux Equivalent |
|---|---|
| `(deny file-write*)` | Read-only bind mounts or Landlock `LANDLOCK_ACCESS_FS_WRITE_FILE` deny |
| `(deny file-read* (subpath "/private"))` | Landlock path-beneath rule |
| `(deny network*)` | Unshare network namespace (`CLONE_NEWNET`) |
| `(deny network-outbound)` | `iptables` / `nftables` OUTPUT DROP, or network namespace |
| `(deny process-exec)` | `seccomp-bpf` filter on `execve` |
| `(deny process-fork)` | `seccomp-bpf` filter on `clone` / `fork` |
| `(deny file-write-setugid)` | `seccomp-bpf` filter on `fchmod` with setuid/setgid bits |
| `(allow default)` | Baseline: allow everything, then layer on denies |

This would require:

1. A Scheme parser (or at minimum a purpose-built `.sb` parser — the language is
   a small subset of Scheme).
2. Translation logic mapping macOS sandbox operations to Linux syscall filters.
3. Integration with `sandbox-exec` to apply the translated policy before
   `exec`-ing the builder.

**Effort**: Weeks to months. Not recommended until after Phase 4 is working.

---

## Security Considerations

**Q: Is it safe to skip the macOS sandbox?**

Yes, for the Darling use case:

1. **Darling already provides isolation.** The `darlingserver` runs Darling
   processes inside a Linux container with namespace isolation (mount, PID, user
   namespaces via `overlayfs`). This is comparable to — and arguably stronger
   than — macOS's `sandbox-exec` for build isolation purposes.

2. **Nix's sandbox is defense-in-depth.** Nix's primary isolation comes from the
   build environment setup (clean `$PATH`, empty `$HOME`, controlled `$TMPDIR`).
   The macOS sandbox adds an extra layer but isn't the only protection.

3. **The Linux host can add its own sandboxing.** If stronger isolation is
   needed, the host can run Darling inside a systemd-nspawn container, a VM, or
   with additional seccomp profiles. This provides equivalent-or-better security
   to macOS's sandbox.

4. **No untrusted code.** In the Nix builder context, the code being executed is
   from derivations that the user has chosen to build. The sandbox prevents
   accidental side effects, not malicious code execution.

---

## Verification Checklist

After completing Phase 2, the following should all work inside `darling shell`:

- [ ] `/usr/bin/sandbox-exec` exists and is executable
- [ ] `sandbox-exec -f /dev/null -D _GLOBAL_TMP_DIR=/tmp /bin/echo hello` prints "hello"
- [ ] `sandbox-exec -p '(version 1)(allow default)' /bin/echo hello` prints "hello"
- [ ] `sandbox-exec` with no command argument prints an error and exits non-zero
- [ ] Calling `sandbox_init("no_network", 0, &err)` from C returns 0 with `err == NULL`
- [ ] Nix's builder invocation (`posix_spawn` → `sandbox-exec` → `/bin/bash`)
  no longer returns `ENOEXEC` / "Bad file descriptor"
- [ ] A trivial `nix-build` with `_NIX_TEST_NO_SANDBOX` **unset** proceeds past
  the sandbox-exec step (it may still fail later due to Phase 1 issues, but it
  must not fail at the sandbox stage)

---

## Implementation Order

```
2.1 (sandbox-exec stub)    — do first, biggest impact
    ↓
2.2 (fix sandbox_init)     — quick follow-up, same files
    ↓
2.3 (verify sandbox_check) — no changes expected, just verify
    ↓
2.4 (stretch: SBPL parse)  — defer until after Phase 4
```

---

*[← Phase 1 — Syscall Fixes](./03-phase1-syscalls.md) | [Phase 3 — Nix Installation →](./05-phase3-nix-install.md)*