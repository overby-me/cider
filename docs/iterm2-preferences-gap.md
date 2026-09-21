# iTerm2 Preferences: what is fixed, and the blank screen that blocks the rest

Command comma on iTerm2 3.5.14 (launchd ON) does not open Preferences. The window never appears
and the terminal is all that is on screen. The application does not crash.

Each attempt raises ONE unrecognized selector while the Preferences nib is being decoded,
surrounded by `NSTextField initWithCoder` lines, with **zero** occurrences of `Exception` in the
log. That is what a caught raise looks like: AppKit wraps the decode, the raise is swallowed, and
the rest of the window is silently abandoned. It is the same shape as the MoneyMoney Preferences
defect, where one caught selector cost the whole window.

## The chain

Each fix advances the decode to the next missing thing, so the gaps are found one at a time.

| # | selector | whose fault | state |
|---|----------|-------------|-------|
| 1 | `-[NSStepperCell _stepUpImage]`, `_stepDownImage` | OURS | FIXED, cocotron patch 0085 |
| 2 | `+[NSFontCollection fontCollectionWithAllAvailableDescriptors]` | OURS | FIXED, cocotron patch 0086 |
| 3 | `-[NSString localizedLowercaseString]` and its two siblings | OURS | NOT LANDED, see below |

1. `NSStepper.m` declares `_stepUpImage` and `_stepDownImage` in a category on `NSStepperCell` and
   `-[NSStepper sizeToFit]` sends both. `NSStepperCell` implements neither and never could: it
   draws its arrows procedurally through the graphics style and owns no images. Our own code sent a
   method we never wrote, so any application laying out a stepper took the raise.

2. `NSFontCollection` is a forwarding stub that implemented `methodSignatureForSelector:` and
   `forwardInvocation:` as INSTANCE methods only. A class method send goes through the metaclass,
   which had no forwarding, so every class method on it raised regardless.

3. The three `localized*String` properties (10.11 and later) are absent entirely. The header has
   the three plain forms and the three `WithLocale:` forms and none of the localized ones.

## Why fix 3 is not landed: the display goes black

With all three in place the decode COMPLETES, `UNRECOGNIZED` goes to 0, and the whole output goes
black at the moment the keystroke lands.

```
capture sequence with all three: d1-start CONTENT, s01-wait CONTENT,
                                 s02-type BLACK, s03-wait BLACK, s04-shot BLACK
  3 of 3 runs black with the keystroke
  3 of 3 runs CLEAN without the keystroke, same build, same minute   <- the control
  2 of 2 runs clean with fixes 1 and 2 only                          <- the bisect
```

So it is not the capture flake and not machine load. It is specific to the path that completing
the decode opens. A blank screen is worse than a window that does not open, which is why fixes 1
and 2 landed alone.

### What is known about the blanking

- The application is ALIVE and DRAWING. The terminal surface is never unmapped, there is no hide
  and no destroy, and its last `pixels=drawn` is 940762 changed with `centre=fffafafa`, a full
  white paint. The screen is black anyway.
- Completing the decode creates two further windows: a 689x141 toplevel (style 0x7) and a
  BORDERLESS 390x139 (style 0x0). Neither is ever mapped and neither ever presents.
- The compositor sees 5 xdg_surfaces in a black run against 3 in a clean one, and exactly one
  mapped view in both.
- There is NO Wayland protocol error on either side, and no output is added or removed: one
  HEADLESS-1 in every run.

### Hypotheses already refuted, so they are not retried

- **The popup.** The borderless window becomes an `xdg_popup`, by the deliberate rule in
  `window.rs` that a borderless window with a mapped parent is a tooltip. Disabling popup creation
  with a gated probe left the screen BLACK 2 of 2. CONFOUNDED THOUGH: with popups off that window
  becomes a toplevel, which the same comment says tiles the screen and paints a black third, so
  this refutes the popup only weakly and could be worth a cleaner probe.
- **Unmapped surfaces as such.** The CLEAN run already carries 2 unmapped surfaces and renders
  fine, so an unmapped surface does not blank the output on its own.
- **No present after a resize.** Both the clean and the black run resize the terminal to 1256x684,
  paint it white, and never present again. It is not the discriminator.

### Where to look next

The remaining structural difference is that the application creates windows it never shows, and we
create a compositor surface for each one eagerly, when the NSWindow is created, rather than when it
is ordered front. Test whether deferring surface creation until a window is actually shown removes
the blanking. That is also the more faithful behaviour: macOS does not give a window a backing
surface until it is shown.

## Cost note for the next attempt

Adding the three `localized*String` methods to `NSString.h` invalidates about 5900 build actions,
as far out as JavaScriptCore, so each iteration costs a near full rebuild. THIS IS AVOIDABLE:
adding them to `NSString.m` alone rebuilds 33 actions and behaves identically, because the raise is
a runtime `objc_msgSend` and nothing of ours calls them at compile time. Verified: the
implementation only build reproduces the blanking exactly, 2 of 2, with the same 5 xdg_surfaces.

## Two traps met on the way

- Both `doesNotRecognizeSelector:` variants in `corefoundation/NSObject.m` print `UNRECOGNIZED`
  with a MINUS sign, so a class method send is reported as though it were an instance method. That
  is why gap 2 read as an instance method until the forwarding stub proved otherwise.
- Guest stderr interleaves, so grepping a whole line for `UNRECOGNIZED` can print a line whose
  visible text is about something else entirely. Use `grep -o` for the selector itself.

## Who asks for a compositor surface, measured

`-[NSWindow cider_platformWindow]` is LAZY: the surface is created on first ask, not at init. So
the question is who asks for the two windows that are never shown. With `CIDER_TRACE_APP=1`, the
twelve asks in one black run break down as:

```
7  -[NSCachedImageRep initWithSize:depth:separate:alpha:]
2  -[NSWindow windowNumber]
2  -[NSWindow setFrame:display:animate:]
1  -[NSWindow orderWindow:relativeTo:]
```

The seven image-cache asks are NOT the blanking. `NSCachedImageRep` backs an `NSImage` with a real
`NSWindow` carrying style mask `NSAppKitPrivateWindow` (0x8000000), and no surface in these runs
has that style: the five are 0xf, 0x5f, 0x10f, 0x7 and 0x0. Those windows get backing without a
compositor surface, which is the intended handling.

That leaves `windowNumber` as the ask worth chasing. Asking a never shown window for its NUMBER
should not cost a compositor surface, and it is the cheapest thing on this list to make answer
without materialising one.
