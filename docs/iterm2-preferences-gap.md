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

## The blanking, located: the workspace is empty

Asking the nested compositor what it is showing settles what every log comparison could not. At the
black moment:

```
output      'HEADLESS-1'   rect=1256x684+0+0
  workspace '1'            rect=1256x684+0+0
                                              <- nothing
```

and the control, the SAME build with no keystroke, at the same point in the drive:

```
output      'HEADLESS-1'   rect=1256x684+0+0
  workspace '1'            rect=1256x684+0+0
    con     ' '  vis=True  rect=1256x684+0+0
```

The terminal view is REMOVED from the compositor tree. Our backend does not know: it still reports
`mapped=yes` for that window, logs no unmap, no hide and no destroy, and its last paint is a full
white 940762 pixels. So the screen is black because there is nothing on the workspace, not because
anything drew black.

That also explains why every log-level comparison came out equal. Both runs map one window, both
present three times, both resize and paint. The divergence is only visible from the compositor.

### Ruled out as the remover

- `on_popup_done`, which destroys the popup, its xdg_surface and its wl_surface. It prints
  `popup=dismissed` and that line NEVER appears in a black run, so it does not fire.
- `windowNumber` materialising a surface. Fixed in cocotron patch 0087, which takes the surface
  count from five to four, and the screen is still black 2 of 2.

### Where to look next

Something makes the terminal's toplevel leave sway's tree. In Wayland a surface is UNMAPPED by
committing a NULL buffer, so the first thing to check is whether the terminal's `wl_surface` takes
a commit with no buffer attached around the keystroke. The backend resizes that window to 1256x684,
reallocates its backing (`context=ok`), paints it white, and does NOT present afterwards, so a
commit in that window with no buffer is plausible and would unmap it exactly this way.

## Instrument note: swaymsg is not on PATH

`swaymsg` is not on PATH in this environment. Run with stderr suppressed it prints NOTHING, which
reads exactly like an empty compositor tree and nearly cost a wrong conclusion. The binary sits
beside the running sway in its nix store bin directory; take the socket from
`/run/user/1000/sway-ipc.1000.<pid>.sock`, newest first, while a drive is still running.

## CORRECTION: the application CRASHES. It is not alive, and the screen is not the defect

Two claims made earlier in this document are WRONG and are withdrawn here.

**Wrong: "The application is ALIVE and DRAWING."** It paints once and then dies. The app log ends
immediately after the last window is created, and `cider-app exit=0` follows. That exit code means
nothing: `cider shell` does not propagate the guest signal, so a SIGSEGV and a clean exit report
the same 0, which is why this looked survivable for several rounds.

**Wrong: framing this as a blank screen at all.** The container log has it:

```
[guest kprintf] sigexc: emulating default signal effects
[guest kprintf] sigexc: handler (11) returning
CIDER_PROCKQ target died, nsid=17 host pid=731833
```

Signal **11, SIGSEGV**. The workspace is empty because the CLIENT IS DEAD and the compositor
dropped its surfaces. Nothing unmapped anything; there was nothing left to unmap.

### The fault

From the `sigexc` register dump, reading the tail of the x86_64 `gregs` block:

```
TRAPNO   0xE                 page fault
ERR      0x7                 present + write + user, so a WRITE to a protected page
CR2      0x7B4854D576C0      faulting address
RIP      0x7B485AB56F10
RSP      0x7FFFFFDFBF38
```

It fires right after the last two windows are created, which is the point the nib decode reaches
once the three missing selectors are supplied.

### What this means for the three fixes

The two that landed, patches 0085 and 0086, are still right: they remove selectors our own code
sends and never implemented. The third, the `localized*String` trio, stays out, but the reason is
now sharper than "a blank screen is worse". Supplying it walks the application into a SEGV that was
always there and was simply unreachable while the decode stopped earlier. The crash is the defect
to fix; the trio is only what exposes it.

### Instruments that misled, and the rule each one breaks

- `cider-app exit=0` is not evidence of a clean exit. The harness says so in its own comment.
  Read the container `ciderd.log` for the fault, and remember it APPENDS across runs, so take the
  LAST occurrence.
- `display_failed()` only ever ran from `roundtrip()`, so a dead connection was invisible to a
  client that stopped asking. A periodic check now runs from the event pump. In this run it proved
  the connection was ALIVE, which is what pointed at the process instead.
- The event pump log is a liveness signal in itself: `nextevent calls=` stops at t=53.96, about
  three seconds after the keystroke, while the drive runs twenty seconds longer. A pump that stops
  is a process that stopped.

## The crash, as far as it is pinned down

Reproduced and preserved once more, with the container log saved before anything truncated it. The
`gregs` block is the full Linux `gregset_t`, 23 entries, so the mapping is not guesswork:

| reg | value | |
|-----|-------|---|
| RIP | `0x7C2A0647DF10` | equals **R11**, so this is an indirect call through a register |
| RDI | `0x0` | first argument NULL |
| RSI | `0x0` | second argument NULL |
| RSP | `0x7FFFFFDFBF58` | |
| ERR | `0x7` | present + write + user: a WRITE to a page that is not writable |
| TRAPNO | `0xE` | page fault |
| CR2 | `0x7C2A006566C0` | faulting address, adjacent to RCX `...656700` and RDX `...656820` |

Two things follow without further measurement:

- **RIP is in the dylib region, not the application.** An app binary loads around `0x1_0000_0000`
  here; `0x7C2A...` is where our frameworks land. So the faulting code is OURS.
- **RDI and RSI are both zero.** For an `objc_msgSend` those are the receiver and the selector, so
  either this is not a message send, or it is one made with nothing.

### Cleared, so the next attempt does not redo it

- The three `localized*String` methods are CORRECT. `tests/foundation/probe_localized_case.m` runs
  all three `WithLocale:` conversions against a real `__NSCFLocale` and passes 5 of 5 with no
  crash. They only let the decode reach whatever faults.
- `-[NSString lowercaseStringWithLocale:]` does not mutate its receiver: it copies into a
  `CFMutableString` first. A write into a constant string was the obvious reading of ERR 0x7 and it
  is wrong.

### What is missing to go further

Symbolication. There is no guest core (`prefix/cores` is empty; the cores under
`/var/lib/systemd/coredump` are unrelated portal crashes) and the container log carries no image
load map, so `RIP` cannot yet be turned into a framework and a symbol. Getting either a core or a
load map out of a guest SIGSEGV is the next step, and it unblocks this immediately: the register
dump already says which instruction shape to look for, an indirect call whose target came from R11.

## SOLVED: the crash is a compat placeholder being CALLED

`TISCreateInputSourceList`.

A guest core does exist, and an earlier claim here that none did was wrong: it came from an
`ls | tail -2` that showed two unrelated portal crashes. `coredumpctl` lists the real one, and
**305** mldr cores are on this machine. `scripts/core-guest-stack.py` resolves it:

```
0x7C2A0647DF10  libswiftCompat.dylib+0xf10  _TISCreateInputSourceList
0x7C2A006566C0  libobjc.A.dylib+0x76c0      _objc_autoreleaseReturnValue
```

`src/darwin/swiftshim/libswiftCompatSymbols.c` line 91:

```c
CIDER_COMPAT_SYMBOL(65, "_TISCreateInputSourceList");
```

and that file says precisely what this is, in its own header:

> THEY ARE ADDRESSES, NOT IMPLEMENTATIONS, and that distinction is the whole point: a placeholder
> gets a process past dyld and faults at the FIRST REAL USE. The poison base makes that fault say
> so rather than look like a wild pointer. A symbol that turns out to be called needs a real
> implementation, and the fault address names which one.

So this is the mechanism working as designed. The placeholder is a `const uintptr_t` **data**
symbol holding a poison value; iTerm2 calls it as a **function**, so control lands on the symbol
itself and the process executes that data as instructions. That is why RIP is exactly the symbol
address, and why the byte soup it ran included something that WROTE, giving ERR 0x7 with CR2
pointing into another library's read-only text.

### Why the three selectors matter at all

They do not cause this. They let the Preferences nib finish decoding, and iTerm2's Preferences
enumerates keyboard input sources, which is what reaches `TISCreateInputSourceList` for the first
time. The crash was always there and simply unreachable.

### What this needs

A real `TISCreateInputSourceList`, in Text Input Sources. See the memory note "A Mac always has an
input source" for what this surface already assumes. Once it exists, re-test the three
`localized*String` methods: they are proven correct by `tests/foundation/probe_localized_case.m`
and are only held back because they walk the application into this fault.

### Correction to this document

The earlier entry that said "there is no guest core" and "symbolication is what blocks going
further" was wrong on both counts. The core was there; the listing I used hid it. Use
`coredumpctl list`, then `coredumpctl dump <pid> --output=<file>`, then
`scripts/core-guest-stack.py --root <prefix> --root <runtime>/libexec/cider <core> <addresses>`,
with the roots BEFORE `--threads` and the core before the addresses.

## Which window is Preferences, and how far the application gets

`CIDER_WAYLAND_TRACE_CREATOR=1` names the creator of every surface, which settles what guessing
from sizes could not. In one run of Command comma:

| # | class | size | created by |
|---|-------|------|------------|
| 1 | NSWindow | 400x450 | `-[PseudoTerminal(WindowStyle) setWindowWithWindowType:...]` |
| 7 | iTermWindow | 585x405 | the terminal, and the ONLY one ever mapped |
| 10 | **iTermPrefsPanel** | 689x141 | `-[iTermPrefsPanel setFrame:display:]` under `PreferencePanel awakeFromNib` |
| 11 | NSWindow | 390x139 | `-[GeneralPreferencesViewController awakeFromNib]` |
| 12 | NSPanel | 940x396 | `-[ProfilesAdvancedPreferencesViewController closeTriggersSheet]` |

**Window 10 is Preferences.** Windows 11 and 12 are a helper and the Triggers sheet, both
materialised as a side effect of a preferences view controller asking for a window.

The creation stack for window 10 shows the application getting a long way:

```
-[iTermApplicationDelegate showPrefWindow:]
-[PreferencePanel run]
-[PreferencePanel window]  ->  -[NSWindowController loadWindow]
  +[NSBundle loadNibFile:externalNameTable:withZone:]
  -[NSNib instantiateNibWithExternalNameTable:]
  -[PreferencePanel awakeFromNib]
  -[PreferencePanel resizeWindowForTabViewItem:animated:]
  -[iTermPrefsPanel setFrame:display:]
```

So the menu action fires, the nib loads, `awakeFromNib` runs, and the panel is even resized for its
current tab. Nothing is missing at that level.

### What does not happen

Spying `PreferencePanel run`, `PreferencePanel window` and the ordering entry points:

- `run` IS called.
- `window` returns a real `iTermPrefsPanel`, six times, never nil.
- `makeKeyAndOrderFront:` is called three times and the receiver is the TERMINAL every time. The
  panel is never ordered front, never made visible, and so never presents, which is why
  `mapped=yes` only ever names window 7.

A CAUTION ON THAT LAST POINT, because it nearly went in the other direction. `CIDER_SPY` on
`iTermPrefsPanel.makeKeyAndOrderFront:` resolves to the inherited `NSWindow` implementation, so it
catches every window, not only that class. That is why it can be trusted to say the panel was NOT
ordered: the instrument is demonstrably firing for other receivers in the same run.

### Next

`-[PreferencePanel run]` gets its window and then does not show it. Disassemble it and find what it
does between `[self window]` and the ordering call it never makes, the same way `showPreferences:`
was read in #254. The stack above gives the exact entry point.

## Why the window is never shown: `run` bails on `isVisible`

`-[PreferencePanel run]` disassembles to, in order:

```objc
[NSApp activateIgnoringOtherApps:YES];
[ivarA updateEnabledState];
[ivarB selectFirstProfileIfNecessary];
NSWindow *w = [self window];
BOOL visible = [w isVisible];
if (visible) return;          // <- the bail
[self showWindow:self];       // tail call, the only thing that shows the window
```

(Selectors resolved from the selrefs: `activateIgnoringOtherApps:`, `updateEnabledState`,
`selectFirstProfileIfNecessary`, `window`, `isVisible`, `showWindow:`.)

Measured, in one run each:

- `PreferencePanel run` IS called.
- `PreferencePanel showWindow:` is armed and **never fires**. So `run` takes the bail.
- Therefore `isVisible` answered TRUE at that instant.

### The contradiction that is still open

A separate spy on `iTermPrefsPanel.isVisible` shows **0** for the real panel instance, which is the
correct answer for a window nobody has ordered front. But in the correlated run the last
`isVisible` before `run` returns is on the **iTermWindow**, the terminal, answering **1**.

And `PreferencePanel.window` was separately measured returning a real `iTermPrefsPanel`, six times,
never nil.

So either `[self window]` inside `run` hands back the TERMINAL rather than the panel, or the
`isVisible` send lands on a different receiver than the one `window` returned. Those are different
defects and the next step is to separate them: spy `PreferencePanel.window` and
`iTermPrefsPanel.isVisible` TOGETHER and read the receiver pointers, which must match if the code
is doing what it looks like.

### Two instrument traps met here, both worth keeping

- `CIDER_SPY` on `Subclass.method` resolves through to the INHERITED implementation when the
  subclass does not override it. So `iTermPrefsPanel.makeKeyAndOrderFront:` swizzles `NSWindow` and
  fires for every window, and `PreferencePanel.showWindow:` swizzles `NSWindowController` and fires
  for every controller. That cuts both ways: a silent spy is only meaningful once you know the
  swizzle is firing for SOMETHING in the same run.
- The spy prints on RETURN, so a call made inside a method appears BEFORE that method's own line.
  Reading the order without knowing that inverts the nesting.
