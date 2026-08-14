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
