# Phase 6 — CI & Automated Testing

**Priority**: P1 · **Effort**: M (2–3 weeks) · **Depends on**: Phase 3 (Nix installation)

Automated testing is essential to prevent regressions as we add syscall
implementations, sandbox support, and other compatibility fixes. This phase
establishes a comprehensive CI pipeline that verifies Darling builds correctly
and that Nix functions inside it.

CI work can begin as soon as Phase 3 is working (Nix installs and evaluates
inside Darling). Tests for later phases (daemon, remote builder) are added
incrementally as those phases land.

---

## Context

The current CI (`.github/workflows/actions.yaml`) only builds Debian packages.
It does not:

- Build Darling with Nix.
- Run any functional tests.
- Verify Nix compatibility.
- Test inside a NixOS VM (which is needed for namespace/overlay support).

We need to replace or supplement this with a Nix-native CI pipeline that runs
real integration tests.

---

## Tasks

### 6.1 — NixOS VM Test: Nix-in-Darling

Create a NixOS VM test at `tests/nix-in-darling.nix` that exercises the full
Nix-inside-Darling pipeline end-to-end.

**Test structure** (using `nixos/lib/testing-python.nix`):

```nix
{ pkgs, ... }:
{
  name = "nix-in-darling";

  nodes.machine = { config, pkgs, ... }: {
    # Import our NixOS module
    imports = [ ../nixosModules/darling ];

    # Enable Darling
    programs.darling.enable = true;

    # Give the VM enough resources
    virtualisation.memorySize = 4096;
    virtualisation.diskSize = 20480;  # 20 GB for Nix store
    virtualisation.cores = 4;
  };

  testScript = ''
    machine.wait_for_unit("default.target")

    # Phase 0: Darling boots
    machine.succeed("darling shell echo 'Hello from Darling'")

    # Phase 2: sandbox-exec stub exists
    machine.succeed("darling shell test -x /usr/bin/sandbox-exec")
    machine.succeed("darling shell /usr/bin/sandbox-exec -f /dev/null /bin/echo ok")

    # Phase 3: Install Nix
    machine.succeed("scripts/install-nix-in-darling.sh")

    # Phase 3: Nix commands work
    machine.succeed("darling-nix nix --version")
    machine.succeed("darling-nix nix-instantiate --eval -E '1 + 1' | grep 2")
    machine.succeed("darling-nix nix eval --expr 'builtins.currentSystem' | grep x86_64-darwin")

    # Phase 4: Trivial build
    machine.succeed(
      "darling-nix nix-build --expr '"
      + "'derivation { name = \"test\"; builder = \"/bin/bash\"; "
      + "args = [\"-c\" \"echo ok > \\$out\"]; "
      + "system = \"x86_64-darwin\"; }'"
    )

    # Phase 4: Verify output
    result = machine.succeed(
      "darling shell cat $(darling-nix nix-build --no-link --expr '"
      + "'derivation { name = \"test\"; builder = \"/bin/bash\"; "
      + "args = [\"-c\" \"echo ok > \\$out\"]; "
      + "system = \"x86_64-darwin\"; }')"
    )
    assert "ok" in result, f"Expected 'ok' in output, got: {result}"

    machine.log("All Nix-in-Darling tests passed!")
  '';
}
```

**Key considerations**:

- The test runs in a NixOS VM, which provides the kernel namespace support
  Darling needs. This avoids requiring special privileges on the CI runner.
- The VM needs ample disk space (Darling prefix + Nix store + build artifacts).
- Timeout must be generous — Darling operations are slow, and the first Nix
  installation involves downloading and unpacking the installer.
- The test should be structured so that early failures (Darling doesn't boot)
  produce clear error messages rather than cryptic timeouts.

---

### 6.2 — Wire Tests into `flake.nix`

Add the NixOS VM test to the flake's `checks` output:

```nix
checks.x86_64-linux = {
  # Build Darling itself
  darling-build = self.packages.x86_64-linux.darling;

  # NixOS integration test
  nix-in-darling = import ./tests/nix-in-darling.nix {
    inherit pkgs;
  };
};
```

This allows running:

```bash
# Run all checks
nix flake check

# Run just the integration test
nix build .#checks.x86_64-linux.nix-in-darling
```

---

### 6.3 — GitHub Actions Workflow

Replace or supplement the existing `.github/workflows/actions.yaml` with a
Nix-native workflow.

**Workflow file**: `.github/workflows/nix-ci.yaml`

```yaml
name: Nix CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - uses: cachix/install-nix-action@v27
        with:
          extra_nix_config: |
            experimental-features = nix-command flakes

      - uses: cachix/cachix-action@v15
        with:
          name: darling-nix  # our Cachix cache
          authToken: '${{ secrets.CACHIX_AUTH_TOKEN }}'

      - name: Build Darling
        run: nix build .#darling -L

      - name: Build Darling SDK
        run: nix build .#darling-sdk -L

  test-syscalls:
    runs-on: ubuntu-latest
    needs: build
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - uses: cachix/install-nix-action@v27
        with:
          extra_nix_config: |
            experimental-features = nix-command flakes

      - uses: cachix/cachix-action@v15
        with:
          name: darling-nix

      - name: Run syscall regression tests
        run: nix build .#checks.x86_64-linux.syscall-regression -L

  test-nix-integration:
    runs-on: ubuntu-latest
    needs: build
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - uses: cachix/install-nix-action@v27
        with:
          extra_nix_config: |
            experimental-features = nix-command flakes
            system-features = kvm

      - uses: cachix/cachix-action@v15
        with:
          name: darling-nix

      - name: Run Nix-in-Darling integration test
        run: nix build .#checks.x86_64-linux.nix-in-darling -L
        timeout-minutes: 60  # generous timeout for VM test
```

**Notes**:

- The integration test requires KVM for the NixOS VM. GitHub's `ubuntu-latest`
  runners have KVM available. Verify with `system-features = kvm` in the Nix
  config.
- The build job runs first and pushes artifacts to Cachix. Subsequent test jobs
  pull from the cache, avoiding redundant rebuilds.
- The `timeout-minutes: 60` is important — Darling operations inside a VM inside
  CI can be very slow. Adjust as needed based on real-world timings.
- `submodules: recursive` is required because Darling has 100+ submodules. This
  checkout step may itself take 5–10 minutes.

**Alternative: use a self-hosted runner** if GitHub's runners are too slow or
lack KVM. A dedicated NixOS machine with nested virtualisation enabled would
provide the most reliable CI environment.

---

### 6.4 — Syscall Regression Test Suite

Create a set of small C programs under `tests/syscalls/` that exercise every
syscall we've fixed. These run inside `darling shell` and assert expected
behavior.

**Directory structure**:

```
tests/
├── syscalls/
│   ├── test_lchflags.c
│   ├── test_setattrlist.c
│   ├── test_renameatx_np.c
│   ├── test_utimensat.c
│   ├── test_clonefile.c
│   ├── test_getentropy.c
│   ├── test_posix_spawn.c
│   ├── test_xattr.c
│   ├── test_fcntl_locking.c
│   └── run_all.sh
├── sandbox/
│   ├── test_sandbox_exec.sh
│   ├── test_sandbox_init.c
│   └── run_all.sh
└── nix/
    ├── test_nix_eval.sh
    ├── test_nix_build_trivial.sh
    ├── test_nix_substitution.sh
    └── run_all.sh
```

**Example test — `test_lchflags.c`**:

```c
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>

#define ASSERT(cond, msg) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s (errno=%d: %s)\n", msg, errno, strerror(errno)); \
        exit(1); \
    } \
} while (0)

int main(void) {
    const char *path = "/tmp/test_lchflags_XXXXXX";
    char tmppath[256];
    strncpy(tmppath, path, sizeof(tmppath));

    int fd = mkstemp(tmppath);
    ASSERT(fd >= 0, "mkstemp failed");
    close(fd);

    /* Clear all flags — this is what Nix does */
    int ret = lchflags(tmppath, 0);
    ASSERT(ret == 0, "lchflags(path, 0) should return 0");

    unlink(tmppath);
    printf("PASS: test_lchflags\n");
    return 0;
}
```

**Example test — `test_renameatx_np.c`**:

```c
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>

/* macOS renameatx_np flags */
#ifndef RENAME_SWAP
#define RENAME_SWAP 0x00000002
#endif
#ifndef RENAME_EXCL
#define RENAME_EXCL 0x00000004
#endif

extern int renameatx_np(int fromfd, const char *from,
                        int tofd, const char *to, unsigned int flags);

#define ASSERT(cond, msg) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s (errno=%d: %s)\n", msg, errno, strerror(errno)); \
        exit(1); \
    } \
} while (0)

static void write_file(const char *path, const char *content) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    ASSERT(fd >= 0, "open for write failed");
    write(fd, content, strlen(content));
    close(fd);
}

static void read_file(const char *path, char *buf, size_t len) {
    int fd = open(path, O_RDONLY);
    ASSERT(fd >= 0, "open for read failed");
    ssize_t n = read(fd, buf, len - 1);
    ASSERT(n >= 0, "read failed");
    buf[n] = '\0';
    close(fd);
}

int main(void) {
    const char *a = "/tmp/renameatx_a";
    const char *b = "/tmp/renameatx_b";
    char buf[64];

    /* Test RENAME_SWAP */
    write_file(a, "AAA");
    write_file(b, "BBB");

    int ret = renameatx_np(AT_FDCWD, a, AT_FDCWD, b, RENAME_SWAP);
    ASSERT(ret == 0, "renameatx_np RENAME_SWAP failed");

    read_file(a, buf, sizeof(buf));
    ASSERT(strcmp(buf, "BBB") == 0, "after swap, a should contain BBB");

    read_file(b, buf, sizeof(buf));
    ASSERT(strcmp(buf, "AAA") == 0, "after swap, b should contain AAA");

    /* Test RENAME_EXCL */
    unlink(b);
    ret = renameatx_np(AT_FDCWD, a, AT_FDCWD, b, RENAME_EXCL);
    ASSERT(ret == 0, "renameatx_np RENAME_EXCL (target absent) should succeed");

    write_file(a, "CCC");
    ret = renameatx_np(AT_FDCWD, a, AT_FDCWD, b, RENAME_EXCL);
    ASSERT(ret != 0 && errno == EEXIST,
           "renameatx_np RENAME_EXCL (target exists) should fail with EEXIST");

    unlink(a);
    unlink(b);
    printf("PASS: test_renameatx_np\n");
    return 0;
}
```

**Runner script — `tests/syscalls/run_all.sh`**:

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
ERRORS=""

for test_src in "$SCRIPT_DIR"/test_*.c; do
    test_name="$(basename "$test_src" .c)"
    test_bin="/tmp/$test_name"

    echo "--- $test_name ---"

    # Compile inside Darling using Apple's clang
    if ! cc -o "$test_bin" "$test_src" 2>&1; then
        echo "FAIL: $test_name (compilation failed)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  $test_name: compilation failed"
        continue
    fi

    # Run
    if "$test_bin"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  $test_name: test failed"
    fi

    rm -f "$test_bin"
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ $FAIL -gt 0 ]; then
    echo -e "Failures:$ERRORS"
    exit 1
fi
```

**Integration with Nix**: Create a derivation that compiles and runs all tests
inside a Darling prefix (this requires a NixOS VM test context since Darling
needs namespace support):

```nix
checks.x86_64-linux.syscall-regression = nixosTest {
  name = "darling-syscall-regression";
  nodes.machine = { ... }: {
    imports = [ ../nixosModules/darling ];
    programs.darling.enable = true;
  };
  testScript = ''
    machine.wait_for_unit("default.target")
    machine.succeed("darling shell bash /path/to/tests/syscalls/run_all.sh")
  '';
};
```

---

### 6.5 — Nix Compatibility Test Matrix

Create a test that attempts to build an expanding set of Nixpkgs packages inside
Darling and tracks pass/fail rates over time.

**File**: `tests/nix/compatibility-matrix.sh`

**Approach**:

```bash
#!/bin/bash
# Test building a set of packages inside Darling
# Tracks pass/fail for each package

PACKAGES=(
    # Tier 1: Must work (no native compilation, just fetch from cache)
    "hello"
    "which"
    "yes"

    # Tier 2: Should work (simple C programs)
    "tree"
    "jq"

    # Tier 3: Stretch (complex builds)
    "curl"
    "git"
    "python3"
)

RESULTS_FILE="/tmp/compat-matrix-$(date +%Y%m%d).json"
echo '{"results": [' > "$RESULTS_FILE"

for pkg in "${PACKAGES[@]}"; do
    echo "--- Testing: $pkg ---"
    start_time=$(date +%s)

    if darling-nix nix-build '<nixpkgs>' -A "$pkg" --system x86_64-darwin --no-out-link 2>/tmp/build-$pkg.log; then
        status="pass"
    else
        status="fail"
    fi

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    echo "  $pkg: $status (${duration}s)"
    echo "  {\"package\": \"$pkg\", \"status\": \"$status\", \"duration\": $duration}," >> "$RESULTS_FILE"
done

# Close JSON (remove trailing comma hack)
sed -i '$ s/,$//' "$RESULTS_FILE"
echo ']}' >> "$RESULTS_FILE"

echo ""
echo "Results written to $RESULTS_FILE"

# Summary
pass_count=$(grep -c '"pass"' "$RESULTS_FILE" || true)
fail_count=$(grep -c '"fail"' "$RESULTS_FILE" || true)
total=${#PACKAGES[@]}
echo "=== Compatibility: $pass_count/$total passed ($fail_count failed) ==="
```

**Tracking over time**: Store the JSON results as CI artifacts. A simple script
can compare results between runs to detect regressions (a package that was
passing now fails) or progress (a package that was failing now passes).

---

### 6.6 — Darling Build Smoke Test

A lighter-weight test that doesn't need a NixOS VM — just verifies Darling
builds from source with Nix:

```nix
checks.x86_64-linux.darling-build = self.packages.x86_64-linux.darling;
```

This runs as part of `nix flake check` and catches build regressions (missing
dependencies, broken patches, compiler errors) without the overhead of a VM
test.

---

### 6.7 — Test Darling SDK Cross-Compilation

Verify that the SDK output can be used to cross-compile Darwin binaries from
Linux (without running them inside Darling — just the compilation step):

```bash
# Use the SDK's clang + ld64 to compile a Darwin binary on Linux
$darling_sdk/bin/x86_64-apple-darwin-ld64 ...  # or however the SDK exposes the tools
```

This tests the SDK packaging independently of the Darling runtime.

---

## Test Categories

| Category | Runs In | Needs VM | Frequency | Phase Dependency |
|---|---|---|---|---|
| Build smoke test | Nix sandbox | No | Every PR | Phase 0 |
| SDK cross-compile | Nix sandbox | No | Every PR | Phase 0 |
| Syscall regression | Darling shell (in VM) | Yes | Every PR | Phase 1 |
| Sandbox stub test | Darling shell (in VM) | Yes | Every PR | Phase 2 |
| Nix installation | Darling shell (in VM) | Yes | Every PR | Phase 3 |
| Trivial build | Darling shell (in VM) | Yes | Every PR | Phase 4 |
| Compatibility matrix | Darling shell (in VM) | Yes | Nightly / weekly | Phase 4 |
| Daemon & multi-user | Darling shell (in VM) | Yes | Every PR | Phase 5 |
| Remote builder | NixOS VM with Nix daemon | Yes | Nightly / weekly | Phase 7 |

---

## CI Performance Considerations

NixOS VM tests are slow. Strategies to keep CI times reasonable:

1. **Cachix**: Push all build artifacts to a binary cache. Subsequent runs skip
   rebuilding Darling (which takes 30+ minutes from scratch).

2. **Test parallelism**: Run the build smoke test and SDK test in parallel with
   the VM-based tests (they're independent).

3. **Incremental testing**: On PRs that only touch `plan/` or `docs/`, skip the
   expensive VM tests. Use path filters in the workflow:
   ```yaml
   on:
     push:
       paths-ignore:
         - 'plan/**'
         - '*.md'
   ```

4. **Test VM snapshots**: If the NixOS testing framework supports it, take a
   snapshot after Darling initialization and restore from it for each test. This
   avoids re-bootstrapping Darling's prefix on every test run.

5. **Split VM tests**: Rather than one monolithic test, split into focused tests
   (syscalls, sandbox, Nix install, build). Failed tests give faster feedback
   about what broke.

6. **Timeout management**: Set aggressive but realistic timeouts per test step.
   A hanging test should fail fast rather than consume the full CI allocation:
   ```python
   # In the NixOS test script:
   machine.succeed("timeout 300 darling-nix nix-build ...")
   ```

---

## Verification Checklist

After completing Phase 6, ALL of the following should be true:

- [ ] `nix flake check` passes (includes build smoke test)
- [ ] `.github/workflows/nix-ci.yaml` exists and runs on PRs
- [ ] Syscall regression tests exist for `lchflags`, `renameatx_np`, `utimensat` (at minimum)
- [ ] Sandbox stub tests verify `sandbox-exec` passthrough works
- [ ] NixOS VM test installs Nix inside Darling and evaluates an expression
- [ ] NixOS VM test builds a trivial derivation inside Darling
- [ ] CI results are visible on GitHub PR checks
- [ ] Cachix cache is populated by CI and speeds up subsequent runs
- [ ] Compatibility matrix script exists and produces JSON output
- [ ] Adding a new syscall implementation has a clear path: implement → add test → CI verifies

---

## Maintenance

- **Adding new tests**: When a new syscall is implemented (Phase 1), add a
  corresponding `test_<syscall>.c` to `tests/syscalls/`. The runner script
  picks it up automatically.

- **Updating the compatibility matrix**: As more packages start working, add them
  to the `PACKAGES` array. The matrix should only grow, never shrink (removing a
  package hides regressions).

- **Flaky tests**: If a test passes intermittently (likely due to Darling's
  incomplete implementation), mark it as `@flaky` in the test script and track
  it separately. Do not disable it — flaky tests are signals of real issues.

- **CI costs**: NixOS VM tests are expensive. Monitor CI usage and adjust the
  trigger frequency (e.g., move the compatibility matrix to weekly if it's too
  costly to run on every PR).

---

*[← Phase 5 — Nix Daemon](./07-phase5-daemon.md) | [Phase 7 — Remote Builder →](./09-phase7-remote-builder.md)*