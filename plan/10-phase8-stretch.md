# Phase 8 — Long-Term / Stretch Goals

**Priority**: P3 · **Effort**: XL (months–years) · **Depends on**: Phase 7 (remote builder)

These are aspirational items that would make the Darling+Nix story truly
compelling but are not required for basic functionality. Each is a significant
project in its own right. They're documented here to provide direction for
future contributors and to ensure the earlier phases don't make architectural
decisions that would preclude these goals.

---

## 8.1 — `aarch64-darwin` Support

**What**: Build and test Apple Silicon (`aarch64-darwin`) packages on Linux.

**Why it matters**: Apple has fully transitioned to ARM. The majority of macOS
users now run Apple Silicon. Nixpkgs' `aarch64-darwin` support is growing
rapidly, but CI coverage is limited by hardware availability.

**Current state**: Darling only supports `x86_64`. The entire codebase —
darlingserver's syscall translation, the Mach-O loader, dyld, and all the Darwin
libraries — is x86_64-only.

**Approach options**:

| Option | Complexity | Performance | Notes |
|---|---|---|---|
| QEMU user-mode emulation | Medium | Slow (~10–50×) | Translate AArch64 instructions to x86_64; `qemu-aarch64` already exists but doesn't handle Mach-O |
| Full AArch64 Darling port | Very High | Near-native on aarch64-linux | Requires porting all of darlingserver, dyld, and libSystem to AArch64 |
| Rosetta-like translation | Extremely High | Fast (~1.5–3×) | AOT binary translation from AArch64 Mach-O to x86_64 ELF; research-grade effort |
| FEX-Emu integration | High | Moderate (~3–8×) | FEX-Emu handles x86_64→AArch64 translation; combine with Darling for Mach-O→ELF on AArch64 Linux hosts |

**Recommended path**: Start with QEMU user-mode for correctness testing (not
performance). A Darling-aware QEMU wrapper that loads Mach-O binaries and
translates Darwin syscalls via darlingserver, with AArch64 instruction emulation
handled by QEMU.

Long-term, a native AArch64 port of Darling is the right answer if the project
gains enough contributors.

**Prerequisites**:
- All Phase 1–7 work must be solid on x86_64 first.
- Darlingserver's architecture must be cleanly separated from x86_64 specifics
  (register mapping, calling conventions, instruction patching).
- The Mach-O loader must handle `arm64` and `arm64e` slices.

**Effort**: 6–18 months for QEMU approach; years for native port.

---

## 8.2 — GUI Application Testing

**What**: Run macOS GUI applications inside Darling on Linux with enough fidelity
for automated screenshot-based testing.

**Why it matters**: Many Nixpkgs Darwin packages include GUI components (e.g.,
Emacs with Cocoa frontend, various `.app` bundles). Currently there's no way to
test these on Linux.

**Current state**: Darling has partial Cocoa/AppKit support via
[Cocotron](https://github.com/darlinghq/darling-cocotron), which translates
Cocoa drawing calls to X11. Basic windows can be created but most applications
crash or render incorrectly.

**Approach**:

1. **Headless rendering**: Run Darling with a virtual X11 server (`Xvfb`) or
   Wayland compositor (`wlheadless`). Cocotron renders to the virtual display.

2. **Screenshot capture**: After launching an app, capture the framebuffer and
   compare against reference screenshots using image comparison tools (e.g.,
   `perceptualdiff`, `pixelmatch`).

3. **Accessibility-based testing**: If Darling implements enough of the
   Accessibility framework, use it for UI testing without screenshots (more
   robust to rendering differences).

**Example test workflow**:

```bash
# Start Xvfb
Xvfb :99 -screen 0 1920x1080x24 &
export DISPLAY=:99

# Launch a Cocoa app inside Darling
darling shell open -a /Applications/TextEdit.app &

# Wait for window to appear
sleep 5

# Capture screenshot
import -window root /tmp/screenshot.png

# Compare against reference
perceptualdiff /tmp/screenshot.png tests/references/textedit.png
```

**Blockers**:
- Cocotron's X11 backend needs significant work for modern Cocoa APIs.
- Core Animation, Metal, and modern AppKit features are unimplemented.
- Font rendering differences between macOS (Core Text) and Linux (FreeType) will
  cause pixel-level mismatches — need fuzzy comparison.

**Effort**: 3–12 months for basic "does the window open and look roughly right"
testing. Much longer for full GUI fidelity.

---

## 8.3 — Nix Flake Integration Library

**What**: A Nix library function (`buildDarwinWithDarling`) that lets any flake
build Darwin packages using Darling, without the user needing to set up a remote
builder.

**Why it matters**: The remote builder approach (Phase 7) requires system-level
NixOS configuration. A flake-level library would make Darwin-on-Linux accessible
to any Nix user, even those not running NixOS.

**Design**:

```nix
# In any project's flake.nix:
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    darling-nix.url = "github:user/darling-nix";
  };

  outputs = { self, nixpkgs, darling-nix }: {
    packages.x86_64-linux.hello-darwin =
      darling-nix.lib.buildDarwinWithDarling {
        inherit nixpkgs;
        # Standard mkDerivation arguments:
        pname = "hello";
        version = "2.12.1";
        src = ./. ;
        buildInputs = [ ];
        # Darling-specific options:
        darlingPrefix = "~/.darling";  # optional
        shareStore = true;             # optional
      };
  };
}
```

**Implementation sketch**:

The `buildDarwinWithDarling` function would:

1. Build the derivation specification (`.drv` file) using Nixpkgs' Darwin stdenv.
2. Wrap the build invocation in a `darling shell` call.
3. Handle store path management (shared or copied).
4. Return the output path as a normal Nix derivation result.

**Challenges**:

- This requires Darling to be runnable inside a Nix sandbox (needs namespace
  capabilities). May need `__noChroot = true` or a fixed-output derivation
  wrapper.
- Must handle the bootstrap problem: the Darling binary itself needs to be built
  for Linux before it can be used to build Darwin packages.
- Nix's build sandbox on Linux may conflict with Darling's namespace usage.

**Alternative**: Instead of embedding Darling in the build, provide a flake that
sets up the remote builder and let users `nix build --system x86_64-darwin` as
usual. This is simpler and avoids the sandbox-within-sandbox issues.

**Effort**: 2–4 months for the library; ongoing maintenance as Nixpkgs evolves.

---

## 8.4 — Upstream Contributions

**What**: Push all syscall fixes, sandbox stubs, and compatibility improvements
back to the [upstream Darling project](https://github.com/darlinghq/darling).

**Why it matters**: Maintaining a fork is expensive. Upstream contributions
benefit the entire Darling community and reduce our maintenance burden.

**Strategy**:

1. **Keep changes modular**: Each syscall fix should be a self-contained commit
   with a clear description and test case. This makes upstream review easier.

2. **Separate Nix-specific changes**: Things like the `sandbox-exec` stub,
   Directory Services stubs, and the NixOS module should be kept in our fork/
   overlay. They're useful for the Nix use case but may not align with
   upstream's goals.

3. **Coordinate with upstream**: Open issues/discussions on the Darling GitHub
   before submitting large changes. The Darling team may have opinions on
   implementation approaches (e.g., they may prefer a different `setattrlist`
   implementation than what we propose).

4. **Contribute tests**: Upstream Darling has minimal testing. Contributing our
   syscall regression tests (Phase 6.4) would be valuable even without the
   corresponding fixes.

**Candidates for upstreaming**:

| Change | Upstream Value | Nix-Specific? |
|---|---|---|
| `setattrlist` / `fsetattrlist` implementation | High — many programs need this | No |
| `renameatx_np` (syscall 488) implementation | High — modern coreutils need this | No |
| `utimensat` fixes | High — affects `touch` and many tools | No |
| `clonefile` stub (returns `ENOTSUP`) | Medium — graceful degradation | No |
| `getentropy` mapping to `getrandom` | Medium — security-related programs need this | No |
| macOS version bump (10.15 → 11.0) | High — unblocks modern software | No |
| `sandbox-exec` stub | Medium — useful but opinionated | Somewhat |
| `sandbox_init` errorbuf fix | Low — cosmetic | No |
| Directory Services stubs | Low — very Nix-specific | Yes |
| NixOS module | None — Nix ecosystem only | Yes |

**Effort**: Ongoing; each upstream PR takes 1–4 weeks including review cycles.

---

## 8.5 — macOS SDK Management

**What**: Automate downloading, unpacking, and managing macOS SDKs inside the
Darling prefix via Nix derivations.

**Why it matters**: Building Darwin software requires Apple's SDK headers and
frameworks. Currently, users must manually download Xcode or the Command Line
Tools and install them. This is a friction point and a licensing grey area.

**Approach**:

1. **Use Nixpkgs' existing SDK infrastructure**: Nixpkgs already packages macOS
   SDKs (e.g., `apple-sdk_15`, `apple-sdk_14`). These are available as Nix
   derivations and can be installed into the Darling prefix.

2. **Automatic SDK installation**: The Darling builder setup (Phase 7 NixOS
   module) should automatically install the appropriate SDK into the prefix:
   ```nix
   services.darling-builder.sdk = pkgs.darwin.apple_sdk_15;
   ```

3. **SDK version selection**: Allow users to choose which SDK version to use.
   Different Nixpkgs branches may require different SDK versions.

**Licensing considerations**:

- Apple's Xcode license allows use on Apple hardware. Using Apple's SDK headers
  on Linux (via Darling) is a legal grey area.
- Nixpkgs' SDK packages contain only headers and `.tbd` stub files (not actual
  binaries), which may be covered by fair use for interoperability purposes.
- Darling itself ships significant Apple-derived open-source code under APSL.
- **Recommendation**: Document the licensing situation clearly. Do not distribute
  Apple proprietary binaries. Use open-source headers where possible and let
  users supply their own SDK if needed.

**Effort**: 2–4 weeks for the Nix integration; legal review is separate.

---

## 8.6 — Binary Cache for `x86_64-darwin`

**What**: Run a Darling-based build farm (Hydra, Garnix, or custom) that
continuously builds `x86_64-darwin` packages and populates a public binary
cache.

**Why it matters**: If Darling can reliably build Darwin packages, we can provide
a community binary cache that eliminates the need for Apple hardware for most
users. Even partial coverage (the top 1000 most-used packages) would be
enormously valuable.

**Architecture**:

```
┌──────────────────────────────────────────────┐
│  Hydra / Build Coordinator (NixOS)           │
│  jobset: nixpkgs x86_64-darwin               │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │  Builder 1: NixOS + Darling           │  │
│  │  services.darling-builder.enable       │  │
│  │  maxJobs = 8                          │  │
│  └────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────┐  │
│  │  Builder 2: NixOS + Darling           │  │
│  │  ...                                  │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  → pushes NARs to: darling-cache.example.org │
└──────────────────────────────────────────────┘
```

**Users add the cache**:

```nix
nix.settings = {
  substituters = [ "https://darling-cache.example.org" ];
  trusted-public-keys = [ "darling-cache.example.org-1:AAAA..." ];
};
```

**Challenges**:

- **Reproducibility**: Builds inside Darling may not produce bit-for-bit
  identical outputs to builds on real macOS. This means the cache serves
  "Darling-built" packages that might differ from the official `cache.nixos.org`
  Darwin packages. Users need to understand this.

- **Coverage**: Not all packages will build successfully inside Darling. The
  cache must gracefully handle partial coverage — users fall back to building
  locally (or on real macOS) for packages that aren't cached.

- **Maintenance**: A build farm requires ongoing infrastructure maintenance,
  monitoring, and storage management.

- **Trust**: Users must trust the cache operator. Use Nix's content-addressing
  and signing to provide integrity guarantees.

**Effort**: 1–3 months to set up the infrastructure; ongoing maintenance.

---

## 8.7 — Build Reproducibility Verification

**What**: Ensure that derivation outputs built inside Darling are as close to
bit-for-bit identical as possible to those built on real macOS.

**Why it matters**: If Darling-built packages differ from real macOS-built
packages, it undermines the value of the compatibility layer. Ideally, a package
built inside Darling should be indistinguishable from one built on real macOS.

**Approach**:

1. **Identify sources of non-determinism**:
   - Timestamps embedded in binaries (Mach-O headers, `__DATA` segments).
   - Hostname / username embedded in build artifacts.
   - Random data (UUIDs, build IDs) that differ between builds.
   - Filesystem ordering differences (`readdir` order).
   - Floating-point rounding differences (unlikely but possible if Darling's FPU
     emulation differs).

2. **Compare build outputs**:
   ```bash
   # Build on real macOS
   real_output=$(nix-build '<nixpkgs>' -A hello --system x86_64-darwin)

   # Build inside Darling
   darling_output=$(darling-nix nix-build '<nixpkgs>' -A hello --system x86_64-darwin)

   # Compare
   diffoscope "$real_output" "$darling_output"
   ```

3. **Fix divergences**: For each difference, determine if it's a Darling bug
   (fix it) or inherent non-determinism (document it).

4. **Content-addressed derivations**: Nix's experimental content-addressed (CA)
   derivation mode hashes outputs by content rather than by input. This means
   two builds that produce identical content (regardless of where they were
   built) share the same store path. Push for CA derivation support to make
   Darling-built and macOS-built outputs interchangeable.

**Effort**: Ongoing; this is a continuous improvement process rather than a
one-time task.

---

## 8.8 — Container / VM Image Distribution

**What**: Distribute pre-configured Darling+Nix environments as OCI container
images or VM images for easy adoption.

**Why it matters**: Not everyone uses NixOS. A Docker/Podman image or a QEMU VM
image with Darling+Nix pre-installed would make Darwin-on-Linux accessible to
the broader developer community.

**Deliverables**:

1. **OCI image** (`ghcr.io/user/darling-nix:latest`):
   ```dockerfile
   FROM nixos/nix:latest
   RUN nix build github:user/darling-nix#darling
   RUN /path/to/scripts/install-nix-in-darling.sh
   ENTRYPOINT ["darling-nix"]
   ```
   Requires: Docker-in-Docker or privileged mode for namespaces.

2. **NixOS VM image**: A QEMU qcow2 image built with `nixos-generators` that
   includes the `darling-builder` NixOS module pre-configured.

3. **GitHub Codespaces / Gitpod integration**: A `.devcontainer.json` that sets
   up a development environment with Darling+Nix for cloud-based development.

**Effort**: 2–4 weeks per distribution format.

---

## Summary: Stretch Goal Prioritization

If resources allow work beyond Phase 7, prioritize in this order:

1. **8.4 — Upstream contributions**: Lowest effort, highest community value.
2. **8.5 — SDK management**: Directly improves usability of Phases 4–7.
3. **8.7 — Reproducibility**: Builds confidence in Darling-built packages.
4. **8.6 — Binary cache**: High value but requires infrastructure commitment.
5. **8.3 — Flake library**: Nice developer experience but requires solving hard
   sandbox-in-sandbox problems.
6. **8.8 — Container images**: Broadens the audience beyond NixOS users.
7. **8.2 — GUI testing**: Niche but uniquely valuable; depends on Cocotron
   maturity.
8. **8.1 — `aarch64-darwin`**: Most impactful long-term, but the most work.

---

*[← Phase 7 — Remote Builder](./09-phase7-remote-builder.md) | [Architecture →](./11-architecture.md)*