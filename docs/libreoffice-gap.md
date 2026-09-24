# What LibreOffice needs that Cider does not have, measured

The north star for #112 is `nixpkgs#libreoffice-bin`: the official macOS build, a Cocoa
application, so it exercises exactly the AppKit and CoreGraphics path this fork implements
rather than a toolkit that would have to be ported first.

**Measured 2026-08-13 against LibreOffice 25.2.1.2, x86-64, and the buck2 prefix.**

## The headline: 49 missing symbols out of 2,324, so 97.9 percent is already there

    app Mach-O files                     212
    symbols wanted from outside          2,324
    prefix Mach-O files                  792
    MISSING                              49

Every one of the 21 system libraries `libmergedlo.dylib` links is present in the prefix,
including AddressBook, AVFoundation, Carbon, Cocoa, CoreMedia, ImageIO, Kerberos and Metal.
Nothing is missing at the level of whole libraries; the gap is individual symbols.

## Getting the list at all

Discovering these one container run at a time costs a run per symbol, because dyld reports
exactly one and aborts. `scratchpad/lo-gap.py` answers the whole question statically: collect
what the bundle's Mach-O files leave undefined, subtract what the bundle itself defines,
subtract what the prefix defines, and group the remainder.

The first run inside the container found `_kCTFontVariationAxesAttribute` and stopped. The
static pass found it plus 48 others in one go, which is the difference between one afternoon
and one command.

## THE ORDER MATTERS, and it is not the order of the list

A two-level-namespace Mach-O binds **data** symbols and **ObjC classes** eagerly, at load, and
**functions** lazily, at first call. So the load-blocking subset is much smaller than 49:

**Eager, so these block `soffice` from starting at all:**

    _kCTFontVariationAxesAttribute              CoreText
    _kCTFontCollectionRemoveDuplicatesOption    CoreText
    _kABGroupNameProperty                       AddressBook
    _kABModificationDateProperty                AddressBook
    _kABPersonRecordType                        AddressBook
    _kABUIDProperty                             AddressBook
    _NSAccessibilityTabButtonSubrole            AppKit
    _OBJC_CLASS_$_MTLCommandBufferDescriptor    Metal
    _OBJC_CLASS_$_QLThumbnailProvider           QuickLook
    _OBJC_CLASS_$_QLThumbnailReply              QuickLook
    _OBJC_METACLASS_$_QLThumbnailProvider       QuickLook

**Lazy, so these only matter when the feature is used:** everything else, which is why a
first run can get a long way before any of them is reached.

## The full list, by library

**CoreText, 8.** Six functions and two constants. The descriptor-matching functions are how a
Cocoa application resolves a font by attributes, so these are real rather than exotic.

    _CTFontDescriptorCopyAttributes
    _CTFontDescriptorCopyLocalizedAttribute
    _CTFontDescriptorCreateMatchingFontDescriptor
    _CTFontDescriptorCreateMatchingFontDescriptors
    _CTFontManagerCreateFontDescriptorFromData
    _CTGetCoreTextVersion
    _kCTFontCollectionRemoveDuplicatesOption
    _kCTFontVariationAxesAttribute

**AddressBook, 13.** Mail merge and the address-book data source. A stub that reports an empty
address book is a legitimate implementation of all of it.

    _ABCopyArrayOfAllGroups  _ABCopyArrayOfAllPeople  _ABCopyArrayOfPropertiesForRecordType
    _ABCopyLocalizedPropertyOrLabel  _ABGetSharedAddressBook  _ABGroupCopyArrayOfAllMembers
    _ABMultiValueCopyLabelAtIndex  _ABMultiValueCopyValueAtIndex  _ABMultiValueCount
    _ABMultiValuePropertyType  _ABRecordCopyValue  _ABTypeOfProperty
    plus the four _kAB* constants above

**Carbon and HIToolbox, 8.** Native theming and the hot-key and secure-input APIs. LibreOffice
draws its own widgets; these are for matching the platform look and for global shortcuts.

    _GetThemeMetric  _HIThemeDrawFrame  _HIThemeDrawMenuBackground  _HIThemeDrawMenuItem
    _HIThemeDrawTextBox  _RegisterEventHotKey  _EnableSecureEventInput
    _DisableSecureEventInput  _GetCurrentEventButtonState  _GetCurrentEventKeyModifiers

**CoreGraphics, 6.** Colour space and path helpers, all of them ordinary Quartz.

    _CGColorGetTypeID  _CGColorSpaceCopyICCData  _CGColorSpaceCopyName
    _CGColorSpaceCreateICCBased  _CGContextBeginTransparencyLayerWithRect
    _CGPathCreateWithRoundedRect

**AppKit and Foundation, 4.**

    _NSAccessibilityActionDescription  _NSAccessibilityTabButtonSubrole
    _NSApplicationLoad  _NSExtensionMain

**Metal and QuickLook, 3 classes.** `libskialo` is Skia, which has a Metal backend it will not
use here, and QuickLook is thumbnail generation.

    _OBJC_CLASS_$_MTLCommandBufferDescriptor
    _OBJC_CLASS_$_QLThumbnailProvider  _OBJC_CLASS_$_QLThumbnailReply

**libSystem, 1.** `_memset_pattern16` is a BSD extension, four lines to write.

## PROGRESS, 2026-08-13: soffice now gets PAST dyld

Two of the eleven load-blocking symbols were the whole of the first two walls, and filling them
moved the failure each time in the order this document predicted, which is the evidence that the
static list is load bearing rather than descriptive.

    kCTFontVariationAxesAttribute, kCTFontCollectionRemoveDuplicatesOption
        vendor/patches/cocotron/0001-...  the first patch against that pin
    the four kAB* constants, plus the twelve AB* functions
        src/darwin/frameworks/AddressBook/capi.c, a framework that had NO C API at all

**`soffice --version` now resolves every symbol it binds at load and starts executing.** The
next failure is a different kind entirely:

    semaphore_timedwait failed (internally): -111
    *** dserver_rpc_interrupt_enter failed with code -111 ***

That is an RPC to a `ciderd` that is not answering, and it is NOT a framework gap. The control
matters: `appkit_probe` runs in the same prefix, in the same container, immediately before and
after, so the daemon works and something in LibreOffice's startup specifically provokes this.
111 is ECONNREFUSED. A -111 has been traced once before, in task #44, to a silent SIGSEGV in the
daemon rather than to a timeout, which is the first thing to rule out here.

The remaining eight eager symbols (one AppKit subrole, the Metal class, the two QuickLook
classes and their metaclass) were never reached, because dyld stopped before them. They are
still owed, and now they are not what blocks.

## THE THREE WALLS AFTER DYLD, 2026-08-13, and none of them was a missing symbol

**1. The daemon died of a divide by zero.** `soffice --version` reached `clock_get_time` on the
calendar clock, and `ciderd` was killed by SIGFPE in `scale_delta`. `xnu_sys_init` called
`clock_init` (XNU calls that once per processor) but never `clock_config` (once at boot), and
`clock_config` is what sets `ticks_per_sec`. It stayed zero, and the calendar path divides by it
twice. The guest then reported `semaphore_timedwait failed (internally): -111`, which reads as a
timeout and is really ECONNREFUSED to a dead daemon.

**LibreOffice 25.2.1.2 now prints its version and exits 0.**

**2. A missing accessibility string stopped the GUI.** With a compositor, VCL printed
`no suitable windowing system found, exiting.` The macOS build loads exactly one plugin,
`libvclplug_osxlo.dylib`, and that dlopen failed silently because
`_NSAccessibilityTabButtonSubrole` is bound EAGERLY. Adding the constant made the plugin load,
and **the Wayland backend came up under LibreOffice**: `register=ok class=NSDisplayWayland`,
`init=ok display=connected globals=21`.

**3. An empty language list, read past the end.** LibreOffice then died on
`+[__NSCFArray _getCString:maxLength:encoding:]`. The chain:

    [NSUserDefaults standardUserDefaults] registers AppleLanguages = [NSLocale preferredLanguages]
    +[NSLocale preferredLanguages] -> CFLocaleCopyPreferredLanguages()
    CFLocaleCopyPreferredLanguages builds its result ONLY from an existing AppleLanguages
      preference, and there is none, so it returns an EMPTY array
    LibreOffice checks CFGetTypeID(value) == CFArrayGetTypeID(), which passes, then reads
      element 0 WITHOUT CHECKING THE COUNT
    the read goes past the end and yields the array itself, which is handed to
      CFLocaleCreateCanonicalLocaleIdentifierFromString and then to CFStringGetCString

On a real Mac that list is never empty, so callers are written as if index 0 exists. The fix is
in `CFLocaleCopyPreferredLanguages`: never return an empty array, and derive the fallback from
LANG/LC_ALL/LC_MESSAGES, which is where every other program on this system reads the user's
language from.

**What made this findable at all** was `scripts/core-guest-stack.py`. A guest process is `mldr`
with Mach-O images mapped into it, so systemd-coredump and gdb print `n/a` for every frame; the
NT_FILE note has the mappings, under guest paths that need a `--root` to resolve.

**And a probe was worth more than the application.** `tests/buck2/gui/prefs_probe.m` exonerated
CFPreferences, the canonicaliser, and toll-free bridging in three runs, which is what moved the
search to where the bug actually was.

## WHERE IT STANDS AFTER THE LOCALE AND CARBON WORK

`soffice --version` runs and exits 0. With a compositor, the Wayland backend comes up under
LibreOffice and answers for the screen:

    cider-wayland-appkit register=ok class=NSDisplayWayland
    cider-wayland-appkit init=ok display=connected globals=21
    cider-wayland-appkit screens=1 frame=1280x800 source=wl_output

**The next wall is not the display.** `--headless --convert-to` fails identically, which is the
control that settles it: no window, no compositor, same error.

**`getpwuid(0)` RETURNS NULL IN THE GUEST**, and that is a general gap rather than a LibreOffice
one. LibreOffice resolves `$SYSUSERCONFIG` (`UserInstallation=$SYSUSERCONFIG/LibreOffice/4` in
`bootstraprc`) through `osl_getConfigDir`, which is built on the passwd entry rather than on
`$HOME`. With no entry there is no config directory and bootstrap fails as "Unspecified
Application Error", which mentions neither users nor directories.

Symlinking `/etc/passwd` to the host's, the way the prefix already does for `nsswitch.conf`,
`localtime` and `machine-id`, makes the FILE readable in the guest but does NOT fix `getpwuid`:
Libinfo reaches it through `si_search_file()` and something between there and the parser still
answers nothing. That is the next thing to take apart, and it is worth it beyond LibreOffice,
since anything asking who the user is hits it.

Past that point, with `-env:UserInstallation=file:///Users/root/.lo4` supplying the profile
directly, LibreOffice creates its profile, registers fonts, and then dies on SIGTRAP. That is
the frontier.

## THE REMAINING WORK IS CORETEXT, measured 2026-08-13

Everything above is fixed. Bootstrap completes with no override, the profile is created at the
real `$SYSUSERCONFIG` path, thirteen fonts are registered, and the failure moves into font
enumeration. `libvclplug_osxlo.dylib` needs 17 `CTFont*` functions:

    real     CTFontGetGlyphsForCharacters  CTFontGetBoundingRectsForGlyphs
             CTFontCreatePathForGlyph      CTFontGetSize
    stub     CTFontCollectionCreateFromAvailableFonts
             CTFontCollectionCreateMatchingFontDescriptors
             CTFontDescriptorCopyAttribute   CTFontCreateWithFontDescriptor
             CTFontCopyFontDescriptor        CTFontDrawGlyphs
             CTFontCopyTable                 CTFontCopyAvailableTables
             CTFontCopyVariation             CTFontCopyVariationAxes
             CTFontCreateForString           CTFontManagerRegisterFontsForURL
    missing  CTFontDescriptorCopyLocalizedAttribute

**THE METRICS LAYER IS ALREADY REAL, which is the good news in that table.** Glyph lookup,
bounding rects and outlines work; what is missing is ENUMERATION (collection and descriptor),
font creation from a descriptor, and `CTFontDrawGlyphs`. LibreOffice on macOS renders all of its
text through CoreText, so it needs those before it can show a document.

That is a self-contained project with a real design choice in it: descriptors can be plain
CFDictionaries of attributes, which is close to what they are on macOS and cheap, or a proper
CFRuntime class. The font data itself can come from fontconfig, which this fork already uses for
the AppKit font methods and which answered 380 families there.

## THE COREFOUNDATION PIN HASH: DO NOT UPDATE IT, tested 2026-08-13

`buck-src.nu` cannot re-materialize `vendor/pins/corefoundation`: the recorded hash no longer
matches what the fetcher produces. The obvious response is to record the new hash. **That would
silently delete a submodule.**

Tested rather than assumed: the tree was snapshotted, the hash set to the value the fetcher
reported, the pin re-materialized, and the result diffed against the snapshot. The new tree is
missing the ENTIRE `submodules/swift-corelibs-foundation` directory, all 22 entries of it.

The cause is visible in `.gitmodules`:

    [submodule "submodules/swift-corelibs-foundation"]
        url = ../darling-swift-corelibs-foundation.git

**The URL is RELATIVE**, so it resolves against however the parent was cloned, and the fetcher is
no longer resolving it. The target repository is alive (`darlinghq/darling-swift-corelibs-foundation`
answers 200), so nothing upstream disappeared; the fetch is what changed.

So the hash is correct and the FETCH is broken. Recording the new hash would bless a deficient
tree, which is exactly the failure mode a pinned hash exists to prevent.

**The three CoreFoundation patches are therefore applied to the working tree by hand.** They are
committed under `vendor/patches/corefoundation/` and apply cleanly with `patch -p1`, but a fresh
checkout will not have them until this is settled. Fixing it properly means pinning the submodule
explicitly instead of relying on relative-URL resolution, which is a change to the pin manifest
and has its own blast radius (entries are never inert, and pins collide by basename), so it is
left for a decision rather than taken here.

## WHERE IT STANDS AFTER THE CORETEXT WORK, 2026-08-13 evening

    soffice --version                          version, exit 0
    soffice --headless --terminate_after_init  completes, no error
    font enumeration                           1560 descriptors, twice per run
    font creation                              works; no "no O2Font" failures reported
    font tables                                CTFontCopyTable answers from FreeType
    soffice --headless --convert-to pdf        exit 0, and NO OUTPUT FILE

The conversion no longer errors and no longer hangs; it runs to completion and produces nothing,
printing none of the `convert ... -> ... using filter` line LibreOffice normally emits. The guest
can read the input (checked from a shell inside the container), so the file is not the problem.

**Two processes register the backend and both enumerate the font list**, so soffice is spawning
its second instance as it does on a Mac. That is the thread to pull next: the work happens in the
child, and the parent exiting 0 tells us nothing about what the child did.

`kCTFontFormatAttribute` was the difference between an empty font list and a working one, and it
is worth remembering why: an attribute that answers NULL reads as UNUSABLE rather than as
unknown, so leaving one out of a descriptor rejects the font rather than leaving it undecided.

## A TRAP WORTH KNOWING: STALE IPC PIPES MAKE IT EXIT 0 DOING NOTHING

LibreOffice keeps a single-instance socket at `<prefix>/private/tmp/OSL_PIPE_SingleOfficeIPC_*`.
A second instance that finds one hands its request to the office that owns it and quits. **If
that office was killed, the request goes nowhere, and the second instance exits 0 with no error
and no output.** Every killed run leaves one behind, so this compounds: three had accumulated
here.

That is exactly the symptom that looked like a broken document pipeline for several runs -
`--convert-to` returning 0 and producing no file. Clear them before every run:

    rm -f "$PREFIX/private/tmp/OSL_PIPE_"*

With them cleared the behaviour changes completely: LibreOffice does real work instead of exiting
immediately.

## THE CURRENT WALL IS A SPIN, not an error

With a clean pipe and a clean profile, `--convert-to pdf` runs for many minutes in state **R**,
burning about 1.2 cores, and eventually reports "Unspecified Application Error". A spinning
process is a different problem from a failing one and needs a different tool: a core taken after
the fact shows every thread parked, because by then the loop has been left.

**SIGABRT does not work for sampling it** - LibreOffice installs a handler and catches it. The way
to catch this is to attach while it spins and read the thread PCs, then resolve them with
`scripts/core-guest-stack.py`, whose `--threads` mode exists for exactly this shape of question.

## What this says about the shape of the remaining work

None of this is Wayland. The display backend is not what stands between this fork and a real
office suite; a handful of framework symbols is, and most of them are stubs whose honest
implementation is "there is no address book" or "this platform draws its own widgets".

That is worth stating plainly because it changes what to do next: finishing the Wayland input
rung and filling this list are independent, and the second one is what `soffice` is waiting for.

## Calc and Impress, driven for the first time

The roster has only ever driven Writer. Calc and Impress are different VCL widget sets and neither
had been exercised, so both were driven from the Start Center on a 1256x684 output and then resized
to 1000x600.

### Calc meets all three criteria

Clicking "Calc Spreadsheet" and typing into the grid:

- **RENDERS**: the full grid with column headers A to R and rows 1 to 42, both icon toolbars, the
  formatting bar with Liberation Sans 10pt, the Name Box, the formula bar, the right hand sidebar,
  the Sheet1 tab, and a status bar reading "Sheet 1 of 1", "English (Denmark)", "Average: ; Sum: 0"
  and 100 percent.
- **INTERACTIVE**: "Cider" typed after the click lands in cell A1 AND in the formula bar, with the
  caret in the cell. The Name Box reads A1.
- **RESIZABLE**: at 1000x600 the grid reflows from R to N columns and 42 to 31 rows, the title bar
  "Untitled 1" and the menu bar come into view, the toolbars reflow with overflow chevrons, and
  "Cider" is still in A1.

### Impress renders its template chooser and filters it live

Clicking "Impress Presentation" opens "Select a Template" with **twelve template previews in full
colour**: Beehive, Blue Curve, Blueprint Plans, Candy, DNA, Focus, Forestbird, Freshes, Grey
Elegant, Growing Liberty, Inspiration and Lights. Behind it the Slides panel holds slide 1 and the
sidebar its layout thumbnails.

Typing "Cider" into the search field filters the grid to **zero results**, which is correct since
no template matches, and the Filter control greys out as it does while searching. That is a live
search round trip through the dialog, not just text arriving in a field.

On resize the main window reflows correctly at 1000x600, title bar, menu bar, Slides panel and
toolbars all present. **The template dialog keeps its size and is clipped at the right edge.** That
is not called a defect here: a dialog does not shrink because the screen did, on this platform or
on a Mac, and a Wayland client cannot reposition its own toplevel anyway.

Nothing in either run needed a fix. Both modules were already working and simply had never been
looked at.

## Tools Options, a surface never driven before

Command comma opens it, which is where LibreOffice puts Tools Options on a Mac. The dialog is
967x640, floating with its shadow over the Start Center, and it renders completely.

**The tree.** LibreOffice expanded with User Data selected, then General, View, Print, Paths, Fonts,
Security, Appearance, Accessibility, Advanced, Basic IDE and Online Update, then Load/Save,
Languages and Locales, LibreOffice Base, Charts and Internet collapsed with their disclosure
triangles. A search field above it, and Help, Reset, Apply, Cancel and OK along the bottom with OK
blue.

**User Data**, the pane it opens on: an Address group of eleven fields laid out in rows of one, three
and two, the Use data for document properties checkbox, then ODF Cryptography with two key fields
showing their No key placeholders, a red X and a Select button each, and the always encrypt to self
checkbox.

**It is interactive, and the title follows.** Clicking Security selects it in the tree and the title
becomes `Options - LibreOffice - Security`; the pane draws six groups, each with its explanatory
paragraph and a right aligned button, Options, Connections, Master Password, Macro Security,
Certificate, TSAs and Browse, plus a checkbox pair and a text field.

Clicking the Load/Save disclosure triangle expands it in place, adding General, VBA Properties,
Microsoft Office and HTML Compatibility, and clicking General gives `Options - Load/Save - General`:
nine checkboxes at three indent levels, a spinner reading 10 minutes, and three pop-ups reading
1.4 Extended (recommended), Text documents (Writer) and ODF Text Document (*.odt).

**Resized to 1000x600** the dialog keeps its 967x640 and clips at the bottom, which is what a dialog
larger than the screen does here and on a Mac. The Start Center behind it reflows.

Nothing was typed into any field and nothing was applied: Cancel and OK were not clicked.

## The Writer menu bar and title bar are MISSING before a resize, and no gate can see it

Found 2026-09-24 while driving LibreOffice down a path the roster has never exercised: a dialog.

### What is measured

Driving Start Center, then Writer Document, at the default drive geometry:

- the screen is `frame=1256x684` (`cider-wayland-appkit screens=1 frame=1256x684 source=wl_output`)
- the Writer window is created at `1004x597` and **mapped at `1256x740`**, which is **56 points
  taller than the screen**
- the capture at that moment has **no title bar and no menu bar**: the toolbar is at y=0
- after the drive resizes the output to 1000x600, the same window shows `Untitled 1` in its title
  bar and the full menu bar, LibreOffice through Help

**2 of 2 drives**, both with the same shape.

### Input still lands where the paint is not

A click at output (290, 35), which is where the menu bar WOULD be, opens the Format menu:
`CIDER_MENU bar drawRect ... index=5`, and 5 is Format counting LibreOffice as 0. So the hit test
puts the bar at y=35 while nothing is drawn there. **The input geometry is right and the paint is
missing**, which is the opposite way round from the usual oversize-window symptom.

### Why no gate catches it

Every roster capture of LibreOffice is either the Start Center, which legitimately has no menu bar,
or a capture taken AFTER the end-of-drive resize, which is exactly the event that makes the chrome
appear. The sweep and the input gate both pass with the bar missing for the whole run.

### What is NOT established

Whether the top 56 rows are being cut by the compositor because the surface is oversize, or whether
the chrome is simply never painted and the resize forces the repaint that draws it. The two are
distinguishable: an oversize surface anchored at its bottom would lose the top, and 56 is close to
a 22 point title bar plus a 28 point menu bar.

A caution against generalising from this: MoneyMoney also maps a window larger than its output
(`create=ok 1124x730` then `mapped=yes 1124x784`) and its title bar and menu bar both draw
correctly, so oversize alone is not sufficient to lose the top.

### The dialog itself renders, and is the other half of the finding

Format then Character opens the Character dialog, and `CIDER_MENU track item=Character... enabled=1
action=menuItemTriggered:` confirms the command fired. It renders complete: six tab icons down the
left (Font, Font Effects, Position, Asian Layout, Background, Border), Western and Asian and Complex
segments, two font family lists with real font names, Typeface, Size and Language rows with combo
boxes and Features buttons, Help, Reset, Cancel and OK with OK as the blue default, and a preview
pane showing Latin, CJK and Hebrew sample text side by side. Zero unrecognised selectors on the
whole path.

### SETTLED by experiment: the surface is oversize, and one fix was tried and REVERTED

**The decisive experiment.** Same drive, screen raised to 1256x850. The window maps at `1256x740`
in BOTH runs, so at 850 it fits, and the capture then shows the title bar and the full menu bar.
At 684 it does not fit and both are gone. So the chrome is not failing to paint: the surface is
taller than the screen and the top is what falls off.

**One fix tried and reverted.** `-[NSWindow constrainFrameRect:toScreen:]` only moves the origin
and never shrinks, which pins the bottom edge and puts the excess off the TOP, exactly where the
title bar and menu bar are. macOS shrinks. Adding a size clamp there changed nothing: the window
still maps at `1256x740`, because that size is decided AFTER the init path where
`constrainFrameRect` is called. Reverted, because a change to the geometry path every window in
the roster goes through does not earn its place on a hypothesis that did not pay out.

**Where the 740 probably comes from, not yet proved.** 1256 is exactly the screen width and 740 is
the screen height plus 56. In this port the menu bar lives INSIDE the window rather than at the top
of the screen, so a frame computed from a content rect of screen size is taller than the screen by
the title bar plus the menu bar. That would make every maximised window in every application too
tall by the menu bar height, which is a design consequence rather than a local bug, and it is the
thing to measure next: what does `frameRectForContentRect:` add, and what does the application ask
for.

### THE MECHANISM, measured: a minimum size taller than the screen beats the compositor

`CIDER_WAYLAND_TRACE_GEOMETRY` on the same drive, and it needed no new instrument because this one
already existed:

```
CIDER_WINFRAME SalFrameWindow asked=1256x684 kept=1256x740 min=212x740 didSize=1   (twice)
CIDER_WINFRAME SalFrameWindow asked=1256x683 kept=1256x740 min=212x740 didSize=1
CIDER_WINFRAME SalFrameWindow asked=1000x600 kept=1000x600 min=1x51    didSize=1
```

**The compositor asks for exactly the screen, 1256x684, and is right.** The window keeps 1256x740
because its MINIMUM height is 740, which is 56 more than the screen it has to live on. A minimum
larger than the output can never be satisfied, and the clamp takes the compositor answer back every
time.

**And the last line is why a resize fixes it.** By then the minimum has relaxed from `212x740` to
`1x51`, so the 1000x600 configure is kept in full and the chrome comes back. The window was only
ever stuck during the window of time when its own minimum was impossible.

**Where the 740 comes from, partly.** At creation LibreOffice asks for a content rect of
`1004x547` and `CIDER_WINGEOM` shows the frame come out `1004x597` for style `0xf`: **exactly 50
more**, which is the 22 point title bar plus the 28 point menu bar. In this port the menu bar lives
inside the window, so every titled window is 28 points taller than the same window on macOS, and
that 28 is inside the minimum as well as the frame. It is not the whole 56, so the application
asks for the rest itself, but it is the part this port adds.

### What is still not explained

MoneyMoney maps `1124x784` on the same 684 screen, 100 points too tall, and **keeps** its title bar
and menu bar, while LibreOffice at 56 too tall loses both. So oversize alone does not decide which
edge is lost, and whatever does decide it is not measured yet. That is the next thing to find, and
it matters more than the minimum size does, because macOS keeps the title bar on screen and cuts
the bottom.

No fix attempted here. Two geometry fixes were tried and reverted on this symptom already today,
and a third guess at a path every window goes through would be worth less than this measurement.

### The contrast that confirms it: MoneyMoney asks for a minimum that fits

Same trace, same screen, MoneyMoney:

```
CIDER_WINFRAME NSKVONotifying_MMWindow asked=1000x600 kept=1000x600 min=640x508 didSize=1
```

**Its minimum is 640x508, comfortably inside the screen, so the configure is kept in full and
nothing is clamped.** LibreOffice asks for `min=212x740` on a 684 tall screen and every configure
is taken back to 740.

So the deciding factor is not how large the window is, it is whether its MINIMUM fits the output.
That also explains the timing exactly: LibreOffice relaxes its minimum to `1x51` later in the
launch, and from that moment configures are honoured and the chrome appears.

One loose end recorded rather than explained away: an earlier sweep capture has MoneyMoney mapping
`1124x784` on this same 684 tall screen with its chrome intact, which this reading does not cover,
because a 784 tall window on a 684 screen should lose an edge whatever its minimum is. That
observation and this trace were taken from different runs and the sweep one has not been repeated
with the geometry trace on, so it is a loose end and not a contradiction yet.

The sway config the drives use, for anyone repeating this: `default_border none`,
`focus_follows_mouse yes`, `output * mode 1256x684`.

### The loose end, closed: every titled window here is 28 points taller than on macOS

The MoneyMoney observation needed the CREATION trace rather than the configure one, because
`1124x784` is reached before any `setFrame:` and so prints no `CIDER_WINFRAME` line at all. With
`CIDER_TRACE_WINGEOM` instead:

```
CIDER_WINGEOM asked 1124.0x680.0 ... -> frame 1124.0x730.0 style 0xf; main frame 1256.0x684.0
```

**Exactly +50 again**, the same as LibreOffice's `1004x547 -> 1004x597`. Measured on two
applications now: `frameRectForContentRect:` adds 22 for the title bar and **28 for the menu bar**,
because in this port the menu bar lives inside the window.

That is the quantified design consequence, and it is the part this port is responsible for:

- MoneyMoney asks for a content area of 680 on a 684 point screen. On macOS its frame would be
  702, already 18 too tall for this small test screen. Here it is 730, another 28 worse.
- LibreOffice asks for 547 and would fit easily on macOS at 569. Here it is 597, still fitting, and
  what makes it fail is the separate minimum of 212x740.

So the menu bar costs 28 points of vertical screen on every titled window, and on a screen close to
what the application wants that is the difference between the chrome fitting and being pushed off.
It does not on its own explain which EDGE is lost, which is still open.

### WHICH EDGE, measured on both sides: the chrome is DRAWN and then not shown

The open question was which edge is lost. Both sides of the comparison can be measured, and neither
is a guess.

**The bitmap, with `CIDER_WAYLAND_SAMPLE`, in its own top-down coordinates, while oversize:**

```
cider-wayland-sample number=2 stride=1304 buffer=1256x684 bitmap=1256x740
   600,5=0x00000000   600,20=0x1a000000   <- the 24 point shadow margin
   600,40=0xffececec                      <- TITLE BAR grey, 236
   600,60=0xfff5f5f5                      <- MENU BAR, 245
   600,80=0xffededed   600,100=0xff0044e0 <- toolbar, and a blue toolbar icon
```

**The capture at the same moment, read by pixel rather than by eye:** x=600 is `(237,237,237)`,
the toolbar colour, at EVERY y from 0 to 80.

So the title bar and the menu bar are drawn, in the buffer, in the right place, and the compositor
shows the window starting about 52 rows below them. **Output y=0 is bitmap y≈76, where
`xdg_surface.set_window_geometry` says it should be bitmap y=24.**

That rules out the two obvious readings. It is NOT a paint failure, because the pixels are there.
It is NOT the buffer being taken from the wrong end of the bitmap, because the present path is a
single `copy_nonoverlapping` of the whole mapping from its start.

**What both `set_window_geometry` calls say:** `(margin, margin, buffer_w, buffer_h)`, which for
this window is `(24, 24, 1256, 684)`. Bitmap row 24 is the top of the title bar. So the geometry
the client declares and the rows the compositor shows disagree by about 52, and finding what
imposes that offset is the next step: the candidates are the `dy` of the buffer attach, the value
of `buffer_h` at the moment of the geometry call, and whatever the compositor does with a surface
whose attached buffer is taller than the geometry it was given.

This is a better-posed question than the one it replaces, and it is the one a fix has to answer.

### THE LINE: the buffer is deliberately taken from the BOTTOM of the bitmap

`src/darwin/wayland/window.rs`, in the backing allocation:

```rust
let top_row = (dh - h).max(0);                                  // 740 - 684 = 56
let offset = (size * (slot + 1)) as i32 + top_row * stride;
let buf = wl_shm_pool_create_buffer(pool, offset, w + margin*2, h + margin*2, stride, format);
```

`dh` is the bitmap height and `h` the buffer height, so `top_row` is the overhang and the wl_buffer
begins **56 rows into the bitmap**. The compositor is therefore shown the LAST 684 rows, and the
first 56 are exactly the shadow margin, the title bar and most of the menu bar. That accounts for
the whole measurement: output y=0 lands at bitmap y≈76, not the y=24 that `set_window_geometry`
declares.

The variable is named `top_row` but it is the index of the first row SHOWN, which for an oversize
window is the top of the BOTTOM portion.

**It is deliberate, and the comment above it says why:** a window "given a 600 high output drew its
title bar 139 pixels down, with the previous frame still above it", and the same mismatch on the
input side is what made clicks land 69 points low. So the bottom was chosen to fix a different
symptom.

**And it disagrees with macOS**, which keeps the title bar on screen and cuts the bottom. That is
the trade-off a fix has to make deliberately rather than by accident, and it is a shared path: the
comment names Swift Publisher, so any change has to be measured on that application too, not only
on LibreOffice.

CORRECTION to the memory that sent me looking in the wrong place: the note
`oversize-window-input-offset` says the buffer is "taken from the TOP of the bitmap" and that the
compositor "shows the top of the bitmap at the top of the screen with the rest hanging off the
BOTTOM". The code takes the bottom. Whether the note was always wrong or describes an earlier state,
it is wrong about the tree as it stands today.

### The fix was TRIED, it works before a resize, and it breaks the resize. REVERTED.

Setting `top_row = 0` so the compositor is shown the top of the bitmap:

**What it fixed.** At the default geometry, with no resize, LibreOffice draws its title bar
`Untitled 1` and its full menu bar, LibreOffice through Help, for the first time. A click at
(290, 35) still opens the Format menu, now with the bar visible behind it. The Start Center gains
its chrome too, and the roster sweep shows the other six applications byte-identical, Swift
Publisher included, which is the application the original comment names.

**What it broke.** The roster INPUT capture for LibreOffice comes back with the window drawn twice:
a stale band carrying the title bar, menu bar, toolbars and ruler occupying the top 140 rows, and
the live window starting below it. The typed text still lands, so input is unaffected, but the
render is wrong.

**That is precisely the artefact the comment being replaced describes**: "drew its title bar 139
pixels down, with the previous frame still above it". So the offset is load-bearing for the RESIZE
path, and the reasoning behind it survives even though its stated premise about where the title bar
sits no longer does.

Reverted, and the backend rebuilt from the reverted source. **Third revert of the day on the same
rule**, and it earned its place every time: the sweep alone would have passed this change, because
every sweep capture of LibreOffice is taken before the resize that exposes the damage. Only the
input gate saw it.

**What a real fix has to do**, now that both halves are known: show the top so the chrome survives,
AND clear or repaint the region the old larger buffer occupied when the buffer shrinks, so the
stale band cannot remain. The two are separable, and the second is the part this attempt did not
do.

### BOTH STATES MEASURED, and the sample trace had to be fixed first to see the second

`CIDER_WAYLAND_SAMPLE` computed its row pitch from `buffer_w` while the mapping is strided by
`draw_w`. Those differ in exactly the case the trace exists to debug, so after the drive resized
the output to 1000 wide the samples were walking the bitmap at the wrong pitch and printing pixels
from nowhere in particular. Fixed to use `draw_w`, and only then does the second state read.

With the corrected stride, the same column at the same rows, in each state the window goes through:

| buffer | bitmap | row 30 | row 60 | row 170 |
| --- | --- | --- | --- | --- |
| 1256x740 | 1256x740 | transparent | transparent | `d9d9d9` |
| 1256x684 | 1256x740 | **title bar** | **menu bar** | `d9d9d9` |
| 1000x600 | 1256x740 | **title bar** | **menu bar** | **title bar again** |

**The last row is the whole thing.** After the resize the bitmap holds the window TWICE: a stale
copy at the top from the 740 tall layout, and the live 600 tall window starting at row 140, which
is `740 - 600`. So `top_row = dh - h = 140` is exactly right there: it skips the stale copy and
shows the live one.

**And in the oversize state before any resize, the window fills the bitmap from the top**, so the
same formula gives 56 and skips real chrome.

So the two states genuinely need different offsets, and the code has one formula:

- buffer 684, bitmap 740: AppKit laid out at 740 and drew from the top. Correct offset **0**.
- buffer 600, bitmap 740: AppKit laid out at 600 and drew at the bottom. Correct offset **140**.

**What a correct fix needs.** The offset is `bitmap height minus the height AppKit actually laid
out in`, and the backend does not reliably know that number: `insist_h` is still 740 in the second
state while AppKit has already relaid out at 600, so `dh - insist_h` is wrong there and
`dh - frame_h` is wrong in the first. Either the backend is told AppKit layout height directly, or
the stale copy is cleared when the bitmap is reused at a smaller layout so that showing the top is
always safe. The second is the same missing piece the reverted attempt needed.

## FIXED 2026-09-24: drop the insist when the window accepts, and show the top

Both halves, and neither works without the other, which is why the first attempt was reverted.

**Half one: the insist was only ever RAISED.** On every configure the backend asks the window what
it made of the size and records a larger frame in `insist_w`/`insist_h` so the bitmap can hold the
whole window. Nothing dropped it. So once LibreOffice relaxed its minimum and accepted 1000x600,
the bitmap stayed at the 740 of its earlier refusal, AppKit drew the new 600 tall window at the
BOTTOM of it, and the rows above kept the previous frame. The insist is now cleared when the window
accepts, which is safe by construction because that branch is only reached when the window did NOT
refuse the size.

**Half two: `top_row = 0`.** With the insist dropped, a bitmap taller than the buffer only happens
while the window genuinely insists, and then AppKit lays out at that full height and draws from the
top, so the first row is the right one.

**Measured after, in both states**, which is what the reverted attempt could not manage:

- before any resize, LibreOffice draws `Untitled 1` in a title bar and the full menu bar,
  LibreOffice through Help, for the first time
- after the resize, a single clean window with no duplicate band
- the Start Center gains its chrome as well

**And Swift Publisher gained its title bar too**, which is the application the replaced comment
names. Its input capture used to begin with the menu bar at y=17 and no title bar; it now shows
`Template Gallery` in a title bar above it. It had been losing its top in the same way and nobody
had noticed, because the only capture that would show it is taken after a resize.

This also matches macOS, which keeps the title bar on screen and cuts the bottom, and it makes the
paint agree with the input side, which already flipped by `draw_h` and so already assumed the top.

### The chrome fix did NOT break the input gate aim, checked rather than assumed

Drawing the chrome moves the Start Center list down by the title bar plus menu bar, and
`roster-input.sh` clicks a fixed `100,273` to open a Writer document, so the obvious worry is that
the gate now clicks a dead zone and passes for some other reason.

Measured three ways:

- the label rows, scanned out of the capture rather than read by eye: Open File 79, Remote Files
  125, Recent Documents 190, Templates 240, `Create:` 291, **Writer Document 328**, Calc 378,
  Impress 426, Draw 472, Math 520, Base 568
- the click as the application receives it, with `TRACE_INPUT`: `button pressed=true x=100 y=273`,
  unshifted
- **a control drive with no click at all**: the Start Center is still there at the end

So the click is doing the work, Writer does not open by itself, and LibreOffice hit-tests
`(100, 273)` onto its Writer Document tile even though that tile carries its label 55 points lower.
The gate passes for the right reason. Worth having written down, because the arithmetic says it
should miss and it does not.

## REVERTED, and the reason is the other half of the coupling

The fix above was landed and then reverted the same night. What it did right was real: an oversize
window showed its title bar and menu bar for the first time, on LibreOffice and Swift Publisher
both, with the other five byte-identical and the input gate passing.

**What it broke: clicking what you SEE opens the item one row below it.** All measured in one
capture, so no cross-run variation is in it:

| labels, scanned from the capture | click | opens |
| --- | --- | --- |
| Writer Document 328, Calc 378, Impress 426 | 273 | Writer |
| | 328 | **Calc** |
| | 378 | **Impress** |

Each click lands about 56 points below where it was aimed, which is exactly the overhang between
the 740 the window insists on and the 684 the screen has.

**The control that settles it.** Driven at 1256x850, where the same 740 tall window FITS and
`backing=oversize` never fires, clicking Calc at 378 opens **Calc**. Oversize it opens Impress; not
oversize it opens Calc. So the misalignment belongs to the path the change touched.

The paint now starts 56 rows earlier in the bitmap and the input still maps as though it did not.
`cider_wayland_post_mouse` flips by `draw_h`, which by arithmetic should already agree with the new
paint, and the measurement says otherwise. Where the other 56 enters is not found, and that is the
work a correct fix has to do FIRST, before moving the paint at all.

**And the gates did not catch it.** `roster-input.sh` clicks a fixed `100,273` for LibreOffice, and
that coordinate lands on Writer Document both with and without the misalignment, so the gate passed
7 of 7 with clicking-what-you-see broken. **A fixed coordinate that still hits something is not
evidence that aim is correct.** The check that would have caught it is the one used here: click a
row, name which item opened, and compare against the label scanned out of the same capture.

## Calc renders, which is new coverage either way

Reached by clicking the Start Center, on both the fixed and the reverted build: title bar, the full
menu bar with Sheet and Data, two toolbars, the Name Box reading A1, the formula bar with its fx,
sigma and equals, column headers A to R, rows 1 to 51, the grid, cell A1 selected with its blue
border, the Sheet1 tab and the status bar reading `Sheet 1 of 1`, `Default`, `English (Denmark)`
and `Average: ; Sum: 0`. Zero unrecognised selectors on the whole path.
