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
