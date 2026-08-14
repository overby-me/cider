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

**STATUS 2026-08-13.** Rungs 1, 2 and 5 are green and gated by scripts/checks/buck-appkit-check.nu,
which runs on weston now rather than Xvfb. Rung 4 is half done: the screen size comes from
wl_output and the gate proves it by running weston at a size the fallback cannot produce. Rung 3,
input, is still blocked on headless weston advertising no wl_seat.

Rung 6 turned out NOT to be gated on the display at all. LibreOffice loads, initialises, and
brings this backend up underneath itself; what stopped it was a chain of framework gaps that
`--headless` reproduces exactly, with no window and no compositor. See docs/libreoffice-gap.md.
The lesson worth keeping: **a control that removes the display and reproduces the failure is what
told us the display was not the problem**, and it cost one run.

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

## Step D has started, and here is the surface a backend has to implement

Read off the Cocotron headers rather than guessed, so the Rust side has a checklist:

    CGSConnection   12   initWithConnectionID, dealloc, windowForId, newWindow, destroyWindow,
                         mouseLocation, setMode:forScreen:, createScreens, createKeyboardLayout,
                         +isAvailable, _windowInvalidated, nativeDisplay
    CGSWindow       13   initWithRegion, dealloc, surfaceForId, orderWindow:relativeTo:, moveTo:,
                         setRegion:, getRect:, setProperty:value:, getProperty:value:, invalidate,
                         nativeWindow, createSurface, _surfaceInvalidated:
    CGSSurface       4   initWithWindow:, setBounds:, nativeWindow, invalidate

29 methods. The X11 backend implements them in 2,442 lines of Objective-C.

**THE FIRST RUNG IS SELECTION, NOT WINDOWS.** src/darwin/wayland/backend.rs registers
CGSConnectionWayland with one class method, +isAvailable, and prints a marker either way. That is
enough for _CGSLoadBackend to choose it on a Wayland session, and it is checkable on its own:
either the marker appears in the probe log or the bundle was never loaded, which is the first
question a failing run asks. Windows come next, against a gate that already exists.

**THREE THINGS THE RUST SIDE NEEDS AND HAS.** The ObjC runtime by hand, six extern declarations
in objc.rs, because vendor/rust carries neither objc2 nor its family and adding one would be a
vendoring exercise to get what a handful of externs give. The type ENCODINGS spelled out beside
each method, since class_addMethod does not validate them and a mismatch corrupts arguments at
the first call rather than failing at registration. And a C constructor in backend_init.c, in its
own file because shim.c is shared with the probe, which has no backend in it and would not link.

## RUNG ZERO IS GREEN: a guest binary reached a compositor, 2026-08-13

    ok   weston is up on /tmp/cider-wayland-1000/wl/cider-wl
    ok   control: wayland-info sees 21 globals on the same socket
    ok   the guest connected to the compositor
    ok   wl_compositor, wl_shm and xdg_wm_base are all bound

The probe reports `globals=21 compositor=true shm=true xdg_wm_base=true output=true`, which is
everything a window needs. `wl_seat` is absent because weston headless advertises none, which is
a fact about the test compositor rather than about the guest.

**THE FOUR CONDITIONS, and each one fails in a way that looks exactly like the others.** They are
in the check now so nobody has to rediscover them:

    LD_LIBRARY_PATH must carry elf_lib_dirs     or the stub cannot dlopen the real .so and the
                                                guest prints nothing at all
    the socket must live OUTSIDE the prefix     the container mounts a fresh tmpfs over /tmp, so
                                                PREFIX/tmp/wl is invisible from inside
    the daemon carries the environment          libwayland is HOST code in the guest process and
                                                reads ciderd's environment, not the guest's
    the container does NOT chroot               a guest process has root=/ and sees the host
                                                filesystem at /Volumes/SystemRoot, while host
                                                code in the same process uses host paths

That last one is the reason the first three attempts each failed differently: there are two path
spaces in one process, and which one applies depends on which side of the bridge is calling.

**THE PROBE ASKS "does the bridge work" FIRST**, with `wl_list_init`, which writes two pointers
into a struct the guest owns. That is an observable effect rather than an inference, and until it
holds every other result is noise.

## The headless compositor needs a RENDERER, and its default is a no-op

Measured while chasing a buffer that was attached and never released: weston's headless backend
selects the **no-op renderer** by default, and prints it as `no-op renderer SHM seed: 0` among a
page of capability lines nobody reads. A no-op renderer never reads a client buffer, so it never
releases one, and a client waiting for the release waits forever with nothing in any log.

The checks pass `--renderer=pixman` so the compositor actually composites in software. Worth
knowing generally: a headless compositor that "runs fine" can still be doing nothing at all, and
that will look exactly like a client bug.

## THE CoreGraphics BACKEND MECHANISM IS DEAD IN THIS PREFIX, INCLUDING X11's

Found while checking why a correctly built Wayland.backend was never loaded. The layout is:

    CoreGraphics.framework/Versions/A/CoreGraphics                       the binary
    CoreGraphics.framework/Versions/C/Resources/Backends/X11.backend     the backends
    CoreGraphics.framework/Versions/Current -> A

`_CGSLoadBackend` asks `[NSBundle bundleForClass:]` for its Resources, which resolves through
`Current`, which is `A`, which has no `Resources` at all. So `pathsForResourcesOfType:@"backend"`
returns an empty list and **no CoreGraphics backend has ever been loaded in a prefix built here**.

A `DYLD_PRINT_LIBRARIES` trace of the AppKit probe confirms it. The only backend bundle loaded in
the whole run is

    AppKit.framework/Resources/Backends/X11.backend/Contents/MacOS/X11

**SO THE LIVE PLUG-IN POINT IS AppKit's NSDisplay, not CoreGraphics' CGSConnection.** That is
where the Wayland work goes. The mechanism is the same shape, with one difference that matters:

    CoreGraphics   sorts by NSPriority, then asks the principal class +isAvailable
    AppKit         sorts by NSPriority, then just does [[principalClass alloc] init] and takes
                   the first that returns non-nil

So on the AppKit side, AVAILABILITY IS EXPRESSED BY RETURNING nil FROM init. There is no
+isAvailable to implement.

This is also a defect to fix independently: either Versions/C should be Current, or the backends
should install under Versions/A/Resources. Until then the CoreGraphics X11 backend is dead code.

## What is ACTUALLY left, measured rather than estimated

The earlier figure of 7,378 lines counted both X11 backends whole. Splitting them by what the
work really is gives a much better number, and one decision worth taking deliberately.

    X11Display.m        1545   of which 869 touch X11 and 486 do not
    X11KeySymToUCS.m    1663   a keysym to Unicode TABLE
    X11Window.m          730   the CGWindow subclass
    X11Pasteboard.m      342
    X11Cursor.m          123
    X11SubWindow.m        57

**THE 1,663 LINE TABLE DOES NOT GET PORTED AT ALL.** It maps X keysyms to Unicode by hand;
xkbcommon returns UTF-8 directly, so the Wayland equivalent is closer to fifty lines than to
sixteen hundred. That single fact removes more than a third of the apparent work.

**31 OF THE 49 METHODS IN X11Display DO NOT TOUCH X11.** They are fontconfig enumeration,
pasteboard, system colours, cursors and the dragging manager: display-agnostic code that happens
to live in the X11 class. 486 lines of it.

So the genuinely new work is roughly:

    869   the display: connect, screens from wl_output, keyboard layout from xkbcommon
    730   the window: xdg_toplevel and wl_shm, whose machinery is already proven by the probe
    342   pasteboard, which is wl_data_device rather than X selections
    123   cursor, which is wl_cursor
     57   subsurfaces
    ----
   2121   lines of Rust, plus about a hundred for xkbcommon

### THE DECISION: what to do with the 486 display-agnostic lines

  A. PATCH COCOTRON to move them from X11Display into NSDisplay, the abstract base. Every backend
     then inherits fonts, pasteboard, colours and cursors, and the Wayland backend implements only
     the windowing methods. It is the smallest total change and it makes deleting X11 clean. The
     cost is a patch to a vendored pin, which this repo deliberately avoids for FEATURES, though
     this is a refactor rather than a feature.

  B. REIMPLEMENT THEM IN RUST, which means fontconfig FFI, pasteboard and colour tables in the new
     backend. No pin is touched and the backend is self-contained, at the price of writing 486
     lines that already exist and work.

  C. KEEP THE X11 BACKEND INSTALLED for those services only. Cheapest now, but it contradicts
     Wayland-only and leaves the X libraries in the bridge.

## LibreOffice Writer lays out a real window, 2026-08-14

Three walls fell, each of which had ENDED THE PROCESS, and none of which was about Wayland:

1. `-pasteboardWithName:` answered nil. Fatal, not degraded: the office asks for the general
   pasteboard while building its first frame. `WaylandPasteboard.m` is a process-local clipboard.
   Cross-application transfer still needs wl_data_device and a seat.
2. `-[NSScroller setKnobProportion:]` did not exist in Cocotron. Unrecognized selector, process
   ends. Patch `cocotron/0033`.
3. `O2Surface` did not handle `kO2ImageAlphaNoneSkipFirst` with `kO2BitmapByteOrder32Big`, which
   LibreOffice asks for; it fell through to the DEFAULT writer, which is a silent wrong result
   rather than a failure. Patch `cocotron/0034`.

Past them Writer draws toolbars with icons, the ruler, paragraph and font controls, a white page,
the sidebar, and a status bar with page, word count, language and zoom.

### The instruments, which is why those were findable

`CIDER_WAYLAND_DUMP=<dir>` writes each window as a BMP from the same pages the compositor reads.
`weston-screenshooter` captures the composited result. The two disagreeing is a format, stride or
alpha bug and nothing else separates those. BOTH need care: the dump path is a GUEST path, so a
host directory silently writes nothing, and weston refuses a screenshot without `--debug`, failing
as a BLACK IMAGE rather than an error. A black screenshot here means the capture failed.

`present`/`flush` counters separate an application that draws nonsense from one that draws
correctly and never commits again. The event wait is capped (`MAX_EVENT_WAIT`) because
NSApplication redisplays BETWEEN events, so an unbounded wait means the first frame is the only
frame.

`tests/buck2/gui/color_probe.m` runs the exact pair `libvclplug_osxlo` sends
(`colorUsingColorSpaceName:device:` then `getRed:green:blue:alpha:`) and shows the colour path is
CLEAN. `tests/buck2/gui/runloop_probe.m` shows `runMode:beforeDate:` honours its date. Both are
negative results that each killed a leading theory.

### Still wrong, and stated plainly

- PARTS OF THE CHROME SHOW UNINITIALISED PIXELS. The values change between runs. Neither O2 span
  writer produces them (traced), HITheme is never called (traced with `STUB_VERBOSE`), and the
  colour table is not the source (proved by giving every name a unique loud colour and seeing NONE
  of them appear on screen). Unresolved.
- NO INPUT AT ALL. `wl_seat` is detected in the registry and never bound. `libxkbcommon` already
  exists as a native forwarding stub, so the keymap side has a library to build on.
- RESIZE IS GATED OFF behind `CIDER_WAYLAND_NOTIFY_RESIZE`. Delivering the configure from inside
  the Wayland callback re-enters AppKit; it needs deferring to the main loop.
- Every killed run leaves a crash flag, so the next start spends itself in a modal recovery dialog.
  The runner clears it; a bare run needs `-norestore`.

## Input works, verified by injection rather than by hand, 2026-08-14

    INPUT_PROBE totals mouseDown=1 mouseUp=1 moved=2 keyDown=5 keyUp=5 flags=2
    INPUT_PROBE typed=hello
    INPUT_PROBE VERDICT mouse=WORKS keyboard=WORKS

Pointer motion, a button press and release, and five keystrokes that arrived as the characters
h e l l o, resolved through the compositor keymap with libxkbcommon.

### The harness is the hard part, and it is worth writing down

weston headless advertises a seat with NO capabilities, so input cannot be tested against it even
in principle. sway on the wlroots HEADLESS backend has a seat but no devices, and the tools that
create virtual ones (wlrctl, wtype) hold the device only while they run. That is a few
milliseconds, which is far too short for a client to see the capabilities event, ask for a pointer
and be handed one. Measured rather than assumed: the pointer attached 120 TIMES and received not
one event.

What works is sway NESTED in the user session (WLR_BACKENDS=wayland). The wayland backend forwards
real, persistent devices, so the capability is stable and an injected event is delivered like any
other. Injection goes to the nested compositor, so nothing reaches whatever the user had focused.
See scratchpad/run-input-nested.sh.

### The bug this found

connect() built its xdg_wm_base and registry listeners as LOCALS. libwayland keeps the pointer and
does not copy the struct, so both dangled the moment connect() returned. weston never sends
xdg_wm_base.ping, so this was invisible; sway pings as soon as a surface exists and the client
jumped into reused stack memory, exiting with code 1 and no output at all.

## Typing works in an AppKit application, and not yet in LibreOffice, 2026-08-14

    INPUT_PROBE typed=hello
    INPUT_PROBE field-contains=hello
    INPUT_PROBE VERDICT mouse=WORKS keyboard=WORKS

A real NSTextField received the keystrokes and CONTAINS the text. That is the whole chain:
compositor key event, xkb keymap, NSEvent, key window, first responder, interpretKeyEvents:,
insertText:, and a control that changed. Receiving an event and inserting a character are
different claims and only the second is what typing means.

### LibreOffice receives the same events and does nothing with them

Traced at the last point this backend can observe, which is what -nextEventMatchingMask: hands
back: 10 NSKeyDown, 10 NSKeyUp, a mouse down and up, and 24 flags-changed events, all delivered.
A screenshot before the click and one after the typing differ by ZERO PIXELS.

So the input path is not the gap. Something inside LibreOffice does not act on events it is given,
and that is where the next work is.

WATCH OUT FOR THIS WHEN TRACING IT. LibreOffice SUBCLASSES NSApplication as VCL_NSApplication and
overrides -sendEvent:, so a trace inside Cocotron NSApplication proves NOTHING about whether the
application received an event. Two hours went into a trace that could not fire. Trace at the
backend boundary instead, where CIDER_TRACE_KEYS now prints every event handed to the application.

### The other lesson, which cost more than it should have

The exception tracer prints lines beginning "cider: RAISE" and "cider: UNRECOGNIZED". Grepping for
anything else finds nothing and reads as "no exceptions were raised". The first click anywhere in
LibreOffice had been dying on -[NSEvent_mouse copyWithZone:] the whole time it was reported as
silent.
