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

### The disassembly is verified, so the contradiction is real

The tail call was read from a block that ended at the register pops, which left the jump target
assumed rather than seen. It is now checked: `0x100327391` is `jmpq *0x100cc0e60`, the same pointer
the function loads into `%r15` for its earlier `callq *%r15`, which is `objc_msgSend`. With
`%rsi = showWindow:`, `%rdi = self` and `%rdx = self`, the tail call is exactly
`[self showWindow:self]`.

So `run` has two exits and only two, and `showWindow:` never firing means it took the other one.
The panel measuring `isVisible` 0 in the same runs is not yet reconciled with that, and one of the
two measurements is lying. Candidates, cheapest first:

1. The `PreferencePanel.showWindow:` spy may not intercept. If that class does not override
   `showWindow:`, the swizzle lands on `NSWindowController` and should fire for every controller in
   the process. It fired for NONE, which is itself suspicious: prove that swizzle can speak by
   spying a controller that certainly shows a window, before trusting its silence here.
2. `[self window]` inside `run` and the six `PreferencePanel.window` calls the spy sees may not be
   the same sends; compare receiver AND returned pointer at the instant `run` is on the stack.

### The swizzle does speak, and the spy is not the cause

Both doubts raised above are now closed, which leaves the contradiction sharper rather than softer.

**The inherited-method swizzle fires for subclasses.** In the same family of runs,
`NSWindowController.window` fired with a `PseudoTerminal` receiver. So spying a method a subclass
does not override does reach that subclass.

**`showWindow:` is never called by anyone.** Spying `NSWindowController.showWindow:` across a whole
run yields the armed line and **nothing else**, in an application that plainly shows windows.

**The `isVisible` spy is not perturbing the result.** A run carrying `PreferencePanel.showWindow:`
with NO `isVisible` spy at all also never reaches `showWindow:`. So the bail is not an artefact of
instrumenting a BOOL-returning method, which was the obvious way for a measurement to change its
own answer.

So `run` takes the early return, `isVisible` answered true to it, and the panel separately answers
0. The only remaining shape that fits all four observations is that the `[self window]` inside
`run` is not yielding the panel at that instant, even though six `PreferencePanel.window` calls
elsewhere in the same run return exactly that. Establish WHEN those six happen relative to `run`:
the spy prints on return, so a call inside `run` prints before `run` own line, and none of the six
sit there.

### The ordering says `run` never called `window`, which cannot be right

Timing the two spies against each other in one run, by line number:

```
PreferencePanel run returns      line 16295
PreferencePanel window calls     lines 16637 16689 16690 16697 16698 16699
window calls occurring INSIDE run (before its own line): 0
```

The spy prints on return, so any call made inside `run` prints before `run` own line. None do.

That contradicts two things that are not in doubt. The disassembly calls `[self window]` TWICE,
unconditionally, before it reaches `isVisible`. And the creator backtrace for the Preferences
window has `-[PreferencePanel window]` and `-[PreferencePanel run]` on the stack together, which is
how the window gets built in the first place.

So in the instrumented run, `run` did not do what `run` does. The most likely explanation is now
THE SPY ITSELF: swizzling a void-returning method and forwarding it may not be invoking the
original, in which case spying `PreferencePanel.run` silently turns it into a no-op and every
conclusion drawn from a run that spied it is about the spy, not the application.

THE EXPERIMENT THAT SEPARATES THEM, and it must come before anything else here:

1. Spy ONLY `PreferencePanel.window`, never `run`, and drive the keystroke. If `window` now fires
   during the keystroke, `run` is executing normally and spying it was the distortion.
2. Then spy only `PreferencePanel.showWindow:` the same way.

Until that is done, treat every conclusion in this section as provisional. The findings ABOVE this
section do not depend on spying `run`: the crash, the TIS fixes, the window identification from
`CIDER_WAYLAND_TRACE_CREATOR`, and the fact that only window 7 is ever mapped all stand.

### CORRECTION: spying `run` does not make it a no-op

The section above suspected that spying a void-returning method stops the original from running.
That is WRONG and the check is one line: the `iTermPrefsPanel` surface is created in every run,
whether `run` was spied or not.

```
it-pair      run spied      iTermPrefsPanel created
it-corr      run spied      iTermPrefsPanel created
it-nospyrun  run NOT spied  iTermPrefsPanel created
it-show      run NOT spied  iTermPrefsPanel created
```

The panel is built by `[self window]` inside `run`, so `run` ran in all four.

And with `run` unspied, the ordering is exactly what the disassembly predicts. The six
`PreferencePanel.window` calls BRACKET the panel creation:

```
window calls   471  523  524      530  531  532
iTermPrefsPanel role line 525, create line 529
```

Three before the surface exists and three after, which is what two `[self window]` sends around a
lazy window load look like.

### So the account stands, minus the ordering anomaly

- `run` executes and calls `[self window]`, which builds the panel.
- `showWindow:` is never called by anyone, measured in runs that did NOT spy `run`.
- `run` has exactly two exits, verified in the disassembly down to the `objc_msgSend` tail call.
- Therefore `run` takes the early return and `isVisible` answered true to it.

What is still unexplained is narrow: in the two runs that spied `run`, its six `window` calls print
AFTER `run` own line instead of before it. That does not change any conclusion above, since the
panel is created either way, but it means the interleaving of the spy output in those two runs
cannot be used for ordering. Use a run that spies one method only.

The next question is unchanged and is now the only one: which object does `isVisible` land on
inside `run`, given the panel itself answers 0.

### The panel answers 0, measured cleanly

With `iTermPrefsPanel.isVisible` as the ONLY spy, so the ordering is trustworthy, and looking only
at calls after the panel surface exists:

```
(iTermWindow)      isVisible -> 1
(NSWindow)         isVisible -> 0
(NSPanel)          isVisible -> 0
(iTermPrefsPanel)  isVisible -> 0      <- the panel itself
```

The panel says 0, which is correct for a window nobody has ordered front, and by the disassembly
that should send `run` to `showWindow:`.

So the thread ends this session on one question, with everything around it measured:

**Either `[self window]` inside `run` hands back the iTermWindow rather than the panel, in which
case `isVisible` correctly answers 1 and `run` correctly bails; or `showWindow:` IS being called
and the spy is not catching it.** Both are testable and neither needs new instruments:

1. For the first: `CIDER_TRACE_UNRECOGNIZED` style backtracing is not needed, a `CIDER_SPY` on
   `PreferencePanel.window` alone already prints the RETURNED pointer. Compare it against the
   `iTermPrefsPanel` pointer that `isVisible` reports, in a run that spies one of them at a time
   and uses the panel creation line as the shared marker.
2. For the second: prove the `showWindow:` swizzle can speak by spying it against an application
   that definitely calls it, before reading its silence here again.

## The window is not merely unshown: Command comma sends the application into a SPIN

Two branches were left open above. Both are now closed, and they close onto something bigger.

**`[self window]` does hand back the panel.** With `PreferencePanel.window` as the only spy, all
six calls return the SAME pointer and it is an `iTermPrefsPanel`. So `run` is not being handed the
terminal, and `isVisible` inside it is being asked of the panel.

**The panel is never ordered front, on an instrument proven to speak.**
`iTermPrefsPanel.makeKeyAndOrderFront:` resolves to the inherited `NSWindow` implementation, so it
fires for every window, and it fires three times in the same run with the TERMINAL as receiver and
never with the panel. A silent instrument would prove nothing; this one is demonstrably firing.

**And the panel is asked `isVisible` TWENTY SIX MILLION TIMES.** In one run with that single spy:

```
app.log                26,402,805 lines, 1.7 GB
isVisible calls        26,653,823
of them on the panel    1,710,391      every one answering 0
event pump reached      ~1,150,000 iterations
```

That is a busy loop, and it is NOT an artefact of the spy. Measured without it, by the pump counter
alone:

| run | keystroke | pump iterations |
|-----|-----------|-----------------|
| it-nokey | no | **81,000** |
| it-show | yes | 466,000 |
| it-nospyrun | yes | 1,064,200 |
| it-final | yes | 2,777,000 |

So Command comma multiplies the event rate by roughly 13 to 34 against the idle control on the same
build, and the terminal keeps rendering throughout (every capture in the control run is CONTENT).

### What that reframes

The question is no longer only why a window is not ordered front. Something after `showPrefWindow:`
enters a loop that never completes, and it polls the panel for a visibility that nothing will ever
set. A wait loop around a window that is never shown would look exactly like this.

Next: name the loop. The pump counter is already in the log, so a backtrace taken at a high pump
count, or a single `CIDER_TRACE_APP` sample while the count is climbing, will say who is spinning.
Do not read `isVisible` again without a plan for 1.7 GB of log.

## Naming the spin: the 16 ms wait is asked for and not honoured

`CIDER_WAYLAND_TRACE_SPIN` already exists for exactly this and needed no rebuild. It answers two
things at once.

**It is NOT the poll-with-no-wait case.** Zero `wait=none` ticks and no `poll-with-no-wait`
backtrace, so no caller is passing a date already in the past. The switch is demonstrably speaking
in the same run, 85 lines of output from its other branch, so that zero is evidence and not
silence.

**Every wait asks for 16 ms and none of them takes 16 ms.**

```
wait n=2000    ms=16 budget=0.016
wait n=280000  ms=16 budget=0.016
140 samples, every one ms=16
```

280,000 waits inside a run of roughly 80 seconds is about 3,500 per second, or 0.28 ms each,
against the 16 ms each one asked for. So the budget is computed correctly and the poll returns
almost immediately anyway.

That moves the question off AppKit and onto what wakes the poll. The session runs a waker thread
whose only job is to poke the main thread, because a sleeping client cannot be reached by the
compositor. A waker that fires continuously produces exactly this shape: a correct 16 ms budget, a
poll that returns at once, and an event pump running thirteen to thirty four times its idle rate.

### Next

Find what makes the poll return. In order, cheapest first:

1. Log the `revents` the poll comes back with, and whether the wake came from the Wayland fd or the
   waker pipe. Those are different causes with different fixes.
2. If it is the waker, find what re-arms it after Command comma. The keystroke is the trigger: the
   idle control sits at 81,000 pump iterations and the same build with the keystroke reaches
   1,064,200.

## A mechanism that fits: the pump guard bails and the queue is never drained

The poll watches exactly ONE descriptor, the Wayland display fd, and asks for 16 ms. A poll on a
readable fd returns at once, so a fd that is never drained turns this into a busy loop without any
caller doing anything wrong.

`session::pump()` carries a non-reentrancy guard, and its own comment says why it must:
`prepare_read`, `read_events` and `cancel_read` have a reader COUNT behind them, and re-entering
before the previous pair finishes leaves that count wrong. It also says re-entry is not
hypothetical: pump runs from `-nextEventMatchingMask:`, an event handler can call back into AppKit,
and AppKit asks for the next event whenever it likes, so the call nests inside itself. Getting it
wrong was measured once as a fault inside `free()`, which is why the guard is there.

The consequence is the part that matters here. When the guard bails, THE QUEUE IS NOT DRAINED. The
fd stays readable, the next poll returns immediately rather than after 16 ms, and the pump comes
straight back around. That is exactly the measured shape: a correct 16 ms budget, 0.28 ms actual,
and an event rate 13 to 34 times idle that begins at the keystroke, which is when a preferences nib
full of view controllers starts calling back into AppKit.

THIS IS A HYPOTHESIS, not a measurement, and it is written down as one. What settles it is a
counter on the guard: how many times `pump` returns early during the spin, against how many times
it drains. If the early returns dominate, this is the mechanism.

If it is confirmed, note that the guard is not the defect and must not simply be removed: the
reader count really does break. The fix is for a nested pump to leave the queue in a state the
outer one will drain, or for the poll to stop treating an undrained fd as work.

### REFUTED: it is not pump re-entry

The hypothesis above is wrong, and settling it needed no rebuild because the counter already exists
and is unconditional: `session::pump` prints `pump=reentered count=N skipped=yes` on the first
three re-entries and every five hundredth after.

```
it-spin       pump=reentered lines: 0
it-nospyrun   pump=reentered lines: 0
it-nokey      pump=reentered lines: 0
it-final      pump=reentered lines: 0
no capture in the tree contains that string at all
```

A zero from an instrument that has never been seen to fire is not evidence, so the string was
checked in the built backend rather than trusted: `pump=reentered` is present in
`Wayland.backend/Contents/MacOS/Wayland`, alongside `wait=none`, whose sibling branch printed 85
lines in the same run. The code is there and the branch simply does not execute.

So the queue is not being left undrained by a nested pump, because there is no nested pump. The
spin has another cause and the search should start from the poll returning early rather than from
AppKit.

What remains true and measured: the poll asks for 16 ms and takes about 0.28 ms, it watches only
the Wayland display fd, and the event rate is 13 to 34 times idle from the keystroke onward.

### And it is not compositor traffic either

Comparing the idle control against a spinning run, on the compositor side:

```
              present  flush  frame callbacks  sway log lines
it-nokey   idle     3      3         2              533
it-nospyrun spin    3      3         2              552
```

Identical. The Wayland fd is not carrying more data in the run that spins, so the poll is not
returning early because the compositor is talking to us.

### The candidate that fits what is left: EINTR

The poll is

```rust
let mut fds = PollFd { fd, events: POLLIN, revents: 0 };
unsafe { poll(&mut fds as *mut PollFd, 1, ms) };
```

and **the return value is discarded**. A poll interrupted by a signal returns -1 with EINTR
immediately, and this loop cannot tell that from a timeout: it just comes back around. The guest
delivers signals through its own sigexc machinery, so a signal arriving often after the keystroke
would produce exactly the measured shape, a 16 ms request served in 0.28 ms with no traffic to
explain it.

WHAT SETTLES IT, and it is small: capture the return value and `errno`, and count the EINTR returns
against the timeouts. If EINTR dominates, the fix is the standard one, retry the poll with the
remaining budget rather than treating an interruption as an elapsed wait. Discarding the result is
what made this invisible for the whole investigation.

## ROOT CAUSE OF THE SPIN: the Wayland fd is hung up and nothing notices

Counting why the poll returns, rather than discarding the result:

```
pollret ready=64000 timeout=4679 err=0 last_rc=1 revents=0x11
```

- `err=0`. Not one interrupted poll, so **EINTR is refuted** as well.
- `ready=64000` against `timeout=4679`. The overwhelming majority of waits end because the
  descriptor is READY, not because 16 ms elapsed.
- `revents=0x11` is **POLLIN | POLLHUP**.

**POLLHUP means the peer closed the connection.** A hung-up descriptor is permanently ready, so
`poll` returns immediately every single time, for ever. That is the spin, completely: a correct
16 ms budget, 0.28 ms actual, no compositor traffic to explain it, and no signal involved.

### Why nothing reported it

`session::display_failed()` asks `wl_display_get_error`, and that only reports an error once a read
or dispatch has actually failed. A client that never successfully reads again never sets it. So the
liveness check added earlier in this session ran sixteen times, found 0, and correctly reported the
display as alive by the only measure it had. POLLHUP is the measure it did not have.

And the poll discarded its return value, so the one place that could see `revents` threw it away.
Two instruments looking straight at a dead connection, both silent, for the same reason: neither
was looking at the descriptor.

### What this explains

The Preferences window cannot ever map, because the connection it would map on is gone. The
terminal still appears in captures only because the compositor holds its last buffer. This is the
same family as the earlier finding that the compositor workspace was empty, and it is consistent
with everything measured since.

### The fix, and the check that must come first

Treat POLLHUP as a dead display: report it once, the way `display_failed` reports a protocol error,
and stop pretending the wait succeeded. But FIRST establish WHEN the hangup happens and whether it
predates the keystroke, because the idle control also spins, at 81,000 pump iterations rather than
1,064,200. If the fd is already hung up before Command comma, the keystroke is not the trigger and
this defect is much wider than Preferences.

### The hangup PREDATES the keystroke, and the connection is not actually dead

The check the section above demanded, run before touching anything:

```
with Command comma  pollret ready=64000 timeout=4679 err=0 revents=0x11
IDLE, no keystroke  pollret ready=78000 timeout=4346 err=0 revents=0x11
```

Identical. POLLHUP is set with no keystroke at all, so Command comma is NOT the trigger and this is
not a Preferences defect. Every iTerm2 run spins on a descriptor that claims to be hung up.

**And the connection is demonstrably alive.** `roster-input` drives iTerm2 and the typed command
appears at the prompt, which it cannot do unless keyboard events are arriving over that same
Wayland connection. A client whose peer has closed receives nothing.

So POLLHUP is being reported on a working connection. `POLLIN | POLLHUP` together, with data still
flowing, is the shape of a `poll` whose revents are not trustworthy, and this is an EMULATED
syscall: it goes through the guest libsystem_kernel rather than the host kernel directly.

### What this now costs, beyond Preferences

Every event wait ends immediately instead of after 16 ms, in every application on the roster, so
the whole port burns CPU waiting. The idle iTerm2 control reaches 81,000 pump iterations where the
design intends roughly 60 per second. Nothing renders wrongly because POLLIN is set too and the
data really is there, which is exactly why this has never shown up as a visible defect.

### Next, in order

1. Check the guest `poll` emulation for how it fills `revents`, and whether POLLHUP can be set
   spuriously for a socket that merely has data. That is one file and it decides everything below.
2. If it is spurious, the poll here should stop trusting POLLHUP alone; if it is real, find what
   half-closes the socket during startup.
3. Either way, measure the CPU cost before and after against the idle control, since the point of
   the 16 ms cap was to bound exactly this.

### The POLLHUP is genuine: the guest poll does not mangle it

`sys_poll_nocancel` passes the `pollfd` array straight to the Linux `poll`/`ppoll` syscall and
converts only the errno. No `events` or `revents` translation happens at all.

That pass-through is CORRECT for these bits, which is the point: Darwin and Linux agree on
`POLLIN` 0x0001, `POLLERR` 0x0008, `POLLHUP` 0x0010 and `POLLNVAL` 0x0020. So the emulation is not
inventing the flag and the host kernel really is reporting POLLHUP on the descriptor being polled.

### Which leaves one shape that fits everything

A hung-up descriptor AND a working Wayland connection cannot both be true of the SAME descriptor.
They can easily both be true if the descriptor being polled is not the live Wayland socket: a
closed fd whose number has been reused, or a display handle that is not the one the rest of the
backend dispatches on. The poll would then spin on a dead fd for ever while the real connection
carries input and frames normally, which is precisely what is measured.

Test it directly, and it is cheap: log the fd number that `cider_wl_display_get_fd` returns each
time alongside `revents`, and compare it against the guest process fd table, which
`read-the-guest-fd-table-from-inside` describes how to read. If the number moves, or if it names
something that is not a socket to the compositor, that is the defect.

### The fd is the Wayland socket, not a stray descriptor

The poll prints its descriptor now, and it is fd 23 in every sample. Startup prints
`waker=started fd=23`, which looked at first like a collision with a waker pipe. IT IS NOT, and the
waker source says so: it takes `wl_display_get_fd(display())`, the same Wayland socket the main
poll uses, deliberately, because waking when that socket is readable is the entire point of that
thread. So there is no fd reuse and no stray descriptor. Both pollers are on the real connection.

That makes the measurement stranger, not simpler, and it is worth stating plainly rather than
resolving by assertion:

- fd 23 is the Wayland display socket.
- `poll` on it returns `POLLIN | POLLHUP` essentially every time, 74,000 ready against 4,198
  timeouts in one idle run.
- Yet the connection carries input: `roster-input` types into iTerm2 and the command appears.

The waker comment names the POLLIN half exactly: *the socket stays readable until the main thread
reads it*, and that thread throttles itself with a 4 ms poll for precisely that reason. The main
event wait has no such throttle, so whenever data is pending and unread it spins at full speed.
That accounts for the spin without needing POLLHUP at all.

POLLHUP on a socket whose peer is alive is the remaining oddity and it may be a red herring for the
spin even though it is real. Separate the two: the spin is explained by unread POLLIN data, and the
fix for it is that the event wait must either read or not treat pending-and-unread as a reason to
return immediately, exactly as the waker already does.

## The spin is an application outliving its compositor, and four of my claims were wrong

The read side was finally counted, and it settles the spin. In a 300 second idle run of iTerm2 with
`CIDER_WAYLAND_TRACE_SPIN=1`:

```
cider-wayland-session readevents ok=1866 fail=2000 errno=0 displayerr=32
cider-wayland-session readevents ok=1866 fail=4000 errno=0 displayerr=32
cider-wayland-session readevents ok=1866 fail=6000 errno=0 displayerr=32
cider-wayland-session readevents ok=1866 fail=8000 errno=0 displayerr=32
```

`ok` is FROZEN at 1866 while `fail` climbs without bound. Every successful read happened before one
instant, and none after it. `wl_display_read_events` failing leaves the data on the descriptor,
`pump()` calls `wl_display_cancel_read` and returns, POLLIN stays set, and the next poll returns at
once. That is the whole spin, and it is why the 16 ms budget was being served in 0.28 ms.

### What actually killed the connection

Not a resize, and not anything the port did. The compositor exited:

```
00:00:33.897 [INFO] [sway/main.c:399] Shutting down sway
```

The successful-read counter froze in that same second. `app-drive.sh` tears the nested compositor
down once it has taken its captures, but `LIMIT` keeps the application running long after that, so
the process spends the remainder of the run pumping an event loop against a socket whose peer is
gone. The measured spin is that tail. It is real, it burns a core, and it is worth not doing, but it
is NOT evidence of a defect that a user would ever meet.

### Four claims withdrawn

1. **"The display error is 0, so the connection is healthy."** Wrong, and repeated over several
   runs. The `err=0` I kept citing is the `pollret` line's count of `poll` itself returning -1. The
   display error is a different number entirely, and it is 32, EPIPE. The two fields were never the
   same thing and I read one as the other.
2. **"`dispatch_pending` returns -1, so the connection is in an error state."** Withdrawn as an
   artifact of my own instrument. The trace called `wl_display_dispatch_pending` inside its
   `println!` while a read was prepared and not yet cancelled, which is an invalid state for
   libwayland, and dispatching is a side effect no trace should have. The field is now `errno` and
   `displayerr`, both read at the call site.
3. **"The connection carries input while POLLHUP is set."** Not established. Input works in runs
   where the compositor is alive; the POLLHUP samples come from after it exits. Those were separate
   phases of a run and I treated them as simultaneous.
4. **"POLLHUP on a live peer is the remaining oddity."** There is no oddity. The peer is dead.

A fifth error was in the searching, not the reasoning: `display_failed()` DID report the death,
printing `display=DEAD errno=32 protocol_error=0`, and I concluded it had stayed silent because I
grepped for lowercase `dead` against an uppercase `DEAD`. The instrument spoke and the reader was
broken, which is the same lesson as `truncated-list-is-a-lying-instrument` wearing a different hat.

### The fix, and what it does not claim

The event wait now sleeps its remaining budget instead of returning instantly, keyed on
`session::display_failed()` rather than on POLLHUP, because the dead connection is the real
condition and POLLHUP was only its shape. A live connection never reaches the branch.

Measured on iTerm2, same instrument, same units:

| | poll ready | poll timeout | reads ok | reads failed | nextevent rate |
|---|---|---|---|---|---|
| before | 76000 | 4189 | 4202 | 76000 | not sampled |
| after | 4000 | 1853 | 1866 | 4000 | 60.3 per second over 23.2 s |

The 16 ms budget specifies 62.5 passes per second and the loop now turns at 60.3, so the idle rate
is the designed one. What this does NOT show is any improvement to a live session: every sample
above comes from a run whose compositor had already exited. **Whether a live compositor ever
produces this spin is unmeasured**, and the way to measure it is a long `SETTLE` rather than a long
`LIMIT`, because the settle happens while sway is still up.

`protocol_error=0` alongside `errno=32` is the same pair `window.rs` records for the offscreen
window flood (task #244). Here it means only that the socket closed without the compositor sending
a protocol error, which is what a normal compositor shutdown looks like from the client side.

### Answered: a live compositor never spun, so the spin was never a user-facing defect

The previous section left one question open and named the experiment for it, a long `SETTLE`
instead of a long `LIMIT`, so that the application idles while sway is still up. Run that way
(`SETTLE=150 LIMIT=260`) one run contains both phases and is its own control:

| phase | window | rate |
|---|---|---|
| live compositor, idle | t 20.6 to 147.1 | 7600 calls in 126.59 s = **60.0 per second** |
| live compositor, late idle | t 100.4 to 147.1 | 2800 calls in 46.70 s = **60.0 per second** |
| dead compositor, after the fix | t 167.0 to 183.5 | 1000 calls in 16.48 s = **60.7 per second** |

sway logged its shutdown at t 158.9, between the second and third windows. The live rate is the
designed 60 per second and never varies, so **the event loop has never spun while the compositor
was alive.** Everything measured in this thread, the 76000 poll returns, the 0.28 ms budget, the
failing reads, came from the stretch after the compositor exited and before the harness limit
killed the process.

That retires the spin as a defect. It was a property of how the runs were driven, not of the port.
The fix stays because a process should not burn a core once its display is gone, and because
`display_failed()` is the honest test for that, but it speeds up nothing a user would meet. The
cost of the confusion was several iterations spent on pump re-entry, EINTR, compositor traffic,
stray descriptors and the skip_work fast path, every one of them correctly refuted and none of them
the answer, because the premise that there was a live-session spin at all went unchecked.

The lesson worth keeping: **a measurement taken from a long tail of a driven run must first prove
the harness was still up.** `nextevent` carries a timestamp and sway logs its own shutdown, so the
check is one `grep` and a subtraction, and it was available from the first sample.

## SOLVED, mostly: run is not bailing, it is being unwound by a raise

Everything above this point that explains the missing Preferences window by the early return in
`-[PreferencePanel run]` is WRONG, and the correction is measured rather than argued.

### The measurement that broke the old account

`CIDER_TRACE_VISIBLE` (cocotron patch 0088) prints the receiver, the answer and the BACKTRACE for
`-[NSWindow isVisible]`, filtered so the two event loop pollers (`_makeSureIsOnAScreen` and
`displayIfNeeded`) cannot spend the budget. In a run where `-[PreferencePanel run]` demonstrably
executed, which is the control that makes a zero mean anything:

```
stacks on iTermPrefsPanel with the pollers filtered   0
frames naming -[PreferencePanel run]                  6, all inside [self window]
```

`run` never asks. Every one of the six backtraces that names `run` is inside
`-[PreferencePanel window]` to `-[NSWindowController loadWindow]` to the nib, and not one shows it
past that call: no `updateEnabledState`, no `selectFirstProfileIfNecessary`, no second `window`, no
`isVisible`.

The disassembly was right all along and so was the reading of the branch. The selrefs were resolved
from the binary to be sure of it: `0x100ec8818` is `isVisible`, `0x100edf450` is `window`,
`0x100ed9148` is `showWindow:`. `run` simply never arrives at the test.

### The five step trace names the step, and the control is in the same run

`CIDER_TRACE_CONTROL` announces the five steps of `-[NSWindowController window]`:

```
PseudoTerminal    ... loadNibFile enter -> setWindow -> loadNibFile leave -> adopted -> done
PreferencePanel   ... loadNibFile enter -> setWindow -> (nothing)
```

Three controllers reach `done` in that run (`PseudoTerminal`, `iTermAdvancedGPUSettingsWindowController`,
`TriggerController`) and the panel is the only one that does not. A nib load that stops with no
leave marker while the main thread is back in the event loop is an unwind, not a hang, which is
exactly what the comment in `NSNib.m` says it is.

### The raise, named

`CIDER_TRACE_NIB` walks the awake list and stops at the same object every time, object 811,
`ProfilesGeneralPreferencesViewController`. The nib loader catches the escaping exception where it
leaves and re-raises, and it prints:

```
cider: RAISE NSInvalidArgumentException: cannot create data from nil url
  -[NSData(NSData) initWithContentsOfURL:options:error:]
  +[NSData(NSData) dataWithContentsOfFile:]
  +[NSImageRep imageRepsWithContentsOfFile:]
  -[NSImage initWithContentsOfFile:]
  -[ProfilesGeneralPreferencesViewController updateImageWell]
  -[ProfilesGeneralPreferencesViewController awakeFromNib]
  ...
  -[PreferencePanel run]
```

`updateImageWell` asks for the profile background image. With none configured the path is the
**empty string**, `fileURLWithPath:` returns nil for it, and our `initWithContentsOfURL:` raises
where macOS returns nil. Foundation patch 0085 makes both file entry points answer nil for a path
that will not convert, which is the documented behaviour every caller is written against.

### What the fix changed, and what it did not

After it: **no raise anywhere in the run**, and the awake walk continues past object 811 into
`defineControl:`, `updateValueForInfo:` and `updateEnabledState`, with the Preferences view
controllers alive and running work off the main queue.

The window still does not appear, and `PreferencePanel` still does not print `loadNibFile leave`.
So this is one defect of at least two, and the honest statement is that the first has been found,
named and fixed, and the second is now reachable for the first time. The next question is narrow:
the awake walk stops printing at 811 with no exception and with the event loop still turning at 60
per second, which by the same reasoning as above is a NESTED RUN LOOP on the main thread rather
than a block. Find what `awakeFromNib` enters that does not come back.

### Instrument notes worth keeping

- A spy on a method the event loop polls is useless without a caller filter. The first attempt cost
  1.7 GB of log and the second spent a 40 stack budget on `_makeSureIsOnAScreen` before the call
  being hunted happened once.
- Picking the backtrace slot for "the caller" by a single index is wrong: inlining moves it. Check
  slots one and two.
- `grep` for lowercase `dead` does not match `display=DEAD`, and that alone made a reporter that
  worked look silent for several runs.
- GNU `nm` cannot read a Mach-O universal binary and says only "file format not recognized". Use
  `llvm-objdump --macho`, and note that `--macho` IGNORES `--start-address`; extract the thin slice
  from the fat header first, then ordinary `--disassemble --start-address` works.

## RESOLVED: Command comma opens the Preferences window

Three defects sat between Command comma and a window, each hidden behind the one in front of it.
All three are ours, all three are fixed, and the window is on screen.

| # | defect | where | patch |
|---|--------|-------|-------|
| 1 | `dataWithContentsOfFile:` RAISES on a path that will not convert, instead of answering nil | `NSData.m` | foundation 0085 |
| 2 | `NSView` answers none of the four gesture recognizer methods, though the classes exist | `NSView.m` | cocotron 0089 |
| 3 | `+[NSString availableStringEncodings]` returns nil where the contract is a zero terminated array | `NSString.m` | foundation 0086 |

### The walk, measured at each step

`CIDER_TRACE_NIB` counts the awake list of `PreferencePanel.nib`, which holds 3104 objects:

| state | last object reached | how it ended |
|---|---|---|
| before any fix | **811** `ProfilesGeneralPreferencesViewController` | NSInvalidArgumentException, cannot create data from nil url |
| fix 1 only | **811** | unrecognized selector `addGestureRecognizer:` |
| fixes 1 and 2 | **922** `ProfilesTerminalPreferencesViewController` | SIGSEGV, reported by the harness as `cider-app exit=0` |
| all three | **3103 of 3104** | completes |

Each fix made the next defect reachable for the first time, which is the pattern this document has
now seen four times. Two of the three were invisible by construction: a raise inside a nib decode
is caught, and a guest SIGSEGV is reported as a clean exit.

### The window

```
CIDER_WC PreferencePanel loadNibFile leave
CIDER_WC PreferencePanel windowDidLoad
CIDER_WC PreferencePanel done
CIDER_DOC showWindow ENTER      controller=PreferencePanel
CIDER_DOC showWindow HAVE-WINDOW controller=PreferencePanel window=0x75dc83e25cb0
CIDER_DOC showWindow ORDERED    controller=PreferencePanel
```

`-[PreferencePanel run]` reaches `showWindow:` and the capture shows the Settings window with its
title bar, all eight toolbar items (General, Appearance, Profiles, Keys, Arrangements, Pointer,
Shortcuts, Advanced) and the full tab row (Startup, Closing, Magic, AI, Software Update, Selection,
Window, Settings, tmux).

**What is still wrong:** the window is far too short. The tab row is there and the pane below it is
collapsed to nothing, so no setting is visible or reachable. That is the same shape as the
MoneyMoney Preferences pane that never resizes, and the two should be looked at together rather
than separately. RENDERS is met, INTERACTIVE and RESIZABLE are not yet demonstrated for this
window.

### How the crash was named, since it reports as a clean exit

`ciderd.log` carries `sigexc: handler (11)` and the register dump. The tail of that dump is RIP,
EFLAGS, then CS and SS, so `0x1006D9EDD` next to `0x10246` is the faulting address. Subtracting the
image base and looking it up in the symbol table of the thin slice names it outright:

```
RIP 0x1006D9EDD -> -[ProfilesTerminalPreferencesViewController sortedEncodings] +0x42
```

and at +0x42 the instruction is `movq (%rax), %rdx` on the result of a class method send, which is
the walk of a zero terminated array. The selector at that send resolves to `availableStringEncodings`.

## The window is too short, and the port is not the one choosing that size

Measured first, because "the window is the wrong size" has two opposite causes. The setFrame trace
now prints both rects (cocotron patch 0090):

```
CIDER_WIN setFrame iTermPrefsPanel asked=924x539@332,-54  got=924x539@332,-54
CIDER_WIN setFrame iTermPrefsPanel asked=689x141@332,344  got=689x141@332,344
```

The panel opens at its nib size and **the application then asks for 689x141**. Every `asked` equals
its `got`, so `setFrame` is faithful and the number is computed upstream. Nothing here is a frame
we mangled.

### Where 141 comes from

`-[PreferencePanel resizeWindowForTabViewItem:animated:]` leads to
`-[iTermPreferencesBaseViewController resizeWindowForCurrentTabAnimated:]`, whose selectors resolve
to `tabView`, `selectedTabViewItem`, `view`, `subviews`, `firstObject`,
`resizeWindowForView:tabView:animated:`. It sizes the window to the FIRST SUBVIEW of the selected
tab page. `CIDER_TRACE_VIEWS` says what that is:

```
NSTabView              648x36 at 8,22
  NSView               644x8  at 2,2
    NSCustomView       0x0 at 0,0 mask=0x0 hidden=0 translates=0 cons=0
```

The pane is **zero by zero**, and the window is exactly as tall as the chrome around it.

### What is known about that view, so the next attempt does not redo it

- It is the ONLY view in the whole panel with `translates=0`. Every other one is 1.
- It holds **no constraints**, and the Preferences nib builds **4210 objects with not one
  NSLayoutConstraint among them**, so nothing in that nib uses auto layout at all.
- `+[NSLayoutConstraint constraintsWithVisualFormat:options:metrics:views:]` IS implemented, in
  Foundation `NSLayoutConstraint.m`. It was checked before being suspected.
- iTerm2 does reference `addConstraint:`, `addConstraints:`, `activateConstraints:` and
  `constraintEqualToAnchor:`, so it may be building constraints in code rather than in the nib.
- `iTermSizeRememberingView` and `resetToOriginalSize` are iTerm2 machinery in the same chain and
  the remembered size is captured from the nib, so a pane that decoded small stays small.

A view with `translates=0` and no constraints can only be sized by someone setting its frame, and
on this path nobody does. Whether the flag itself is decoded correctly is the first thing to test:
in a nib with no constraints anywhere, macOS would leave such a view translating its mask.

This is the same shape as the MoneyMoney Preferences pane that never resizes. Take the two together.

### Six explanations for the zero sized pane, all refuted by measurement

The pane is `NSCustomView 0x0 at 0,0 mask=0x0 translates=0 cons=0`, and the window is exactly as
tall as the chrome around it. Each of these was checked rather than argued, and each is now closed:

| candidate | what was measured | verdict |
|---|---|---|
| the nib gives the placeholder no size | 104 placeholders decode, every one a real class at a real size, 525x279 up to 922x420 | refuted |
| something sizes it later and we drop that | `NSCustomView` gets `setFrame:`/`setFrameSize:` **zero** times in a whole run | it is never sized, by anyone |
| the frame trace is simply dead | same trace widened to any class containing View prints **1360** events across twelve classes in the same run | the instrument speaks |
| a class in the nib does not resolve | `CIDER_NIB archive NO CLASS` never fires; the `NSCustomView unknown class` log never fires, with 479 other NSLog lines in the capture | every class resolves |
| we turn off `translatesAutoresizingMaskIntoConstraints` | both assignments in `NSView.m` set it to **YES**, and the decode has a `// TODO: decode this` above it | the application turns it off |
| it is a plain `alloc`/`init` | `-[NSView init]` gives **1x1**, not 0x0 | refuted |
| iTerm2 sizes it by constraints we drop | `cons=0` on every view in the panel; the nib builds 4210 objects with **no** NSLayoutConstraint; `setActive:` correctly calls `addConstraint:`; only 11 visual format strings exist in the binary and none is for this pane | no constraints are ever created |

What that leaves is precise: the pane carries the **zero initialised ivars of a bare alloc** (frame
zero, mask zero, translates NO, no subviews). Every path in this framework that builds a view from
an archive sets at least one of those, and none of them ran for this object. Finding who allocates
it is the next step, and `CIDER_TRACE_CUSTOMVIEW` plus `CIDER_TRACE_SVFRAME` (cocotron patch 0091)
are the instruments to do it with.

Worth noting for whoever picks this up: `-[NSCustomView initWithCoder:]` never calls
`[super initWithCoder:]` on its keyed path, which is why a trace added to `-[NSView initWithCoder:]`
reports nothing for this class. That cost a build to learn.

## SOLVED: the pane was the bare placeholder, and the swap was never announced

The seventh candidate was the right one, and it was proven by pointer rather than argued.

`-[NSCustomView initWithCoder:]` returns a DIFFERENT object from the one the unarchiver allocated.
The unarchiver stores that raw allocation in its table BEFORE calling it, deliberately, so a cycle
terminates. Anything resolving that reference while the method is still running gets the bare
`NSCustomView`, and because the method never calls `[super initWithCoder:]`, that object has
nothing at all: frame zero, mask zero, `translates` NO, no subviews. Every symptom in the table
above falls out of that one fact.

The two pointers are the proof:

```
CIDER_CUSTOMVIEW name=iTermPreferencesInnerTabContainerView self=0x7128abd28120 new=0x7128abd28430
CIDER_VIEW       NSCustomView(0x7128abd28120) 0x0 at 0,0 mask=0x0 translates=0 cons=0
```

The object wired into the view tree IS the placeholder `self`. The real pane at `…430` was built
and thrown away.

The fix (cocotron patch 0092) is one call, `[coder replaceObject: self withObject: newView]`, placed
**before** the `NSSubviews` decode, because that decode is where the re-entrant reference is taken.
`-[NSClassSwapper initWithCoder:]` is the only other caller and does the same thing for the same
reason, and the unarchiver already expects a slot that no longer holds what it allocated: the
branch reading `inSlot != instance && inSlot == initialised` is written for exactly this.

| | before | after |
|---|---|---|
| tab page | `NSView 644x8` | `NSView 644x151` |
| pane | `NSCustomView 0x0`, no children | `iTermPreferencesInnerTabContainerView 569x143`, five controls |
| window | 689x141 | 689x284 |

The General to Startup pane now draws its "Window restoration policy" label, its popup button and
its three checkboxes.

This is a nib decode change, so it reaches every application. Gates after it: roster sweep 7 of 7
and roster input 7 of 7, with byte identical captures to the run before it, and Swift Publisher,
MoneyMoney, iA Writer, LibreOffice and CMake looked at individually.

**What remains for this window:** it is still shorter than a Mac would draw it, so panes with more
content than Startup will clip, and INTERACTIVE and RESIZABLE are still not demonstrated for the
Settings window itself. The next step is to click a toolbar item and a tab and see whether the pane
swaps and the window resizes with it.

## The Settings window meets all three criteria, and one defect is left

Driven with Command comma, then a click on the Appearance toolbar item, then one on Profiles:

| step | window asked for | what the capture shows |
|---|---|---|
| Command comma | 689x284 | General to Startup: restoration policy popup, three checkboxes |
| click Appearance | 689x299 | pane swaps |
| click Profiles | **1060x588** | profile list with Default selected, the eight tab row, and the full form |

The Profiles pane draws Name, Shortcut key, Tags, Badge, Title with its "Applications in terminal
may change the title" checkbox ticked, Subtitle, Icon, Command set to Login Shell and /bin/zsh,
Send text at start, and Initial directory with Home directory selected.

- **RENDERS CORRECTLY**: yes, looked at.
- **INTERACTIVE**: yes, a toolbar click swaps the pane.
- **RESIZABLE**: yes, and the application resizes the window itself for each pane, `asked` equal to
  `got` every time.

### The one defect left: a window that grows is not moved back onto the screen

At 1060 wide from x=332 the window runs to 1392 on a 1256 wide screen and the capture is clipped on
the right, losing the right hand column of every field. The application asked for that frame and we
gave it exactly, so this is not a frame we mangled; what is missing is the step that keeps a window
on screen after it changes size.

`-[NSWindow _makeSureIsOnAScreen]` exists and the event loop calls it on every pass (it is one of
the two pollers the `CIDER_TRACE_VISIBLE` filter had to skip), so the question is why it does not
move this one. That is the next thing to measure, and it is a general defect rather than an iTerm2
one: any window that grows near a screen edge will be clipped the same way.

### CORRECTION: the clipping is the output size, not a missing constrain step

The section above called the right hand clipping a defect and named
`-[NSWindow _makeSureIsOnAScreen]` as the thing that should have prevented it. **That is wrong and
it is withdrawn.**

Driven identically on a 1600x1000 output, the Profiles pane renders COMPLETELY: the profile list,
the eight tab row, and every field including Badge with its Edit button, Subtitle with Enable Tall
Tab Bar, Icon, Command, Send text at start, all four Initial directory options with
`/Users/root`, URL schemes, and the Tags, plus, minus and Other Actions footer. Nothing is cut off.

What gave it away is that the frame cannot explain the picture. The last frame in that run is
`1060x588@676,-103`, and no later frame moves it. Read as a screen position that puts the window
past the right edge and 103 points below the bottom, yet the capture shows it whole and roughly
centred.

**A Wayland client does not position its own toplevel.** There is no request for it in the
protocol; the compositor places the surface. So the origin in an NSWindow frame reaches nothing,
only the SIZE is honoured, and reasoning from that origin to where the window will appear is
reasoning about a number nobody reads. Every earlier line in this document that treats a window
origin as a screen position is suspect for the same reason.

The 1256x684 clipping is therefore just an output too small for a 1060x588 window placed where the
compositor put it. It is a property of the test harness, not of the port, and it is the second
time in this document that a harness property was mistaken for a defect. The first was the event
loop spin.

**Status of the Settings window: all three criteria met, with no known defect.**

## The MoneyMoney Preferences pane is fixed too, by the same patch

This document refers three times to "the MoneyMoney Preferences pane that never resizes" as the
same shape as the iTerm2 one, and says to take the two together. Taking them together is now the
answer: the premise changed when cocotron 0092 landed, so the measurement was re-taken.

Driven with Command comma on a 1600x1000 output, MoneyMoney Preferences renders correctly:

- the toolbar shows General, Security, Payments, PSD2 and Extensions, each with its icon above its
  label, and **no label overlap**;
- the pane below is properly sized and draws all of its content: four checkboxes, the Language
  popup set to English, the new version notification checkbox and its nested beta test checkbox.

That is the same defect and the same fix. `-[NSCustomView initWithCoder:]` never announced that it
had replaced itself, so any reference resolved during the decode kept the bare placeholder with a
zero frame; both applications build their preference panes out of custom view placeholders, so both
lost them the same way.

Two items this document has carried are therefore closed by one patch, and the honest lesson is
that they should have been treated as one defect the first time the phrase "the same shape as"
was written down three times without anyone testing it.

## A preferences sweep across the roster, and what it found

With cocotron 0092 landed, Preferences is a path most of the roster had never been driven down, so
Command comma was sent to iA Writer, Swift Publisher and CMake on a 1600x1000 output.

| app | result |
|---|---|
| Swift Publisher | Preferences opens and lays out correctly, but a radio group drew TWO filled dots |
| iA Writer | Preferences opens with its nine item toolbar and full General pane, but two label rows are drawn on top of each other |
| CMake | nothing, and correctly so: it is Qt and Command comma is not its Preferences shortcut |

### The radio group: every nib loaded matrix had lost its mode and all its flags

`-[NSMatrix initWithCoder:]` decodes `NSMatrixFlags` into a local in its KEYED branch, and the code
that INTERPRETS that local sits inside the non keyed `else` branch, together with the selected cell
normalisation. For every modern nib none of it runs, so a matrix keeps the zeros from `alloc` for
`_mode`, `_allowsEmptySelection`, `_autosizesCells`, `_drawsBackground`, `_drawsCellBackground`,
`_selectionByRect`, `_isAutoscroll`, `_tabKeyTraversesCells` and `_selectedIndex`, and
`-selectCell:` is never called.

**The zero that `_mode` keeps happens to equal `NSRadioModeMatrix`**, which is why this hid: every
matrix in every application has been in radio mode by accident, so a real radio group looked right
while track and list mode ones did not.

```
before   [0] state=1 Template Gallery   [1] state=1 Blank Document   [2] state=0 Radio
after    [0] state=1 Template Gallery   [1] state=0 Blank Document   [2] state=0 Radio
```

and the decode now reports real modes where every matrix used to report the same accidental zero:
`mode=0` radio, `mode=1` highlight, `mode=3` track. cocotron patch 0093.

### How it was cornered, because the instrument kept not reaching

Worth recording, since four builds went into aiming it:

1. A spy on the matrix said `selectedCell index=0` while the picture showed two dots. That cannot
   separate a state defect from a drawing one, so a cell list dump was added at draw time. It said
   two cells really did hold `state=1`.
2. A `setState:` trace with a backtrace then showed those two cells are **never sent setState at
   all**, while `US`/`Metric` in the same window are correctly driven through `_deselectAllCells`.
   That moved the suspicion from the application to the decode.
3. A trace inside the keyed branch printed NOTHING, with the string proven present in the built
   binary, while an entry trace ABOVE the branch fired seven times with `coder=NSKeyedUnarchiver
   keyed=1`. A trace inside a branch cannot tell a branch not taken from a method not called; the
   one above it can.
4. Six checkpoints through the decode all fired, and the one after them did not, which put the
   boundary exactly at the `} else {`.

Two instrument traps met on the way: `TRACE_ENV` is injected into an `env` command line, so a value
containing a space (`CIDER_TRACE_CELLSTATE=Blank Document`) silently breaks the launch; and a
budgeted trace spent its whole allowance on a 33 cell gallery of untitled cells before the two
cells being hunted were touched once, so the budget had to skip untitled cells.
