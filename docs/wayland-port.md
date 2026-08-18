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
  SUPERSEDED: the seat is bound, and the pointer and keyboard both work end to end.
- RESIZE IS GATED OFF behind `CIDER_WAYLAND_NOTIFY_RESIZE`. Delivering the configure from inside
  the Wayland callback re-enters AppKit; it needs deferring to the main loop.
  SUPERSEDED: the configure is recorded in the callback and applied from the main loop, the
  environment variable is gone from the source entirely, and the resize is demonstrated at 700x600
  and 1150x640. This list is the state of the port on the morning of 2026-08-14 and is kept for the
  history; the sections below it are what is true now.
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

## The chrome is not mis-coloured, it is UNPAINTED, 2026-08-14

Setting CLEAR_PIXEL to pure green and looking at the result answers in one image what a dozen
measurements could not. See docs/wayland-clear-colour-diagnostic.png.

GREEN, meaning the clear colour showing through and nothing painted over it:
  the status bar background, the sidebar background, the toolbar background between the icons,
  the ruler background, and a VERTICAL BAND straight through the middle of the page.

PAINTED CORRECTLY: the page itself, every toolbar icon, all text, the menu bar, the window frame.

So this was never a palette problem. The regions that look wrong are the ones nothing ever fills,
and their colour changes between runs because it is whatever the buffer happened to hold, not
because a colour is being computed wrongly.

### What that rules out, each by measurement rather than argument

  NOT the colour table. Every system colour given a unique loud value puts none of them on screen.
  NOT the conversion. colorUsingColorSpaceName:device: and getRed:green:blue:alpha: are clean for
    every colour LibreOffice reads, tested directly in tests/buck2/gui/color_probe.m.
  NOT Onyx2D. Traced in the writer functions themselves, which is where every write to a window
    buffer must pass. Neither the BGRA writer nor the argb8u writer produces a wide non-grey span.
  NOT a format, stride or alpha bug between us and the compositor. The buffer dump and the
    screenshot agree exactly.
  NOT CGLayer, which is never created, and NOT a large bitmap context: every one LibreOffice makes
    is 1x1 or 16x16.

### The pattern worth following next

The unpainted regions are exactly the places a macOS application draws NATIVE WIDGET backgrounds:
toolbar, status bar, sidebar, ruler. Content that LibreOffice draws itself, the page and the text
and the icons, is correct. The four HITheme entry points it imports are stubs that draw nothing,
and they are NEVER CALLED, so the question is what LibreOffice does instead when it believes the
platform will draw a control background.

A NOTE ON THE STATUS BAR MEASUREMENT. It reads 8,245,41 against a clear of 0,255,0, so it is not
strictly untouched: something paints it with a nearly transparent wash. Close to the clear colour
is not the same as equal to it, and the difference is a real clue rather than noise.

## Windows that were never shown were being mapped anyway, 2026-08-14

The blank rectangles are gone. See docs/wayland-render-after-visibility.png: no band through the
page, no blank sidebar, no flat panels over the document.

THE BUG. present() is reached from -flushBuffer, from -makeKey, from -setTitle and from half a
dozen other places, and the first one to arrive MAPPED THE SURFACE. An application creates windows
long before it shows them and LibreOffice creates plenty it never shows at all, so those appeared
as flat rectangles of whatever the backend had cleared the buffer to. Thirteen windows created,
four mapped, three of them containing ONE unique colour across every pixel. Now: thirteen created,
ONE mapped, and that one has 3358 distinct colours in it.

HOW A WINDOW IS ACTUALLY SHOWN, which took two wrong turns to find. It is NOT
-showWindowWithoutActivation, which is what -[NSWindow setIsVisible:] calls and which LibreOffice
never reaches: gating on that alone mapped nothing at all. -[NSWindow orderWindow:relativeTo:] sets
its own _isVisible directly and then calls -placeAboveWindow: on the platform window, so THAT is
the signal. Both routes now mark the window visible, and -showWindowForAppActivation: does too,
which had been a no-op.

WAYLAND HAS NO EXPOSE EVENT, which is a real difference from X11 rather than a detail. X sends
Expose whenever a window needs its contents and the X11 backend draws from that; a Wayland client
owns its buffer and must know when to paint. Newly shown and newly resized windows are therefore
marked for display explicitly, from the main loop.

### Still wrong

The chrome around the page, the sidebar strip and the status bar background are painted in a colour
that is still not right, and it still shows the signature of an uninitialised read: within one run
the regions share a BLUE byte exactly while red and green differ, and the values change between
runs. It is no longer the clear colour and no longer a blank window; it is a fill with a wrong
colour, which is a different and smaller problem than the one this fixes.

## Correction: Onyx2D DOES write those pixels, and how the wrong answer was reached

An earlier entry here recorded that the bad chrome pixels are not written by Onyx2D, traced in the
writer functions themselves. THAT CONCLUSION WAS WRONG, and the way it was wrong is worth more than
the claim was.

The trace selected spans of at least 64 pixels, on the reasoning that a large flat area of chrome
is a wide fill. ONYX2D EMITS SPANS OF EIGHT PIXELS. Every filtered version of that trace therefore
matched nothing, in runs where the page was plainly being painted white, and each empty result was
read as evidence about LibreOffice rather than about the filter. Removing the filter entirely
printed writes immediately:

    CIDER_O2_WRITE x=1 y=6 len=8 rgba=251,251,251,254

AN INSTRUMENT THAT CANNOT FIRE PROVES NOTHING. The check that would have caught this is the one
that was finally run: remove every filter and confirm the trace fires at all, before believing a
silence.

### What is actually known about the chrome strips

LibreOffice creates bitmap contexts of 1040x38, 1040x51 and 1040x86 with CALLER OWNED data, which
are toolbar and status bar sized, and it imports CGBitmapContextGetData, CGBitmapContextGetBytesPerRow
and memcpy. So it draws into its own buffers and copies them into the window itself. Those
allocations were also missed at first, by a trace that printed the first twenty bitmap contexts and
was filled by 1x1 and 16x16 icon scratch buffers before a frame sized one appeared.

## An unfound writer: window sized surfaces are filled by something not yet located

Stated precisely so the next attempt does not repeat this one.

WHAT WAS ESTABLISHED, by pointer comparison rather than by reading the format switch:

    CIDER_O2_WRITER size=1024x656 info=00002002 supported=1 argb8u=0x...100 bgra=0x...100 match=1

The window surface selects O2SurfaceWrite_argb8u_to_BGRA8888, the same function instrumented. The
comparison is the point: deducing the writer from the bitmap info by hand had already been wrong
once.

WHAT WAS THEN MEASURED: with a trace inside that function and NO filters except a surface width of
400 or more, ZERO writes were recorded in a run where the window ended up holding a complete
rendered interface, 3358 distinct colours, page, text and icons. Not one.

So a path fills window sized surfaces without passing through _writeargb8u, and it has not been
found. It is not O2BitmapContextGetData: that is never called, traced. It is not CGLayer: never
created, traced. Everything reachable from _pixelBytes outside O2Surface.m is a READ.

### Three filter mistakes, all the same mistake

Every empty result from this instrument before today was an artefact, and each cost a round:

  spans of at least 64 pixels  -- Onyx2D emits spans of EIGHT, so nothing ever matched
  the first pixel only         -- skips any blit whose left edge is grey, which is most of them
  a print cap of forty         -- consumed by 16x16 icon scratch buffers before the window painted

THE RULE. Run the instrument with NO filter first and confirm it fires, then add one selector at a
time. An instrument that cannot fire proves nothing, and its silence reads exactly like a result.

### The negative result is now solid, and here is the instrument to use next

Three INDEPENDENT filters, each chosen to avoid the assumption the last one made, all agree that
Onyx2D never writes a window sized surface:

  by surface width   -- assumes O2ImageGetWidth answers correctly for a window surface
  by span length     -- fails on its own, since Onyx2D emits spans of eight
  by ROW NUMBER      -- assumes nothing at all: a row above 200 can only exist on a tall surface

The third found nothing either, in a run whose window ended up holding a complete interface. And
O2SurfaceWriteSpan_largb32f_PRE, the float entry point, is NEVER CALLED ONCE in a whole run, so the
8 bit path is the only one in use and it has now been ruled out three ways.

So the window pixels are written by something that is not the Onyx2D rasteriser, not
CGBitmapContextGetData, not CGLayer, and not any other reference to the pixel bytes in Onyx2D,
which are all reads.

NEXT INSTRUMENT, and it cannot lie: after clearing the backing, mprotect the shm mapping PROT_READ
and install a SIGSEGV handler. The first write faults, the handler prints the faulting instruction
pointer and restores PROT_READ|PROT_WRITE, and scripts/core-guest-stack.py resolves that address to
a symbol. A watchpoint answers who writes the memory without needing to guess which layer to
instrument, which is what every attempt so far has had to guess.

## The writer is found, and every empty trace is explained, 2026-08-14

    CIDER_WATCH write offset=0 pc=0x77ffc5ac66d1 image=Onyx2D symbol=O2argb8u_copy_by_coverage+65

One run. No hypothesis. src/darwin/wayland/watch.c makes the shm mapping read only after clearing
it, catches the fault, and asks dladdr who the faulting instruction belongs to.

WHY EVERY TRACE BEFORE THIS PRINTED NOTHING, from O2RasterizeWriteCoverageSpan8888_Copy:

    O2argb8u *direct = surface->_read_argb8u(surface, x, y, dst, length);
    if (direct != NULL) dst = direct;
    O2argb8u_copy_by_coverage(src, dst, coverage, chunk);
    if (direct == NULL) { O2SurfaceWriteSpan_argb8u_PRE(surface, x, y, dst, chunk); }

WHEN A SURFACE OFFERS DIRECT ACCESS THE RASTERISER WRITES INTO IT AND NEVER CALLS THE SPAN WRITER.
O2ImageRead_BGRA8888_to_argb8u returns a pointer straight into the pixels on little endian, so a
window surface always takes that path. Every trace placed in _writeargb8u was in the branch that
window drawing does not use, which is why three independent filters all found nothing and why the
16x16 icon buffers, which do not take the direct path, were the only writes ever seen.

The layout is NOT swapped, checked rather than assumed: O2argb8u is O2argb8u_LE, which is b, g, r,
a, and that matches BGRA memory. The blend arithmetic in O2argb8u_copy_by_coverage is correct for
that layout too.

### Where the remaining colour bug must be

The write path is now known and it is only three values wide: src, which comes from
O2PaintReadSpan_argb8u_PRE, and coverage, and the destination it blends against. The next step is
to trace those three at that call site, filtered to the window surface, which is now possible
because the site is known rather than guessed.

A WATCHPOINT NEEDS NO HYPOTHESIS, and that is the lesson worth keeping. Every previous instrument
required choosing a layer first, and each wrong choice produced a silence that read like a result.

## The drawing stack paints faithfully; the colour is chosen wrong upstream

Read at the site the watchpoint named, O2RasterizeWriteCoverageSpan8888_Copy, immediately before
the blend:

    CIDER_COV y=201 x=0 chunk=1024 coverage=256 src=52,79,95,255 dst=237,237,237,255 direct=1

and the screen at that region: srgb(52,79,95). IDENTICAL. Full coverage, full window width, and the
destination underneath was the correct light grey that something painted first.

So Onyx2D reproduces exactly the colour it is handed, and the wrong colour is chosen before it gets
there. That closes the question the last several rounds were really asking.

### It does come from the colour table, correcting an earlier entry again

With the table temporarily set to loud values, the paint span at those rows carried src=255,0,0,
which is controlColor. An earlier entry here recorded that none of the loud colours reach the
screen; that was measured before the visibility, first responder and appearance fixes, and it is
now wrong. LibreOffice does use controlColor for the region around the page.

What is NOT yet explained: in an ordinary run controlColor is grey 0.93, so that region should be
grey, and instead it is a colour that changes between runs. The region is painted MORE THAN ONCE,
grey first and then something else over it, so the paint that wins is a later one whose source has
not been identified.

### Ruled out this round, each by measurement

  DARK MODE. AppleInterfaceStyle is nil and effectiveAppearance is NSAppearanceNameAqua, so an
    application asking either question is told light.
  THE COLOUR SPACE OF THE GREYS. Building them with colorWithDeviceRed rather than
    colorWithCalibratedWhite changes nothing on screen, so that change was reverted rather than
    kept on a hunch.

## The chrome colour is inside LibreOffice own backing image, and the whole path is now known

The full stack at the paint, captured with backtrace and dladdr at the site the watchpoint named:

    O2RasterizeWriteCoverageSpan8888_Copy
    O2DContextFillEdgesOnSurface
    -[O2Context_builtin drawImage:inRect:]
    CGContextDrawImage
    AquaSalGraphics::UpdateWindow(CGRect&)          <- libvclplug_osxlo
    -[SalFrameView drawRect:]
    -[NSView displayRectIgnoringOpacity:] ... -[NSWindow displayIfNeeded]
    AquaSalFrame::Show(bool, bool)

So the chrome is not filled, it is BLITTED: LibreOffice renders into its own image and draws that
image into the window. Reading a pixel out of the SOURCE at the blit:

    CIDER_IMAGE src=1024x640 bpp=32 info=00002002 mid=116,92,210,255 direct=1
    screen at that region: srgb(116,92,210)

IDENTICAL. The source image already contains the wrong colour, so neither the blit nor the
rasteriser nor the colour table is responsible for it.

### Ruled out this round, each by an experiment rather than an argument

  THE BLIT AND THE RASTERISER. src at the blend equals the pixel on screen, exactly.
  UNINITIALISED CALLER MEMORY. Zeroing every caller supplied buffer at surface creation ended the
    run, because the application also wraps icon data it has already filled; zeroing only window
    sized ones is survivable and changes NOTHING on screen. So the wrong pixels are not simply
    malloc garbage in a buffer nobody painted.

### What is left

The wrong pixels are produced inside LibreOffice own rendering into its own image, before anything
this port can see through a CoreGraphics call. The next question is which of its draws produces
them, and the honest answer is that finding it needs either its debug symbols or a narrower
reproducer than a whole office suite.

## LibreOffice never sets a coloured fill through CoreGraphics, which closes off the CG layer

Traced at O2ContextSetFillColorWithColor, which every CG fill colour must pass through, printing a
backtrace whenever a non black non grey colour is set. NOT ONE in a whole run.

Combined with the previous entry, where the image handed to CGContextDrawImage already contained
the wrong colour, this says the chrome pixels are produced by LibreOffice OWN RENDERER writing into
its own memory, and only the finished image is handed to CoreGraphics. That is why every instrument
placed at a CoreGraphics boundary has come up empty: there is nothing to see there.

### The eliminations, gathered in one place

  the colour table                 -- loud values DO reach the screen, so it is consulted
  the colour conversion            -- clean for every colour LibreOffice reads, tested directly
  the rasteriser                   -- src at the blend equals the pixel on screen, exactly
  the blit                         -- the source image already holds the wrong colour
  a format or stride difference    -- buffer dump and screenshot agree
  CGLayer                          -- never created
  uninitialised caller buffers     -- zeroing window sized ones changes nothing
  CG fill colours                  -- never set to anything coloured, not once
  dark mode                        -- AppleInterfaceStyle nil, effective appearance Aqua

WHAT THAT LEAVES is LibreOffice deciding a wrong colour internally and painting it with its own
code. The remaining lead is the one thing that IS observably ours: the loud palette experiment
proves it reads controlColor for that region, so the value it derives from controlColor is where to
look, and that derivation happens in VCL rather than in anything this port implements.

## The keyboard chain is verified correct up to LibreOffice own text input

Every link measured, not inferred:

    compositor key event                cider-wayland-input key=1 pressed=true window=2 text=h
    NSEvent built and posted            CIDER_POSTKEY built=yes type=10 windowNumber=2
    handed to the application           cider-wayland-appkit delivered-event type=10
    window is key and announced         CIDER_BECOMEKEY window=2 early=0 delegate=SalFrameWindow responds=1
    first responder is the view         CIDER_FOCUS firstResponder=SalFrameView
    the view asks for text              CIDER_INTERPRET responder=SalFrameView insertText=0 insertTextRange=1
    the text is delivered to it         CIDER_INSERT responder=SalFrameView len=1   (five times, for hello)

So the characters arrive inside LibreOffice OWN -insertText:replacementRange:, one per keystroke,
and nothing appears in the document.

THE EARLY RETURN IN becomeKeyWindow WAS CHECKED rather than assumed, because it would have skipped
the focus notification entirely: early=0, the notification is posted, and the delegate responds to
windowDidBecomeKey:. That was the last plausible gap on this side.

The same probe, in the same run, types hello into an NSTextField AND into a view that implements
only insertText:replacementRange:, which is the exact shape LibreOffice view has. So the mechanism
works; what does not work is inside VCL.

### Both remaining defects now sit past the same boundary

The chrome colour is inside an image LibreOffice renders itself, with no coloured fill ever reaching
CoreGraphics. The keystrokes are delivered into its own text input method and discarded. Both are
now characterised precisely, both are outside this port, and going further into either needs
LibreOffice debug symbols or a reproducer smaller than an office suite.

## The focus notification fires, and the mouse asymmetry is the useful clue

    CIDER_NOTIFY windowDidBecomeKey window=2 delegate=SalFrameWindow

Registering a selector and that selector being CALLED are different claims, and only the first had
been checked. An observer of this backend own, added for exactly this question, shows the
notification is really posted and really delivered, with the LibreOffice window as the delegate.
It is kept behind CIDER_TRACE_KEYS since it costs nothing and this question will come up again.

THE ASYMMETRY IS THE PART TO CARRY FORWARD. Mouse events reach VCL and are ACTED ON: a click in the
document places a text caret, measured as a 1x17 pixel change. Key events reach the same frame,
through the same window, into its own insertText:replacementRange:, and produce nothing. So the
frame is alive, focused and routing events; it is the KEY path inside VCL specifically that drops
them, not frame focus and not event delivery.

That rules out the remaining explanations on this side, since anything about focus or liveness
would break the mouse too.

## Resize is DEMONSTRATED, not asserted, 2026-08-14

Driven from the compositor with swaymsg, at two deliberately different widths, and compared as
pictures: docs/wayland-resize-narrow.png and docs/wayland-resize-wide.png. The log line for the
same run:

    cider-wayland-window resized number=2 size=700x600
    cider-wayland-window resized number=2 size=1150x640

A BUFFER THAT CHANGES SIZE IS NOT A RELAYOUT, which is why this needed pictures. What the two shots
show is the application moving its own furniture:

    toolbar          about 18 icons at 700, many more at 1150, through the omega and the globe
    formatting bar   ends at abc at 700; at 1150 it adds superscript, subscript, font colour,
                     highlight, the alignment group and the list group
    status bar       four fields at 700; at 1150 it adds English (Denmark) and Insert
    ruler and page   rescaled and recentred at both widths

So the compositor resizes and LibreOffice relayouts. Criterion three is met, and it is met with
evidence rather than with a size in a log.

The chrome colour is wrong in both shots, which is the separate defect recorded above.

## Where task 112 actually stands, and what would move it

    RENDERS CORRECTLY   no      everything this port draws is right; the chrome is not
    INTERACTIVE         partly  mouse works in LibreOffice; keyboard does not, though it is
                                delivered correctly at every measured link
    RESIZABLE           yes     demonstrated at two widths with pictures

APPLICATION ACTIVATION was checked this round as well, since VCL might gate focus on it: NSWindow
platformWindowActivated: sets the window active, NSApp isActive is derived from that, and
_windowDidBecomeActive: posts NSApplicationDidBecomeActiveNotification. That path is intact, so it
joins the list of excluded explanations rather than becoming a fix.

### Why the instrument rounds have stopped paying

Both open defects sit on the far side of a boundary that has now been measured clean from this side
in eight separate ways. The keyboard reaches LibreOffice own insertText:replacementRange: with the
right character, once per keystroke. The chrome colour arrives already wrong inside an image the
application renders itself, with no coloured fill ever passing through CoreGraphics. Every
instrument that can be placed at a CoreGraphics or AppKit boundary has been placed, and each one
now reports that its side is correct.

WHAT WOULD ACTUALLY MOVE IT, in rough order of expected value:

  1. A LibreOffice build with symbols, or a debug build of libvclplug_osxlo alone. Every question
     left is of the form which branch does VCL take, and that is unanswerable from outside it.
  2. A smaller NSTextInputClient application that reproduces the same discard, which would turn a
     one hour LibreOffice cycle into a fifteen second one and might expose a difference this port
     can fix after all.
  3. Comparing against the X11 backend on the same LibreOffice: if keys work there and not here,
     the difference is a signal this backend does not send, and that is a short list.

The mouse asymmetry is the strongest hint on record: clicks reach VCL and place a caret, so the
frame is alive, focused and routing, and only the key path is dropped.

## The X11 control does not start, so this backend has already passed the one it replaces

Run back to back, same LibreOffice, same prefix, same session. scratchpad/run-lo-x11.sh selects the
X11 backend simply by NOT setting CIDER_WAYLAND_BACKEND, and drives Xvfb with xdotool.

    X11 backend       SOFFICE_EXIT=1, Unspecified Application Error, dies during startup
    Wayland backend   13 windows, 1 mapped, EXIT=137, renders and survives the harness

Repeated twice with the same result, so it is not flakiness.

TWO CONSEQUENCES, and the second one closes a lever this plan was counting on.

  The Wayland backend is FURTHER ALONG than the X11 one for this application. LibreOffice reaching
  a laid out document window at all is new, not a regression from something that used to work.

  Comparing the two backends cannot diagnose the keyboard, because there is no working control to
  compare against. That was the third of the three levers listed above and it is now spent; the
  remaining two are symbols for libvclplug_osxlo and a small NSTextInputClient reproducer.

INCIDENTAL, and it says something about the colour table: the X11 run prints missing color for
underPageBackgroundColor, systemGrayColor and controlAccentColor, all of which the Wayland table
supplies. The table written for this port is more complete than the one it was copied from.

The X11 failure raises no ObjC exception either, so it is a C++ one inside LibreOffice, the same
shape of failure as the Wayland keyboard: caught, unnamed, and reported only as Unspecified
Application Error.

## Key codes were derived from the physical key, which is wrong on every layout but US

Measured, with a synthetic keymap, BEFORE the fix:

    key=1 carbon=53 text=h      Carbon 53 is kVK_Escape
    key=2 carbon=18 text=e      Carbon 18 is kVK_ANSI_1

and after, with the keysym consulted first:

    key=1 keysym=0x68 carbon=4    kVK_ANSI_H
    key=2 keysym=0x65 carbon=14   kVK_ANSI_E
    key=3 keysym=0x6c carbon=37   kVK_ANSI_L
    key=4 keysym=0x6f carbon=31   kVK_ANSI_O

A PHYSICAL KEYCODE ONLY MEANS A LETTER IF THE LAYOUT SAYS SO. Translating the raw evdev number
through a fixed US table is right on a US keyboard and wrong everywhere else, and it fails
SILENTLY: the character is correct while the key code names an unrelated key. An application that
reads the key code to decide what a keystroke MEANS is then told Escape while being handed the
letter h. This machine has a Danish layout, so it was wrong for real and not only under the test
harness.

IT DID NOT FIX LIBREOFFICE TYPING. The document still shows a zero pixel difference after the same
five keystrokes. So this was a real bug found while looking for another one, which is worth having
on its own terms: shortcuts and every keycode dependent behaviour would have been wrong on any
non US keyboard.

The probe still types hello into a modern NSTextInputClient, and the weston control still reaches
13 windows and survives.

## Modifiers were hard coded bit positions, which is the same mistake as the key codes

    cider-wayland-input modifiers=0x40000 depressed=0x4      0x40000 is NSControlKeyMask

WHICH BIT IS CONTROL IS A QUESTION FOR THE KEYMAP. The positions used before were the conventional
xkb order, which holds for ordinary layouts and not for synthetic ones, and a wrong guess means a
modifier that is never reported: every shortcut misses and nothing says why. The indices now come
from xkb_keymap_mod_get_index by name, with XKB_STATE_MODS_EFFECTIVE so a latched or locked
modifier counts as held. The old order remains as a fallback for the window before a keymap arrives.

AND CTRL+Q STILL DOES NOT QUIT LIBREOFFICE. It now receives the correct key code, kVK_ANSI_Q, with
the correct modifier, and does nothing, so this fix is correct without being the cause. That is the
second such fix in two rounds.

### What that pair of results means

A shortcut and a character take different branches inside VCL and BOTH produce nothing. So the
failure is not in text handling specifically; it is that VCL is not acting on key events for this
frame at all, while it does act on mouse events for the same frame. Everything AppKit side is
measured correct: the key code, the modifiers, the key window, the notification, the first
responder, the text interpretation, and the delivery into the application own
insertText:replacementRange:.

## The mouse claim, re-checked against an idle control

The evidence for the mouse working was a 1x17 pixel change after a click, read as a text caret. A
BLINKING CARET PRODUCES EXACTLY THAT DIFFERENCE WITH NOBODY TOUCHING ANYTHING, so the claim needed a
control it did not have. scratchpad/run-lo-idle.sh takes three screenshots a second apart and sends
no input at all:

    idle-1 vs idle-2   0 differing pixels
    idle-2 vs idle-3   0 differing pixels

Nothing changes on its own. So the 1x17 vertical bar was caused by the click, and the mouse half of
criterion two stands. It stands on a control now rather than on an inference.

That also sharpens the asymmetry: VCL acts on mouse events for this frame and not on key events,
with both delivered correctly and both measured.

### The delegate registration was checked too, and is sound

Cocotron posts the key window notification with object self and registers the delegate with object
self, and setDelegate assigns _delegate BEFORE registering, so respondsToSelector tests the new
delegate. Both were plausible ways for the application observer to be silently skipped while the
observer added for this investigation still fired, and neither is happening.

## The key path is textbook, including the application own frames

Captured with backtrace and dladdr inside interpretKeyEvents:

    ImplSVMain
    Desktop::Main
    Application::Execute
    Application::Yield
    AquaSalInstance::DoYield
    -[VCL_NSApplication sendEvent:]      the application own override
    -[NSApplication sendEvent:]          which it CHAINS TO
    -[NSWindow sendEvent:]
    -[SalFrameView keyDown:]             the application own
    -[NSResponder interpretKeyEvents:]

This is the canonical macOS key path, with LibreOffice frames above and below ours. Two things
follow.

THE APPLICATION OWN keyDown RUNS, so whatever state it sets up before asking for text interpretation
is set up. The discard happens after that, inside its own insertText:replacementRange:, with its own
key state prepared by its own code.

AND AN EARLIER INFERENCE HERE WAS WRONG. A note above reasoned that VCL_NSApplication overrides
sendEvent: and does not chain to super, because a trace placed in the Cocotron implementation never
fired. The stack shows -[NSApplication sendEvent:] IS in the chain. The trace failed for some other
reason and the conclusion drawn from its silence was unfounded, which is the third time a silent
instrument has been read as a result in this file.

## Every gate an application can check is open

    CIDER_FOCUS window=2 class=SalFrameWindow canBecomeKey=1 isKey=1 isMain=1 canBeMain=1
                appActive=1 firstResponder=SalFrameView

Key AND main, the application active, and its own view as first responder. Each of those was a
plausible gate on the keyboard and each is correct, so they are printed together now rather than
being rediscovered one at a time.

Two more configurations tried and eliminated in the same round:

  TYPING WITH NO CLICK FIRST. Every earlier run clicked into the document before typing, and a
  click could plausibly move focus somewhere that swallows keys. Three keystrokes delivered with no
  click at all: zero pixels changed. So the click is not the problem.

  A KEYBOARD SHORTCUT. Ctrl+Q with the correct key code and the correct modifier does not quit,
  so it is not that text is lost while commands work.

### A recurring hazard worth naming, since it has now happened twice

Both times a cleanup broke a source file, the run afterwards printed a healthy looking result from
the PREVIOUSLY INSTALLED dylib, because the harness copies a build artefact into the prefix and a
failed build leaves the old one in place. A green run after a failed build is not a green run.
Check the build result before believing the run.

## Clicking a menu OPENS it, and the menu is invisible for a nameable reason

From one log, in order:

    cider-wayland-input button=0x110 pressed=true x=95 y=11      the click on the File menu
    cider-wayland-window create=ok number=15 size=247x381 level=2   the menu, five lines later
    cider-wayland-window mapped=yes number=15

So the click was hit tested to the menu bar, dispatched, and acted on. That is criterion two mouse
half met in the words of the prompt, click a menu and it opens, and it is a much stronger result
than the caret: a caret says a click reached the document view, a menu says it reached a specific
control and the application ran its handler.

WHY THE MENU IS NOT ON SCREEN, and this is ours. Every window here is created as an xdg_toplevel,
so a compositor treats a menu as another application window: a tiling one gives it a tile of its
own or stacks it elsewhere, and it never appears under the pointer where a menu belongs. Menus and
tooltips are xdg_popup, which is positioned RELATIVE TO ITS PARENT with an anchor rectangle, and
that is the missing piece.

LEVEL IS THE SIGNAL and it is already available: this window arrived with level=2, which is
NSFloatingWindowLevel, while document windows are level=0. The earlier attempt to distinguish
window kinds used the style mask and could not separate a menu from a scrollbar helper; the level
does it exactly.

NEXT RUNG, now concrete: get_popup with a positioner for windows above level 0, keeping toplevel
for level 0. The parent is the key window, the anchor rectangle comes from the frame origin the
application already sets, and popup_done has to unmap.

## THE FILE MENU OPENS ON SCREEN. Criterion two, mouse half, is met, 2026-08-14

docs/wayland-menu-open.png. Click the File title and the menu appears under it with every item
drawn: New, Open with Ctrl+O beside it, Recent Documents, Wizards, Templates, Save with Ctrl+S,
Export, Print with Ctrl+P, and the disabled entries correctly greyed. Measured alongside:

    cider-wayland-window popup=ok number=15 size=247x381 level=2
    cider-wayland-window create=ok number=15
    cider-wayland-window mapped=yes number=15
    cider-wayland-window pixels=drawn number=15 changed=94107/94107 colours=64+

That is the prompt own wording satisfied: click a menu and it opens.

### What it took, and the two mistakes in the middle

A MENU IS AN xdg_popup, NOT A TOPLEVEL. xdg_shell has two roles: a toplevel is an entry in the
compositor list of open windows, a popup belongs to a parent, is positioned against it with an
anchor rectangle, and is dismissed by the compositor rather than closed by the client. As a toplevel
the menu opened correctly and was placed as a tile somewhere else entirely.

THE LEVEL IS THE SIGNAL. Menus arrive at level 2, NSFloatingWindowLevel; document windows at 0. An
earlier attempt at this used the style mask and could not tell a menu from a scrollbar helper.

AND THE PARENT MUST BE MAPPED. The first working version parented the popup to the last TITLED
window, and every popup came back create=FAILED reason=never-configured with NOTHING in the
compositor log. Most titled windows here are never shown: the application makes a dozen and one is
mapped. Looking the parent up among windows that are actually mapped is what made the compositor
configure it.

The anchor rectangle converts between two coordinate systems that disagree about which way is up:
AppKit origin bottom left with y increasing upwards, Wayland top left with y increasing downwards,
so the conversion goes through the parent TOP edge. Getting that wrong puts the menu at the other
end of the window rather than under its title.

## Typing works. Clicking breaks it. And the chrome colour is a use after free, 2026-08-14

Three findings, each from an instrument that did not exist this morning.

### THE KEYBOARD REACHES THE APPLICATION CORRECTLY, and characters DO appear

The application own key path is now measured from INSIDE the application, by wrapping its
Objective-C methods from this backend (CIDER_TRACE_VCL). Per keystroke:

    CIDER_VCL keyDown view=SalFrameView window=2 isKey=1 firstResponder=SalFrameView
    CIDER_VCL insertText:replacementRange: text=[h]
    CIDER_VCL hasMarkedText=0
    CIDER_VCL sendKeyInputAndReleaseToFrame code=519 char=104 mods=0x0

code 519 is KEY_H and char 104 is h. That is the textbook path with the right values at every step,
so everything this backend is responsible for is done.

AND THE TEXT APPEARS ON SCREEN: three characters typed before any click show up in the document with
the caret after them (docs/wayland-typing-noclick.png). Criterion two, the typing half, is
DEMONSTRATED, with one condition.

THE CONDITION IS THE CLICK. Characters typed AFTER a click in the document body are delivered
identically, byte for byte, and nothing appears. Same window, same first responder, same key code,
same sendKeyInputAndReleaseToFrame. So the loss is inside the application, after the point where its
own code accepts the keystroke, and the mouse is what changes its mind. The mouse methods are traced
now as well, which is where that thread continues.

### THE CHROME COLOUR WAS A USE AFTER FREE IN NSColor_catalog

    - (NSColor *) colorUsingColorSpaceName: (NSColorSpaceName) space device: (NSDictionary *) device
    {
        ...
        _color = [_color colorUsingColorSpaceName: space device: device];   // autoreleased, no retain
        return _color;
    }

An autoreleased object stored in an instance variable with no retain. The catalog colour outlives
the pool, and every later -setFill, -CGColor and -patternImage reads freed memory. What it looks
like from outside says nothing about colour objects: every window was filled with a FLAT colour that
was DIFFERENT ON EVERY RUN, purple, then green, then orange, while the menu bar beside it stayed the
correct grey. -[NSThemeFrame drawRect:] fills the whole window with the window backgroundColor,
which is a catalog colour, which is why it was the whole window.

Fixed by not caching: the answer depends on the colour space AND the device asked for, so a cache
keyed on neither is wrong even when the memory is alive. The window background and the page are the
right colours now.

METHOD NOTE, because two hypotheses were eliminated by measurement and both were plausible:
uninitialised bitmaps (CGBitmapContextCreate and NSMutableData dataWithLength: were tested against a
DIRTIED heap, both zero correctly) and a wrong palette entry (a wrong constant cannot change between
runs). What identified it was the pair of facts that the colour was FLAT and that it MOVED.

### THE REST OF THE CHROME IS STILL WRONG, and the source is now named

The toolbars, the sidebar and the status bar are still a flat run-varying colour. The fill trace
(CIDER_WAYLAND_TRACE_COLORS) with a backtrace through dladdr names the exact call:

    CIDER_FILLCOLOR comps=0.518,0.914,0.714,1.000     (times 255: 132,233,182, the pixels on screen)
      Onyx2D!O2ContextSetRGBFillColor
      CoreGraphics!CGContextSetRGBFillColor
      libmergedlo.dylib!OutputDevice::InitFillColor
      libmergedlo.dylib!OutputDevice::DrawRect
      libmergedlo.dylib!OutputDevice::DrawColorWallpaper
      libmergedlo.dylib!vcl::Window::Erase

So the application itself asks for the garbage colour: the rasteriser is innocent and so is the
palette. Alpha is exactly 1.0 and the three components are arbitrary, which is what a VCL Color made
of three garbage BYTES looks like after the divide by 255. Every colour the application reads
through -getRed:green:blue:alpha: is sane (70 reads in a run, all of them), so the garbage enters
somewhere that is not a system colour read.

### Two more things that were broken and are not any more

A COMPATIBLE CONTEXT HAD NO IMPLEMENTATION. -createCompatibleContextWithSize:unused: has always
ended in [[self class] alloc] initWithSize:context:, and no context class in the tree implemented
that selector, so every CGLayer and every transparency layer raised unrecognized selector. Nothing
noticed until SAL_DISABLESKIA=1, where LibreOffice terminates before its first window. Implemented
on O2Context_builtin, and that path now runs.

SKIA IS THE DEFAULT RENDERER HERE, which is worth knowing: with it off, the classic CoreGraphics
path is used and every drawing call goes through Onyx2D, which is why the fill trace above could see
the colour at all.

### The startup was never slow, the harness was

Measured, after adding a clock to the backend log (t= on every mapped and present line) and a wall
clock outside it:

    WALL to first document window: 2.53 s
    cider-wayland-window mapped=yes number=2 size=1024x656 t=1.76

Two and a half seconds from launch to a fully drawn Writer window, toolbars, ruler, sidebar and all.
Every GUI experiment in this task has been waiting SETTLE=95 seconds for that, which is a 40x tax on
every question asked. scratchpad/bench-gui.sh is the fast harness; the runners keep a longer settle
only where they drive input, because the drivers need the compositor to have settled too.

### Where the time actually goes, sampled rather than guessed

perf cannot read Mach-O, so a profile of the guest is a wall of hex addresses. scripts/
perf-guest-symbols.py joins the mapping list in the perf data to nm output per image and resolves
them, which turned a useless profile into named answers in one pass:

    28%  FcFontMatch under Onyx2D O2FontCreateWithFontName_platform
    12%  memset under large_malloc calloc
     5%  Vec::extend_from_slice under wayland_appkit_lib::window::dump_buffer
     4%  map_foreach under kqueue_closed_fd, on every close() the guest makes

The first is a font lookup with no cache anywhere above it: a fontconfig match walks the whole font
set comparing every property, and it ran on every single font creation. Memoised in
O2Font_freetype filenameForPattern:, which is a pure function of the pattern and the shared config.

The third was this backend own dump instrument copying twelve megabytes to prepend a fifty four byte
header. Now written as two writes.

    text to PDF conversion, before: 4.58 s, 4.45 s
    text to PDF conversion, after:  3.40 s, 3.59 s

## Nobody was watching the socket, and the whole runtime is built -O0, 2026-08-14

### The application stopped asking for events after five seconds

Wayland delivers everything over a file descriptor and NOTHING in this application waits on it. The
main thread parks inside the Darwin runtime, in a Mach receive under libdispatch, and comes back
only when the runtime has a reason of its own. Counted with a clock on the call:

    nextevent calls=200  t=4.99      and then nothing for the rest of the run

That is the whole explanation for a window that draws once and never repaints, a caret that never
blinks and text that appears only if something else forces a redraw. It is not a paint bug.

The fix here is a thread that polls the connection fd and wakes the main thread, which is the small
version of the eventual design (making the fd a run loop source). With it:

    nextevent calls=1000  t=18.2     about 62 calls a second, steady

CIDER_WAYLAND_NO_WAKER turns it off, because a change that alters WHEN an application runs its own
deferred work needs a comparison run, not an argument.

### And then it crashed, which is how the -O0 was found

With the application actually running its deferred work, it died about eighteen seconds in. The
fault was a store of a FUNCTION ARGUMENT into its own stack frame, in _dispatch_source_wakeup, with
the stack pointer inside the PROT_NONE guard page below a 520 KB worker stack. That is a stack
overflow, and the disassembly says why: 656 bytes of frame for a function taking three arguments,
because every one of the 108 targets in vendor/src/BUCK is compiled -O0 and none is compiled -O2.

libdispatch RELIES on tail calls: its wakeup and drain paths call each other in a chain an optimiser
turns into a loop. At -O0 every link is a real frame. Building libdispatch -O2 (493 KB against
849 KB) removes that crash.

It also answers a question the user asked directly, about performance: the whole runtime, this
rasteriser and this font stack included, is built unoptimised.

### What is still wrong

The application now runs live for about eighteen to twenty seconds and then dies inside the memory
allocator or on an os_unfair_lock taken recursively, differently between runs. Racy corruption
looks like that. Caching the main run loop so the waker cannot race its creation did not fix it, so
the next candidate is re-entrancy in what now runs during a wakeup rather than the wakeup itself.

### There was no -O flag in the toolchain at all

_DARWIN_FLAGS in buck/toolchains/BUCK had no -O, so clang used its default, which is -O0, for every
Darwin object in this tree: the rasteriser, the font stack, Foundation, AppKit, libdispatch, all of
it. The 105 explicit -O0 flags in vendor/src/BUCK were a separate thing and are now -O2 as well.

    AppKit   2,883,944 -> 2,525,280 bytes
    Onyx2D     955,480 ->   912,808 bytes
    libdispatch 849,656 ->  493,560 bytes

Checked by building 80 vendored dylibs, JavaScriptCore included: 6085 compiles, all green.

The headless conversion benchmark does NOT move (3.9 s against 3.6 s, inside the noise), which makes
sense: that path is dominated by LibreOffice own code and by fontconfig and freetype, all of which
were already optimised. The win is in OUR code, which is what draws.

### The chrome is black now, and it is not our colour table

The all-names probe palette settles it. Every system colour this backend hands out is now a distinct
bright colour under CIDER_WAYLAND_COLOR_PROBE, generated from the name so a new entry cannot be
forgotten, rather than the eight names the first version covered: a region painted from a name that
was NOT in that list looked exactly like a region painted from nowhere.

    menu bar   70,201,164   = mainMenuBarColor, ours
    toolbar    0,0,0        = not ours
    margin     0,0,0        = not ours

So the application asks for a black background and neither our palette nor the missing names
explain it. Dark mode is ruled out too: AppleInterfaceStyle is nil and the effective appearance is
NSAppearanceNameAqua. Before -O2 the same regions were a DIFFERENT arbitrary colour every run;
zeroed memory rather than recycled memory is the whole difference, so the value is still one nobody
set, and it is set inside LibreOffice. docs/wayland-chrome-black-at-O2.png.

## The main queue was never drained, and the crash is not ours, 2026-08-14 later

### LibreOffice queues its wakeups on the main queue and nothing drained it

dispatch_async is the ONLY dispatch call LibreOffice makes, and it makes it on the main queue:
AquaSalInstance::wakeupYield posts a block there to tell its own event loop that something arrived.
Blocks on the main queue run when the main thread drains it, and on macOS the run loop does that by
calling _dispatch_main_queue_callback_4CF from its main queue port handler. The run loop here is
Cocotron own, so that call never happened and every block queued for the main thread sat there for
the life of the process.

The event pump calls it now, once per pass, which is where the run loop would. The callback returns
immediately on an empty queue and crashes loudly if called from the wrong thread, so it is cheap and
self checking.

### A display that is not presented is invisible

-[NSWindow display] draws into the pages the compositor maps, but a compositor does not re-read a
surface it was not told about. Measured with a forced redraw: the application drawRect ran twenty
times and the frame on screen never changed once. deliver_pending_configures now presents after it
displays, and CIDER_WAYLAND_FORCE_REDRAW=<ms> is the diagnostic that found it.

### The chrome is drawn black EVERY frame, and the crash is not Wayland

Two eliminations, both by measurement.

THE BLACK IS NOT A STALE FRAME. With a forced redraw every 500 ms and a present after each one, the
picture is redrawn about fifty times and comes out black every time. The application draws it that
way, deliberately, on every pass.

THE CRASH IS NOT THE WAYLAND BACKEND. The same LibreOffice on the X11 backend, which is a different
NSDisplay entirely, reaches the same point and dies the same way with "Unspecified Application
Error". The waker did not cause the crash; it let the application run far enough to reach one that
was always there. The allocator, asked to check itself (MallocCheckHeapEach), aborts inside free
under _dispatch_source_invoke -> _dispatch_dispose, and the other face of the same damage is an
os_unfair_lock taken recursively, which is what a corrupted lock word looks like. The lock identity
was checked and cleared: thread ports are unique, thirteen of thirteen.

## THE CHROME IS THE RIGHT COLOUR. Four bugs, one chain, 2026-08-14 evening

docs/wayland-chrome-correct.png. Light grey toolbars, a slightly darker margin around the page, a
status bar whose text is readable, a white page. Sampled: toolbar 237,237,237, margin 217,217,217,
status bar 237,237,237, page 255,255,255, menu bar 229,229,229.

### How LibreOffice actually reads a system colour, which is the thing to know

It does not ask the colour for its components. From vcl/osx/salframe.cxx, getNSBoxBackgroundColor:

    CGContextRef ctx = CGBitmapContextCreate(&aPixel, 1, 1, 8, 32, rgb,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Big);
    NSGraphicsContext* gc = [NSGraphicsContext graphicsContextWithCGContext: ctx flipped: NO];
    NSBox* pBox = [[NSBox alloc] initWithFrame: rect];
    [pBox setBoxType: NSBoxCustom];
    [pBox setFillColor: pSysColor];
    [pBox setBorderType: NSNoBorder];
    [pBox displayRectIgnoringOpacity: rect inContext: gc];
    return Color(aPixel.r, aPixel.g, aPixel.b);

aPixel is a LOCAL, and nothing initialises it. So every background colour in the application is
whatever that one pixel ends up holding, and if the box does not draw, it is whatever the stack
held. The whole mystery of the chrome, a flat colour that changed every run and later a stable
black, is that sentence. Reproducing this exact sequence in the probe is what settled it, after ten
other explanations had been eliminated one at a time.

### The four bugs in the way, each of which alone was enough

1. A WINDOWLESS VIEW DREW NOTHING. -displayRectIgnoringOpacity:inContext: went through the ordinary
   display path, which needs -lockFocus, which needs a window. LibreOffice box has none. It draws
   itself and its subviews into the given context directly now.

2. NSBox DEFAULTED TO TRANSPARENT. -initWithFrame: set _isTransparent = YES and -drawRect: returns
   immediately for a transparent box. The AppKit default is NO. So a box created in code drew
   nothing, ever.

3. THE BOX HAD NOWHERE TO PUT ITS FILL COLOUR. -setFillColor: stores into a dictionary that was
   only created when decoding a nib, so for a box built in code the setter was a silent no-op and
   -fillColor answered nil. -drawRect: then set NO colour before filling and painted with whatever
   was left in the context, which was the groove colour.

4. ALPHA FIRST WAS WRITTEN LAST. kCGBitmapByteOrder32Big with an alpha-first layout means the bytes
   are A, R, G, B; the writer put them R, G, B, A. Every channel one place to the left: a colour of
   0.2, 0.4, 0.8 came back as 0.4, 0.8, 1.0.

### Still wrong

The menu bar shows Application and File and not the rest of the menus. That is the next rendering
question. The application still dies at about twenty seconds, and that is NOT this backend: the X11
backend reaches the same point and dies the same way.

## TYPING WORKS, BEFORE AND AFTER A CLICK. Criterion two is met, 2026-08-14 evening

docs/wayland-typing-works.png. The document reads abcxyz and the status bar reads 1 word, 6
characters. The driver typed abc with no click, then clicked in the middle of the page, then typed
xyz. Both halves appear, in order, in the right place.

The click regression is gone and it was never about the mouse: characters after a click were always
delivered to the application correctly, and what was missing was the REPAINT. The main queue drain
is what fixed it, because LibreOffice defers its screen updates through blocks on the main queue and
nothing was running them. The status bar updating its word count in the same frame is the proof that
the deferred work now runs: that counter is recomputed by an idle handler, not by the keystroke.

So criterion two is met: click a menu and it opens (docs/wayland-menu-open.png), type in a document
and characters appear (docs/wayland-typing-works.png).

## RESIZE, re-demonstrated on the current build, 2026-08-14 evening

    cider-wayland-window resized number=2 size=1256x684
    cider-wayland-window resized number=2 size=700x600
    cider-wayland-window resized number=2 size=1150x640

docs/wayland-resize-narrow.png is 700x600 and docs/wayland-resize-wide.png is 1150x640, both with
the correct chrome. At the narrow size the application has RELAID OUT rather than been clipped: the
toolbars collapse into the overflow chevron, the ruler ends at 14 instead of 18, and the status bar
drops the fields that no longer fit.

TWO HARNESS BUGS WERE IN THE WAY, and both made the resize look broken when it was not.

    [class=".*"] MATCHES NOTHING ON WAYLAND. class is an X11 property. Every resize this harness
    issued was aimed at whatever happened to be focused. The selector is [app_id=".*"] now, which
    needs the next item to work at all.

    THE TOPLEVEL HAD NO app_id. A window with none is anonymous to the compositor: no rule can match
    it, it has no identity in a task list and it gets no icon. The backend sets it now, from the
    bundle identifier, so LibreOffice appears as org.libreoffice.script.

Resizing the OUTPUT rather than the window is also what a person actually does by dragging a window
edge; a floating resize is a request the compositor may clamp, and it left the width unchanged every
time.

## THE TWENTY SECOND DEATH WAS A WORKQUEUE THREAD NESTING INTO ITS OWN STACK, 2026-08-14 night

LibreOffice ran for eighteen to twenty five seconds and died, every run, on both backends. It does
not any more: alive at 8, 16, 24, 32 and 40 seconds, no crash line, and the event pump steady at
about 58 calls a second through t=48.

### What it was

_start_wqthread never touches the stack pointer. On a real system XNU sets it before jumping, so a
worker thread begins each item at the top of a fresh stack. This emulation jumped to that same entry
point from inside sys_workq_kernreturn, which is itself running on the thread stack, and left the
stack pointer where it was. Every park and wake cycle NESTED: the frames of the previous cycle
stayed below the new ones.

    48x _start_wqthread
    48x _pthread_wqthread
    48x _dispatch_source_invoke
    48x ___workq_kernreturn
    48x _sys_workq_kernreturn

That is one sampled window of a 1.5 MB stack, and the fix is one instruction: the pthread structure
sits AT the top of the stack for a workqueue thread, which is what libpthread records as stackaddr,
so restoring rsp to self is exactly what the kernel does.

### Why it took so long to see

It never looked like a stack overflow. The thread ran out of room at a different place every run, so
the symptom was a fault inside free(), or an os_unfair_lock aborting for recursion, or a heap that
the allocator refused to walk. Three separate memory bugs that were all the same bug.

### The reproducer, which is the part worth keeping

tests/buck2/gui/timeout_probe.m. In its run loop mode it does nothing but enter and leave
CFRunLoopRunInMode with a sixteen millisecond timeout, which creates and cancels one dispatch timer
source per pass. Before the fix it died between pass 500 and pass 1000, reliably, in about ten
seconds. After it, 1520 passes and a clean exit. Its sources mode is smaller still: create, cancel
and release timer sources in a loop, with no CoreFoundation at all.

Getting from a word processor that dies in twenty seconds to a forty line program that dies in ten
is most of the work here. The stack histogram is what named it: dumping the whole live stack and
counting return addresses by frequency, rather than reading the top frame.

## ALL THREE CRITERIA, ONE RUN, ON THE FINAL BUILD, 2026-08-14 night

scratchpad/run-lo-final.sh drives one 120 second session and takes a picture at each step. No crash
line in the log, and the application is still running at the end.

    1 RENDERS      docs/wayland-final-typed.png     light grey toolbars, correct icons, ruler,
                                                    white page, readable status bar
    2 INTERACTIVE  docs/wayland-final-typed.png     Hello from Wayland is in the document and the
                                                    status bar says 3 words, 18 characters
                   docs/wayland-final-menu.png      the File menu opens on a click with every item,
                                                    shortcuts and greyed entries correct
    3 RESIZABLE    docs/wayland-final-resized.png   760x620 after the compositor resized the output,
                                                    toolbars collapsed to the overflow chevron, the
                                                    ruler ends at 11, the status bar drops fields

### What is still wrong, and it is not nothing

ESCAPE DOES NOT DISMISS A MENU. The key arrives, is translated correctly (keysym 0xff1b, Carbon 53,
characters 0x1b) and is handed to the application, and the log shows it delivered as an NSKeyDown.
It never reaches -[SalFrameView keyDown:], while the letters before and after it do. So it is lost
between AppKit delivering the event and the application view receiving it. The visible consequence
in the run above is that the typing meant for the document navigated the open menu instead.

A REGION CAN HOLD A STALE FRAME. In the second picture the menu bar shows Application and File and
nothing else; in the third, taken after a click forced a repaint, the rest of the bar is there. The
content is drawn correctly when it is drawn, but nothing repaints that strip on its own.

## ESCAPE CLOSES THE MENU. It was bound to the wrong selector, 2026-08-14 night

    "0x001B" = "cancel:";		was
    "0x001B" = "cancelOperation:";	is

AppKit binds Escape to -cancelOperation:, and that is the selector applications implement:
LibreOffice has cancelOperation: in its selector table and does NOT have cancel:, so Escape arrived,
was translated correctly, reached -[SalFrameView keyDown:], turned into doCommandBySelector: cancel:
and stopped there. Nothing was missing from the keyboard path; one name was wrong.

NSResponder now has the default -cancelOperation: that AppKit documents, which passes cancel: along
the responder chain, so this framework own panels that implement the older selector keep working.

Measured after: doCommandBySelector: cancelOperation: is followed by
sendKeyInputAndReleaseToFrame code=1281 char=27, which is KEY_ESCAPE, and the open menu closes
(docs/wayland-escape-closes-menu.png). Typing straight after that goes to the MENU BAR rather than
the document, which is what LibreOffice does everywhere else: one Escape leaves the menu, a second
leaves the menu bar.

WHAT FOUND IT was tracing the application own doCommandBySelector: alongside the key path. Return
was already working through insertNewline:, so the two side by side said the machinery was right and
one binding was not.

## The menu bar strip, which is the last visible rendering defect, 2026-08-14 night

At rest the menu bar shows Application and File and nothing else. One click on it and the whole bar
is there: Edit, View, Insert, Format, Styles, Table, Form, Tools, Window, Help. A forced redraw does
the same, which says the application HAS the items and simply does not repaint that strip on its own.

What it is NOT, each checked rather than assumed:

    NOT a resize artefact. It happens in the headless harness where the window is never resized.
    NOT the buffer. A forced display plus present paints the whole bar correctly.
    NOT missing menus. They are all present and open correctly once painted.

A full redraw after a frame change is right in any case and is committed here, but it did not fix
this: the resize happens before the menus are built.

## THE MENU BAR IS COMPLETE. Nothing told the strip its menu had changed, 2026-08-14 night

docs/wayland-menubar-complete.png: Application, File, Edit, View, Insert, Format, Styles, Table,
Form, Tools, Window, Help, at rest, with no interaction.

A window builds its main menu view once, from the menu object the application shares, and NSMenu
addItem:, insertItem:atIndex: and removeItem: mutated that object and told nobody. LibreOffice fills
its menu bar in as it loads, so the strip kept the two items it had when it was first drawn, for the
whole session, and one click on the bar repainted it and all twelve appeared at once.

AppKit posts NSMenuDidAddItemNotification for exactly this. Those names do not exist in this
framework, so the mutators invalidate the views directly: a walk of the window list per mutation,
which happens while an application builds its menus and essentially never afterwards.

WHAT MADE IT FINDABLE was comparing the two instruments the plan has always described. The BMP dump
and the compositor screenshot AGREED, which ruled out every commit, stride and format explanation in
one step and left only "the application really did draw two items". After that the question was why,
and the answer was that it had drawn them when there were two.

## Every fix of today is a PATCH FILE now, which it was not an hour ago

vendor/src is a MATERIALISED pin: it is overlaid from vendor/pins and patched, and it is not tracked.
Nine of today's fixes lived only in that tree, which means the next time the pin materialises they
would have been gone, and the only trace of a day of work would have been the commit messages.

    cocotron 0043 windowless displayRectIgnoringOpacity:inContext:
    cocotron 0044 NSBox draws, and keeps the fill colour it is given
    cocotron 0045 alpha first big endian writes A R G B, not R G B A
    cocotron 0046 NSResponder cancelOperation: default
    cocotron 0047 Escape is cancelOperation:, not cancel:
    cocotron 0048 a menu change invalidates the bar that draws it
    cocotron 0049 NSWindow _mainMenuChanged
    cocotron 0050 the colour component read trace
    xnu      0010 the workqueue entry resets the stack
    xnu      0011 the workqueue park timeout knob

Each one was checked by reverse applying it against the tree: if it does not come back off cleanly
it does not describe what is actually there.

## The patch series did not apply, and nobody would have known, 2026-08-14 night

Capturing today fixes as patches is not the same as those patches WORKING. Applying the whole series
to a freshly fetched pin is the only check that means anything, and it found two things:

    0034-surface-noneskipfirst-big-endian FAILED at hunk 1. It had been generated against a tree
    that already had other changes in it, earlier in this session, and nothing since then had
    materialised the pin, so the endpoint build had been broken ever since and no run noticed.

    //src/darwin/etc:resolv.conf did not exist. Both buck/prefix/BUCK and buck/prefix-min/BUCK have
    referenced it since the file was added, so every graph query over either prefix died with
    "Unknown target" and took the nix endpoint with it. The file was there; the three lines that
    export it were not.

0034 is regenerated from the pristine pin and now carries the alpha-first byte order fix as well, so
0045 is gone. The whole series applies: 49 of 49 cocotron, 11 of 11 xnu, and the result is
byte-identical to the tree that produced every screenshot above.

THE LESSON, which is the same one as always: a patch that reverse-applies to the tree you are running
proves only that it describes that tree. Apply the series to the ORIGINAL, and diff the result
against what you tested.

## Keyboard shortcuts work, and the two character strings are not the same string

docs/wayland-command-a-selects.png: type into the document, press Command and A, and the status bar
says Selected: 4 words, 18 characters with the text highlighted. That is a modified shortcut going
all the way through, which nothing had tested before.

Control and A found a real bug on the way. -characters is what a key produced WITH the modifiers
applied and -charactersIgnoringModifiers is what it would have produced without them, and this
backend sent the same string for both. xkbcommon applies the control transformation, so Control and
A arrived as U+0001 in BOTH, no binding for control plus a was ever found, and the application
inserted the control character into the document: the selection was replaced by an invisible
character and the word count went to 1.

The bare string comes from the keysym now, which carries no modifier transformation. After: Control
and A leaves the text alone and keeps the selection.

## The endpoint evaluates again, and the mouse motion trace

nix build .#cider-buck2-min --dry-run now resolves the whole graph and exits 0: the pins materialise
with the full patch series, the buck2 graph lowers, and the derivations for cider-min are listed. It
has not done that at any point in this session.

MOUSE MOTION HAS A TRACE NOW. It was the only pointer event without one, which made a drag that
selects nothing indistinguishable from a drag whose motion never arrived. With it:

    cider-wayland-input motion=1 x=300 y=215 buttons=0x0 type=5
    cider-wayland-input button=0x110 pressed=true x=300 y=215 type=1
    cider-wayland-input button=0x110 pressed=false x=300 y=215 type=2
    cider-wayland-input motion=2 x=540 y=215 buttons=0x0 type=5

The release arrives BEFORE the motion. Both swaymsg forms behave this way: cursor set warps and drops
the button grab, and cursor move is coalesced into one motion delivered after the release. So DRAG
SELECTION IS UNVERIFIED rather than broken: the backend classifies a move with a button held as a
drag and posts it as one, and this harness cannot produce that ordering. A real pointer would.

## Arrows, Home, End, Page Up and Page Down did not exist at all until now

docs/wayland-page-down-scrolls.png: a four page document, made with Command and Return, then Command
and Home to the top, then two Page Downs. The status bar reads Pages 2 and 3 of 4 and the text of the
next page is on screen. That is view scrolling, driven from the keyboard, end to end.

WHAT WAS WRONG. AppKit does not deliver an arrow key or Page Down as an empty string: it delivers a
character in the private use block from 0xF700 up, and every key binding table in the framework and
in applications is written against those values. xkbcommon produces NOTHING for those keys, so this
backend sent an empty -characters, no binding matched, and the application received a keystroke with
no content. Measured: Page Down and Home arrived here with the right keysyms and the right Carbon
codes and NOTHING reached -[SalFrameView keyDown:].

The mapping covers the four arrows, Home, End, Page Up, Page Down, Insert, forward delete, F1 to F12
and the three lock keys. AppKit also sets the function modifier for all of them and the numeric pad
modifier for the arrows, which is what the framework binding table matches on, so both are set.

After: Page Down arrives as KEY_PAGEDOWN with modifiers 0x800000, Command and Home as KEY_HOME with
0x840000, and the view moves.

A NOTE ON THE TEST ITSELF. The first version of this used Control and Return for a page break and
concluded that scrolling was broken because the picture did not change. The document had one page:
the shortcut on this platform is COMMAND and Return, and the application was right. The check that
caught it was reading the page count in the status bar rather than trusting the comparison.

## The endpoint builds from scratch, which is the last thing that was unproven

    nix build .#cider-buck2-min   ->  /nix/store/...-cider-min, exit 0, no errors

That is: pins fetched fresh from their recorded revisions, the whole patch series applied, the buck2
graph lowered, and the min prefix compiled and linked with the toolchain now at -O2. It took about
forty minutes and 9076 lines of log.

It matters because buck2 alone cannot check any of it. buck2 builds from vendor/src, which is the
MATERIALISED pin tree and is not tracked, so it will keep building fixes that exist only on this
disk and report success. This is the only path that starts from what is committed.

## The wheel scrolls, and two placeholders that had stopped being true

docs/wayland-wheel-scrolls.png: eight wheel notches over the page and the view moves to the next
page, status bar Pages 1 and 2 of 2.

TWO BUGS, and the second is the interesting one.

THE POINTER WAS ALWAYS AT THE ORIGIN. -[NSDisplay mouseLocation] returned 0,0 and
-currentModifierFlags returned 0, both written when there was no seat to track and both left behind
when there was. An application that asks where the pointer is before acting decides the event
happened at the corner of the screen. They read the tracked state now.

AND -[NSEvent phase] DID NOT EXIST. LibreOffice classifies every scroll with isMouseScrollWheelEvent,
which reads -phase and -momentumPhase before anything else: a wheel is where both are None, a
trackpad gesture is where they are not. Neither selector existed, so the first thing the application
did with a scroll was raise an unrecognized selector, and its own handler swallowed it. Eight scroll
events reached -[SalFrameView scrollWheel:] with the right deltas and the document did not move.

    cider: RAISE NSInvalidArgumentException: -[NSEvent_mouse phase]: unrecognized selector

That line is why CIDER_TRACE_EXCEPTIONS exists, and it named the bug in one run after two rounds of
guessing had not.

A NOTE ON THE HARNESS. None of this could be tested until the pointer was driven by a virtual
pointer device (wlrctl) rather than by compositor IPC: swaymsg cursor set warps and drops the button
grab, cursor move is coalesced and delivered after the release, and cursor press cannot make an axis
event at all. With a virtual device the drag arrives as it should, motion with buttons=0x1 and type 6,
NSLeftMouseDragged.

STILL NOT WORKING: a drag across text does not SELECT it. The events are right, so the next question
is what LibreOffice does with them.

## A double click was two single clicks, and selection is still not working

AppKit reports the second press of a double click as clickCount 2, and applications read it: that is
how a double click selects a word and a third click selects a line. This backend reported 1 for
every press, so a double click was two single clicks and nothing that needs one could happen. Presses
are counted now, within 500 ms and 5 pixels of the previous one, which is the macOS rule.

    CIDER_VCL mouseDown: clickCount=1
    CIDER_VCL mouseDown: clickCount=2     <- after the fix

AND SELECTION STILL DOES NOT WORK, by drag or by double click. Everything at the boundary is now
verified correct, which is worth listing because each was a candidate:

    the drag arrives as NSLeftMouseDragged with buttons held (motion trace, type 6)
    mouseDown, six mouseDragged and mouseUp all reach -[SalFrameView ...]
    the click count is 1 for the press and 2 for a double click
    the coordinates LibreOffice computes are right: it reads [NSEvent mouseLocation], and
      mouseLocation minus the window frame origin is exactly the local position, moving 285 to 390
      across the drag
    no exception is raised anywhere in the run, so nothing is being swallowed
    a single click DOES position the caret, so the same coordinates through the same path work

So the events are right and the application does not act on them. The next step is VCL side: what
starts a text selection in a Writer edit window, and what it requires that a caret move does not.

## Keyboard selection works, which narrows the mouse one considerably

docs/wayland-shift-selects.png: ten Shift and Left presses after typing, and the last ten characters
are highlighted. So VCL selection machinery is fine, its Writer edit window extends a selection
happily, and the drawing of a selection is fine too.

That leaves the mouse path specifically. What is known:

    a single click moves the caret, so MouseButtonDown reaches the edit window with usable
      coordinates
    the drag arrives as NSLeftMouseDragged with the button held and a click count of 1
    a double click arrives with a click count of 2
    the coordinates the application computes from [NSEvent mouseLocation] are correct throughout
    nothing raises

and neither a drag nor a double click selects anything. The difference between a caret move and a
selection on the VCL side is TRACKING: MouseButtonDown starts it, mouse moves are delivered to the
tracking window as TrackingEvents rather than as plain moves, and MouseButtonUp ends it. That is
where to look next, and it is the only part of this that has not been instrumented.

## CORRECTION: mouse selection works. The tests were clicking in the margin

docs/wayland-drag-selects.png: a drag across the line and Drag across this sente is highlighted,
exactly the span the pointer covered. docs/wayland-double-click-selects.png: a double click on the
first word and Drag is highlighted.

THE SECTIONS ABOVE THAT SAY SELECTION DOES NOT WORK ARE WRONG, and the reason is worth keeping. The
drag started at x=285 and the double click at x=330, and in that window the text starts at x=390:
both were in the page margin, where there is nothing to select and where LibreOffice correctly does
nothing. Three rounds of instrumenting the event path found nothing wrong with it because there was
nothing wrong with it.

What found the mistake was the plainest test available: type a known line, click at three different
places, type a marker after each, and read where the markers landed.

    2AAAA BBBB CCCC DDDD1

The 1 came from a click past the end of the line and landed at the end; the 2 came from a click at
x=400 and landed at the start, which is correct, because x=400 is ten pixels into a text that starts
at 390. Both clicks were right and so was the application. The map from screen position to text
position was the missing measurement, and it took two minutes.

The click count fix that came out of the same investigation is real and still needed: a double click
reported as two single clicks cannot select a word however good the coordinates are.

## The Wayland backend is the DEFAULT, and X11 is what happens when no compositor answers

CIDER_WAYLAND_BACKEND was an opt-in while the backend could not do the job. It is an opt-OUT now
(set it to 0 to decline on purpose and compare against X11 without rebuilding).

Nothing about the fallback needed writing, because AppKit already expresses availability the right
way: NSDisplay sorts the backend bundles by NSPriority DESCENDING (NSDisplay.m does [p2 compare: p1])
and takes the first whose principal class returns non-nil from -init. Wayland is 300 and X11 is 200,
so Wayland is asked first and answers nil when it cannot reach a compositor.

Both directions are checked, and the second one is the one that matters:

    compositor present, variable unset   window mapped, 1024x656, first frame at t=2.54 s
    no compositor at all                 cider-wayland-appkit init=declined reason=no-compositor

The second is a control that FIRES: if the decline had stopped working, the line would be missing and
X11 would never be reached on a machine without Wayland.

## Saving a document works, and it took three missing methods

docs/wayland-save-panel.png is the panel Command S opens: a file list of the guest root, Cancel and
Save. The proof is not the picture though, it is the file: type a sentence, Command S, click Save,
and /Users/root/Documents/Untitled 1 is an OpenDocument Text whose content.xml contains
"Drag across this sentence with the mouse please".

THREE SEPARATE BUGS, each of which stopped the save on its own, and each invisible in the ordinary
sense: the application caught every one and reported nothing.

1. -[NSSavePanel setCanSelectHiddenExtension:] did not exist. An application configures the panel
   before showing it, so this killed the process outright: the whole dialog was built and then the
   configure step raised. Unspecified Application Error, no panel.

2. -[NSImage lockFocusFlipped:] did not exist. This one is subtler: the raise happened INSIDE the
   save path, LibreOffice caught it, and the panel simply never appeared. The keystroke traced
   perfectly to the application every time. This is what made the panel look flaky.

3. -[NSSavePanel _selectFile:] took the filename from the SELECTED ROW, which cannot be right for a
   save: the file does not exist yet, so nothing is selected, and the panel returned OK with an
   empty name. Clicking Save closed the panel and saved nothing. It uses the name field the
   application already sets, joined to the directory. NSOpenPanel keeps the row behaviour, in its
   own override, because opening really is the row.

The A and B for 3 is exact: the same script and the same click on the same panel wrote no file with
the row version and wrote the document with the name field version, one run apart.

CORRECTION, and it is my own error: THE PANEL BUTTONS ARE NOT CLIPPED. I said they were in the
commit above, from looking at a downscaled crop whose bottom edge fell near them. A pixel column
through the Cancel button says otherwise, in the application own buffer and in the compositor
screenshot, identically:

    1333 EDEDED   panel background under the list
    1347 C7C7C7   button TOP border
    1348 FFFFFF   button interior
    1356 373737   the glyphs
    1368 C7C7C7   button BOTTOM border
    1369 EDEDED   background again, twenty rows of it before the surface ends at 1388

The layout agrees: the content view is 845x1388 and the buttons are 96x32 at y=12, twelve points
above the bottom, with the file list above them at 807x1325+18+55. Nothing is cut.

DO NOT JUDGE A RENDERING FROM A SCALED CROP. Two claims in this file came from that and both were
wrong, this one and the drag selection one. Crop at full resolution, or read the pixels.

## Save As works now: the panel has a field you can type a filename into

docs/wayland-save-name-field.png shows it: a Save As label, a field holding cider-typed-name with
the caret after it, and the Cancel and Save buttons under it. The proof is again the file, not the
picture: /Users/root/Documents/cider-typed-name is an OpenDocument Text with the document text in
it, and the name came from the KEYSTROKES, not from the name LibreOffice set on the panel.

The nib content view holds a scroll view and two buttons and nothing else, so there was nowhere to
type. The field is built when the panel is about to run rather than added to the nib, for two
reasons: the nib is a binary in the pin, so a patch to it would be unreviewable, and a panel that
builds its own field also works for a caller that never loaded the nib. The list gives up the height
the field takes, so nothing overlaps at any window size, and the field is made first responder so
the first keystroke lands in it.

An open panel never gets one. NSOpenPanel has its own runModal and its own OK action for the same
reason: opening answers with the selected row, and a name field would have nothing to do.

## Opening a document works, and fixing it removed the thing that made this harness flaky

docs/wayland-open-panel-selects.png: Command O, and the file at the guest root is selected in the
panel list. docs/wayland-open-two-documents.png: two document windows, the original and the opened
one, both showing the saved sentence and both saying 8 words, 47 characters.

A TOOLTIP IS NOT A WINDOW EITHER. The rule that decides toplevel or popup was the window LEVEL
alone, and a tooltip is level 0 with style mask 0, so every tooltip became a toplevel. On a tiling
compositor each one takes a share of the screen. Measured in one run: TWENTY windows 18 points tall
mapped as the pointer crossed the toolbar, one every 0.3 seconds, and the last survivor was a
419x684 tile painted 59x18 -- a black third of the screen.

It also explains the flakiness that cost hours of this session. The tiles were being reshuffled by
tooltips while a test was driving the application, so the document window was 1690 wide in one run
and 419 in the next, clicks computed from a previous screenshot landed somewhere else, and the save
panel appeared to open only sometimes. After the fix a whole run maps TWO toplevels, the document
and the panel, and the tile geometry is the same every run.

The signals together are exact: borderless AND parented is a tooltip; borderless with no mapped
parent stays a toplevel, which is what a splash screen wants; the scrollbar helpers the old comment
worried about are never mapped at all.

THE FRESHLY OPENED WINDOW WAS WRONG IN TWO WAYS, and both are fixed. docs/wayland-open-two-documents
.png now shows both documents laid out to their tiles, status bar at the bottom of each.

FIRST, THE BUFFER. One traced line explains the black half of that window:

    cider-wayland-setframe number=46 asked=1024x656 current=628x684

LibreOffice sizes a new document window to its preferred 1024x656 AFTER the compositor has tiled it
to 628x684, and this backend obeyed, committing a 1024x656 buffer into a 628x684 surface. A
compositor shows the part it has and black for the rest. A Wayland client does not get to pick: once
a compositor has configured a toplevel, that size is binding, so the configured size now wins and the
application is told the real size rather than silently overruled. A compositor with no opinion sends
0x0, never sets a configured size, and nothing changes for it -- weston headless behaves exactly as
before, and a popup still sizes itself.

SECOND, THE LAYOUT, and the shape of this one is worth keeping. Repeating the SAME size changed
nothing, a hundred times over six seconds. Forcing a real compositor resize to a DIFFERENT size laid
the window out correctly at once. So the application ignores a resize to the size it believes it
already has, and the only thing that reaches it is a change. The first frame change after an override
is therefore delivered ONE ROW SHORT, once, with the true size a sixth of a second later: exactly
what dragging a window edge by a pixel would send.

The repeat stops on evidence rather than a guess: while the bottom row of the buffer is still the
clear value the application has not painted the bottom of its own window, so it keeps being told,
and once that row is painted it stops. A deadline bounds it for a window that is legitimately dark
down there.

## The clipboard reaches other applications now, both ways

WaylandPasteboard.m said it did not do this and named the missing piece: wl_data_device, which needs
a seat, which now exists. Verified against wl-clipboard as the other application, in one run:

    OUT  select all in the document, Command C, then wl-paste --list-types and wl-paste
         text/plain;charset=utf-8 / UTF8_STRING / text/plain / TEXT
         Drag across this sentence with the mouse please
    IN   wl-copy "CLIPBOARD FROM LINUX", then Command V in the document
         docs/wayland-clipboard-from-linux.png shows that line in the page

THREE THINGS HAD TO LINE UP, and each was invisible on its own.

THE COPY IS LAZY AT BOTH ENDS. Publishing from -setData:forType: caught nothing, because LibreOffice
never calls it at copy time: it DECLARES the types it could produce and waits to be asked. Wayland
makes the same bargain, so ownership is taken in -addTypes:owner: and the bytes are rendered in the
wl_data_source.send callback, where the pasteboard asks its owner for the first time. A copy nobody
pastes costs one protocol message and renders nothing.

THE SERIAL IS THE PERMISSION. set_selection is refused unless its serial belongs to a recent input
event on the seat, which is how a compositor stops a background process from taking the clipboard.
input.rs records the serial of every key and button press for this.

LOSING OWNERSHIP HAS TO REACH THE PASTEBOARD. With the first two done, copy out worked and paste in
inserted the applications OWN old text: wl-copy had taken the selection but the pasteboard still held
its data and never looked further. wl_data_source.cancelled is that news, and it now empties the
general pasteboard, which is what makes the next paste fall through to the system selection.

THE COST IS PAID: -types asks the system on every call, and an application asks more than once per
paste, so the run above did four pipe transfers where one was needed. The answer cannot change
without a new offer, so it is cached against the offer and cleared when one arrives. Same run after:
ONE transfer, both directions unchanged. The empty answer is cached too, or a clipboard holding
something we cannot read would be asked for again on every keystroke that enables a Paste item.

## Export as PDF works, and the name you type is the name you get

Click the PDF button on the toolbar and LibreOffice exports DIRECTLY: no options dialog, straight to
the file picker (docs/wayland-pdf-export-panel.png). Type a name, click Save, and
/Users/root/Documents/cider-export.pdf is a PDF document, version 1.7, 1 page.

THE TYPED NAME IS THE NAME, and it now carries the extension the panel was told to require:
typing cider-noext into a PDF export produces cider-noext.pdf, and the same panel saving a document
produces cider-typed-name.odt, both verified with file(1).

A CORRECTION TO THE COMMIT THAT ADDED THIS. It said LibreOffice never asks the panel for a filename,
because a trace in -_selectFile: and one in -_setFilename: printed nothing across four runs that
each produced a PDF. That conclusion was wrong and so was the reasoning: the instrument was never
validated. Probes at the ENTRY of every panel method print this, in order:

    +savePanel / runModal enter / _ensureNameField / _selectFile
    setFilename=/Users/root/Documents/cider-noext
    ok filename=... nameField=cider-noext property=Untitled 1 directory=/Users/root/Documents
    runModal returned=1 required= allowed=( pdf )

So the panel IS asked, it does return the path, and the application writes exactly there. The two
earlier traces were in a build that did not reach the run: same source, same command, and the
artifact that ran was the previous one. VALIDATE AN INSTRUMENT BEFORE CONCLUDING FROM ITS SILENCE.

The extension needed one more thing after that. -_selectFile: read the text field DIRECTLY, so the
extension applied by -nameFieldStringValue was computed and thrown away. It reads the accessor now.
allowed=( pdf ) in the trace above is what supplies the extension; a name typed WITH one is left
alone, or a save dialog ends up writing report.pdf.pdf.

## Command F killed the application, twice over, and neither wall was visible before the keystroke

Find is ordinary use, and it took two fixes to survive it. docs/wayland-find-toolbar.png is the
result: a close button, a Find field, up and down arrows, Find All, Match Case and the search icon.

FIRST, A MISSING SYMBOL THAT LINKED CLEANLY. LibreOffice draws the toolbar through a transparency
layer and the exact call it makes was not there:

    dyld: lazy symbol binding failed: Symbol not found: _CGContextBeginTransparencyLayerWithRect
      Referenced from: libvclplug_osxlo.dylib

Bound LAZILY, so nothing complains until the first call: the plain BeginTransparencyLayer existed and
was backed by a real Onyx2D layer, only the rect variant was absent. It is implemented as the layer
plus a clip to the rect, and the clip is applied AFTER the layer begins on purpose:
-beginTransparencyLayerWithInfo: saves the graphics state and -endTransparencyLayer restores it
before compositing, so the clip disappears with the layer instead of leaking into later drawing.

SECOND, THE FOCUS RING. Past the symbol, the next keystroke raised
-[NSComboBoxCell drawFocusRingMaskWithFrame:inView:] as an unrecognized selector. AppKit draws a
focus ring by asking the CELL to fill the shape it wants ringed and then stroking around that fill;
NSCell defines the default and subclasses override it. Nothing here defined it at all, so the first
control that took focus killed the process. NSCell fills its frame now, and answers
-focusRingMaskBoundsForFrame:inView: with the same rectangle.

HOW IT WAS FOUND, because the first two attempts were wrong. The crash is SIGABRT, LibreOffice turns
it into Unspecified Application Error, gdb catches the abort but cannot walk a Mach-O stack, and the
core has one thread left in a syscall. What named it was raising the applications OWN logging to
SAL_LOG=+WARN+INFO and reading the last lines before the fatal: dyld prints exactly which symbol it
could not bind, and the ObjC runtime prints exactly which selector went unrecognised.

## Bold renders, and the reason it did not is one line of plumbing

docs/wayland-bold-renders.png: the selected word is visibly heavier than the text around it, and
after Command Z it is back to the regular weight. Ordinary use now passes end to end: select a word,
bold it, undo it, open find, type a word and see the match highlighted.

THE FORMAT WAS NEVER THE PROBLEM. LibreOffice applied it and lit the B in its toolbar; the glyphs
came out regular because the request never reached the file. Two things were in the way.

A NAME HERE IS A FONTCONFIG PATTERN. O2Font_freetype hands the string straight to FcNameParse, so
"Liberation Serif:style=Bold" selects the bold face -- and everything above it passed the bare
family and nothing else, so a bold run and a regular run resolved to the same file.
CTFontCreateWithFontDescriptor now reads the symbolic traits it was given and asks for the styled
pattern, falling back to the family when the face does not exist: a family with no bold on disk must
still produce a font, and letting fontconfig substitute a different FAMILY for the style would be
worse than the regular weight of the right one.

AND THE DESCRIPTOR COULD NOT BE BUILT AT ALL. CTFontDescriptorCreateWithAttributes was a stub
returning NULL -- with the wrong signature, taking void -- so an application could not ask for a
font by anything except a family name. A descriptor in this port IS the attribute dictionary, which
CTFontCollection builds per face and CTFontDescriptorCopyAttribute reads straight out of, so
creating one from attributes is a copy. LibreOffice calls it 53 times in a single run.

## Command P: the dialog opens and renders, and dismissing it still ends in a crash

docs/wayland-print-alert.png is what Command P produces: the red alert icon, "No default printer
found.", "Please choose a printer and try again." and an OK. That is CORRECT -- there is no printer
and no spooler in this container -- and the dialog draws.

THREE REAL GAPS WERE FIXED GETTING THERE, each one a crash of its own:

    +[NSPrinter printerNames]        did not exist, and the class forwards INSTANCE messages only,
                                     so a class message landed nowhere and raised
    +[NSPrintInfo defaultPrinter]    did not exist either
    -[NSPrintInfo setPrinter: nil]   raised "Cannot set nil objects nor nil keys", because the
                                     setters passed nil straight into a dictionary. nil removes the
                                     key now, which is what an absent attribute means anyway

The selectors were found statically, by intersecting the strings of libvclplug_osxlo with the API,
rather than one crash per round trip.

IT STILL DIES, and the honest statement is that this path is NOT fixed. Dismissing the alert now
reaches "index (0) beyond array bounds (0)" inside LibreOffice: its macOS backend indexes element
zero of a printer list without checking whether one exists. Handing it ONE invented printer was
tried and does not help -- the same exception arrives from somewhere else -- and inventing a printer
this system cannot print to is a lie the next layer would trip over anyway. Printing needs a spooler
in the container, which is a different piece of work.

WHAT THE BUTTON TRACE FOUND ALONG THE WAY. CIDER_TRACE_PANEL now also prints every NSButtonCell
bezel draw with its class, window, bezel style, border and frame. The alert OK button turned out not
to be drawn by AppKit at all: the draws that happen while it is on screen have class=nil and
window=(null), which is LibreOffice rendering its own controls into its own context with a cell and
no view, one of them 93 points wide and ZERO high. That is why the OK has no bezel and only its
label shows. The button is still clickable, which is how the crash above was reached at all.

## A view can be cached into a bitmap now, which fifteen calls a run were quietly failing to do

-[NSView bitmapImageRepForCachingDisplayInRect:] and -cacheDisplayInRect:toBitmapImageRep: were both
NSUnimplementedMethod. They are used TOGETHER -- ask for a rep, then fill it -- so a caller received
nil and then nothing, and a view that answers nil is indistinguishable from one that drew an empty
image. Fifteen calls in a single LibreOffice run, every one from NSScroller.

The rep is RGBA8 non planar, and the fill reuses -displayRectIgnoringOpacity:inContext: rather than
calling -drawRect: directly, because that path already handles focus, clipping and subviews and, as
the comment above it says, works for a view with NO WINDOW -- which is the ordinary case for
something being rendered into a bitmap.

The translation is the whole of the second half: the rect being cached has to be moved to the rep
origin, or a control living at x=200 is drawn 200 points off the edge of a 60 point rep and the
caller gets an empty image, which looks exactly like a view that refused to draw.

Verified by absence and by no regression: the unimplemented line is gone from a full run, the
application survives to its timeout with no unrecognised selectors, and drag selection still
highlights exactly the span the pointer crosses.

## The event pump had no autorelease pool, and idle cost nineteen megabytes a second

Found by soaking rather than by reading: five minutes of ordinary editing took resident memory from
1.4 GB to 11.7 GB. The first suspicion was the document growing, so the soak was rewritten to keep it
to ONE LINE, and it still climbed. Then the control that settled it: the same run with NO INTERACTION
AT ALL, no keyboard, no mouse, nothing but the pump.

    idle, no pool            1.29 GB to 3.60 GB in two minutes    about 19 MB/s
    idle, pool on the drain  0.76 GB to 1.59 GB in two minutes    about 7 MB/s
    editing soak, before     1.4 GB to 11.7 GB in five minutes

Flat mapping count throughout (1310), flat file descriptors (41): anonymous memory that is never
given back, and an application doing NOTHING cannot leak from what it is doing.

On Apple systems the run loop wraps every iteration in an autorelease pool. This backend IS the loop
-- it calls the libdispatch main queue drain directly from -nextEventMatchingMask: -- and there was
no pool anywhere, so every autoreleased object made by a block on the main queue lived until exit.
For LibreOffice that means its timers, its idle work and the drawing they cause.

WHAT IS NOT FIXED: about 7 MB/s remains, and it is the events themselves. The proper answer is the
run loop pattern -- one pool per pass, released at the TOP of the next pass, so the event survives
being handled -- and it kills the application on its first window: it is holding something from the
previous pass. The pool therefore covers the drain and this backend own per-pass work, and the event
fetch stays outside it.

## Three things the user could see, and one of them was a real protocol mistake

THE MENU BAR WAS TOO SHORT AND ITS ITEMS TOO SMALL. menuFontOfSize: 0 resolves to the general 12
point default and the bar is sized from that string height plus eight points, which came out
SIXTEEN points tall. Apple uses a 14 point menu font in a bar of about 22 at 1x. Both are set now,
with 22 as a floor: a height derived purely from a measured string follows whatever the font backend
reports, and a fallback face with tight metrics would silently squash the bar again.

THE FIRST MENU SAID "Application". On Apple systems the title of the first item in the main menu is
IGNORED and the system substitutes the running application name; LibreOffice titles that item
Application and expects never to see the word. NSMainMenuView substitutes it now, from
CFBundleDisplayName, then CFBundleName, then the process name. docs/wayland-menubar-app-name.png:
LibreOffice File Edit View Insert Format Styles Table Form Tools Window Help.

THE SAVE DIALOG WAS A TILE BESIDE THE DOCUMENT instead of a dialog centred over it, and that was our
bug rather than the compositor being odd. A panel is TITLED, so the rule that decides parenting made
it a parent in its own right. It asks the delegate whether it is an NSPanel now -- NSSavePanel,
NSOpenPanel and the window NSAlert builds all are -- and gives it a parent, which is how xdg_shell
expresses a dialog and what makes a compositor float it.

AND THE PARENT WAS WRONG TOO, which only the wire showed. WAYLAND_DEBUG=1 on a run prints

    xdg_toplevel#151.set_parent(xdg_toplevel#29)
    xdg_toplevel#19.configure(1256, 684)     <- the document window is 19, not 29

The parent being sent was the most recent TITLED window, and this application creates a dozen that
are never shown. A parent that is not a mapped view is ignored, so the dialog was tiled. It is
parented to a MAPPED toplevel now, the same rule popups already used, and the result is
docs/wayland-dialog-centred.png: the panel at its natural 500x400, centred at 378,142 in a 1256x684
output, over a document window that keeps the whole screen.

STILL EMPTY: the save panel window has no TITLE on the wire, only set_title(""). Both halves of the
plumbing are right -- NSWindow forwards to the platform window, and the backend now asks the window
for its title when the toplevel is created rather than relying on having seen it earlier -- so
something in the panel own path leaves it unset. Cosmetic, and unfinished.

## Where the residual idle leak is NOT, which is most of the work of finding it

After the autorelease pool, an idle LibreOffice still grows about 7 MB/s. Everything below is ruled
out by measurement, so the next attempt can start where this one stopped.

    the view bitmap cache      CIDER_NO_VIEW_CACHE=1 changes the slope not at all
    the buffer dumps           removing CIDER_WAYLAND_DUMP changes the slope not at all
    our surfaces and buffers   mapping count flat at ~1310, descriptors flat at 41, and the one shm
                               file mapping stays 3.3 MB
    the brk heap               [heap] is 50 MB before and 50 MB after
    the main queue drain       turning it OFF makes it WORSE, 19.5 MB/s instead of 7: the blocks
                               pile up unrun. The drain is the relief, not the cause.

What IS growing is anonymous mappings: 622 MB to 908 MB in 45 seconds, which is the guest malloc
taking new chunks. At 65 pump passes a second that is about 100 KB per pass, far too much for event
garbage and far too regular for anything the user is doing, since the user is doing nothing.

The suspects that remain are the blocks themselves: either LibreOffice idle work allocating C++
memory that is never freed in this environment, or this fork of libdispatch leaking the CONTINUATION
of every block it runs. The next measurement is to count blocks and bytes across one drain, which
separates those two, and CIDER_WAYLAND_NO_DRAIN is in the tree to make that comparison cheap.

## libdispatch is not the leak: 240,000 blocks cost 232 kilobytes

tests/buck2/gui/dispatch_probe.m is the suspect on its own, with no window, no application object and
no LibreOffice: it queues trivial blocks on the main queue and drains them exactly the way the pump
does, printing its own resident size as it goes.

    DISPATCH_PROBE start  rss_kb=16208
    DISPATCH_PROBE round=12 blocks=240000 rss_kb=16440

232 KB across a quarter of a million blocks, about one byte each, and flat from round five onwards.
So the continuation machinery gives back what it takes, and the 7 MB/s an idle LibreOffice grows is
what ITS blocks do rather than the queue that runs them.

## The waker woke the application sixty two times a second for nothing, and the leak is not ours

The waker thread polls the Wayland socket with a sixteen millisecond timeout and then woke the main
run loop WHETHER OR NOT anything had arrived. That is a full pass of the application event loop
sixty two times a second, forever, with the application idle: measured at 65 passes a second.

It wakes on a readable socket now, which is the point of the thread, and otherwise ticks four times
a second so a deferred repaint and a caret blink still happen without an event to carry them.

    pump passes while idle    65 a second before, 12 after
    first document window     2.53 s, unchanged
    interaction               drag selection still highlights exactly the span, no raises

AND IT SETTLES THE LEAK, by not changing it. Memory still grows about 7 MB/s with the pump running
five times less often, so the residual leak is not per pass and has nothing to do with the event
loop: it is per unit of TIME, from the application own timers, which fire whether or not anything
wakes them. Combined with the dispatch probe -- 240,000 blocks for 232 KB -- what remains is
LibreOffice allocating in its own periodic work and not giving it back.

The autorelease pool earlier IS ours and was real: 19 MB/s to 7. What is left is not.

## Application activation may only undo what deactivation did

-showWindowForAppActivation: showed EVERY window it was sent to. An application has windows that
were never ordered front, so bringing the application forward could put a window on screen that had
never been visible. It now restores only the windows THIS backend hid when the application was
deactivated, which is what activation means; the flag is per window and set at hide time.

A surface with nothing in it is also no longer mapped, which is Wayland own rule: a client is not
obliged to attach a buffer and a surface without one is unmapped by definition. The first attach now
waits for the application to draw something, and once a window has been mapped the check is skipped,
because a window that later clears itself is still a window.

NEITHER FIXED THE WINDOW THIS WAS AIMED AT, and that is worth writing down rather than quietly
leaving. LibreOffice keeps a borderless 648x200 window called VCL ImplGetDefaultWindow, created at
1396,620 on a real session, and it is the FIRST thing on screen: a blank rectangle before the
document appears. It survives both rules because the application does draw into it and does order it
front. What it does NOT survive on Apple systems is being seen, so the next thing to find is which
call makes it visible here.

## The whole interface was in DejaVu Sans, which is why it did not look like macOS

THE GOAL CHANGED, 2026-08-15, on the user instruction: LibreOffice should look EXACTLY as it does on
macOS, styling included, and be functional, and then be fast. The three original criteria are a floor
to keep, not the finish line. See scratchpad/STATUS.md, which now opens with this.

First measurement under the new goal, with a trace added for it (CIDER_TRACE_FONTS):

    CIDER_FONT pattern=San Francisco file=.../dejavu-fonts-2.37/.../DejaVuSans.ttf

AppKit asks for San Francisco, applications ask for Helvetica Neue and Lucida Grande, and none of
them exist here: they are Apple fonts and cannot be shipped. Fontconfig never fails, it SUBSTITUTES,
and its answer for an unknown sans family on this system is DejaVu Sans, a wide face with a large
eye that reads as anything except macOS. Every menu, every dialog and every label was in it.

Those names now resolve through a family list -- Helvetica first in case a real one is installed,
then TeX Gyre Heros, which is a Helvetica clone, then Liberation Sans -- and only the family part of
the pattern is rewritten, so a requested style, weight or size survives:

    CIDER_FONT pattern=Helvetica,TeX Gyre Heros,Liberation Sans,sans-serif asked=San Francisco
               file=.../gyre-fonts-2.501/.../texgyreheros-regular.otf

docs/wayland-ui-font-helvetica.png is the menu bar in it. Compare with
docs/wayland-menubar-app-name.png, which is the same bar in DejaVu.

## A macOS title bar, because nobody else was going to draw one

docs/wayland-macos-titlebar.png: a light bar with the three lights on the left, the window title
centred, and the menu bar under it. The lights are grey there because the window is not key in a
headless run, which is also what Apple does.

Cocotron never drew one -- the line it replaces read "when/if we add titlebars and such do it here"
-- because on Apple systems the window server draws it. On Wayland nobody does: a compositor
decorates only if the client asks through the decoration protocol, and what it draws is the DESKTOP
style. For an application whose point is to look like macOS, the macOS one is the right answer.

The geometry half is in the backend: a titled window now reserves 22 points at the top, which is
what Apple uses at 1x, so the content rect is the frame minus the bar exactly as it is there. The
drawing half is in NSThemeFrame: bar, hairline, three 12 point lights 8 apart and 20 from the left,
title centred in the small system font, everything dimmed when the window is not key.

IT IS DRAWING ONLY. Clicking a light does nothing and the bar cannot be dragged yet; that needs
hit-testing and xdg_toplevel.move, and a button that does not work is worse than one that is
honestly not there yet. Interaction after the change is unaffected: drag selection still highlights
exactly the span the pointer crosses, with the test coordinates moved down by the 22 points the bar
takes.

## The combo dropdown the user reported is still missing, and here is what it is NOT

Set Paragraph Style, Font Name and Font Size draw as plain boxes with no dropdown affordance. Ruled
out, each by measurement rather than argument:

    AppKit cells            a trace on every -[NSCell drawWithFrame:inView:] and on NSButtonCell
                            bezel drawing shows THREE cells drawn in a whole startup, all of them
                            17x14 checkboxes with the NSSwitch image. No combo, no popup, no arrow.
    HITheme                 the application imports exactly four theme calls and none of them is a
                            button; HIThemeDrawFrame is now implemented (a hairline rect, focus
                            ring when focused) and changed nothing on those fields.
    GetThemeMetric          never called in a run at all, so a zero metric is not shrinking anything
    stubbed C functions     the seventeen the application imports are all CoreText and font related
                            plus NSSetFocusRingStyle; no drawing primitive it uses is a stub
    gradients               it does not use any: its drawing is paths, rects, images and CGLayers
    CGLayer                 O2Context_builtin implements drawLayer:inRect:, it is not the abstract
                            raise the base class has

So the application draws those fields itself and simply does not put the button there under this
stack. The next move is LibreOffice own logging around its native widget path rather than more
guessing from the outside.

## The title bar works, dialogs float over their document, and a dialog has no menu bar

docs/wayland-dialog-macos.png: clicking the red light asks LibreOffice to close, it puts up Save
Document with its own title bar and coloured lights, and that dialog is CENTRED over a full size
document window at its natural 419x165 rather than tiled beside it.

THE LIGHTS DO SOMETHING NOW. Red is -performClose:, which is why the picture exists at all. Yellow
and green ask the compositor, because a Wayland client cannot minimise or maximise itself:
xdg_toplevel.set_minimized and set_maximized, sent with the SERIAL of the click, which is how a
compositor tells a user action from a background process. Dragging anywhere else in the bar is
xdg_toplevel.move for the same reason: a client that moved its own surface would be fighting
whatever the compositor thinks the position is. The requests live on the platform window and
NSThemeFrame sends them by name, so cocotron needs to know nothing about this backend.

A DIALOG IS A TITLED WINDOW THAT CANNOT BE RESIZED, and that one distinction fixed two things. The
Save Document window is style 0x3, titled and closable and not resizable, against 0xf for a
document. So it is parented like an NSPanel, which is what makes a compositor float it, and
+[NSWindow hasMainMenuForStyleMask:] no longer gives it a menu bar: cocotron draws the menu inside
each titled window because it has no screen menu, and a full File-through-Help bar inside a 419x165
dialog is something no macOS dialog has ever had.

STILL WRONG in that picture: the buttons are text with no bezel, the same as the print alert. That
is LibreOffice drawing its own controls, and the cell traces show it never asks AppKit to draw them.

## Two graphics bugs found while chasing the missing dropdown, neither of which was it

The user reported that Set Paragraph Style, Font Name and Font Size have no dropdown button. Chasing
it turned up two real faults in the graphics layer. Both are fixed. NEITHER fixed the dropdown, and
saying so is the point of this entry.

CGRectApplyAffineTransform RETURNED ITS INPUT. A stub, printing a line and handing back the
untransformed rectangle, called 322 TIMES in a single LibreOffice startup: every one of those is a
place where something computed where to draw and got coordinates in the wrong space. It transforms
the four corners and answers their bounding box now, which is what the documentation says and what a
rotation requires.

THE CLIP BOUNDING BOX WAS ALWAYS EMPTY. -[O2GraphicsState clipBoundingBox] is O2UnimplementedMethod,
so CGContextGetClipBoundingBox answered a zero rectangle for every context, and an empty clip is a
perfectly good reason for a caller to draw nothing at all. It now answers in user space: the clip
rectangle when one is set, the whole surface when none is, both through the inverse device
transform. O2ClipStateIntegralRect had been declared in the header since the beginning and never
defined, which is why nothing had ever noticed.

    layer_probe before   clip=0,0,0x0
    layer_probe after    clip=0,0,20x20

AND THE LAYER PATH IS FINE, which is worth recording because a first version of that probe said it
was broken. tests/buck2/gui/layer_probe.m drives the path LibreOffice uses for native controls: a
bitmap context, a CGLayer made from it, a fill into the layer, the layer blitted back. It reported
EMPTY, and the reason was the PROBE: Core Graphics puts the origin at the BOTTOM LEFT, so a rect at
(0,0) lands in the last rows of the buffer and the pixel it was reading near the top was always
going to be zero. Scanning the whole buffer shows 100 painted pixels starting at row 10, for the
layer, for the point form, for an image made from a context and for one made from raw bytes.

WHAT IS STILL TRUE: with SAL_NO_NWF=1, which turns off LibreOffice own native widget path, the
dropdowns and the dialog button bezels APPEAR. With it on they do not. So the application takes that
path, and the path produces nothing on this stack for reasons not yet found.

## THE MISSING DROPDOWN, FOUND: a combo box cell drew itself the size of the whole window

The user reported that Set Paragraph Style, Font Name and Font Size have no dropdown button. They
have one now, and the cause was not in the graphics layer at all.

    - (NSSize) cellSize {
        NSSize size = [_controlView frame].size;    /* the WHOLE VIEW */
        size.width -= 3.0;
        size.height -= 2.0;
        return size;
    }

and both draw methods opened with frame.size = [self cellSize], throwing away the rectangle the
caller had asked for. That works when a cell owns its view, one NSComboBox per combo box, which is
every cocotron application. LibreOffice draws MANY controls with ONE cell into ONE shared
SalFrameView that covers the window, so the cell asked the view how big it was and got the window:

    CIDER_COMBO asked=249x20+0+0  cellSize=1021x638  button=20x20+229+0   Set Paragraph Style
    CIDER_COMBO asked=176x20+0+0  cellSize=1021x638  button=20x20+156+0   Font Name
    CIDER_COMBO asked=78x20+0+0   cellSize=1021x638  button=20x20+58+0    Font Size

Before the fix the button rect was 638x638 at x=383, computed from a 1021 wide frame, so it landed
entirely outside the small offscreen context LibreOffice had handed over. Nothing was clipped, badly
drawn or mis-coloured: the whole native control was painted off the edge of its own bitmap. The fix
is one line in each method, deleted: draw in the rect the caller gave.

HOW THE INSTRUMENT LIED FIRST, which is the reusable part. The cell trace lived on
-[NSCell drawWithFrame:inView:] and reported ZERO cell draws in a run that drew thirty three of
them, because NSTextFieldCell and NSButtonCell override that method and neither calls super. A
trace on a base class sees only the classes that do not override it, and its silence looks exactly
like a code path that is never taken. What broke the deadlock was tracing the CONSTRUCTORS instead:
NSCell initTextCell and initImageCell are the funnel every cell passes through, and they showed
LibreOffice creating one NSComboBoxCell, one NSPopUpButtonCell, four NSButtonCells and thirty two
NSTextFieldCells. A path that creates cells and never draws them is a different bug from one that
is never entered, and only the constructor trace could tell them apart.

STILL OPEN in the same area: three NSButtonCell draws arrive with view=nil, and every bezel in
cocotron goes through [controlView graphicsStyle], which is a category on NSView. A message to nil
returns nil, so those buttons get no bezel at all. That is the alert button with a label and no
box, and it is the next thing to fix.

## A CELL CAN DRAW WITHOUT A VIEW, and until now it could not

graphicsStyle is a CATEGORY ON NSVIEW. Every bezel, arrow, check mark and slider knob in cocotron
is drawn through it, and a cell reaches it with [controlView graphicsStyle]. A message to nil
returns nil, so the moment an application draws a cell with inView:nil the whole chain goes silent:
no drawing, no error, no exception. AppKit draws into the CURRENT CONTEXT and needs no view for
any of it, and LibreOffice relies on that, so its check boxes had no box.

NSGraphicsStyleForView(view) is that same style with a nil view allowed, and nineteen cell call
sites use it instead. A nil view costs nothing: the only thing the style ever reads out of one is
the window background colour of a progress indicator.

THAT WAS NOT ENOUGH ON ITS OWN, and the second half is the interesting one. The check box still did
not appear, because the SIZE came from the same dead chain:

    imageSize = [[[self controlView] graphicsStyle] sizeOfButtonImage: image ...];

nil style, zero size, and a 9.75 by 9.75 image blitted into a rectangle of 0 by 0.

    CIDER_BUTTON_IMAGE image=NSSwitch size=9.75x9.75 rect=0x0+2+7     before
    CIDER_BUTTON_IMAGE image=NSSwitch size=9.75x9.75 rect=9.75x9.75+2+2  after

The image had been found, loaded and handed to a blit that had nowhere to put it. Note the shape of
the mistake: the first fix was correct and the symptom did not move, which reads exactly like a
wrong diagnosis. Tracing the rect rather than re-reasoning about it is what showed the second one.
docs/wayland-checkbox-and-dropdowns.png has both, the Match Case box and the three toolbar arrows.

AND ONE MORE LOST EDIT, found by the same whole-pin diff that found the wheel fix: NSView.m carried
CIDER_NO_VIEW_CACHE, the A and B switch from the memory hunt, only in the materialised tree. It is
in this patch too. The rule stands and keeps earning: diff the built pin against the live tree
before every commit that touches vendor.

## THE FIRST CLICK ON A DROPDOWN DID NOTHING, and the culprit was a tooltip twenty five points high

Clicking the Font Name arrow did nothing. Clicking it a second time did nothing. The third one
opened the list. Not a hit area: the backend log shows all three arriving at the same window with
the same coordinates.

    button pressed=true x=404 y=95 window=2      nothing happens
    pointer=enter x=1 y=3 window=12              a TOOLTIP appears UNDER the pointer
    button=dropped reason=no-window-for-surface  the second click goes to it and dies
    button pressed=true x=404 y=95 window=2      the list opens

The A and B that named it: turn tooltips off in the profile and ONE click opens the list, every
time. A tooltip in this toolkit is a float, and a click that closes a float is consumed before any
control sees it. So the question became why the tooltip was under the pointer at all, and the
answer was arithmetic:

    popup number=12 asked=528,551 parent-left=125 parent-top=660 local=403,91   before
    popup number=12 asked=528,551 parent-left=128 parent-top=685 local=400,116  after

LibreOffice had placed it correctly, twenty one points BELOW the pointer in its own bottom left
coordinates. PARENT_TOP was stored by whichever titled window was created last, and this
application creates titled windows it never shows: one of them, 1004x591 at 125,69, put the top
edge at 660 while the window on screen had its top at 685. Every popup came out twenty five points
high. For a menu that is invisible; for a tooltip it is the difference between sitting below the
pointer and sitting under it. The anchor now comes from the SAME window that is used as the popup
parent, read when the popup is made rather than remembered from a window that may not even be on
screen.

docs/wayland-font-list-one-click.png is one click on the arrow: every family drawn in its own face,
Arabic and Hebrew samples included, Liberation Serif selected. The File menu still opens under its
title, checked in the same round, and the menu test had been clicking at y=10 ever since the title
bar arrived, which is inside the chrome.

STILL WRONG, and next: an xdg_popup position is fixed when the popup is CREATED. LibreOffice makes
its dropdown windows at startup and moves them before showing, so the list appears at the position
the window had at creation, which is why it hugs the left edge of the screen instead of hanging
under its own field. That wants xdg_popup.reposition.

## A DROPDOWN NOW HANGS UNDER ITS OWN FIELD, which needed xdg_shell version 3

An xdg_popup position is decided by the positioner it was CREATED with and never changes on its
own. LibreOffice builds its dropdown list windows during startup, parks them at a default origin
and moves each one into place just before showing it, so every list appeared where its window had
been at creation: hard against the left edge of the screen.

    popup=setframe number=7 origin=125,14  size=384x602   the parked default
    popup=setframe number=7 origin=368,-22 size=384x602   where it actually goes
    popup=move     number=7 asked=368,-22  local=240,105  and now the compositor is told

The protocol answer is xdg_popup.reposition, which arrived in version 3, and this client had been
binding xdg_wm_base at VERSION 1 since the beginning. Binding at 3 is safe here: the popup listener
already declares repositioned, and the toplevel listener already declares the configure_bounds and
wm_capabilities of 4 and 5.

WHAT MADE IT FINDABLE was tracing every setFrame on a popup rather than only the ones that moved.
The first version printed on a move and printed nothing at all, which reads as "the application
never repositions its lists" when the truth was that our reposition path was dead: can_reposition
answered no on a version 1 popup and returned in silence. A trace that fires only when the
interesting thing happens cannot tell you it never happened.

docs/wayland-font-list-under-its-field.png: one click on the arrow, and the list drops from the
field it belongs to with its scrollbar, every family in its own face. The File menu still opens
under its title, checked in the same round.

## THE BLUE SQUARE WITH THE ARROW IN IT

The user named this one exactly: the toolbar selectors were missing the blue square with the arrow
down inside. With the geometry fixed they had a button, but it was the old cocotron one, a grey
chiselled bevel with a black triangle loaded from a tiff, which is the look of a different decade
and a different system. It is drawn now: a rounded rectangle in the system accent blue with a white
chevron, grey when the control is disabled and darker while it is held down. Drawing beats an image
here because an image has to exist at every size and is the wrong colour the moment the button is
not blue.

AND IT CAME OUT GREY THE FIRST TIME, which is the part worth keeping. NSComboBoxCell sets
_buttonEnabled and _isButtonBordered in initWithCoder and NOWHERE ELSE, so a cell made in code
rather than loaded from a nib has a button that is disabled from birth. Every application that does
not use nibs got the disabled colour, and LibreOffice is one. The item count rule in the add and
remove methods is left alone, so an application that empties its own list still greys the button.

docs/wayland-blue-dropdown-buttons.png, and note the Find toolbar has one too.

## THE OK BUTTON WAS NINETY THREE WIDE AND ZERO HIGH, and one stubbed metric explains it

GetThemeMetric answered ZERO and an error for every metric it was ever asked. That reads like a
harmless stub, and it is not: a caller that ignores the status lays its control out at nothing.
LibreOffice asks for exactly ONE metric, kThemeMetricPushButtonHeight, three times per print alert,
and its OK button arrived at the cell as

    CIDER_BUTTON bezel=1 bordered=1 title= frame=93x0+0+0     before
    CIDER_BUTTON bezel=1 bordered=1 title= frame=93x20+0+0    after

The table now answers the documented Aqua values for the metrics worth standing behind and keeps
the old fallback for anything else, so a caller asking for something not in the table still uses
its own idea rather than a number invented here.

A SECOND FIX IN THE SAME AREA THAT DID NOT MOVE THIS SYMPTOM, said plainly because it would be
easy to imply otherwise: -[NSButtonCell cellSize] adds up the title and the image, so a bordered
button with NEITHER measures zero high. That is wrong on its own terms and it is fixed, with the
same floors NSPopUpButtonCell already uses, but LibreOffice does not ask the cell for that height,
it asks the theme, so the button stayed 93x0 until the metric changed.

WHAT IS STILL WRONG THERE: the label reads OK in near white on a near white bezel. On Apple systems
the DEFAULT button is filled with the accent colour and its text is white, which is why LibreOffice
draws it white; our bezel is not blue, so the text vanishes into it. The cell cannot currently tell
that it is the default button, because the only signal cocotron has for that is
[[controlView window] defaultButtonCell] and LibreOffice draws with no view at all.

## A CELL DRAWN WITHOUT A VIEW NEEDS NO VIEW COMPENSATION

-[NSButtonCell getControlSizeAdjustment:] shrinks a rounded push button by ten points and moves it
up seven. The comment above it says why: a button built in Interface Builder gets a VIEW frame
larger than the bezel it wants drawn, to leave room for the shadow, so the cell compensates. An
application that draws a cell straight into a context passes the EXACT rectangle it wants filled
and has no oversized view anywhere, so the compensation is subtracted from a number that never had
it added. The adjustment is skipped when there is no control view, which is only ever the drawn
directly case.

Measured in the print alert, same crop both times: the white area of the button grew from 5085 to
5691 pixels and the bezel now fills the rectangle LibreOffice asked for instead of a smaller box
inside it.

THE INSTRUMENT THAT SETTLED IT, and it is worth keeping: CIDER_BEZEL_MAGENTA fills the bezel rect
in magenta AND fills the same rect grown by forty points in green. Filling only the frame answers
"did anything land here" and nothing else; when the answer is a single row, it cannot say whether
the rest was clipped, drawn above or drawn below. The halo showed the clip was a four row band at
the bottom edge of the button, which is what named the offset. docs/wayland-bezel-halo-control.png.

STILL WRONG, AND I DID NOT SETTLE IT: the OK label does not appear. It is drawn in near white
(measured: 19 pixels of #F2F2F2 against a #FFFFFF bezel, before the bezel grew over them), which is
what an application draws when it believes the button is the DEFAULT one, because on Apple systems
that button is filled with the accent colour and its text is white. Two explanations remain and the
evidence does not separate them: our bezel is white where macOS would be blue, or LibreOffice draws
its label BEFORE asking for the bezel and the bezel paints over it. The second is suggested by the
label disappearing entirely once the bezel grew. What would separate them is a bezel drawn at half
alpha, which is one build and one run away. Note also that the cell cannot tell it is the default
button: cocotron knows only through [[controlView window] defaultButtonCell], there is no view, and
the key equivalent is EMPTY in the trace, so LibreOffice is not marking it that way either.

## AND IT IS SETTLED: THE OK LABEL IS THERE, UNDER OUR OWN BEZEL

The entry above left two explanations standing and said what would separate them. It took one run.
CIDER_BEZEL_ALPHA draws the push button bezel at half alpha, and with it the word OK appears,
WHITE, centred, correctly sized, plainly underneath. docs/wayland-ok-label-under-the-bezel.png.

So the label is not missing, not the wrong size and not in the wrong place. LibreOffice draws it and
then something makes our bezel land ON TOP of it. The button is redrawn three times per alert, and
the halo control showed the last of those clipped to a four row band, so the likeliest shape is a
partial repaint that renders the native bezel again without the text. That is LibreOffice repaint
sequencing and it needs logging on the application side, not more guessing from here.

WHY THE LABEL IS WHITE, which now matters: it is what an application draws when it believes the
button is the DEFAULT one, since Apple systems fill that button with the accent colour. Our bezel is
white, so even with the ordering fixed the label would be white on white. Both have to be right.
The cell still cannot tell it is the default button: cocotron knows only through the window default
button cell, there is no view, and the key equivalent is empty in the trace.

The instrument stays, and it is a general one: an opaque thing that covers another cannot be told
apart from a thing that was never drawn, and half alpha separates them in a single run.

## PERFORMANCE, MEASURED AGAINST NATIVE FOR THE FIRST TIME

Every number here had been Cider against Cider, which can say whether a change helped and never how
far there is to go. The same text to PDF conversion, same machine, same input:

    native LibreOffice 25.8.5.2   0.51 s   (three runs, warm, within 0.015 s of each other)
    Cider  LibreOffice 25.2.1.2   3.63 s   BEFORE
    Cider  LibreOffice 25.2.1.2   2.87 s   AFTER the change below

Not the same binary, which has to be said rather than hidden: nixpkgs ships 25.8 and the dmg we run
is 25.2. Same task though, and the ratio went from 7.1x to 5.6x.

WHERE IT IS NOT: startup. A trivial guest program through the same launcher costs 0.175 s against
0.004 s native, and soffice --version costs 0.337 s against 0.293 s. The container and the loader
are not the problem; the work is.

WHERE IT WAS: fontconfig, 34.6 percent of the run in children and 31.4 in SELF, and inside it
FcFontMatch alone at 29.69 percent -- more than the layout, the rasteriser and the PDF filter
together. FcFontMatch walks the entire font set comparing every element of the pattern against every
candidate, and it was called 1573 times in one startup.

THE FIX IS ONE WORD IN AN OBJECT SET. The typeface names handed to AppKit are fontconfig patterns
produced by FcNameUnparse during enumeration, and Onyx2D parses them back later to find the font
FILE. The file was in our hands at enumeration and dropped on the floor, so finding it again cost a
full match per typeface. Asking FcFontList for file as well, and reading it back out of the pattern
instead of matching, took the matches from 1573 to 333.

    text to PDF          3.63 s  ->  2.87 s
    first document window 2.53 s ->  1.52 s     (backend own clock 1.86 -> 1.08)

AND THE RENDERING IS BYTE IDENTICAL, which is the check that matters for a change to font
resolution: the same window dump, compared pixel for pixel against the run before it, differs in
ZERO pixels. The fonts resolve to exactly the files they did before, only without asking twice.

TWO THINGS TRIED FIRST THAT DID NOT WORK, recorded so they are not tried again:
  A cache in front of the substitution. 281 calls, 281 MISSES: an application enumerating its font
    list asks about each family exactly once, so there is nothing to hit.
  A fontconfig cache directory inside the container. The guest has no /etc/fonts at all and
    XDG_CACHE_HOME arrives from the HOST as a path that does not exist in the container, which looks
    like a smoking gun and is not: pointing it at a guest directory changed nothing and wrote
    nothing. The cost was matching, not scanning.

## A CLOSE SHOULD NOT WALK THE DESCRIPTOR LIMIT

With fontconfig out of the way the profile named its own second: map_foreach at 15.47 percent of the
whole run, behind only memmove, and every caller was the same thing.

    map_foreach <- kqueue_closed_fd <- sys_close_nocancel <- fclose
    map_foreach <- kqueue_closed_fd <- sys_close_nocancel <- opendir
    map_foreach <- kqueue_closed_fd <- sys_close_nocancel <- rtl_bootstrap_args_open
    map_foreach <- kqueue_closed_fd <- sys_close_nocancel <- fileaccess ReconnectingFile close
    map_foreach <- kqueue_closed_fd <- sys_close_nocancel <- Python

Every close(2). libkqueue keeps its kqueues in a flat array indexed by descriptor, sized with the
process HARD limit, which in this container is 524287 slots, and map_foreach walked ALL of them: four
megabytes scanned to find the handful of kqueues an application actually has. libkqueue own comment
above kqueue_closed_fd says the function is too expensive for how often it is called and that
walking every kqueue should go; this is the cheap half of that.

The map now remembers one past the highest index ever inserted and walks only that far. It only
grows, and a walk that races an insert into a higher slot would have missed that entry anyway,
because the walk goes in index order and an insert behind its cursor is missed with or without it.

    text to PDF  2.87 s -> 2.52 s

CUMULATIVE, and against the only reference that matters:

    native LibreOffice 25.8.5.2   0.51 s
    Cider, start of the day       3.63 s   7.1x
    Cider, now                    2.52 s   4.9x

VERIFIED, not assumed: the window dump is byte identical to the run before the change, zero
unrecognized selectors, typing still gives 8 words 47 characters, and the File menu still opens with
every item. A change to file descriptor bookkeeping earns that check.

## memmove WAS THE 1990 PORTABLE LOOP, AND IT WAS THE LARGEST THING IN THE SYSTEM

With fontconfig and the kqueue map dealt with, the profile had one obvious leaf left:
_platform_memmove at 19.97 percent of ALL samples, ahead of the allocator, the loader and the font
machinery. It is the Berkeley portable implementation from 1990, a loop that moves one long at a
time, and there is no optimised variant anywhere in this tree: upstream keeps the assembly out of
the portable directory and only the portable directory was ever built.

Large forward copies use rep movsb now. Every x86-64 part since Ivy Bridge implements it as a wide
internal copy, and every one since Ice Lake makes it good for short lengths too, which is what glibc
reaches for in the same place. It copies forward only, so it is used where forward is safe -- no
overlap, or the destination below the source -- and the portable loop still handles a backward
overlapping move. Short copies keep the old path, because the instruction has a startup cost that a
handful of bytes does not amortise on every part it runs on.

    text to PDF  2.52 s -> 2.20 s

AND THERE IS A TEST THAT COULD FAIL, which for the most safety critical function in the system is
the point. tests/buck2/gui/memmove_probe.m checks 79807 cases against a byte at a time reference:
every length to 300 at every alignment pair, lengths around the floor and the page size, and OVERLAP
IN BOTH DIRECTIONS. It reports 0 failures.

THE CONTROL FIRES. Removing the overlap guard, so that backward overlapping moves also take rep
movsb, makes the same probe report 1111 failures and name them: every one is a destination above its
source. A test that cannot fail proves nothing, and this one was made to fail before it was trusted.

    CUMULATIVE, against native, one task, one machine:
        native LibreOffice 25.8.5.2   0.51 s
        Cider, start of the day       3.63 s   7.1x
        Cider, now                    2.20 s   4.3x
        first document window         2.53 s -> 1.52 s

## AND THE OTHER HALF OF memmove: SMALL COPIES

rep movsb took the big copies and left the small ones, which were still going one long at a time,
and memmove was still 10 percent of the run. Copies of 32 bytes or fewer now read BOTH ENDS and then
write both ends, in eight, four or two byte pieces that overlap in the middle.

Reading everything before writing anything has a property worth more than the speed: it is correct
for ANY overlap in either direction, because every load happens before every store. No direction
test and no second implementation for the backward case. The rep movsb floor drops to 32 with the
small path underneath it, so nothing lands on the portable loop except a backward overlapping move
of more than 32 bytes.

    text to PDF  2.20 s -> 2.07 s

Same 79807 case probe, still zero failures, and the window dump still byte identical.

    native LibreOffice 25.8.5.2   0.51 s
    Cider, start of the day       3.63 s   7.1x
    Cider, now                    2.07 s   4.1x

## memset WAS A FUNCTION CALL PER FOUR BYTES, AND THE PROBE THAT SAID IT WAS FINE WAS WRONG

_platform_memset built a four byte pattern and handed it to _platform_memset_pattern4, whose loop
calls _platform_memmove ONCE PER FOUR BYTES. Clearing a page was a thousand calls. Every memset and
every bzero in the system went through it. It is rep stosb now above 32 bytes, with the same written
out small path as memmove underneath.

HONESTLY: THIS DID NOT MOVE THE BENCHMARK. The conversion is 2.09 s against 2.07 s before, which is
noise. The profile had memset_pattern4 at about 2 percent and that is at the edge of what this
measurement can see. It is kept because a call per four bytes is indefensible and because the probe
now covers it, not because a number improved.

AND THE REAL FINDING IS THE PROBE. A one byte overwrite planted in _platform_memset on purpose was
reported OK by 19472 cases. The reason is worth more than the fix:

    for (size_t i = 0; i < length; i++) reference[off + i] = value;

CLANG TURNS THAT INTO A CALL TO memset. The reference was no longer independent of the thing under
test: both sides called the same broken function and agreed. A dump of one case showed TEN bytes of
the fill value on BOTH sides where there should have been nine, which is what finally named it.
Marking the reference destination volatile forbids the rewrite, and with that the same probe reports
the planted bug immediately and names firstdiff as off plus length.

A reference implementation compiled by the same compiler as the implementation can BECOME it. That
applies to every hand written memcpy, memmove, memset and strlen check anyone writes here.

## AND A PATCH REGENERATED AGAINST A PATCHED PIN IS NOT THAT PATCH

The libplatform patch stopped applying and the cider-src build failed with 2 of 3 hunks rejected.
The cause: after committing 0001, the pin in the store HAS 0001 applied, so regenerating 0001 by
diffing that pin against the live tree produces the DELTA SINCE 0001, not 0001. It applied cleanly
in the check, because the check applied it to the same already-patched pin.

Regenerate against a pristine pin: an older cider-src store path from before the patch existed, or
reverse the committed patch first. And the verification has to apply the WHOLE SERIES to a pristine
tree, which is what caught it.

## ITERM2: WHAT IT WOULD TAKE, MEASURED RATHER THAN GUESSED

The second north star, tried for the first time. It does not start. The interesting part is not that,
it is knowing exactly why without discovering it one dyld error at a time.

    dyld: Library not loaded: /System/Library/Frameworks/CryptoKit.framework/...

scripts/macho-needs.py reads the load commands of a Mach-O and answers the whole question at once,
which is the difference between one round trip and thirty. For iTerm2 3.6.10, x86_64 slice:

    needs=89  present=63  in-bundle=10  missing=9  weak-missing=7

THE NINE, and they fall into exactly two groups:

    /System/Library/Frameworks/CryptoKit          not in this tree, and not in Darling either
    /System/Library/Frameworks/QuickLookUI
    /System/Library/Frameworks/ScreenCaptureKit
    /System/Library/Frameworks/SwiftUI

    /usr/lib/swift/libswift_Concurrency           Swift 5.5 and later
    /usr/lib/swift/libswiftSystem                 swift-system, 5.6 and later
    /usr/lib/swift/libswiftSystem_Foundation
    /usr/lib/swift/libswiftUniformTypeIdentifiers
    /usr/lib/swift/libswiftWebKit

THE SECOND GROUP IS ONE PIN BUMP. vendor/pins/swift is version.txt 5.2.2, and its build.sh extracts
the dylibs straight out of an official swift.org release package. Every missing library there
belongs to a LATER Swift, so moving that pin forward should supply all five at once, with no new
code. That is a tractable next step and it should be taken before anything else here.

THE FIRST GROUP IS REAL WORK. SwiftUI in particular is not a stub anyone writes in an afternoon, and
a framework that loads while exporting nothing does not help: a two level namespace binds classes
and data at load time, so it fails at the first symbol the application really uses.

AND A LOCAL TRAP WORTH KNOWING. The forty four swift dylibs in the runtime tree are 131 byte GIT LFS
POINTER FILES here and real Mach-O only in the nix pin. Anything asking whether the file EXISTS
reports a complete Swift runtime; dyld disagrees. macho-needs.py reads the magic for that reason and
reported not-macho=23 before the real ones were copied in, 0 after.

The version of iTerm2 is worth stating too: the nixpkgs recipe points at the stable URL with a hash
that no longer matches what that URL serves, so the bundle here was fetched with its real hash. The
version inside it is still 3.6.10, the same as nixpkgs claims.

## ITERM2 3.4.23 LOADS AND REACHES THE RUN LOOP

3.6.10 is blocked on SwiftUI and four other frameworks nobody here has written. 3.4.23 is the last
release before iTerm2 took on SwiftUI and Swift concurrency, and the difference is not small:

    3.6.10   needs=89  present=63  in-bundle=10  missing=9
    3.4.23   needs=33  present=27  in-bundle=6   missing=0

NOTHING is missing at the library level for 3.4.23. It failed at the SYMBOL level instead:

    Symbol not found: _kTISPropertyUnicodeKeyLayoutData
    Expected in: /System/Library/Frameworks/Carbon.framework/Versions/A/Carbon

and HIToolbox had been exporting that symbol all along. Carbon is an UMBRELLA framework and
HIToolbox lives under it, so an application that links Carbon expects to reach Text Input Services
through it; the two level namespace then demands the symbol from CARBON, and exporting it from the
sub framework is not enough. Carbon re-exports HIToolbox now, one line, and LibreOffice is
unaffected: its window dump is byte identical and its startup unchanged.

With that, iTerm2 3.4.23 gets all the way to AppKit:

    cider-wayland-appkit register=ok class=NSDisplayWayland
    cider-wayland-appkit init=ok display=connected globals=22 seat=false output=true
    cider-wayland-appkit nextevent calls=3 mask=0xffffffff t=0.26

IT DOES NOT OPEN A WINDOW, and it does not crash either: the process is alive when the harness kills
it at the time limit. So the next question is what it is waiting for, not what it is missing.

THE WORK LIST IS 25 SYMBOLS, from scripts/macho-undefined.py, which reads what the binary needs and
subtracts what every Mach-O in the tree exports. Not one dyld failure per run, the whole set at once:

    CATransform3D{Concat,MakeRotation,MakeScale,MakeTranslation}   Core Animation transforms
    CGContext{Get,Set}FontSmoothingStyle                           text rendering
    CGEvent{Get,Set}Flags, CGSDefaultConnectionForThread           event and window server
    CGSessionCopyCurrentDictionary, CGWindowListCopyWindowInfo
    FSEventStream{CopyDescription,FlushAsync,FlushSync}            file system events
    GetCurrentKeyModifiers, IsSecureEventInputEnabled              Carbon input
    LS{CanURLAcceptURL,CopyDefaultRoleHandlerForContentType,...}   Launch Services
    NSAccessibilityRoleDescriptionForUIElement
    MTLCaptureDescriptor, NSSearchToolbarItem                      two classes
    _NSDictionaryOfVariableBindings, memset_pattern16

CAVEAT ON THAT TOOL, and it matters: the set difference is FLAT and the runtime is two level, so a
symbol that exists in the wrong library reads as resolved. That is exactly the Carbon case above,
which the tool did NOT report. It answers what is missing entirely; dyld still has to say what is
missing FROM THE RIGHT PLACE.

## ITERM2 IDLES IN A RUN LOOP IT DID NOT REACH THROUGH NSApplicationMain

Four probes, and the useful result is which ones stayed silent.

    seat                 headless weston has none; nested sway forwards real devices and reports
                         seat=capabilities pointer=true keyboard=true. NO WINDOW EITHER WAY, so
                         waiting for a keyboard is not what it is doing.
    NSNib entry          -[NSNib initWithContentsOfFile:] is NEVER CALLED. Not a nib that fails to
                         decode: no nib is opened at all, and iTerm2 does import
                         loadNibNamed:owner:topLevelObjects:.
    NSApplicationMain    NEVER ENTERED, although the binary imports the symbol.
    the core             all four threads blocked in libsystem_kernel, and the stack words name
                         CoreFoundation and this backend, which is what an idle run loop looks like.

So the application is running a run loop and pumping our events, and it did not get there through
the function every Cocoa application starts in. Those two facts together are the next thread to
pull, and they rule out most of what was suspected: it is not a missing library, not a nib format,
not the seat, not a hang in an RPC.

WHAT THE MAIN NIB IS, for when the nib path does become the question: MainMenu.nib is a NIBArchive,
the format Xcode has written since version 4, whose first eleven bytes are the ASCII text
NIBArchive. Cocotron NSNib reads exactly two formats, the keyed property list and the older
typedstream, and treats anything not a directory as keyed. So the nib WOULD fail if it were reached.
It is not reached yet, and saying otherwise would be inventing a cause.

Both traces are gated behind CIDER_TRACE_NIB and stay: an entry probe on a method that is supposed
to run is the only thing that separates "this failed" from "this never happened", which is the
mistake this port has now made twice.

## CORRECTION: THE NIB IS OPENED, IT IS A NIBArchive, AND IT FAILS TO DECODE

The entry above is wrong and this replaces it. It said the nib was never opened and
NSApplicationMain was never entered. Both claims came from probes that print with NSLog, and NSLog
PRODUCES NOTHING IN THIS PROCESS. I read the silence of an instrument I had never seen speak here,
which is the same mistake this port has now made three times, and this time it reached a commit
message.

The same probes with fprintf to stderr, which needs nothing but a file descriptor:

    CIDER_NIB open /Applications/iTerm.app/Contents/Resources/MainMenu.nib
    CIDER_NIB instantiate bytes=58174
    CIDER_NIB bytes=58174 keyed=1 magic=NIBArchive objectData=NIL
    CIDER_NIB NSApplication run
    CIDER_NIB finishLaunching entering delegate=nil
    CIDER_NIB finishLaunching done delegate=nil windows=0

So iTerm2 does everything a Cocoa application does. It opens its main nib. The nib is a NIBArchive,
the format Xcode has written since version 4, whose first eleven bytes are that ASCII text.
Cocotron NSNib knows two formats, the keyed property list and the older typedstream, and assumes
keyed for any file that is not a directory, so the keyed unarchiver is handed a NIBArchive and
returns NIL. Nothing raises. No object graph, so NO DELEGATE and NO WINDOWS, and the application
then runs its loop forever in perfect health with nothing on screen.

THE BLOCKER IS A NIBArchive READER. That is a real piece of work and a well defined one: header,
object table, key table, value table, class table, then rebuilding the graph the same way the keyed
path already does.

TWO THINGS TO KEEP FROM THE HUNT. Probes print with fprintf and fflush from now on, because a probe
that depends on Foundation cannot report on a process where Foundation is what is in question. And
finishLaunching is now reached from the first event pump as well as from -run, which is correct on
its own terms: an application with its own loop still has to be told it launched. It changed nothing
here, because iTerm2 does come through -run, and LibreOffice is unaffected either way: byte
identical dump, unchanged startup.

## THE XNU LOG IGNORED ITS OWN LEVEL AND HAD REACHED 5.2 GIGABYTES

The hook the emulation calls to log took a level argument and threw it away, printing every message
including debug. The waitq and mach message layers call the debug macro on every link, unlink,
prepost and receive, which is a write syscall per line for the busiest code in the system.

    683 KB written in a twenty second LibreOffice run
    5.2 GB sitting in the prefix

A log nobody reads that fills a disk is worse than no log, and this machine has been wedged once by
a full filesystem already. Warning and above by default now, with CIDER_XNU_LOG=debug, info,
warning, error or none to move the floor without a rebuild.

    155 KB in a THIRTY FIVE second run, so about six times less per unit of time

What survives is worth keeping and worth someone reading: 859 of Trying to lock mutex without an
active thread and 859 of the unlock counterpart in one startup, plus 430 of an unimplemented thread
policy flavour. Those are real warnings that were buried under the debug flood.

Verified: byte identical window dump, zero unrecognized selectors, startup unchanged at 1.52 s.

## THE THREE CRITERIA, RE-CHECKED AT THE END OF 2026-08-15

Fifteen commits today, including memmove, memset, the kqueue map and libSystem, so all three were
checked again on the final build rather than assumed.

    RENDERS      the window dump is byte identical to the one inspected this morning, and that one
                 was looked at: menu bar, blue dropdown buttons, Match Case check box, ruler, page,
                 status bar, find bar
    INTERACTIVE  typing gives 8 words 47 characters in the status bar and the text is on the page,
                 the File menu opens under its title with every item and shortcut
    RESIZABLE    700x600 and 1150x640, relaid out both ways, toolbar overflowing to the chevron at
                 the narrow size and fully expanded at the wide one

Zero unrecognized selectors in every run.

## A DIALOG IS A WINDOW WITH NO MINIMISE BUTTON, NOT ONE THAT CANNOT BE RESIZED

The Options window is the biggest dialog LibreOffice has: a tree of twenty sections, a page of
fields, check boxes, and a button row. It came out with its right third off the edge of the screen,
because the rule for what counts as a dialog was too narrow.

The old rule was "titled and not resizable". That caught the save prompt, style 0x3. The Options
window is style 0xb, titled and closable and RESIZABLE, so it was treated as a document window: a
tiling compositor gave it half the screen, LibreOffice refused to lay its 967 wide content out into
a 628 wide tile, and the buttons went off the edge. It also got a full LibreOffice menu bar drawn
across the top of it, File through Help, inside a preferences dialog.

MINIATURIZABLE IS THE SIGNAL, and it is the one macOS itself uses: no dialog has a minimise button,
whatever else it has, and a document window has all four bits. Unresizable is a special case of it,
so the save prompt is still caught. Both places that decide this now use the same test, and they
have to: a window that is a dialog for placement and a document for its menu bar gets the worst of
both.

    role number=12 style=0xb dialog=false titled=true    before, tiled and clipped
    role number=12 style=0xb dialog=true  titled=false   after, floated at 967x658

docs/wayland-options-dialog.png. The whole tree, every field, the check boxes with their marks, the
Select buttons, and Reset, Apply and Cancel along the bottom. Checked for regressions in the same
round: the document window keeps its menu bar, and the save panel still floats centred with a name
typed into it and no menu bar of its own.

STILL WRONG IN THAT PICTURE, and it is the bug from this morning: the fourth button, the default
one, is an empty box. Its label is white on our white bezel.

## AND THE PATCH REGENERATION TRAP CAUGHT ME A SECOND TIME

Same day, same mistake, documented above and repeated anyway: 0071 was regenerated by diffing
against a store pin that already had 0071 applied, so what landed was the delta since 0071, and
cider-src failed with 3 of 4 hunks rejected. The rule is not "regenerate against a pristine pin"
in the abstract, it is: FIND A cider-src STORE PATH FROM BEFORE THAT PATCH EXISTED and diff against
that one. They are all still in the store; grep them for a marker the patch adds and pick one that
does not have it.

## THE INVISIBLE BUTTON LABEL IS alternateSelectedControlTextColor, AND IT IS DRAWN ON TOP

Two corrections and one identification, all from the colour probe, which assigns every system colour
a unique bright value and prints the name next to it.

    Reset   Apply   Cancel   drawn in one probe colour
    OK                       drawn in ANOTHER: #E87F9D, which the log names exactly

    cider-wayland-color name=alternateSelectedControlTextColor probe=0.9067,0.5,0.6167

232/255, 127/255, 157/255. That is the match, and it is not close to any other name in the run.

SO THE LABEL IS DRAWN, AND IT IS DRAWN ON TOP OF OUR BEZEL. In the probe run the OK label is plainly
visible over the white bezel. The earlier entry said the label was underneath and that the half alpha
probe had settled it: that was wrong. Half alpha cannot distinguish white text under a white bezel
from white text on top of one, because both come out white either way, and I read it as proof.

THE SECOND CORRECTION: it is not white in the Options dialog because nothing is drawn there. It IS
drawn, in a colour that happens to be white in the real palette, which is why the region has no
pixels that differ from the bezel. Three buttons next to it are drawn in controlTextColor and are
perfectly visible.

WHY THIS IS NOT A ONE LINE FIX. alternateSelectedControlTextColor is white on macOS and correctly
white here: it is the text colour for an emphasised background. LibreOffice uses it for its DEFAULT
BUTTON text and expects that button to be filled with the accent colour, which on macOS happens
because AppKit knows which cell is the window default button. LibreOffice tells us nothing: all four
buttons arrive with identical cell state, no title, no key equivalent, no view, state 0, and only
their widths differ. There is no signal to key on, and inventing one would be a guess dressed as a
fix.

WHAT WOULD ACTUALLY FIX IT: a way for the native control draw to learn that a button is the default
one. That is a LibreOffice side question, and the answer is in how its macOS backend passes
ControlState::DEFAULT into the cell it paints with.

docs/wayland-default-button-colour-probe.png is the picture that names it.

## AND THE SIGNAL WAS THERE ALL ALONG: THE RETURN KEY

The entry above says LibreOffice gives no way to tell which button is the default one, that all four
arrive with identical cell state, and that inventing a rule would be a guess. That was wrong, and
the reason it was wrong is the fourth instrument failure of this session.

Two of the traced lines were identical in every visible character and yet did not collapse under
uniq. The difference was invisible:

    ... defaulted=0 key=^M frame=93x20+0+0     the default button
    ... defaulted=0 key=   frame=93x20+0+0     the others

A CARRIAGE RETURN in the key equivalent. The log printed the string raw, and a control character
does not show: it moves the cursor. So a signal that was in every run of this hunt was read as its
own absence, and I wrote that absence into a commit.

THE RETURN KEY IS THE macOS CONVENTION for the default button, and LibreOffice follows it.
-[NSButtonCell drawBezelWithFrame:inView:] now asks the window OR the key equivalent, which needs no
view at all, and the default bezel is filled with the accent colour instead of being a white box
inside a black ring, which was a much older macOS. White label on accent blue is exactly what
LibreOffice expects, because it draws that label in alternateSelectedControlTextColor.

    keychar=13 twice, keychar=0 forty two times, in one Options dialog

VERIFIED IN THREE DIALOGS, all looked at rather than counted: Options shows Reset, Apply and Cancel
white with dark labels and OK blue with a white one; the print alert shows a blue OK that can be
read for the first time; the save panel shows a blue Save beside a white Cancel, and it still writes
the file, cider-typed-name.odt, 9699 bytes. Zero unrecognized selectors in every run.

AND THE TRACE IS FIXED SO IT CANNOT HAPPEN AGAIN: the key equivalent prints as a character CODE.
A probe that renders a control character raw can hide the very thing it was added to find.

## COMMAND P NO LONGER KILLS THE APPLICATION

Printing has died on dismissal since it first drew a dialog, and the log said only

    Terminating app due to uncaught exception, reason: index (0) beyond array bounds (0)

which is a true statement about an empty array and useless: there are hundreds of arrays. What
named it was an instrument that was already in the runtime and had never been used here:

    OBJC_PRINT_EXCEPTION_THROW=YES

Apple objc4 prints a full symbolised backtrace at every throw, and it works through @throw, which
-[NSException raise] does not see. Two blockers, one after the other, both ours:

    -[NSPopUpButtonCell selectItemAtIndex:]   checked for negative and not for too large, so
                                             selecting item 0 of an EMPTY popup raised. AppKit
                                             deselects instead, which is what an application relies
                                             on while it is still filling the menu.
    -[NSPrintPanel addAccessoryController:]   did not exist. It is how a Cocoa application puts its
                                             own options into the print dialog, and LibreOffice does
                                             exactly that. doesNotRecognizeSelector raises, nothing
                                             in that chain catches it, and the process went down.

Both fixed. Command and P now shows the No default printer found alert, and clicking OK returns to
the document with the text, the caret and the word count intact: docs/wayland-print-survives.png,
and the process is still alive when the harness kills it at the time limit.

PRINTING STILL DOES NOT PRINT, and this does not claim otherwise. There is no printer and no spooler
in the container, so the alert is the correct outcome; what changed is that the alert is now the
END of the story rather than the last thing before losing the document. The accessory controllers
are stored and handed back but the panel does not display them yet, which is a gap and is written
in the header rather than papered over.

THE INSTRUMENT IS THE LASTING PART. OBJC_PRINT_EXCEPTION_THROW belongs in the list at the top of
this file: it names the raise site of anything that throws, through @throw and objc_exception_throw
alike, with symbols, and it needed no code from us at all. A backtrace was also added to
-[NSException raise] on the way, which is worth keeping for the raises that DO go through it.

## NO MENU ITEM HAS EVER RUN ITS COMMAND, AND NOW THEY ALL DO

This is the largest functional hole found in the port so far, and it was hiding behind a criterion
that had been called met. Menus were verified as OPENING. Nobody had verified that choosing an item
from one DOES anything, and it did not: Format then Character opened nothing, by mouse and by
keyboard alike, with no exception, no unrecognised selector and no log line.

The instrument is two lines in the tracking loop, behind CIDER_TRACE_MENU, and it named the bug on
its first run:

    CIDER_MENU stack depth=2 [0 NSMainMenuView sel=5] [1 NSSubmenuView sel=8]
    CIDER_MENU track item=Format enabled=1 action=menuItemTriggered: target=SalNSMenuItem

Selected index 8 of the SUBMENU is Character, and it is right there in the stack. What was sent was
FORMAT, the menu bar item that opened the menu. item is assigned the moment the mouse comes up on
the menu bar, which is what opens a menu at all, and nothing ever replaced it. LibreOffice reads
that action as open the menu, so every command in every menu did nothing, silently.

The item now comes from the DEEPEST open menu when there is more than one, and a parent is skipped:
an item that owns a submenu is not a command, and firing it would reopen the menu just closed.

    CIDER_MENU track item=Character… action=menuItemTriggered:

docs/wayland-character-dialog.png is the result: five tabs, the family list with Liberation Serif
selected, typeface and size with their blue dropdowns, the language row with a Features button, the
preview, and Help, Reset, Cancel and a blue OK. None of that had ever been reachable.

WHAT THIS SAYS ABOUT THE CRITERIA. Interactive was called met on typing, key equivalents, menu
opening, clicking and dragging in the document, and the toolbar dropdowns. All of those are true and
none of them covers a menu item. A criterion is only as good as the actions actually driven, and
the honest way to hold it is to keep adding actions until one fails, which is what happened here.

## AND THE FIRST THING BEHIND THE MENUS IS BROKEN: INSERT IMAGE BLANKS THE DISPLAY

With menu items working, four commands that had never run were driven. The first one broke, and it
breaks hard: Insert then Image opens the file picker and THE WHOLE SCREEN GOES BLACK. Every
screenshot after it is uniformly zero, and the session never recovers.

WHAT IS NOT WRONG, which took the buffer dump to establish and is the reason this is not a drawing
bug at all:

    window-2   1256x684  mean 0.94   the document, correct
    window-24   234x456  mean 0.88   a popup, correct
    window-25   500x422  mean 0.96   THE FILE PICKER ITSELF, correct

docs/wayland-file-picker-buffer.png is that picker, drawn properly, at the moment the screen shows
nothing. The application is painting; the compositor is not showing it.

WHAT THE COMPOSITOR SEES: nothing at all. Asking sway for its tree before and after is the whole
story.

    before   con org.libreoffice.sc Untitled 1  0,0 1256x684
    after    the workspace is EMPTY

The document window was never hidden and never invalidated from our side; the traces added here say
so by name. The picker is hidden five times over, the first while it is still visible.

AND THE APPLICATION IS NOT FROZEN, IT IS SPINNING:

    nextevent calls=1198200 t=89.71

about twenty thousand calls a second. A modal session polls with a date that has already passed, the
wait cap keeps the short wait as it is supposed to, and the loop runs flat out. Whether the spin
starves the connection or the surfaces go away for another reason is not established, and this does
not claim it is.

TRIED AND REVERTED, recorded so it is not tried again: servicing the connection from the re-entrant
pump. The theory was that a modal session leaves only the nested pump running and skipping it
freezes everything. It changed nothing, because the failure is a spin rather than a freeze, and
dispatching events from inside an event handler is exactly the re-entry that guard exists to
prevent. A change that fixes nothing and can corrupt a heap is not worth keeping. What stayed is the
counter: the old trace printed once and could not distinguish one re-entry from a million.

## THE BLACK SCREEN IS A PROTOCOL ERROR, AND HERE IS THE WIRE

WAYLAND_DEBUG names it in one run. The whole sequence, from the file picker mapping to the
connection dying, is nine lines:

    xdg_toplevel#102.configure(500, 422, array[4])      the picker
    xdg_surface#96.configure(67)
     -> xdg_surface#96.ack_configure(67)
    xdg_toplevel#19.configure(1256, 684, array[16])     the document
    xdg_surface#18.configure(69)
     -> xdg_surface#18.ack_configure(69)
     -> wl_surface#101.attach(wl_buffer#104, 0, 0)      the picker, its own buffer, committed
     -> wl_surface#17.attach(wl_buffer#20, 0, 0)        the document, committed
    wl_display#1.error(xdg_wm_base#5, 4, "wrong configure serial: 67")

A protocol error is FATAL: the compositor drops the client and every surface with it. That is the
black screen, the empty workspace, the correct buffers and the twenty thousand a second spin, all
four at once, and none of them is a separate bug.

WHAT DOES NOT EXPLAIN IT, tested rather than argued: each configure is acknowledged immediately, on
the surface that sent it, with the serial it sent, and the pairing is right (xdg_surface#96 does
belong to wl_surface#101, and #18 to #17). The ids are RECYCLED, which is worth knowing: xdg_surface
id 96 is created late in the run, long after other objects have come and gone.

AND ONE HYPOTHESIS TESTED AND REJECTED, kept because it is right on its own terms: the configured
flag was set once at creation and never cleared when a surface is unmapped. An unmapped surface
starts again, and attaching before the new configure is acknowledged is a protocol error. It is
cleared now in -hide and on popup dismissal. It did NOT fix this, and saying so is the point: the
same error, with the same serial, at the same place. The document window is byte identical, the File
menu still opens, typing still gives 8 words 47 characters.

AND THE GREP THAT LIED, again: the first search for destroyed objects found nothing because
WAYLAND_DEBUG writes wl_surface#17 and the pattern said wl_surface@17. Same shape as the carriage
return in the key equivalent: the instrument was fine and the question was malformed.

## AND THE UNMAP IS THE THING: A TOPLEVEL THAT COMES BACK NEEDS A NEW ROLE, NOT A NEW BUFFER

The wire log, with the noise removed, is the whole lifecycle of the file picker and it ends in the
error every time:

    2330  get_xdg_surface(new id xdg_surface#96, wl_surface#101)
    2331  xdg_surface#96.get_toplevel(new id xdg_toplevel#102)
    2335  wl_surface#101.commit()                 the empty commit that asks for a configure
    2344  xdg_surface#96.configure(66)
    2345  xdg_surface#96.ack_configure(66)
    2354  wl_surface#101.attach(wl_buffer#104) + commit        mapped, and correct
    2392  wl_surface#101.attach(nil) + commit                  UNMAPPED
    2451  xdg_surface#96.configure(67)
    2452  xdg_surface#96.ack_configure(67)
    2459  wl_surface#101.attach(wl_buffer#104) + commit        remapped
          wl_display#1.error(xdg_wm_base#5, 4, "wrong configure serial: 67")

Every step of that is what the protocol asks for read literally, and it still dies. The unmap at
2392 is what makes the difference: a surface that has been unmapped is RESET, and the compositor
does not consider the configure it sends afterwards to belong to the same generation. Clients that
hide and show a toplevel do not do it this way. They DESTROY the xdg_toplevel and the xdg_surface,
and build new ones when the window comes back.

So the fix is a change of strategy in this backend, not another guard: hide should destroy the role
objects, show should create them again and go through the initial configure. That is the next piece
of work and it is a real one.

TWO GUARDS TRIED AND KEPT, NEITHER OF WHICH FIXED IT, said plainly:
  the configured flag is cleared when a surface is unmapped, because an unmapped surface really does
    have to be configured again before a buffer may be attached
  an unmap that changes nothing is skipped, which took the picker from EIGHTEEN unmaps in one modal
    session to one
Both are correct on their own terms and both leave the error exactly where it was, same serial, same
place. Neither is a fix and neither is presented as one.

Regressions checked after both: document window byte identical, startup 1.52 s, the File menu opens,
the save panel still writes its file (9703 bytes), zero unrecognized selectors.

## AND THAT IS THE FIX: HIDE DESTROYS THE ROLE, SHOW BUILDS IT AGAIN

The previous entry says what the answer has to be, and it is. Hiding a window no longer attaches a
null buffer. It destroys the role objects in the order the protocol requires -- the xdg_toplevel or
xdg_popup first, then the xdg_surface, then the wl_surface -- and drops the backing. Showing it
again finds no surface and runs create_surface, which is the same code that built it the first time
and does the whole handshake: empty commit, wait for the configure, acknowledge, attach.

    protocol errors  1 -> 0
    screen after Insert then Image   mean 0 -> mean 0.926

docs/wayland-insert-image-survives.png is the document window after that command: menu bar,
toolbars, blue dropdowns, ruler, page, status bar, find bar, all intact. The blackout is gone.

WHAT IS STILL NOT RIGHT, and it is a different bug: the picker maps and is hidden again within a
couple of seconds, so it is not usable yet. The modal loop that spins at twenty thousand nextEvent
calls a second is still spinning. Insert then Image no longer destroys the session, which is what
this fixes; it does not yet insert an image.

REGRESSIONS, all re-run because this changes the lifecycle of every window in the port:
    document window      byte identical dump, startup 1.52 s
    File menu            opens with every item, typing gives 8 words 47 characters
    save panel           floats, takes a typed name, writes cider-typed-name.odt at 9701 bytes
    Options dialog       floats at its natural size, whole tree, blue default button
    resize               three configures applied, 700x600 and 1150x640 relaid out
    zero unrecognized selectors and zero protocol errors in every one of them

## AUTHENTIC IS A SEPARATE AXIS FROM WORKING, and the user reads it faster than any check

2026-08-15. Six observations arrived while the loop was working, each one a sentence, each one
real: the menu bar and the items are spaced wrong, macOS has separators, menus are translucent and
rounded, the highlight is rounded, there is more air; the combo boxes and check boxes are not
rounded; Reset, Apply, Cancel and OK are not rounded; the Options window is not rounded and its
title is not bold; the tree selection is grey where macOS is light blue; the traffic lights sit too
far in.

Five of the six were fixed in four commits, and the interesting part is that three of them had ONE
cause each, none of which was a styling constant.

THE FONT METRIC. Cancel and Open in the file picker were drawn cut through the middle of their own
letters. The bezel was whole, so the clip was the title rect, and the title rect was nine points
tall for a font whose glyphs need seventeen. -[NSFont defaultLineHeightForFont] is
round(ascent + descent + leading) and the descent arriving there was NEGATIVE: KTFont_FT returned
face->descender straight from FreeType, where Core Text is the other convention. One negation, and
every string AppKit lays out got taller -- menu items went from fourteen points to twenty one, which
is most of what "more space around them" asked for.

THE SUBMENU ARROW. Every submenu had a tick beside it that looked like an apostrophe. The arrow
column was five points wide and the drawing insets it by its margins, two each side, so the triangle
that reached the screen was ONE point wide. The column is fourteen now and the triangle four by
eight.

THE MIDDLE BAND. Reset, Apply and Cancel were white rectangles with a grey line above and below and
no sides. The bezel rect an application asks for is ten points wider than the button it shows, and
the view-less path skipped the whole size adjustment, so the rounded ends were five points outside
the visible area at each end. The vertical half of that adjustment is still skipped, because it is
what patch 0068 removed for good reason.

AND ONE MECHANISM WORTH KEEPING: TRANSPARENCY. A menu on macOS is rounded and translucent, which
means the pixels outside the shape have to be nothing at all. A transient window now gets an
ARGB8888 buffer instead of the XRGB8888 the protocol guarantees, cleared to zero rather than to
light grey, and the corners of every decorated window are punched out in present() -- in the PIXELS,
because the top corners of a window are painted by the frame and the bottom ones by the application
content, so anything AppKit rounds the content would square off again. The mask samples coverage
four by four and only scales a pixel that is still fully opaque, which is what makes it safe to run
on every present rather than fading its own corners away one frame at a time.

Proved in the buffer before it was believed on screen, with CIDER_WAYLAND_DUMP:
    window-24 (a menu)     corner 00000000, three pixels in fff5f5f5
    window-2 (a document)  ffececec everywhere, untouched

A CATALOG COLOUR CANNOT BE ASKED FOR A VARIANT OF ITSELF. The first translucent menu came out
BLACK, which is a cleared surface with nothing drawn on it: the fill was
[[NSColor menuBackgroundColor] colorWithAlphaComponent: 0.94] and that answered something the fill
ignored. Colours for drawn shapes are built from components here.

STILL NOT AUTHENTIC, and named so it is not forgotten: there is no backdrop blur behind a menu, so
translucency shows the toolbar sharply where macOS shows it smeared. Nothing else on the user list
is outstanding.

## TWO JOURNEYS THAT GO ALL THE WAY THROUGH, and what they cost

2026-08-15. A menu that opens is not an application that works. Two complete user journeys now run
end to end, each driven through the compositor with a real pointer and a real keyboard:

OPEN A FILE. Command O, the picker maps at 500x422, click a row, click Open, and the document opens
in its own window. sway reports both: cider-typed-name.odt and cider-open-me.odt, side by side,
845x1388 each.

INSERT A PICTURE. Insert, three Downs, Return, the picker maps, click the PNG, click Open, and the
image is decoded, placed in the page with selection handles, and the toolbar becomes the image
toolbar: anchor, wrap, align, filter, transparency. docs is where the screenshot goes if it is ever
needed again; the run is scratchpad/run-lo-image.sh.
  A MENU ITEM IS COMMITTED WITH THE KEYBOARD, not with a second click. A second click on an open
  menu dismisses it, which is why the first attempt reached the picker zero times out of two while
  the working command runner had been walking with Down and committing with Return all along.
  The harness clicks a row by pixel offset, so a new file in the directory shifts every row: one run
  selected the directory bin and LibreOffice answered Unknown image format, correctly.

WHAT THE PICKER COSTS, measured because it felt slow. The call counter in the backend said

    nextevent calls 13000 -> 2751400 over 142.7 s = 19189 per second

and a dladdr backtrace at the point of the call named the caller: AquaSalInstance::AnyInput, under
Scheduler::CallbackTaskScheduling, under AquaSalTimer::callTimerCallback, under DoYield, under
Application::Execute. It asks for an event with a date that has ALREADY PASSED, nineteen thousand
times a second, and each of those was getting a full pass of the backend and of AppKit.

Raising the event wait cap from 16 ms to 50 changed the cost by three percent, which is the proof
that nothing was waiting: the cap bounds a wait that happens, and none did.

    getenv                        21.7 percent of all samples, gone: env_flag reads once
    [NSScreen screens]            an NSScreen, an NSArray and a printed line per visible window per
                                  pass, now built once per output size
    deliver_pending_configures    cloned the window list and read the clock per window, now scans
                                  under the lock and allocates only when there is work
    the AppKit housekeeping sweep four sweeps of every window per pass, eight hundred thousand
                                  message sends a second with forty windows, now skipped for a poll
                                  that arrives within 2 ms of the last one
    the manufactured idle event   an NSEvent allocated to mean nothing, now nil for a poll

    picker open  62 percent of a core -> 45.  idle 2.6 percent, unchanged.  startup 1.521 s.

Still true: LibreOffice polls nineteen thousand times a second while a system dialog is open. Making
each poll cheap is not the same as not polling, and the remaining 45 percent is mostly its own
scheduler and yield mutex on the way to asking.

AND A WINDOW THAT ARGUES ABOUT ITS SIZE GETS NUDGED. A document opened into a tiled slot came up
laid out for the size it wanted: find bar across the middle, grey below it. Everything measurable
said the window was fine -- frame 845x1388, content view 845x1338, delegate implements
windowDidResize, pixels drawn. The line that mattered was setframe asked=1024x690 current=845x1388:
the application argued, this backend overruled it, and that is correct and not enough. The nudge
that makes LibreOffice lay out again -- one row short, then the true size -- was gated on
bottom_row_is_clear, which only sees a window nobody painted. LibreOffice paints. The signal is the
argument, not the pixels, so set_frame records it and two frame changes are delivered regardless of
what the window looks like.

AND THE STARTUP FAILURE IN THE README IS GONE. It claimed one start in sixty failed with a SIGFPE or
a start-stack mmap failure. Measured with the container torn down between attempts: 420 cold starts
and 140 warm shells, zero failures. If the rate were still one in sixty the chance of that is about
one in a thousand, so the entry went.

## THE MENUS ARE MAC MENUS NOW, and the clipboard was already there

2026-08-15, later. Three more things the user named, and one they asked for.

THE APPLICATION NAME IS BOLD, which is the only bold title in a Mac menu bar. Drawing it took four
lines. Getting a bold FONT took the rest: boldSystemFontOfSize converts the system font through
fontFamilyWithTypefaceName, the system font is called San Francisco, the typefaces this backend
publishes are named with fontconfig patterns, and no family matched -- so the conversion returned
the SAME font and everything that asked for bold silently got regular, including the window titles
made bold an hour earlier. Ask the family directly, and test traits as BITS: typefaceWithTraits
compares the mask for EQUALITY and a real face carries bold AND unitalic, so asking for the bold bit
alone matches nothing that exists.

KEY EQUIVALENTS LOOK LIKE MAC ONES, after three faults in a row:

    the modifier was spelled Ctrl+ through the Windows modifier map
    Command is the DEFAULT modifier and NSMenuItem initialised the mask to zero, so Hide, Hide
      Others and Quit drew as a bare H, H and Q
    the key NAME came from a plist keyed by character, so a function key -- a character in the
      private use area -- matched nothing and the raw character was appended, which draws as
      nothing: Insert Table showed Ctrl+ with no key after it

And then the symbols did not draw either. MEASURED: the Command symbol is ZERO points wide in the
menu font, so the string was laid out into a rect measured without it and only the letter survived.
CIDER_TRACE_FONTS names the face, TeX Gyre Heros, a Helvetica clone with no Command glyph, and a
probe over five characters showed every other one measuring fine. So the key equivalent, and only
that, is drawn in the first family that measures the symbol wider than nothing -- DejaVu Sans here.
If no family has it the text forms go in, and that decision is a measurement rather than a font
name.

THE HELP MENU SEARCHES EVERY MENU, which is a real macOS feature. Typing in the open Help menu
collects a query, the first row shows it, and the rows under it are the matching items from every
menu -- the ORIGINAL items, not copies, because LibreOffice reads a pointer off the sender of
menuItemTriggered. A correction to the commit that added it: it does NOT need a Down first. With
CIDER_TRACE_MENU the stack at the moment the letter arrives is already
[NSMainMenuView, NSSubmenuView(Help)]; the run that suggested otherwise had clicked Tools.

AND THE CLIPBOARD, which nobody had checked since the port and which is a criterion in its own
right. Both directions work: Command C in the document and wl-paste on the compositor side reports
four types and the right text; wl-copy on the compositor side and Command V puts that line in the
page. Copy and paste inside the document works too.

STILL A STUB WITH A NOTE ON IT: NSSetFocusRingStyle now draws a ring rather than printing, and the
call is reached, but no ring has been SEEN in a LibreOffice dialog -- probably the same overpainting
that owns the white box above a focused field.

## SHOULD COCOTRON BE BUNDLED RATHER THAN PATCHED, measured

2026-08-15. The question came from the user after the eighty sixth patch. The numbers first, because
the answer follows from them:

    86 patch files, 8,092 patch lines, 5,044 of them ADDED lines
    137 files touched out of 1,327 in the pin, which is 10.3 percent
    the pin is 16 MB
    upstream cjwl/cocotron: last pushed 2015-11-06, eleven years cold
    our upstream darlinghq/darling-cocotron: alive but only just, last commit 2026-06-06, and the
      recent ones are Fedora build fixes for a build system this fork does not use

And the cost that is paid every single commit: a patch has to be regenerated against a REFERENCE
TREE built by applying the whole series to a pristine fetch, then verified by applying it to a copy
and diffing. That is minutes per commit and it has a whole memory entry about the ways it goes
wrong.

THE REPOSITORY ALREADY HAS THE PATTERN AND THE RULE. vendor/pins/ciderd is checked into git with a
VENDORED.md that says why: so its sources can be edited in-tree WITHOUT THE PATCH FILE INDIRECTION.
The de-vendoring rule this fork wrote down is patch live Apple upstreams, bundle dead ones.
Cocotron is a dead upstream by that test.

So: bundle it. The mechanical shape, kept deliberately small:

    git add vendor/pins/cocotron with the 86 patches already applied
    delete vendor/patches/cocotron and the manifest entry in nix/submodules.json
    add vendor/pins/cocotron/VENDORED.md naming darlinghq/darling-cocotron and the base commit
      c8d38d16a9f613d300157bebbab2b9501bc0c274, with the patch series preserved in git history
    the 710 cocotron references in vendor/src/BUCK keep working, but NOT because nothing moves

NOT DONE IN THIS SESSION, on purpose: it puts 16 MB and 1,327 files into the repository in one
commit, and the thing it has to be verified against is the nix endpoint, which is the expensive
build. It wants its own session with the checks run, not the tail of a long one.

## THE INTERFACE FONT IS INTER NOW, WHEN THE MACHINE HAS IT

2026-08-15, task #113. The interface resolved to TeX Gyre Heros, a clone of Helvetica, which is the
face Apple REPLACED with San Francisco in 2015: it renders perfectly and it is a decade out of date.
Inter is the closest open source face to San Francisco, and the hook to prefer it already existed --
_CiderPreferredFamilies rewrites the Apple family names before fontconfig sees them, so that an
unknown Apple family does not silently become DejaVu Sans. Inter goes at the front of that list.

Because it is a fontconfig FAMILY LIST, the first family present wins: a machine without Inter gets
exactly what it had. Verified both ways in one session -- with a scratchpad fontconfig that adds the
nixpkgs inter store path, the menu bar is visibly not Helvetica any more; without it, the same run
is byte for byte the old face. Inter also has U+2318, so the Command symbols draw in the interface
font rather than through the DejaVu fallback.

Not done: shipping Inter with the runtime, which means adding it to the package and having the
launcher point FONTCONFIG_FILE at a generated configuration that includes the system one.

## AND THE COCOTRON VERSION, WRITTEN DOWN BEFORE IT IS BUNDLED

Task #114 will check the tree into git and delete the patch series, so the fork point has to survive
somewhere a git range can use it:

    upstream   https://github.com/darlinghq/darling-cocotron
    base rev   c8d38d16a9f613d300157bebbab2b9501bc0c274
    taken      2026-08-15; upstream head that day was the 2026-06-06 merge of the Fedora 44 fix
    ancestor   cjwl/cocotron, last pushed 2015-11-06, which is the dead original

Catching up later is then git log base..upstream against darling-cocotron and a merge of what
matters, rather than archaeology. The VENDORED.md that lands with the bundle carries these four
lines verbatim.


## A CORRECTION TO THE BUNDLING PLAN, before anybody follows it

The entry above says the path does not change. That is wrong in a way that matters, and the
correction is the useful part:

    vendor/src is GITIGNORED and is explicitly EXCLUDED from the nix source in cider-src.nix, with
      a comment saying it is hundreds of megabytes and would rehash every build. The patched tree
      cannot be checked in where it lives today.
    a bundled pin lives at vendor/pins/<name>, in git, with NO entry in nix/submodules.json. That
      is the whole mechanism: baseSrc is the repository tree, and only pins WITH manifest entries
      are overlaid on top of it. vendor/pins/ciderd is the precedent.
    cocotron has no per-pin BUCK. Its rules are in the single generated vendor/src/BUCK and name
      cocotron/... paths, so vendor/src/cocotron still has to EXIST after bundling.

So the missing step is the third one: scripts/buck-src.nu materialises vendor/pins/<name> into
vendor/src/<name> from the MANIFEST, and it has to learn to copy an in-tree pin when there is no
manifest entry rather than trying to fetch it. Everything else is as described, and the fork point
that has to reach VENDORED.md is written above.

## COCOTRON IS SOURCE NOW, and the step that plan missed

2026-08-15, task #114 done in commit c7adfb57. The tree is checked in at vendor/pins/cocotron with
the 86 patches applied, the manifest entry is gone, vendor/patches/cocotron is deleted, and
VENDORED.md carries the fork point so upstream fixes are still a git range.

THE STEP THE PLAN MISSED, and it is the useful part of the entry: a bundled pin still has to REACH
vendor/src. The generated vendor/src/BUCK names cocotron files there and knows nothing about where
they came from, so BOTH materialisers had to learn about a pin with no manifest entry:

    scripts/buck-src.nu    copies an in-tree pin instead of printing no submodule entry and exiting
    ciderBuck2Graph.nix    materializePins gained an EXPLICIT bundled list, not a scan of
                           vendor/pins, because the two bundled pins want opposite treatment:
                           ciderd carries its own BUCK and builds in place, cocotron is compiled by
                           vendor/src/BUCK and must be copied

Skipping the second one fails at analysis with

    Source file cocotron/AppKit/include/AppKit/AppKit.h does not exist as a member of package
    root//vendor/src

which is what the first attempt did, and is why the verification order matters: the materialised
tree diffed against the old one first, then buck2 over the four frameworks, then the nix pinsTree
derivation, then the pin checks, then the application itself.

What is NOT verified: a full nix endpoint build. pinsTree is the derivation that consumes the pin
materialisation and it passes; .#cider was not run.

## WINDOWS FLOAT NOW, which is what the reference screenshots actually show

2026-08-15. The user supplied screenshots of LibreOffice on real macOS, and the largest remaining
difference in them was not a control at all: every window and every dialog sits on a soft shadow,
and ours were flat rectangles against the desktop.

A Wayland client draws its own shadow. The surface is twenty four points bigger than the window on
each side, the ring is painted with a falling alpha, and xdg_surface.set_window_geometry names the
inner rectangle so that tiling, snapping and popup anchoring keep working on the WINDOW. The shadow
is cast from a rectangle six points above the window, so more of it falls below than above.

FOUR THINGS MOVE WITH THE MARGIN, and each is a bug if it does not:

    the O2 surface handed to AppKit is the INNER rectangle -- a pointer into the middle of the
      mapping with the padded stride, which is how a subrectangle of a bitmap is described
    the corner mask rounds the WINDOW, or the shadow gets the round corners and the window keeps
      square ones
    the damage covers the padded surface, or the shadow never appears
    POINTER COORDINATES ARRIVE IN SURFACE SPACE, so every one is twenty four too large in both
      axes; without subtracting it every click lands a widget down and to the right

Verified by looking, and by re-running everything the geometry could break: the application menu
opens under its own title with the blue pill and the Command symbols, which exercises both popup
anchoring and click coordinates; typing reaches the document; resize to 700x600 relayouts; startup
1.5215 s; zero unrecognized selectors. CIDER_WAYLAND_NO_SHADOW turns it off, which is how before and
after were compared.

WHAT THE REFERENCE STILL HAS AND WE DO NOT: a focused text field with a blue ring (ours draws one,
LibreOffice paints over it), and the system save and open panels, which on macOS are a sheet with a
sidebar, a Where popup and no traffic lights at all, where ours is cocotron own layout with a file
list. Those are the next two rungs of the authentic axis.

## A POINTER THAT HOLDS A BUTTON, and drag selection turns out to work

2026-08-15, commit fd32b11e. Drag selection had been carried as unverified for weeks. The reason was
never the port: nothing available could express a drag.

    sway IPC   builds a virtual device for the command list it is running and destroys it with the
               list, so the press and the release reach the client with the SAME timestamp and
               before any motion. Measured on the wire, not assumed.
    wlrctl     has click, move and scroll. No press, no release.

A gesture whose button is already gone when the first motion arrives is a mouse move, and that is
what LibreOffice was being sent every time this was tried.

scripts/cider-vptr.c is a wlr-virtual-pointer-unstable-v1 client. The device it creates lives
exactly as long as the process, so a press, ten motions spread over real time and a release come
from one device. Commands are one per line on stdin: abs, rel, press, release, scroll, sleep. The
protocol glue is generated rather than committed and the recipe is in the header comment. The
harness that drives it is run-lo-vdrag.sh.

WHAT IT ANSWERED. The line was typed, the sentence measured at x 277 to 507, the drag run from 290
to 500 at y 250:

    button=0x110 pressed=true x=290 y=250 type=1 clicks=1 window=2
    motion=2 x=311 y=250 buttons=0x1 type=6
    ... eight more, every one with the button still down ...
    motion=11 x=500 y=250 buttons=0x1 type=6
    button=0x110 pressed=false x=500 y=250 type=2 clicks=1 window=2

Looked at: the highlight covers the sentence from just after Dr to just before the final e, which is
the dragged range rather than the whole line. Then typing ZZZ over it leaves DrZZZe, and the dark
ink in that row falls from 277 to 507 down to 277 to 328. A highlight can be argued about in a
screenshot; text that a keystroke deleted cannot, because only a selection does that.

Two things this also settles. The pointer capability is withdrawn and re-advertised as the tool
comes and goes, and the backend handles it, which the release path in input.rs was written for and
had never been exercised. And the motion trace no longer rate limits a motion with a button held:
ten steps were sent and four printed, which reads as dropped motion and cost a run to work out.

What is still not driven: a double click, which selects a word, and drag and drop, which is a stub
in the backend rather than a harness limitation.

## THE FILE PANELS, and the view that was being thrown away

2026-08-15, commits 5e94177e, 63cbc518 and 81fc1752. The reference screenshots the user supplied
made the save sheet the biggest remaining difference, and the first thing found was not a style
problem at all.

    CIDER_PANEL accessory=NSView frame={{0, 0}, {300, 153}} subviews=7

-setAccessoryView: stored the view and did nothing else. That is where LibreOffice puts File type
and the save options, so three hundred by a hundred and fifty three points of controls were being
dropped on every save, and there was no way to choose what a document was saved as.

WHAT THE PANEL DOES NOW, bottom to top, which is the macOS order: buttons at the bottom right, a
hairline, the accessory view, a hairline, the name row, and the file list taking what is left. The
window grows for the accessory view when the screen has room, otherwise the list gives up the
difference. An open panel is the same layout with no name field, one override rather than a second
copy.

FOUR THINGS THAT WERE NOT MAC, all found by putting the two screenshots side by side:

    a push button title is CENTRED, and cocotron used the cell alignment, which a nib encodes as
      left, so Cancel and Save sat against the left edge of their bezels
    the DEFAULT button draws its label WHITE, because it is filled with the accent colour; ours was
      black on blue
    the list showed dot files, unsorted (the data source carried a TODO where the sort should be),
      and banded every other row in light blue, which reads as a selection
    the selected name in the field was white on pale blue, a ghost of itself

The last one was one colour used for two different backgrounds. selectedTextColor is for text
selected inside a field, where the band is pale and the text stays black; a table row is filled with
selectedControlColor, the accent, and takes alternateSelectedControlTextColor. Cocotron used
selectedTextColor for both, so one of them was always wrong.

While there: the data source read the directory once per row. An outline view asks for a count and
then for each child by index, and both called contentsOfDirectoryAtURL:, so N rows meant N plus one
reads and N plus one arrays of NSURL, again on every reload. Read once and kept now, keyed by path.

Looked at: the save panel shows ODF Text Document (.odt) with Automatic file name extension ticked
and the two disabled rows, in the order macOS has them; the open panel shows File type, Version and
Read-only; both still complete their journeys, one document saved as cider-typed-name.odt and
another opened as cider-open-me.odt by typing its name in the list.

STILL NOT MACOS: these are windows with traffic lights, not sheets attached to the document. There
is no sidebar, no Where popup, no preview and no search field. A selected row is drawn with a dotted
focus rectangle around it, which is a Windows habit.

## THE MENU BAR STAYS IN THE WINDOW, and that is a decision rather than a limitation

2026-08-15. Built and reverted the same day: 0c979445 added the wlr layer shell, 229df081 moved the
menu bar onto a strip anchored to the top of the screen, and a2981ba5 took both out.

It worked. The strip came up as a layer surface anchored top, left and right with an exclusive zone,
the bar read LibreOffice File Edit View Insert Format Styles Table Form Tools Window Help with the
application name bold along the top of the display, the document window below it had no menu row of
its own, and clicking File opened the File menu under it with the Command key equivalents in place.
A compositor without layer shell, headless weston, kept the old row inside the window.

THE USER STOPPED IT, and the reason is the design one: on Linux there is no global menu bar. A strip
along the top of the display belongs to the DESKTOP, not to an application, and an application that
claims it is fighting whatever panel the user already runs. The menu bar is part of the window here.

That is the line for the authentic axis. Matching macOS pixel for pixel stops where it would take
over the desktop, and the in-window menu row is the answer rather than a step towards something
else.

What the two reverted commits still record, for anyone who needs a surface anchored to a screen
edge: the shim and FFI for zwlr_layer_shell_v1, the third surface role in create_surface, the
NSMainMenuWindowLevel signal, hasScreenMenuBar on NSDisplay, and the one place in
+[NSWindow hasMainMenuForStyleMask:] where the whole geometry follows from one answer.

## STARTUP IS NOT THE PROBLEM, measured against the native build under the same compositor

2026-08-15. Goal 3 of the queue is performance measured against native LibreOffice, and there was no
number for it. Every harness in the scratchpad sleeps twenty five to thirty seconds before touching
anything, which is a guess nobody had ever checked.

Both builds were started under the SAME nested sway, from a clean profile, and the compositor was
polled until a window of the application was mapped:

    native  LibreOffice 25.8.5.2, Linux, gtk3     1.38 s to a window
    cider   LibreOffice 25.2.1.2, macOS build     1.13 s to a window

The screenshots two seconds later say what those numbers are worth, and they are the reason the
measurement is not a summary statistic: ours shows a COMPLETE Writer window, menu bar, toolbars,
ruler, page, sidebar, find bar and caret. The native one is still filling in, with half its toolbar
icons missing and a stray Set Paragraph Style tooltip on the canvas.

So starting is roughly at parity and the settle in the harnesses is superstition. What remains on
the performance axis is the one measured thing: LibreOffice polls nineteen thousand times a second
while a system dialog is open, which costs 45 percent of a core, and each poll is already as cheap
as this backend can make it.

Not measured yet, and the honest list: typing latency, scrolling, layout of a long document, and
memory.

## FOUR MORE JOURNEYS, driven by keys and a virtual pointer rather than by pixel guesses

2026-08-15. With the settle down from thirty seconds to ten, a journey costs about a minute, so
these were run to find breakage rather than to confirm anything:

    find        Command F focuses the find bar, typing brown and pressing Return highlights brown in
                The quick brown fox jumps over the lazy dog, and the bar shows the word with a caret
    formatting  Command A then Command B makes the whole sentence bold
    undo        Command Z takes the bold off again
    scrolling   eight wheel steps from cider-vptr move the page under the cursor
    printing    Command P raises the LibreOffice alert No default printer found, drawn correctly
                with the red stop icon, the blue default button and traffic lights

The last one is not a rendering bug and not fixable here: there is no print system in the container,
so LibreOffice is right. Printing needs CUPS inside the prefix, which is a different piece of work
from the GUI port.

Nothing in the four broke, so nothing was changed for them. The dotted focus rectangle around a
selected row and the missing ring on a focused field were changed, and both are in their own
commits.

## ITERM2 GETS PAST ITS NIB, and the next three things in the way are named

2026-08-15, commits 6aed9b8a and 883685d8. Goal 4 of the queue is iTerm2 given the same treatment as
LibreOffice, and it had never started at all: it loaded MainMenu.nib, got nothing, and ran an event
loop over zero windows.

The reason was the FORMAT. This framework reads the typedstream and the keyed property list nib;
everything Xcode has written since version 4 is a NIBArchive, and nothing read it. A nib that fails
to decode is silent, which is why this looked like an application that starts and does nothing.

The object graph inside a NIBArchive is the one this framework already builds, class for class and
key for key, so only the container needed reading. Where iTerm2 is now:

    CIDER_NIB archive objects=1849 keys=55 values=7683 classes=17
    CIDER_NIB bytes=58174 keyed=1 magic=NIBArchive objectData=decoded
    CIDER_NIB NSApplication run
    CIDER_NIB finishLaunching entering delegate=iTermApplicationDelegate
    CIDER_NIB finishLaunching done delegate=iTermApplicationDelegate windows=0

The nib decodes, the menu is built, the delegate is connected, and applicationDidFinishLaunching runs
to the end. THREE THINGS STOP IT AFTER THAT, in order:

    +[ODSession defaultSession]      OpenDirectory, which this tree does not have at all. Raised
                                     inside finishLaunching and caught by NSApplication, so it is
                                     survivable rather than fatal.
    shouldRestoreStateOnNextLaunch   sent to the NSApp instance, whose class is the KVO subclass
                                     NSKVONotifying_iTermApplication. The only definition of that
                                     selector in the binary is a CLASS method of
                                     iTermRestorableStateController, so either iTerm2 is asking an
                                     object that cannot answer or something about the KVO subclass
                                     is answering the wrong lookup. Not yet worked out, and it is
                                     what kills the process.
    windows=0                        no terminal window is made even before that, so there is more
                                     than one thing left.

What was needed on our side and is now there: the NIBArchive reader, and colorUsingColorSpace: on
NSColor, which is the 10.7 way to ask for a conversion and the only way current code asks.

## WHICH VIEW A CLICK REACHED, and what the file type popup does with one

2026-08-15. The save panel shows LibreOffice accessory view now, so the obvious next journey is
saving as .docx through the File type popup in it. Three runs clicked at three positions and nothing
happened, which from outside is indistinguishable from a control that ignores clicks.

NSWindow now prints the view a mouse down hit under CIDER_TRACE_PANEL, and the question answered
itself in one line each time:

    CIDER_HIT at=300,106 view=NSView frame={{100, 75}, {300, 153}} responder=0
    CIDER_HIT at=300,210 view=NSPopUpButton frame={{77, 126}, {200, 22}} responder=1

The first is the accessory CONTAINER, which means the click missed every control inside it. The
second is the popup button, and that click opened a menu: popup=ok number=33 size=233x363 level=6.
So the accessory view is hit tested and its controls work; the earlier runs were aimed wrong, and
the arithmetic that aimed them was wrong in a way only a trace could show.

WHAT STILL DOES NOT WORK: the menu that opens is gone from a screenshot taken two seconds later, and
the keys typed after it went into the NAME FIELD, so the file was saved as cider-docx-nameWord.odt
rather than as a Word document. A popup menu on macOS stays up until something is chosen. Whether
ours is dismissed by the release, by the modal session the panel is running, or by something else is
the next thing to find out.

The instrument stays: a control that does nothing when clicked is either not being hit or being hit
and ignoring it, and those are the same picture from outside.

## A POPUP MENU THAT VANISHES, and the two coordinate spaces behind it

2026-08-15, commit 5990488d. The entry above ended with a question: the File type menu opened and was
gone from a screenshot two seconds later, and I did not know whether the release, the modal session
or something else dismissed it. It was none of those.

Cocotron already implements the sticky behaviour macOS has: a short click with no movement leaves the
menu up, a click that moved or was held releases into a selection. The two are told apart by
comparing where the pointer is NOW against where it STARTED. Now comes from NSEvent mouseLocation,
which is on the SCREEN. Started was [event locationInWindow], in the control window, never converted.
They agree only for a window at the origin. The save panel sits at 595,483, so every click looked
like a drag of several hundred points and released immediately.

The fix is one conversion. What it buys is every NSPopUpButton in every dialog, not just this one.

WHAT THE JOURNEY NOW DOES, end to end and checked on disk rather than on screen alone: type a
sentence, Command S, type a name, click the File type popup, the menu stays up with ODF Text Document
(.odt) highlighted and Word 2010 to 365 Document (.docx) five rows down, drag to it, release, Save.
The file is Microsoft Word 2007+ by file(1), a zip of ten entries, and word/document.xml contains the
sentence that was typed.

That is the accessory view earning its place: until today it was stored and never shown, so no format
other than the default could be chosen at all.

## THE CONTEXT MENU, which never once appeared, and what three wrong guesses cost

2026-08-15, commits 2d8ed0ea, fb9d731e and 488f8a91. Right clicking in a document did nothing at all.
The event was never the problem: the right button arrives, the view gets rightMouseDown, VCL builds
the menu and asks for two dozen colours to style it with. Everything after that was ours.

    1. AquaSalMenu ShowNativePopupMenu opens the menu through
       -[NSPopUpButtonCell performClickWithFrame:inView:], which did not exist. The whole thing died
       on the unrecognized selector.
    2. With that written, a menu window appeared at 0,-290, off the top of the screen. The tracking
       placed it at the origin of the control view BOUNDS and ignored the cell frame it was given.
       That is the same point for an ordinary popup button and wrong for everyone else: LibreOffice
       draws into a view that fills the window and passes the rectangle it wants the menu at.
    3. My first fix took the cell frame only when it was not empty, and NSIsEmptyRect is TRUE for a
       rect with zero HEIGHT, which is exactly what a caller asking for a menu AT A POINT passes.
    4. The menu then opened as a square translucent slab: the only background it ever drew was at
       148x49, because the view is created at the size of the CELL and resized when tracking starts,
       and marking it as needing display is not the same as drawing it.
    5. It had six bands of separators where macOS has three, because an application leaves its empty
       groups in and macOS drops a separator that follows a separator.

TWO INSTRUMENTS came out of this, both kept, because three of those five were guesses that a trace
would have settled sooner:

    the window role line names the APPKIT CLASS of each surface, so a 164x304 panel at level 6 is
      identified as an NSPopUpWindow rather than guessed at
    CIDER_WAYLAND_TRACE_CREATOR prints the frames that made a window, which is what finally named
      AquaSalMenu ShowNativePopupMenu at the top of the stack

And one thing worth knowing about this tree: an NSLog from inside that tracking loop never reaches
the log, in a run full of other NSLog output. The traces there are fprintf.

Looked at, against the reference the user supplied: Cut, Copy, Paste, one inset rule, Clone
Formatting, Clear Direct Formatting, Character, Paragraph, List, one rule, Insert Comment, one rule,
Page Style, on a rounded translucent panel with a hairline border, at the pointer. The reference has
exactly those groups. What it still lacks: a chevron rather than a triangle for a submenu, the taller
system rows, and a drop shadow.

## A SECOND APPLICATION, and the two things that stop one from loading at all

2026-08-16, commit b791cade. The user asked in public which macOS applications would be worth
running under this, and the answers became tasks: iA Writer, Swift Publisher 5 and MoneyMoney, which
they sent directly. MoneyMoney went first because it is AppKit rather than SwiftUI.

Getting it is three steps and no Apple tooling: the trial is a xar, its payload a cpio, and libarchive
reads both. Inside is a universal binary built against the macOS 26.2 SDK whose MainMenu.nib is a
NIBArchive, which this tree learned to read the day before.

TWENTY SYMBOLS were unresolved by scripts/macho-undefined.py, which is a short list for an
application of this size, and dyld named them one at a time. Strings mostly: print keys, popover
close reasons, the text content types a password manager fills, the action dictionary keys of an
embedded web view, the TLS properties of a stream. Two were CLASSES, NSDraggingSession and
NSStatusBarButton, and a missing class is a link error rather than a message that goes nowhere: the
process cannot start at all.

ONE OF THEM TEACHES SOMETHING GENERAL. NSCalendarDayChangedNotification is declared in Foundation and
defining it there changed nothing, because dyld said where it wanted it:

    Expected in: /System/Library/Frameworks/CoreFoundation.framework

A two level namespace import names the library. The header is not the authority; the import record is.

AND THE CONTAINER HAD NO TIME ZONES, which is a fault in this port rather than in the application.
The prefix links /usr/share/zoneinfo at /Volumes/SystemRoot/usr/share/zoneinfo, which is the host
path on Debian and Fedora and does not exist on NixOS. The cost is not a wrong clock: CFDateFormatter
puts the zone into a dictionary, a dictionary refuses nil, and the throw is fatal. The message says
Cannot set nil objects nor nil keys and nothing about time.

The instrument that found it stays: a nil insert now names the key before it throws.

    CIDER_DICT_NIL object=(nil) key=__NSCFConstantString keytext=kCFDateFormatterTimeZoneKey

The packaging points the link at the tzdata the package already depends on. Proved by making that
link by hand in the runtime tree: the time zone nil disappears. The packaged form has not been
rebuilt, since that is the endpoint build.

WHERE IT STANDS: MoneyMoney loads and dies during startup on another nil under the key dateFormat.
Not a window yet, and every step of the way is above rather than summarised.

## FIVE STEPS INTO A NIB THAT KILLS THE PROCESS, and the traces that made each one a line

2026-08-16, commit ad1d2878. MoneyMoney loaded and then died during startup with no exception, no
message and exit code 1. Five guesses would have been five wasted runs, so the decoder learned to
say what it was doing, and each step named itself.

    CIDER_NIB enter 1077 NSUserDefaultsController      a class this framework has
    CIDER_NIB built 1077 NSUserDefaultsController ok   and it came back
    CIDER_NIB enter 1078 NSArray                       so the next thing is an array
    CIDER_NIB objectdata NSObjectsValues               which is being decoded for this key
    CIDER_NIB objectdata keys=168 values=168           and the two parallel arrays agree
    CIDER_NIB objectpair 164 key=NSCustomObject wants=Realtime value=NSApplication

TWO REAL FAULTS came out of it, and both are general rather than about this application.

A NIL SUBSCRIPT REMOVES THE KEY. dict[key] = nil is documented to remove the entry and ours forwarded
it to setObject:forKey:, which refuses nil. Ordinary code of that shape was fatal:
-[NSDateFormatter setDateFormat:] stores its argument that way and is given nil to clear the format.

A CONTAINER IS STORED BEFORE IT IS FILLED. The NIBArchive reader recorded an array only after
building it, so a cycle through a container never terminated and the stack ran out: silence, because
a stack overflow has nothing to print. Objects were already stored before initWithCoder: for exactly
this reason; containers were not. The stored container is mutable even where the archive says
NSArray, because swapping in an immutable copy at the end would leave every object that already
holds the mutable one holding a different collection.

WHERE MONEYMONEY STANDS: 1573 objects decode, NSIBObjectData walks its object table, and the
application instantiates its own controllers in turn -- NSUserDefaultsController, NewsCheck, Locale,
Realtime -- and dies inside the last one with no output. That is application code, and the next step
is a debugger rather than another trace.

Regressions checked by running them rather than by reasoning: the LibreOffice save panel opens,
reveals its directory and saves; iTerm2 decodes its nib and opens its first run dialog.

## WHAT A CORE DUMP SAID THAT NO TRACE COULD

2026-08-16, commits 3a507f1b and 4c074fc7. MoneyMoney died with no exception, no message and exit
code 1, five objects into instantiating its own controllers. Traces had taken it as far as the name
of the class, Realtime, and stopped being able to say anything: the process was simply gone.

systemd collects a core for the guest, because a guest process IS mldr with Mach-O images mapped into
it, and scripts/core-guest-stack.py turns those addresses into names through the NT_FILE note. The
stack answered in one line:

    #3 CFAbsoluteTimeGetCurrent
    #4 NSRequestConcreteImplementation
    #5 to #19 the same address in the application, fifteen times

Fifteen identical frames is a stack overflow, and a stack overflow has nothing to print, which is why
every instrument in this tree was silent.

WHAT IT WAS. +[NSTimeZone localTimeZone] read getenv TZ unconditionally and built a string from the
result. TZ is usually not set: getenv returns NULL, the string is nil, the zone is nil, and every
method on it lands on the ABSTRACT base class, which raises. An application that retries around that
raise recurses until the stack ends. The system zone is the fallback now, which works because the
container finally has a zone database.

It did NOT get MoneyMoney further. It still dies inside Realtime, which is application code and the
next thing to look at with a debugger. The fix stands anyway: a nil local time zone is wrong for
every application on this port, and the recursion it can cause is now written down.

AND THE SUBMENU CHEVRON, from the same reference screenshot as the separators: two strokes meeting at
a point rather than a filled triangle. The first attempt drew a vertical BAR, because the arrow box
after its margins is four points by eight and insetting it left nothing, which the screenshot said
before anything was claimed about it.


## Swift Publisher 5, and what a prologue fault means

2026-08-16, commits 2959ea88 and 10b9ae00. The second application from the user list, and the first
one to draw a window of its own.

THE SWIFTUI QUESTION WAS MEASURED, NOT ASSUMED. The user replied in the Bluesky thread that SwiftUI
support was probably needed before any of these could run. For this one it is not: the x86_64 slice
of the trial links Cocoa, WebKit, Quartz, CoreImage, AddressBook, ExceptionHandling and
iTunesLibrary, and not one Swift runtime library. Reading the load commands took a minute and saved
the assumption. The trial itself is a public download, a UDBZ dmg that 7z from nixpkgs reads without
a mount, and it goes into a prefix of its own so a broken install cannot take LibreOffice with it.

NINE ROUNDS TO LOAD. Run it, read what dyld says, fix that, run again. Every one was a real gap:

- iTunesLibrary, a whole framework and not one macOS ships. iTunes installs it into
  /Library/Frameworks, so it is a FLAT bundle with no Versions/A, and the install name has to say
  exactly that or the loader never finds it. It answers nil with an error, which is the truth on a
  machine with no iTunes library, rather than a stub object whose empty collections a caller would
  believe.
- AddressBook: ABGroup and ABMultiValue as classes, and twenty four label and key constants with
  the values macOS uses. A label is stored in the database as it stands, so a spelling that differs
  is a phone number that has lost its label.
- WebKit: WebUndefined, which is what a bridged JavaScript value that was never set reads back as,
  and four keys whose names drop the View exactly as macOS does.
- AppKit: three more sharing service names. CoreText: the five frame attributes, declared in the
  header since it was written and defined nowhere at all.
- CoreGraphics: THE PDF C API. Onyx2D has parsed and drawn PDF for years and no application could
  call any of it from C. CGPDFArrayGet{Count,Object,Array,Dictionary,Stream,String},
  CGPDFObjectGet{Type,Value}, CGPDFDictionaryApplyFunction, CGPDFStreamGetDictionary,
  CGPDFPageGetDictionary, and for writing CGPDFContextCreateWithURL with BeginPage and EndPage.
  These are bindings onto methods that already existed. The nine CGPDFObjectType values are
  deliberately the same numbers Onyx2D uses internally, so there is no translation table to drift,
  and the range is checked rather than assumed because everything past the stream type in that
  enumeration is a parser mark with no PDF meaning. CGPDFDictionaryApplyFunction needed one new
  thing underneath: every accessor on O2PDFDictionary takes a key you already know, so a caller
  reading a dictionary it has never seen had no way in.

A PROLOGUE FAULT IS A STACK OVERFLOW, and this is the method worth keeping from the second half.
The application died with no message, and the fault looked like nothing:

    RIP  AppKit+0x65e6c   twelve bytes into -[NSMatrix initWithFrame:mode:cellClass:...]
    RSP  0x7FFFFF5FFFF8   eight bytes below a page boundary

A prologue faults where it first WRITES, so a fault twelve bytes in with a stack pointer one word
past a page boundary IS the diagnosis: the stack ran out. Counting the stack words that land in a
mapped image then named the cycle exactly, four frames repeated 34,600 times.

The cause was general. -[NSMatrix initWithFrame:mode:cellClass:numberOfRows:numberOfColumns:] began
by sending -initWithFrame: TO SELF, which is a call into the subclass. On macOS the long form is the
designated initialiser and -initWithFrame: is the convenience, so a subclass whose -initWithFrame:
calls the long form is ordinary Cocoa, and here it recursed forever. The shared setup is a method of
its own now and no initialiser sends anything to self to reach it.

TWO PLACES TO READ REGISTERS, because coredumpctl shows one thread and it is not the one that
faulted. The DAEMON log carries the guest register dump (ciderd.log, the sigexc gregs block, where
greg 8 is RDI and greg 15 is RSP), and scripts/core-guest-stack.py resolves any address through the
NT_FILE note. Between them, a receiver of 0xFFCECECEFFCECECE is identifiable as a fill pattern
rather than an object without a debugger anywhere.

FIVE MORE FIXES, all general: setSelectionByRect: on NSMatrix; CALayerContext answering nil rather
than keeping a null GL context (there is no OpenGL on this backend, so every layer-backed view was
building one); NSURLSessionTask and the three classes under it, which were EMPTY, so no data task
could be built at all; the app-group container on NSFileManager; and the appearance of an NSWindow,
which applications OBSERVE to follow dark mode and which threw out of addObserver:forKeyPath:.

AND A CORRECTION TO THE DAY BEFORE. Guarding the two optional NSExceptionHandler delegate methods
was right, but the same edit moved the HANG MASK onto the path that has a delegate. With no debugger
attached SIGTRAP is not a pause, it is the end of the process, and it killed this application for two
runs after the real bug was already fixed.

AND HERE IT IS: docs/wayland-swift-publisher-template-gallery.png. The window lives about a tenth of
a second, so a driver that waits for a settle never sees it; shooting continuously from the moment
the compositor starts does. What that image shows is the Template Gallery, with its source list
(All, then DESKTOP PUBLISHING with sixteen categories under it, DISCS AND MEDIA, BUSINESS CARDS), a
grid of four template tiles with their captions, an Open Recent popup and a Choose button. It is
recognisably the application.

WHAT IS WRONG IN IT, and the screenshot is the reason any of this is known rather than assumed. The
template grid sits on a DARK GREY background where macOS has a light one. The in-window menu bar
carries only the application name, which is the objectValue exception below cutting createMainMenu
short. The heading Please choose a design is clipped along its top edge. The window is placed at
y = -40, so its title bar is off the top of the screen.

WHERE IT STOPS. The application then opens its welcome nib and dies in the keyed unarchiver. The main menu is built in code and binds its items to
objectValue, which NSMenuItem does not have, so every item raises; -[NSWindow standardWindowButton:]
is unimplemented; and a layer-backed view has no compositor to render it.


## Menus, finished: the rows and the blur

2026-08-16, commits 9124f8ee and 14f60990. The user named three things about menus that were not
macOS: a triangle instead of a chevron, the row spacing, and no shadow. The chevron and the shadow
were done earlier; these two close the list.

THE ROWS WERE MEASURED, NOT LOOKED AT. Counting rows of dark pixels down the middle of the reference
screenshot gives the pitch directly: 70, 48, 48, 48, 48, 70, 70 retina pixels, so 24 points between
titles and 35 across a separator, and 236 points of panel for eight items and three separators. Ours
read 32, 21, 20, 21, 21, 33, 32 and a panel of 207. The text bands are the same height in both
images, so what was missing was the space around the text rather than the size of the type. Title
margins went from two points to three and a half, and the space at the two ENDS of the panel became
its own constant at six rather than borrowing the three point side border, because Apple leaves
noticeably more at the ends than at the sides. After: 35, 24, 24, 24, 24, 35, 35, and a panel of
164 by 237.

A BLURRED BACKDROP, WHICH WAYLAND CANNOT GIVE YOU. A menu here is translucent and the compositor
blends it over what is below, so the toolbar and the document text behind it arrive sharp and
readable through the panel. macOS blurs what is behind: the colour comes through, the detail does
not. There is no protocol for this and there will not be one, because a client does not get to read
the compositor output.

The way in is that a menu belongs to a window THIS PROCESS DREW, and those pixels are in a buffer of
ours. So the backdrop is sampled from the parent window buffer, blurred, and composited under the
panel. Three box blurs are a Gaussian to the eye and each is a running sum, so the radius costs
nothing; a menu sized panel takes about a millisecond.

Three rules make it correct rather than merely blurry:

- INSIDE THE GEOMETRY RECTANGLE ONLY. The shadow ring outside it falls on the real desktop rather
  than on the parent window, so it has to stay translucent and the compositor has to keep blending
  it.
- A FULLY TRANSPARENT PIXEL IS LEFT ALONE. Those are the rounded corners; filling them would square
  the menu off.
- A SOLID PIXEL IS LEFT ALONE. There is nothing to see through it.

Proved with a kill switch rather than by assertion: CIDER_WAYLAND_NO_VIBRANCY=1 turns it off, and
the two runs of the same harness over the same Start Center were looked at side by side. Without it,
Open File, Remote Files, Recent Documents and Templates are readable straight through the menu and
the blue button behind it is a solid blue rectangle. With it, none of that is there.

What is not done: a submenu samples the window rather than the menu it opened from, because the
parent search skips popups, and the backdrop is taken once per present, so a window that redraws
under an open menu leaves it holding the older picture until the menu draws again.


## The application queue, as it stands

Three applications were added to the work by the user, from a Bluesky thread and one sent directly.
Where each one is, so the next session does not measure it again.

**iA Writer, task 115: BLOCKED ON GETTING IT, and on nothing in this tree.** The download page
distributes the Mac version through the Mac App Store only; there is no direct trial dmg or zip. A
public trial download is allowed and a purchase is not, so there is no legitimate way to obtain it
at present. Worth re-checking if iA ever publishes a direct trial.

**Swift Publisher 5, task 116: RUNS AS FAR AS ITS TEMPLATE GALLERY.** The trial is a public download
from cdn.belightsoft.com, a UDBZ dmg that 7z reads without mounting anything. The SwiftUI question
that hung over this one is answered: it links no Swift runtime library at all. It loads, decodes its
nibs, and presents its Template Gallery, then dies in the welcome nib inside the keyed unarchiver.

**MoneyMoney, task 117: LOADS AND DIES IN ITS OWN CODE.** It gets through startup as far as its
Realtime controller, which is application code rather than anything in this tree, and wants a
debugger rather than another trace.

Everything these three needed to get as far as they did was general: a missing framework, missing
classes, missing constants, an initialiser that recursed, a URL session that could not be built, a
window with no appearance. None of it was specific to any one of them, which is the argument for
running unfamiliar applications in the first place.


## iA Writer, and where a Swift application actually stops

2026-08-16. The user asked whether iA Writer can be downloaded from the iA site rather than the Mac
App Store. It can, and the earlier note in this tree saying otherwise was wrong: the downloads page
has a Mac trial button, and the endpoint behind it answers with a public zip.

    curl -s -X POST 'https://ia.net/download?type=writer&code=downloads&start=1'
    {"success":true,"file":"https://files.ia.net/writer/release/iA-Writer-8.0.6-80046.zip"}

MEASURED FROM THE BINARY rather than assumed: an x86_64 slice, built against the macOS 26.5 SDK with
a minimum of 10.15, linking the Swift runtime and NOT SwiftUI. The Swift runtime turned out not to
be a blocker at all, which is worth knowing for every Swift application after this one: the prefix
already ships a real libswiftCore, six and a half megabytes with twenty seven thousand symbols, and
forty three framework overlays beside it.

Three things were missing and all three were general:

- NSFileVersion, an entire Foundation class. There is no version store on this system, so every
  query answers empty, which is what macOS answers for a file that has never been versioned, and the
  calls that would modify a store fail with an error rather than reporting a success that did not
  happen.
- kCACornerCurveCircular and kCACornerCurveContinuous in QuartzCore. A continuous corner is the
  squircle; nothing here draws the difference yet, but a referenced string constant that does not
  exist is a link error.
- NSMenuDidAddItemNotification and its two siblings. The comment in NSMenu.m already said they were
  missing and that the menu bar was invalidated directly instead. They are posted now, with the
  index under NSMenuItemIndex, which is the key an observer written for macOS reads.

AND THEN THE REAL WALL, which is the useful part of this entry:

    Symbol not found: _$s7Combine10PublishersO3MapVMn

That is the Swift nominal type descriptor for Combine.Publishers.Map. An empty Combine framework
gets the application past the LOAD of Combine; this is what it reaches for next. Swift type metadata
cannot be written in Objective-C, so this is not a stub away. It needs Combine compiled from Swift
under the module name Combine, matching the ABI the application was compiled against. That is a
project, and it is the honest answer for iA Writer today.

The pattern across all three applications tried so far holds: what stops them is almost never
specific to them. A missing framework, a missing class, missing constants, an initialiser that
recursed, a URL session that could not be built, a window with no appearance. Only iA Writer has hit
something that is genuinely its own kind of problem.


## The tick, the title, and one gap that is not ours

2026-08-16, commits 93014bd9 and 30c9ce9b, both found by comparing against the screenshots the user
sent rather than by reading code.

A TICKED MENU ITEM SHOWED THE LETTER a. The mark was drawn as character 0x61 of Marlett, the Windows
interface font, in which 0x61 is a check mark. Marlett is not on this system and nothing substitutes
for it, so the character came out as itself: the View menu had six stray letters down its gutter. It
is two strokes now, in the same style as the submenu chevron, which had been replaced earlier for
exactly the same reason. The vertical direction is asked for rather than assumed, because a menu
view is flipped and a tick is not symmetric about its middle.

THE SAVE PANEL HAD AN EMPTY TITLE BAR, and fixing that revealed a second fault behind the first.
-[NSSavePanel setTitle:] kept the string for the dialog and never called super, so the window title
was never set and the theme frame had nothing to draw. With that fixed the bar read Window, which is
what a nib calls a window nobody has named: resetToDefaultValues runs after the nib is loaded and
assigned the ivar directly rather than going through the setter. Both panels now set their default
through the setter, so the placeholder is overridden and an application that sets its own title
later still wins.

AND ONE GAP THAT IS PROBABLY NOT OURS, written down because the next session will see it too. The
macOS reference has a status bar under the find bar; ours ends at the find bar. What is established:
the profile has no StatusBar entry at all, and the View menu shows Status Bar UNCHECKED, so
LibreOffice itself believes it is off rather than us failing to draw it. What is not established:
why it is off. The profile persists between runs in the same prefix, so an earlier driven run may
have turned it off; a fresh prefix is the first thing to try, before anything about drawing.

Three harness facts came out of the same session. A nested sway can be any size with
WLR_BACKENDS=headless and an output resolution line, where the wayland backend ignores it and
follows the parent window. The first click into an inactive window is spent activating it, so a run
whose first action is clicking a menu title opens nothing. And an empty environment value is still
SET as far as the backend is concerned, which is how passing CIDER_WAYLAND_NO_VIBRANCY= silently
turned the menu blur off in every run of one harness and made a working feature look regressed.


## The status bar answered a question and asked a better one

2026-08-16. The macOS reference has a status bar under the find bar and ours did not, which looked
like a drawing gap. It was not: the View menu showed Status Bar unchecked, and deleting the
LibreOffice PROFILE, not the prefix, brought the whole thing back on the next run.

    Page 1 of 1 | 0 words, 0 characters | Default Page Style | English (Denmark) | Insert |
    selection mode | book view icons | zoom slider | 100 percent

That is docs/wayland-status-bar.png, and it draws correctly in every part. The bar had been switched
off in the accumulated profile by some earlier driven run. The lesson is worth more than the answer:
THE LIBREOFFICE PROFILE SURVIVES BETWEEN RUNS in the same prefix, so a question about what the
application believes starts by deleting the profile, not by reading our drawing code.

AND THAT TEST FOUND A REAL DEFECT. The first run with no profile fails:

    run 1, no profile at all   -> Unspecified Application Error, and zero windows
    run 2, same path           -> starts normally, fourteen windows

Reproduced four times, both on the default profile path and on a clean -env:UserInstallation path,
so it is not about one directory. It is not profile creation as such either: soffice --headless
--terminate_after_init on a clean path exits zero and leaves a complete profile behind. It is the
GUI first run specifically.

SAL_LOG is no help here, and that is worth knowing before the next attempt: nixpkgs ships the
official release build, which has SAL_INFO and SAL_WARN compiled out, so no log level produces
anything at all. The next step is guest syscall tracing rather than another environment variable.

This is a real not-fully-working item: a person installing this and starting LibreOffice for the
first time sees an error dialog and has to start it a second time.


## The first run, diagnosed to the instruction

2026-08-16, commit b5e0cfcf. The first LibreOffice run against a new profile dies with Unspecified
Application Error and zero windows; the second run on the same profile works. Everything in this
tree was silent about it: no exception, no unrecognised selector, and SAL_LOG produces nothing
because nixpkgs ships the release build with logging compiled out.

THE REASON NOTHING COULD SEE IT is worth more than the bug. A fatal signal goes to the handler the
application installed, which is correct, and is also the end of any hope of debugging: the handler
prints its own message and exits cleanly, so there is no core and the guest stack resolver has
nothing to read. The only trace was one line in the DAEMON log, sigexc: will forward signal to app
handler.

So there is now a switch. CIDER_SIGNAL_NO_APP_HANDLER=1 makes sigexc take the DEFAULT effect for the
four signals that mean the process is broken, SEGV, BUS, ILL and FPE, and the kernel writes a core.
It is read once at setup, from /proc/self/environ because that code is below libc, and it changes
nothing unless it is set. The first time it was used it answered in one line:

    tid 3  libskialo.dylib+0x49936b  MetalWindowContext::checkDestroyShared (+43)

And the disassembly of those three instructions is the whole bug:

    mov rax, qword ptr [fGlobalShared]
    mov rax, qword ptr [rax + 0x20]
    mov eax, dword ptr [rax + 8]        <- faults

Skia reads the reference count of fGlobalShared->[0x20] without checking it for null, and null
checks the same field two instructions later. The field is null because MTLCreateSystemDefaultDevice
answers nil here, which is the truth: there is no Metal on this system. So this is a Skia null
dereference on its own failed-Metal path, inside the one-time capability probe LibreOffice runs per
profile. Once it has crashed, the profile records enough that the probe never runs again, which is
exactly why the second run works.

MEASURED AND DID NOT HELP: SAL_DISABLE_SKIA=1, SAL_FORCE_SKIA_RASTER=1, and making
+[CAMetalLayer alloc] answer nil so that a class whose every method raises cannot be built at all.
That last change was reverted, because it fixed nothing and an unproven behaviour change is not
worth keeping. The probe runs whatever the Skia decision is.

Where that leaves it: not fixable from our side without a working Metal, and the workaround is what
already happens by accident, which is to start it twice. It stays on the list as a real
not-fully-working item rather than being quietly dropped.


## The first run was two of ours, and the Skia frame was a red herring

2026-08-16, commits c0fb3ea8 and 5eeff803. The first LibreOffice run against a new profile failed
every time with Unspecified Application Error and no windows. Yesterday this was recorded as a Skia
null dereference we could not fix. That was wrong, and the way it was wrong is worth keeping.

CIDER_SIGNAL_NO_APP_HANDLER=1, added to see the crash at all, turns a HANDLED crash into an
unhandled one. LibreOffice runs its Skia probe expecting it to be able to crash: it catches the
signal itself, records the result, and never repeats it. So the switch made the probe crash look
like the answer when it was the application working as designed.

The real cause was two bugs of ours in the same code path.

FIRST, O2SurfaceCreateImage dereferenced its argument on the first line. Every Core Graphics entry
point on macOS checks: it writes something like invalid context 0x0 to the log and returns NULL, so
a caller whose context creation failed limps rather than dies. That is the one that was fatal.

SECOND, and the reason the context was null in the first place, O2Surface assumed thirty two BITS
PER PIXEL for every bitmap. CGBitmapContextCreate is not given a bits-per-pixel; Core Graphics
derives it from the bits per component, the number of components in the colour space, and whether
the format stores an alpha byte. LibreOffice draws a bitmap with a mask by making an eight bit GREY
context for the mask, and thirty two turned that into a combination nothing supports.

The message named the combination but not the caller, so the failure now prints a backtrace with it,
and that is what named this in one line:

    O2Image failed to init with bpc=8, bpp=32, colorSpace=type=0, bitmapInfo=0x0
    <- QuartzSalBitmap::CreateContext <- CreateWithSalBitmapAndMask
    <- AquaGraphicsBackend::drawAlphaBitmap <- OutputDevice::DrawDeviceAlphaBitmap

Measured on a clean profile path: before, no windows were presented at all; after, nineteen presents
and no error. The first run reaches its window now, which it never did.

AND THE BUG THIS UNCOVERS. The masked bitmap path now draws, and it draws VERTICALLY FLIPPED: the
font dropdown in the toolbar comes out mirrored, text and all, and so does the strip along the
bottom of the window. That path could not draw at all before, so it is newly visible rather than
newly broken, and it is the next rung.


## The icons came back, and what is known about the flip

2026-08-16, commit d5b25f48. -[O2Image copyWithMask:] was O2UnimplementedMethod, so
CGImageCreateWithMask returned nil for every caller. The rasteriser has supported a soft mask all
along: drawImage:inRect: asks the image for its mask and builds an O2Paint_image with both. Only the
way to attach one was missing. LibreOffice draws every toolbar and sidebar icon that way, through
drawAlphaBitmap, so with the mask step failing the icons were not there at all. Looked at, same
harness and same frame, before and after: the sidebar icons return and the toolbars keep their
colour icons, dropdown arrows and separators.

An instrument came out of it, because this took four wrong guesses. CIDER_TRACE_DRAWIMAGE names
every image draw with its size, its destination, whether it carries a mask, and the frames that
asked for it. Its first useful answer was not about masks at all:

    CIDER_DRAWIMAGE 1256x634 -> 0,0 1256x634 mask=0 <- AquaSalGraphics::UpdateWindow

THE WHOLE WINDOW ARRIVES AS ONE BLIT of the bitmap LibreOffice renders into. Nothing in a
LibreOffice window is drawn straight into the window surface, which is worth knowing before
attributing anything drawn wrong to the window path.

THE FLIPPED DROPDOWN IS NOT FIXED. What is established, so the next attempt does not start over:

- It is in the BUFFER, not the presentation. The CIDER_WAYLAND_DUMP of the popup window is itself
  upside down and agrees with the screenshot, which rules out a stride, format or alpha bug.
- Masked icon draws are not flipped. They came back the right way up, so the image draw path and
  its image-to-surface transform, which does carry the standard Core Graphics flip, are right.
- A window context and a bitmap context are created the same way, initWithSurface:flipped:NO, so
  they share one vertical convention.
- What is flipped: the popup window content, and the status bar strip in the main window. Both are
  places LibreOffice renders through a VirtualDevice and blits.

What is not established is where the flip enters. The next experiment is already designed: the
raw-pixel dump written and removed in this session captured the FIRST four big draws, which are all
early and nearly empty. Capture the LAST instead, one file overwritten per draw, with the dropdown
open, and compare that source bitmap against the screen. If the source is already upside down the
fault is in what we drew into it; if it is not, the fault is in the blit.


## Narrowing the upside down text to one transform

2026-08-16, commits 8fa88373 and f7503125. Still not fixed, and this is what is known, so the next
attempt starts here rather than at the beginning.

The dump of the source images settled the first question. The 384x602 image that the popup blit
draws is ALREADY upside down before our blit touches it, and the 1256x634 image behind the document
window is upright: toolbars at the top, ruler under them, page below. So it is not all bitmap
contexts, it is one of them, and the blit is innocent.

The text instrument named the caller exactly:

    CIDER_TEXTCTM ctm=[1.00 0.00 0.00 1.00 0.0 17.0] surface=61x17
      <- KTFont drawGlyphs <- AquaGraphicsBackend::drawTextLayout
      <- OutputDevice::DrawText <- StatusBar::ImplDrawItem <- StatusBar::Paint

The status bar draws each item into its own small bitmap context, and the transform in force has d
POSITIVE. Every text draw caught in that run has a positive d; not one has the negative d that a
bitmap context starts with. That is a context the caller has flipped once, which is the ordinary
CoreText idiom on macOS: scale by minus one in y and draw at negative y.

And the other half, from reading the rasteriser rather than running it: the FreeType path in
O2Context_builtin_FT places each glyph at point.y minus slot->bitmap_top and takes only the SCALE
out of the text rendering matrix. It assumes a top down device space whatever the transform says,
and a positive d is exactly the case that assumption gets wrong.

That is a lead rather than a proven cause, and it is recorded as one. What is proven is the line
above it: the status bar text goes through a bitmap context with a positive d, and the status bar
strip is one of the two things on screen that come out mirrored.


## The upside down text, fixed

2026-08-16, commit 93b9f4c4. Every dropdown list drew upside down, text and all, and so did the
status bar. The document beside them was right, which is what made it hard.

The FreeType path takes the scale out of the text rendering matrix with a square root,

    scaleY = sqrt(b*b + d*d)

which is always positive, so the SIGN of d never reached the glyph. Then every glyph was placed at
the baseline minus its top with its rows written downwards, which is right for one sign and the
mirror image for the other. Both signs happen in this application:

    trm=[1 0 0 -1 ...]   the document window, correct all along
    trm=[1 0 0  1 ...]   the status bar, which draws each item into its own small bitmap context

A glyph outline is defined with y going UP. A negative d turns that into y going down the screen,
which is exactly the order FreeType hands its bitmap back in, so the rows go out as they come. A
positive d leaves the outline pointing the way it started, and the glyph then belongs on the screen
mirrored: the rows go out in reverse and the top of the glyph sits below the baseline. That is done
now, and only in that case.

THE METHOD IS THE PART TO REUSE, because three guesses were wrong before it. First dump the SOURCE
pixels of the blit rather than reasoning about the blit: the popup bitmap was already mirrored and
the document bitmap was not, which ruled out the blit and ruled out all bitmap contexts at once.
Then trace the TEXT RENDERING MATRIX rather than the CTM. The CTM alone cannot answer this question,
because the text matrix is the other half of it and the two multiply.

Looked at, three images and not one: the font dropdown in
docs/wayland-font-dropdown.png reads Fira Sans, Liberation Serif, Noto Naskh Arabic and the rest,
each name drawn in its own face with the Arabic and Hebrew samples the right way round; the status
bar reads Page 1 of 1, the word count, English Denmark, Insert and 100 per cent; and the document
window, the toolbars and our own menus are untouched, because the sign they draw with was already
the other one.

WHAT THE FIX UNCOVERS, and it is the next rung: the toolbar icons redrawn while a dropdown is open
come out blue where they should be black and red, and a few are missing. The format is traced now,
bpc=8 bpp=32 info=0x6 which is alpha-none-skip-first with byte order DEFAULT, colour space RGB, and
initFunctionsForParameters rewrites a default byte order to 32Little on a little endian machine, so
those pixels are read as BGRX. That is not a sufficient explanation on its own, because the same
format is used for the icons that come out correct at startup, and it is recorded as an observation
rather than a diagnosis.


## The violet icons were a byte order

2026-08-16, commit aa6990d9. The LibreOffice toolbar icons came out violet: the blue folder was
magenta, the black floppy was blue, everything with colour in it rotated. Not always, which is what
made it worth chasing properly.

Core Graphics reads kCGBitmapByteOrderDefault as the layout the alpha info spells out, on every
machine: with kCGImageAlphaNoneSkipFirst a pixel is X, R, G, B in memory, in that order. The host
order is what kCGBitmapByteOrder32Little says instead, and a caller that wants it asks for it, which
is exactly what the Wayland surface in this tree does. Onyx2D rewrote Default to 32Little on a
little endian machine, so an XRGB pixel was read as B, G, R.

The same icon in two runs said it exactly:

    correct   srgb(119,205,247)     memory X=255 R=119 G=205 B=247
    wrong     srgb(205,119,255)     those same bytes read as B=255 G=119 R=205

Measured after the change, the same pixel in the harness that was wrong: srgb(119,205,247), the
value the other harness had all along. And looked at: the folder is blue, the save icon is black and
white, the PDF icon has its red A, the printer is blue and grey. The other harness is unchanged down
to the pixel, and the save panel keeps its traffic lights, its blue default button and its blue tick
and still writes the file.

THE PART THAT MADE IT CONFUSING is worth remembering for the next time two harnesses disagree: the
SAME icons were correct in one and violet in the other because the two runs take different paths
inside LibreOffice, not because the compositors differ. The nested 1256x684 run draws 283 masked
icons through drawAlphaBitmap; the headless 1600x1000 run draws none at all. A difference between
harnesses is not always a difference in the environment.

And one instrument cost an application crash to find. Dumping the pixels of a small masked image
took LibreOffice down with Unspecified Application Error, because an image can reach the draw with no
eight bit reader at all. The dump checks first now, and says so when it finds one, since an image
nothing can read is a bug in its own right rather than something to step around quietly.


## Two toolbar defects, characterised and not fixed

2026-08-16. With the flip and the byte order fixed, two things in the LibreOffice toolbar are still
wrong. Neither is fixed here; both are pinned down far enough that the next attempt can start from
evidence rather than from a screenshot.

THE FIRST TOOLBAR ROW STOPS AFTER REDO, in the nested 1256 by 684 harness. Twelve icons draw, new,
open, save, PDF, print, preview, cut, copy, paste, clone, undo and redo, and then the row is empty
to the right edge with NO overflow chevron, while the second row is complete and does show one. The
same toolbar in the headless 1600 by 1000 harness is complete. Colour is ruled out, since the icons
that do draw are now correct to the pixel, and so are missing readers, since CIDER_IMAGE_NOREADER
never fired. What is not established is whether the missing icons are drawn at all, and the next
step is to count the masked draws against the icons visible on screen.

THE FONT NAME BOX GOES SOLID BLACK WHEN CLICKED, and the trigger is one action rather than a repaint
in general. The shots either side of it say so: a3 and b0 have the box white at 255,255,255, the
harness clicks at 300,95 which is inside it, and b1 has it black at 0,0,0 with a 1,1,1 fringe. The
size box next to it is untouched. The picture is docs/wayland-font-box-black.png.

A missing system colour is ruled out: CIDER_WAYLAND_TRACE_COLORS reports ZERO names answering nil in
that run, and selectedTextBackgroundColor is in the table as a pale blue and is reached through
colorWithCatalogName rather than around it. What is left is a blend mode used for drawing a
selection, or a control drawn into a fresh bitmap and then composited as opaque, which would show
whatever the bitmap started as. The next step is to trace the fill colour and the blend mode in
force over that rectangle.


## The black font name box was a transparency layer composited in the wrong place

2026-08-16. The box is white again, with the family name in it and the dropdown next to it working:
docs/wayland-font-box-fixed.png, and the list it opens, drawn with every family in its own face, is
docs/wayland-font-list.png. The bug was ours and it was general, so it is worth writing down how it
was cornered, because five instruments in a row said NO and the sixth said where.

WHAT IT WAS. Core Graphics groups drawing between CGContextBeginTransparencyLayer and
CGContextEndTransparencyLayer and composites the group once at the end. O2Context_builtin ended one
by drawing the layer into the rect (0,0,width,height) IN USER SPACE. User space is not device space
the moment a caller translates the transform, and LibreOffice draws every native control by sending
drawWithFrame:inView: to an NSCell between those two calls, with the transform translated to the
control. So a 1256 by 634 layer was composited at 238,-571, clipped to the control, and the control
was filled with pixels from outside the layer, which read as zero. Solid black, only after a click,
because only then is that control drawn as an editable field.

HOW IT WAS FOUND, in the order the instruments spoke, since each one that says no is a fact:

    CIDER_TRACE_SYSCOLOR      Every named colour the run resolves, 111 of them. Not one nil and not
                              one raise, so a missing system colour was out. It also showed which
                              names LibreOffice actually reads, and textBackgroundColor is not one.
    CIDER_TRACE_FILL=black    Every rect fill in a near black colour, with its caller. THREE in the
                              whole run, all of them OutputDevice::Erase on small offscreens, none
                              of them the box.
    CIDER_FILLPATH            The same filter for path fills, which carry no rect and which the
                              first instrument therefore could not see. Nothing at the box size.
    CIDER_TRACE_DRAWIMAGE     Every image draw with its size. No blit anywhere near 170 by 16, so
                              the box does not arrive as a bitmap either.
    CIDER_FILL_REDPROBE       The one that turned the question around. It repaints the white fill
                              that DOES land there in red, and the box stayed black, which proves
                              the fill is not the last write. Elimination could not have told a
                              wrong colour from an overpaint; a one bit experiment did, in one run.
    CIDER_TRACE_PAINT         Every path, image and shading that touches a given rectangle, with the
                              clip and the surface it lands on. One line named the caller:
                              endTransparencyLayer, an image of 1256 by 634 at 238,-571 under a
                              clip of 148 by 18, from paintCell.

A WRONG SIZE FILTER COST TWO RUNS, and it is the kind of mistake that reads as evidence. The first
fill trace was set to 190 by 20 with a tolerance of eight, and the box is 176 by 20 drawn into a 170
by 16 hole, so the fills that mattered fell outside the window and the trace said the box is never
filled. Measure the rectangle from the screenshot before filtering on it.

WHAT THE FIX IS, and what it costs. A transparency layer now draws straight onto the surface. That
is not the Core Graphics semantic, and the comment in the code says so: a group alpha, a group blend
mode and a group shadow now apply per primitive instead of once to the whole group. The half of the
feature that existed was worse than nothing, because only the edge fill path ever consulted the
layer surface while drawImage and the FreeType glyph renderer wrote to the parent, so a control drew
its background one way and its text the other and then a misplaced composite ran over the result.
Doing it properly needs every primitive to be pointable at a group surface, which is a separate
piece of work and is written down here rather than half done again.

STILL WRONG IN THE SAME TOOLBAR. The first row still stops after redo in the nested 1256 by 684
harness with no overflow chevron, while the second row is complete and the same toolbar in the
headless 1600 by 1000 harness is whole. That one is untouched by this fix.


## Resize, checked again with LibreOffice itself and not with a test window

2026-08-16. The earlier resize evidence in this document is a test window. This is the application:
headless sway starts at 1256 by 684, LibreOffice Writer opens, and the OUTPUT RESOLUTION is then
changed under the running process, twice, with a shot at each size. run-lo-resize.sh in the
scratchpad does it.

    configure number=2 asked=1600x900 frame=1256x684    backing 1256x684 -> 1600x900
    configure number=2 asked=1000x620 frame=1600x900    backing 1600x900 -> 1000x620

AND THE APPLICATION RELAYOUTS, which is the half that a buffer size cannot tell you. At 1600 by 900
the title bar, both toolbars and the status bar span the wider window, the page is centred in the
new width and the sidebar stays on the right edge: docs/wayland-resize-1600x900.png. At 1000 by 620
BOTH TOOLBAR ROWS COLLAPSE AND GROW AN OVERFLOW CHEVRON, the page narrows, and the status bar packs
its fields tighter: docs/wayland-resize-1000x620.png. That is the macOS behaviour, and the chevron
appearing on its own is the part worth pointing at, since it is VCL deciding it has less room rather
than us clipping something.

## The truncated toolbar row is the nested harness, and here is how far that is nailed down

Same day, chasing the first row that stops after redo. What is now established:

    1256 by 684 headless, no input        row complete to the right edge
    1256 by 684 headless, one click       row complete
    1256 by 684 nested in a compositor    row stops after redo, no overflow chevron
    live resize to 1600 and to 1000       relayout correct at both, chevron at the small size

So it is not the width, since the same width headless is whole, and it is not the click, since a
click headless changes nothing. It is the nested backend, WLR_BACKENDS=wayland, and the screen the
application is told about is right there too: screens=1 frame=1256x684 source=wl_output.

The paint trace says what LibreOffice does rather than what it decides. The row is painted WHOLE
TWICE, thirty two icons from x=7 to x=1189, and the third pass paints TWELVE, at exactly the same
positions, 7 through 446. Nothing about spacing or item size changed, the row simply ends early, so
the next step is on the LibreOffice side of the boundary: what does it ask us for between the second
and third pass. The icons in the missing part are drawn and then dropped, which also means this is
not a missing image or a failed reader.


## Interactive, checked headlessly at last, and what it took to make a virtual keyboard tell the truth

2026-08-16. Keyboard and mouse have been checked before in the nested harness, which borrows a real
keyboard from the compositor it runs inside. This is the same check with NO real input device
anywhere: headless sway, a virtual pointer and a virtual keyboard, run-lo-interact.sh.

WHAT IT DOES AND WHAT CAME BACK, all of it looked at:

    types two paragraphs        both appear, correct glyphs, correct wrap, second paragraph after
                                a Return, and the status bar counts the words
    double clicks a word        the word is selected, pale blue band with the text still black,
                                and the status bar says Selected: 1 word, 6 characters
                                docs/wayland-interact-word.png
    Command A then Command B    the whole document is selected and then EMBOLDENED, which means the
                                key equivalent found the menu item and LibreOffice acted on it
                                docs/wayland-interact-bold.png
    clicks the menu bar         the application menu opens with its shortcut glyphs, its separator,
                                its submenu chevron and its shadow
                                docs/wayland-interact-menu.png

THE SHORTCUT PATH IS WHOLE, and it was worth proving because it has four places to fail silently.
CIDER_TRACE_KEYEQ prints the event as NSApplication sees it, then every menu it walks and every item
carrying a key equivalent with its modifiers and its enabled state. For Command B it prints

    CIDER_KEYEQ sendEvent chars=b mods=0x100000 keyWindow=yes mainMenu=yes
    CIDER_KEYEQ   item=Bold key=b mods=0x100000 enabled=1 action=menuItemTriggered:

and then STOPS WALKING, which is how you know the item matched and the action was sent rather than
falling through to the next menu. The whole chain is ours: xkb reports Mod4, the modifiers become
NSCommandKeyMask, the key event carries them, NSApplication sends it to the main menu first, the
menu matches on charactersIgnoringModifiers, and LibreOffice does the rest.

FOUR HARNESS TRAPS, all of them capable of looking exactly like a broken keyboard.

    ONE DEVICE FOR THE WHOLE TEST. wtype makes a virtual keyboard, does what its arguments say and
    destroys it. A client is told a keyboard exists only when the device appears, and binding one,
    receiving the keymap and being given focus is a round trip through the application main loop.
    Seventy characters sent as four short invocations arrived as nine, and a Command B sent on its
    own never arrived at all. Everything the keyboard does now goes in ONE invocation.

    A KEEP ALIVE DEVICE IS WORSE THAN NONE. Holding a second keyboard open does keep the capability
    up, but wl_keyboard is per SEAT: the keep alive modifiers event lands on the same seat and
    clears the Command the other device is holding. Command F opened nothing while a shift was
    being pressed every two seconds beside it.

    -d IS THE DELAY BETWEEN KEYSTROKES AND -s IS A ONE SHOT SLEEP. Typing with -s 60 does not pace
    anything, it sleeps once. The pauses that let the mouse steps run beside the keyboard script
    are -s, and they are what makes one process able to drive both.

    THE POINTER MUST OUTLIVE THE GESTURE, which vptr/cider-vptr already existed for. A click sent
    through wlrctl or sway IPC creates a device that is gone before the application has bound a
    wl_pointer to it.

WHAT IS NOT PROVEN HERE. Command F was sent in an earlier pass and the find bar was not in the shot,
but the shot and the Escape that closes it were half a second apart, so that is a harness timing
question and not a finding. Drag and drop is still untested.


## iTerm2 gets through window construction, and a catch all stub is worse than a missing method

2026-08-16, goal 4. iTerm2 used to die inside its own variable machinery before any window. Seven
gaps later it builds its terminal window without a single unrecognized selector and dies afterwards,
silently, in layer and visual effect setup.

THE FIRST ONE WAS US BEING STRICTER THAN macOS, and it is the one worth reading. NSConcreteMapTable
raised NSInvalidArgumentException for a nil key, while removeObjectForKey: ten lines above has always
warned and returned. A map table is not a dictionary. The proof that macOS accepts it is in the
application, disassembled rather than guessed:

    -[PseudoTerminal finishInitialization...]   makes an iTermVariables with NO values in it and
                                                IMMEDIATELY calls setPrimaryKey with the string id
    -[iTermVariables setPrimaryKey:]            builds a reference to that path and reads its value
    -[iTermVariables valueForVariableName:]     answers nil: nothing has set id yet, and the name
                                                has no dot for the path walk to follow
    -[iTermVariablesIndex setVariables:forKey:] is SIX INSTRUCTIONS and a tail call straight into
                                                setObject:forKey:, with no nil guard anywhere

A shipping application does that on every window it opens. The insert is dropped now rather than
stored, and the caller comes back with a real key through the change block it installed.

A CATCH ALL STUB IS WORSE THAN A MISSING METHOD, which is the other lesson. NSVisualEffectView and
NSTitlebarAccessoryViewController answered EVERY selector through a forwarding stub whose signature
said the method returns void and takes nothing. A setter then arrives with an argument the signature
does not describe, which is the NSForwardSignatureError iTerm2 produced on setMaterial:,
setBlendingMode: and setState:, and a GETTER returns whatever is in the return register, so an
application that asks which material it is gets a number nobody chose. Both classes have real
properties now, and NSVisualEffectView draws its material as the nearest system colour, which is an
approximation and is written down as one: blending behind the window needs the compositor and
blending within it needs the content under the view.

THE REST, all of them ordinary missing API: NSWindow titlebarAccessoryViewControllers and the add,
insert, remove and set methods (kept and answered, NOT placed in the title bar yet); NSWindow
backingScaleFactor and the four backing converters; CALayer contentsGravity, contentsScale,
masksToBounds, needsDisplayOnBoundsChange, backgroundColor, borderColor, borderWidth, cornerRadius,
zPosition, hidden and name (stored and answered, drawing does not honour them yet); the CALayer
action map, where actionForKey: now consults it so that NSNull under a key means no action;
NSTabView controlSize, which the nib decoder has always read and nothing could set; and NSBundle
imageForResource:, the image rather than the path.

WHERE IT STOPS NOW. No exception and no message: the process takes SIGABRT right after it sets up
its visual effect views, and all five threads in the core are parked in libsystem_kernel, which is
what the abort path looks like from outside. The next step is to walk the aborting thread rather
than the thread list.


## A silent abort, a stack overflow and a default forwarding that re-invoked

2026-08-16, goal 4 again. iTerm2 died after its terminal window was created with SIGABRT and no
message. Three instruments were needed, and two of them are new and stay in the tree.

FIRST, WHOSE ABORT. The only line in the log was

    thread caused non-unwinding panic. aborting.

which is a RUST panic reaching an extern "C" boundary. RUST_BACKTRACE=full named the boundary as
wayland_appkit_lib::display_next_event, called from -[NSApplication nextEventMatchingMask:]. There
was no panic of ours in it: an OBJECTIVE-C EXCEPTION was unwinding through a Rust frame declared
plain "C", and the compiler had promised the optimiser that cannot happen, so what ran instead was
panic_cannot_unwind. The declarations that matter now say "C-unwind": objc_msgSend and every alias
of it, the glue that drains the main queue, and the eleven IMPs this backend registers. An exception
raised by application code now travels through us the way it travels through a real AppKit method,
and the FIRST one to come out was -[NSData initWithBase64Encoding:], deprecated in 10.9 and still
called by shipping software. It is implemented, along with -base64Encoding, on top of the modern
pair.

SECOND, THE CRASH THAT NAMES ITSELF. CIDER_TRACE_CRASH=1 installs a handler for SIGSEGV, SIGBUS,
SIGILL and SIGFPE that prints the signal, the fault address and the frames, then restores the
default and re-raises so the core is still written. Two details make it work where the core did not:
it runs on an ALTERNATE STACK, because the fault it was written for is a stack overflow and a
handler with no stack cannot run, and the frames come from the FAULT CONTEXT rather than from
backtrace(), which walks the handler stack and answered zero frames. The frame pointer chain in the
interrupted context is walked by hand with two guards, that it climbs and that it stays aligned.

    cider CRASH signal=11 code=1 addr=0x7fffff5fffc8 rip=... rsp=0x7fffff5fff50 frames=64

Eight bytes past the bottom of the eight megabyte main stack, and the frames repeat:

    -[iTermApplication invalidateRestorableState]
    _CF_forwarding_prep_0 -> ___forwarding___ -> -[NSInvocation _invokeUsingIMP:withFrame:]
    -[iTermApplication invalidateRestorableState]      ... about a hundred and thirty thousand times

THIRD, AND IT IS A GENERAL BUG. -[NSObject forwardInvocation:] set the invocation target to self and
INVOKED it, which dispatches the same selector on the same object. When forwarding is reached
because a lookup failed that is merely pointless; when it is reached because of a SUPER CALL to a
method the superclass does not have, the invocation resolves the selector on the receiver class,
finds the subclass override that made the super call, and calls it again, forever. Any application
that overrides a method this tree is missing and calls super died of a stack overflow with nothing
in the log. macOS raises doesNotRecognizeSelector there, and so does this now.

The missing method underneath was real too: NSResponder had no state restoration at all.
-invalidateRestorableState, -encodeRestorableStateWithCoder:, -restoreStateWithCoder: and
+restorableStateKeyPaths are the documented no-op defaults now. The state is NOT persisted, which is
the behaviour of a system with restoration turned off, and that is written in the code.

WHERE ITERM2 IS NOW: five windows created, including the terminal window at 400x450 and its panels,
NO CRASH, and the application reports one exception of its own, "index (0) beyond array bounds (0)",
which it survives. NO BUFFER IS EVER ATTACHED, so nothing is on screen yet: the windows exist and
have never been shown. That is the next rung.


## Ten missing pieces of AppKit between iTerm2 and a window, found one run at a time

2026-08-16, still goal 4. With the forwarding fix in place, every remaining gap announces itself as
an unrecognized selector instead of a stack overflow, so the loop became: run, read the one line,
implement it, run again. Ten rounds, about three minutes each.

    -[NSPopUpButton setTitle:]            for a PULL DOWN it wrote into item zero of a menu that can
                                          be empty, which is an NSRangeException with nothing in the
                                          message to say which array. iTerm2 titles the overflow
                                          button of its tab bar before it fills it. The title item
                                          is created when there is none.
    the 10.10 accessibility properties    accessibilityLabel, title, value, help, role, subrole,
                                          roleDescription, identifier, children, parent, element and
                                          enabled. Kept with associated storage, so they work on a
                                          view, a cell or a plain object without an ivar anywhere.
                                          NOTHING READS THEM: there is no accessibility bus here.
    +[NSSearchField cellClass]            missing, so a search field got a plain NSTextFieldCell and
                                          every search method went to a cell that never heard of it.
    NSTableView allowsTypeSelect and      stored and answered. Type select does not select by
    floatsGroupRows, rowSizeStyle,        typing, group rows do not float, the style does not change
    usesAutomaticRowHeights, style        the drawing.
    -[NSTableColumn setTitle:]            the header cell string value under its modern name.
    -[NSScrollView scrollerStyle]         follows the scrollers that are there, defaults to LEGACY,
                                          which is what this tree draws.
    -[NSTextStorage initWithAttributedString:]  a primitive Foundation implements on the PLACEHOLDER
                                          class only, so a real subclass never inherits it.
    NSLayoutManager hyphenationFactor     and usesFontLeading, showsInvisibleCharacters,
                                          showsControlCharacters, backgroundLayoutEnabled. Stored;
                                          none of them changes the layout.
    the 10.12 convenience constructors    NSImageView imageViewWithImage:, NSTextField
                                          labelWithString: and its three relatives, NSButton
                                          buttonWithTitle:target:action:, checkboxWithTitle: and
                                          radioButtonWithTitle:.
    NSWindow restorationClass             the window half of state restoration, kept and not
                                          persisted, like the NSResponder methods.

AND THE INSTRUMENT THAT MADE THE LOOP POSSIBLE. CIDER_TRACE_EXCEPTIONS used to live inside
-[NSException raise], which is one of two ways an exception is thrown and not the one Foundation
uses: every range check does @throw [NSException exceptionWithName:...] and never touches -raise.
The trace now runs in the exception PREPROCESSOR, which objc_exception_throw calls for both paths,
so it names the throw and the frames underneath it:

    cider: RAISE NSRangeException: index (0) beyond array bounds (0)
    cider:   CoreFoundation    -[__NSCFArray objectAtIndex:]
    cider:   AppKit            -[NSPopUpButton setTitle:]
    cider:   iTerm2            -[PSMOverflowPopUpButton initWithFrame:pullsDown:]

WHERE ITERM2 IS: three windows created, no exception left in the run and NO WINDOW ON SCREEN. It
ends without a crash and without a message after setting an alpha value on an image view, which is
the next thing to chase. NO REGRESSION: LibreOffice Writer draws its window, both toolbars, ruler,
page, sidebar and status bar, with no unrecognized selector in the whole run.


## A crash handler that loses to the application, and a nib reader that trusted the file

2026-08-16. Two things after the ten API additions, and one of them is only half done.

THE HANDLER HAS TO BE TAKEN BACK. CIDER_TRACE_CRASH printed nothing for a SIGSEGV that the core file
proved was real, because an application is entitled to install its own fatal signal handlers and a
crash reporting one is ordinary. iTerm2 has one, whoever calls sigaction last wins, and a handler
installed at load time always loses to one installed during startup. It is now re-checked from the
event pump and taken back whenever it has been replaced, which costs one sigaction read per pass and
returns immediately when the trace is off. With that, the same fault printed forty one frames.

EVERY INDEX IN THE NIB READER COMES FROM THE FILE, and none of them was checked: the class index of
an object, the value index of a record, and the offset and length of a data payload. A value index
past the end of the table gives a record whose kind, offset and length are whatever was in memory,
which is a wild read dressed up as a decode. They are all bounded now and each says so on stderr
when it fires.

AND THE CRASH IT WAS WRITTEN FOR IS STILL THERE, which is the honest part. iTerm2 dies with

    cider CRASH signal=11 code=1 addr=0x18
    0  libobjc.A.dylib   objc_msgSend + 29
    1  AppKit            -[_NSNIBArchiveUnarchiver _objectAtIndex:]
    2  AppKit            -[NSResponder initWithCoder:]
    ...
    15 AppKit            -[NSBundle(NSNibLoading) loadNibFile:externalNameTable:withZone:]

A receiver of 0x18 is a small integer where an object should be. CIDER_TRACE_NIB says exactly where
in the graph it happens:

    enter 8 NSTextField -> build 8 NSTextField -> enter 26 NSClassSwapper -> build 26
    NSClassSwapper -> enter 27 NSString        and nothing after that

so it is inside the container build or the class lookup for object 27, and NONE of the new bounds
checks fire on the way. The next step is a trace at each branch of _buildContainerOfClass: and
_classForName:, since the frame offset dladdr reports is measured from an exported symbol and does
not point at the call it looks like it points at.


## The nixpkgs iTerm2 is 3.6.10, and what it actually needs is now measured rather than guessed

2026-08-16. The user asked for the iTerm2 nixpkgs ships, not the 3.4.23 that was being used because
3.6.10 was assumed to be out of reach. nixpkgs iterm2 is a darwin package so it cannot BUILD here,
but its source is a plain fetch and the artifact is identical:

    nix eval  nixpkgs#legacyPackages.x86_64-darwin.iterm2.version   -> 3.6.10
    nix eval  ...iterm2.src.outputHash  -> sha256-igdExoh3d8EZBuKkqyNqF087jUISax07rSWG3eenUbw=
    nix store prefetch-file --unpack https://iterm2.com/downloads/stable/iTerm2-3_6_10.zip
                                     -> the SAME hash, so this is nixpkgs iTerm2 to the byte

It is installed in the prefix now; 3.4.23 is kept beside it as iTerm-3.4.23.app.

WHAT IT LINKS, and this is the whole point of measuring: 89 libraries, of which the prefix already
has 63. Of the 16 it does not have, six are WEAK and ten are required to start at all:

    strong   SwiftUI, Charts, FoundationModels, QuickLookUI, ScreenCaptureKit, CryptoKit,
             libswift_Concurrency, libswiftSystem, libswiftSystem_Foundation, libswiftWebKit,
             libswiftUniformTypeIdentifiers
    weak     Network, libswiftCoreMIDI, libswiftOSLog, libswiftQuickLookUI, libswiftSpatial,
             libswiftVideoToolbox and several more the loader may ignore

HOW MANY SYMBOLS EACH ONE OWES, counted from every Mach-O in the bundle, which is 31 files. The
count needs BOTH import formats: these binaries use LC_DYLD_CHAINED_FIXUPS, so the classic bind
tables miss most of it, and the chained fixup import table misses what the older binaries still bind
the old way. The union is 308 symbols:

    SwiftUI 97, libswift_Concurrency 85, Charts 62, FoundationModels 18,
    libswiftUniformTypeIdentifiers 18, CryptoKit 11, libswiftWebKit 8, ScreenCaptureKit 5,
    libswiftSystem 2, QuickLookUI 1, libswiftSystem_Foundation 1

That is small enough to answer with LOAD STUBS: a Mach-O dylib with the right install name and one
trapping function per symbol, so dyld can finish and the application can start. Every stub traps if
it is ever REACHED, which is what tells a load from a use. scratchpad/stub-until-loads.sh runs the
loop: start the app, read the one line dyld prints, build that library, go again.

AND THE SWIFT RUNTIME IS ALMOST ENOUGH ALREADY, which is the surprise. The prefix carries 44 real
Apple Swift dylibs. Against this application:

    libswiftCore        wants 939 symbols, MISSING 8
    libswiftFoundation  wants 467, missing 4
    libswiftos          wants 10, missing 3
    libswiftDispatch    wants 68, missing 1
    libswiftObjectiveC, libswiftAppKit, libswiftDarwin   missing NONE

Eight symbols is a shim, not a port. dyld looks for a symbol in the library the import NAMES, so a
separate dylib cannot supply them: the real library is renamed in place to libswiftKore.dylib (the
name is patched inside the x86_64 slice of the fat file, same length so nothing moves) and a new
libswiftCore.dylib re-exports it and adds the eight. Three of them have a SAFE answer rather than a
stub, and safe is not the same as right: isUniquelyReferenced answers NO, so every copy on write
buffer copies; isStackAllocationSafe answers NO, so the allocation goes to the heap; and the
@available check answers YES, which is what this stack claims everywhere else.

WHERE IT STOPS TODAY: dyld gets all the way through the Swift runtime and stops on
_OBJC_CLASS_$_WKContentWorld. That is the head of a short and completely concrete queue, measured
the same way, of symbols missing from frameworks this tree DOES have:

    CoreServices 9   the LSQuarantine keys and three UTType constants
    AppKit 6         NSTextMovementUserInfoKey, NSFilePromiseReceiver, NSGlassEffectView,
                     NSImageSymbolConfiguration, NSSearchToolbarItem, NSTouch
    AVFoundation 6   Carbon 5 (the TIS input source keys), CoreFoundation 5, CoreGraphics 3
                     (CGDisplayCreateImage and the two screen capture access calls),
                     CoreLocation 3, CoreVideo 2, MetalKit 2, Metal 1, Network 1, WebKit 1,
                     CoreMedia 1, ApplicationServices 1

About ninety symbols, most of them CONSTANTS. NOTHING OF THIS IS IN THE TREE YET: the stubs and the
shim live in the prefix and in scratchpad/swiftstubs, so this section is a measurement and a method,
not a build. Putting them in means BUCK targets and packaging entries, which is the next rung.


## Working the load chain: the constant literal classes, and the constants under them

2026-08-16, continuing the nixpkgs iTerm2. Each round is one line from dyld, one implementation, one
run. Since the last entry the chain has moved from CryptoKit through eight more symbols.

THE CONSTANT LITERAL CLASSES are the interesting ones. A current SDK compiles @42, @3.5, @[a, b] and
@{k: v} in a file with no dynamic parts into STATIC objects in __DATA, whose isa fields point at
NSConstantIntegerNumber, NSConstantDoubleNumber, NSConstantFloatNumber, NSConstantArray and
NSConstantDictionary. The compiler lays the instances out, so the implementation declares the same
fields in the same order and answers the ordinary questions about memory it did not allocate. Two
things follow from the instances being static and both are implemented: they can never be
deallocated, so retain answers self and release does nothing, and they can never be mutated, so
nothing writes.

WHERE THEY HAD TO GO is not obvious and the linker settles it. The three number classes are in
FOUNDATION, because that is where NSNumber is a real class in this tree, and CoreFoundation has only
__NSCFNumber, so a static subclass cannot even link there. The two collection classes are in
CoreFoundation, where NSArray and NSDictionary are. That also matches the imports: dyld expects the
numbers in Foundation and the collections in CoreFoundation, and Foundation re-exports
CoreFoundation rather than the other way round.

THE CONSTANTS, each one a string or a number whose VALUE has to be the one macOS uses, since a key
that differs by a character is a setting that silently does nothing: AVVideoCodecTypeH264 and the
three H264 profile levels, AVVideoProfileLevelKey, AVMetadataKeySpaceQuickTimeMetadata,
NSURLContentTypeKey, kCLErrorDomain and the six CoreLocation accuracies.

WHERE THE CHAIN IS NOW: _kCMMetadataBaseDataType_RawData in CoreMedia, with the CoreServices
quarantine keys, the Carbon TIS input source keys, CoreVideo, MetalKit and two classes behind it.
Every one of them is in the measured list in the section above.


## Two more rounds, and a correction to the missing symbol list

2026-08-16. kCMMetadataBaseDataType_RawData in CoreMedia, with the six other metadata base types
beside it, and the two CoreVideo CG compatibility keys. Both are identifiers rather than behaviour:
what matters is that the VALUE is the one macOS uses, since a dictionary key that differs by a
character is a request that is silently ignored.

AND A CORRECTION WORTH KEEPING. The per framework counts in the measurement above OVERSTATE the work,
because the check compares what an import asks of a library against that library EXPORTS TRIE, and a
trie does not list what the library RE-EXPORTS. The Carbon input source keys are already in
HIToolbox, which Carbon re-exports; the LSQuarantine and UTType constants are already in
LaunchServices, which CoreServices re-exports; most of the Foundation row is CoreFoundation, which
Foundation re-exports. So the honest list is the one dyld produces, one line per run, and it is
shorter than ninety.

WHERE IT STOPS NOW: _OBJC_CLASS_$_MTLCaptureDescriptor. Metal is a MATERIALISED pin, so that one is a
patch file rather than an edit, which is the next rung rather than this one.


## The metal pin cannot be re-materialised, so the chain is blocked on a fetch and not on code

2026-08-16. The next symbol after the CoreVideo keys is _OBJC_CLASS_$_MTLCaptureDescriptor. Metal is
a FETCHED pin, so the class is a patch file rather than an edit, and the patch is written and proved
against the materialised tree: vendor/patches/metal/0001-a-capture-descriptor-to-go-with-the-manager.patch
adds the descriptor beside the manager it belongs to, holding the capture object, the destination
and the output URL, and capturing nothing because there is no GPU trace on this system to write.

IT CANNOT BE APPLIED, and the reason is not the patch. Re-materialising the pin fetches it again and
the fetch no longer matches the manifest:

    error: hash mismatch in fixed-output derivation source.drv
             specified: sha256-fMa6Bgw0hlgJ8C5p05Jt5O+MqB0kMHrQuqmHWAaXmFw=
                got:    sha256-YyHGLJ/SBFN43UC6aNLfELlAOU0cVTflvTBr1y09JlM=

for darlinghq/darling-metal at rev ae20248dc144beab899e38752f5a530f28a0ea56, which nix/submodules.json
pins with recursive true. A pinned rev whose content hashes differently means either the archive
upstream serves changed or a submodule under it moved. THE HASH IS NOT TO BE PASTED OVER: the whole
point of the pin is that the content is fixed, and replacing the expected hash with whatever is being
served today accepts a change nobody has looked at. What is needed is to find out WHICH file differs,
which is a fetch of both and a diff, and that is the next rung for this pin.

Two consequences worth stating. Any patch to metal is blocked until then, so the iTerm2 load chain
stops here. And a FRESH CHECKOUT cannot build metal at all today: the copy in vendor/src exists only
because an older fetch is still in the store.


## Drag selection works, which was the last untested part of interactive

2026-08-16. The three loop criteria have been checked with clicks, typing and shortcuts, but a DRAG
had never been tested: a press, several motions spread over real time, and a release. It is the one
gesture sway IPC cannot produce, because the virtual device it makes for a command list dies with
the command list, so the press and the release arrive with the same timestamp and no motion is ever
sent with a button held. vptr/cider-vptr exists for exactly this.

run-lo-drag2.sh types two paragraphs, then presses at x=300 on the second line, moves through 360,
430 and 500, and releases at 560. What comes back, looked at rather than counted:

    cond paragraph, typed by a keyboard th        selected, pale blue band, text still black
    Selected: 7 words, 38 characters              in the status bar

which is the range the drag covered, so the press, the motions and the release all arrived in order
and were interpreted as one gesture. docs/wayland-interact-drag.png.


## The pin was never wrong: the MATERIALISER fetched it as a tarball

2026-08-16. The hash mismatch that blocked the metal pin is not upstream drift and not a changed
archive. It is scripts/buck-src.nu fetching every pin with fetchFromGitHub:

    let expr = "... pkgs.fetchFromGitHub { owner; repo; rev; hash; }"

A GitHub archive tarball contains NO submodule content and no LFS objects, so its NAR hashes
differently from the fetchgit the manifest hash was made with. nix/lib/cider-src.nix has always
chosen the right fetcher (fetchgit with fetchSubmodules for a recursive pin, fetchLFS for the swift
one); the script had a comment claiming it used the same arguments, and it used them only for the
simple case.

PROVED RATHER THAN ARGUED, in one line:

    nix-prefetch-git --url https://github.com/darlinghq/darling-metal --rev ae20248... \
        --fetch-submodules
    -> "hash": "sha256-fMa6Bgw0hlgJ8C5p05Jt5O+MqB0kMHrQuqmHWAaXmFw="

which is the manifest hash EXACTLY. The content upstream is intact; the fetch recipe was wrong. And
the store agrees: the old cider-sub-vendor-pins-metal path still hashes to the same value.

The script now mirrors cider-src.nix, and the blast radius is the seven recursive pins (libxpc,
corecrypto, IOKitUser, openpam, xcbuild, nghttp2, metal) plus the one LFS pin (swift). Every one of
them would have failed the same way, which means NONE of them could be re-materialised, and that is
exactly the class of pin most likely to need a patch.

WITH THAT FIXED, metal takes patches: MTLCaptureDescriptor beside the manager it belongs to, and
MTKTextureLoader with its option keys, which answers nil with an error for every load because no
device here can hold a texture. The chain then moves to the async URLSession data(from:delegate:)
in libswiftFoundation, which is the same shim problem as libswiftCore and is next.


## dyld is satisfied: the nixpkgs iTerm2 loads, and dies in an image initialiser

2026-08-16. The libswiftFoundation shim is the same shape as the libswiftCore one: the real overlay
is renamed in place to libswiftKoundation.dylib, the name patched inside the x86_64 slice at equal
length so nothing in the file moves, and a new libswiftFoundation.dylib re-exports it and adds the
four symbols a 12.4 SDK asks for. All four TRAP rather than answer, deliberately: they are a
throwing read, a throwing write and an ASYNC URLSession fetch, and a stub that returned an empty
Data would be a silent wrong answer inside a program that is downloading something.

WITH THAT IN PLACE, DYLD IS DONE. No missing library and no missing symbol remains for iTerm2
3.6.10: the process gets past the loader, the Objective-C runtime starts registering classes (the
FMDB duplicate class warnings are ordinary, the app ships its own copy of a framework this prefix
also has), and image initialisers run.

AND THEN IT DIES, with SIGSEGV, in an initialiser. DYLD_PRINT_INITIALIZERS names every image as it
is about to run one, and the last two lines are libc++, so the fault is inside that initialiser or
the next image before its line reaches the log. NOTHING IS PRINTED by the crash handler, and the
reason is structural rather than a bug: CIDER_TRACE_CRASH installs the handler from the Wayland
backend, which AppKit loads when the application asks for a display, and this crash happens long
before that. The next rung is to install the handler EARLIER, from an image that is already loaded
at initialiser time, and then read the frames the way every other fault in this port has been read.

WHAT IS AND IS NOT IN THE TREE. The load stubs for the eleven missing libraries and the two Swift
shims are in the PREFIX and in scratchpad/swiftstubs: they are how the measurement was taken, not a
build. What is in the tree is everything a framework this port owns had to gain: WKContentWorld, the
empty collection storage, the constant literal classes, the modern AppKit symbols, the CoreGraphics
screen capture answers, the AVFoundation, CoreLocation, CoreMedia and CoreVideo constants, and the
two metal patches.


## A crash handler that can be inserted, and the reason it does not reach the application

2026-08-16. src/darwin/crashtrace is a dylib whose only job is to be there before anything else:
a constructor installs handlers for SIGSEGV, SIGBUS, SIGILL, SIGFPE and SIGTRAP, and an inserted
library is initialised before the main executable and every framework it links, which is what the
backend copy of this handler cannot do for a fault during image initialisation.

TWO THINGS IT LEARNED THE HARD WAY, both now in the code. It CHAINS to the handler that was there
before instead of restoring the default: Darling delivers some faults through SIGSEGV on purpose,
and the first version turned the shell helper own kevent wait into a kill. And it can be limited to
one process, because an inserted library is inserted into everything the prefix runs: bash,
path_helper and shellspawn all load it, and CIDER_TRACE_CRASH can name a substring of the
executable path instead of 1.

IT WORKS, and it does not reach iTerm2. The handler installs in /bin/bash and /usr/libexec/path_helper,
prints a chained trace for the shell helper fault in kevent, and the application never appears in
the list at all, while the same run shows the application own initializers running. So
DYLD_INSERT_LIBRARIES is not reaching that process. The most likely reason is the one macOS has:
dyld PRUNES the DYLD_ environment for a restricted binary, and iTerm2 is signed with library
validation. That is the next thing to establish, and the alternatives if it holds are to install the
handler from an image the application already loads early, or to run the check that prunes and see
what it decides.

So the SIGSEGV in an image initialiser is still unexplained: what is known is that it happens after
libc++ initialisers, before AppKit, with the loader fully satisfied.

## The fault is before CoreFoundation, and the stubs are the likely reason

2026-08-16. CoreFoundation now opens the crash handler from its own initialiser when
CIDER_TRACE_CRASH is set, which is on the path every application takes and needs no DYLD_ variable
that dyld may prune. It is dlopen rather than a second copy of the handler, so the alternate stack
and the chaining live in one place.

AND IT STILL PRINTS NOTHING, which is itself the measurement: CORE FOUNDATION IS NEVER INITIALISED.
A probe at the top of __CFInitialize did not fire, and DYLD_PRINT_INITIALIZERS ends at the two
libc++ initialisers. So iTerm2 3.6.10 dies BEFORE CoreFoundation, in or just after libc++.

WHAT THAT POINTS AT, stated as a hypothesis with its reasoning rather than a conclusion. The
difference between this run and every run that got further is the ELEVEN LOAD STUBS. Of the 308
symbols they answer, many are Swift TYPE METADATA and PROTOCOL CONFORMANCE descriptors, and this
file defines every one of them as a FUNCTION. dyld is satisfied by that, because dyld only binds
addresses. The Swift runtime is not: image initialisation walks the conformance and metadata
sections of every loaded image and DEREFERENCES those addresses as structures, and a function is
not a structure. That is exactly the shape of a SIGSEGV during initialisation with the loader
already finished.

If it holds, it also says something about the ceiling: SwiftUI cannot be answered with stubs at all,
because what an application needs from it first is metadata, not code. The way to prove it is a
handler that is installed before libc++, which means dyld itself or libSystem rather than
CoreFoundation, and that is the next rung.


## A correction: that SIGSEGV is not a fault, and it is not the application

2026-08-16, and this entry corrects the two before it. The core dump from the iTerm2 3.6.10 run was
read rather than assumed, and it says something different from what was written:

    NT_SIGINFO   signo=11 code=0 addr=0x2
    NT_PRSTATUS  pid=2 ppid=1 cursig=11

si_code 0 is SI_USER, which means the signal was SENT rather than raised by a memory access, and for
a sent signal the field that was read as a fault address is the sender pid. So nothing dereferenced
address 0x2. And the process the core belongs to is PID 2 with parent 1 INSIDE THE GUEST, which is
the shell helper that starts the application, not the application: the same helper whose stack the
inserted handler printed earlier, twelve frames ending in listenForConnections and main.

WHAT IS ACTUALLY KNOWN, with the guesses removed:

    the loader is satisfied      no missing library, no missing symbol
    initialisers begin           libobjc, libSystem, libc++ all print through
                                 DYLD_PRINT_INITIALIZERS
    and then it stops            CoreFoundation never initialises, and neither does libswiftCore,
                                 whose initialiser would run before the application own
    the shell reports 1          which is an ordinary exit status, not 128 plus a signal

So the application is not crashing where the last two entries said it was. It stops between the
libc++ initialisers and the Swift runtime initialiser, and the core that was being read all along
belongs to the helper process.

THE HYPOTHESIS ABOUT STUB METADATA IS THEREFORE UNSUPPORTED SO FAR. It may still be right, and the
new suspect beside it is the libswiftCore SHIM itself: the real runtime was renamed to
libswiftKore.dylib and re-exported under the old name, and the Swift runtime registers its own image
during initialisation. The next rung is to find out whether the application process produces a core
of its own at all, and to instrument the exit rather than the signal.


## Two facts and a second retraction: the app EXITS 1, and the dyld trace was never about it

2026-08-16. Two controls, each one line, and both change what the previous entries mean.

EXIT CODES PROPAGATE THROUGH cider shell, which was assumed and is now measured:

    cider shell /bin/bash -c "exit 0"   ->  0
    cider shell /bin/bash -c "exit 3"   ->  3

So PROBE_EXIT=1 from the iTerm2 run is the APPLICATION exiting with status 1. It is not killed, it
does not fault, and it does not abort: it exits, the way a program exits when it has decided to.

AND THE INITIALISER TRACE WAS NEVER ABOUT THE APPLICATION. DYLD_PRINT_INITIALIZERS printed the same
three groups, ten libobjc initialisers then libSystem then two libc++, exactly three times, once per
process: bash, path_helper and the shell helper. The application is missing from that list entirely,
and the reason is the one already established for DYLD_INSERT_LIBRARIES: dyld PRUNES the DYLD_
environment for a restricted binary, and iTerm2 is signed with library validation. So the sentence
in the entry above, that it stops after the libc++ initialisers, describes the HELPERS. What the
application does after loading is not visible in any of these runs.

WHAT IS STILL TRUE. The loader is satisfied for the application: no missing library and no missing
symbol. It gets far enough to load its own frameworks, because the duplicate class warnings for FMDB
come from the application bundle against the copy in this prefix. And then it exits 1 with nothing
on stderr.

THE NEXT RUNG IS THEREFORE ABOUT VISIBILITY, not about a fault: find an instrument that survives a
restricted binary. CoreFoundation opening the crash handler was meant to be that, and it prints
nothing, which now has two possible meanings rather than one: either CoreFoundation is never
initialised, or the application never gets that far. The way to tell them apart is a print from an
image that is loaded and initialised even earlier, and libSystem is the candidate.


## The fault is real after all, and it is in load_categories_nolock

2026-08-16. strace on the whole process tree, filtered to write, exit_group and the signals, ends the
argument about what happens to iTerm2 3.6.10:

    [guest kprintf] sigexc_handler(11, ...)
    [guest kprintf] sigexc: have RIP 0x74887AA5B56A
    [guest kprintf] sigexc: emulating default signal
    kill(0, SIGSEGV)
    --- SIGSEGV {si_code=SI_USER, si_pid=2} ---   +++ killed by SIGSEGV (core dumped) +++

So there IS a genuine signal 11 first. What the core showed, a sent SIGSEGV from pid 2, is the
SECOND one: Darling sigexc emulates the default action by killing the process GROUP, which is also
why the shell helper died and why the harness saw an ordinary exit status. Both of the previous two
entries were reading that second signal.

AND THE GUEST HANDLER PRINTS THE FAULTING RIP, which the core resolves through its NT_FILE note:

    0x74887AA5B56A  libobjc.A.dylib+0x3356a
                    load_categories_nolock(header_info *)::$_0::operator()(category_t * const *)

That is the Objective-C runtime ATTACHING CATEGORIES from a loaded image. It walks the category list
of each image and follows each category class pointer, and one of those pointers is not a class.

WHICH MAKES THE STUB THEORY CONCRETE AND SHIFTS IT. The load stubs answer eleven libraries with one
TRAPPING FUNCTION PER SYMBOL, and some of those symbols are _OBJC_CLASS_$_ names:
SCContentFilter, SCShareableContent, QLPreviewPanel and their relatives. dyld is satisfied, because
dyld binds addresses. The Objective-C runtime is not: a category in the application that extends one
of those classes hands load_categories_nolock a pointer to a FUNCTION where a class object belongs,
and the first field it reads is nonsense.

So the next rung is not a mystery, it is a generator change: a stub for an _OBJC_CLASS_$_ symbol has
to be a REAL Objective-C class, compiled as Objective-C against libobjc, not a trap. The Swift
metadata symbols have the same shape of problem behind them and are the rung after that.


## The class stubs became real classes, and the nixpkgs iTerm2 reached AppKit

2026-08-16. The load_categories_nolock fault said what to do and it worked. Six of the stub symbols
are _OBJC_CLASS_$_ names, QLPreviewPanel and the five ScreenCaptureKit classes, and they are now
compiled as REAL Objective-C classes against libobjc instead of trapping functions. With that:

    cider-wayland-appkit register=ok class=NSDisplayWayland
    cider-wayland-appkit init=ok display=connected globals=57 seat=true output=true

iTerm2 3.6.10 runs its own main, reaches NSApplicationMain, connects to the compositor through this
backend and starts decoding MainMenu.nib. That is the first time the nixpkgs build has executed a
line of its own code.

WHAT IT FOUND NEXT, in order, each fixed and each a real gap:

    -[NSConstantIntegerNumber shortValue]     the constant number classes answered only the natural
                                              width. Every width converts now, which is what an
                                              NSNumber does.
    -[NSConstantDictionary keyEnumerator]     a fault on address 1, which is a COUNT being used as a
                                              pointer: the ivar order was wrong.
    -[NSScreen localizedName]                 in AppKit since 10.15 and missing. It answers a plain
                                              descriptive name, since the compositor hands out no
                                              marketing name for a display.

AND ONE THING THAT IS EVIDENCE RATHER THAN UNDERSTANDING, said plainly in the code: the two constant
collections do not agree about where the count goes. The dictionary works with the count LAST and
the array with the count FIRST, and both orders were established from a fault address rather than a
document. The reliable way to settle it is to read a constant instance out of the __DATA section of
a binary that has one. Until then they are measured guesses.

WHERE IT STOPS NOW: -[NSClassSwapper initWithCoder:] sending a message to 0x18 while decoding the
main nib, which is the SAME fault the 3.4.23 build hits. So the two versions have converged on one
bug in this port nib reader, and that is now the single thing between iTerm2 and a window.


## The nib reader freed an object that was still running, and the wall after it is Swift metadata

2026-08-16. The fault both iTerm2 versions converged on is a USE AFTER FREE in this port nib reader,
and it is one line.

-[_NSNIBArchiveUnarchiver replaceObject:withObject:] released the object it was replacing. Its one
caller is -[NSClassSwapper initWithCoder:], which replaces ITSELF with the object it has just
allocated and then keeps going: it reads its own ivars afterwards to send initWithCoder: to that
object. The swapper only reference is the one the instance table holds, so releasing it there
deallocated it MID METHOD, and the next ivar read came out of freed memory. What that looks like
from outside is nothing like a use after free: objc_msgSend faulting with a receiver of 0x18,
sixteen frames into a nib decode. It is an autorelease now.

AND THE WALL AFTER IT IS THE ONE PREDICTED TWO ENTRIES AGO. iTerm2 3.6.10 now gets past the nib and
dies in the Swift runtime:

    0  libswiftKore.dylib     swift_checkMetadataState + 27          fault address 0
    2  libswiftKore.dylib     swift_getGenericMetadata + 1477
    4  iTermSwiftPackages     WebExtensionsFramework.BackgroundScriptNavigationDelegate ...
    6  libswiftKore.dylib     swift_getSingletonMetadata + 949
    8  libobjc.A.dylib        realizeClassMaybeSwiftMaybeRelock
    9  libobjc.A.dylib        realizeAllClasses

So the Objective-C runtime is realising every class, one of them is a Swift class whose metadata has
to be instantiated, and instantiating it walks into a type this prefix answers with a LOAD STUB. A
stub can satisfy dyld, which binds addresses; it cannot satisfy swift_checkMetadataState, which
reads a metadata record. This is the ceiling the stub approach was always going to hit, now with the
frames to prove it rather than a hypothesis.


## iTerm2 3.4.23 opens its terminal window path, and two more real gaps on the way

2026-08-16. With the nib use after free fixed, the 3.4.23 build launches, runs a stable event loop
and gets as far as building a terminal window. Two things had to be fixed to get there and both were
mine to fix.

THE EMPTY SINGLETONS NEEDED A CONCRETE CLASS. Building __NSDictionary0__ with
objc_constructInstance took the class it was given literally, and NSDictionary is ABSTRACT: the
first -count on it raised

    NSDictionary count requires a subclass implementation

which iTerm2 hit while registering a built in function with an empty dictionary literal in it. That
was a regression from the storage change two entries ago, and it is fixed with two small concrete
classes, __CiderEmptyDictionary and __CiderEmptyArray, which implement the primitives an empty
collection needs and nothing else.

ALLOWS DEFAULT TIGHTENING FOR TRUNCATION is a real 10.11 property and it was missing from both the
cell and the view. macOS squeezes inter character spacing a little before it truncates; this tree
does neither automatically, so the value is KEPT AND NOT ACTED ON, which the code says. The view
forwards to its cell, because a label is what a caller has in its hands and that is where the setter
arrives.

WHERE IT STOPS NOW, and it is a good deal further than a window that never opened:

    0  libobjc.A.dylib   objc_release + 37
    1  AppKit            -[NSCell setObjectValue:] + 91
    3  AppKit            -[NSControl setStringValue:]
    5  iTerm2            -[iTermWindowShortcutLabelTitlebarAccessoryViewController updateLabel]
    6  iTerm2            -[PseudoTerminal finishInitializationWithSmartLayout:...]
    13 iTerm2            -[iTermUntitledWindowStateMachine openWindowIfWanted]

So the application IS opening its terminal window, and the fault is in releasing the old object value
of a cell. That is the next rung, and the titlebar accessory controller in the frames is one this
port only just gained, which makes it the first thing to look at.


## The index set kept its ranges unsorted, and that is what both iTerm2 crashes were

2026-08-16. iTerm2 3.4.23 stopped crashing today, and the fix was not in AppKit at all. Three
defects, all in the Foundation NSIndexSet, all on the same path:

THE RANGES WERE NOT SORTED. -addIndex: finds the range that must PRECEDE the new one and then calls
DL_INSERT, which inserts BEFORE the node it is given. So the new range landed on the wrong side:
adding 0, 4 and 13 in ascending order produced

    index 0 -- index 13 -- index 4

Everything downstream assumes sorted order. -count sums the lengths and says 3, while
-indexGreaterThanIndex: walks the list and stops at 13, so -[NSArray objectsAtIndexes:] filled two
of the three slots it had malloced and handed the third, uninitialised, to its caller. That is
where the two failures came from: sometimes the tail read as nil, and NSSet raised

    The object at objects[2] is nil.

and sometimes it read as garbage and CFSetCreate faulted in objc_msgSend with a receiver of 0x18.
Same bug, two faces, which is why chasing either one alone did not converge. The split path in
-removeIndexesInRange: had the identical mistake.

THE CACHE OVERRAN TWO BUFFERS AND WAS NEVER USED. NSIndexSetBuildCache switches from a 32 entry
stack array to the heap at rangeCount > 32, one entry after the array is full, with capacity still
0, so it wrote past the stack array, then malloced ZERO bytes, then wrote through that, and never
copied the entries it had already gathered. It also never set _cacheValid, so every reader has
always taken the linear path and the cache was rebuilt, and leaked, on every -count. It is not
built any more, and re-enabling it now has a written list of what must be true first.

AN UNDERFILL IS NOT SILENT ANY MORE. -[NSArray objectsAtIndexes:] says so and clamps to what it
actually filled, because handing uninitialised malloc to a caller is how this became two unrelated
looking crashes.

WHERE ITERM2 3.4.23 IS NOW: no crash, no raise. It builds its terminal window and then fails in its
own code, with its own diagnostic:

    Failed to create grammar: Error Domain=CPEBNFParserErrorDomain Code=1 Could not parse EBNF for
    grammar. 1:2: Found <Error>, Expected {(Identifier)}

so the next rung is the CoreParse tokeniser, which is the expression parser iTerm2 builds at
startup. Still NO WINDOW ON SCREEN.

## Why iTerm2 3.4.23 and not the 3.6.10 that nixpkgs ships

MEASURED, not assumed. nixpkgs iterm2 is 3.6.10 and its main binary STRONG links SwiftUI:

    strong  /System/Library/Frameworks/SwiftUI.framework/Versions/A/SwiftUI     Contents/MacOS/iTerm2
    strong  /usr/lib/swift/libswift_Concurrency.dylib                           Contents/MacOS/iTerm2
    strong  /usr/lib/swift/libswiftWebKit.dylib                                 Contents/MacOS/iTerm2
    WEAK    /System/Library/Frameworks/Charts.framework/...                     Contents/MacOS/iTerm2
    WEAK    /System/Library/Frameworks/FoundationModels.framework/...           Contents/MacOS/iTerm2

and what it binds from SwiftUI is not a handful of functions but 46 TYPE RECORDS: the View protocol
descriptor, Text, VStack, HStack, Color, AnyView, ForEach, State, EnvironmentValues, NSHostingView,
GeometryReader and the generic conformances between them. A load stub satisfies dyld because dyld
only needs an address; swift_checkMetadataState reads the record, which is why realizeAllClasses
faults. That is a SwiftUI implementation, not a gap to fill, and the swift pin here is 5.2.2 from
swift.org, which predates _Concurrency entirely.

SO THE APP UNDER TEST IS THE NIXPKGS DERIVATION AT AN OLDER VERSION, not a hand download. nixpkgs
iterm2 is a fetchzip of the iterm2.com stable zip parameterised by version, so overriding the
version is the whole change:

    pkgs.iterm2.overrideAttrs (old: {
      version = "3.4.23";
      src = pkgs.fetchzip {
        url = "https://iterm2.com/downloads/stable/iTerm2-3_4_23.zip";
        hash = "sha256-hQV/jGT/3JOvHBICyCeNnuSYMeeF7lfErN55f+Frg2w=";
      };
    })

The result is BYTE IDENTICAL to the bundle that was already installed, so every earlier measurement
carries over unchanged.


## A scanner that had been refusing to scan, and the cell copies that release twice

2026-08-16, later. iTerm2 3.4.23 went from dying in its own grammar parser to opening a terminal
session. Four separate things, each measured:

THE SCANNER SCANNED NOTHING once anybody set the skip set to nil. -[NSScanner
setCharactersToBeSkipped:nil] is the first line of every hand written tokeniser, and the helper
every scan method starts with answered the STRING LENGTH when there was no skip set. The callers
all compute

    length = [string length] - location

so they got 0 and returned NO. That is why CoreParse could not tokenise a single space and iTerm2
reported

    Could not parse EBNF for grammar. 1:2: Found <Error>, Expected {(Identifier)}

The self test that settled it, run inside the guest on the exact input CoreParse fails on:

    inverted(space)=0 inverted(c)=1 firstNonSpaceFrom1=2 scanned=0 [(nil)] locAfter=1

Every ingredient correct, the scan itself refusing. It reads scanned=1 [ ] locAfter=2 now.

CTFontCopyGraphicsFont WAS A STUB RETURNING NIL, and CGFontGetGlyphAdvances dereferenced what it
got. NSFont is toll free bridged to CTFont on macOS, so applications hand their NSFont straight to
that function; iTerm2 does it when it measures a character cell. Both classes answer -graphicsFont
now, and O2FontGetGlyphAdvances answers NO for a null font, which is what CoreGraphics does.

THE CELL COPIES RELEASE OBJECTS THEY NEVER OWNED. -[NSCell copyWithZone:] starts with NSCopyObject,
a BITWISE copy, and then re-owns the ivars it knows about. Every ivar it forgot is held by two
cells with one reference between them, so the second dealloc is an over release. Audited the whole
hierarchy by comparing what each dealloc releases against what each copy re-owns:

    NSCell            _identifier
    NSButtonCell      _normalImage
    NSTextFieldCell   _placeholder, _allowedInputSourceLocales
    NSBrowserCell, NSMenuItemCell, NSPathCell, NSSearchFieldCell, NSSegmentedCell
                      no copyWithZone: at all, so everything their dealloc releases

Two more found while reading: NSComboBoxCell released a data source it had only ASSIGNED, and
copied a MUTABLE array with -copy, so the copy raised on the next -addObject:.

NINE MISSING APPKIT METHODS, each one an unrecognized selector that killed the application:
scroll elasticity and predominant axis scrolling, colorWithHue:saturation:brightness:alpha: and
colorWithDisplayP3Red:..., -[NSColor colorSpace], colorWithColorSpace:components:count:,
NSColorSpace generic and device spaces, -[NSView allowedTouchTypes],
-[NSLayoutManager glyphIndexForCharacterAtIndex:], the typesetter baseline offset,
-[NSScroller setKnobStyle:] and the transparent titlebar pair. The ones that describe hardware or
chrome this backend does not have are KEPT AND NOT ACTED ON, and the code says so.

WHERE IT IS NOW: iTerm2 3.4.23 builds its window, measures its font, creates a session and loads
the find bar nib. It ends in an over release inside an autorelease pool pop during that nib load,
and in about one run in three, in the same place a cell releases a string that something else has
already freed. Still NO WINDOW ON SCREEN, and the next rung is that over release.


## The nib table released what it did not own, and iTerm2 reached its session

2026-08-16, evening. iTerm2 3.4.23 now builds its window, its tab bar and a terminal session, and
runs a display update cadence. Five more fixes, and the first one is a correction of my own.

THE NIB TABLE OWNERSHIP, corrected. The earlier fix here changed a release to an AUTORELEASE in
-[_NSNIBArchiveUnarchiver replaceObject:withObject:], because releasing deallocated the class
swapper mid method. That was the same bug one pool deep: the reference the table holds is the one
-initWithCoder: is in the middle of CONSUMING, so the swapper release at the end of that method is
THE release, and the autorelease came due at the pool pop and freed it twice. What that looks like
is a fault inside AutoreleasePoolPage::pop with no user frame in sight.

The table does not touch the original at all now, and -_objectAtIndex: settles the count once
initWithCoder: has returned and it can see both objects: if the slot was rewritten mid decode, the
table already retained the replacement and init returned the same object with a second reference,
so one is dropped. Proved by bisect first: leaking the whole table made the pool fault vanish and
carried the application straight into its tab bar.

AN EMPTY RANGE REMOVES NOTHING. -[NSMutableArray removeObjectsInRange:] started at NSMaxRange - 1,
which is -1 for a zero length range at 0, and compared that SIGNED index against an UNSIGNED
location, so -1 was promoted to a huge value, the guard held and it asked for index -1:

    index (-1) beyond array bounds (0)

iTerm2 hit it on the first tick of its throughput estimator, which empties a queue it has just
drained.

THREE MORE GAPS, each of which ended the process: -[NSWindow convertRectFromScreen:] and its three
relatives, which is how anything current converts screen coordinates and how the tab bar places
every tab; +[NSColor windowFrameTextColor] with a recipe in the Wayland colour table; and the
private CGSDefaultConnectionForThread plus CGSSetWindowBackgroundBlurRadius, which iTerm2 binds
LAZILY, so the process aborted at first use rather than failing to load.

NSRunningApplication was a class with one stub method. It can answer about THIS process exactly,
from the running process and its own bundle, so it does: currentApplication, the identity
properties, and NO from the four that would act on another process, which is what the API says
when the operation did not happen.

WHERE IT IS NOW: the application runs. It creates its window, lays out its tab bar, sets up a
session, and exits with status 1 during the first display updates, with no exception and no fault.
The next rung is that exit: the likely candidate is the PTY and the shell behind the session.
Still NO WINDOW ON SCREEN.


## A method with no return statement, and the helper that took the application with it

2026-08-16, night. Two findings, and the second one changes what "the application exits" means here.

A METHOD THAT RETURNS NOTHING IS NOT A STUB. +[NSScrollView
contentSizeForFrameSize:horizontalScrollerClass:verticalScrollerClass:borderType:controlSize:scrollerStyle:]
had a body of one line, NSUnimplementedMethod(), and NO RETURN STATEMENT. That macro only logs, so
the caller read whatever was in the return registers and used it as a size. iTerm2 divides it by
its character cell to choose how many columns its first session gets, which is how a terminal came
to say

    WARNING: Session has -1 width

and give up before showing a window. Both the content and frame directions are implemented now,
with the two rules the modern signature carries: a NIL scroller class means no scroller, and an
OVERLAY scroller floats above the content and takes no space.

A SWEEP FOR THE SAME SHAPE found twelve methods across cocotron whose body is an unimplemented
raise with no return and a non void return type. Nine of them raise (NSInvalidAbstractInvocation
does not return, so those are fine). THREE ARE THE REAL THING, and one was on this path:
+[NSScroller preferredScrollerStyle], which decides whether a scroller takes space at all;
-[NSWorkspace isFilePackageAtPath:], now a real answer from the standard package extensions; and
-[NSPersistentStore loadMetadata:].

THE APPLICATION WAS NOT THE ONE THAT DIED. With SIGABRT added to the crash handler and a core dump
read, the abort turned out to be in a DIFFERENT PROCESS: iTermServer, the helper iTerm2 spawns to
own its pty. It aborted inside mldr in ec_dlopen_fatal, and the guest signal emulation turned that
into kill(0, SIGABRT), which killed the whole process group, application included. From the outside
that looks exactly like the application quietly exiting with status 1.

The fatal elfcalls now SAY WHAT FAILED before aborting, straight to fd 2 with write, since they run
on the elfcall path where the guest arrives on a misaligned stack and Rust formatting machinery
cannot be used. Two lines of output would have replaced a core dump.

WHERE IT IS NOW: the session width warning is gone. The application still ends during its first
display updates, and the last thing on the wire in the newest runs is duct-tape reporting

    [xnu_sys] Trying to lock mutex without an active thread!

repeatedly, which is what a thread that duct-tape does not know about looks like: the shape of a
process that has forked. That is the next rung. Still NO WINDOW ON SCREEN.


## iTerm2 on screen

docs/wayland-iterm2-first-window.png, taken one second after launch in headless weston, LOOKED AT:
the traffic lights, the iTerm2 menu bar with its real menus (iTerm2, Shell, Edit, View, Session,
Scripts, Profiles, Toolbelt, Window, Help) and the black terminal area filling the window. The
backend agrees with the picture:

    cider-wayland-window create=ok number=4 size=585x405 at=131,45 level=0 style=0x10f
    cider-wayland-window mapped=yes number=4 size=585x405 t=0.40
    cider-wayland-window resized number=4 size=1280x720
    cider-wayland-window pixels=drawn number=4 changed=1005802/1019904 colours=64+ centre=ff000000

WHAT IT DOES NOT SHOW, and this is the honest half: there is NO PROMPT and no text in the terminal,
because the session behind it never runs. The window survives about a second and then the whole
process group goes down. The tab bar is not drawn either. So iTerm2 renders its chrome and its
window, and it is not yet a terminal.

The screenshot had to be taken at one second because that is all the time there is; the earlier
runs took theirs at fifty and caught nothing, which is why this looked like an application that
never opened a window at all.


## A fatal signal went to the whole process group, and iTerm2 stays up now

2026-08-16, late. The application was never the process that died. iTerm2 spawns iTermServer to own
its pty; the server aborts while loading, and the guest signal emulation did this:

    // Resend signal to self
    LINUX_SYSCALL(__NR_kill, 0, linux_signum);

kill(0, sig) does not send to self. It sends to EVERY PROCESS IN THE CALLER GROUP, so the helper
took the application down with it, and every other helper too. On macOS a child that crashes never
touches its parent. It sends to getpid() now, and the SIGTSTP branch beside it had the same shape.

MEASURED BEFORE AND AFTER, three runs each, same harness:

    before   PROBE_EXIT=1, PROBE_EXIT=1, PROBE_EXIT=1        window gone after about 1.5 seconds
    after    PROBE_EXIT=0, PROBE_EXIT=137, PROBE_EXIT=0      137 is the harness kill at 30 seconds

So iTerm2 now survives its helper aborting. LOOKED AT the screenshots at 10, 16 and 18 seconds,
including after the harness types into the window: the traffic lights, the iTerm2 menu bar and the
black terminal area are all still there, and NOTHING ELSE IS. No prompt, no cursor, no typed text,
no tab bar, because the session behind the window still never runs.

WHAT IS STILL WRONG, precisely: iTermServer aborts inside mldr in ec_dlopen_fatal, so no shell is
ever started. The fatal elfcalls print the library and the dlerror text now, and can also append to
the file named by CIDER_FATAL_LOG, but neither reaches the log for this process: the application
gives the helper its own fds and its own environment, and under strace the abort does not
reproduce at all, which makes it a timing dependent one. That is the next rung.

LibreOffice is unaffected by the signal change: Writer draws its title bar, menu bar, both toolbar
rows, ruler, page, sidebar and status bar, with zero raises.


## The host loader path now survives an exec, and iTerm2 stops losing its helper

2026-08-16, night. The helper aborted because it could not load libGL.so.1. Proved by running it
both ways:

    without LD_LIBRARY_PATH   cider mldr: FATAL dlopen failed: libGL.so.1: cannot open shared object
    with it                   no fatal

Every Mach-O image that wraps a host ELF library dlopens that library from a CONSTRUCTOR and aborts
if it is missing, so a process that loses the loader path dies before it runs a line of its own
code. iTerm2 spawns iTermServer with an EMPTY ENVIRONMENT, measured from /proc, so it lost it.

THE PATH TRAVELS UNDER TWO NAMES NOW. The private __mldr_elf_path goes in unconditionally, because
an application that curates an environment has no reason to strip a name only this runtime knows;
LD_LIBRARY_PATH goes in only when the caller did not bring its own. mldr retries a failed dlopen
against the directories in the private one, because the dynamic loader reads its search path once
at process start and a value that arrives later changes nothing.

THREE MISTAKES ON THE WAY, all of them silent, and each looked like the fix not working:
  a 16 KB automatic buffer for /proc/self/environ does not fit on the stack this code runs on, and
    the read produced nothing;
  ONE read of 16 KB is not the environment. A shell session carries far more, LD_LIBRARY_PATH sat
    past the cut, and the lookup answered not-present for the one process that mattered;
  the injected strings were block locals, so by the time execve read envp they were dead stack and
    the child received an empty entry. They are alloca now, like the buffer beside them.

MEASURED: abort cores in a 40 second run went from six to ZERO, and the application ran the whole
run. LOOKED AT the screenshots at 12, 18 and 20 seconds: menu bar, traffic lights, black terminal
area, and STILL NO PROMPT AND NO TEXT. One brokenPipe remains in the log, so the session child
still ends; it is no longer the loader that kills it. That is the next rung.


## Two window methods the terminal needs, and where the session stands

2026-08-16, end of the night. iTerm2 now runs a full 45 second harness run without terminating.

TWO MISSING NSWindow METHODS, both found in the applications OWN exception log
(Users/root/Library/Application Support/iTerm2/log.0.txt, which records what it caught):

    -[iTermWindow occlusionState]   unrecognized selector
    -[NSWindow disableBlur]         unrecognized selector, and this one was fatal

occlusionState answers VISIBLE for a visible window, because an application told its window is
hidden stops drawing, which looks like a freeze. The blur pair is private AppKit that a window
server would composite; this one does not, so both are accepted and do nothing.

WHERE THE SESSION STANDS, honestly: the helper no longer aborts, no brokenPipe appears in the last
runs, and the application stays up. There is still NO PROMPT AND NO TEXT in the terminal. The last
exec chain under strace ends at the application itself, so no shell is being started at all yet;
what starts it, and why it does not, is the next thing to measure.

A NOTE FOR WHOEVER LOOKS NEXT: the applications own log is the best instrument here. It records
every exception iTerm2 catches, including the ones it swallows, and it is a plain text file in the
prefix.


## SHELL pointed at a host path, and the terminal got a session

2026-08-16, last rung of the night. The launcher rewrites PATH, TMPDIR and HOME for the guest and
then copies every other host variable verbatim. SHELL is a PATH, and on a nix host it is

    SHELL=/nix/store/fmmhdx9k95s8iqag7zip533mbl3f27sw-bash-5.3p9/bin/bash

which does not exist inside the container. Measured from inside the guest: that path is No such
file or directory, while /bin/bash is right there. Every application that launches "the user shell"
from SHELL therefore fails to exec, and reports nothing more useful than a broken pipe.

SHELL is /bin/bash for the guest now, alongside the other three the launcher already rewrites.

WHAT CHANGED ON SCREEN, LOOKED AT: the iTerm2 title bar reads

    -- 80x25

which is the terminal grid, and it only appears when a session exists. Before this it was empty.
No brokenPipe in the log either.

WHAT STILL DOES NOT WORK: the terminal area is still black with no prompt and no text. A process
watch shows iTerm2 FORKING roughly every five seconds and the child never reaching exec, so the
session child is started and dies before it runs a shell. Under strace the fork does not happen at
all, which makes it timing dependent and means the next measurement has to be taken without it.

LibreOffice is unaffected by the launcher change: Writer draws its title bar, menu bar, both
toolbar rows, ruler, page, sidebar and status bar, with zero raises.


## Why the terminal is empty: the forked child spins, and so does the daemon

2026-08-16, last measurement of the night. The session exists (the title bar says 80x25) but no
shell ever runs. The reason is now measured rather than guessed.

WHAT HAPPENS. iTerm2 forks for its session. The child checks in with the daemon and then never
reaches exec:

    /proc/<child>/status    State: R (running)   Threads: 1
    /proc/<child>/syscall   47 (recvmsg)
    utime/stime over 3 s    14 -> 26 and 84 -> 147, so it is BURNING CPU, not blocked

And the daemon is burning more than the child:

    ciderd  +197 ticks in 3 seconds     (about two thirds of a core)
    child   +124 ticks in 3 seconds

WHAT IT IS. Under strace, which is the only way to see the daemon own messages, a 25 second run
prints

    350 x [xnu_sys] Trying to lock mutex without an active thread!
    351 x [xnu_sys] Trying to unlock mutex without an active thread!

That is src/linux/server/src/xnu/locks.rs: when current_thread() is NULL, xnu_sys_mutex_lock falls
back to the native queue lock and SPINS, with a comment saying anything taking that path must hold
briefly. Something on the forked child path takes it constantly instead.

current_thread() is NULL when there is no MICROTHREAD, so the caller is running on the daemon own
thread rather than on a guest call microthread. Finding which caller that is, and giving it a
microthread (or making the lock park instead of spin), is the next rung. It is the last thing
between iTerm2 and a shell prompt.

A NOTE ON INSTRUMENTS, learned the hard way in this same hour: getenv is NOT usable from
libsystem_kernel. It sits below libc, and a trace gated on getenv there broke the container so
completely that every command answered

    cider: write() to the shellspawn socket failed

Read /proc/self/environ instead, the way execve.c does. And the daemon messages never reach the app
log: strace -f -e trace=write is the only way to read them.


## Half a million closes: the descriptor limit is why the terminal had no shell

2026-08-16, and this is the one that mattered. The guest inherits the host RLIMIT_NOFILE:

    guest   ulimit -n = 524287
    macOS   a few hundred, soft

Cocoa applications are written to the macOS number. The standard way to sanitise a child before
exec is to close every descriptor from 3 up to getdtablesize(), which returns the SOFT limit, so
iTerm2 forking to launch its pty helper turned into over half a million close calls. Every one of
those is an RPC to the daemon here. The child sat in recvmsg burning a core, the daemon burned two
thirds of another servicing them, and the exec never arrived, which is why a terminal window opened
with no shell in it.

mldr now lowers the SOFT limit to 1024 for guest processes and leaves the HARD limit alone, so
anything that genuinely needs more can raise its own the way it would on macOS. Measured after:
guest ulimit -n = 1023, hard still 524287.

WHAT THAT UNBLOCKED, in order, each one measured:
  iTermServer SPAWNS and stays (a process watch sees five of them at 5.6 s where there were none);
  the session reaches TEXT DRAWING, which announced itself by aborting inside
    -[iTermTextDrawingHelper drawFastPathStringWithoutUnderlineOrStrikethrough:...] on a lazy bind
    of _CGContextGetFontSmoothingStyle, a private CoreGraphics call this tree did not have. The
    getter answers 0 and the setter ignores, because there is one rasteriser here with no style
    variants. With it in place the abort is gone and the run survives its full 45 seconds.

ALSO IN THIS ROUND: xnu task creation moved onto a kernel microthread. xnu_sys_task_create takes
xnu mutexes, and with no current microthread xnu_sys_mutex_lock cannot park a waiter, so it spins
on the queue lock; if a microthread holds that mutex the daemon thread spins for a thread only it
can schedule. The lock-without-a-thread warnings dropped from 350 to 255 in a 25 second run. The
remainder come from thread creation, which is the same shape and is chicken-and-egg: creating the
first microthread cannot itself be on a microthread.

WHERE IT STANDS: the window, the menu bar and the 80x25 title are drawn, iTermServer runs, and the
terminal area is STILL BLACK with no prompt. No shell process appears under the server yet. That is
the next rung.

LibreOffice is unaffected by the descriptor change: Writer draws its title bar, menu bar, both
toolbar rows, ruler, page, sidebar and status bar, with zero raises and no too-many-open-files.


## The terminal has no shell because there is no bootstrap port

2026-08-16, and this one is answered in the applications own words. iTermServer now loads and runs,
but it exits within 50 milliseconds of starting, with status 0 and nothing on stderr. Its log goes
to syslog, which does not exist in the container, so it was invisible: strace catches the sendto
that fails, and the message is in the buffer.

    iTermFileDescriptorMultiServer.c:952  Initialize: Server starting Initialize()
    iTermFileDescriptorMultiServer.c:888  InitializeSignals: Installing SIGHUP handler.
    iTermFileDescriptorMultiServer.c:790  MainLoop: Entering main loop.
    iTermFileDescriptorMultiServer.c:686  SelectLoop: Begin SelectLoop.
    iTermFileDescriptorServerShared.c:287 iTermSelect: select returned 2, error = Bad file descriptor
    iTermFileDescriptorMultiServer.c:939  CheckIfBootstrapPortIsDead: Unable to get the type of the
                                          bootstrap port! errno=9
    iTermFileDescriptorMultiServer.c:922  QuitCleanly: QuitCleanly
    iTermFileDescriptorMultiServer.c:993  CleanUp: Cleaning up to exit

So it starts, enters its select loop, asks mach_port_type about its bootstrap port to check whether
its parent is still alive, gets an error, and QUITS DELIBERATELY. That is correct behaviour for the
application. What is missing is ours: this container runs with DARLING_NO_LAUNCHD, whose init is
shellspawn, so nothing ever becomes the bootstrap server and every task inherits a NULL bootstrap
port. From inside the guest:

    launchctl list   ->   bootstrap_parent() 268435459

RUNNING WITH LAUNCHD INSTEAD IS NOT A WAY ROUND IT TODAY. With DARLING_NO_LAUNCHD=0 the run
produces no application output at all and the screenshot is entirely black: no window, nothing.
That is task #47 and it is still open.

SO THE NEXT RUNG IS ONE OF TWO THINGS, and it is worth choosing deliberately: make launchd work as
the container init, or give tasks a valid bootstrap port without it. The second is smaller but has
a trap: a port that exists and is never serviced turns a fast failure into a hang for anything that
actually sends a lookup, which may be worse than what happens now.

WHAT WORKS AS OF TONIGHT: iTerm2 opens its window, draws the traffic lights, the menu bar and the
80x25 title, runs a full 45 second harness run without crashing or raising, spawns its pty helper,
and reaches its text drawing path. The terminal area is BLACK and there is NO SHELL, for the reason
above.


## The three criteria, re-verified after a day of runtime changes

2026-08-16, end of the day. Today changed the signal emulation, the exec environment, the loader
path, the descriptor limit and task creation in the daemon. All of those sit under every guest
process, so the three DONE criteria were re-verified from scratch rather than assumed, by LOOKING
at every image.

RENDERS. LibreOffice Writer, checked after each change: title bar, menu bar, both toolbar rows,
ruler, page with its text, right sidebar and the full status bar. Zero raises, zero unrecognized
selectors, and no too-many-open-files after the descriptor limit changed.

INTERACTIVE, from scratch/run-lo-drag2.sh, six screenshots and every one of them looked at:
  a mouse DRAG selected exactly the run it crossed, and the status bar agrees: Selected: 7 words,
    38 characters;
  the KEYBOARD typed two paragraphs into the document, which are in the picture;
  Command A and Command B took, and the text is bold with the B button lit;
  a mouse CLICK on the application menu opened it: About LibreOffice, Preferences with its Command
    comma, Services with its submenu arrow, Hide LibreOffice, Hide Others, Show All, Quit
    LibreOffice with Command Q.

RESIZABLE, from scratch/run-lo-resize.sh, the compositor changing the output resolution under a
running application:

    cider-wayland-window resized number=2 size=1600x900
    cider-wayland-window resized number=2 size=1000x620

and at 1000x620 the application has RELAID OUT rather than scaled: the toolbar has grown an
overflow chevron, the ruler is shorter, the page is narrower and the status bar has dropped fields.

A HARNESS NOTE WORTH KEEPING. scratch/run-lo-click.sh drives the pointer with wlrctl, and it does
NOT work: wlrctl makes a virtual pointer, sends the click and destroys the device, so the press and
release arrive at the device origin rather than where swaymsg put the compositor cursor. Three
screenshots came out byte identical and the menu never opened. scratch/vptr/cider-vptr holds ONE
device open for the whole script and takes abs/press/release on stdin, which is what run-lo-drag2.sh
uses and why its clicks land.


## Task 47 measured: launchd starts, and its second thread cannot reach the daemon

2026-08-16. Running the container with launchd as init hangs, and now there is a chain rather than
a symptom. The instrument is the one that worked on iTermServer: strace the container and read the
syslog buffers, since nothing here has a syslog socket.

    *** launchd[1] has started up. ***
    /bin/launchctl: Could not open job overrides database at:
        /private/var/db/launchd.db/com.apple.launchd/overrides.plist: 2: No such file or directory
    /bin/launchctl: launch_msg(): Socket is not connected

So launchd DOES start. launchctl then fails because it never learns launchd socket path:
liblaunch asks for it with _vprocmgr_getsocket, which is vproc_mig_getsocket over the BOOTSTRAP
PORT, and that Mach call does not get through.

WHY IT DOES NOT GET THROUGH, and this is the part worth having:

    *** 1:2: dserver_rpc_explicit_mach_reply_port: BAD SEND STATUS: -111 ***
    *** 1:2: dserver_rpc_explicit_mach_msg_overwrite: BAD SEND STATUS: -111 ***
    mach_msg_overwrite failed (internally): -111

The 1:2 prefix is guest pid 1, thread 2, which is LAUNCHD ITSELF, and -111 is ECONNREFUSED on the
per-thread RPC socket to the daemon, not a Mach error. launchd second thread cannot talk to the
daemon at all, so it cannot serve the bootstrap request, so launchctl gets nothing, so no job ever
starts and the container never comes up. launchd then takes a SIGABRT from pid 1.

THAT IS THE NEXT RUNG FOR TASK 47: why a second thread of the container init has an RPC socket the
daemon refuses. Every other guest process in the tree gets one, so it is specific to how PID 1
threads are created or checked in. It also matters well beyond launchd, because a bootstrap port is
what iTerm2 pty helper checks before it will stay alive, and what any XPC service needs.

FOR THE RECORD, the other side of the same run: the overrides database directory
/private/var/db/launchd.db/com.apple.launchd does not exist in the prefix. That one is cosmetic
next to the socket failure, but it will need creating too.


## Correction, and a sharper chain for task 47

2026-08-16. The previous entry said launchd second thread could not reach the daemon and that this
was why launchctl got nothing. THAT WAS WRONG, and timestamps settle it:

    16:30:22.192  *** launchd[1] has started up. ***
    16:30:22.683  /bin/launchctl: Could not open job overrides database at ...
    16:30:22.745  /bin/launchctl: launch_msg(): Socket is not connected
    16:31:01.900  *** 1:2: dserver_rpc_explicit_mach_reply_port: BAD SEND STATUS: -111 ***

The -111 lines come THIRTY NINE SECONDS LATER, when the harness timeout tears the container down.
They are shutdown noise. The failure is at 22.745, and it had already happened.

WHAT IS ACTUALLY MEASURED NOW:

  1. launchd starts.
  2. launchctl needs launchd socket path. liblaunch asks for it with _vprocmgr_getsocket, which is
     vproc_mig_getsocket over the BOOTSTRAP PORT. Failing that, sun_path stays empty, connect never
     happens, and the send reports ENOTCONN as "Socket is not connected".
  3. The child DOES have a bootstrap port. The daemon own task-create log, raised to warning for one
     run, says so:
         xnu_sys_task_create: nsid=1 parent=0x0 parent_bootstrap=0x0          <- launchd, the root
         xnu_sys_task_create: nsid=4 parent=0x...560 parent_bootstrap=0x...140 <- its child, INHERITED
  4. launchd NEVER CREATES ITS SOCKET. The pid1 socket lives at _PATH_VARTMP/launchd/sock, created
     by ipc_server_init, which runs only when job_mig_getsocket is called. After a run there is no
     /private/var/tmp/launchd at all, and no mkdir error in the log either. So job_mig_getsocket
     never ran: THE MIG MESSAGE NEVER REACHED LAUNCHD.

So the question for task 47 is now narrow: a message sent to a valid, inherited bootstrap port is
not delivered to the receiver queue. That is daemon side Mach routing, not the guest, not fork, and
not the environment.

ONE REAL GAP FIXED ON THE WAY, and it is necessary but NOT sufficient: /private/var/tmp did not
exist in the prefix, and neither did the launchd job overrides database directory. mkdir does not
create parents, so even once the message arrives, ipc_server_init would have failed. The launcher
creates both now. Tested: launchd still does not come up, which is why this is written down as
necessary rather than as a fix.

LibreOffice after the launcher change: Writer draws its title bar, menu bar, both toolbar rows,
ruler, page, sidebar and status bar, with zero raises.


## Launchd works: the blocker was one missing directory, and a prefix that could never gain it

2026-08-16. launchd comes up as the container init now, and the chain that got there is worth
keeping because every step of it was measured and two of my earlier readings were wrong.

WHAT IT ACTUALLY WAS. A trace of the syscalls rather than the logs:

    mkdirat(AT_FDCWD, "<prefix>/var/tmp/launchd", 0700) = -1 ENOENT

launchd as PID 1 puts its client socket in _PATH_VARTMP/launchd/sock. mkdir does not create
parents, <prefix>/var/tmp did not exist, so ipc_server_init gave up, job_mig_getsocket answered
BOOTSTRAP_NO_MEMORY, and launchctl reported the ENOTCONN that reads as "Socket is not connected".

TWO WRONG READINGS ALONG THE WAY, both corrected by measuring:
  the -111 ECONNREFUSED lines were teardown, thirty nine seconds after the failure;
  "the MIG message never reached launchd" was wrong too. Instrumenting _vprocmgr_getsocket showed
    bootstrap_port=0x507 kr=0x451, and 0x451 is 1105, which is BOOTSTRAP_NO_MEMORY: the message got
    through, launchd ran ipc_server_init, and IT is what failed.

AND THE REASON THE DIRECTORY COULD NOT COME BACK: setup_prefix runs only when a prefix is first
created, so a prefix made by an older build never gains a directory the runtime later needs. The
directory list is idempotent now and runs on every launch. Verified by deleting <prefix>/var/tmp,
running again, and watching the launcher recreate it and launchd create its socket inside it.

WHAT THAT UNBLOCKS, and this is the part that matters: with launchd as init there IS a bootstrap
port, and iTerm2 gets much further. It now reaches

    -[iTermTextDrawingHelper constructAndDrawRunsForLine:...]
    -[iTermTextDrawingHelper drawFastPathString...]
    -[iTermTextDrawingHelper selectFont:inContext:]
    CTFontCopyGraphicsFont

which is the terminal DRAWING ITS LINES. It crashes there in objc_msgSend with a receiver of 0x18,
so the font it hands over is not an object. Two lines earlier in the same log:

    convertFont:toHaveTrait: failed, Monaco 1
    convertFont:toHaveTrait: failed, Helvetica 2

which is our own AppKit saying it could not apply a trait. That is the next rung, and it is a small
one: -[NSFontManager convertFont:toHaveTrait:] must answer the original font when it cannot apply
the trait, which is what macOS does, rather than something the caller then draws with.

LibreOffice after the launcher change: Writer draws its title bar, menu bar, both toolbar rows,
ruler, page, sidebar and status bar, with zero raises.


## The font iTerm2 draws with is not an object, and a correction about the font manager

2026-08-16. With launchd up, iTerm2 reaches its text drawing and dies on the font. Two things,
one of them a correction.

THE CORRECTION. The previous entry said the next rung was -[NSFontManager convertFont:toHaveTrait:]
answering the original font when it cannot apply the trait. IT ALREADY DOES. The lines

    convertFont:toHaveTrait: failed, Monaco 1
    convertFont:toHaveTrait: failed, Helvetica 2

are OUR OWN NSLog, from a method that then returns the font unchanged, which is the macOS
behaviour. Reading a log line as a defect without reading the code beneath it is the same mistake
in a new place.

WHAT IS ACTUALLY WRONG. iTerm2 takes the font straight out of its attributes dictionary:

    NSFont *const font = cheapString.attributes[NSFontAttributeName];
    [self selectFont:font inContext:ctx];

and what comes out is not an object. CTFontCopyGraphicsFont now checks the pointer before messaging
it and says so:

    CTFontCopyGraphicsFont: 0x47 is not an object

0x47, and on the next line iTerm2 asks the same value for its pointSize and faults at 0x18. So the
value is small, junk, and DIFFERENT between the two reads. That is not a font that failed to
resolve, which would be nil: it is memory being read as an object pointer when it holds something
else.

The guard is worth having on its own account, because a fault inside CTFontCopyGraphicsFont points
at CoreText when the caller is the one holding rubbish, but it does not fix anything: iTerm2
crashes two instructions later in its own code, messaging the same value.

WHERE TO LOOK NEXT: who fills that attributes dictionary, and what our runtime returns to it. The
same dictionary carries a CGColorRef under kCTForegroundColorAttributeName, which is the kind of
CF-in-NS mixing where an object that is not really an object gets retained and released.

LibreOffice after the CoreText change: Writer draws its title bar, menu bar, both toolbar rows,
ruler, page, sidebar and status bar, with zero raises and no not-an-object lines.

## The font was not a font because a glyph had been written on top of it, and the terminal is
## still black for a different reason

2026-08-16, commits b723842f and bb80562e.

THE ANSWER TO THE PREVIOUS SECTION. The attributes dictionary was innocent. A probe on our own
objectForKeyedSubscript: printed on the happy path and never once on a bad value, which is what
turned the question around: the value was not READ wrong, it was WRITTEN over afterwards.

Two classes answer -getGlyphs:forCharacters:length: and they disagree about the width of what they
write. KTFont writes CGGlyph, which is uint16_t. NSFont writes NSGlyph, which is NSUInteger, so
eight bytes on this target. CTFontGetGlyphsForCharacters forwarded the caller buffer to whichever
object it was handed, so an NSFont overran that buffer by a factor of four.

iTerm2 does exactly that. It allocates the buffer with alloca immediately below its locals and takes
the font straight out of its attributes dictionary, where it is an NSFont. The overrun runs up the
stack and over the saved font pointer, two instructions after it is stored. The value that came back
was 0x47, which is glyph index 71.

The function now decides by the argument type encoding of the method it is about to send, and
narrows through a bounce buffer when the receiver writes wide. NSControlGlyph, 0xFFFFFF, does not
fit in a CGGlyph, so it answers 0, which is what CoreText answers for an unmappable character.

HOW IT WAS FOUND, after three wrong guesses (the NSFont cache, convertFont:toHaveTrait:, and the
dictionary literal, all of which were either correct already or a real but unrelated bug):

  1. backtrace_symbols_fd inside the guard. It named the caller as iTerm2 rather than our own code,
     which is what made the application binary the thing to read.
  2. llvm-objdump on the x86_64 slice of the fat binary. The font arrives from a stack slot; the
     slot is filled from objectForKeyedSubscript:; and alloca(length * 2) happens two instructions
     later. That is the whole bug, visible in twenty instructions.
  3. A probe on our side of the lookup, printing unconditionally for its first few calls so that
     silence on the bad case could not be confused with the code not running.

AND THE TERMINAL IS STILL BLACK, for a reason that was hiding behind the crash.
CGContextShowGlyphsAtPositions was a STUB. iTerm2 called it 97 times in one launch: that is its
whole fast text path. It is implemented now, transforming each position through the text matrix,
whose translation is the current text position, and drawing through the same Onyx2D entry point
KTFont drawGlyphs uses.

That is not enough, and the following is measured rather than argued (CIDER_TRACE_GLYPHRUN):

    each run reaches the FreeType rasteriser once per glyph
    with a real O2Font_freetype and a real FT_Face, at pointSize 12
    no glyph fails FT_Load_Glyph
    every glyph blits UNCLIPPED, for example a 7x10 bitmap at 5,96 against a viewport 0,51 1265x669
    CIDER_GLYPH_RED=1 repaints every glyph red and the screen does not change

So the pixels are written into the window surface and are never seen. The next question is whether
that surface is the one presented, or whether something repaints over it after the text.

A TRAP WORTH THE PARAGRAPH. Every one of these traces is capped, and the menu bar draws first. It
ate the whole budget three separate times, so the terminal looked untraced and the natural reading
was that the code never ran. Compare the line number of the LAST trace line against the FIRST line
of the thing being studied before believing any silence.

Still open, both seen in the same runs: CTLineCreateWithAttributedString is a stub called 759 times,
and +[QLPreviewPanel sharedPreviewPanelExists] is unrecognized, raising through
wayland_appkit_lib::input::on_keyboard_enter, which is extern C and cannot unwind, so the process
aborts on keyboard focus in about half of runs.

### The buffer has the text in it

Same day, and it took one more instrument: read the pixel back out of the surface immediately after
the blit (CIDER_GLYPHBACK, added alongside the traces above).

With CIDER_GLYPH_RED=1 the surface holds bright red glyph pixels: rgba 219,0,0,219 and 223,0,0,223,
96 and 93 samples of each, which is red at 86 percent coverage. The screen at those coordinates is
pure black. So the write is not the problem and neither is the colour.

The detail that says where to go next is the ALPHA. On every sample the alpha equals the red
channel. These are premultiplied, so that only happens when the DESTINATION WAS FULLY TRANSPARENT
before the glyph was blended onto it. iTerm2 fills its terminal background opaque black before it
draws any text. That fill is not in this buffer.

So the black rectangle on screen is not this surface at all, and the drawing is going somewhere that
is never presented. Look for where the view backing store and the committed wl_buffer diverge: a
resize that allocates a new surface while drawing still holds the old one, or a back buffer that is
never swapped. CIDER_WAYLAND_DUMP writes no files even with the variable passed through the harness,
which is consistent with the same split and is the cheapest thing to check first.

### It is overdraw, and the dump was lying

Correcting the previous section, which guessed that the drawing went to a surface nobody presents.
It does not.

The glyph blit trace now prints the surface it is writing to and that surface's size. Terminal
glyphs land on a 1690x1388 surface. The window dump is 1738x1436. That is the same surface plus the
24 pixel shadow margin on each side, so the text is going into the window buffer the compositor
reads, exactly where it should.

What is true, and is the actual bug: at the moment a glyph is blended, the destination pixel is
TRANSPARENT. Every premultiplied sample has alpha equal to red. iTerm2 fills its terminal background
opaque black BEFORE it draws text, so that fill has not happened yet. In the presented buffer the
same area is opaque black. Something paints the background AFTER the text, which on macOS is the
wrong way round, so the next thing to look at is our view draw order: a parent or sibling painting
after the text view rather than before it.

THREE BUGS IN THE INSTRUMENT ITSELF, all fixed, and each one had already sent the investigation the
wrong way:

  1. It sheared. Rows were read back at draw_w * 4 while they are really (draw_w + margin * 2) * 4
     apart, so each row started earlier than the last and the whole image slanted. On a window with
     a shadow that is every dump. It looked like a rendering bug in the application.
  2. It wrote nothing when the directory did not exist. The path is named from OUTSIDE the
     container and opened from INSIDE it, where it routinely does not exist. It now creates it.
  3. It reported no error when the write failed, so the absence of a file read as the window never
     being presented. It now says which path failed and why.

### One line: the clip view background nobody turned off

-[NSScrollView setDrawsBackground:] stored the flag and never passed it on. macOS documents that it
must: turning a scroll view background off turns its content view background off too. NSClipView
keeps its own flag and it defaults to YES, so iTerm2, which explicitly asks for no background,
got one anyway. -[NSClipView drawRect:] filled the whole document area with opaque black AFTER the
text view had drawn into it, and the last write wins.

iTerm2 now shows a working terminal: the dyld initializer lines, Unimplemented syscall (351), Login
incorrect, and a login prompt with a block cursor, white on black. The line reading echo hello from
cider is what the harness typed, so keystrokes reach the pty and come back as glyphs.

WHAT THIS SAYS ABOUT INSTRUMENTS. Five in a row confirmed a fact that was true and useless: the
glyphs were rasterised, positioned correctly, blended with the right paint, into the right surface,
and readable back out of it afterwards. All true. None of them asked what happened NEXT. The one
that found it in a single run was CIDER_TRACE_PAINT=x,y,w,h, which prints every write that lands in
a named rectangle together with the frames that asked for it: the last write into the first text row
was NSClipView filling black. For anything invisible, reach for that first.

A SECOND LESSON, cheaper and more embarrassing. A harness that forwards every switch writes VAR= for
the ones that are unset, and getenv answers an empty string for that, which is not NULL. So
CIDER_GLYPH_RED was on in a run nobody asked to be red, and the first screenshot of working text came
out entirely red and read as a colour bug. Both glyph gates now treat empty as off.

### A terminal with a shell in it

Three things stood between iTerm2 and a shell, and none of them was the terminal.

USER and LOGNAME were the HOST account. The launcher computed HOME from the container account and
copied USER straight through from the host, so the environment said USER=overby.me and
HOME=/Users/root at the same time. The only account this container has is root. iTerm2 opens its
session with login -fp $USER, so getpwnam answered NULL and login printed Login incorrect.

PAM denied it. /etc/pam.d/login was never installed at all, so openpam fell back to
/etc/pam.d/other, which is pam_deny for every facility. Apple's own login policy would not have
helped: it is built on pam_opendirectory and there is no directory service in this container. The
Cider policies now live in src/darwin/etc/pam.d beside master.passwd and group, with the reasoning
written into the files.

Two traps in that one file. login asks for the service name login.term and never login, which
tracing the opens says in one run and guessing does not. And naming a module that cannot be loaded
breaks the whole policy no matter how it is marked: an optional pam_launchd.so produced
"no pam_launchd.so found" followed by pam_start failing with a system error, and login exited 1
having exec'd nothing.

THE REASON IT WAS SILENT IS WORTH MORE THAN THE FIX. login reports these failures to syslog, not
stderr, and there is no syslog socket in the container, so nothing appears anywhere. Every syslog
call becomes a sendto on a dead descriptor and the message text is still in the buffer strace
prints: strace -f -s 400 -e trace=sendto named all three messages, in order, in one run. Reach for
that whenever a guest program exits with no output.

Sheets were a separate abort. Cocotron declares sheetOrderFrontFromFrame:aboveWindow:, with two
arguments; the Wayland window class registered the one argument sheetOrderFrontFromFrame:, which is
a different selector, so the call reached the abstract implementation and raised. Wayland has no
window glued to another, so a sheet is shown as an ordinary toplevel. iTerm2 now puts up its
warning alert properly instead of dying, and LibreOffice, whose save and print dialogs are sheets,
was one save away from the same crash.

Looked at, not counted: the terminal shows a bash prompt reading Darling [~]# with a typed command
on it.

Still untested for iTerm2: mouse and menus, and resize. auditon, syscall 351, is still
unimplemented and prints one line into the scrollback per session.

### The three criteria, re-verified after the AppKit changes

2026-08-16. The clip view, scroll view and sheet changes of the last few days all touch drawing and
window behaviour that LibreOffice leans on, and the criteria had only been checked for RENDERING
since. All three were re-run and every claim below is something that was LOOKED AT.

RENDERS CORRECTLY. The tall Writer render is unchanged through every change in this series: title
bar, menu bar, both toolbar rows, ruler, page with its text, sidebar, status bar.

INTERACTIVE, and this is the one with new evidence:

  - Clicking Format in the menu bar OPENS THE MENU. The dropdown draws its separators, its submenu
    arrows, its keyboard shortcuts and its disabled items in grey.
  - Dragging across text SELECTS IT. The selection is drawn and the status bar reads
    Selected: 7 words, 38 characters.
  - Clicking in the body and typing INSERTS CHARACTERS. BBB appears at the caret and the count goes
    from 47 to 50 characters, with undo becoming available.

  ONE APPARENT BUG WAS NOT ONE. Typing straight after Escape goes to the MENU BAR rather than the
  document, and the letters navigate menus. That looks wrong and is not: CIDER_TRACE_MENU shows a
  SINGLE tracking session for the whole sequence, because Escape with a submenu open pops back to
  the menu bar rather than exiting, which is what macOS does. A second Escape leaves. The instrument
  is what stopped a correct behaviour from being changed.

RESIZABLE. The output resolution was changed under a running Writer, twice:

  1256x684 to 1600x1000: the window fills the larger output, the toolbars span it, the ruler
  extends, and the page recentres.
  1600x1000 to 1000x620: the window shrinks and the toolbars grow OVERFLOW CHEVRONS at both rows,
  which is LibreOffice genuinely relaying out rather than being scaled or clipped.

TWO CLAIMS IN THE LOOP PROMPT ARE STALE and this contradicts them with evidence: wl_seat is bound
and input works, and resize is delivered and acted on. STATUS has said the three criteria are a
floor rather than the goal for some time; this is the check behind that.

### iTerm2 menus do not open, and what has been ruled out

The click reaches the application. That is now measured rather than assumed, because pointer motion
and button delivery were NOT traced at all and their silence had already been read twice as evidence
of nothing arriving. With the trace added:

    cider-wayland-input pointer=motion x=88 y=36 window=4 buttons=0
    cider-wayland-input button=0x110 pressed=true  x=88 y=36 type=1 clicks=1 window=4
    cider-wayland-input button=0x110 pressed=false x=88 y=36 type=2 clicks=1 window=4

Exactly on the Shell menu, both edges, correct window. And CIDER_TRACE_MENU, which was NOT enabled
in the iTerm2 harness the first two times it was consulted, reports ZERO tracking sessions with it
properly on.

Ruled out:

  - The harness and the pointer path. The identical sequence opens the Format menu in LibreOffice,
    verified in the same session.
  - A vertical coordinate flip. Clicking the mirrored position, y = height - 36, behaves the same:
    delivered, no track.
  - The lazily bound LaunchServices symbol that used to abort the process on this exact click. That
    is fixed separately; the application now survives and its shell prompt is still there.

So the events arrive at window 4 with the right coordinates and the menu bar never tracks. The
question to answer next is which window the iTerm2 menu bar actually lives in: an earlier glyph
trace showed menu bar text rendering onto a 585x405 surface while the terminal was 1690x1388, and
if the strip on screen is not the surface receiving these clicks, that is the whole bug.

### iTerm2 resize: the window relayouts and the grid does not agree with itself

Changing the output under a running iTerm2 works in the sense that matters least and fails in the
one that matters. The window fills each new size and keeps drawing its text, and the title bar shows
iTerm2 recomputing its grid from the initial 80x25. But the numbers disagree with each other:

    1600 wide  ->  179 columns  ->  8.9 pixels per column
    1000 wide  ->  225 columns  ->  4.4 pixels per column

A smaller window reporting a LARGER grid is not a stale title, it is a cell width that changed
between the two resizes, and the glyphs on screen do not change size to match. So resize is
delivered and acted on, and the metrics it is acted on with are wrong.

### iTerm2 menus open, and it was the clipboard

Answering the previous section, which had ruled out the harness, a coordinate flip and the
LaunchServices abort, and left the question of which window the menu bar lives in. Wrong question:
the menu bar is in the terminal window and the click was arriving at the right view all along. A
mouseDown entry trace on NSMenuView, added because the exit trace alone cannot tell a track that
found nothing from a click that never arrived, showed the click landing on NSMainMenuView at 88,14
in a 1280x28 view with ten items. Tracking started. No menu appeared.

The next lines of the log had it:

    -[NSMenuView trackForEvent:]
    -[NSMenu update]                      validate the items before showing them
    -[PTYTextView validateMenuItem:]       should Paste be enabled
    -[WaylandPasteboard pasteboardItems]   UNRECOGNIZED, raises

The raise unwinds out of the tracking loop, so every menu in the application was dead, by mouse and
keyboard alike, because the clipboard could not answer a question about itself.

WaylandPasteboard now implements pasteboardItems. A clipboard holds one item with several
representations of the same thing, so it answers one item carrying the types the board already
reports and asking the board for the bytes, and an empty array rather than nil when empty, since
callers iterate it. Upstream NSPasteboardItem is a stub that logs unknown selectors instead of
raising, so a subclass overriding the three that carry data is enough.

Looked at: the Shell menu opens with New Window and its Command N, the four split commands with
their shortcuts, Broadcast Input and tmux with submenu arrows, and Save Selected Text, Close and
Undo Close correctly greyed.

### The iTerm2 grid after a resize is told the wrong width, and the number says by how much

Unchanged by the menu fix, so it is its own bug. The window relayouts and keeps drawing, and iTerm2
recomputes its grid, but the two sizes disagree:

    1600 wide  ->  179 columns
    1000 wide  ->  225 columns

The cell width implied by the first is 1600 / 179, about 8.9 pixels, which is right for this font.
Applying that same cell to the second gives 225 * 8.9, which is about 2000, or EXACTLY TWICE the
1000 pixel output. So the font metrics are fine and the application is being told its content is
twice as wide as it is, on the second resize only. That is the shape of a scale factor applied where
it should not be, and it is the next thing to look at in the backend resize path.

### The iTerm2 grid was never wrong, and the terminal has no tty

Two earlier explanations for the terminal grid are both WRONG and this records the correction, since
each was written down as if it were progress.

It is not a doubled width: the geometry trace is exact at every step, surface 1000x620 giving frame
1000x620 and content 1000x570. It is not the advances either: fixing two real defects in
CTFontGetAdvancesForGlyphs changed the reported grid by nothing.

THE NUMBERS FIT THE PREVIOUS SIZE. 179 by 47 is what a 1280x720 window holds, since its content is
1280x670 and the cell is about 7.15 by 14.3. 225 by 67 is what 1600x1000 holds. Nudging the output
once more, to 1004x624, made the title read 139 by 40, which is what the 1000x620 window held. So
the grid is computed correctly and reported one resize late, every time.

AND THE REASON IT CANNOT TRACK THE WINDOW AT ALL is one command away. With a shell running, typing
stty size answers

    not a tty

so the session standard input is not a terminal by isatty. A shell that is not on a tty gets no
SIGWINCH and has no window size to report, which is exactly the shape of a grid that only ever
catches up when something else pokes it. Whatever iTerm2 is spawning its session onto, our pty
emulation does not present it as a tty. That is the next rung, and it is worth more than the title:
a terminal whose child has no controlling terminal has no job control either.

A HARNESS TRAP WORTH RECORDING, since it cost three runs and looked exactly like a broken Return
key. wtype creates a virtual keyboard, sends its keys and destroys the device at exit. A Return sent
by its OWN invocation produced NO key event in the application at all, while the same Return sent
inside the invocation that typed the text arrived correctly as keysym 0xff0d, carbon 36. The input
trace is what separated the two. Same shape as the virtual pointer: one device, held open, for the
whole gesture.

### Correcting the tty claim: the session has a pty, and a resize breaks the input path

The previous section concluded from one stty answer that the iTerm2 session was not on a tty. That
is WRONG and this replaces it.

Typing a command and pressing Return in a run with NO resize gives:

    Darling [~]# ls -l /dev/fd/0
    lrwx------ 1 root root 64 Aug 16 21:25 /dev/fd/0 -> /dev/pts/27

So standard input is a real pty, the command runs, Return works, and ls even colours its output. The
earlier not a tty came from a run that had resized three times first, and so did every later failure.

WHAT IS ACTUALLY BROKEN, stated as narrowly as the evidence allows: after the output has been
resized, keystrokes still reach the application, and the session no longer shows them. The key trace
records all thirty two keys of the command including Return, delivered to window 4, and the terminal
displays a bare prompt and nothing else. Without a resize the same harness types the same command
and it appears and runs.

Not yet isolated to a single resize rather than three, and not yet explained. What it is NOT: it is
not the menu, since the same failure happens with the menu click aimed at the terminal body instead
of the menu bar, and it is not key delivery, since the trace shows the keys arriving.

THE TERMINAL WAS FULL OF DYLD NOISE AND THAT WAS OURS. The harness forwards
DYLD_PRINT_INITIALIZERS=${DYLD_PRINT_INITIALIZERS:-}, which SETS the variable to the empty string,
and dyld tests only whether it is present. Every session began with dozens of initializer lines that
raced the typing and scrambled it. This is the same empty-is-not-unset trap that had already been
fixed inside our own glyph gates, met a second time from the other side.

### A nil CTLine is not an empty line, it is a dead process

Chasing imgcat produced a rule worth keeping. In this CoreFoundation, CFRelease of NULL is a HALT.
So every CoreText creator that answers nil kills any caller written the ordinary way:

    obj = CTSomethingCreateWith...(string);
    ... measure ...
    CFRelease(obj);

CTLineCreateWithAttributedString and CTFramesetterCreateWithAttributedString were both stubs
answering nil, and iTerm2 died in
-[NSString(iTerm) it_boundingRectWithSize:attributes:truncated:] measuring its badge. The line stub
alone was reached 759 times in a single launch, so this was not an obscure path.

Both are implemented now. CTLine resolves the font from the attributes, maps characters to glyphs,
measures advances and answers bounds, counts, offsets and hit testing, and draws through the same
Onyx2D entry point as the rest of the text path. CTFramesetter answers a suggested size by laying
the string out through CTLine with greedy word wrapping at the constraint width. Truncation and
justification are not implemented and return the line RETAINED rather than nil, which is the same
rule stated positively: hand back something the caller can release.

FIXING THE FIRST ONE DID NOT STOP THE CRASH, which is the part worth remembering. The same HALT
came from the same call site, and twenty instructions of iTerm2 disassembly showed the pattern
create, measure, release with the released value coming from a DIFFERENT stub two calls earlier.
That named the framesetter without guessing. When a create-and-release crash survives a fix, read
the caller rather than the next plausible function.

### base64, and the prompt that still said Darling

The container had no base64 at all, which is what imgcat noticed first. Apple builds no such target
in basic_cmds, where uuencode keeps a private base64.c for its -m flag, so there was nothing
upstream to switch on and src/darwin/base64 is a first party implementation of the macOS interface.
The interface is the part that matters: imgcat runs base64 --version and takes a different path if
the answer mentions GNU, so answering an unknown option with usage on stderr and a failure, as macOS
does, is deliberate.

The shell prompt said Darling because the bash pin sets it in bashrc. That pin is materialised and
read only, so the change is vendor/patches/bash rather than an edit.

### Still not working after all that

imgcat runs with no error and draws no image. The badge is accepted, measured without crashing, and
not drawn. So iTerm2 inline drawing needs something beyond text measurement, and that is the next
rung rather than a claim of success.

### imgcat: what was in the way, and what is actually broken

Three things stood between imgcat and a picture, and only the third is ours to fix.

FIRST, there was no base64 (fixed, see above). SECOND, a permission dialog. iTerm2 asks
"Allow Terminal-Initiated Display?", naming the file and its size, with No and a default Yes, and it
WAITS. Six frames captured six seconds apart are byte identical while it is up. That dialog is why
nothing appeared, and it is not a bug: it is the feature working.

The dialog itself is drawn correctly, which is worth stating as a positive result for the alert
path: warning triangle, title, body naming imgtest.png and its 699 bytes, No and a highlighted Yes.
Clicking Yes dismisses it, so alert buttons respond to a real pointer click.

THIRD, AND THIS IS THE REAL GAP: with the dialog answered, NO IMAGE IS DRAWN. The cursor moves to
the next line and the terminal is unchanged. So iTerm2 inline image display does not work here, and
that is a rendering gap rather than a missing dependency or a prompt.

Honest limit on that last claim: both buttons dismiss the dialog, and while the click was aimed at
the Yes position measured off a full frame, this run cannot by itself prove it did not hit No.

TWO WAYS THIS INVESTIGATION WENT WRONG, both worth not repeating.

Reading a CROP instead of the frame. The conclusion "no dialog and no image" came from a crop whose
bottom edge stopped about thirty pixels above the dialog. LOOK AT THE WHOLE WINDOW.

Presetting the preference does not work. iTerm2 REWRITES com.googlecode.iterm2.plist when it exits,
so a hand added AlwaysAllowTerminalInitiatedDisplay, or the NoSync spelling, is gone by the next
run and the dialog comes back.

### Stale containers make a run render nothing

Several runs produced completely black frames with no crash and no error. The cause was accumulated
state: dozens of leftover launchd, securityd and iTermServer processes from earlier runs of the same
prefix, plus a stale nested compositor socket. A new iTerm2 attaches to the OLD session, whose
windows belong to a compositor that is gone, so the new screenshot is black.

Before believing a black frame, list what is still running for that prefix and clear it. And note
the trap when doing so: pgrep matches YOUR OWN command line if it contains the prefix name, so a
kill loop over its output kills the shell running it.

### Inline images: narrowed to inside iTerm2, with six things ruled out

Answering the dialog by CLICK could not prove which button was hit, since both dismiss it. Answering
it with RETURN can, because that activates the DEFAULT button, which is Yes. Done that way the
result is the same: no image.

So the failure is real, and these are now measured rather than assumed:

  1. base64 is correct. The tool written for this produces output byte identical to GNU base64 for
     the actual file, 660 bytes each.
  2. The escape sequence is dispatched. The badge, which uses the same OSC 1337 handler, reached
     iTerm2 drawing code and crashed there, which is what led to the CTLine and CTFramesetter work.
  3. The permission dialog is not the blocker any more. It draws correctly and is answered.
  4. It is not the payload size. An 8x8 image, 184 base64 bytes, behaves exactly like a 240x120 one.
  5. It is not the bit depth. Eight bit and sixteen bit PNG behave the same.
  6. OUR DECODERS ARE NEVER ASKED. CIDER_TRACE_IMAGESOURCE, added here, prints every time a decoder
     matches or nothing does. A full iTerm2 run matches 46 times, all TIFF and ICNS for application
     resources, and NEVER PNG.

Six is the important one: iTerm2 drops the image before it would hand anything to CoreGraphics, so
whatever is missing is a check inside iTerm2 rather than a decoder of ours. Finding it means reading
what iTerm2 requires of a session before it will display an image, which is where this stops for now
rather than being called done.

### Inline images need an XPC service, and it never starts

The previous section narrowed this to inside iTerm2. It is now named.

iTerm2 does not decode inline images in process. Its binary exports
decodeImageFromData:withReply:, and the withReply suffix is the NSXPCConnection convention, so the
work goes to a service. The bundle has one: Contents/XPCServices/iTerm2SandboxedWorker.xpc, whose
executable is present and 1.7 MB. Sampling the process list every five seconds for the length of a
run, while imgcat runs, never sees it. It is never started.

That explains every observation at once. Our decoders are never asked because the data never reaches
them; nothing is logged because iTerm2 treats a decode that does not answer as a failed decode; and
no rows are reserved because there is no image to size.

WHERE THE GAP IS. libxpc already knows about bundle services: xpc_connection_create resolves through
initAsClientForService, and bundle.m knows Contents/XPCServices is where they live. Our launchd does
not: the string XPCServices appears ZERO times in it. On macOS launchd is what discovers an
application XPC services and spawns them on demand, so a connection to a bundled service name has
nothing to resolve against here.

So the next rung for inline images is launching bundle XPC services, not anything in CoreGraphics.
That is a real piece of work rather than a missing selector, and it is worth saying that it is also
what any application using a sandboxed helper will need.

### The XPC lookup fails silently, and os_log will not tell you

Following the previous entry, the exact failure point is
-[XPC_CLASS(connection) activate] in vendor/src/libxpc/src/connection.m: for a client of a named
service it calls bootstrap_look_up, and on failure calls xpc_log_error and gives up. Nothing
registered com.iterm2.sandboxed-worker, so the lookup fails every time.

The failure is INVISIBLE, and that is the part worth recording. xpc_log_error goes to os_log, os_log
goes to syslog, and there is no syslog socket in this container. The sendto trick that recovers
syslog text from syslog(3) callers does NOT work here: tracing sendto through a whole run captures
721 calls and they are binary mach traffic. So a service that cannot be found produces no output on
any channel.

vendor/patches/libxpc adds a stderr line under CIDER_TRACE_XPC naming the service that could not be
resolved. It is not exercised yet, because libxpc is a materialised pin and buck2 builds the
unpatched copy until the source tree is rebuilt through nix.

WHAT WOULD ACTUALLY FIX IMGCAT, stated so the next rung is not re-derived: launchd has to discover
an application bundled XPC services, Contents/XPCServices with a CFBundleIdentifier of
com.iterm2.sandboxed-worker in this case, and spawn one on demand when a client looks its name up.
libxpc already knows where they live, bundle.m resolves the XPCServices subdirectory; launchd is the
half that is missing.

### The sandboxed worker runs now, and imgcat still shows nothing

With CIDER_XPC_LAUNCH_SERVICES on and the eightbyte fix in, an iTerm2 run reports

    CIDER_XPC spawned bundled service com.iterm2.sandboxed-worker
      at /Applications/iTerm.app/Contents/XPCServices/iTerm2SandboxedWorker.xpc/Contents/MacOS/iTerm2SandboxedWorker

with no crash. So the service iTerm2 decodes inline images in is running, the connection to it no
longer kills the process, and the picture STILL does not appear: imgcat echoes its command, the
cursor moves to the next line, and nothing is drawn. There was not even a permission dialog in that
run, which there always was before.

Three real blockers have been removed on the way here, and none of them was the last one: no base64
in the container, two CoreText creators returning nil into a CFRelease that halts, and an argument
offset that was four bytes inside its own slot. The honest position is that inline images remain
broken and the remaining cause is not yet identified.

### A garbage collection can empty your screenshots

Several runs produced no frames, and one earlier round produced pure black images, with no crash and
no error from the application. The cause was not the application at all: the nix store paths the
harness hard codes for grim and wtype had been garbage collected, so the screenshot and the typing
simply did not happen.

    run-iterm-visible.sh: line 85: /nix/store/...-grim-1.5.0/bin/grim: No such file or directory

A rebuild restores the SAME path, so the fix is one nix build away, but the failure reads as the
application drawing nothing. Before believing an empty or black capture, check that the tool that
was supposed to take it still exists.

### The decode request goes out, the worker is running, and nothing comes back

Correcting something written an hour earlier in the same sitting. The sandboxed worker does NOT exit
immediately. It is alive: sampling during a run finds it 25 seconds in. The earlier claim came from
sampling on the process NAME, and every guest process here is called mldr, so that test could never
have matched whatever was running. Third measurement of this shape to be wrong in this way.

What is actually true, all from one run with CIDER_XPC_LAUNCH_SERVICES on:

  the service is spawned, com.iterm2.sandboxed-worker, and the lookup that follows SUCCEEDS,
    since no lookup failure is reported for it;
  the worker process is alive and stays alive, and run by hand it blocks in its run loop as a
    service should rather than exiting;
  iTerm2 sends the request, decodeImageFromData:withReply:, with a valid reply block and a reply
    type of iTermImage;
  no decoder is ever asked for the data, 43 matches in the run and all of them TIFF or ICNS for
    application resources;
  nothing fails, there is no decode error, no connection invalidation and no interruption.

So the message leaves and nothing answers. The remaining question is whether the far side receives
it at all, which is a question about the receiving half of NSXPCConnection rather than about images.

### The worker refused every connection because it could not enter a sandbox

The receiving half was the right place to look, and the answer was one instruction into iTerm2 own
code rather than anywhere in ours.

Tracing the whole chain at the five points it could stop, and naming each so the FIRST missing line
is the answer, gave this for the two bundled services in one run:

    pidinfo           XPCMAIN -> XPCSERVER -> XPCPEER responds=1 -> accepted=1 -> RECV -> INVOKE
    sandboxed-worker  XPCMAIN -> XPCSERVER -> XPCPEER responds=1 -> accepted=0

So the worker started, was offered the connection, and its own delegate said no. The first
instruction of that delegate says why:

    cmp byte [_sandboxSuccessful], 0
    je   ...                          ; return NO

and _sandboxSuccessful is set by main from a four call sequence, of which the FIRST already failed:

    params = sandbox_create_params();      <- our libsandbox answered NULL
    if (!params) goto fail;
    profile = sandbox_compile_string(text, params, &error);
    if (sandbox_apply_container(profile, 0) != 0) goto fail;

NULL is not a neutral answer. An application that cannot BUILD a sandbox concludes it is running
unprotected and disables the feature itself. sandbox_apply_container already returned zero, which
its caller reads as success, so create_params was the only blocker. It now answers a static token.

THIS IS A DELIBERATE LIE AND IT IS WRITTEN INTO THE SOURCE. A process that asks to be confined is
told it was confined and is not. On this system that removes nothing it could have relied on, since
the guest already runs with the privileges of the user running Cider and no sandbox was ever going
to be applied; the alternative is not a safer iTerm2 but one that cannot show an image.

With that changed the chain completes, accepted=1 through to
decoded sel=decodeImageFromData:withReply:, and the PNG decoder is asked for the first time: 2
matches for O2ImageSource_PNG where every previous run had 43 TIFF and 2 ICNS and never a PNG.

### A focus change messaged a window that had been freed

The run after that fix crashed where none had before:

    0  libobjc.A.dylib  objc_msgSend + 41
    1  Wayland          cider_wayland_set_keyboard_focus + 67
    2  Wayland          wayland_appkit_lib::input::on_keyboard_leave

cider_wayland_key_window was a raw unretained id. Nothing tells it when its window is deallocated,
so the next focus change sent respondsToSelector: to freed memory. It is reached most easily on the
LEAVE path, where the incoming delegate is nil and the only object messaged is the stale one. If a
pointer is kept across events then its object has to be owned, so it is retained while held and
released when replaced. Six frames captured after that, no crash.

### The image draws, and the pixels are still wrong

imgcat now produces a VISIBLE rectangle in the terminal, correctly sized and correctly placed
between the command and the next prompt. That is new. It is not finished:

    source imgtest8.png   240x120 truecolour, a vertical gradient from (244,0,11) to (9,0,246)
    what is drawn         a uniform (128,128,128) rectangle, every sampled pixel identical

A flat mid grey is a placeholder rather than a damaged gradient, and iTerm2 knows the size from the
escape sequence, which is why the box is the right shape while empty.

AND THE REPLY IS NOT THE PROBLEM, correcting a reading made an hour earlier. CIDER_XPCRECV never
fired in the application process, which looked like a reply that never arrived; it cannot fire,
because a message sent with send_message_with_reply is answered into a REPLY HANDLER and not into
the connection event handler. Traced properly, both halves are there:

    CIDER_XPCREPLYSEND pid=61 sel=decodeImageFromData:withReply:
    CIDER_XPCREPLY     pid=20 seq=0 type=dictionary

So the request is decoded by the worker, a reply is sent, and the application receives it. What is
still unknown is what survives inside that reply: whether the iTermImage decodes back into an object
with pixels in it.

### The round trip is whole, and the application still does not draw the picture

Following the image rather than the connection, in the order the bytes travel. Everything below is
from traced runs, not from reading code.

    worker   PNG decoder asked, imageRepsWithData frames=1 reps=1
    worker   NSImage initWithData bytes=493 repClass=NSBitmapImageRep reps=1
    worker   O2BitmapContextCreate 240x120 bpc=8 bpr=960 data=0x771bd1628000 info=0x1 -> ok
    worker   CIDER_PAINT image 240x120 <- O2ContextDrawImage <- -[iTermImage dataForImage:]
                                       <- -[iTermImage encodeWithCoder:] <- NSXPCEncoder
    app      CIDER_XPCREPLYARGS sel=decodeImageFromData:withReply: args=2: [1]=iTermImage
    app      initWithBitmapDataPlanes 240x120 bps=8 spp=4 alpha=1 planar=0 bpr=960 bpp=32 planes=0x0

So the worker decodes the file, builds a bitmap context over the bytes of the NSMutableData that
iTermImage hands it, DRAWS the image into that context while encoding the reply, and the application
receives a reply whose argument decodes into a real iTermImage rather than nil. On the far side it
builds a 240x120 32 bit rep with a NULL planes pointer, which is the ordinary way to make an empty
rep and then copy pixels into bitmapData, and bitmapData here is implemented.

WHAT IS STILL MISSING is the last step: the application never draws that image. Six image draws
happen in the whole run and the 240x120 one is the WORKER encoding its reply. The others are a 12x12
icon three times and the 32x32 alert icon twice, all in the application, which is what makes this
readable at all: the instrument plainly works in that process and would have caught a 240x120 draw.

AND A CORRECTION ABOUT HOW THAT WAS READ. An earlier pass concluded the application never draws any
image. That was an artefact of the trace RECTANGLE, which was 60x30 and too small; widening it to
300x200 produced the five application draws above. A rect filtered trace can only ever prove what it
saw, so the rect belongs in the claim.

### A run that produces no output at all is a startup fault, not a result

Two of three consecutive runs ended with the application printing NOTHING, the harness log seven
lines long, PROBE_EXIT=137 from the timeout kill, and captures that were uniformly black. The
markers were present in the installed binaries and the following run of the SAME build worked, so
this is the startup fault already recorded here rather than a broken change. Re-run before drawing
anything from a silent log; a build that never reached the run has already been written into a
commit message once as a fact.

### The XPC chain instrument is now a patch rather than a local edit

The five point trace lives in two MATERIALISED pins, foundation and libxpc, where an edit is
invisible to nix and is lost the moment the tree is re-materialised. It is now captured as
vendor/patches/foundation/0011 and vendor/patches/libxpc/0002.

The pristine pin could not be refetched to diff against, since the manifest hash does not match a
plain fetchFromGitHub, so the patches were built by reconstructing the pre-edit file from the added
blocks. That would be worth nothing on trust, so the generator applies its own output to the
reconstruction and fails unless the result is byte identical to the file on disk. Both passed, and
buck-pin-patches-check.nu agrees each set reaches the pin it was written for.

### imgcat works: isValid answered NO to everything

The last link was four lines of cocotron, and it was not in any of the places this chase spent its
time. -[NSImage isValid] was

    - (BOOL) isValid {
        NSUnimplementedMethod();
        return 0;
    }

and 0 is NO. An application asks isValid before it uses an image and skips the drawing entirely when
the answer is no, so the picture was decoded, drawn into a bitmap by the worker, encoded, carried
back over NSXPCConnection, rebuilt into a 240x120 representation in the application, and then simply
never drawn. Eleven of those log lines sat in the run the whole time saying so.

That is why every earlier measurement looked healthy. Each one was: the connection is accepted, the
decoder is asked, the reply carries a real iTermImage, the rep is built. All true, and none of them
was the question, which was whether anything ever asked to DRAW it.

Valid now means there is something to draw, measured as a representation with a real size. An image
that has not loaded yet still answers NO, which is what it answered before, so nothing that worked
can regress.

MEASURED AFTER, not asserted:

    isValid complaints            11 -> 0
    NSImage drawInRect 240x120     0 -> 1        the inline image itself
    NSImage drawInRect 245x14      0 -> 27       iTerm2 painting it one terminal row at a time

and the pixels on screen, sampled down the middle of the drawn image against the source file:

    y  72  (244,0,11)      source top    (244,0,11)
    y 183  (  6,0,249)     source bottom (  9,0,246)

green zero throughout and monotonic in between, the three point difference at the bottom being the
resample from 120 rows to 126. This is the gradient in the file, not a plausible looking rectangle.

STILL IMPERFECT: a light grey border, 238,238,238, about five pixels wide down the right edge and
four along the bottom, where the reserved cell box is larger than the drawn image. Cosmetic, and
noted rather than fixed.

### Keys after a resize work now, and what is actually broken is the scrollback

The recorded failure was that after a resize keystrokes still arrive and the session no longer shows
them. It NO LONGER REPRODUCES. A harness that types on both sides of the resize, rather than only
after it, gives:

    before one resize     echo before_resize -> before_resize -> prompt
    after one resize      echo after_resize  -> after_resize  -> prompt
    after three resizes   echo after_resize  -> after_resize  -> prompt

Three, because three is what the original failure was seen after, and a single resize would have
been a weaker test than the one that found it. The responder trace agrees across the whole run:
every one of the thirty six key downs went to windowNumber=4, keyWindow=4(iTermWindow),
responder=PTYTextView, before and after.

The likely cause of the old failure is the dangling key window pointer fixed earlier tonight, since
that static is on the focus path and a resize is exactly when windows are deactivated and
reactivated. That is a plausible attribution and not a demonstration: the old build was not re-run
to confirm it, so it is written down as the likeliest explanation rather than a proven one.

WHAT IS BROKEN INSTEAD, and it is a better specified defect than the one it replaces: a resize
BLANKS THE SCROLLBACK. Immediately after resizing, and before anything is typed, the terminal shows
only the prompt, sitting at the row it had reached, with every line above it empty. The two lines
that were there, a command and its output, are gone. macOS reflows that content instead of
discarding it. The cursor row survives the resize; the text above it does not.

### Correcting that: the scrollback is not blanked, the resize inserts blank rows and a new prompt

The section above says a resize BLANKS THE SCROLLBACK. That is wrong, and this replaces it. It was
written from the visible screen alone, which after a resize does show a lone prompt with empty rows
above it. Scrolling back shows the content is all still there:

    Cider [~]# echo before_resize
    before_resize
    Cider [~]#
        (blank rows)
    Cider [~]#
        (blank rows)
    Cider [~]#

So nothing was lost and nothing needs recovering. What each resize actually does is leave a BLOCK OF
BLANK ROWS and a fresh prompt, three resizes giving three prompts, and the newest prompt is far
enough down that the earlier content is off the top of the view. From the visible screen that is
indistinguishable from having been cleared, which is exactly how it was misread.

The lesson is the same one this document keeps recording in different clothes: a screenshot shows
what is VISIBLE, and on a terminal the visible region is a window onto a model that outlives it.
Scrolling back cost one extra key press in the harness and turned a wrong claim about lost data into
a much smaller and more accurate one about layout.

What remains, stated narrowly: a resize should reflow the existing rows, and instead it advances the
cursor past a run of empty rows and reprints the prompt there.

### The grey edge on an inline image is not the cached rep, and that was tested rather than argued

The picture draws correctly and carries a light grey edge, 238,238,238, about five pixels down the
right side and four along the bottom, where the cell aligned box iTerm2 reserves is slightly larger
than the 240x120 picture scaled to 245x126.

238 is 0.93 of 255, and 0.93 grey is the cocotron WINDOW BACKGROUND, which made an obvious suspect:
NSCachedImageRep is backed by a real NSWindow, so a cache begins filled with that colour and
anything the drawn image does not cover would show it. The fix would then be that a cache asked for
alpha starts clear.

IT WAS TRIED AND IT CHANGED NOTHING. Setting the backing window opaque NO with a clear background
colour, verified present in the tree buck2 reads and in a rebuilt AppKit, left the edge at exactly
238,238,238. The change was reverted rather than kept, because a change that does not do what its
comment says is worse than no change.

What that rules out, and it is worth having: the edge does not come from the cache background by
this route, and both cache creation sites already pass alpha YES so the guard was not the reason.
The 240x120 draw also reports best=NSBitmapImageRep, meaning it draws straight from the bitmap and
builds no cached rep at all, so the remaining candidate is whatever produces the SCALED 245x126
image that iTerm2 actually paints in row slices.

### Auditing for the shape that cost a night: BOOL predicates stubbed to NO

-[NSImage isValid] returning 0 disabled every image in the application, so the obvious next question
is how many more of those there are. Scanning cocotron for a BOOL method whose whole body is
NSUnimplementedMethod followed by return 0 or NO finds FORTY FOUR.

Most are harmless, either because nothing consults them or because NO is genuinely the macOS default
(acceptsFirstMouse, canDrawConcurrently, isRotatedFromBase). Two things separate the dangerous ones:
the correct default is YES, and something in the tree actually reads the answer. Checking callers
rather than guessing:

    wantsDefaultClipping          default YES, but NO CALLERS anywhere here, so changing it is a
                                  no-op and it was left alone
    NSWindow isMovable            default YES, but the callers found are NSRulerMarker and
                                  isMovableByWindowBackground, not this, so low impact
    NSViewController commitEditing  default YES, and it IS read, by
                                      -[NSController commitEditing]: if ([editor commitEditing] == NO) return NO;
                                    and by NSDocument before saving

So commitEditing was the one worth changing. It means "were you able to commit any pending edit",
its callers treat NO as a refusal and stop, and a view controller that tracks no editors has nothing
pending. The truthful answer is YES. Answering NO silently blocked saves, which matters for every
application in the queue, since iA Writer, Swift Publisher and MoneyMoney are all document or form
applications.

STATED HONESTLY: this one is REASONED, not measured. No application in the queue reaches a save yet,
so unlike isValid there is no before and after to show. What was verified is only that iTerm2 does
not regress: the inline image still draws, no crash, keys still reach PTYTextView.

The remaining forty odd are listed by this scan and are worth re-running whenever an application
does something invisible for no reason. The pattern to remember: a stub returning 0 from a QUESTION
is a policy answer, and the policy is always no.

### The alert checkbox was placed with an uninitialised variable

macOS shows a Remember my choice checkbox in the iTerm2 permission alert and ours showed none. The
application was not the reason. A trace of what it actually asks for says:

    CIDER_ALERT style=0 icon=yes iconSize=32x32 suppression=1 accessory=(nil) buttons=2
                msg=Allow Terminal-Initiated Display?

suppression=1, so iTerm2 does call setShowsSuppressionButton, and NSAlert does have code to place
it. That code was:

    NSRect frame;

    frame.origin.x = LEFT_MARGIN + iconSize.width + ICON_MAIN_GAP;
    frame.origin.y = panelSize.height - TOP_MARGIN - messageSize.height -
                     messageInformativeGap - informativeSize.height -
                     informativeSuppressionGap - frame.size.height;   <- read here
    frame.size = supressionSize;                                      <- assigned here

frame.size.height is READ ONE LINE BEFORE IT IS ASSIGNED, so the vertical position came from an
uninitialised stack value and the checkbox landed at a garbage offset, off the panel. Assigning the
size first fixes it. The accessory view block immediately below is written the other way round,
taking its frame from the view first, which is why only this one was wrong.

Two smaller things went with it. setButtonType:NSSwitchButton was COMMENTED OUT, so even placed
correctly the control would have been a push button rather than a checkbox; it is enabled. And the
suppression size was measured from the title text alone, which leaves no room for the box glyph, so
it now adds that width.

The checkbox appears in the right place. What still differs from the reference: the gap between box
and title is tighter than macOS, the panel has square corners where macOS is rounded, the buttons
are small rectangles where macOS uses tall pills, and we draw a yellow warning triangle where the
macOS alert has NO icon at all.

### Every alert wore a critical icon, including the ones that are not critical

The comment at the top of NSAlert has always said what the icon should be:

    NSWarningAlertStyle       - app icon
    NSInformationalAlertStyle - app icon
    NSCriticalAlertStyle      - large yellow /!\ triangle w/ small app icon

and init set the yellow triangle unconditionally, contradicting it. So every alert in every
application wore a critical-alert icon. iTerm2 raises its permission alert with style=0, which is
NSWarningAlertStyle, and the macOS reference for that exact alert has no triangle on it.

The default now follows the style, and setAlertStyle moves it if the application has not chosen an
icon of its own, compared by identity because imageNamed and applicationIconImage both answer a
shared instance. When there is no application icon it answers nil rather than falling back to the
triangle: no icon is what macOS shows here, and a wrong icon misleads more than none does. In this
container the trace goes from

    icon=yes iconSize=32x32   ->   icon=(nil) iconSize=0x0

and the alert now matches the reference in structure: no icon, bold title, informative text, the
Remember my choice checkbox, and No and Yes at the bottom right with Yes blue.

Verified not to regress what the alert is FOR: the same harness that answers the dialog still ends
with the picture drawn, no crash, keys still reaching PTYTextView.

WHAT STILL DIFFERS from the reference: square panel corners where macOS is rounded, no drop shadow,
small rectangular buttons where macOS uses tall pills, and a tighter gap between the checkbox and
its title.

### An alert was a third of the screen wide, because that is literally what it asked for

    mainSize.width = MAX(screenSize.width / 3., ...)

So the text column of every alert grew with the display: 419 points on the 1256 pixel output used
for testing, and far worse on a real monitor. macOS sizes an alert to a CONSTANT, which is why the
reference panel is about 257 points while ours measured 487.

It is a constant here now, 240 points for the text column, measured off the reference rather than
invented, with the screen kept as a ceiling so a small display cannot overflow. The alert button
minimum went from 40 points wide to 90, which is what an alert button looks like on macOS and what
the reference shows at about 110.

The result, looked at rather than summarised: the panel is 292 pixels instead of 487, the informative
text wraps into three lines exactly as the macOS one does, and No and Yes are proper alert buttons
instead of two small squares. Verified not to break what the dialog is for, since the harness that
answers it still ends with the picture drawn and no crash.

Left over, and all of it is chrome rather than layout: square panel corners where macOS is rounded,
no drop shadow, buttons that are rounded rectangles rather than pills, and a tight gap between the
checkbox and its title.

### A rounded panel needs an alpha channel, and the alert did not have one

Rounding NSThemeFrame was not enough on its own, and the reason is worth writing down because the
first attempt looked like it had simply not run.

Filling the frame with a rounded rectangle instead of NSRectFill changed nothing visible. A trace
proved the code WAS running on the right window:

    CIDER_THEMEFRAME draw class=NSPanel rounded=1 style=0x40 bounds=292x185

So the corners were being left unpainted and something else was filling them. That something is the
backend. It clears a surface to one of two values, and picks between them with

    st.level > 0 || st.style_mask & 0x1 != 0

An alert panel has style 0x40, which carries neither the titled bit nor a level, so it was cleared to
CLEAR_PIXEL, which is 0xffeeeeee, an OPAQUE light grey. The rounded fill therefore revealed grey
rather than nothing, and grey against a grey panel is invisible: the corner measured 238,238,238
before and after, which is also why the panel background at 0.93 white could not be told apart from
it by eye or by a threshold.

The backend already computes whether a window is an NSPanel, by asking the delegate, but only to
decide a role and only as a local. It is kept on the window state now and wants_alpha consults it.
Measured on the same corner, before and after:

    ##############        .......#######
    ##############        .....#########
    ##############        ....##########
    ##############   ->   ...###########
    ##############        ..############
    ##############        .#############
    ##############        ##############

a clean quarter circle. Verified not to regress the opaque case: the terminal window still renders,
the picture still draws, no crash, keys still reach PTYTextView.

### A panel had no shadow, and a black terminal cannot tell you whether it does now

macOS floats every alert on a soft shadow. shadow_margin gave ours none, because a toplevel only
qualified with the titled style bit and an alert carries 0x40, which has no titled bit and is not a
popup either. Panels are included now, the same way they were for the alpha channel.

THE SCREENSHOT CANNOT CONFIRM THIS AND SAYING SO IS THE POINT. A shadow is dark, the terminal behind
this alert is black, and dark composited over black is black: the pixels outside the panel measured
0 before the change and 0 after it, which is exactly what no shadow ALSO looks like. That is a
measurement that cannot fail and therefore proves nothing.

So the decision was traced instead of the pixels, which is a question a capture can answer:

    shadow number=4 margin=24 style=0x10f  panel=false popup=false   the terminal window
    shadow number=5 margin=14 style=0x5f   panel=true  popup=true    a menu, already had one
    shadow number=7 margin=24 style=0x40   panel=true  popup=false   the alert, was 0

The alert now takes the same 24 point margin a window does. What is verified is that the code
decides to draw one and reserves the surface for it; what is NOT verified is how it looks, and it
will not be until an alert appears over something lighter than a black terminal.

### The panel changes were checked against LibreOffice, not just iTerm2

Rounding panels, giving them an alpha channel and giving them a shadow are changes to AppKit and to
the backend, so they reach every application. LibreOffice was run afterwards on its dialogs harness:
no crash, the document renders, the menus open, and the Tip of the Day dialog draws correctly with
its title bar, its three lights and its buttons.

That run also answers, indirectly, the question the iTerm2 capture could not: the LibreOffice dialog
sits on a LIGHT document rather than a black terminal, and its shadow is plainly visible there. That
is the same shadow code, on a titled window rather than a panel, so it confirms the mechanism draws
something real even though it does not confirm the panel case specifically.

### An alert button is a pill, and every other push button is not

The last chrome difference against the reference. macOS draws the buttons in an alert with fully
rounded ends and ours were rounded rectangles.

The drawing method never knew which kind of button it had: NSButtonCell calls
drawPushButtonNormalInRect:defaulted: and the radius was the literal 4 inside it. Both push button
methods now take the radius, the old two argument forms remain and forward with 4, so anything that
overrides or calls them is unaffected.

HOW AN ALERT BUTTON IS RECOGNISED, and this is the part worth keeping: NSAlert sets ITSELF as the
target of every button it builds, so the target is the alert. That is exact. Guessing from the
window class would catch every button in a panel, and guessing from the size would catch anything
that happened to be that tall.

The result, looked at: No and Yes are now pills, and the alert as a whole now matches the reference
in icon, title, text wrapping, checkbox, button shape, panel corners and width.

WHAT WAS NOT VERIFIED, stated rather than glossed: no ORDINARY push button could be got on screen to
confirm it still draws as a rounded rectangle. The LibreOffice dialogs harness stopped showing its
Tip of the Day dialog, which is where its two push buttons were, and wiping the profile did not
bring it back. What is known is that the default radius is unchanged at 4, that the only difference
for a non-alert button is the inner highlight going from radius 4 to 3, and that LibreOffice runs
through its whole harness with no crash and its chrome intact.

## Task 116, Swift Publisher 5: a font conversion that answered nil killed every document preview

Picked up where it stopped, and the first thing a re-run said is that the state has changed: the
application no longer CRASHES. It presents its Template Gallery, opens
CCWellcomeWindowController.nib, reaches NSConnections in the keyed unarchiver, and then exits with
status 0 rather than faulting on a 0xFFCECECEFFCECECE receiver. The nib is still where it stops.

WHAT THE RUN SHOWED THAT WAS NEW, three times over, in a background operation building previews:

    CIDER_DICT_NIL object=(nil) key=__NSCFConstantString keytext=NSFontAttributeName
    cider: RAISE NSInvalidArgumentException: Cannot set nil objects nor nil keys
      -[NSRichTextReader processControlWithArgValue:]
      ... -[CCDocument initWithDocumentType:andOptions:]
      -[CCCreatingDocumentPreviewOperation main]

The RTF reader does this for every bold, italic and font size control word:

    font = [manager convertFont: font toHaveTrait: NSBoldFontMask];
    [_currentAttributes setObject: font forKey: NSFontAttributeName];

with no nil check, so a nil from the conversion is not a degraded font, it is an exception that ends
the parse and therefore the preview.

THE FIRST FIX WAS THE WRONG ONE AND THE COUNT SAID SO. convertFont:toHaveTrait: could return nil
when a typeface was found but fontWithName could not build a font from its name, so that was
repaired first. The exception count before and after was 3 and 3: the guess was wrong, and a count
is what caught it rather than an argument about the code.

The nil came from the other two converters. convertFont:toSize: ended in a bare

    return [NSFont fontWithName: [font fontName] size: size];

with no fallback and no nil-font guard at all, and convertFont:toFamily: returned whatever
fontWithFamily gave it. Apple returns the font it was handed when a conversion fails, which
convertFont:toFace: in this same file already does with a comment saying exactly that. All four
converters now agree. Exceptions 3 to 0, and the rich text frames in the log fall from 4 to 2.

This is a fix for any application that reads RTF, not only this one. iTerm2 re-run afterwards, since
NSFontManager is reached by everything: picture still drawn, no crash, keys still delivered.

STILL OPEN on this application: the nib stops at NSConnections; the template grid is dark grey where
macOS is light; the in-window menu bar has only the application name, because building the main menu
binds items to objectValue which NSMenuItem does not have; and the heading is clipped at its top.

### NSMenuItem answers objectValue now, and that did NOT restore the menu bar

219 exceptions in one launch, all the same:

    NSUnknownKeyException: <NSMenuItem: title: Delete ...> is not key value coding compliant
    for the key objectValue

The backtrace names the mechanism exactly, and it is not a missing property on the application side:

    -[NSObject(NSKeyValueCoding) valueForUndefinedKey:]
    -[_NSKVOBinder writeDestinationToSource]
    -[_NSKVOBinder bind]
    MenuItem(NSString*, id, NSString*, NSString*, ...)
    -[CCDocumentController createMainMenu]

Swift Publisher builds its menu through a helper that BINDS each item, and a binder reads the bound
object with valueForKeyPath: the moment the binding is made. NSMenuItem answered nothing for
objectValue. macOS answers it, most likely because AppKit carries a private ivar of that name and
key value coding finds it, so ours answers it now. It is stored in an ASSOCIATED OBJECT rather than
a new ivar, because NSMenuItem is public and the applications here are prebuilt, which takes any
question about subclass layout off the table.

    objectValue raises   219 -> 0
    all raises           223 -> 4
    log                  4247 lines -> 807

AND IT DID NOT DO WHAT I EXPECTED, which the earlier note in this file predicted it would. The
in-window menu bar still carries only the application name. The claim that these exceptions cut
createMainMenu short and emptied the menu bar is WRONG: the menus come from MainMenu.nib, which
loads, and the menu bar was empty for some other reason. What the fix did is remove 219 real
exceptions from menu construction, which is worth having on its own and is all that is claimed.

WHAT THE QUIETER LOG NOW SHOWS, having been buried under those 219:

  NSWindowServerCommunicationException from -[NSDisplay init], reached from
    +[NSFontFamily addFontFamilyWithName:] on a BACKGROUND thread during preview building;
  -[__NSPlaceholderAttributedString initWithCoder:] unrecognized, so an attributed string cannot be
    read back out of a keyed archive, which is what -[CCDocument readFromURL:ofType:error:] needs;
  -[NSApplication setAppleMenu:] unimplemented, which is a menu bar lead worth following;
  and a nib decode reporting objectpair key=NSMenuItem wants=NSMenuItem value=NSMenu.

Both of the exceptions above were present BEFORE this change, in the four that were not about
objectValue, so none of them is a consequence of it.

### The menu bar was never empty, it was drawing eight blank items

Swift Publisher showed a menu bar with the application name and nothing else. Two theories were
tested and BOTH WERE WRONG before the right one turned up, which is the useful part of this.

WRONG ONE. The plan said the objectValue exceptions cut createMainMenu short. Fixing them removed
219 exceptions and changed the menu bar not at all.

WRONG TWO. setMainMenu: only gives the menu to windows that exist when it is called, and this
application builds its menu in applicationWillFinishLaunching: before any window exists, so a window
created later could never receive it. That reasoning is sound and the conclusion is still wrong; the
trace says so:

    CIDER_MAINMENU set items=9 windows=0
    CIDER_MAINMENU addWindow class=NSWindow panel=0 mainMenu=9 windowMenu=9

The window already HAS the nine item menu by the time it is added. The code written for that theory
never fired, so it was removed rather than left in with a comment claiming a fix.

THE ACTUAL CAUSE came from printing the titles rather than the count:

    titles=[Apple sub=1] [ sub=1] [ sub=1] [ sub=1] [ sub=1] [ sub=1] [ sub=1] [ sub=1] [ sub=1]

Nine items, every one with a submenu, and EIGHT WITH AN EMPTY TITLE. The bar was drawing all nine
and eight of them were blank. That is the ordinary Cocoa idiom for building a menu bar in code:

    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle: @"File"];
    NSMenuItem *item = [[NSMenuItem alloc] init];      // no title of its own
    [item setSubmenu: fileMenu];

and macOS draws File, taking the name from the submenu when the item has none. Ours drew nothing.
The main menu view now falls back to the submenu title, in the DISPLAY path so that nothing an
application can read back is changed.

    Swift Publisher 5  File  Edit  Insert  View  Format  Arrange  Window  Help

iTerm2 re-run afterwards and its bar is unchanged, which is the case that matters: it titles its
items, so the fallback must not touch it.

METHOD, worth keeping: a count told me nine items existed and hid the whole problem. The titles told
me eight were blank. Print the CONTENT, not the size.

### An attributed string could not be read out of a keyed archive, and the run format was derived

-[__NSPlaceholderAttributedString initWithCoder:] was an unrecognized selector, so ANY archive
holding an attributed string failed to decode. Swift Publisher hits it opening its own documents in
-[CCDocument readFromURL:ofType:error:], which is why no template preview could be built.

THE FORMAT WAS MEASURED, NOT GUESSED, which matters because inventing a byte layout here produces
text with silently wrong attributes rather than an error. Apple writes:

    NSString         the characters
    NSAttributes     ONE dictionary when the whole string shares its attributes, an ARRAY otherwise
    NSAttributeInfo  the runs, present only in the array case

The runs are repeated pairs of (length, index into NSAttributes). Reading each as a single byte
explains many archives and fails on the rest:

    strlen 702 attrs 3 info [16, 0, 1, 1, 173, 5, 2]     seven bytes, not pairs at all

Reading them as ULEB128 varints explains it exactly: 16, then 1, then (173 & 0x7f) + (5 << 7) = 685,
and 16 + 1 + 685 = 702, the string length. Checked across the Swift Publisher template set by
requiring that run lengths sum EXACTLY to the string length and every index is inside the array:

    1-byte pairs   456 of 628 archives, 172 unexplained
    ULEB128 pairs  628 of 628 archives, 0 unexplained

3,840 of the 4,468 archives in those templates are the uniform single-dictionary case and 628 carry
runs, so both halves are worth having.

Measured after: the initWithCoder exception goes from 4 to 0. ENCODING IS STILL ABSENT, said plainly:
an application that archives an attributed string has nothing to call, and this fixes reading only.

The four exceptions that remain in the run are all ONE cause, which the quieter log now makes
obvious: NSWindowServerCommunicationException out of -[NSDisplay init], reached through
NSThreadSharedInstance on a BACKGROUND thread, once from +[NSFontFamily addFontFamilyWithName:] and
once from -[NSWindow initWithContentRect:styleMask:backing:defer:].

### One display per process, not one per thread, and a flake that nearly caused a wrong revert

+[NSDisplay currentDisplay] answered NSThreadSharedInstance, so EVERY THREAD that asked for the
display tried to build one, and building one opens a connection to the window server. On any thread
but the first that fails, and it fails as an exception rather than a nil:

    NSWindowServerCommunicationException: Failed to connect to a window server
      -[NSDisplay init]
      NSThreadSharedInstance
      +[NSFontFamily addFontFamilyWithName:]      font lookup on a worker thread
      -[NSWindow initWithContentRect:...]         and window creation on one

Swift Publisher builds document previews on an NSOperationQueue and does both there. There is ONE
connection to the compositor in this process, so there is one display. NSApplication creates it from
the main thread during init, which is what makes the first caller the right one.

Swift Publisher now runs with NO EXCEPTIONS AT ALL: 4 to 0, and its total raise count is zero.

AND THE REGRESSION CHECK LIED ONCE, which is the part worth recording. The first iTerm2 run after
this change reported no image and NO KEYS reaching PTYTextView, which reads exactly like a display
singleton breaking a second process. It was not: the log was 8,416 lines with windows presented, so
not the usual startup fault either, and re-running the SAME build gave image drawn, 38 keys
delivered, no crash, and the picture on screen. A revert on the strength of the first run would have
thrown away a correct change.

The rule that saved it is the one already in this file: re-run before believing a single run.
LibreOffice was checked alongside and is unaffected.

### Correcting the Swift Publisher exit: it does not exit cleanly, it SEGFAULTS

Everything written here so far about this application stopping said it reaches NSConnections in
CCWellcomeWindowController.nib and EXITS WITH STATUS 0. The status is real and the conclusion drawn
from it was wrong.

Two things say so. The log ends MID-WRITE, in the middle of an NSLog:

    -[CCDocumentController setAutosavingDelay:] unimplemented ...
    -[NSButton setCanDrawConcurrently:] unimplePROBE_EXIT=0

A process that calls exit finishes the line it is writing. And systemd has a core for that run, timed
to the second at 05:11:43, 15.5 MB, SIGSEGV, from the container mldr. So the process is killed by a
segmentation fault and the harness reports 0 anyway, which is why no amount of reading the log was
ever going to find a terminate call.

WHERE IT FAULTS, from core-guest-stack.py --threads, which is the tool for this because
systemd-coredump shows ONE thread and it is not the one that died:

    10 threads
    tid 3   libobjc.A.dylib+0x3d4d7   <- the only one not in a kernel wait
    tid 6..14  libsystem_kernel.dylib+0x3d36d

So it dies in a message send. Naming the receiver needs the stack words walked out of the core and
resolved, which is the next step rather than a finished one.

AND IT GETS MUCH FURTHER THAN THE RECORD SAYS. The nib is no longer where it stops: NSConnections is
the last nib KEY logged, but decoding the connections pulls in the connected objects, and the run
now goes on through hundreds of font decodes, NSButton, NSScroller, NSTabView, NSOutlineView and
NSSplitView setup, and into CCDocumentController. The attributed string decoder and the process wide
display are what moved it, and the remaining fault is somewhere past all of that.

### A WebView was declared on NSObject, and a nib puts one in a view hierarchy

The segfault named in the previous entry is solved, and the core is what named it. Walking the
faulting thread stack out of the dump, rather than reading the log:

    tid 3: rip in libobjc
      [    0] Foundation   __decodeObjectBinary
      [   10] WebKit       _OBJC_CLASS_$_WebView      <- the class itself, ten words in
      [  288] libobjc      _objc_msgSend
      [  306] Foundation   __decodeObjectBinary
      [  328] Foundation   __decodeObject

So it dies decoding a WebView out of the nib. The declaration says why:

    @interface WebView : NSObject

A nib puts a WebView IN THE WINDOW VIEW HIERARCHY, so decoding one sends -initWithCoder:, and
NSObject has no such method. It went to the catch-all forwardInvocation stub, whose method signature
says the return is VOID, so the return register was never written and the unarchiver took whatever
was in it as the new view. AppKit then sent view messages to that value.

Two changes. WebView now inherits NSView, which gives it initWithCoder:, a frame, a superview and
drawing, and is what a placeholder for a web view has to be: an empty rectangle in the right place
rather than an object of the wrong shape. And both stubs here now answer NIL rather than a register
nobody wrote, by declaring an object return and setting it, because garbage returned to a caller
crashes far away from the stub that produced it.

The link then needed AppKit as a WebKit sibling, since a class needs its superclass at link time.
macOS WebKit links AppKit for exactly the same reason.

LOOKED AT, and this is the result: THE WELCOME WINDOW OPENS. Title bar with three lights, its
Show this window when Swift Publisher 5 opens checkbox, and a Close button. Six window presents
where there were three. The body of the window is EMPTY, which is honest: the WebView is a
placeholder and nothing here renders HTML.

WHAT THE RUN NOW REACHES, having got past the crash: 1,298 exceptions, every one of them
-[NSColor_CGColor CGColorRef] unrecognized. That is the next thing rather than a regression; the log
went from 810 lines to 30,707 because the application is doing far more than it could before.

### NSShadow has always asked for a CGColorRef that no colour class answered

With the WebView crash gone the run reached the drawing, and 1,298 of its 1,298 exceptions were one
selector:

    NSInvalidArgumentException: -[NSColor_CGColor CGColorRef]: unrecognized selector

This is not the application being unusual. It is cocotron asking itself. -[NSShadow set] is

    CGColorRef color = [_color CGColorRef];
    CGContextSetShadowWithColor(context, _offset, _blurRadius, color);
    CGColorRelease(color);

and that accessor exists nowhere, so EVERY shadow in every application raised. There is exactly one
caller in the whole tree, which is what made it safe to add.

Two implementations, because NSShadow asks whatever colour it was handed. NSColor_CGColor returns
its own ref, and the base NSColor builds one by converting to calibrated RGB, so a catalog colour or
any other subclass answers as well; a colour that cannot convert answers NULL rather than raising,
which CGContextSetShadowWithColor reads as no shadow.

OWNED, NOT AUTORELEASED. The caller above releases what it gets, so returning the ivar unretained
would hand NSShadow a colour it then over-releases. That is the sort of detail that turns a fix into
a crash two frames later.

Measured, before and after, on the same harness:

    raises        1298 -> 6
    CGColorRef    3880 mentions -> 0
    log          30,707 lines -> 1,002

The six that remain are four distinct small gaps: setUsesFindPanel:, captureBitmapInRect: on the
abstract O2Context, URLQueryAllowedCharacterSet and disableAutomaticTermination:.

iTerm2 re-run afterwards, because NSColor is reached by everything: picture drawn, no crash, 38 keys
delivered.

### Swift Publisher does not stay up, and it is Sparkle that kills it

A CORRECTION TO HOW I HAVE BEEN REPORTING THIS. The welcome window and the template gallery are
real and the captures of them are real, but the application ABORTS ABOUT 1.2 SECONDS AFTER LAUNCH,
having drawn both. That is why the harness for it shoots a burst from t=0 rather than settling
first: there is nothing to settle to. Writing that the window opens without writing that it then
disappears was half the truth.

It was found by trying to CLICK something. A click harness that waits sixteen seconds and then
presses Close produced an empty capture directory and no driver output at all, because by then
there was no process. The log says the same thing plainly once looked at:

    present number=2 count=3 size=910x590 t=1.20
    Uncaught exception: ...
    PROBE_EXIT=0

and systemd has a SIGABRT core for it. An uncaught Objective-C exception on a dispatch queue does
not unwind to anything, it aborts, and the harness still reports 0.

WHAT RAISES IT IS THE UPDATER. Swift Publisher ships Sparkle, and Sparkle starts an update download
about a second after launch:

    -[SPUDownloaderSession startTemporaryDownloadWithRequest:]
      -[NSProcessInfo disableAutomaticTermination:]   <- missing, now implemented

NSProcessInfo had neither the sudden nor the automatic termination pairs. They are counts rather
than flags, because macOS documents them as nesting and an application may hold several reasons at
once; nothing here can act on the count, and that is said in the source rather than implied.

THAT MOVED THE ABORT RATHER THAN REMOVING IT. Sparkle now gets one step further and dies on

    -[NSURLSessionDownloadTask initWithCompletionHandler:]: unrecognized selector

and NSURLSessionDownloadTask exists ONLY as a declaration in NSURLSession.h: there is no
implementation anywhere. So the remaining blocker for this application is a working NSURLSession
download stack, which is a project rather than a rung, and it is the auto updater phoning home
rather than anything the application itself needs to run.

### Swift Publisher stays up and answers a click, once its updater is switched off

The abort chain was Sparkle, and the next link after disableAutomaticTermination was a whole
NSURLSession download stack that does not exist. Rather than build one for an auto updater, the
check was turned off THE WAY A USER WOULD: Sparkle reads SUEnableAutomaticChecks from user defaults
before the Info.plist, so setting it false in the application own preferences stops the check. No
application code is modified and nothing in Cider is faked.

WHERE THE PREFERENCES ACTUALLY LIVE, which cost a run to find. Writing the plist under
/Users/root/Library/Preferences did nothing at all. The guest HOME is /var/root, and the file the
application really reads and writes is

    <prefix>/var/root/Library/Preferences/com.belightsoft.SwiftPublisher5.plist

It already held SUHasLaunchedBefore, written by Sparkle itself, which is what proves CFPreferences
works here and that the first attempt had simply been put in the wrong directory.

WITH THAT SET, MEASURED:

    uncaught exceptions   1 -> 0
    process lifetime      aborts at 1.2 s -> runs the full 60 s of the harness

and the second criterion can finally be tested at all. Driving cider-vptr to press the welcome
window Close button:

    before   welcome window over the gallery, Close at 1022,618
    after    welcome window GONE, the full Template Gallery revealed, six tiles with captions,
             New Document, Blank Portrait, Blank Landscape, Facing Pages, Half-Fold, Tri-Fold

So a real pointer event reaches a real control and the application acts on it. RENDERS and
INTERACTIVE are both met for this application now. RESIZABLE is untested.

WHAT IS STILL MISSING, said plainly: NSURLSessionDownloadTask has no implementation, so an
application that downloads anything still dies on it. Turning the updater off is a workaround for
testing this application, not a fix for that gap, and any application whose own work needs a
download will hit it.

### Swift Publisher meets all three criteria, and the Choose button does not enable

Driven end to end with cider-vptr and captured at every step, so each claim is a picture rather
than a count.

    d1  welcome window over the gallery
    d2  click Close at 1022,618      -> welcome window GONE, full gallery revealed
    d3  click Blank Portrait tile    -> the tile is SELECTED, blue highlight around it
    d4  click Choose at 1186,661     -> nothing; the button is drawn dim and no document opens
    d5  resize the output to 1000x600 -> the window redraws at the new size AND RELAYOUTS: the tile
                                        grid reflows from three columns to two, the source list,
                                        menu bar, Open Recent and Choose all reposition, and the
                                        title recentres

RENDERS, INTERACTIVE and RESIZABLE are all met for this application. Two clicks land on two
different controls and both act, and the relayout is a real reflow rather than the window being
stretched or clipped.

WHAT DOES NOT WORK: the Choose button never enables. The template selects, so the gallery knows
what was picked, but the button stays disabled and no document window opens, which means the
application cannot actually be used yet. Whether that is button enablement, a binding that
validates the selection, or something the gallery only does after a preview loads, is not yet
known and is the next thing to find out.

Also lost across the resize: the tile selection highlight. macOS keeps it.

### The click is real, proved by not clicking, and two instruments were in the wrong place

Doubt arrived from an instrument rather than from a picture. A trace in -[NSControl mouseDown:]
printed NOTHING for any button in a whole run, including the Close button that visibly works, and a
trace in -[NSControl sendAction:to:] printed nothing either. Two silent instruments while the thing
they watch demonstrably happens means the instruments are in the wrong place, not that the click is
imaginary, but it does mean the interactivity claim rested on one picture.

So the claim was tested by REMOVING the cause. The same harness, identical timings and identical
captures, with the pointer events suppressed:

    with clicks     d4: welcome window GONE, gallery revealed, tile selected
    without clicks  d4: welcome window STILL OPEN

That is a control experiment rather than a screenshot, and it settles it: the click closes the
window. Swift Publisher is interactive.

WHAT IS STILL UNEXPLAINED. Clicking Choose does nothing, and the button is ENABLED when it happens:

    CIDER_CONTROL setEnabled class=NSButton title=Choose flag=1   (four times)

so the application does enable it once a template is picked, which corrects the earlier note here
saying the button stays disabled. Its title is also drawn grey in the run where a template was
selected, darkest pixel 102,102,102 against 0,0,0 for the Close button that works, and drawn dark in
the run where nothing was clicked. Neither the drawn colour nor the dead click is explained yet, and
the path a button click actually takes in this AppKit has not been found: it is not
-[NSControl mouseDown:] and not -[NSControl sendAction:to:].

Fixed along the way, and it was mine: the WebView stub declared its method signature as "@@:", which
says every method takes no arguments, so the first one that took an argument produced

    NSForwardSignatureError: invoked with 3 args, but 2 expected. Selector setFrameLoadDelegate:

The signature is now built from the selector by counting its colons. Four such errors in a run
became zero.

### Two real URL gaps closed, and the theory they were built on was wrong

The Choose button is disabled at the moment it is clicked, which the pointer in the trace settles:
one button, 0x...9cd0, enabled when a template is picked and DISABLED again before the click.

    setEnabled flag=0 was=1      disabled
    setEnabled flag=1 was=0      enabled when the template is selected
    setEnabled flag=1 was=1      (three more)
    setEnabled flag=0 was=1      DISABLED again
    mouseDown  enabled=0         the click lands on a disabled button

That also corrects an earlier note here: the button is not enabled-but-drawn-dim, it is genuinely
disabled when clicked, and the grey title is therefore correct.

THE THEORY. The disable came immediately after an exception thrown out of closing the welcome
window, and the path was exact:

    -[NSControl mouseDown:] -> performClose: -> -[NSWindow close]
      -> -[CCWellcomeWindowController sendRequestToLoadMainPage] -> parametersString()
         -> +[NSCharacterSet URLQueryAllowedCharacterSet]                    unrecognized

so the theory was that the throw left the gallery in a half-configured state and disabled Choose.

TWO REAL GAPS WERE CLOSED FOLLOWING IT, and both were worth closing on their own:

  +[NSCharacterSet URL*AllowedCharacterSet], all six, contents from RFC 3986 as Apple documents
    them, ASCII only and written out rather than composed from alphanumericCharacterSet which
    reaches far outside ASCII;
  -[NSString stringByAddingPercentEncodingWithAllowedCharacters:], whose sibling
    stringByRemovingPercentEncoding was already there, encoding the UTF-8 BYTES of any character
    outside the set so a multi byte character survives the round trip.

Raises in a run went 8 to 4 and both of those selectors are gone from the log.

AND THE BUTTON IS STILL DISABLED. Removing both exceptions from that exact path changed nothing
about Choose, so the theory was wrong: the throw was not what disabled it. What disables it is still
unknown, and the next step is to find who calls setEnabled:NO rather than to guess again, which
means a backtrace at the setter rather than a line count.

### Who disables Choose: the application does, on every window update

A backtrace on the way DOWN through -[NSControl setEnabled:] answers the question three guesses
could not. Only on a disable, since an enable was never the puzzle, and symbols only, the same way
-[NSException raise] prints its frames. Four distinct backtraces in a run, and the one that matters
appears twice:

    -[CCAssistantController updateNextButton]
      -[NSNotificationCenter postNotification:]
      -[CCAssistantController windowDidUpdate:]

and once more through

    -[CCAssistantController updateNextButton]
      -[CCAssistantDesignController outlineViewSelectionDidChange:]

So nothing in AppKit is disabling this button. The APPLICATION is, from its own updateNextButton,
called from windowDidUpdate:, which -[NSWindow update] posts on every pass of the event loop. That
also corrects the shape of the earlier note: this is not a single disable following the welcome
window close, it is a decision re-made continuously, which is why removing two exceptions from the
close path changed nothing.

WHAT IS LEFT TO FIND is what updateNextButton reads. It concludes that nothing is chosen while the
tile is visibly selected, so the application view of the selection differs from what is drawn. The
second backtrace is the hint worth following: outlineViewSelectionDidChange: means the SOURCE LIST
is part of that decision, and an NSOutlineView whose selectedRow does not agree with its highlight
would produce exactly this.

The instrument is worth keeping. CIDER_TRACE_CONTROL now prints, per control, the setter with the
object POINTER, the mouseDown with the enabled state at click time, and a symbolised backtrace for
every disable. The pointer is what proved this is one button changing its mind rather than two
buttons with the same title.


## A view could not screenshot itself, which is why every template tile was empty

-[O2Context captureBitmapInRect:] was O2InvalidAbstractInvocation on this backend. Only the two
Windows contexts ever implemented it, so on Linux every caller got an exception instead of pixels.
The caller that matters is -[NSBitmapImageRep initWithFocusedViewRect:], which is how an application
screenshots its own view, and Swift Publisher builds every template preview that way.

THE FORMAT IS NOT NEGOTIABLE. initWithFocusedViewRect: hands the result straight to
CGImageSourceCreateWithData, so raw pixels are useless: it has to be a file some decoder recognises.
The Windows implementation returns a BMP file and O2ImageSource_BMP is in the registry, so this one
does too. The surface is 32 bit little endian ARGB, which is BGRA in memory, which is exactly what a
32 bit BI_RGB BMP wants, so the rows copy across without swizzling; the only transformation is that
BMP stores the last row first. bmp_test accepts biSize 12, 40, 56 or 108, and this writes 40.

THE FIX EXPOSED THE NEXT BUG IMMEDIATELY, which is the useful part. With capture returning data the
app went one step further and the process died:

    CoreFoundation HALT at CFRuntime.c:574 in CFRelease,
    called from +[NSBitmapImageRep canInitWithData:]

+[NSBitmapImageRep canInitWithData:] released the image source unconditionally, and CFRelease(NULL)
is a halt, not a no-op. The method exists precisely to be asked about data that might not be an
image, so every honest NO took the process down with it. It had never fired before because nothing
had ever handed it data that no decoder claimed.

EVIDENCE, on the run after both fixes. CIDER_TRACE_IMAGESOURCE now prints the capture as well as the
decoder that claimed it:

    cider-capture rect=0,0 440x340 surface=440x340 out=440x340 bytes=598454
    CIDER_IMAGESOURCE matched O2ImageSource_BMP
    cider-capture rect=0,0 340x440 surface=340x440 out=340x440 bytes=598454
    CIDER_IMAGESOURCE matched O2ImageSource_BMP
    CIDER_IMAGESOURCE imageRepsWithData frames=1 reps=1

598454 is 440 x 340 x 4 plus the 54 byte header, so the geometry is right, and the tiles that used to
be empty dashed placeholders now show real page thumbnails. The comparison is against a capture from
an earlier build of the same gallery, not against a memory of one.

WHAT THIS DID NOT FIX is the Choose button, and the pixels lied to me about that. In one run the
button was drawn with black text and a border and I read that as enabled; the control trace on the
next run says otherwise:

    CIDER_CONTROL mouseDown self=0x7276418764b0 class=NSButton title=Choose enabled=0

So the click still lands on a disabled button. The trace also shows the shape of it: Choose is
enabled at startup, and -[CCAssistantController updateNextButton] disables it about 150 ms after the
welcome window closes, then never re-enables it when a template tile is clicked. The two runs
disagreed about how many tiles had previews, so the preview work is asynchronous and racing, and a
statement about this button is only worth making with the trace next to it.

## Two definitions of the same class, twenty six times

Chasing the preview failure turned up a raise that named a class we do implement:

    -[CCLayoutManager setBackgroundLayoutEnabled:]: unrecognized selector

CCLayoutManager is the application subclass, and llvm-objdump --macho --objc-meta-data on the
application says its superclass is _OBJC_CLASS_$_NSLayoutManager. The same dump on our AppKit says
NSLayoutManager there has 112 methods including setBackgroundLayoutEnabled:, from a category called
CiderTypesettingSwitches. So the method exists and the subclass descends from the class that has it,
and it was still not found.

The dump answers why: UIFoundation ships its OWN NSLayoutManager, a 34 line stub whose superclass is
NSObject and whose entire method list is methodSignatureForSelector: and forwardInvocation:.
Intersecting the two class lists gives TWENTY SIX classes defined in both images:

    NSATSTypesetter, NSCollectionViewFlowLayout, NSCollectionViewLayout,
    NSCollectionViewLayoutAttributes, NSCollectionViewLayoutInvalidationContext, NSFont,
    NSFontDescriptor, NSGlyphGenerator, NSGlyphInfo, NSLayoutManager, NSMethodSignature,
    NSMutableParagraphStyle, NSParagraphStyle, NSShadow, NSTextAttachment, NSTextBlock,
    NSTextContainer, NSTextList, NSTextStorage, NSTextTab, NSTextTable, NSTextTableBlock,
    NSTypesetter, UINibEncoder, _NSAttributeRun, _NSAttributes

NSFont and NSMethodSignature are on that list, which is not a small thing.

THE INSTRUMENT FOR THIS, and the reason it is worth keeping: -[NSObject doesNotRecognizeSelector:]
now prints the whole superclass chain with the IMAGE each class came from, via class_getImageName.
A class name on its own cannot tell a missing method from a class that is not the one you think it
is, and the chain says which in one line:

    cider:   chain CCTextView                       MacOS/Swift Publisher 5
    cider:   chain NSTextView                       C/AppKit
    cider:   chain NSObject                         lib/libobjc.A.dylib

That is vendor/patches/corefoundation/0018. The CCLayoutManager raise has not recurred since the
capture fix, so which of the two NSLayoutManagers wins on a given run is still unmeasured; the
duplicate list above is the thing to act on regardless.


## The Choose button: three bugs in NSMatrix, found by reading the application

The button was disabled and nothing in our code was disabling it, so the only way forward was to
read what the application asks. -[CCAssistantController updateNextButton], disassembled out of the
shipping binary with the selectors resolved, is four selectors long:

    [tabView selectedTabViewItem] -> [tabView indexOfTabViewItem:]  ; if index == 1, return
    [nextButton setEnabled: [designController isDesignSelected]]

and -[CCAssistantDesignController isDesignSelected] is six instructions:

    cell = [templateView selectedCell]
    return cell != nil

templateView is a CCAssistantTemplateView, whose superclass in the objc metadata is NSMatrix. So the
whole button is one question: does our NSMatrix have a selected cell. Tracing selectedCell,
selectCellAtRow:column: and _setSelectedIndexFromCell: printed the answer as a sequence:

    selectCellAtRow row=0 col=1 rows=284 cols=2 cells=568
    setSelectedIndex index=1 cells=568         <- the remembered template, selected at startup
    selectedCell index=1 cells=568
    selectedCell index=-1 cells=570            <- gone, and the cell count changed
    selectCellAtRow row=0 col=1 rows=190 cols=3 cells=570
    setSelectedIndex index=1 cells=570
    selectedCell index=-1 cells=568            <- gone again

The count moving 568, 570, 568 is the gallery fitting itself to its scroll view, twice, before the
user gets to click anything. Three bugs were behind that:

1. renewRows:columns: called _deselectAllCells unconditionally. macOS does not clear the selection
   there, and an application that relays out on resize expects the chosen cell to stay chosen. The
   selected cell is now remembered across the rebuild and restored if it survived.

2. removeColumn: removed the wrong objects. _cells is row major, so the cell at row r column c is at
   r * _numberOfColumns + c, and the loop removed index i * col: a scatter of unrelated cells, and
   for column zero, index zero over and over, which is the first ROW. After one relayout every cell
   was at a different row and column than the one it was drawn at. That is why clicking a tile did
   nothing: -[CCAssistantTemplateView mouseDown:] asks the cell from cellAtRow:column: whether
   isImageLoading and returns immediately if it says yes, so it was asking a cell that was never
   drawn and never loaded.

3. _setSelectedIndexFromCell: stored NSNotFound when the cell was not in _cells. NSNotFound is
   NSIntegerMax, which is positive, so it went straight past the _selectedIndex < 0 test in
   selectedCell and was caught only by the count check under it, the one whose own comment says it
   should not be needed. It stores -1 now.

VERIFIED, on the run after the fixes: the selection holds at index 1 through 568, 570 and 568 again,
and the click on the button reports

    CIDER_CONTROL mouseDown class=NSButton title=Choose enabled=1

against enabled=0 before. New NSMatrix objects with three and four cells appear immediately after,
which is the application building document furniture.

THE DOCUMENT STILL DOES NOT OPEN. One line after the click:

    -[__NSPlaceholderAttributedString initWithRTFD:documentAttributes:] unimplemented

so the template text cannot be read and the document build stops there. That is the next rung, and
it is a real piece of work rather than a stub: RTFD is RTF with attachments.


## RTFD, and the rest of the road to a document

With Choose working, the first thing the click hit was

    -[__NSPlaceholderAttributedString initWithRTFD:documentAttributes:] unimplemented

initWithRTF: has been implemented all along, through NSRichTextReader; only the two RTFD entry
points were stubs. RTFD is RTF plus attachments, and two shapes arrive at that method: plain RTF,
which applications pass to the RTFD entry point all the time, and flat RTFD, which wraps the same
RTF in a serialised file wrapper. The wrapper format is not documented, so rather than guess at its
table this finds the RTF inside it and reads that. THAT IS A HEURISTIC and is written down as one in
the source: the attachments are dropped, and text that arrives with none is exact. The directory
form, initWithRTFDFileWrapper:, is a lookup of TXT.rtf and needs no guessing.

Both entry points also handle a NULL documentAttributes pointer, which initWithRTF: writes through
unconditionally.

MEASURED, not assumed: after the change the unimplemented line is gone and the fallback trace that
fires when no RTF can be found in the data did not fire, so an RTF payload was located and handed to
the reader. Whether the reader liked it is not proven by that, and is not claimed.

WHERE THE DOCUMENT ACTUALLY STOPS, read out of -[CCAssistantController buttonNext:]:

    idx = [tabView indexOfTabViewItem: [tabView selectedTabViewItem]]
    path = [designController getCurrentDocPath]          ; nil BAILS
    doc  = [[CCDocument new] initWithDocumentType:andOptions:]   ; nil BAILS
    ok   = [doc readFromURL: url ofType: type error: &err]       ; NO BAILS
    [doc setFileURL:] [doc setShowLayoutElements:]
    [[NSDocumentController sharedDocumentController] addDocument: doc]
    [doc updateChangeCount:]
    [doc makeWindowControllers]                          ; the window comes from here

Three silent bail-outs before anything is visible, which is why pressing the button looks like it
does nothing at all. The action itself is confirmed to fire:

    CIDER_CONTROL send class=NSButton action=buttonNext: target=CCAssistantController enabled=1

and the application goes on to load fonts and the colour panel nib, so it is doing work. Tracing
-[NSDocument readFromURL:ofType:error:], -[NSDocumentController addDocument:] and
-[NSDocument makeWindowControllers] is what says which of the three bails, and those traces are in
this commit.


## iTerm2 stopped starting, and the cause was a more correct Foundation

A fresh run of iTerm2 died six lines in, before any window, with

    This copy of libswiftCore.dylib requires an OS version prior to 10.14.4.

and cider-crashtrace named the frame: libswiftCore checkVersion -> swift::fatalError -> abort.
Disassembling the bundled library says what that check is:

    __swift_isBackDeploying:
        version = <cached OS version>
        if major <  10   -> 1
        if major != 10   -> 0
        if minor <  14   -> 1
        return (minor == 14) && (patch < 4)

    checkVersion:
        if (__swift_isBackDeploying()) return;
        fatalError("This copy of libswiftCore.dylib requires an OS version prior to 10.14.4.")

so on anything at or after 10.14.4 the bundled copy refuses to run, ON PURPOSE. We report 14.4.1,
so the abort is CORRECT. It used to pass only because the cached version comes from
-[NSProcessInfo operatingSystemVersion], which our Foundation could not answer; the selectors the
initialiser uses are operatingSystemVersion, instancesRespondToSelector:, and failing that
dictionaryWithContentsOfFile: on SystemVersion.plist. A more correct Foundation is what turned
iTerm2 from working to dead, which is worth saying plainly.

macOS never reaches this because the OS provides Swift and dyld prefers it over an application
back-deployment copy. Cider is supposed to ship it too, and here is the part that had gone unseen:

    44 git-lfs POINTER files in the runtime, all of them /usr/lib/swift

The whole system Swift runtime was 132 byte text files. NOT a fetch bug: the pin already declares
lfs = true and both fetched store paths hold the real 6.4 MB libswiftCore.dylib. The stale copy was
vendor/src/swift, MATERIALISED before the flag was added, and scripts/buck-src.nu skips a tree whose
rev stamp already matches. FORCE=1 re-materialises it.

TWO FIXES, and both were needed:
  1. vendor/patches/dyld/0001: the system Swift wins over a bundled copy, keyed on the BASENAME
     before any prefix is expanded, because iTerm2 asks for
     @executable_path/../Frameworks/libswiftCore.dylib and the @rpath form is just as common. An
     @rpath-only version of this rule was written first and never fired once.
  2. FORCE=1 scripts/buck-src.nu vendor/pins/swift, so there is something to prefer.

VERIFIED by looking: iTerm2 comes up, ./imgcat imgtest8.png draws the gradient inline and the prompt
returns under it, on a capture taken after both fixes.

TWO TRAPS THIS COST TIME ON, both already in this document and both re-learned anyway:
  a stale container from an earlier run makes a fresh run render nothing, and it has to be cleared
  before EVERY run, not once; and the imgcat path needs CIDER_XPC_LAUNCH_SERVICES=1, which is in
  run-iterm-xpc.sh and not in run-iterm-visible.sh, so the wrong harness reports
  "CIDER_XPC lookup failed for service com.iterm2.sandboxed-worker" and draws nothing.

ALSO SELF INFLICTED: rsync -a --delete from the prefix artifact onto the runtime tree removes
usr/lib/cider-crashtrace.dylib, which //buck/prefix:cider_prefix does not ship. Without it
CIDER_TRACE_CRASH prints "cider-crashtrace did not open" and every crash is silent. Copy it back
after syncing.

## The prompt said Darling because a patch never reached the tree buck2 builds

/private/etc/bashrc sets PS1, and vendor/patches/bash/0001-prompt-and-comment-say-cider.patch is
the rename. vendor/src/bash was materialised before that patch existed, and buck-src.nu skips a
tree whose rev stamp matches, so the patch was never applied to what buck2 compiles. It stayed
invisible while the runtime tree still held an older bashrc built when the tree was current;
rsyncing a freshly built prefix over it is what surfaced it.

Checking every patched pin the same way, by trying to reverse-apply its latest patch against the
materialised tree, says bash is the ONLY stale one of the thirteen. That check is worth keeping.


## The three criteria, re-verified on the build that has all of tonight in it

The runtime changed a great deal in a few hours: system Swift precedence in dyld, a real Swift
runtime where 44 LFS pointers had been, NSMatrix, RTFD, view capture, a Foundation that answers
operatingSystemVersion. All three criteria were re-checked by LOOKING, on that build, not carried
forward from an earlier claim.

RENDERS. The menu bar, the terminal text, an inline image from imgcat, and the Shell menu opened
with its key equivalents right aligned, its separators, its greyed out items and its submenu
arrows. The prompt reads Cider again.

INTERACTIVE, keyboard AND mouse. echo before_resize runs and prints; the Shell menu opens on a
press at 87,36 and CIDER_MENU reports mouseDown on NSMainMenuView at 87,14 with a 290x627
NSSubmenuView behind it.

RESIZABLE, and this is the part that had a claim attached to it. Keystrokes DO still reach the
session after a resize: echo after_resize runs and prints, so the old "keystrokes stop reaching the
session after a resize" does not reproduce. The pty follows the window, measured with the app
itself rather than inferred:

    before   stty size -> 44 175      window 1256x684, 1256/175 = 7.2 px per column
    after    stty size -> 33 125      window  900x520,  900/125 = 7.2 px per column

and 7 px per column is what the capture measures directly, from glyph runs starting at x = 6, 13,
20. So the grid, the pty and the drawn cell all agree.

A CORRECTION I MADE MID-CHECK. The title bar reads 165x46 after the resize and I read that as the
grid failing to follow, on the arithmetic that 1256/165 and 637/46 land on the drawn cell size.
stty says otherwise, so that was wrong. 165x46 is the grid for 1180x700, the SECOND of the three
resizes the driver performs, so the indicator is one step stale while the session is correct.

WHAT IS STILL WRONG, and it is the reflow, not the size:
  a resize does not rewrap the scrollback. The old lines stay where they were and the shell draws
  its prompt below them, so each resize leaves a blank band and another prompt. Nothing is lost,
  scrolling back shows every line and the earlier stty output; macOS iTerm2 rewraps instead.
  The title bar size indicator lags one resize behind.
  A light grey edge, 238,238,238, about five pixels right and four bottom of an inline image.


## Three exceptions on the way to a document window, and one of them was ours

-[CCAssistantController buttonNext:] gets all the way to addDocument: and makeWindowControllers,
and no window appears. Three raises sat on that path, each one aborting the window setup silently
because the application catches them:

1. -[CCTextView setUsesFindPanel:] unrecognized. usesFindBar and usesInspectorBar were both
   present in NSTextView; usesFindPanel, the older switch that a nib built against an older SDK
   sets, was not. It is stored and answered now rather than NSUnimplementedMethod, because storing
   it IS the property; what is unimplemented is the find UI, which neither neighbour implements
   either. Raised while the document nib was being instantiated, which happens inside
   -[NSWindowController window], so the window was never finished.

2. +[NSSharingService sharingServiceNamed:] unrecognized, from

     -[CCMainWindowController shareToolbarItemMenu]
     -[CCMainWindowController toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:]
     -[NSToolbar loadDefaultItemsIfNeeded]

   NSSharingService had instance forwarding stubs, but a CLASS method has no such fallback: the
   metaclass forwards nowhere. It answers nil now, which is not a placeholder but the true answer,
   since none of those services exist here and nil is what macOS returns for one that is
   unavailable. A share button nobody asked for was taking the whole document with it.

3. OURS, and the interesting one:

     _NSControllerArray still being observed by <NSKeyValueObservance> on key path paperFormat
     -[_NSControllerArray dealloc]
     -[NSControllerSelectionProxy controllerWillChange]
     -[NSObjectController setContent:]
     -[_NSKVOBinder bind]
     -[CCMainWindowController setDocument:]
     -[CCDocument makeWindowControllers]

   -[NSControllerSelectionProxy _stopObservingSelectedObjects] asked [_controller selectedObjects]
   for the list to remove observers from. That is the same list it added them to only while nothing
   is changing, and controllerWillChange runs precisely when something is: the controller can
   already be answering the NEW selection, so the removal ran over objects that were never observed
   and left the observers standing on the old ones, which then raised on dealloc. It now keeps the
   objects AND the keys it registered and removes exactly those pairs.

WHAT CHANGED, and it is not a summary statistic: before the third fix the application generated two
template previews and stopped; after it, it reads template after template, Tri-fold, Z-Fold, Gate,
Accordion, Roll, Rack, and the gallery shows the whole category tree with many previews drawn.

THE DOCUMENT WINDOW HAS STILL NOT BEEN SEEN. The run that proved the previews also went off script:
the nested output came up at a different size, so the driver clicked where the welcome window was
not, and the sequence never reached Choose. The harness needs to fix its output resolution before
that run means anything.


## Where the document window actually stops: loadWindow does not return

The three exceptions above are gone and the window still does not appear, so the question became
which call never comes back. One print could not answer it: a single line after [self window] is
silent both when showWindow: was never reached and when it was reached and never returned. Printing
on entry as well separates them, and then the five steps of -[NSWindowController window] separate it
further. The answer, from one run:

    showWindow ENTER            CCWellcomeWindowController
    CIDER_WC windowWillLoad     CCWellcomeWindowController
    CIDER_WC loadWindow         CCWellcomeWindowController
    CIDER_WC done               CCWellcomeWindowController
    showWindow HAVE-WINDOW      CCWellcomeWindowController
    showWindow ORDERED          CCWellcomeWindowController

    showWindows[0]              CAMainWindowController
    showWindow ENTER            CAMainWindowController
    CIDER_WC windowWillLoad     CAMainWindowController
    CIDER_WC windowControllerWillLoadNib CAMainWindowController
    CIDER_WC loadWindow         CAMainWindowController        <- entered, never returns

CCAssistantController and CCWellcomeWindowController run all five steps and finish. The document
window enters loadWindow and stops there. Inside it are exactly three things: NSBundle
loadNibFile:externalNameTable:withZone:, synchronizeWindowTitleWithDocumentName, and the optional
cascade. The nib itself is known to DECODE, the trace shows Document2.nib read, its three object
pairs resolved and its toolbar images claimed by the TIFF decoder, so the stop is after the decode
and inside instantiation, connection or the title synchronisation.

That is the next rung, and it is a narrow one: bracket those three calls the same way.

CORRECTING MYSELF ONCE MORE: earlier in this document I wrote that -[NSWindowController showWindow:]
was never entered, on the evidence that its trace did not print. It IS entered. The trace called
[self window] before printing, so the print was downstream of the call that hangs. A trace that
depends on the thing it is measuring cannot report on it.


## The document window: -[CCMainWindowController awakeFromNib] never returns, and the process is fine

Bracketing narrowed it one step at a time, and each step needed the previous one to be wrong about
something.

    CIDER_WC loadWindow            CAMainWindowController
    CIDER_WC loadNibFile enter     CAMainWindowController     <- no leave
    CIDER_NIB phase buildConnections enter / leave
    CIDER_NIB phase mainMenu leave
    CIDER_NIB phase awakeFromNib enter
    CIDER_NIB awake 0/14 CAMainWindowController               <- no leave

The welcome window runs the same five steps and all three inner calls to completion, so this is
specific to Document2.nib. The object that does not come back is the FIRST of fourteen, and it is
the application own -[CCMainWindowController awakeFromNib].

TWO OF MY OWN READINGS WERE WRONG ON THE WAY, and the corrections are the useful part.

FIRST, I sampled the guest threads and found the main thread parked in syscall 47, recvmsg, on
__skb_wait_for_more_packets, and read that as blocked on an unanswered RPC to the daemon. It is not.
That is what an idle Cocoa event loop looks like here, because the event wait IS a socket read.

SECOND, I then checked the completion markers with a plain search over the whole log and found
loadNibFile leave, synchronizeWindowTitle leave and cascade leave all present, which would have
meant loadWindow completes. Those lines belong to the WELCOME window, which loads earlier and
prints the same strings. Scoped to the lines after Document2.nib opens, none of them appear. A
marker that is not scoped to the thing it is measuring is not evidence.

WHAT IS ACTUALLY HAPPENING, and it fits both observations at once: awakeFromNib does not return AND
the event loop keeps running, cider-wayland-appkit nextevent climbing past two thousand calls at
t=112. A method that never returns while its own application keeps pumping events is a method that
has entered a NESTED RUN LOOP. So the document window is not blocked on anything of ours; the
application is waiting inside awakeFromNib for something that never arrives, and pumping events
while it waits.

The 56 selectors in that method are mostly window furniture, toolbar, boxes, split view, tab view.
The next rung is to find what it waits FOR: the candidates worth checking first are the notification
handlers it registers just before the wait, handlerFTSelectionOfObjectsChanged:,
handlerFTDocViewBoundsMayBeChanged: and handlerFTNextStepForCheckSpelling:, and whether the
application is waiting on an operation queue that our side never completes.


## The document window, five more exceptions down, and a correction about the nested run loop

The last entry said awakeFromNib had entered a nested run loop, because it never returned while the
event loop kept pumping. THAT WAS WRONG, and the thing that showed it was adding the thread identity
and then reading the raises after the marker rather than only the markers themselves:

    CIDER_NIB awake 0/14 CAMainWindowController main=1 thread=0x74c18182ee40
    cider: RAISE ... -[_NSControllerArray dealloc] ... -[CCMainWindowController awakeFromNib]

An EXCEPTION unwinding out of awakeFromNib explains both observations at once and needs no nested
loop: the stack is torn back past every leave print, which is why none of them appeared, and control
lands in the application handler and then in the ordinary event loop, which is why nextevent kept
climbing. A trace that only prints on the happy path cannot tell a hang from an unwind.

FIVE EXCEPTIONS ON THAT ONE PATH, each uncovered by fixing the one before it, all inside
-[CCMainWindowController awakeFromNib] during the document nib load:

1. _NSControllerArray still being observed, on paperFormat and later on visibleRightView. The
   earlier fix to NSControllerSelectionProxy was not enough because the observers are registered on
   the ARRAY itself, not on its elements. -[_NSControllerArray dealloc] now UNWINDS what is left
   instead of raising: this array is not an object an application holds, it is the transient value
   a controller hands back and replaces whenever the content changes, so the controller destroying
   it is normal. The forwards to its elements are removed, which is what removeObserver: would have
   done, because leaving them attached would be the real bug.

2. NSRangeException: index (-1) beyond array bounds (0), from
   -[_NSControllerArray removeObserver:forKeyPath:]. indexOfObject: answers NSNotFound, the code
   stored it in an int, and NSUIntegerMax in an int is -1. Removing an observer that is not
   registered now does nothing, which is what it means.

3. -[CCSplitView setAutosaveName:] unrecognized. NSSplitView had no autosaveName at all. The name is
   stored and answered; persisting divider positions is separate work and is not claimed.

4. -[CCCanvasesPreviewAndDocumentSplitViewController loadView] nibName is nil. AppKit says a view
   controller with no nib gets a plain NSView and that a subclass overrides loadView; ours raised
   instead. It makes the empty view now.

5. +[NSImage imageTypes] unrecognized. It did not exist. It answers the UTIs that match the decoders
   registered in O2ImageSource, PNG, TIFF, JPEG, BMP, GIF and ICNS, so it is a real answer and not
   an empty array claiming we can read nothing.

WHERE IT STOPS NOW, and it is ours:

    -[NSDisplayWayland currentModeForScreen:]: unrecognized selector

NSDisplay declares modesForScreen: and currentModeForScreen:, X11Display implements both, and the
Wayland backend implements neither. The contract is small: a dictionary of Width, Height and Depth
for the current mode, and an array holding it for the list. The geometry is already there, it is
what display_screens hands out from session::output_size. What is missing is the Rust side plumbing
to build an NSDictionary, since the backend today only has message sends for zero arguments, a
rect pair, and a pointer with a length.


## Three more, and the document nib now reaches the inspector

Continuing down the same path, each fix uncovering the next raise inside
-[CCMainWindowController awakeFromNib]:

6. -[NSDisplayWayland currentModeForScreen:] unrecognized, and this one was OURS. NSDisplay
   declares modesForScreen: and currentModeForScreen:, X11Display answers both from XRandR, and the
   Wayland backend answered neither. Both are implemented now from session::output_size, the same
   source display_screens uses, so the mode cannot disagree with the screen; Depth is 32 because
   that is what the surfaces are. It needed one new message send signature, msg_send_obj2, for
   setObject:forKey:.

7. -[NSCell sendActionOn:] unrecognized. The mask is stored, the old one returned, and isContinuous
   is kept in step with it, which is how the two are defined against each other. NOTHING READS THE
   MASK YET: tracking code that consults it to decide when to send the action is separate work and
   is not claimed.

8. -[NSNumberFormatter setLocalizesFormat:], then setMinimum:, and the legacy family around them.
   localizesFormat predates CFNumberFormatter and has no kCFNumberFormatter key, so it lives in the
   same attributes dictionary as the rest of the state. minimum, maximum, format,
   thousandSeparator and hasThousandSeparators were DECLARED IN THE HEADER and never implemented.
   Stored and answered, not enforced: nothing clamps a formatted value to the range, and that is
   said in the source rather than implied.

A COST WORTH RECORDING: adding two declarations to Foundation/NSNumberFormatter.h rebuilt
JavaScriptCore and a thousand other actions, about twenty five minutes. The implementation file
alone is seconds. An application reaches these through the runtime, so where our own header is not
the caller, the method can go in the .m and the header can be left alone.

WHERE IT STANDS NOW. The document nib load gets FAR further than object 0 of 14: it now loads the
inspector nib, 958 objects, and works through it. The remaining raises there are different in kind,
-[__NSCFDictionary isEqualToString:], __NSCFArray does not support addObserver:forKeyPath:, and an
NSUnknownKeyException on an NSPopUpButton, and the application carries on past them.

THE WINDOW STILL DOES NOT APPEAR, and the failure has CHANGED shape: the application now exits
cleanly, status 0, a few seconds after Choose, with no crash and no signal, while building the
inspector. That is not the exception unwind that was there before, and it is the next thing to
chase.


## A stub that returns NULL is returning SUCCESS, and it cost a SIGSEGV

The clean exit turned out not to be an exit at all. Ruling that out took three instruments and two
of them printed nothing, which was the useful part:

  -[NSApplication terminate:] and -stop: were traced with backtraces, and the run loop was traced
  where it falls out of its do while. NONE of the three ever printed, and the markers were verified
  present in the deployed binary first, so the silence is evidence rather than absence.

  cider-crashtrace grew an atexit handler. It prints who called exit, which a crash handler never
  sees, and it immediately named two container helpers, path_helper and bash, exiting normally.

With those ruled out the real thing was already in the log, from the crash handler:

    cider CRASH signal=11 code=1 addr=0x0
    0  CoreFoundation      CFArrayGetCount + 44
    1  Swift Publisher 5   +[CCEnvironment fillPageSizeMenuWithDelegate:] + 192
    2  Swift Publisher 5   -[InspectorViewController awakeFromNib] + 7638
    ... -[NSWindowController loadWindow] ... -[NSDocument showWindows]

SIGSEGV at address zero. The application had not exited cleanly; it had died, and the status 0 came
from the container shell around it.

WHAT IT WAS. Disassembling the caller shows the shape exactly:

    lea rsi, [rbp-0x50]        an out parameter
    xor edi, edi               a NULL printer
    call PMPrinterGetPaperList
    test eax, eax / jne        an error would have branched away
    mov rdi, [rbp-0x50]
    call CFArrayGetCount       on whatever the out parameter holds

and our PMPrinterGetPaperList was declared void* f(void) returning NULL, like every other stub in
PrintCore.m. NULL in the return register is 0, 0 is noErr, so the application was told the call
SUCCEEDED and then read an out parameter nobody had written.

THE GENERAL SHAPE, worth more than this one function: for any OSStatus API, returning NULL is not a
neutral placeholder, it is the success code. A stub that cannot do the work must answer an ERROR, or
the caller proceeds on data that does not exist. PMPrinterGetPaperList, PMCreateSession and
PMServerCreatePrinterList now have their real signatures, clear their out parameters and return -50,
paramErr, which is the truth: there is no print system behind this framework.

VERIFIED: the SIGSEGV is gone, no crash dump at all, and the application survives the whole run
where it used to die a few seconds after Choose. All six captures exist now, including the ones
after the resize.

THE WINDOW IS STILL NOT ON SCREEN. The inspector nib, 958 objects, is still working through them
when the run ends, raising exceptions it survives: -[__NSCFDictionary isEqualToString:],
__NSCFArray does not support addObserver:forKeyPath:, and NSUnknownKeyException on selectedObject
and on an NSPopUpButton, repeating per popup. loadNibFile has still not returned by the end of the
run. Whether that is slowness or another stop is the next thing to establish, and the honest answer
today is that it is not known.


## A collection is not an observable link, and the harness was lying about clicks

TWO THINGS THIS RUNG, one in the runtime and one in the measurement, and the second explains a
string of runs I had been reading wrong.

THE RUNTIME. -[NSKeyValueNestedProperty object:didAddObservance:recurse:] took whatever
valueForKey: returned for the next link of a key path and called addObserver: on it. When that value
is a collection, NSArray, NSSet or NSOrderedSet answer by RAISING, here and on macOS both, because
observing the collection object itself is not what a to-many relationship means. So any binding
whose path ran through a to-many key threw from inside the KVO machinery:

    __NSArrayI does not support -addObserver:forKeyPath:options:context:
    -[NSKeyValueNestedProperty object:didAddObservance:recurse:]
    -[NSObjectController addObserver:forKeyPath:options:context:]
    -[_NSTextFieldBinder startObservingChanges]
    +[GUIBinder bindTo:withKeyPath:...]
    -[InspectorViewController awakeFromNib]
    -[NSNib instantiateNibWithExternalNameTable:]

and the exception unwound the document window nib load. The link is skipped now, on the add side and
on BOTH removal sites, because a path skipped on the way in has to be skipped on the way out or the
teardown throws instead. That second half only appeared after the first was fixed. 79 skips in a
run, and both exception kinds are gone from the log.

THE MEASUREMENT, and this one is a lesson about the harness rather than the port. Captures from one
run came out 1256x684, 1690x1388, 1690x1388: the nested output is a window inside the user own
compositor and that compositor RESIZES IT WHILE THE RUN IS GOING. Every driver coordinate is
absolute, so a resize between two clicks sends the next one somewhere else entirely. Runs where
Choose never fired, which I had been reading as the application ignoring a click, were the driver
clicking the wrong tile. The output is now re-pinned before EVERY click and the tile is clicked
twice, because the first click can also be swallowed by isImageLoading. Both changes together make
the run reproducible: three runs in a row now reach the document nib.

WHERE IT STANDS, measured rather than summarised: the inspector nib reaches object 0 of 958 and
-[InspectorViewController awakeFromNib] still does not return. It is not an exception storm, 31
raises in the whole stretch, and the main thread is parked in recvmsg rather than spinning, so it is
WAITING. It is not an XPC lookup either: CIDER_TRACE_XPC prints nothing after that point.

WHAT IS STILL RAISING THERE, all survived by the application: -[__NSCFDictionary isEqualToString:]
and the same on __NSCFNumber, NSUnknownKeyException for the key selectedObject on an NSPopUpButton,
-[NSTextField setNilValueForKey:] unrecognized, and -[NSURL startAccessingSecurityScopedResource]
unrecognized. selectedObject is a real NSPopUpButton binding and setNilValueForKey: is a documented
KVC hook, so both are honest gaps to close next.


## Three more gaps on the binding path, and the exception load falls 33 to 7

All three were things the code already promised and never delivered, which is a different kind of
bug from a missing feature: the class advertises a key or a hook and then does not answer it.

-[NSObject setNilValueForKey:] was DECLARED in NSKeyValueCoding.h and CALLED from six places in
NSKeyValueAccessor.m, every one of them the path where nil is set for a scalar key, and implemented
nowhere. The call therefore became doesNotRecognizeSelector, so instead of the documented
NSInvalidArgumentException a caller got an unrecognized selector, which reads as a missing class
rather than a rejected value. The chain trace made that plain: NSTextField, NSControl, NSView,
NSResponder, NSObject from libobjc, and nowhere for the selector to land. It raises now, with the
message Cocoa uses, because raising IS the documented default; an object that accepts nil for a
scalar overrides this hook, which is why the hook exists.

NSPopUpButton posts willChange and didChange for selectedIndex, selectedValue, selectedObject and
selectedTag whenever the selection moves, and had an accessor for exactly one of them. A class that
notifies about a key it is not key value coding compliant for is a contradiction, and binding to
selectedObject raised NSUnknownKeyException six times per run. selectedObject is the represented
object of the selected item, selectedValue is its title, and setting either selects the item that
carries it; an object no item carries clears the selection rather than inventing one.

-[NSPopUpButton(BindingSupport) _setItemValues:forKey:] passed the content array straight into
addItemsWithTitles:. Content bindings routinely hold objects that are not strings, and the first
thing -[NSMenu itemWithTitle:] does is send isEqualToString: to compare with existing items, so a
popup bound to dictionaries or numbers raised once per item. Values are coerced with description
now, which is what Cocoa shows for a value with no display key or transformer, and nil becomes an
empty string so the item count still matches the content array.

MEASURED: raises inside the inspector nib load fall from 33 to 19 to 7 across the three fixes, each
one confirmed by its own exception disappearing from the log rather than by the total.

STILL NOT DONE, and this is the fourth rung in a row where it is the same sentence:
-[InspectorViewController awakeFromNib] reaches object 0 of 958 and does not return, so the document
window never appears. It is not an exception storm, it is not spinning, it is not an XPC lookup. The
next thing to try is a different instrument rather than another API gap: the seven remaining raises
are worth reading in full, and if none of them unwinds the load then the wait needs finding with a
stack from inside the wait, not from the frames of an exception.


## It was never a hang: an uncaught exception on a worker thread was killing the process

Four rungs ended on the same sentence, that -[InspectorViewController awakeFromNib] reaches object 0
of 958 and does not return. That sentence was true and the conclusion drawn from it was wrong twice.

FIRST WRONG READING, corrected here: I said six of the seven remaining raises unwind the nib load,
on the evidence that their frames run through instantiateNibWithExternalNameTable:. They do not
prove that. CIDER_TRACE_EXCEPTIONS prints the backtrace AT THE RAISE, and writeDestinationToSource
wraps that set in a @try, so those frames show where an exception started, not where it ended.

WHAT WAS ACTUALLY HAPPENING. The instrument that settled it was a new one: cider-crashtrace now
handles SIGUSR1 and prints a stack WITHOUT killing the process, so a thread can be sampled while it
is stuck. Before it was ever used, its sibling caught the answer:

    cider CRASHTRACE signal=6
    abort <- abort_message <- demangling_terminate_handler <- _objc_terminate
          <- std::terminate <- _dispatch_client_callout <- _dispatch_root_queue_drain
          <- _dispatch_worker_thread2 <- _pthread_wqthread <- start_wqthread

An Objective C exception reaching the top of a libdispatch block is caught by nobody: terminate
aborts the WHOLE PROCESS. The main thread was not hanging, it was being killed mid method, and from
the main thread that is indistinguishable from a method that never returns.

The exception was -[NSURL startAccessingSecurityScopedResource], declared in NSURL.h and implemented
in neither NSURL.m. It is the security scoped bookmark pair, and on a system with no sandbox the
truthful answer is YES, the file is already reachable; NO would mean access refused and a careful
caller would skip the work. Implemented with its partner, stopAccessingSecurityScopedResource.

THE DIFFERENCE, measured on the same harness:

    before   inspector nib awakens object 0 of 958, 11 windows, process aborts
    after    inspector nib awakens 957 of 958, awakeFromNib LEAVES, 145 windows, no abort at all

A second abort of the same shape followed immediately, -[NSMenuItem setView:] from
-[ImagePopUpButton menu] on an NSOperation, and is fixed the same way: the view is stored and
answered. THE MENU DRAWING STILL IGNORES IT, so an item with a view set draws empty; that is written
in the source rather than left to be discovered.

WHERE IT STANDS. The document window is STILL NOT ON SCREEN, and the gallery is what the capture
shows. But the failure is no longer a mystery with no stack: the application now survives to the end
of the run, idle in its event loop, having built 145 windows, and the remaining raises are a long
tail of binding keys on its own view classes, selectedIdentifier on NSTabView and content,
contentObjects, contentValues and selectedObject on an NSMatrix subclass, plus
-[NSView adjustSubviews], which is a consequence of MY nib-less view controller fallback handing
back a plain NSView where a split view controller wanted an NSSplitView.


## A split view controller now builds a split view, and the document nib load completes

The nib-less fallback added earlier hands a view controller a plain NSView, which is what AppKit
documents. For NSSplitViewController that is the wrong view, and the application said so:

    -[NSView adjustSubviews]: unrecognized selector

adjustSubviews lives on NSSplitView, so this was a consequence of my own fallback rather than
anything unusual in the application. The place to fix it is the subclass, not a special case inside
NSViewController: a controller that wants a particular view overrides loadView, and
NSSplitViewController is that controller. It makes an NSSplitView now and answers splitView.

WHAT IS STILL MISSING THERE is the split view ITEM machinery, addSplitViewItem: and splitViewItems,
so such a controller has a real split view with no children in it. The forwarding stubs still catch
those and log them, which is the honest state rather than a silent nothing.

MEASURED, and it is the first time this line has changed:

    CIDER_WC loadNibFile leave        YES

The document window nib load COMPLETES now. It has never done that before; every earlier run ended
inside it, first on an exception, then on a process abort from a worker thread.

STILL NOT ON SCREEN, and the capture shows the gallery. After loadWindow the remaining steps of
-[NSWindowController window] are windowDidLoad, windowControllerDidLoadNib: and done, and none of
them printed before the run was killed at its limit, so the next question is whether those are
slow or stopped, exactly the question that was answered once already for loadWindow.

A HARNESS CAVEAT THAT STILL BITES: the run that produced this capture came out 1690x1388 even with
the re-pin before every click, because the parent compositor can resize the nested output between a
click and the shot that follows it. The measurement above comes from the LOG, which is not affected
by that; a claim about the picture from that run would be.


## The main thread is in the event loop, and has been all along

The sampler built last rung finally ran, and the answer overturns the framing I had been using for
five rungs. Sampled twice, twelve seconds apart, while the document window was supposedly being
built, the main thread is:

    NSApplicationMain -> -[NSApplication run] -> nextEventMatchingMask: -> display_next_event
      -> -[NSRunLoop runMode:beforeDate:] -> CFRunLoopRunSpecific -> __CFRunLoopServiceMachPort
      -> mach_msg -> dserver receive

There is no awakeFromNib on that stack, no nib loading, no showWindow. THE METHOD RETURNED. What
never happened was the printing of its leave markers, and an exception unwinding past them explains
that exactly, as it did for the earlier abort.

TWO CORRECTIONS TO MY OWN LAST TWO ENTRIES:

1. I wrote that the document nib load COMPLETES, on the strength of CIDER_WC loadNibFile leave
   appearing. Scoped to the controller that matters it does NOT appear: CAMainWindowController stops
   at loadNibFile enter, and the leave belonged to CCWellcomeWindowController and CCAssistantController,
   which load their own nibs earlier and print the same words. This is the SECOND time an unscoped
   marker has fooled me in this document, having already been written down as a lesson once.

2. The nib phase markers have the same defect: CIDER_NIB phase awakeFromNib leave says nothing about
   WHICH nib. In order, the sequence is Document2.nib open, awake 0/14 CAMainWindowController,
   Inspector.nib open, awake 0/958 InspectorViewController, awakeFromNib LEAVE. The leave is the
   INSPECTOR nib finishing. The document nib never finishes.

THE INSTRUMENT ITSELF NEEDED FIXING, and that is worth recording. The first sampler called
backtrace() and printed frames=0 three times. backtrace() answers 64 frames from a libdispatch
worker here and ZERO from the main thread, which is a property of that stack rather than of the code
being sampled. Walking rbp out of the Darwin ucontext, which is what the crash handler has been
doing all along, gives the seventeen frames above. An instrument that returns nothing is not
evidence of nothing.

WHAT THIS MAKES THE NEXT RUNG. Not a wait, not a hang, not a missing API: an exception that escapes
-[CCMainWindowController awakeFromNib] and leaves the window unbuilt. Frames printed AT THE RAISE
cannot say which exception escapes, because most of them are caught. The way to name it is to catch
it where it leaves: wrap the awakeFromNib loop in -[NSNib instantiateNibWithExternalNameTable:] in a
handler that PRINTS and RE-RAISES.


## The escape catcher, and the failure moving earlier than the nib

The instrument the last entry asked for is in: the awakeFromNib loop in
-[NSNib instantiateNibWithExternalNameTable:] is wrapped in a handler that PRINTS the exception and
RE-RAISES it, so it fires only for an exception that has already walked out of awakeFromNib and it
changes no behaviour.

IT HAS NOT SPOKEN YET, and that is reported as nothing rather than as a result. Two runs in a row
did not reach Document2.nib at all, so the catcher had nothing to catch. The marker is present in
the deployed AppKit, checked, so the silence is about the runs and not about the build; an
instrument that has never fired proves nothing either way, which is the same rule that has already
cost time twice in this document.

WHY THOSE RUNS DID NOT GET THERE, and it is a different failure from the one being chased:

    NSInvalidArgumentException: attempt to insert nil object into NSMutableSet
      CFTCoreDoc::rearrangeWrappingPath()
      CFTCoreDoc::Serialize(CDDArchive const&, NSError **)
      -[CCDesignElement serialize:error:]
      -[CCDocument serialize:error:]
      -[CCDocument readFromData:ofType:error:]
      -[CCDocument readFromFileWrapper:ofType:error:]
      -[CCDocument readFromURL:ofType:error:]
      -[CCAssistantController createWizardDocument]

Reading the template now throws inside the application own serialiser, before any window nib is
loaded. The same exception has been visible on the preview worker threads for several rungs; this is
the first time it has been seen on the path the Choose button takes.

A nil going into a set means something we handed back nil where macOS hands back an object, and
rearrangeWrappingPath is about text wrapping around a shape. That is the next thing to name, and it
is worth naming with a real instrument rather than a guess: the frames stop at the C++ boundary, so
the next step is to find which of our calls inside that function can answer nil.

WHAT IS ALSO TRUE, and it explains the run to run variance in this document: whether a run reaches
the document nib at all depends on this exception, so several earlier runs that looked like harness
flakiness may have been this instead.


## The nil that stops the document has a name: CFTTextExt::layoutManager

The exception that ends document reading is

    NSInvalidArgumentException: attempt to insert nil object into NSMutableSet
    CFTCoreDoc::rearrangeWrappingPath()

and the frames stop at the C++ boundary, so the function was read instead. It uses six selectors,
set, addObject:, two fast enumerations, textContainers and textContainerChangedGeometry:, and the
loop around the addObject: reads:

    for each element of a C++ container
        if (element == NULL) continue                  <- checked
        casted = __dynamic_cast(element, ...)          <- a stub, resolved through its jmp
        if (casted == NULL) continue                   <- checked
        id lm = CFTTextExt::layoutManager(casted)      <- NOT checked
        [set addObject: lm]                            <- nil arrives here

So the application null checks the container element and the dynamic_cast and then trusts
CFTTextExt::layoutManager to answer an object. It answered nil.

WHAT I DO NOT KNOW, and will not assert: WHY it is nil. The obvious candidate was the very first
exception of this whole investigation, -[CCLayoutManager setBackgroundLayoutEnabled:] unrecognized
inside -[CCLayoutManager init], which would leave a text element with no layout manager. That would
close the chain neatly, and it is NOT SUPPORTED: CCLayoutManager appears zero times in each of the
last three runs. A tidy story is not evidence.

HOW TO NAME IT NEXT, since the frames end at the C++ boundary and that boundary has now been read
twice: the layout manager is an ObjC object held by a C++ wrapper, so the place to catch it is where
it is CREATED rather than where it is missing. -[NSLayoutManager init] and the text container and
text storage it is attached to are ours; a trace on those, printing which text element they belong
to, would say whether one was never made or one was made and lost.

The three selectors this function uses that are ours, textContainers and
textContainerChangedGeometry: on NSLayoutManager, are both implemented; I checked after a regex
first told me they were not, which is worth saying because that regex nearly became a claim.


## Layout managers ARE made: three hypotheses killed, and what the counts say

The rung was to catch the layout manager where it is created rather than where it is missing.
-[NSLayoutManager init], -setTextStorage: and -addTextContainer: now trace under
CIDER_TRACE_CONTROL, and one run says:

    init              371
    setTextStorage    371
    addTextContainer   45

WHAT THAT KILLS.

1. "The layout manager is never created." It is: 371 of them, and the trace names the class, so
   CCLayoutManager instances exist by name. The application subclass initialises fine.

2. "-[CCLayoutManager setBackgroundLayoutEnabled:] is still failing and leaving a nil." Already
   ruled out by its absence from three logs, and now positively contradicted: those objects reach
   -init and get a text storage.

3. "The container back pointer is not set, so [container layoutManager] answers nil."
   -addTextContainer: does [container setLayoutManager: self] and -layoutManager returns the ivar.
   That mechanism is correct where it runs.

WHAT IS LEFT, stated as a fact and not a theory: 371 layout managers are created and given a text
storage, and only 45 are ever given a text container. Whether that asymmetry is normal for this
application or is the defect is NOT established here, and the number on its own does not decide it.

AND ONE MORE FACT WORTH HAVING: the first "attempt to insert nil object into NSMutableSet" of a run
happens with ZERO raises before it, during the preview generation at startup, not on the Choose
path. So the nil is structural rather than the aftermath of some earlier caught exception, which is
what a chain of failures would have looked like. It fires twelve times in a run.

The document window is still not on screen. This rung bought three eliminations and two numbers, and
no fix; that is what it bought.


## The accessor is [[self textContainer] layoutManager], and my fix for it changed nothing

Reading CFTTextExt::layoutManager out of the binary finishes the sentence the last entry started. It
is not a member read:

    CFTTextExt::layoutManager()  ==  [ CFTTextExt::textContainer() layoutManager ]

one call to CFTTextExt::textContainer, one objc_msgSend of the selector layoutManager, and the
result is what goes unchecked into the set.

THAT POINTED AT A REAL DEFECT, and it is fixed: -[NSLayoutManager initWithCoder:] restored its
containers with

    [_textContainers addObjectsFromArray: [keyed decodeObjectForKey: @"NSTextContainers"]]

which appends to the array but never does what -addTextContainer: also does, namely
[container setLayoutManager: self]. Every text container decoded from an archive therefore answered
nil to -layoutManager while looking attached from the layout manager side. The decode now sets the
back pointer for any container that does not already name one.

AND IT CHANGED NOTHING. Same run, same harness, same count: twelve raises of attempt to insert nil
object into NSMutableSet, in the same frames. The fix is kept because the defect is real and the
asymmetry is plain from the counts, 371 layout managers created against 45 calls to
addTextContainer, but IT IS NOT THE CAUSE OF THE SYMPTOM and is not claimed as one.

WHAT I ASSUMED AND SHOULD NOT HAVE. That expression has two ways to answer nil, and I only pursued
one. If CFTTextExt::textContainer answers nil then [nil layoutManager] is nil as well, and the
container back pointer is irrelevant. Nothing measured so far distinguishes the two, and the next
rung is exactly that: a trace on -[NSTextContainer layoutManager] returning nil, which says whether
a container was asked at all.

## The layout manager was never joined to its container, and what that unblocked

THE BUG, end to end. Swift Publisher builds every text block the same way, straight from the
disassembly of CDDTextBlock::CDDTextBlock(double, double):

    initWithNewTextStorage()
    container = [[CCTextExtContainer alloc] initWithContainerSize: w h]
    [[[storage layoutManagers] objectAtIndexedSubscript: 0] addTextContainer: container]

Its storage is CCTokenizedTextStorage, an application subclass of NSTextStorage which supplies its
own primitives and so calls [super init], not -initWithString:. NSTextStorage had no -init, so that
went to NSObject and _layoutManagers stayed nil. Every step after that was a message to nil and
said nothing: addObject: to nil, layoutManagers answering nil, objectAtIndexedSubscript: on nil,
addTextContainer: on nil. The container was joined to nothing, and much later
CFTTextExt::layoutManager, which is [[self textContainer] layoutManager], answered nil and the
document read died putting it into an NSMutableSet.

Fixed by adding -init, and by creating the array on demand in -addLayoutManager: and
-layoutManagers. Measured: layout managers held 0 always to 1, containers answering nil 2566 to 0,
containers answering a real one 0 to 5 which is the trace cap, nil into set raises 10 to 0.

HOW TO FIND THIS KIND OF THING. The accessor had two ways to answer nil, a real container holding
nothing or a nil container, so put the trace where only one of them can reach and give it a positive
control, otherwise silence proves nothing. Then intersect pointer sets: 41 containers were wired and
never asked, 285 were asked and never wired, and the two sets did not overlap at all. dladdr on
__builtin_return_address named the application function that built the unwired ones.

## Three things behind it, and the platform wall they hit

Fixing the above let text layout actually run, and it immediately found the next three.

1. NSATSTypesetter WAS AN EMPTY STUB. The whole implementation lived in a sibling called
   NSTypesetter_concrete, so an application subclass of NSATSTypesetter, which is what CCATSTypesetter
   is, inherited only the abstract raise from NSTypesetter. On the real system NSATSTypesetter is the
   concrete typesetter. Merging the implementation into it removed all 26 raises of
   layoutGlyphsInLayoutManager only defined for abstract class, and layout ran for the first time.

2. FREETYPE FACES ARE SHARED AND WERE NOT PROTECTED. O2Font_freetype caches faces and already locks
   the cache, but nothing covered use of a face afterwards, and FT_Set_Pixel_Sizes and FT_Load_Glyph
   both write into the shared face and its single glyph slot. This is not theory: a contention
   counter recorded five real waits in one run, because the application lays text out on the main
   thread while an operation queue generates document previews.

3. THE BEST FONT CACHE IS A BARE STATIC. -[NSMutableAttributedString _bestFontForCharacter:...] keeps
   a static NSMutableDictionary with no lock, and the same two threads mutate it through
   -fixFontAttributeInRange:. That arrives as an abort inside __CFStringHash with no message and no
   address of ours, nowhere near the font code that caused it.

THE WALL. The obvious fix for 2 and 3 is a pthread mutex, and that is where the guest itself gives
out. Under real contention the run prints

    psynch_mutexwait failed internally: -111
    psynch_mutexdrop failed internally: -111

so a contended pthread mutex in guest code does not currently work. Uncontended trylock is fine,
which is why the contention counter reported happily while the abort continued. Anything that needs
mutual exclusion in guest code is blocked behind that until psynch is fixed.

WHERE THIS LEAVES THE APPLICATION. Worse than before, so the three changes above are reverted in the
commit that follows the one carrying them, and stay in history to be reapplied once psynch works.
With them the process aborts during the welcome window and captures nothing. Without them the
template gallery renders correctly and relayouts on a compositor resize, and the document window
still does not open.

## iTerm2 resize: the scrollback DOES rewrap, and the size indicator is a different bug

CORRECTING AN EARLIER CLAIM. The standing note said a resize does not rewrap the scrollback and
leaves a blank band and a second prompt. That is not what happens on the current build. Printed one
line of 200 W between two markers at 1000 px wide, where it occupies two rows, then narrowed to
700 px: it reflowed onto three rows with AAA1 and AAA2 still bracketing it, no blank band and no
duplicate prompt, and widening back reproduced the original layout exactly. Verified by looking at
the captures, not by a statistic.

The earlier run that suggested otherwise had failed before it began: the nested output came up at
1690x1388 because the resolution line in the sway CONFIG FILE does not take, the window never drew,
and the typing meant to happen before the resize went nowhere. Pin the output with swaymsg after the
socket appears, with a retry, and confirm it against get_outputs. run-iterm-rewrap.sh does this.

WHAT IS REAL is the size indicator in the title bar, and it is exactly one resize behind. Measured
twice in one run: at 700 px the title read 139x38, which is the 1000 px grid, and back at 1000 px it
read 96x38, which is the 700 px grid.

MECHANISM, so far as it is established. The title is set twice for three sizes, and the trace prints
the frame at the moment of the call:

    resized 700x600      no setTitle at all
    resized 1000x600
    CIDER_TITLE 96x38 frame=1000x600

iTerm2 computes the string from a grid it has not yet updated for the new frame, and only calls
setTitle when the string differs, which is why the narrowing produced no call at all. Neither
waiting eleven seconds nor typing makes it recompute, so this is not deferred work that never runs.

WHAT IT IS NOT. We were never calling -platformWindow:frameSizeWillChange:, so the delegate method
-windowWillResize:toSize: was never delivered for a compositor resize at all, which the real system
always does before applying one. That is now fixed and the call arrives once per resize. IT DID NOT
CHANGE THE INDICATOR: iTerm2 answers with the size unchanged and sets no title there. The fix is
kept as fidelity, not as a remedy, and is not claimed as one.

THE NEXT RUNG IS BETTER THAN THE INDICATOR. The macOS reference in Downloads/macos-images shows the
title bar reading a session name, ~/Downloads, with no size indicator at all. Ours reads
"  - 139x38" with an EMPTY name, so the leading authenticity gap in that title bar is not the stale
number but the missing name: iTerm2 gets the foreground job of the tty from process information,
and that is what to check next.

## The empty session name: proc_listpids and the working directory were both refused

The title bar reads "  - 139x38" with nothing before the dash because iTerm2 cannot find out what is
running in the session. It asks the kernel twice and was refused both times:

    sys_proc_info(): Unsupported callnum: 1          proc_listpids, 265 times in one run
    sys_proc_info(): Unsupported pidinfo flavor: 9   PROC_PIDVNODEPATHINFO, once

That is exactly the pair the macOS reference implies: it enumerates the processes under the shell,
then asks the one it finds for its working directory, which is what ~/Downloads in the reference
screenshot is. A guest pid IS the Linux pid in this emulation, which the rest of proc_info.c already
assumes when it reads /proc/<pid>/stat, so both come straight out of /proc. Implemented in
vendor/patches/xnu/0015, PROC_ALL_PIDS and PROC_PPID_ONLY for the listing and readlink of
/proc/<pid>/cwd through vchroot_unexpand for the directory.

WITH IT ON, every proc_info complaint in an iTerm2 run disappears. And then iTerm2 walks into the
next thing: getting a real process list, it builds an iTermProcessCollection and aborts inside OUR
NSIndexSet, in -[NSIndexSet _mergeOverlappingRangesStartingAtIndex:] under -[iTermProcessCollection
commit], through malloc_report, which is heap corruption whose guilty write is somewhere else. The
list macros in utlist.h and the merge itself read correctly, so this needs dynamic work, not
another reading.

SO THE LISTING IS OFF BY DEFAULT, behind CIDER_PROC_LISTPIDS, and one word turns it on. Refusing it
costs an empty name in a title bar. Serving it makes iTerm2 abort at startup, which is worse. The
working directory flavour is on, because nothing depends on it yet and it cannot make anything
crash.

## A crashed run poisons the next one, and the statistics do not say so

The run that checked the gated build came back with zero crashes, five captures and no complaints,
and every frame was solid black. The previous run had crashed and left launchd, memberd and
shellspawn alive under the same prefix; the harness only ever killed ciderd. Nothing errors in that
state, the application simply never draws.

kill-stale-prefix.sh kills every guest process of a prefix by PID, with the match pattern in the
FILE rather than on a command line, because a pgrep whose pattern is in its own argv matches the
shell running it. run-iterm-rewrap.sh calls it before every run. Zero crashes and five captures is
not evidence: look at one.

## DL_INSERT read its argument four times, and the second read changed it

The abort that kept the process listing switched off is a plain macro bug, and the trace named it in
four lines. Every RangeList birth and death was printed, and the tail read:

    IDXSET alloc p=0x...a6cf0 site=243
    IDXSET free  p=0x...a6cf0 site=1918
    IDXSET free  p=0x...a6cf0 site=1918     the same pointer, twice, with no allocation between

DL_INSERT(head, next_node, add) is called as DL_INSERT(head, ptr->next, newRange). Written out with
the argument substituted:

    (add)->prev = (ptr->next)->prev;
    (ptr->next)->prev->next = (add);      this ASSIGNS ptr->next = add
    (add)->next = (ptr->next);            so this reads add, and add points at ITSELF
    (ptr->next)->prev = (add);            and so does its prev

The inserted node came out as a one element circular list. DL_DELETE then saw del->prev == del, took
its only-element branch, set the head to NULL and unlinked nothing, so the merge loop read the same
next pointer again and freed it a second time. That is the malloc report under
-[NSIndexSet _mergeOverlappingRangesStartingAtIndex:]. The macro now reads next_node once, into a
local.

MEASURED, same harness: the run went from aborting after FOUR index set operations to 11,913 of them
with no crash and iTerm2 alive throughout, so proc_listpids is on by default now and the gate is
gone. Two frees in that run were of something not currently live, out of 11,913, which is most
likely addresses colliding across the several iTerm2 processes the log merges rather than a second
bug, and it is NOT claimed as clean until the trace carries a pid.

## A fresh materialisation did not build, and only a FORCE showed it

Re-materialising foundation to pick up the new patch broke the build:

    NSData.m:1277: error: missing context for method declaration

vendor/patches/foundation/0006 adds -initWithBase64Encoding: and -base64Encoding, and its hunk
anchored on context loose enough that patch placed both methods AFTER the @end that closes the
implementation. They belonged to no class and the file did not compile. The tree in vendor/src had
been correct only because it was materialised from a different starting point, which is exactly the
hazard of an untracked materialised tree: buck2 was building something nix could never reproduce.
0006 now anchors on the @end and the @implementation NSSubrangeData that follows it, and a forced
re-materialisation puts the pair inside the implementation and builds.

## What the title bar still does not say

The name is STILL empty. The listing works, nothing is refused, no complaint is printed, iTerm2
survives building its process collection, and the bar still reads "  - 96x38" with nothing before
the dash. So the missing name needs more than the process list, and what that is has not been
established yet. Do not read the fixed crash as a fixed title bar.

## CORRECTION: a guest pid is NOT the Linux pid, and proc_listpids answers in the wrong pid space

The commit that added proc_listpids said "a guest pid IS the Linux pid in this emulation, which the
rest of proc_info.c already assumes when it reads /proc/<pid>/stat". THAT IS WRONG, and the rest of
proc_info.c is wrong in the same way.

src/linux/server/src/container.rs:214 clones the container into a NEW PID NAMESPACE and mounts a
procfs for it at <prefix>/proc. So the pids an application holds are namespace local and small,
while proc_info.c sits BELOW vchroot where a bare /proc is the HOST procfs. Reading /proc/<pid> for
a guest pid therefore lands on an unrelated system process.

PROVEN, not argued. iTerm2 asked for the working directory of pid 25 and 26:

    PROCINFO cwd pid=25 readlink failed -13      EACCES, a host process we may not read
    PROCINFO cwd pid=29 path=[/Users/root]       the same call once the path goes through vchroot

So proc_listpids as committed hands out HOST pids, which an application can never match against its
own, and every pidinfo flavour that reads /proc/<pid> answers about the wrong process. It is not
harmful in the sense of a crash and iTerm2 behaves exactly as before, but the data is wrong and
nothing should be built on it until the pid space is fixed.

## And every guest process is called mldr

The second half of the same question. Field two of /proc/<pid>/stat is the LINUX executable, and
every guest process runs under the loader, so a whole run answers:

    2022 comm=[mldr]

plus mldr:sh0 and mldr:disk$0, where the loader squeezed a hint of the real program into the fifteen
characters Linux allows. Nothing in that tree is called sh, so an application looking for the job
running in its terminal finds nothing it recognises. The guest program IS available: the loader is
exec'd as "<loader>!<host path of the program>" with the GUEST path as the next argument, so
/proc/<pid>/cmdline has it.

## What was tried and is NOT committed

Routing every /proc read in proc_info.c through vchroot_expand, enumerating <prefix>/proc for the
listing, and taking the name from the guest command line. iTerm2 then exits 1 during startup before
opening a window, so it is reverted and NOT in the tree. The suspect is the vchroot_expand_args
buffer, a whole MAXPATHLEN, put on the stack of a helper called for every process in the tree; the
next attempt should not do that. The single cwd call, which is on a cold path, worked perfectly.

THE TITLE BAR NAME IS STILL EMPTY. Two real causes are now named and proven and neither is fixed.

## CORRECTION: the startup failure was not the stack buffer, it is vchroot_expand called too early

The previous entry blamed the vchroot_expand_args buffer, a whole MAXPATHLEN, on the stack of a
helper called once per process. THAT WAS A GUESS AND IT IS WRONG. The buffer is gone entirely in the
second attempt, which resolves the guest procfs ONCE into a directory fd and then reads relative
paths through it, so nothing large sits on any hot stack. iTerm2 still exits 1 during startup.

WHAT THE RUN SAYS. With -[PROC_PIDT_SHORTBSDINFO] routed to the guest procfs, the log has ZERO
PROCINFO lines, where the same gate printed thousands in earlier runs. The trace sits AFTER the
guest read in that function, so the process dies inside the very first call, before it can speak.
The only new thing on that path is vchroot_expand, and shortbsdinfo is called during early startup,
long before the listing is. Which is consistent with the one part that DOES work.

WHAT WORKS, verified: the LISTING alone may use the guest procfs. proc_listpids resolving
<prefix>/proc lazily on its first call left iTerm2 perfectly healthy, 45 window lines and a live
window, and the trace showed the directory fd resolved. The listing simply runs late enough.

WHY THAT IS NOT COMMITTED ON ITS OWN. It would make things WORSE, not better. The listing would hand
out namespace pids while every reader still reads the HOST procfs for them, so the two halves of the
answer would disagree with each other. Today both halves are wrong together, which at least is
consistent. This is a change that only helps once it is complete.

THE NEXT APPROACH, and the reason to think it will hold: the emulation is NOT chrooted, it maps
guest paths to host paths itself, so <prefix>/proc is an ordinary host path. Getting the prefix
without calling vchroot_expand on the early path, and opening that directly, avoids the early
vchroot call altogether. That is the thing to try next, not another variation on the buffer.

## Four eliminations on the guest procfs, and the bisect that made them worth having

The change is still not in. What IS now settled is where it is not, and the method that settles it.

THE BISECT, which is the useful part. Two files were in play, proc_info.c and vchroot_userspace.c,
and each was tested against the committed version of the other:

    committed kernel                      iTerm2 lives, 35 window lines
    vchroot accessor only                 iTerm2 lives, 42 window lines
    my proc_info.c                        iTerm2 exits 1 before drawing anything

So the fault is inside proc_info.c and the vchroot accessor is innocent. That accessor,
vchroot_prefix_if_known, answers the prefix only when it is already there and never initialises,
which matters because vchroot_expand initialises on demand and init_vchroot_path ABORTS if its RPC
fails.

FOUR THINGS IT IS NOT, each tried and each still failing:
  the multi kilobyte stack frame        rebuilt with nothing over 512 bytes on the path
  vchroot_expand called early           replaced by the non initialising accessor
  a descriptor held from early startup  replaced by open and close per read
  the undefined strrchr symbol          replaced by a hand written scan, symbol gone from the dylib

AND A MEASUREMENT THAT CONTRADICTS THE OBVIOUS READING. A probe on the FIRST line of
_proc_pidinfo_shortbsdinfo never fires, and neither does the one in proc_listpids, so with that
kernel iTerm2 dies before it calls proc_info at all. Yet the same kernel runs /bin/echo and /bin/ps
to completion, so it is not a load failure either. Those two facts together are the thing to explain
next, and they were only visible because the probe was moved to the first line of the function
rather than left after the code under suspicion.

A CHEAPER LOOP FOR NEXT TIME. cider shell /bin/ps answers in about thirty seconds and exercises the
same layer, against six minutes for the GUI harness. Note while using it that ps prints only its
header and no processes AT ALL, on the committed kernel as much as on any other, so that is a
pre-existing gap and not a symptom of this work.

STILL NOT WORKING: the title bar name, for the two proven reasons already recorded.

## The names come out right, and the same build starts only two times in eleven

CORRECTING THE ENTRY ABOVE. It said the bisect put the fault inside proc_info.c because the
committed kernel lived and mine exited 1. That reading was wrong: THE FAILURE IS NOT
DETERMINISTIC. The identical binary that had failed six times in a row then ran the harness twice
successfully, 42 and 45 window lines, so no amount of bisecting against a single run was ever going
to be sound.

WHAT THE CHANGE ACTUALLY DOES, when it starts, and this is the thing worth keeping. Reading
/proc under the prefix rather than at /proc, and taking the process name from the guest command
line, gives real names for the first time:

    508 comm=[mldr]        host processes, which correctly keep their Linux name
    354 comm=[shellspawn]
    177 comm=[launchd]
    177 comm=[iTerm2]
    176 comm=[-sh]
    176 comm=[login]
    176 comm=[iTermServer-3.4]

against comm=[mldr] and nothing else before it. Headless, the same kernel runs iTerm2 to a 45 second
timeout and prints pid=30 comm=[login] and pid=31 comm=[-sh], which is exactly what an application
looking for the job in its terminal needs.

WHY IT IS STILL NOT COMMITTED. Counting every run of each: the committed kernel started 3 times out
of 3, and this one 2 times out of 11. That is not a coincidence to argue away even though no single
run proves anything, so the change makes startup unreliable and stays out until that is understood.

AND THE TITLE BAR IS STILL NAMELESS ANYWAY. On the runs that do start, with every process correctly
named, the bar still reads "  - 96x38" with nothing before the dash. So the missing name needs
something beyond correct process names too, and the theory that the names were the last piece is
disproved rather than confirmed.

A FAST LOOP EXISTS NOW: cider shell on the iTerm2 binary with no compositor answers in 45 seconds
and exercises this whole path, against six minutes for the GUI harness. The committed kernel HANGS
there (alive at the timeout), which is the healthy baseline to compare against. Use it to find which
of the three parts, the listing, the stat read or the name, is the one that makes startup fragile.

## The flaky startup was my own cleaner, and with it fixed the change lands

CORRECTING THE TWO ENTRIES ABOVE, and they were both wrong for the same reason. The startup failure
I called intermittent, and then used to reject this change on a 2-of-11 pass rate, was
scratchpad/kill-stale-prefix.sh killing the very container it was clearing for.

It matched /proc/<pid>/cmdline against the prefix and then against mldr. EVERY hand run of the
container names both on its command line, because it passes CIDERPREFIX and DSERVER_MLDR_PATH there,
so the script matched itself, its own shell, and anything else in the middle of starting. That is
the trap this document already records, arriving inside a script written to avoid it. It now matches
/proc/<pid>/exe, which is what a process IS rather than what it was asked to do: a guest process
execs mldr and matches, a shell that merely mentions mldr does not.

MEASURED, same kernel, only the cleaner different:

    broken cleaner    iTerm2 alive 1 of 6
    fixed cleaner     iTerm2 alive 6 of 6

and with the proc_info change in as well, 6 of 6 again. So the change never destabilised anything,
and every startup conclusion drawn earlier today rests on a broken instrument.

WHAT IS NOW IN. Process info reads the procfs mounted for the container PID namespace rather than
the host one, and the process name comes from the guest command line, so the names an application
sees are real for the first time:

    488 comm=[mldr]        host processes, correctly keeping their Linux name
    328 comm=[shellspawn]
    164 comm=[securityd]
    164 comm=[launchd]
    164 comm=[iTerm2]
    163 comm=[-sh]
    163 comm=[login]

Verified from a FORCED re-materialisation, so nix and buck2 build the same source: patches 0015 and
0016 apply from pristine, the build is green, startup is 6 of 6, and the harness runs with no crash.

AND THE TITLE BAR IS STILL NAMELESS. With every process correctly named it still reads a size with
nothing before it, so the name was NOT the last piece and the theory behind this whole line of work
is disproved rather than confirmed. What it did buy is correct process information, which is worth
having on its own.

A NOTE ON READING CAPTURES FROM A TRACED RUN: with CIDER_TRACE_PROCINFO on, startup is slow enough
that the harness types before the session is ready and the first characters of a line are lost, so
the shell reports command not found. That is the harness being early, not the terminal dropping
input; the untraced runs show the whole line.

## The title bar is not broken: nothing was setting it

Typed one escape into the session by hand:

    printf "\033]0;CIDERTITLE\007"

and the bar reads CIDERTITLE - 139x38, in the trace and in the capture, which I looked at. So the
whole title path works: iTerm2 receives the escape, sets the title, and our window chrome draws it.

WHICH MEANS THE EMPTY NAME IS NOTHING SAYING ANYTHING, not something being lost. The bar reads two
spaces, a dash and a size because the name component is an empty string. On the real system that
name is put there by the shell: the macOS reference reads ~/Downloads because a default macOS shell
emits this escape from its prompt. Our guest shell emits nothing, so there is nothing to draw.

WHAT IS STILL OPEN, and it is a smaller question than it was. On macOS a session with no title
escape at all still shows the JOB name rather than an empty string, and iTerm2 now has the job name
available, since process info reports -sh and login correctly. Whether iTerm2 needs shell
integration for that fallback, or whether we are still missing something it wants, is not
established. What IS established is that this was never a rendering or a chrome bug.

TWO HARNESS TRAPS HIT WHILE ESTABLISHING IT, both mine:
  A driver block spliced with an off by one left ") &&" where ") &" belonged, so the driver ran
    SYNCHRONOUSLY BEFORE the application started: it typed into nothing and captured an empty
    screen, and the run looked like the escape had been ignored.
  That capture was also 1690x1388 rather than the pinned 1000x600, which is the same signature as
    the unpinned output trap, and would have sent me after the wrong thing if I had not read the
    generated script.

## The grey edge on an inline image is the window background, not a wrong colour

Measured properly for the first time, with a solid red 240x120 image so that any pixel which is not
pure red came from us. The image draws EXACTLY right, 28800 pure red pixels which is 240 times 120
with the bounding box the same, so nothing is scaled, cropped or tinted. The defect is beside it:

    right of the image   FF0000 FF0000 | EEEEEE x5 | 000000 ...
    below the image      FF0000 x3     | EEEEEE x6 | 000000 ...

AND THE ARITHMETIC NAMES THE SHAPE. 240 plus 5 is 245, which is exactly 35 cells of 7 pixels, and
120 plus 6 is 126, exactly 9 rows of 14. So iTerm2 reserves a whole number of CELLS for an image and
the leftover strip is the remainder of that block.

THE COLOUR IS NOT A CHOICE ANYONE MADE. CIDER_TRACE_PAINT over the strip records no write into it at
all, only the big window fills at c=0.930, and 0.930 of 255 is 237, which is the EEEEEE being seen.
So the strip is not painted the wrong colour: it is NEVER PAINTED, and what shows through is the
window background. On the real system that remainder carries the session background, which is black.

That is a different bug from the one in the note it replaces, and a smaller one: find why the
terminal view does not paint the remainder of a cell block it has claimed.

## Two things about the test rig, one of them from the user

THE NESTED COMPOSITOR IS A WINDOW IN A TILING MANAGER, so it is resized whenever that manager likes.
Captures coming back 1690x1388 with the output pinned to 1000x600 are that, not a broken pin, and I
had blamed my own scripts for it more than once. Run HEADLESS when a fixed size matters.

BUT HEADLESS HAS NO SEAT KEYBOARD. Run that way the window never gets focus, wtype types into no
surface, and the capture comes back with a bare prompt and grey title buttons, which reads exactly
like the application ignoring input. Focusing by IPC reports success and changes nothing. So:
headless for anything about SIZE or pure rendering, nested for anything that needs INPUT.

## The permission alert next to the macOS reference

imgcat raises "Allow Terminal-Initiated Display?" here exactly as it does on macOS, which is why an
image never drew in these runs until Return accepted it. Ours is recognisably the same alert with
the same words, and differs in: corner radius, much smaller here; no drop shadow; buttons that are
rounded rectangles rather than full pills, and much narrower; an unchecked checkbox drawn as a white
box with a thin border where macOS fills it grey; and smaller text throughout.

## CORRECTION: the remainder is transparent inside iTerm2 own bitmap

The entry above said the strip is never painted and concluded the terminal view fails to paint the
remainder of its cell block. The first half is right and the conclusion is wrong. The image trace
says what actually happens:

    CIDER_IMAGESOURCE initWithBitmapDataPlanes 245x126 bps=8 spp=4 alpha=1
    CIDER_IMAGESOURCE NSImage drawInRect 245x14 at 0,0 size=245x126 reps=1 best=NSBitmapImageRep

iTerm2 allocates a bitmap that is ALREADY the whole cell block, 245x126 with an alpha channel, draws
the 240x120 picture into it, and blits it back one 14 pixel row at a time. So there is no scaling
question and nothing skips a fill: the remainder INSIDE that bitmap is simply transparent, and a
transparent blit reveals whatever is under it, which here is the window background at 0.930 grey.

That relocates the bug. Either the bitmap should have been cleared to the session background before
the picture went in, or what sits under an image block should be the session background rather than
the window background. Which of those macOS does is the thing to settle next, and it is worth
settling with the disassembly rather than another guess, because both are plausible.

NOT ESTABLISHED: the confirming run, with the image resized to exactly one cell block so that a
remainder cannot exist, RENDERED NOTHING AT ALL, a wholly black capture. It proves neither way and
is not counted.

## Settled from the disassembly: iTerm2 never fills that bitmap, so macOS paints underneath

The fork was whether macOS clears the image block bitmap to the session background, or paints the
session background under the block. The disassembly of
-[NSImage(iTerm) safelyResizedImageWithSize:destinationRect:scale:] answers it outright. The whole
body is:

    NSBitmapImageRep alloc -> initWithBitmapDataPlanes:... -> setSize:
    saveGraphicsState -> graphicsContextWithBitmapImageRep: -> setCurrentContext:
    drawInRect:fromRect:operation:fraction:
    restoreGraphicsState -> NSImage initWithSize: -> addRepresentation:

There is NO fill, NO clear and NO colour set anywhere between allocating the bitmap and drawing into
it. So the remainder is transparent on macOS as much as here, and what macOS shows through it is
whatever lies UNDER the image block. Which means the terminal view there paints the session
background across the rows an image occupies, and ours does not.

AND IT IS NOT THE WINDOW COLOUR EITHER. Tracing -[NSWindow setBackgroundColor:] through a whole run
records five calls, all on ONE window, and every one of them asks for controlColor at 0.930 grey.
Nothing ever asks for black. So the black under the text cannot be coming from the window, it is
painted by the view, and the remaining question is precisely why that painting does not cover the
rows an image block occupies.

WHAT IS NOT ESTABLISHED: whether the window in that trace is the terminal window or the alert panel.
The trace does not say, and I did not assume it either way.

## CORRECTION: nothing writes into the strip IN THE WINDOW, which is not the same statement

Two entries above say CIDER_TRACE_PAINT records no write into the grey strip and treat that as
proof that nothing paints it. The measurement is real and the reading was too strong.

The tracer is hooked in three places in O2Context_builtin, for paths, for shadings and for images,
so it does see blits and not only fills; that part is fine. What it reports is writes into ONE
SURFACE, in that surface own coordinates. And iTerm2 does not draw the terminal into the window: the
image trace shows O2BitmapContextCreate 1256x633, the size of the text view, so the terminal renders
into its own bitmap and that bitmap is composited into the window afterwards.

So a rectangle given in WINDOW coordinates cannot select anything the text view does to its own
bitmap. Nothing writing into the strip in the window is exactly what a composited view looks like,
and it says nothing about whether the background was painted inside the bitmap. What the window
traces DO show is the window background at 0.930 and transparent black window paths, which is
consistent with either explanation.

THE NEXT MEASUREMENT, stated so it cannot be got wrong again: trace the surface whose size is
1256x633, with the rectangle in THAT surface coordinates, and look for the background fill on the
rows the image block occupies. That is the one thing still unknown.

## The whole image pipeline, traced on the right surfaces

Pointing the tracer at the surfaces the terminal actually draws into, with the rectangle in their
coordinates, shows the entire path. Distinct surfaces receiving writes in one run:

    on=245x126   the image block bitmap
    on=245x14    one bitmap per CELL ROW
    on=1000x600, on=1256x684, on=585x405, on=292x185   windows

and the writes themselves:

    image 240x120 at 0,0   clip=245x126@0,-6  on=245x126    the picture, and the ONLY write into it
    image 245x126 at 0,0   clip=0x0@0,0       on=245x14     the block, blitted into row one
    image 245x126 at 0,-14                    on=245x14     row two, and so on down the block

So: the picture is drawn once into a 245x126 bitmap and the remainder of that bitmap is NEVER
touched, which is exactly what the disassembly said to expect. The block is then blitted into a
fresh 245x14 bitmap per cell row. NOTHING fills a background into either of them, here or on macOS.

WHICH MOVES THE QUESTION ONE STEP FURTHER, and it is now about compositing rather than painting. The
black on the real system cannot come from the block or from the row bitmaps, because nothing paints
it there, so it must come from what lies UNDER the row when the row is composited into the view. If
that composite blends, a transparent remainder leaves the black underneath alone, which is macOS. If
it copies, the transparent remainder ERASES what was under it, and the window background shows
through, which is what we see.

THE NEXT MEASUREMENT: the blend operation used when a row bitmap is composited into the view. The
image trace prints no blend mode today, so it needs one line more before it can answer.

## The blend modes, measured, and they kill the copy theory

The image trace now prints the blend mode, and one run answers the question the last entry asked:

    blend=17  240x120 -> on=245x126    the picture into the block bitmap, 17 is Copy
    blend=0   245x126 -> on=245x14     the block into each row slice, 0 is source over
    blend=0   245x14  -> on=1000x600   each row slice into the window, source over

SO THE COPY THEORY IS WRONG. I proposed that the row is copied over the view and its transparent
remainder therefore erases the black underneath. The composite into the window is SOURCE OVER, which
leaves whatever is underneath alone. Copy appears exactly once, where iTerm2 draws the picture into
its own block bitmap, which is correct and is not the problem.

WHAT THAT LEAVES. The remainder is transparent, it is composited source over, and what shows through
it is the window background at 0.930. So there is simply nothing black underneath: the terminal
paints its row backgrounds AROUND the image block and the block does not cover its own remainder.
On the real system the same arrangement shows black, so on the real system something IS black under
there, and the only candidate left is the window itself.

WHICH IS CHECKABLE, and the earlier check was too weak. CIDER_TRACE_WINDOWBG recorded five
setBackgroundColor calls, all controlColor, all on ONE window, and I never established whether that
window was the terminal or the alert. If iTerm2 sets the terminal window black through some other
route, a layer colour or setOpaque, we would miss it entirely and this is exactly the difference
that would produce the grey.

NEXT: identify the terminal window in that trace, by number or by size, and find out whether it ever
receives a background colour at all.

## Two measurements that cannot both be right, stated rather than reconciled

Tracing the middle of the black terminal area, window rect 400,300,10,10, the only things that touch
it are:

    path 985x549 at 0,0 clip=985x549@0,0 on=1000x600 n=4 c=0.000,0.000,0.000,0.000  O2ContextFillRects
    path 973x532 at 5,15 clip=985x549@0,0 on=1000x600 n=4 c=0.000,0.000,0.000,0.000  O2ContextFillRects
    path 1000x600 and 1000x550 at 0,0 on=1000x600 n=2 c=0.930,1.000                  O2ContextFillRect

The tracer prints up to four components in order, so n=4 with 0.000 last reads as a TRANSPARENT
black fill, and n=2 with 1.000 last reads as opaque grey. Those two readings are in direct conflict
with the screen:

  - If the 985x549 fill is transparent, nothing in that list paints the terminal black, and yet the
    middle of the terminal IS black.
  - If it is opaque black, it covers the whole view INCLUDING the image block remainder, so the
    strip should be black too, and the strip IS grey.

Either the fourth component is not the alpha for this path, or something outside this rectangle is
involved. I do not know which, and the honest state of this investigation is that the last two
measurements disagree.

WHAT IS STILL SOLID, because it does not depend on this: the defect measurement itself (5 grey
pixels right, 6 below, the picture pixel exact), the disassembly showing iTerm2 never fills the
block bitmap, the pipeline (picture into a 245x126 block, block into one 245x14 bitmap per row),
and the blend modes (Copy once into the block, source over for both composites).

WHAT TO DO NEXT, and it is a smaller step than another theory: make the tracer print the colour
SPACE and the gState alpha alongside the components, so a line like c=0,0,0,0 can be read without
guessing. Every reading above rests on that field and it has now produced a contradiction.

## Half the contradiction resolved: the fill really is transparent, so black is not painted at all

The plan was to make the tracer print the alpha beside the components. Reading O2Color first killed
that idea, which is the useful part:

    O2Float O2ColorGetAlpha(O2ColorRef self) {
        return self->_components[self->_numberOfComponents - 1];
    }

The alpha IS the last component. Printing it would have printed the same number again, so that
change was written, seen to be worthless, and reverted rather than shipped.

WHAT IT SETTLES. The fill that covers the terminal genuinely has alpha 0. It is a TRANSPARENT fill,
by the colour own accounting, so the earlier reading was right and there is no colour bug here. And
that means nothing paints the terminal black at all: the black on screen is what a transparent
region looks like once the window buffer reaches the compositor, because that buffer is presented as
opaque and an alpha of zero is simply not carried through.

WHICH REFRAMES THE WHOLE THREAD, and makes the grey the odd one out rather than the black. The
question is no longer why the strip is not painted black, since nothing is. It is why the strip is
NOT transparent like the rest of the terminal, when the window background under it was painted the
same 0.930 grey everywhere. Something clears the terminal area to transparent and does not clear the
image block remainder.

NEXT: find the clear. It is the fill printed as path 985x549 at 0,0 with c=0,0,0,0 through
O2ContextFillRects, and what matters is its blend mode, which the path trace does not print. The
image trace prints one now and the path trace does not, which is the asymmetry to close.

## The fills are all Copy, which is what makes a transparent fill visible

Counting the Onyx2D enum, Clear is 16 and Copy is 17, and the path trace now prints the mode:

    path blend=17 985x549  at 0,0  on=1000x600 n=4 c=0.000,0.000,0.000,0.000   the terminal area
    path blend=17 1241x633 at 0,0  on=1256x684 n=4 c=0.000,0.000,0.000,0.000
    path blend=17 585x405  at 0,0  on=585x405  n=2 c=0.930,1.000               a window background

EVERY path fill goes through Copy, which is why a transparent fill is not a no-op: copying
transparent black CLEARS the destination. So the terminal is a cleared region presented through an
opaque buffer, which is the black on screen, and this half of the account holds together.

WHAT STILL DOES NOT ADD UP, and it is recorded rather than explained away: that clear covers
985x549 at 0,0, which INCLUDES the image block remainder, so the remainder should be cleared too and
should read black like the rest. It reads grey. Either the clear happens before something that puts
grey back in just that strip, or the rect that reaches the surface is not the rect the trace prints.
Ordering is what would settle it and the trace has no timestamps.

PARKED HERE. The user has redirected the work to the application queue, and this is a cosmetic five
pixel edge on an app whose three criteria are met. The account so far, all measured: the picture is
pixel exact, iTerm2 never fills the block remainder (disassembly and trace agree), the block is
blitted per cell row source over, every fill is Copy, and the terminal black is a cleared region.

## Swift Publisher: the typesetter stub is the blocker, and making it concrete is not enough

WHAT IS BETTER, and it was not the target. A template preview now RENDERS in the gallery, the Book
Shop tile drawing its artwork where every tile used to be an empty dashed placeholder. That comes
from the accumulated fixes, NSTextStorage getting an init and DL_INSERT reading its argument once,
not from anything done in this rung.

THE DOCUMENT WINDOW STILL DOES NOT OPEN, and the blocker is now named. Choosing a template raises,
seven times in a run:

    NSInvalidArgumentException: -layoutGlyphsInLayoutManager:... only defined for abstract class.
    Define -[CCATSTypesetter ...]

which is our NSATSTypesetter stub: the whole implementation lives in a sibling called
NSTypesetter_concrete, so CCATSTypesetter, the application subclass, inherits only the abstract
raise.

MAKING IT CONCRETE REMOVES THAT RAISE, seven to zero, and text layout runs for the first time:
14,381 glyph positions in one run, every one with a valid face, a sane pixel size and a glyph index
inside num_glyphs. And Swift Publisher then dies, 3 runs of 3, with no captures at all.

WHAT THE DEATH IS NOT. The first crashes were a SIGSEGV inside FreeType on the PREVIEW WORKER thread
while the main thread laid text out, which is the shared FT_Face race proved earlier by a contention
counter. So faces were made per thread, and then FreeType libraries per thread as well, since
FT_New_Face allocates through the library and FreeType does not serialise that. NEITHER CHANGED THE
RATE: 3 of 3 before, 3 of 3 after. The FT concurrency is real and is NOT what blocks this.

WHAT IT LOOKS LIKE INSTEAD: SIGILL with rip equal to the faulting address, reached through
dyld_stub_binder from the application, which is the shape of a deliberately trapping stub rather
than corruption. Something the application only calls once text layout actually runs is not
implemented. DYLD_BIND_AT_LAUNCH printed nothing, so naming it needs another route.

REVERTED, and verified back at six captures with no crash. A lock was never an option for the FT
race either: a contended pthread mutex fails in this guest with psynch -111, which is why the fix
attempted was per thread state rather than a mutex.

## Where the three queued applications actually stand

Breadth first, because two of them had never been run this session and the priority is applications
working rather than one application polished.

### iA Writer (#115): blocked on Combine, which is an empty stub

It does not launch. dyld says so precisely:

    dyld: Symbol not found: _$s7Combine10PublishersO3MapVMn
      Referenced from: .../AccountCore.framework
      Expected in: /System/Library/Frameworks/Combine.framework

Our Combine.framework is 8,368 bytes with ZERO exported text symbols: a placeholder, not a partial
implementation. The repo builds it from a hand written section of the frameworks BUCK.

The obvious remedy, building OpenCombine (a complete MIT reimplementation in Swift), is out of reach
today: there is NO swiftc in the toolchain, only a swiftc_shim. So this is an infrastructure gap,
not a bug, and nothing short of a Swift compiler plus a Combine implementation moves it.

### MoneyMoney (#117): launches, then overflows the stack in NSDate

It gets much further: the main nib loads and is decoded (NSUserDefaultsController, NewsCheck,
Locale, Realtime), and then it dies:

    cider CRASHTRACE signal=11 addr=0x7fffff5ffff8 rsp=0x7fffff600000 frames=64

The fault address is EIGHT BYTES BELOW the stack pointer, which is the guard page and therefore a
stack overflow, and sixty of the sixty four frames are the same address in MoneyMoney. The main
thread already gets the 8 MB macOS gives, so this is unbounded recursion and not a small stack.

The disassembly names it. The repeating return address sits immediately after
-[[%rdi super] init] in a MoneyMoney method that also references
initWithTimeIntervalSinceReferenceDate:. So the application has an NSDate subclass whose initialiser
calls [super init]; that reaches -[NSDate(NSDateCreation) init] in our CoreFoundation, which is

    - (id)init { return [self initWithTimeIntervalSinceReferenceDate:CFAbsoluteTimeGetCurrent()]; }

and self is the subclass, so it dispatches straight back into the override. Round and round until
the guard page.

NOT YET ESTABLISHED, and it decides the fix: Apple documents exactly this implementation for the
abstract class, so the same shape ought to recurse on macOS too. Either the application overrides
something we do not expect it to, or macOS NSDate resolves the cluster before dispatching. Read the
subclass out of the binary before changing NSDate, because changing a class cluster initialiser on a
guess is how a whole framework goes wrong quietly.

### Swift Publisher (#116)

Unchanged from the entry above: the typesetter stub is the blocker, making it concrete lets layout
run and the application then dies through a trapping stub reached only during real layout.

## MoneyMoney: the abstract NSDate was driving creation, and a subclass recursed into itself

FIXED, and measured. MoneyMoney has its own NSDate subclass, a class it calls Date, whose
DESIGNATED INITIALISER calls [super init]. Read out of the binary rather than guessed: the method at
imp 0x10047da60 is initWithTimeIntervalSinceReferenceDate:, the repeating return address 0x10047da95
sits immediately after -[[super] init] inside it, and the class record says
superclass _OBJC_CLASS_$_NSDate.

Our abstract NSDate answered that [super init] with

    - (id)init { return [self initWithTimeIntervalSinceReferenceDate:CFAbsoluteTimeGetCurrent()]; }

which dispatches DYNAMICALLY, so it went straight back into the subclass override, round and round
until the guard page: signal 11 with the fault address eight bytes below the stack pointer and sixty
of sixty four frames one address.

THE ABSTRACT CLASS SHOULD NOT DRIVE CREATION AT ALL. NSDate here is a proper class cluster: +alloc
answers __NSPlaceholderDate, which has its OWN -init and turns into a __NSDate, so
[[NSDate alloc] init] never reaches the abstract method. The only caller that can is a subclass
saying [super init], and what that must get is NSObject behaviour. It does now
(vendor/patches/corefoundation/0019).

MEASURED, three runs before and three after: crash every time before, no crash at all after, and the
application now gets much further, all the way to its MainWindowController.

AND THE NEXT BLOCKER IS ALREADY VISIBLE, so this does not make MoneyMoney work. It now loads its
main window FOREVER: 19,930 windowDidLoad and 19,931 opens of MainWindow.nib in one run, with no
exception raised. That is the shape of -[NSWindowController window] finding _window still nil after
the nib has loaded and asking for it again, which means the File Owner window outlet is not being
connected when we decode that nib.

## An operational trap: FORCE on a pin with nested submodule pins

FORCE=1 re-materialising vendor/pins/corefoundation left the build broken:

    File not found: .../corefoundation/submodules/swift-corelibs-foundation/.../CFAttributedString.h

That path is its OWN entry in nix/submodules.json, and re-materialising the parent does not bring
the children back. Materialise the nested pin too, by its full path, or the tree is incomplete in a
way that only shows up at the next build.

## A window controller now reads its nib once, and MoneyMoney still shows nothing

-[NSWindowController window] reloaded the nib every time _window was still nil, and nothing ever set
a flag, so a nib that loads WITHOUT connecting the File Owner window outlet is read again on every
call for ever. MoneyMoney ran 19,931 of those cycles in one run. It reads it once now, measured
twice: 19,931 loadWindow to 1, no crash, and the application stays alive to the timeout instead of
dying.

TWO OBVIOUS IMPLEMENTATIONS ARE WRONG, and both were tried and measured rather than reasoned about.

  AN IVAR CHANGES instanceSize. Adding one BOOL to NSWindowController stopped MoneyMoney reaching
  its window controller AT ALL: zero CIDER_WC lines where there had been thousands, with the gate
  explicitly on. An application subclass compiled against the real AppKit has its own ivars laid out
  after ours, and that is what moving them does. It looks nothing like a layout problem from the
  outside, which is why it is written down here.

  CLEARING OUR OWN _nibPath DOES NOT WORK. A subclass that overrides -windowNibName, which is the
  ordinary way to write one, recomputes the path and loads again regardless: the cycles stayed at
  19,931 while the nib FILE was opened only twice, because the nib itself is cached.

So the flag is an associated object, which changes no layout and does not depend on where the path
came from.

AND MONEYMONEY STILL DOES NOT WORK. The captures are solid black: no window is drawn at all. The
loop is gone and the cause of the loop is not: the nib load produces no window, so the File Owner
window outlet is not being connected when we decode MainWindow.nib. THAT is the next thing, and it
is now reachable because the application no longer thrashes.

## A modern nib bundle has no keyedobjects.nib, and we were reading nothing

MoneyMoney main window nib is a DIRECTORY containing exactly two files:

    keyedobjects-101300.nib
    keyedobjects-110000.nib

and no keyedobjects.nib at all. That is how Interface Builder writes a nib with more than one
deployment target: one file per minimum system version, the digits being MMmmpp. Our loader looked
for keyedobjects.nib, then objects.nib, found neither, and NSNib init answered nil.

NOTHING UPSTREAM SAID A WORD. loadNibFile did not log its failure, the window controller carried on,
found its window still nil and asked for it again, which is the 19,931 cycle loop from the previous
entry. The loop was the symptom; this is the cause.

The loader now picks the newest file the running system is old enough to use, and falls back to the
oldest if the system is older than all of them. Verified in the trace:

    CIDER_NIB versioned keyedobjects-110000.nib for system 140401

and the nib decodes: MoneyMoney went from one window to three.

## And then it asked for NSMenu minimumWidth, which we did not have

With the nib decoding, MoneyMoney set a minimum width on a menu while building its main window:

    -[NSKVONotifying_NSMenu setMinimumWidth:]: unrecognized selector

uncaught, so objc_terminate took the process. That is real API since 10.6 and was missing entirely.
Implemented, stored in an ASSOCIATED OBJECT rather than an ivar for the reason recorded above, and
reported honestly by the getter; nothing makes the menu honour it yet, which is the same shape as
the rest of the menu metrics.

Measured three runs: no crash in any of them, three windows, windowDidLoad exactly once.

## MoneyMoney STILL SHOWS NO WINDOW

The captures are solid black and the application exits cleanly, status 0, right after windowDidLoad
and a pair of TIFF icons. Every fix in this rung moved it further along the same path and none of
them put a window on the screen, which is what the criteria ask for. That is where it stands.

## CORRECTION: crash=0 from our own tracer was not evidence of no crash

The previous entry reported three runs with no crash after implementing NSMenu minimumWidth, and
used that as the measurement. It was wrong, and the way it was wrong is worth more than the claim.

cider-crashtrace IS installed in every one of those runs, the log says so, and it DID report the
earlier failure. It reports nothing now. The kernel disagrees:

    coredumpctl: SIGSEGV present /tmp/cider-appkit-1000/rt/libexec/cider/usr/libexec/cider/mldr
    Command Line: mldr!/tmp/cider-mm-1000/.../MoneyMoney.app/Contents/MacOS/MoneyMoney

There is a core dump for each of those runs. So MoneyMoney still dies of a segmentation fault, and
our in-process tracer simply cannot see this one. What the NSMenu fix genuinely did is remove the
unrecognized selector, which is gone from the logs; it did not stop the application dying.

ASK THE KERNEL, NOT ONLY THE PROCESS. coredumpctl list is the check that would have caught this, and
it costs nothing.

## Where MoneyMoney actually dies: inside the main nib load

Bracketing the two calls at the end of NSApplicationMain says it outright:

    CIDER_APP main nib load enter        prints
    CIDER_APP main nib load leave        NEVER prints
    CIDER_APP calling run                never prints

So [NSBundle loadNibNamed: MainMenu owner: NSApp] does not come back, which is why -run is never
entered and why nothing ever finishes launching. The window controller work, windowDidLoad and the
TIFF icons all happen INSIDE that load, and the process is gone before it returns.

gdb on the core cannot name the site: the frames are guest Mach-O and it symbolises none of them.
That is the next thing to solve, and the honest state is that the application still does not open a
window and now fails in a way our own instrument does not report.

## MoneyMoney makes a real window now, and still dies inside the main nib load

WHAT IS NEW AND GOOD: the window exists. With the versioned nib fix the trace says

    cider-wayland-window role number=1 style=0xf titled=true class=MMWindow
    cider-wayland-window create=ok number=1 size=1124x730 at=2,2 level=0

so MMWindow is built and reaches the compositor. That is the first time MoneyMoney has produced a
window at all.

AND IT STILL DIES INSIDE THE MAIN NIB LOAD, which the bracket proves: main nib load enter prints,
main nib load leave never does.

CORRECTING A GUESS I MADE AN HOUR AGO: the last thing in the log was two TIFF decodes, and I said it
died right after them. Bracketing the decoder shows both of them RETURN:

    CIDER_IMAGESOURCE matched O2ImageSource_TIFF
    CIDER_IMAGESOURCE built   O2ImageSource_TIFF -> 0x78429308fba0
    CIDER_IMAGESOURCE matched O2ImageSource_TIFF
    CIDER_IMAGESOURCE built   O2ImageSource_TIFF -> 0x78429308f740

so TIFF is not the fault site. It was simply the last thing the instruments could see, which is not
the same claim.

## The crash handler was itself crashing

Using the core dump NT_FILE mapping to place the faulting PC, in a run WITH cider-crashtrace
inserted:

    FAULT file: /usr/lib/cider-crashtrace.dylib   offset 0x990

The instrument faults, which is exactly why it printed nothing while the kernel had a core dump for
every run.

IT IS NOT THE ROOT CAUSE THOUGH. Running with DYLD_INSERT_LIBRARIES unset, so crashtrace never
loads, the window is still created and there is still a SIGSEGV core dump. So the application has a
real fault of its own and crashtrace has a second one on top of it, and the second was hiding the
first.

SUPERSEDED, see the section below: the core was never needed. A fatal signal handler compiled into
AppKit named the faulting instruction and then the whole recursion cycle, in one run.


### MoneyMoney (#117): it opens its window

The core never had to be read. The faulting thread was found by asking the process itself, with a
fatal signal handler compiled into AppKit behind CIDER_TRACE_APP, and what it printed ended the
hunt in one run.

The death was a stack overflow, and the cycle repeated every 1,776 bytes:

    -[NSPopUpButton selectItem:] -> -[NSPopUpButtonCell selectItem:]
      -> willChangeValueForKey: ... didChangeValueForKey:
      -> -[NSKeyValueObservance observeValueForKeyPath:ofObject:change:context:]
      -> -[NSPopUpButton selectItem:]   ... 1,180 times

A popup button bound to a model is observed by its own binder, so announcing a new selection makes
the binder write the value back into the view. That round trip is supposed to settle immediately,
because the second call finds the value it is being asked for already in place. It did not:
selectItem: assigned _selectedIndex AFTER the willChange that starts the round trip, so the nested
call read the old index, concluded the selection had changed, and set off again. The guard was
written for a caller that arrives afterwards and there is no such thing here.

The fix is a re-entrancy flag in an associated object: a nested call applies the value and announces
nothing, the outer call owns the notification. Not an ivar, because applications subclass
NSPopUpButtonCell and an ivar added here would move the ones they declare.

Two absent selectors raised uncaught exceptions immediately after, and both are ordinary AppKit
properties: ignoresMultiClick on NSControl and allowsEditingTextAttributes on NSTextField. They
store what they are given and hand it back. Neither behaviour is implemented, and each carries a
comment saying which behaviour is missing, because a property that silently does nothing is exactly
the kind of thing that reads later as a mystery.

WHERE IT STANDS: main nib load leave prints in five runs of five. The window carries the full menu
bar, the toolbar and the application logo, and it relayouts when the compositor resizes it. Of the
three criteria, RENDERS is nearly met and RESIZES is met; INTERACTIVE is untested. One clear defect
is visible: the alert message paints as a solid black rectangle rather than text.

The instrument is worth more than the fix. The injected crashtrace dylib faults inside itself, so
until now a process that died in application code said nothing at all. The handler in NSApplication
prints the faulting program counter through dladdr, and when the stack is the thing that ran out it
scans the stack and names what is lying in it. Three things had to be true before it worked:
backtrace() reports depth 0 from a signal frame and the rbp chain is gone as well, so the frames
have to be found by scanning rather than walking; a write to /dev/null is not a safe way to ask
whether a page is mapped, because the syscall emulation touches the buffer and faults exactly like
the read it was meant to replace, while mincore answers from the mapping tables; and the handler
needs its own sigaltstack, or its locals fault on the very stack whose exhaustion it is reporting.

One operational note, because it made two earlier rate measurements meaningless: stale guest
processes make every run after the first fail. kill-stale-prefix.sh has to run before EVERY run.

### Swift Publisher (#116): the gallery draws, and the blocker was two threads in one FreeType

Two separate faults were in the way, and the first one hid the second.

The application died with SIGILL through dyld_stub_binder from its own code, which reads as a trap
in the application. It is a lazy bind that cannot be resolved: those call sites are bound the first
time a document layout reaches one, and dyld aborts when the symbol is not there. The name is only
in the abort payload, Symbol not found: _CGImageSourceCreateThumbnailAtIndex, which the fatal signal
handler surfaced. ImageIO shipped the thumbnail option keys and not the function; it now decodes and
scales, honouring kCGImageSourceThumbnailMaxPixelSize.

Behind it was the real one. Swift Publisher lays text out on the main thread while an operation
queue builds document previews, and both arrive in the host font libraries. fontconfig and FreeType
are host code reached through elfcalls, allocating on the HOST heap, so two guest threads inside
them at once corrupt it. What that looked like was glibc reporting malloc(): unaligned tcache chunk
detected, and faults inside FreeType reached from -[KTFont_FT positionOfGlyph:precededByGlyph:
isNominal:] on the preview worker.

The guard has to be a compare and swap spin rather than a mutex, because a CONTENDED pthread mutex
still fails in this guest with psynch -111 and aborts; that is why an earlier attempt at locking
this was reverted, taking the correct diagnosis with it. A spin never enters the kernel. It covers
the fontconfig match, both face constructors, and the glyph paths, where one shared face and its
single glyph slot are written by FT_Set_Pixel_Sizes and FT_Load_Glyph. The slot is read out inside
the lock, since releasing before reading it would hand back another threads glyph.

This corrects something written here earlier. The note that per thread FT faces and per thread FT
libraries left the failure rate at 3 of 3, and that the FT race was therefore not the cause, was
measured while the missing ImageIO symbol was aborting every run anyway. That experiment could not
have shown a difference whatever it did, and the conclusion drawn from it was wrong.

WHERE IT STANDS, from the captures rather than from a counter: three runs in four survive the whole
driver and produce captures, against none at all in the twelve runs before. The Template Gallery
draws its menu bar, its category sidebar and all four template previews with real content; a click
selects a tile and it takes the blue focus ring; the window relayouts when the compositor resizes it
to 1000x600.

STILL BROKEN: one run in four dies. Pressing Choose does not open a document: CAMainWindowController
prints loadWindow and loadNibFile enter, and never the leave, which is the shape MoneyMoney had
before its own nib was fixed. One preview tile draws bands of colour noise where a photograph
belongs.

### Swift Publisher: the document window, and why the toolbar says Button

Pressing Choose did nothing, and behind that were three faults, each one only visible once the one
in front of it was gone.

The first was `-[NSView adjustSubviews]`, sent by
`-[CCCanvasesPreviewAndDocumentSplitViewController setVisibleCanvasesPreview:]` to a view that is a
plain NSView here. It escaped the nib load and took the whole document window with it. NSView
answers it now by laying its subviews out again at the size it already has, which is the only thing
the name can honestly mean for a view that is not a split view.

The second killed the process inside a KVO notification, in `-[_NSKVOBinder
writeDestinationToSource]`, messaging freed memory. Binders are kept in a STATIC dictionary keyed by
a NON RETAINED pointer, so nothing in it is reachable from the object it describes and nothing
removes it when that object dies. NSView and NSControl call `_unbindAllBindings` from their dealloc.
NSMenuItem does not, and Swift Publisher binds menu items. The log had been saying so for a while:
an instance of NSKVONotifying_NSMenuItem was deallocated while key value observers were still
registered with it. An associated object now reaps the entry when its owner is destroyed, whatever
the class, and tells each binder to FORGET its source rather than to unbind, because by that point
the source must not be messaged at all.

Worth recording as a failed attempt before that: a guard using `malloc_zone_from_ptr` to ask whether
the source was still alive. It is not a liveness test, because a freed block still belongs to its
zone, so it never fired; and returning an empty array from `peerBinders` made the caller read an
uninitialised stack array, which produced a NEW crash that looked like the old one.

The third was a jump to address zero while drawing toolbar text.
`O2ContextSetupPaintAndBlendMode` clears `_blend_argb8u_PRE` and fills it in for six blend modes
only. The general rasteriser knows this and tests the pointer, falling back to the float blend; the
glyph run called it without looking. Guarded, falling back to the normal 8 bit blend, which means
text under an unsupported blend mode composites normally instead. That is an approximation, and a
glyph run that draws with the wrong blend beats one that ends the process.

WHERE IT STANDS: three runs of three now survive the whole driver with zero crashes and six captures
each, against one crash and three captures in every run before. The window is titled Untitled -
Swift Publisher 5 and carries the menu bar, a toolbar whose groups read View, Editing Tools, Zoom,
Preview Mode, Insert, Share, Print, Text Styles, Fonts, Media Tracks and Inspector, a sidebar and an
inspector panel. It relayouts on resize, collapsing the toolbar into an overflow chevron. The mouse
works, since every step of the path to that window was a click.

WHY THE TOOLBAR READS BUTTON, exactly rather than approximately. `+[NSImage imageNamed:]` now
reports three outcomes rather than two, and over one run: 226 found, 143 lookups with no file at
all, and one with a file we cannot decode, AppIcon.icns. The 143 are 29 distinct names, 27 of them
the application's own, and they are inside Contents/Resources/Assets.car; strings on that file lists
InspectorCornerRadius.png, its @2x and Drk variants, the ToolbarButton set and tab_background. We
have no reader for a compiled asset catalog, an NSButton with no image draws its title, and the
title is the Interface Builder default, the literal word Button. This is not a small fix: renditions
in a modern car file are not stored as PNG files, so it needs a BOM reader and a rendition decoder.
It belongs in its own task.

The canvas in the middle of the document window is still blank.

### iA Writer (#115): still blocked on Combine, and now confirmed unfixable without a Swift compiler

Re-checked 2026-08-18, because a run of font, binding and KVO fixes had landed since it was last
looked at and any of them might have moved it. None did. It still aborts before any window:

    abort_with_payload: reason: Symbol not found: _$s7Combine10PublishersO3MapVMn
      Referenced from: .../iA Writer.app/Contents/Frameworks/AccountCore.framework/.../AccountCore
      Expected in: /System/Library/Frameworks/Combine.framework/Versions/A/Combine

That mangled name is Combine.Publishers.Map's nominal type descriptor. Our Combine is an empty stub,
and this is the part that matters: there is no swiftc anywhere in the toolchain, and none in the nix
expressions either. A nominal type descriptor is Swift metadata, not a C entry point, so it cannot be
stubbed in Objective C the way a missing AppKit selector can. Filling it in means building a real
Combine, which means a Swift compiler first.

So iA Writer is BLOCKED in the strict sense used here: it has never worked once, and the missing
piece is a whole toolchain rather than plumbing. It should not be picked up again until a Swift
compiler exists in the build.

### Swift Publisher: the canvas draws, and a lock that could not be taken twice

The canvas was blank because nothing ever gave it a size. CIDER_TRACE_FRAMES, which watches one
class by substring and prints every setFrame and every birth with its caller, settled it in one run:
CCDocScrollView is BORN 0x0 from -[NSScrollView initWithFrame:] and then receives no setFrame at all
for the rest of the process. Not from the application, and not from autoresizing, which never
reaches it because it is added after its container already has a size. The layout call the
application makes is adjustSubviews, and ours did nothing.

-[NSView adjustSubviews] now gives a subview with NO SIZE AT ALL the room left over after the
subviews that do have one. The rule is narrow on purpose. A pane that has a width and no height was
collapsed deliberately, which is exactly what a hidden canvases preview looks like, and stretching
it would undo the thing the caller just asked for. The first attempt stretched anything zero in
either dimension, and the capture showed the mistake immediately: the page got half the height and
the hidden preview took the other half.

What the window shows now is a white page with a working ruler, reading 1 through 8 inches, where
there was a uniform grey void. Three runs of three, no crashes, the canvas sized 618x694 every time,
and it relayouts when the compositor resizes the window.

**And a regression of mine, found only by re-running the other application.** The host font spinlock
introduced for Swift Publisher was not recursive. The glyph run holds it while code beneath it can
ask for a font again, because a fallback for a missing glyph goes through +filenameForPattern:,
which takes the same lock. A plain spin then waits on a lock its own thread is already holding,
forever, and says nothing. MoneyMoney printed main nib load enter and stopped there in two runs of
two, having opened its window in five of five the day before. The lock now records its owner and
counts re-entry, and MoneyMoney is back to four of four.

The lesson is worth more than the fix: after touching anything shared, re-run the other applications.
A silent hang somewhere else is what a non-recursive lock looks like from outside, and nothing in
the application it was written for ever showed it.

### Swift Publisher: the canvas draws nothing because the application draws nothing

The canvas has a size now and is asked to draw, and it still comes out empty. This rung eliminated
everything on our side of that, by measurement rather than argument.

The application's own -[CCDocView drawRect:] IS called, ten times in a run. Bracketing those calls
and running the paint trace at the same time shows ZERO paints between the enter and the leave. So
its drawing code runs and issues no drawing whatever. That rules out a clipped page, a page drawn
off to one side, and a page drawn in the wrong colour, all at once: there is no page.

The geometry is fine: CCDocScrollView 618x694, NSClipView 587x678 at 16,16, CCDocView 587x693, both
scrollers where they belong. The document bytes are delivered in full, 420,727, which is the whole
of doc.thread. There are no exceptions in the run and, since NSObjectController addObject: and
NSScanner scanUnsignedLongLong: went in, no unrecognized selectors either. CCDocView is not layer
backed, so the failing GL context has nothing to do with it.

And the parse is not ours. A Swift Publisher document is an XML property list, which suggested our
plist reader, so the trace went on _CFPropertyListCreateWithData, the one function every public
entry point funnels through. No property list read of 420,727 bytes happens anywhere in the run.
NSXMLParser -parse is never called either, and the application links no libxml or expat from us. It
parses that XML in its own statically linked code.

What is left is inside the application: it reads its document and builds nothing from it. Finding out
why means disassembling its parser, which is more than a rung. Its Undefined document type warnings
are its own bookkeeping as well, since -[NSDocument fileType] and setFileType: are never called at
all, so CADocument overrides both.

The diagnostics used to establish this in corefoundation and foundation were reverted afterwards: a
materialised pin needs a patch file per edit, and these had already answered their question.

### MoneyMoney: resize and menus verified

Two of the three criteria had never actually been measured for this application, because the driver
opened by clicking the button on the small dialog and that button ENDS THE PROCESS: every run
stopped at the first capture. Resizing needs no click, so the driver now resizes first and clicks
afterwards.

With that order the window relayouts in both directions, 1256x684 to 1000x600 to 1400x900. The menu
bar spans the new width, the toolbar items reposition, the search field moves to the far right and
the content re-centres. Three runs of three produced the full set of captures.

Clicking the menu bar opens a menu that draws correctly and dismisses cleanly. The application menu
shows About, Check for Updates, Preferences, License Key, Privacy Policy, License Agreement,
Imprint, Services with a submenu arrow, Lock MoneyMoney, Hide, Hide Others, Show All and Quit, with
the command glyphs for Hide, Hide Others and Quit and the right entries greyed out. Another run
opened the File menu instead, with Refresh All Accounts, Refresh Scheduled Payments, Cancel Refresh,
Mark All Transactions as Checked, Mark All Statements as Read and Page Setup, every one disabled,
which is what a locked application should show.

One caution worth writing down. Comparing a crop mean between two runs reported them identical while
those runs had in fact opened different menus. A summary statistic over a region can agree while the
content differs completely, which is the whole reason the rule is to look at the capture.

What is still wrong here is unchanged: the small dialog paints a black band where its message
belongs, and the application sits at its lock screen, which no password will ever be typed into.

### MoneyMoney: the black band was two bugs, and the dialog now reads

The band in the MoneyMoney dialog is gone, and what it was hiding is the application saying its own
file seems to be damaged, which is its integrity check failing under Cider. Two separate faults had
to be fixed for that sentence to appear.

The first is that -[NSAttributedString boundingRectWithSize:options:] answered NSZeroRect for every
string. An application that sizes a label from its text gave that label height zero, so it drew
nothing while the box behind it still painted. The view tree named the situation exactly: MMBox
370x69 with MMLabel 327x0 inside it, and the label already held the text. -size measured through
NSStringDrawer all along, so the only missing piece was the constraining size, which is the
difference between one long line and a wrapped paragraph. The options are still not honoured.

The second is subtler. -[NSColor colorWithAlphaComponent:] on the abstract class answers self for
alpha 1 and NIL for anything less, and NSColor_catalog never overrode it. So a system colour with an
alpha applied came back nil, a caller sending set to nil set nothing at all, and the box drew with
whatever colour the context already held, which was black. It converts to calibrated RGB first now.
The same class also gained getRed, getWhite, getHue and getCyan, which had been left to the abstract
superclass where they raise; MoneyMoney does not take that path, measured with a counter that never
fired, so that part is a real gap closed rather than a fix for this bug.

The method that found it is worth keeping. The fill was traced to one address inside the application
binary, and the x86_64 slice was disassembled there by hand: FAT slice offset 0x4000, __TEXT vmaddr
0x100000000, so the file offset is the virtual address minus 0x100000000 plus 0x4000. objdump -D -b
binary -m i386:x86-64 --adjust-vma on the extracted bytes works, where llvm-objdump ignores
--start-address on Mach-O. Selector references resolve by reading the pointer stored at the selref
address and then the C string it points at, which turned the calls into textBackgroundColor,
disabledControlTextColor, windowBackgroundColor, selectedTextBackgroundColor and set.

One thing recorded rather than claimed: at 1400x900 the lock screen behind the dialog draws its
wordmark as very large glyphs. It does not appear at 1000x600 and it sits behind the dialog.

### What is actually inside an Assets.car, and what reading one would cost

Task 118 says the Swift Publisher toolbar reads Button because its icons live in a compiled asset
catalog we cannot read. This is what that file turns out to be, established by parsing it rather
than by reading about it.

The container is a BOM store, and it parses cleanly with about forty lines of code: an eight byte
BOMStore magic, a block table, and a variable table naming CARHEADER, RENDITIONS, FACETKEYS,
APPEARANCEKEYS, KEYFORMAT, EXTENDED_METADATA and BITMAPKEYS. CARHEADER carries the tag RATC, CoreUI
version 805, storage version 17 and a rendition count, 205 for this application. KEYFORMAT is tmfk
with twenty attribute identifiers. RENDITIONS is a BOM tree whose leaf holds 205 key and value block
pairs, and each value begins with ISTC and a header giving width, height, scale and pixel format.

Two pixel formats appear here, BGRA for 83 renditions and GA8 for 122. The payloads are the problem.
Scanning every rendition for compression markers finds bvx2, which is LZFSE, in 21 of them, and the
remaining 184 are 334 bytes each REGARDLESS of their stated pixel size, 18x18 and 36x36 and 15x15
all alike, so they are not raw bitmaps and not the icons either; the real images are the compressed
ones.

So the blocker is precisely an LZFSE decoder, and we have nothing to decode with:
src/darwin/libcompression/src/compression.c is forty six lines in which every function returns zero,
while the header does declare COMPRESSION_LZFSE. An application calling compression_decode_buffer
gets a silent zero today.

That makes task 118 a sequence rather than a fix: get an LZFSE decoder into the guest, implement
compression_decode_buffer on top of it, then write the CAR reader and hang it off
+[NSImage imageNamed:] where the loose-file search currently gives up. The parsing half is the easy
half and is now written down.

### The rendition body, decoded and looked at

The LZFSE decoder from the previous step is enough to get a picture out of a compiled asset catalog,
and doing that by hand settled the last unknown: what the bytes after the header actually are.

A rendition body is NOT one compressed stream. It is several, laid end to end, each a complete LZFSE
stream ending in the bvx$ marker, which is why a single lzfse_decode_buffer call over the whole body
returns only the first chunk and looks wrong. The Swift Publisher rendition that was used as the
example has four: three of 36,096 bytes decoded and one of 768.

Concatenated they come to 109,056 bytes for an image the header calls 180 by 142 in BGRA, where a
raw buffer would be 102,240. The difference is the ROW STRIDE: 109,056 is exactly 768 times 142, and
768 is 180 times 4 rounded up from 720. Each chunk holds whole rows, 47 of them (36,096 divided by
768), and 47 plus 47 plus 47 plus 1 is the 142 rows of the image. The MLEC header says as much
before any of this: the field that reads 0x2f is 47, the rows per chunk, and the one after it is the
first chunk compressed length.

Assembling those rows, taking the first 720 bytes of each and swapping BGRA to RGBA, produces a real
picture: a grid of grey and white rounded rectangles with green icons down the side, which is Swift
Publisher artwork. That is the proof that the whole chain is understood, and it was looked at rather
than checksummed.

FACETKEYS parses the same way and is where the names live: 47 named facets in this catalog,
including InspectorCornerRadius, ToolbarButtonSingle and ToolbarButtonCentral, three of the names
that +[NSImage imageNamed:] reports as having no file at all. So the names an application asks for
really are in there and really do map to renditions.

What is left for the reader is therefore mechanical rather than exploratory: walk FACETKEYS for the
name, follow it into RENDITIONS, read the ISTC header for width, height and pixel format, decode the
chunk streams with compression_decode_buffer, and lay the rows out at the stride. Two formats appear
here, BGRA and GA8, and only 21 of the 205 renditions carry a compressed payload at all; the other
184 are 334 bytes each whatever their stated size and are not bitmaps.

### The small renditions are LINKS into packed sheets, and the chain is now proven

A correction to the previous entry, which said the 184 small renditions were 334 bytes each and
therefore not the icons. They are not bitmaps, that part was right, but they are not junk either:
each one is a LINK, and the icons are inside them by reference.

Taking ToolbarButtonSingle, one of the names +[NSImage imageNamed:] cannot find, the chain runs:

  FACETKEYS holds the name and a PARTIAL key, here attribute 1 = 85, attribute 2 = 181 and
    attribute 17 = 19427, where 17 is an identifier derived from the name.
  RENDITIONS holds full keys, twenty uint16 values in the order KEYFORMAT lists, and four of them
    match that partial key: 1x and 2x, in BGRA and in GA8.
  The matching rendition is 330 bytes and its name field reads ToolbarButtonSingle-1.png. Inside it
    is a chunk tagged KLNI, which is INLK backwards, holding x 98, y 58, width 42, height 26 and a
    key for ANOTHER rendition: attribute 1 = 9, attribute 2 = 181, attribute 12 = 1.
  That other rendition is one of the twenty one with an LZFSE payload, 180 by 142 BGRA, whose
    metadata calls itself PackedAsset. It is a SHEET with many small pieces of artwork on it.
  Decoding its chunk streams and laying the rows out at the padded stride gives the sheet, and
    cropping 42 by 26 at 98,58 gives a rounded rectangle with a light fill and a grey border, which
    is exactly what a toolbar button bezel should look like.

One trap worth writing down: the link key mentions attribute 16, and attribute 16 is NOT in this
catalogs KEYFORMAT at all. A matcher that insists every attribute in the link be present in the
rendition key finds nothing. Attributes absent from KEYFORMAT have to be treated as satisfied.

So nothing about the format is unknown any more. The reader is mechanical: name, partial key, full
key, link, sheet, chunks, rows, crop.

### The catalog reader, in the application at last

The reader is in NSImage.m and runs from +[NSImage imageNamed:] when the loose-file search fails.
Both pixel formats these catalogs use are handled now: BGRA, and GA8, which is eight bits of grey
and eight of alpha and is how a template icon is stored. Accepting only BGRA left half the catalog
invisible.

Two things cost most of the time, and both were mine rather than the format's.
compression_decode_buffer takes SIX arguments and the function pointer declared five, so the
algorithm argument was whatever happened to be in the register, never matched COMPRESSION_LZFSE, and
every stream returned zero, which is indistinguishable from a corrupt payload. And a trace that
inferred a catalog hit from the absence of a loose file counted in-memory CACHE hits as catalog hits
and cheerfully reported 93 successes when the real number was zero. Record what happened; do not
infer it from what did not.

The third obstacle was the harness. The application had never been seen using the reader because the
driver rarely reached the document window: the template gallery scrolls between runs, so the click
that should pick a tile lands elsewhere and Choose stays disabled. Passing a template document as an
ARGUMENT opens it directly, skips the gallery, and builds the toolbar every time.

What that shows on screen: the toolbar buttons now have their BEZELS, each label sitting in a
rounded frame, where before they were bare words on a grey strip. Nineteen lookups per run come from
the catalog, the same nineteen in two runs of two, with no crashes, and the twelve distinct names
are exactly the ones that used to fail, the ToolbarButton set and the six Inspector ones.

What is still wrong: the buttons continue to read Button. That word is the button TITLE, so the
glyphs that belong on top of these bezels are not coming through imageNamed at all and have another
source. Four names the application asks for, verticalSplitHandler, tab_background, tab_foreground
and splash, are not facets in this catalog, so there is nothing here to read for them.

### The toolbar icons were never a catalog problem

The bezels behind the Swift Publisher toolbar buttons came out of the asset catalog, and it was
tempting to assume the glyphs on top of them would follow. They did not, and they never would have:
those glyphs are LOOSE TIFF FILES beside the application, ToolbarZoomIn.tiff and ToolbarPrint.tiff
and the rest, and they were being found all along.

What stopped them was the image POSITION. A button cell keeps an image and a position, the position
starts at NSNoImage, and AppKit promotes it to NSImageOnly when an image is set on a cell that had
none. Ours did not, so a cell could hold a perfectly good picture and still draw only its title,
which for a cell built in code is the word Interface Builder leaves behind: Button.

The trace is what settled it, and only after being taught to print one more field. It already said
img=image with a real name; adding imgpos to it turned a mystery into a one line fix, because
imgpos=0 is NSNoImage and means do not draw the thing you are holding.

The result is the whole toolbar: layout and dropdown under View, the dark rectangle and green T and
green square under Editing Tools, both magnifiers under Zoom, the blue eye under Preview Mode, line
and green upload and green printer for Insert and Share and Print, blue AA under Text Styles, a
camera under Media Tracks, and the sidebar and inspector glyphs beside them. Two runs of two, no
crashes.

Switch and radio cells set their position before handing over an image, so they keep NSImageLeft and
are untouched, and MoneyMoney was re-run afterwards and is unchanged.

### The iTerm2 session: a daemon that quit on purpose, and a launch request too big to decode

The terminal had everything except a shell. The window drew, the menus opened, keys arrived, and the
session never appeared. Six files called iterm2-daemon-1.socket.lock through -6 were left behind by
every run, which reads like six failed attempts, and it is: the application starts a daemon, the
daemon goes away, it starts the next one.

The reason nothing explained itself is that the daemon does not write to stderr. iTermServer calls
openlog and routes every one of its messages through CDLogImpl, which calls vsyslog. Under Cider
that datagram goes nowhere and the send fails with EBADF, but strace prints the TEXT of a buffer it
could not deliver, so

    strace -f -tt -e trace=sendto,sendmsg

recovers the whole log, with the source file and line number of each line, from a process that
appears completely silent. That single change turned this from guesswork into reading.

What the log says, without launchd:

    MultiServer.c:952 Initialize: Server starting Initialize()
    MultiServer.c:912 InitializeSignals: signals initialized
    MultiServer.c:686 SelectLoop: Begin SelectLoop.
    MultiServer.c:939 CheckIfBootstrapPortIsDead: Unable to get the type of the bootstrap port
    MultiServer.c:922 QuitCleanly: QuitCleanly
    MultiServer.c:998 CleanUp: Unlink .../iterm2-daemon-1.socket

CheckIfBootstrapPortIsDead runs after every select. It asks task_get_special_port for
TASK_BOOTSTRAP_PORT and then asks mach_port_type what that port is, and it treats a dead bootstrap
port as proof that the user session is gone, so it quits. With DARLING_NO_LAUNCHD=1 there is no
launchd, itk_bootstrap is IP_NULL for the root task and for everything that inherits from it, the
port comes back as MACH_PORT_NULL, and mach_port_type answers KERN_INVALID_NAME. The daemon then
removes its own socket and exits. Line 939 rather than 934 is what identifies the second call as the
one that failed, and the line numbers come straight out of the binary: the two error branches load
0x3a6 and 0x3ab into ecx before calling CDLogImpl.

Run the same application through launchd and the same line reads

    MultiServer.c:946 CheckIfBootstrapPortIsDead: Bootstrap port isn't dead yet.

and there is ONE daemon instead of six. So the first cause is simply that iTerm2 needs a session:
launchd is not optional for it, because a process with no bootstrap port looks to iTerm2 like a
logged out user.

The second cause was waiting behind the first. With the daemon alive, the handshake completes, the
daemon writes its 8 and 64 byte replies, reports zero children, and then the connection drops and it
exits because no children remain. The application side says why, and it is an assertion in iTerm2
itself:

    Assertion failed: (status == 0: On decode: status is 1 for encoded length 67951),
    function -[iTermFileDescriptorMultiClient copyLaunchRequest:]

copyLaunchRequest encodes the launch request and immediately decodes it to take a copy. The request
carries the executable path, the argv, the working directory, the tty state and the ENVIRONMENT, and
the message buffer is fixed. 67951 bytes is what our environment costs: the host environment
measures 67560 bytes, so the request is the environment and almost nothing else. It is a nix
devshell, and four variables are nearly all of it, NIX_CFLAGS_COMPILE at 21272 bytes, DIRENV_DIFF at
10836, NIX_LDFLAGS at 6016 and PATH at 4871.

Unset every variable over 400 bytes apart from PATH and LD_LIBRARY_PATH and the assertion is gone.
This is our environment rather than a defect in Cider, and it is worth knowing anyway: an
application can fail to start a child for no reason other than the size of the environment it
inherited, and the failure surfaces as a decode error rather than as anything about size.

With launchd and a trimmed environment the session comes up and works. Two commands typed into it
run and print their output, and its own ps shows the real macOS session chain, login -fp root, then
sh -sh, then the ps itself.

A correction to what I wrote last time. I recorded that the helper calls exit_group(1). The binary
contains exactly one _exit(1), and it is in iTermExec, on the forked child path after execvp fails,
where it exits silently when there is no error descriptor to write to. The daemon's own exit is
_exit(0) from QuitCleanly. Reading an exit status as a failure was wrong; the daemon was quitting
deliberately, and the status said so.

Three things about the harness came out of the same runs. A headless wlroots has no input devices,
so its seat advertises no keyboard and typing goes nowhere: the nested wayland backend is what makes
keystrokes arrive. wtype must be given the text and the Return in ONE invocation, because it creates
a virtual keyboard for the duration of a run and destroys it afterwards. And
DYLD_PRINT_INITIALIZERS was being passed through as empty but set, which reads as ON, which is why
the terminal filled with dyld initializer lines.

Three runs of three, each with different process ids, so they are genuinely three runs and not one
picture looked at three times.

What is still wrong inside the session, both small and both new: tty prints "not a tty" and ps shows
?? in the TTY column for every process, where macOS names the pty, and ps prints "Unimplemented
syscall (539)" three times. 539 is task_read_for_pid, from the xnu syscalls.master already in the
tree, which is also why every TIME column reads 0:00.00.

### Swift Publisher: the canvas draws nothing because the application asks for nothing

The document window comes up with its rulers, its panels and its toolbar, and the page area in the
middle stays empty. The last note here left it at "the application draws nothing" with the parse
unaccounted for, and guessed that chasing it meant disassembling the application's own parser.
Measuring first was cheaper.

Three questions were answered, each with an instrument that was made to speak before its silence
was believed.

Does the application get its document? Yes, all of it. A trace on NSFileWrapper says the
application asks a directory wrapper for its children twice, then asks for doc.thread and receives
420,727 bytes, which is the whole file.

Does it parse that through us? No, and now this is measured rather than inferred. doc.thread is an
XML property list. The application binds NSXMLDocument and NSPropertyListSerialization from
Foundation and CFXMLTreeCreateFromData from CoreFoundation, so every candidate was instrumented at
once: NSXMLDocument initWithData, NSXMLParser parse, CFXMLTreeCreateFromData, and
_CFPropertyListCreateWithData, which every public property list read funnels through, including the
stream one. A run does 27 property list reads, the largest 273,567 bytes, and NONE of them is the
document. The XML entry points are never called at all. Nor is a scanner: the application's own
parser uses NSScanner, which is why scanUnsignedLongLong had to be added, but no scanner is ever
created over a string longer than ten thousand characters, so the document is not scanned either.

The reason that silence can be trusted this time is a constructor in each library that prints once
when the gate is on. Both announced. A gate that never fired and a library that was never rebuilt
look exactly alike without it, and that has cost a rung here before.

Does its view draw anything? No, and this is the useful one. Onyx2D now counts drawing operations
in its five primitives, fills, paths, glyphs, images and shadings, and the drawRect bracket in
NSView reports the count for the watched class. -[CCDocView drawRect:] is called ten times in a run
and every one of them reports ops=0. Not one fill, not one path, not one glyph. The coverage is
not a guess either: the application imports CGContextFillPath, CGContextStrokePath,
CGContextStrokeRect, CGContextDrawImage, CGContextDrawShading and the text calls, and no CGLayer or
CGPDF entry point at all, so there is no drawing route that the counter would miss.

So the application reads its document, tells NSDocument that reading succeeded, and then has
nothing to draw. What is left is between the bytes and the model, inside its own code, and the next
instrument for it is message send logging around the document open rather than more elimination
from our side.

The counter stays. It costs an increment on five paths, prints only when CIDER_TRACE_FRAMES names a
class, and it answers a question that read-only tracing could not: zero drawing operations inside a
drawRect that is definitely running means an empty model, never a clip or a colour.

### CORRECTION: Swift Publisher does parse its document through us, and the parse succeeds

The previous section says the application parses doc.thread without us, on the strength of four
instruments that never fired. Three of those four were right and the conclusion drawn from them was
wrong, because the fourth was watching the wrong door.

The application does this, and the disassembly of -[CCDocument readFromData:ofType:error:] says it
in four instructions: it makes an NSString from the data with encoding 4, which is UTF-8, and sends
it -propertyList. Our -[NSString propertyList] calls _CFPropertyListCreateFromXMLString, which goes
to _CFPropertyListCreateFromUTF8Data. That is NOT _CFPropertyListCreateWithData, which is where the
trace was, and which every data entry point does funnel through. A string entry point does not.

Traced at the shared funnel instead, the answer arrives in one line:

    CIDER_PLIST fromXMLString chars=420727 utf8=420727 result=plist

The whole document parses, through our property list reader, successfully. So the earlier statement
that no parse of ours is involved was doubly wrong: it is ours, and it works. The lesson is narrow
and worth keeping: a funnel is only a funnel for the callers that reach it, and "every public entry
point goes through here" has to be checked against the entry point the application actually calls,
which the disassembly names for free.

### The application had been telling us what was wrong for weeks

Swift Publisher logs its own complaints, in this shape:

    *** Warning in class:'%@' selector:'%@' file:'%@:%ld' - '%@'

They go through NSLog, so they are already in every run log we have collected, 116 of them, and
nobody had read them. Two distinct complaints, and one of them was ours.

A hundred and eight of the 116 were this:

    class:'MyPicture' selector:'updateOriginalImageSizeAndReturnFullImage:'
      - 'key 'PixelWidth' for '.../BundleClipArtImages/AVQ_Royal Family 096.jpg' returns nil'

macOS always reports PixelWidth and PixelHeight from CGImageSourceCopyPropertiesAtIndex, taken from
the image and not from any metadata block. Ours reported the EXIF tags and nothing else for a JPEG,
and an empty dictionary for everything else, so a plain JPEG with no EXIF answered nothing at all. A
layout application asks for the pixel size of every picture before it can place one.

Both are fixed. The base image source now decodes and measures, which is correct for every format,
and JPEG overrides it by reading the frame header, which is where the size actually lives: markers
from the start of the file, the SOFn ones carrying precision, height and width, with 0xC4, 0xC8 and
0xCC excluded because they sit in the same numeric range and are not frame headers. After that the
warning count for PixelWidth goes from 108 to zero in a run.

### A nib loaded window did not know its own controller

The remaining four warnings say 'Undefined document type', and chasing them led somewhere better.
-[CCDocView drawRect:] opens by asking [[self window] windowController] for the document, and
returns immediately, drawing nothing, when what comes back is nil. That is exactly the ops=0 the
drawing counter measured.

-[NSWindowController loadWindow] loads the nib, and the nib connects its window outlet straight into
the _window ivar. -setWindow: therefore never runs, and it is -setWindow: and -initWithWindow: that
call -[NSWindow setWindowController:]. So a window loaded the ordinary way, by a controller from a
nib, answered nil to -windowController for its whole life. On macOS it always knows.

One line in loadWindow fixes it, and the run says so:

    CIDER_WC CAMainWindowController adopted window=0x7eb5f6ec50f0 controller=0x7eb7059ef390

The canvas is still blank, and that is worth saying plainly: the fix is real and macOS faithful, and
it was not sufficient. drawRect has two nil guards, not one, and the second is [windowController
ftView], which the application sets from -[CCDocument makeWindowControllers] through
performSelector. Which of the two guards still fires is the next measurement, and it is a question
about one selector rather than about the document.

The disassembly work is reusable: scratchpad/objc-dis.py disassembles a range of a thin x86_64
Mach-O and resolves selrefs, classrefs and cfstrings, which llvm-objdump will not do for a Mach-O
with a start address. Extracting the thin slice from the FAT binary first is what makes the range
options work at all.

### Which of the two guards fires: the document has no design element

-[CCDocView drawRect:] returns early on either of two nil values, so knowing which one it is halves
the remaining search. The window controller is built by the applications own makeWindowControllers,
which our NSDocument calls, so our NSDocument can ask the controller for those values the moment it
receives it, and -[NSWindowController showWindow:] can ask again later in case something fills them
in during the nib load.

Both samples agree:

    CIDER_DOC   controller ftView -> 0x7d1b1b40be20
    CIDER_DOC   controller currentDesignElement -> 0x0
    CIDER_DOC showWindow ftView -> 0x7d1b1b40be20
    CIDER_DOC showWindow currentDesignElement -> 0x0

So ftView is fine: the C++ core view is constructed and set. What is missing is the current design
element, which is the page. The document parsed its property list, said the read succeeded, and
ended up with nothing in its design element list.

That puts the next question inside -[CCDocument serialize:error:], which walks
countOfDesignElements, builds each element with initWithCCDocument:withDocumentType:andOptions: and
inserts it. And that initialiser is one of the four places that logs 'Undefined document type', so
the type warning is not the cosmetic thing it looked like: a design element built with no document
type is the most likely reason the list stays empty. That is the thread to pull next.

One trap from writing the probe, and it cost a run: -ftDocument and -ftView answer C++ objects, not
Objective-C ones. Calling object_getClassName on one walks into objc_class::demangledName and
segfaults, so the probe crashed the application it was there to measure. Print the pointer; nil or
not nil was the whole question.

### The page was never selected: avoidsEmptySelection was a rule, not an invariant

The blank canvas has a cause, and it is ours. -[CCDocView drawRect:] reads the current page as

    [[[[self window] windowController] currentDesignElement] ftDocument]

and -[CCMainWindowController currentDesignElement] is

    [[[self designElementsArrayController] selectedObjects] lastObject]

so the whole document view depends on one NSArrayController having a selection. Measured, a hundred
and fifteen times in one run:

    CIDER_AC selectedObjects self=0x... arranged=1 selected=0 content=__NSCFArray avoidsEmpty=1

The controller has the page. It is bound to CADocument.designElements, the binding is established,
the destination holds one object at bind time, and the write goes through and reads back. Nothing is
missing except a selection, and avoidsEmptySelection is on, which on macOS means a controller with
content always has one.

Ours enforced it only INSIDE -setSelectionIndexes:. A controller whose content arrives without
anyone touching the selection afterwards therefore keeps an empty selection over a non empty
arrangement, which macOS never does; with preservesSelection off, -rearrangeObjects did not call the
setter at all. The fix restores the invariant where the arrangement changes.

Everything before that was elimination, and it is worth recording what it cost: the binding
machinery was suspected first (it works), then the binder class registry (it always answers), then
whether the write raised (it does not, and the read back proves the content arrives), then the
decoded controller flags (that application never decodes a controller from a nib at all). The one
measurement that mattered was printing arranged, selected and the flags together.

### Two failures that only appeared once the selection existed

A fix that makes an application do work it has never done before will find whatever is broken in
that work, and this one found two things immediately.

The process began aborting on every run, 2 of 2, where nine runs before the change had not aborted
once. The backtrace names it: wayland_appkit_lib::input::on_keyboard_enter. An ObjC exception raised
under that callback is not a Rust panic, catch_unwind cannot see it, and Rust aborts the process
rather than let a foreign exception cross an extern C frame. There was already a catch around the
one call inside that function where iTerm2 had raised; Swift Publisher raised from a different call
in the same function. The catch is now at the BOUNDARY, around the whole of
cider_wayland_set_keyboard_focus and cider_wayland_watch_focus_notifications, which is the level the
constraint actually applies at.

With the abort gone the exception names itself:

    cider-wayland: keyboard focus raised NSInvalidArgumentException:
      CCMeasurementUnitsFormatter stringForObjectValue: requires a subclass implementation

The application implements that method, and calls super from it through objc_msgSendSuper2, which
the disassembly shows plainly. Our NSFormatter raised on the abstract primitive. An application
that ships on macOS is not crashing while formatting a ruler, so the base class answers nil now
(foundation patch 0022) and the caller decides.

### Where Swift Publisher stands after all that

The document window builds its inspector from the selection now: Simulate paper color with its
swatch, Document Margins with four fields, and the Info group with Title, Author and Description,
where before that whole panel was empty. That is the selection reaching the bindings.

The canvas is still not drawing, and the reason has changed. The document view now gets a frame of

    CIDER_FRAME CCDocView -> -15x15 at 0,0 (was 0x0) from -[NSView resizeWithOldSuperviewSize:]
    CIDER_FRAME CCDocView -> nanxnan at 0,0 (was -15x15) from -[NSView setFrameSize:]
    CIDER_FRAME CCDocView DISPLAY nanxnan at nan,nan frame nanxnan hidden=0

A view whose size is not a number cannot paint anything. The negative width one step earlier comes
out of our own autoresizing, so that is where to look next, and it is a different problem from the
one this section started with.

MoneyMoney and the iTerm2 session were both re-run on all of these changes and are unchanged.

### After the selection: a scroll view that nobody ever sized

With a page selected the application runs geometry code it had never reached, and it now reports the
failure itself, with its own file and line:

    *** Warning in class:'CCDocView' selector:'setupGeometryForDisplayCurrentCanvasAndSave
        PreviouseScrollPosition:' file:'CCDocView.m:1851' - '[[self docView] frame] content NAN'

and the Undefined document type warnings are gone, because the document type is in the page that is
now selected. The disassembly of that method shows what it computes from: the document view frame,
the visible rect, and [[self enclosingScrollView] contentSize].

The frame trace explains the NaN one step further back. CCDocScrollView is born 0x0 from
-[NSScrollView initWithFrame:] and NOTHING EVER SETS ITS FRAME: there is not one setFrame line for
it in a whole run, only DISPLAY lines that still say frame 0x0. Our scroll view then tiles a
document view out of a zero content size minus the scroller width, which is where the document view
got -15x15; autoresizing is now clamped so it comes out 0x15 instead, which is honest and still
useless, and the application divides by it and gets a size that is not a number.

So the clamp is right and it is not the fix. The question for the next rung is why the document
scroll view never receives a frame: it is created in code at zero size, and something has to give it
the room, either the application through a layout method or our own split view and autoresizing
after it is added.

### The canvas view that nobody sizes, traced to the view it was added to

The NaN has a source and it is not arithmetic of ours. The frame trace now names two callers rather
than one, because the nearest caller of -setFrame: is almost always our own -setFrameSize:, and with
that the line reads

    CCDocView -> nanxnan (was 0x15) from -[NSView setFrameSize:]
        <- -[CCDocView setupGeometryForDisplayCurrentCanvasAndSavePreviouseScrollPosition:]

so the application computes it, from a scroll view that has no size, and then detects it and warns.
Our own division was worth fixing anyway and was NOT this: NSSplitView divided the available space
by the total width of its subviews, which is zero when they are created in code at zero size, so
every proportional resize of a fresh split view produced infinity and then NAN. It now shares the
room equally when there are no proportions to preserve, and clamps.

Where the scroll view comes from, measured by tracing the insertion rather than guessing:

    CCDocScrollView BORN 0x0 from -[NSScrollView initWithFrame:]
    CCDocScrollView ADDED to NSView 759x725 (siblings=3, in NSKVONotifying_CCSplitView)
        own 0x0 mask=0x0

It is created at zero size and added as one of three children of a plain NSView pane which already
has its size, and it is given NO autoresizing mask, so autoresizing can never reach it. It then
never receives a frame for the rest of the run: not one setFrame line, and every DISPLAY still says
frame 0x0, including after the compositor resizes the window. The document view inside it does get a
mask, 0x12, and is the one thing in that subtree that our autoresizing can touch, which is where its
0x15 comes from.

What the application expects is now the open question, and there is good evidence for the answer.
The only places it calls adjustSubviews are -[CCSplitView setVisibleLeftView:],
-[CCSplitView setVisibleRightView:] and
-[CCCanvasesPreviewAndDocumentSplitViewController setVisibleCanvasesPreview:], and that last one
sends it to the controller OWN VIEW. A view controller that sends adjustSubviews to its own view
believes that view is a split view. Ours is a plain NSView, which is why an earlier rung had to give
NSView an adjustSubviews of its own. So the next question is a narrow one: is the pane container
supposed to be an NSSplitView, and is it decoding as a plain NSView. That decides whether the fix is
in nib decoding or in layout.

It also explains why the canvas used to have a size and now does not. The earlier runs went through
setVisibleCanvasesPreview:, which called adjustSubviews and let the NSView fallback stretch the
zero sized pane; with a selected page the application takes a different path and never calls it.
The application does not use Auto Layout at all, checked: no NSLayoutConstraint, no anchors, no
addConstraint:, so nothing else was ever going to size that view.

### The ancestry of the view that never gets a size

The insertion trace prints the whole chain now, because the immediate container is rarely the one
that decides:

    CCDocScrollView ADDED own 0x0 mask=0x0, chain:
      0 NSView 759x725 mask=0x0 subviews=3
      1 NSKVONotifying_CCSplitView 1000x725 mask=0x12 subviews=2
      2 NSBox 1000x725 mask=0x12 subviews=2
      3 NSThemeFrame 1000x829 mask=0x12 subviews=3

Everything above the pane is healthy: the window frame, the box and the applications own split view
all have real sizes and real masks, and our split view tiles the pane to 759x725. The scroll view is
one of three children of that pane, at zero size, with no mask, and nothing in the application or in
us ever gives it a frame.

Two facts found while chasing the container tell the next rung where to go. The application creates
the split view of its canvases-and-document controller in code, with new, and calls setView: with
it, so a controller sending adjustSubviews to its own view is sending it to a real split view rather
than to a plain one. And CCDocScrollView OVERRIDES -tile, which is the NSScrollView method that
lays out the clip view, the scrollers and the rulers. A scroll view that is never given a frame
never tiles, so an override that would have arranged the document view never runs.

So the question is now: what gives a code-created scroll view its first frame, on a plain view pane,
in an application that uses no constraints and sets no autoresizing mask on it. That is a much
smaller question than the one this whole thread started with.

### CORRECTION: the scroll view with no frame is not what makes the canvas NaN

The last section left the canvas at a scroll view that nobody sizes, and implied that finding it a
frame was the fix. It is not, and the experiment that settled it took one run.

The application creates that view with new, which is a zero frame, in
-[CCMainWindowController awakeFromNib], adds it to a pane, sets its scrollers and its document view,
gives the DOCUMENT view a mask of 0x12 and gives the scroll view none, and never sets its frame
again. That much is confirmed from the instructions themselves, and every automatic route that could
have sized it is ruled out: the application uses no Auto Layout at all, implements no
windowDidResize:, no windowDidLoad, no layout method, and uses no frame change notifications, and
its only calls to adjustSubviews are the two pane toggles.

So the suspect was mutated rather than argued about. Behind a gate, a view added at zero size into a
container that has one was given the container bounds. The scroll view came out 759x725, the
document view 759x710 and then 759x725 through ordinary autoresizing, and the application still did
this:

    CCDocView -> nanxnan (was 759x725) from -[NSView setFrameSize:]
        <- -[CCDocView setupGeometryForDisplayCurrentCanvasAndSavePreviouseScrollPosition:]

with its own warning about a NAN in the document view frame, three times, exactly as before. The
probe was removed afterwards.

That is worth stating plainly: the missing frame is a real gap and it is NOT the cause of the blank
canvas. The NaN survives a fully sized scroll view.

Where it does come from is now named. That geometry method builds a transform through
-[CCDesignElement transformForRotateViewForCanvas:master:] and then calls two categories the
application adds to OUR NSAffineTransform, transformRect: and transformAndNormalizeRect:. The first
is four instructions of glue: it sends -transformPoint: for the origin and -transformSize: for the
size, both ours. Neither can create a NaN, because both are matrix multiplies with no division at
all, so they can only carry one that already exists in the matrix or in the rect. Our -invert is not
the source either; it checks the determinant and refuses.

So the next question is which side is already NaN, the transform the application built or the rect
it fed in, and the instrument for it is small: report from -transformPoint: and -transformSize: when
the matrix or the argument is not a number. That is one run away.

### The transform is clean, so the NaN is in the fit arithmetic

The instrument for the transform primitives was made to speak on the happy path first, because
silence from a probe that only reports failures cannot be told apart from a probe that is never
reached. It spoke twice in a run, and both were clean:

    CIDER_XFORM transformPoint matrix=ok [1 0 0 1 0 0] identity=1 flipY=0 arg=ok (-792,0)
    CIDER_XFORM transformSize  matrix=ok [1 0 0 1 0 0] identity=1 flipY=0 arg=ok (2376,612)

The transform is the IDENTITY and the rect it carries is sane: origin minus 792, size 2376 by 612,
which is three pages of 792 across and one page of 612 down, exactly what a spread of a US Letter
landscape document should be. So the application built a good transform, ours multiplied it
correctly, and the NaN is neither in the matrix nor in the rect.

That leaves the arithmetic after it, inside the same method: a fit, computed from fitSizeMode, the
visible rect and the scroll view content size, which is the only place left where a division can
happen. Our -[NSScrollView contentSize] and -[NSView visibleRect] are the values it reads, so the
next instrument reports those at the moment the geometry runs. The diagnostic in NSAffineTransform
was reverted, since that pin is materialised and it has answered its question.

### Every number we give the canvas is right, and it still computes a NaN

Two real defects of ours came out of looking for the NaN, and neither of them is it, which is worth
stating before the finding itself.

A view transform is built by dividing the frame by the bounds, to work out how much the bounds are
stretched to fill the frame, and a view whose bounds are empty made that a division by zero. Zero
over zero is NAN and anything over zero is infinity, and the result goes straight into the transform
used by -convertRect:fromView:, -visibleRect and every other conversion through that view, so ONE
empty view poisoned the geometry of everything beneath it. With no extent there is nothing to scale
by, so the scale is one now.

And -[NSScrollView clipViewFrame] only ever SUBTRACTS: a scroller width, a ruler, a header. A scroll
view that has not been given a size therefore produced a NEGATIVE content rect, and -contentSize
handed it straight out: the application was told its content was minus fifteen by zero. macOS
reports an empty content rect for an empty scroll view, never a negative one, so that is clamped.

Now the finding. With the document scroll view given a frame, by the gated probe, every value the
application reads from us at the moment it computes the bad frame is correct:

    CCDocView GOT NAN frame, was 759.0x725.0 bounds 759.0x725.0 visible 618.0x725.0 at 0.0,0.0
        scrollView=CCDocScrollView content 759.0x725.0

A sane frame, sane bounds, a sensible visible rect and a sensible content size, and it still sets a
size that is not a number. So this is not our arithmetic and it is not a division by one of our
zeroes: it is the application computing with something of its own. The transform is identity and its
rect is a correct 2376 by 612 spread, checked earlier, so what is left in that method is the fit
mode, the spread flag, the current canvas index and the state model behind them.

The next step is to read the arithmetic rather than the inputs: disassemble the stretch of
setupGeometryForDisplayCurrentCanvasAndSavePreviouseScrollPosition: between the transform and the
setFrameSize:, and find which value it divides by. That is static work and needs no run.

### Controllers created in code had none of their defaults, and the NaN has a named branch

Reading the arithmetic rather than the inputs was the right move, and it took two steps.

The stretch of setupGeometryForDisplayCurrentCanvasAndSavePreviouseScrollPosition: before the bad
setFrameSize: is a divide, a clamp and a multiply by the same scale, so a zero there would give
infinity and then infinity times zero. But the scale is not the problem. Further up there is a
branch:

    testq %rbx, %rbx        ; the transform from -[CCDesignElement transformForRotateView...]
    je    ...               ; and if it is nil:
    xorps %xmm0, %xmm0      ; the page width and height are set to ZERO

and the fit then divides by that zero. So the NaN has one cause: the application asked its design
element for a transform, got nil, and took the branch that zeroes the page. That also explains why
our transform instrument only ever saw ONE rect transformed where the method transforms two.

Chasing what was nil found a real defect of ours, though not that one. A controller created in code
went through NSObject init and came up with EVERY flag zero: avoidsEmptySelection NO,
preservesSelection NO, selectsInsertedObjects NO, where Cocoa documents all three as YES, and the
object controller half never got its observed key set, its object class name, or isEditable. Only a
controller decoded from a nib, or created with initWithContent:, was set up properly. Swift
Publisher builds the controllers for its canvases in code, so they held their canvases and selected
NOTHING: measured as arranged=2 selected=0 and arranged=1 selected=0, which is exactly the two
content canvases and the one master page in the document.

Both initialisers are fixed: init goes through initWithContent:, which is the designated one, and
NSArrayController initWithContent: now calls its superclass designated initialiser rather than its
init. After that every controller with content selects: arranged 2 selected 1, arranged 1 selected
1, arranged 11 selected 1, and so on through the whole window.

The canvas still does not draw, and the reason is now one method call wide. At the moment the bad
frame is set the window controller is there and its current design element is a real object, so the
receiver is not nil; the application still hands back a nil transform for it. What that method does
with the canvas index and the master flag is the next thing to read.

Two more of ours were fixed on the way, both found by looking for the NaN and neither of them it: a
view transform divided the frame by the bounds, which is a division by zero for an empty view and
poisons every conversion under it, and NSScrollView reported a NEGATIVE content size for a scroll
view smaller than its scrollers.

### CORRECTION: the transform is not nil, and the fit is the arithmetic that matters

Earlier in this thread I wrote that the application asks its design element for a transform, gets
nil, and takes the branch that zeroes the page. The first half of that is wrong and the trace says
so plainly. With every transform logged rather than only the first few, the run reads:

    CIDER_XFORM point (-792,0) matrix a=1 d=1
    CIDER_XFORM size (2376,612) matrix a=1 d=1
    CIDER_GEOM CCDocView GOT NAN frame ...

three lines apart. The transform happens immediately before the bad frame, with the identity matrix
and the correct 2376 by 612 spread, so the nil branch is NOT taken. The reasoning that got it wrong
was sound in isolation and untested: a nil transform would explain the zeroes, and I never checked
whether that branch was actually reached. It was not, and two independent facts now say the receiver
cannot be nil either, since the same method dereferences it through a C++ call that would fault, and
our own +[NSAffineTransform transform] cannot answer nil.

What the arithmetic actually does, read instruction by instruction: the fit divides a size by the
page width, compares, and keeps a scale in one slot; at the end that same scale is used as a
divisor, a clamp is subtracted from it, and the page size is multiplied by the result. A zero scale
there gives a division by zero and then infinity times zero, which is the NaN.

And here the honest part. The scale is fed by a size that IS zero in the ordinary run, because the
document scroll view has never been given a frame, which is the gap this thread started with. But
when that view was given one by the gated probe, so that the frame, the bounds, the visible rect
and the content size were all sane, the application STILL produced a NaN. Both measurements are
real and they do not fit together yet, so the next rung starts by re-running the fill probe with the
transform trace on, which is the one combination not yet measured.

### The measurement that closes our side of the canvas

The one combination never run was the fill probe and the transform trace together, and it settles
the contradiction the last section left open. With the document scroll view given a frame:

    CIDER_XFORM point (-792,0)
    CIDER_XFORM size (2376,612)
    CIDER_GEOM CCDocView GOT NAN frame, was 759.0x725.0 bounds 759.0x725.0
        visible 618.0x725.0 at 0.0,0.0 scrollView=CCDocScrollView content 759.0x725.0

Four lines apart. The transform runs, carries the correct 2376 by 612 spread, and every value we
hand the application is a sane number: its frame, its bounds, its visible rect and the content size
of the scroll view it lives in. And it still sets a size that is not a number.

So our side of this is done, and that is worth saying as plainly as the failures were. The zero or
the NaN that the fit divides by is inside the application: the scale it keeps comes from a C++ call
on its own core document, and everything Cocoa gives it on the way is correct. Nothing in the list
of stubs the run reports touches document loading either; they are drawing and accessibility, and
the one that appears 164 times is an NSImage draw variant whose sibling paths visibly work.

What that leaves for Swift Publisher is a question about its own deserialisation, which is a much
larger and more speculative piece of work than the gaps this thread has been closing, and it is not
a Cocoa gap. The queue has an application whose keyboard has never been tested, and that is a
criterion, so the next work goes there.

### MoneyMoney: the keyboard, tested without typing anything

The keyboard was the one criterion never checked for MoneyMoney, and it needs care rather than
avoidance: the application talks to banks and the field on screen at that point is a credential
field, so nothing is typed into it, ever. The test is arranged so that no text is entered at all.
With the File menu open, two Down presses and then Escape: the menu is still open in the capture
after the Downs and closed in the capture after Escape.

Three runs of three, looked at as pairs each time, and a fourth ad hoc run before them. So keys
reach the application and are acted on.

The Down presses move no highlight, and that is correct rather than a failure: every item in that
menu is disabled while the application sits at its lock screen, and there is nothing for an arrow
key to land on.

One real difference from macOS came out of it, small and worth recording: after Escape closes the
menu the File title in the menu bar STAYS highlighted, where closing the same menu with a click
clears it. So the keyboard path through menu tracking ends without restoring the title.

What this does NOT prove is text entry into a field, and that is deliberate. The only text field
reachable in that state is the password field of the lock screen, and it will not be typed into.

### The menu title that stays highlighted, and one theory eliminated

Closing a menu with Escape leaves the title highlighted in the menu bar, where closing the same menu
with a click clears it. The obvious theory was stale pixels: the tracking loop ends by setting its
selected index to NSNotFound and marking the view for display, and a mouse close is followed by more
events that would carry that pending display along, while a keyboard cancel is followed by nothing.

That theory is wrong, and the run says so. Forcing the work immediately, with displayIfNeeded and
flushWindow at the end of tracking, changes nothing at all: the title is still blue in the capture
two seconds after Escape. The change was reverted rather than left in as an unexplained line.

So either the index is not actually cleared on the view that draws the bar, or the redraw does not
reach the surface by that route. The next step is a trace of the index at the end of tracking, which
tells the two apart in one run. It is a small cosmetic defect and it is written down rather than
left as a vague impression.

## iA Writer starts now, and the Combine verdict gets sharper rather than reversed

The section above (blocked on Combine, no swiftc) was right about the ceiling and wrong about the
floor. Thirty-one zero-valued placeholder symbols, written to the mangled names AccountCore imports,
got the process past dyld; sixteen more C and Objective-C names got it past its own +load methods and
into NSApplicationMain. It now reaches -[NSApplication finishLaunching], which posts
NSApplicationWillFinishLaunching, and the app builds an AccountCore.Account from its observer. That
faults at address -8 inside __swift_instantiateConcreteTypeFromMangledName, which is the runtime
turning a mangled type name into metadata: it reads one of the placeholders, gets zero, and
dereferences it.

So the placeholder trick is a LOADER fix and nothing more, and that is worth writing down because it
looks like progress of a kind it is not. A zero placeholder is correct exactly as long as nobody
touches the type. AccountCore touches one in its first publisher.

WHAT THE REMAINING GAP ACTUALLY IS, measured by subtracting both the runtime exports and what the
application own 25 binaries define for each other, and excluding the Sparkle updater helpers that are
separate processes we never launch: 57 symbols, not the 264 reported before that subtraction.

    23  Swift stdlib     Int128 codable requirements, typed throws, coroutine frames,
                         isolated deinit -- all newer than the runtime pin
     5  __swift_FORCE_LOAD markers for overlays we do not ship (OSLog, QuickLookUI, Spatial,
                         UniformTypeIdentifiers, Builtin_float)
     3  Swift runtime    swift_coroFrameAlloc, swift_stdlib_isStackAllocationSafe,
                         swift_willThrowTypedImpl
    12  libc             NOT A GAP: memcpy, strlen and friends. MoneyMoney imports them too and
                         runs, so the loader supplies them; a static nm union cannot see that
    11  ours             all implemented this rung
     1  vImage           implemented this rung
     2  AppIntents       nothing: those 164 symbols are defined inside the app own frameworks

The runtime pin dates itself: vendor/pins/swift ships PREBUILT dylibs, and its libswiftCore exports
no task or concurrency symbols at all, so it predates Swift 5.5 while iA Writer is a Swift 6 era
build. That single fact explains the 23 stdlib gaps and the 3 runtime gaps without any further
measurement.

Writing Combine by hand in C or Objective-C is not an alternative: generic value metadata and
protocol conformance descriptors are compiler output, not something a header and a .m can produce.
OpenCombine compiled with -module-name Combine would satisfy the names exactly, and needs a
Darwin-targeting Swift compiler, which is the infrastructure gap already named above. iA Writer is
therefore blocked in a different way from Swift Publisher: SP needs its own file format understood,
this needs a toolchain that does not exist in this build.

### The three real defects found on the way, which outlive iA Writer

  +[NSBundle bundleWithIdentifier:] only searched a table of bundles somebody had already created,
  with a TODO admitting it should search. Every framework that asks for ITSELF by identifier got nil.
  It now asks +allFrameworks once, which walks every loaded image and registers each framework it
  finds, then looks again. iA Writer put that nil straight into an NSMutableSet from a +load.

  +[NSError setUserInfoValueProviderForDomain:provider:] did not exist. A domain registering a lazy
  provider is how every modern framework fills userInfo, and the app registers one from a +load, so
  the process died on an unrecognised selector with no other message. Implemented per domain under
  its own lock, and every accessor that reads a single key now asks the provider when the dictionary
  has no value for that key.

  CFStringTokenizerCopyBestStringLanguage was commented out with a note that it needs a language
  model. It answers from Unicode script now: right where a script belongs to one language, a most
  common answer for Latin and Cyrillic, NULL where there is no script at all. The code says which
  question it is answering.

### Three patches that could never have applied, and the method that catches it

foundation 0011 hunk 10, foundation 0016 hunk 4 and corefoundation 0009 hunk 1 carried context lines
whose newlines had been collapsed (two statements joined by four spaces), so nix could not build
either pin. They had been captured from a mangled copy and committed without a pin build to check
them, which is exactly the failure mode the materialised-pin rule exists to prevent.

The repeatable method, now used for all five patches this rung:

    nix-build -E 'with import <nixpkgs> {}; fetchFromGitHub { owner=...; repo=...; rev=...; hash=...; }'
    cp -r that store path, apply 0001..N-1, copy the tree, apply N (good hunks land, one rejects),
    hand-apply the rejected hunk intent, diff -u the two trees, keep the prose header

and then verify with the pin build itself rather than by eye:

    nix-build scratchpad/pinpath.nix --argstr pin vendor/pins/foundation

followed by a file-by-file diff of the built pin against vendor/src. Ten of ten identical here, which
is what makes buck2 and nix the same program rather than two that merely look alike.

## The guest knows which terminal it is on, and ps stops lying about time (task #120)

The task was written as "make the guest recognise its pty (tty, isatty, task_read_for_pid)" and one
run showed that isatty had never been the problem:

    Cider [~]# test -t 0 && echo T0_YES || echo T0_NO; stty -a | head -2
    T0_YES
    speed 0 baud; 44 rows; 175 columns;

So the fd is a terminal, the termios ioctls work, and `ls -l /dev/fd/0` even shows it pointing at
/dev/pts/3. What returned NULL was ttyname(), and tty(1) prints "not a tty" for exactly that.

ttyname_r here is the FreeBSD one: fstat the fd, require a character device, then ask devname_r to
turn the device NUMBER into a name. And devname_r opens /dev and reads only that directory. On macOS
that is the whole answer, because a pty slave is /dev/ttys00N, in /dev itself. Under this port the
terminal is a Linux pty and the slave lives in /dev/pts, one level down, so the loop walked 204
host device nodes and matched none of them.

The scan is now a helper called once per directory, and /dev/pts is searched when the first pass
finds nothing. The name comes back carrying its subdirectory, "pts/3", which is what every caller
wants because they all prepend /dev. Two visible things changed for one edit: tty(1) answers
/dev/pts/3 with status 0, and ps(1) shows pts/3 in its TTY column where it had shown ??.

BSD syscall 539, task_read_for_pid, was simply missing from the table, so ps printed
"Unimplemented syscall (539)" once per process and skipped the task info it wanted. It is answered
now with the ordinary task port. macOS distinguishes control, read and inspect flavours precisely so
that a reader cannot write to the task it measures; this port has one kind of task port and nothing
to weaken it with, so the implementation says that in a comment rather than implying a restriction
that is not enforced.

That still left every process reading 0:00.00, and the server said why itself: task_info carried the
comment "TODO: fetch utimeus and stimeus somehow" and hardcoded zero for both TASK_BASIC_INFO and
TASK_THREAD_TIMES_INFO. The times now come from /proc/<hostpid>/stat, which is the same route task
#62 used to get real virtual and resident sizes out of /proc/<hostpid>/statm. The parse begins after
the LAST ')' in the line, because field 2 is the executable name and may contain both spaces and
parentheses; counting whitespace from the left is wrong for any process whose name has a space.

Measured rather than asserted, with a burner running and then killed:

     PID TTY         TIME CMD
      30 pts/3      0:00.02 login -fp root
      31 pts/3      0:00.04 sh -sh
      37 pts/3      0:12.00 yes yes
      39 pts/3      0:00.00 ps

Twelve CPU seconds for a process that had been running about twelve wall seconds, and `kill %1`
terminated it, which also exercises job control through the pty.

TASK_THREAD_TIMES_INFO asks for the live threads only and gets the process totals here. That is the
same number until a thread has exited, and it is written in the code rather than left to be
discovered: separating the two needs per-thread accounting the server does not keep.

An operational note that cost a detour: vendor/src/libc materialises READ-ONLY (444 files, 555
directories), unlike the foundation and corefoundation pins, so an edit there needs chmod u+w first.

## The menu title is stale on the screen, not in the window (task #121, and it opened task #122)

The defect looked like a piece of state nobody cleared: open a menu from the bar, press Escape, and
the title stays highlighted until something else is clicked. It is not that. Four instruments, one
question each, and the chain is the answer:

    CIDER_MENU cleanup self=NSMainMenuView index=NSNotFound     the model clears
    CIDER_MENU bar drawRect 1400x28 index=NSNotFound            the bar redraws with it
    CIDER_PAINT path blend=17 1400x28 at 0,850 c=0.960          and repaints the whole strip
    (buffer scanned at present time)                            no accent blue anywhere near the bar
    d4d +2s, d4e +6s, d4f +12s                                  the screen still shows it
    d4g after pointer MOTION, no click                          and then it is gone

Two details worth keeping from the instruments themselves. Onyx2D's blend mode numbering is NOT Core
Graphics numbering: it swaps HardLight and SoftLight, so every index from 8 upward is off by one and
17 is Copy here where Core Graphics calls 17 Clear. And the surface Onyx2D draws into is bottom-up
relative to the capture, so a rect traced from a screenshot has to be mirrored before
CIDER_TRACE_PAINT will match it; tracing the un-mirrored rect showed only NSThemeFrame writes and
made it look as though the menu bar never painted at all.

Dumping one BMP per frame instead of one per window makes the timing exact: 48 consecutive frames
carry the highlight, the last of them is present 948, and the tracking cleanup is present 1008. The
compositor was still showing it sixty presents later.

Forcing a present at the end of tracking does not fix it. It was tried on two separate rungs and
reverted both times. The first attempt did nothing for a reason the flushWindow trace names
directly: flushing is disabled during a display pass, so -[NSWindow flushWindow] only sets the
deferred flag. Sequenced so that it really flushes, the backend present runs and the screen still
does not change.

What that leaves is the presentation path itself, and there is a defect in plain sight there. The
window path SINGLE BUFFERS: one shm buffer is attached on every present, AppKit draws into it
whenever it likes, and nothing in window.rs listens for wl_buffer.release (probe.rs has a listener;
the real window path has none). A client that modifies a buffer the compositor still owns is exactly
how some frames land and some do not, and how an unrelated event knocks the last one loose. Task
#122 is to double buffer with a release listener; task #121 is blocked on it, and so, quite possibly,
is a share of the redraw flakiness elsewhere.

## CORRECTION: the menu highlight was never stale pixels, and the log order said otherwise

The section above is wrong in its central claim and the way it went wrong is worth more than the
defect was. It reported that the model cleared, the bar repainted, the committed buffer was clean
and the compositor kept showing an old frame. The first two are read from a log in the order the
lines appear, and those lines are not in the order things happened. With a clock on both sides, the
wayland present line carrying t= and the driver stamping every capture with date +%s.%N, one run
says:

    t=58.4   the menu opens and the highlight enters the window buffer
    t=65.8   Escape
    t=81.3   the bar redraws and the highlight leaves the buffer

Fifteen and a half seconds. The redraw and the tracking cleanup that looked adjacent to the escape
belong to the NEXT tracking session, the one the driver's later click starts. Nothing about
presentation was involved.

What was involved is two things in NSMenuView's tracking loop, both of them ordinary AppKit
behaviour that cocotron does not have:

  Escape POPS ONE LEVEL there. Closing a menu opened from the menu bar therefore left the loop
  running with the title still selected, which is exactly what the screen showed. macOS ends the
  whole tracking session on Escape from a top level menu; only a submenu pops one level.

  The loop takes its own events with nextEventMatchingMask instead of returning to NSApplication,
  and it was NSApplication that displayed dirty windows before blocking. So even a selection change
  the loop DID make sat undrawn until an unrelated event woke it. It now displays and flushes every
  visible window before waiting, which also makes arrow-key navigation inside a menu appear as it
  happens rather than one keystroke late.

Measured three runs of three, captures looked at: 753 accent-blue pixels in the File cell with the
menu open, 0 after Escape, every time, and the buffer loses the highlight 0.02 seconds after the key.

### The double buffering was real, and it fixed nothing visible

Task #122 came out of the wrong diagnosis and is worth keeping anyway. The window path attached ONE
shm buffer on every present while AppKit drew into it whenever it liked, and nothing in window.rs
listened for wl_buffer.release. That is a client modifying a buffer the compositor owns. The mapping
is now three frames: AppKit draws into the first, which is never attached, and the other two take
turns being handed over, each with a release listener; a frame that finds both busy is dropped and
re-presented when one returns. The pointer AppKit draws through never moves, so there is no context
invalidation and no resize churn. It changed nothing on screen, and that is the point of writing it
down: it removes a real hazard and it was not this defect.

### What actually settled it was a mutation, not another trace

Five read-only instruments had each answered their own question and the answers still did not add
up. What decided it was writing a block of colour into the menu bar strip that changed every
present: it alternated on screen while the title stayed highlighted, so the strip was reaching the
compositor and the compositor was not at fault. The probe was removed afterwards. It also caught the
documented env trap first hand: the driver passed CIDER_WAYLAND_BARPROBE empty, env_flag treats SET
BUT EMPTY as on, and the probe painted into three captures that were meant to be clean.

## Swift Publisher: the canvas is not the app's file format, it is a scroll view with no size

Three things this plan recorded about task #116 were wrong, and each was wrong in the same way: a
conclusion drawn from what the log put next to what, rather than from an identity.

The transform was said to run immediately before the bad frame. Printing the CALLER return address
in -[NSAffineTransform transformPoint:] and transformSize: ends that: a whole run makes exactly two
transform calls and both come from 0x10025c0xx, while the geometry method that produces the NaN runs
from 0x1002e7d34 to 0x1002e8130. Different functions, hundreds of kilobytes apart.

The NaN was said to have one cause, a nil transform. The application's own code says otherwise:
-[CCDesignElement transformForRotateViewForCanvas:master:] loads +[NSAffineTransform transform] into
r14 in its first three instructions, and every exit, including the one taken when its document is nil
and the one for an unrecognised orientation, returns that register. It cannot answer nil unless our
+transform does.

And the remaining work was said to be the application's own deserialisation. A BLANK PORTRAIT
document, built from the application's defaults with no template file to read, produces the same NaN
and the same empty canvas. Whatever is missing is not a file format.

What is missing is a size. The document scroll view is created with [CCDocScrollView new], added to
a pane inside the document CCSplitView, and never given a frame: every setFrame: and setFrameSize:
sent to any scroll view during a whole run was traced, and the inspector and gallery scroll views get
theirs while this one never does. It has no autoresizing mask either. The 0x12 the application sets
right after construction goes to the CCDocView INSIDE the scroll view, which the disassembly shows
plainly (the receiver is r14, the document view, not r15, the scroll view). So nothing in AppKit can
size it and the application does not.

Give it the bounds of the view it is added to, behind a gate, and the canvas draws a page: white
page area, rulers, a page edge, where every previous run showed flat grey. The NaN warnings still
appear, so they are not the whole story, but the page is there and it was not before. That probe is
CIDER_SVFILL and it stays off: sizing a subview on insertion is not AppKit behaviour and shipping it
would change layout for every application.

So the question is now narrow: what sizes that scroll view on macOS. Ruled out: the application
never sets its frame; CCSplitView implements no layout methods at all; the only override on the
scroll view is -tile, and that one only checks its own frame and bounds for NaN; the split view is
masked 18 inside an NSBox that autoresizes its subviews; the panes themselves are sized by our
adjustSubviews. What is left to examine is the nib (something we may not be decoding), the
notification the application registers for on the clip view's bounds, and the initWithFrame: path a
[Class new] takes through our NSView, which starts at 1x1 here and at zero on macOS.

### Two coordinate methods, and an env gate that turned a control into a probe run

-[NSView scaleUnitSquareToSize:] and -[NSView translateOriginToPoint:] were both
NSUnimplementedMethod, and the first is how a view zooms at all: scaling the unit square makes the
BOUNDS smaller as the scale grows, so a canvas showing at 2x covers half as many units of its own
space. Swift Publisher calls it on its canvas. Both are now implemented, both are documented
arithmetic, and a zero or negative scale is refused rather than obeyed.

They do not put a page on the canvas by themselves, and the way that became clear is worth keeping.
A run described here as "with the two methods implemented" showed a page; it was not theirs. The
CIDER_SVFILL probe was on, because the driver exports the name with an EMPTY value and the gate
tested only getenv() != NULL. That is the trap this document already lists, and it caught two probes
in one session: the menu bar colour block and this one. The rule that follows is sharper than the
warning: a gate that only PRINTS may test for presence, but a gate that CHANGES BEHAVIOUR must test
for a non-empty value, because a driver that passes every switch through will otherwise enable it in
every run, including the ones meant as controls.

With the gate fixed, the pair is unambiguous on one build: probe off, flat grey canvas; probe on, a
page with rulers and a page edge.

## Swift Publisher answers the mouse now, and the click was landing 69 points low

Its menus never opened. The input trace showed every click arriving, the hit trace showed a view
being found, and from outside that is indistinguishable from an application that ignores the mouse.
What was wrong is a coordinate flip using the wrong height.

A window whose application refuses to shrink below a size keeps DRAWING at that size while the
compositor is handed a smaller buffer taken from the top of the bitmap. ensure_backing says so:

    cider-wayland-window backing=oversize number=36 buffer=1256x684 bitmap=1256x753

Wayland reports the pointer in surface coordinates from the top and AppKit wants them from the
bottom of its own window, so the event path needs a height to flip by, and window_for_surface was
handing it the BUFFER height. Every click in that window therefore arrived 69 points low, which is
exactly the overhang:

    before   CIDER_HIT at=281,649 view=NSView              the document pane, one point below the bar
             CIDER_HIT at=281,658 view=NSToolbarItemView
    after    CIDER_HIT at=281,718 view=NSMainMenuView frame={{0, 703}, {1256, 28}}
             CIDER_MENU mouseDown on NSMainMenuView at 281,13 bounds=1256x28 items=9

The flip now uses the bitmap height, which is what AppKit lays out in, and the View menu opens with
its real contents. Five runs out of five reached mouseDown on the menu bar. Neither MoneyMoney nor
iTerm2 has an oversize window, so neither changes, and both were re-run and looked at.

### And the canvas chain, mapped end to end

With menus working, the remaining canvas question got a precise answer about WHERE the missing size
comes from, read out of the application binary rather than guessed:

    -[CCMainWindowController updateViews]   the ONLY code that ever sizes the document scroll view;
                                            it moves [[self docView] enclosingScrollView] corner to
                                            the inspector view
    updateViews                             has exactly one caller: setInspectorVisible:
    setInspectorVisible:                    has exactly one caller in code: toggleInspectorVisible
    toggleInspectorVisible                  is never sent from code at all
    inspectorVisible                        is a declared BOOL property, so a binding drives it

So on macOS something pushes that property while the window is being set up, and the scroll view
gets its frame as a side effect of the inspector layout. Here nothing pushes it, the scroll view
keeps the zero frame it was created with, and the canvas stays grey. The next measurement is our own
binding machinery: whether a binding to inspectorVisible exists once the nib has loaded, and whether
it ever pushes an initial value.

The Hide Inspector menu item is a red herring worth writing down so it is not chased twice: its
action is literally `fake`, it has no target, and its title is bound. A class named fakeClass
implements `fake` and is not in the responder chain, so autoenabling greys the item. macOS searches
the responder chain the same way, so that item is very likely grey there too.

scripts note: scratchpad/objc-callers.py lists every call site of a selector and names the method
that contains it, by finding the selref loads rather than disassembling eight megabytes. That is how
the chain above was read in three commands.
