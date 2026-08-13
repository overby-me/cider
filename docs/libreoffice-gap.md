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

## What this says about the shape of the remaining work

None of this is Wayland. The display backend is not what stands between this fork and a real
office suite; a handful of framework symbols is, and most of them are stubs whose honest
implementation is "there is no address book" or "this platform draws its own widgets".

That is worth stating plainly because it changes what to do next: finishing the Wayland input
rung and filling this list are independent, and the second one is what `soffice` is waiting for.
