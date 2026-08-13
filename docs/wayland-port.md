# Moving the GUI backend from X11 to Wayland

Asked for 2026-08-13. This is the survey and the plan, written before any code, from reading the
tree rather than from assumptions about how Darling does GUI.

## DECIDED 2026-08-13: WAYLAND ONLY. X11 goes.

The user's words: X11 does not matter and the backend can be eliminated entirely, but it is
worth keeping as inspiration. That is the plan below. The X11 sources are not deleted from the
pin, only from the build and the prefix, so they stay readable in `vendor/src/cocotron` while
the Wayland ones are written against them.

**AND IT MOVES ONE THING ONTO THE CRITICAL PATH.** `scripts/checks/buck-appkit-check.nu` is the
only GUI verification this repo has, and it works by opening a window under X11. Removing X11
removes the gate. So the headless-compositor check is not phase 4 any more, it is a
PRECONDITION for deleting anything: Wayland must be verifiable before X11 stops being.

## How a backend is selected, which is what makes this tractable

CoreGraphics does not link a window system. It **loads backend bundles at runtime**
(`vendor/src/cocotron/CoreGraphics/CGS.m`, `_CGSLoadBackend`):

1. every `*.backend` bundle under the framework's `Resources/Backends/` is loaded;
2. they are sorted by the `NSPriority` integer in their `Info.plist`, highest first;
3. the first whose principal class answers `+isAvailable` YES becomes the backend.

X11 today is `NSPriority` 200 and its probe is `getenv("DISPLAY") != NULL`. A Wayland backend
plugs into the same three points with `getenv("WAYLAND_DISPLAY")`, so **the work is one bundle,
not a change to CoreGraphics**. While both exist, priority decides; when X11 is deleted, the
Wayland bundle is simply the only one there.

## What has to be written

Two bundles, each a principal class plus its window and surface classes:

    CoreGraphics/X11.backend    11 files, 2,442 lines   CGSConnectionX11, CGSSurfaceX11,
                                                        CGSWindowX11, X11KeySymToUCS
    AppKit/X11.backend          16 files, 4,936 lines   the NSDisplay/NSWindow/event side

7,378 lines total, Objective-C, in a pin (Cocotron). **They are upstream code in
`vendor/src/cocotron`, which is dead upstream**, so the Wayland ones should be FIRST PARTY under
`src/darwin/` rather than a patch to a pin. That also keeps the pin patch set from growing a
feature-sized delta, which the repo rule about de-vendoring already discourages.

Start with CoreGraphics: it is the smaller half and the AppKit backend sits on top of it.

## What the X11 backend actually uses, which is the size of the Wayland side

From the CoreGraphics backend: `XOpenDisplay`, `XNextEvent`/`XPending`, `XQueryPointer`,
`XSetErrorHandler`, `XSynchronize`, the **Xkb** family (`XkbQueryExtension`,
`XkbSelectEvents`, `XkbRF_GetNamesProp`, `XkbLibraryVersion`) and **XRandR**
(`XRRQueryExtension`, `XRRSelectInput`).

The Wayland equivalents:

    XOpenDisplay / XNextEvent      wl_display_connect, wl_display_dispatch, the registry
    window creation                xdg_wm_base, xdg_surface, xdg_toplevel
    surface pixels                 wl_shm buffers (CG hands the backend a bitmap), or EGL later
    XQueryPointer, events          wl_seat, wl_pointer, wl_keyboard
    the Xkb family                 libxkbcommon, which is the same keymap model
    XRandR                         wl_output

## Phase 1, and it is small: bridge the host libraries

Cider does not port host libraries, it BRIDGES them: `src/linux/native/BUCK` lists
`(name, soname, install dir)` triples and `elf_wrapper` generates a Mach-O stub per library that
forwards through libelfloader. The X entry is one line:

    ("X11", "libX11.so", "/usr/lib/native"),

Wayland needs three:

    ("wayland-client", "libwayland-client.so", "/usr/lib/native"),
    ("wayland-cursor", "libwayland-cursor.so", "/usr/lib/native"),
    ("xkbcommon",      "libxkbcommon.so",      "/usr/lib/native"),

and each also needs its `# buck-registry:` pragma in that file, the host library probe list in
`scripts/buck-setup.nu` (which resolves the real `.so` directories that `wrapgen` dlopens at
BUILD time), and an install entry in `buck/prefix/BUCK` and `buck/prefix-min/BUCK`.

**One thing to check before writing any of it:** `wrapgen` reads the host `.so` at build time, so
the build machine must have Wayland client libraries present. That is a nixpkgs input change in
`nix/ciderBuildInputs.nix`, not just a BUCK edit.

## Phases

    1. bridge libwayland-client, libwayland-cursor, libxkbcommon        small, mechanical
    2. a headless compositor the checks can run against                 PROTOTYPE FIRST, see below
    3. src/darwin/CoreGraphics-wayland: CGSConnection/Surface/Window     the real work
    4. src/darwin/AppKit-wayland: the NSDisplay and event side           the larger half
    5. port buck-appkit-check to it, then DELETE X11:                    the removal, all at once
         the two X11.backend bundles from buck/prefix/BUCK and prefix-min
         X11, Xext, XRandR, Xcursor and xkbfile from src/linux/native/BUCK
         the same five from the host probe list in scripts/buck-setup.nu
         whatever X headers the SDK farm carries for them

Phase 2 before phase 3 is deliberate. Writing 7,000 lines of backend with no way to run it is how
this repo has been burned before; the check comes first so every step after it is verifiable.

## The gate, and why it is now phase 2 rather than last

`scripts/checks/buck-appkit-check.nu` boots a container and opens a trivial AppKit window under
X11, and the README lists it as the only GUI thing this fork claims. Since X11 is going, that
check has to be REPLACED, not kept: a Wayland session for the container to connect to, and the
same trivial window opened against it.

That needs a headless compositor in the check environment, the way the X11 check needs an X
server. It is the one piece with no precedent in this repo, so it is prototyped before the
backend is written rather than after.

## What stays

The Cocotron pin stays: it is where AppKit and CoreGraphics themselves come from, so only the
two `X11.backend` subdirectories stop being built. They remain on disk as the reference the
Wayland classes are written against, which is what the user asked for.

## The app ladder, and the north star

The user's goal, 2026-08-13: once Wayland works at all, keep raising the bar with more demanding
applications until a real office suite runs. OnlyOffice was the first suggestion and was changed
to LibreOffice when it turned out `nixpkgs#onlyoffice-desktopeditors` is an ELF Linux Qt build
whose `meta.platforms` contains no darwin at all.

**`nixpkgs#libreoffice-bin` IS a macOS build, and it is a better target than OnlyOffice for this
port specifically:**

    meta.platforms          [ "x86_64-darwin" "aarch64-darwin" ]
    version                 25.2.1
    src                     LibreOffice_25.2.1_MacOS_x86-64.dmg, from documentfoundation.org

It is not Qt on macOS. LibreOffice carries its own VCL backend per platform and the macOS one is
Cocoa, so it exercises **exactly the AppKit and CoreGraphics path this fork implements** rather
than a toolkit that would have to be ported first. That makes it a north star that measures the
right thing.

**ONE PLANNING FACT FELL OUT OF LOOKING IT UP, and it belongs in the aarch64 discussion rather
than here: nixpkgs warns that 26.05 is the LAST release to support x86_64-darwin.** The test
corpus for a 64-bit Intel guest therefore has a shelf life, which is an argument for the aarch64
release that is already the next one.

The rungs, in the order they get hard, each one a check that can fail for a nameable reason:

    1. appkit_probe.m, which exists: NSApplication up, one NSWindow, one event pumped
    2. the same, but DRAWING: a filled rect, then text, so the surface path is exercised
       rather than just window creation
    3. input: a synthetic key and pointer event round trip, which is where xkbcommon lands
    4. resize, multiple windows, and a second screen from wl_output
    5. a real Cocoa application built with the guest toolchain
    6. LibreOffice from the dmg above

Rungs 1 to 4 are all verifiable with a headless compositor and a screenshot, which is why the
compositor comes first.

## Phase B is done: the headless compositor works, measured 2026-08-13

Proven before any backend code, which is the whole point of doing it first:

    weston 15.0.1 --backend=headless --socket=cider-wl --width=1024 --height=768
    wayland-info                     connects, 21 globals, headless output 1024x768
    weston-flower                    ran to the timeout and the compositor logged a surface

The globals a backend needs are all present:

    wl_compositor   version 5      wl_shm      version 2
    xdg_wm_base     version 5      wl_output   version 4

**TWO THINGS THE PROTOTYPE TAUGHT, both of which would have cost an hour later.**

`XDG_RUNTIME_DIR` must be SHORT. The first attempt put the socket in the session scratchpad and
weston died with `failed to add socket: File name too long`: a unix socket path caps around 108
bytes and the scratchpad path alone is longer. The check should use `/tmp/cider-wl-$(id -u)`.

**THERE IS NO `wl_seat`.** Headless weston with no input devices advertises 21 globals and a seat
is not one of them, so rung 3, the key and pointer round trip, cannot be done against this
configuration as it stands. That is a problem for the INPUT rung only; windows and pixels are
unaffected. Options to settle when rung 3 arrives: a wlroots compositor instead (`cage` or `sway`
with the headless backend, which synthesizes a seat), or weston with a virtual input device.
Worth knowing now rather than discovering it with a backend already written.

**AND THE CONTROL IS THE POINT.** `weston-flower` is a known-good client on the same socket. When
our backend fails, running it says whether the compositor or the backend is at fault, which is
the ambiguity this repo has been bitten by repeatedly.

## How a RUST backend actually gets built here, decided from the constraints

The user chose Rust. A Cocotron backend is an Objective-C class hierarchy, so the shape is not
obvious, and three facts of this build system decide it:

  ONLY libc AND bitflags ARE VENDORED. vendor/rust has 53 crates and neither objc2 nor
    wayland-client is among them, so anything else means vendoring a crate family.
  build.rs DOES NOT RUN under buck2. That is already recorded in buck/rules/rust.bzl, and it
    rules out wayland-protocols and wayland-sys, whose whole job is code generation at build time.
  A GUEST CRATE IS ONE FILE today, because the endpoint stages the crate root and nothing else.
    That is the first thing to fix, and it is one line: srcset.rs already takes the whole
    directory for any action whose identity contains "(rustc ", which is why HOST crates can be
    multi-file, and the guest rule's category is darwin_rust_staticlib.

So the backend is:

    protocol           wayland-scanner (a host tool, like wrapgen and MIG already are) emits the
                       xdg-shell C glue in a codegen rule, compiled as C
    wayland client     hand-written extern "C" declarations against libwayland-client, which is
                       already how this fork reaches every host library
    objc classes       hand-written extern "C" against the objc runtime:
                       objc_allocateClassPair, class_addMethod, objc_msgSend, and one
                       +load-equivalent entry point that registers CGSConnectionWayland
    the rest           ordinary Rust

That keeps the vendored crate set at libc, and it matches how the repo already treats generated
code and host libraries rather than inventing a second mechanism.
