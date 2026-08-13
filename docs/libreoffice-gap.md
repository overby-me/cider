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

## What this says about the shape of the remaining work

None of this is Wayland. The display backend is not what stands between this fork and a real
office suite; a handful of framework symbols is, and most of them are stubs whose honest
implementation is "there is no address book" or "this platform draws its own widgets".

That is worth stating plainly because it changes what to do next: finishing the Wayland input
rung and filling this list are independent, and the second one is what `soffice` is waiting for.
