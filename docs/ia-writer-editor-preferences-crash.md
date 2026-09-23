# iA Writer Preferences, Editor pane: a segfault in O2ColorSpaceRetain

Found 2026-09-23 while trying to reach the two buttons that cocotron 0138 made reachable. Not
caused by that change, and not previously recorded.

## What happens

Open iA Writer, press Command comma, wait for the General pane, click the Editor item in the pane
toolbar. The process dies with SIGSEGV and the capture goes black.

    DRIVE GUEST FAULTED during this drive, 1 time(s). exit=0 above is NOT a clean run:
    DRIVE   [guest kprintf] sigexc: have RIP 0x701D0F4B1AD4 pid 2 sig 11

`exit=0` is the usual lie here: the drive reports the fault separately.

## Rate, and what is ruled out

**Three of three.** Three separate drives, three SIGSEGVs, and every RIP ends in `AD4`:
`0x74078D21AAD4`, `0x701D0F4B1AD4`, `0x77666DBCEAD4`. Only the image base differs, so it is the
same instruction every time, not a race.

**Not the tree probe.** The first of the three had `CIDER_TRACE_TREE=30` set, and
`CIDER_TRACE_TREE` has killed what it was watching before (it terminated mmex four times out of
four). The two control runs had no trace at all and crashed identically, so the probe is not
involved.

**Not cocotron 0138.** That change only acts on a binding named `target` or `doubleClickTarget`.
`EditorPreferences.nib` has three binding connectors and they are `hidden`, `value` and
`selectedTag`, so the new code returns immediately and never touches this path.

## Where it dies

`scripts/core-guest-stack.py` puts the RIP at `Onyx2D+0x4ad4`, and the nearest preceding symbol is
`_O2ColorSpaceRetain` at `0x4ad0`. So it is four bytes into:

```c
O2ColorSpaceRef O2ColorSpaceRetain(O2ColorSpaceRef self) {
    return (self != NULL) ? (O2ColorSpaceRef) CFRetain(self) : NULL;
}
```

### The caller

Walking the crashing thread stack out of the core gives the return address at `rsp+8`, which is
`Onyx2D+0x31ec`. The nearest preceding symbol is `_O2ColorCreateGenericGray` at `0x31e0`, so the
call is twelve bytes into:

```objc
O2ColorRef O2ColorCreateGenericGray(O2Float gray, O2Float a) {
    return [[O2Color alloc] initWithDeviceGray: gray alpha: a];
}

- initWithDeviceGray: (O2Float) gray alpha: (O2Float) alpha {
    O2Float components[2] = {gray, alpha};
    O2ColorSpaceRef colorSpace = O2ColorSpaceCreateDeviceGray();
    O2ColorInitWithColorSpace(self, colorSpace, components);   /* the retain is in here */
    [colorSpace release];
    return self;
}
```

Both `initWithDeviceGray:alpha:` and `O2ColorInitWithColorSpace` are inlined into
`O2ColorCreateGenericGray`, which is why the call appears to come from there.

### And here the obvious reading BREAKS, which is worth saying rather than hiding

`O2ColorSpaceCreateDeviceGray()` is `[[O2ColorSpace alloc] initWithDeviceGray]` and
`-initWithDeviceGray` only sets two ivars. There is no shared instance and no cache, so the colour
space being retained is freshly allocated on the line above and cannot be a stale pointer. The
over-release reading does not survive contact with the code.

Disassembling makes it worse rather than better. `_O2ColorSpaceRetain` begins:

```
    4ad0:  55              pushq  %rbp
    4ad1:  48 89 e5        movq   %rsp, %rbp
    4ad4:  48 83 ec 10     subq   $0x10, %rsp     <- the reported RIP
    4ad8:  48 89 7d f8     movq   %rdi, -0x8(%rbp)
```

**The instruction at the faulting address touches no memory.** `sub $0x10, %rsp` cannot raise
SIGSEGV on real hardware. The recorded `rsp` is consistent with the two instructions before it
having run (16 byte aligned at a call boundary, minus the 8 of the push), so the machine state and
the fault do not agree.

Nor is it a stack overflow: the `PT_LOAD` holding `rsp` runs `0x7fffff600000` for `0x800000`, and
`rsp` is `0x7fffffdfb130`, about 20 KB below the top of an 8 MB region. The stack is nearly empty,
which also rules out runaway recursion.

What IS established is that it is deterministic and tied to this path: three runs, three faults,
the same offset every time. What is NOT established is which access actually faults. The guest
emulation layer is the remaining suspect for the RIP attribution.

**The next step is an instrument, not more inference:** print the pointer and
`__builtin_return_address(0)` from `O2ColorSpaceRetain` under an environment switch, drive it
again, and read the last line. Ground truth beats another theory here, and two theories have
already died on this one.

## How the click was proved to land on the right item

The pane toolbar frames came from `CIDER_TRACE_TREE` rather than from the capture: ten
`NSToolbarItemView` children of `NSToolbarView`, the fifth at `win 40x56@267,456 top 50..106`, so
the Editor item is window x 267..307. The Preferences window position was measured from the
capture programmatically, not by eye: a row scan at y=90 gives a run exactly 600 pixels wide from
x=200 to x=799, matching the window width, and a column scan puts the in-window menu bar at
y 91..118, which against the tree's `top 22..50` for that view puts the window top at y=69. Editor
centre is therefore output (487, 147).

That the click reached the Editor pane is confirmed by an accidental fingerprint, below: the
no-click run logs 6 of the ABSTRACT lines and the click run logs 15, which is 6 plus the 9 that
`EditorPreferences.nib` contributes.

## A separate, benign defect found on the way

`-[NSNibConnector establishConnection]` is `NSInvalidAbstractInvocation()`, which logs

    cider: ABSTRACT -[NSNibConnector establishConnection] at .../NSNibConnector.m:103

and returns. Modern nibs contain plain `NSNibConnector` objects that are not connections at all.
Every one of them in `EditorPreferences.nib` has a nil destination and this label:

> Encoding NSStackView requires being decoded before other connections with an early decoding
> order priority of 999990.

They are decode ORDERING MARKERS, one per `NSStackView`. Establishing one is meant to do nothing,
and on macOS the base class evidently does nothing, since every application using a stack view
would die otherwise. Here it is only log noise, 6 lines for the General pane and 9 more for the
Editor pane, but the base implementation should be an empty method rather than an abstract one.

Counted in iA Writer alone: `GeneralPreferences.nib` 6, `EditorPreferences.nib` 9,
`CustomPatternsPreferences.nib` 0.

## What this blocks

The two `target` bindings in `CustomPatternsPreferences.nib`, `addPattern:` and `removePattern:`,
are the only `NSControl` cases of the cocotron 0138 fix anywhere in the roster that are safe to
drive, and the Editor pane is the way in. Until this crash is fixed the fix is verified on
`NSMenuItem` only. The other three `NSControl` cases are in MoneyMoney, and two of them are
`purchase:`, which probably leaves the application.

## SOLVED, and the instrument that solved it first had to be fixed

### The instrument was lying, and that is why two theories died

`scripts/core-guest-stack.py` resolved the RIP to `_O2ColorSpaceRetain+4`, and after a rebuild to
`-[O2ColorSpace initWithPattern]+4`. Both were wrong, and both put the fault on an instruction that
touches no memory, which is what should have given it away.

The symbols came from the wrong file. There are two Onyx2D binaries in the tree and only one is
loaded:

    buck-out/.../buck-src/__Onyx2D_dylib__/Onyx2D                       md5 8ead2718   NOT loaded
    buck-out/.../buck/prefix/__cider_prefix__/.../Onyx2D                md5 230e8616   loaded

Passing `buck-src` as a `--root` makes the script resolve to the first one silently. Against the
binary that actually ran, the same offset is a different function entirely.

**A fault attributed to an instruction that cannot fault is a fact about the instrument, not about
the bug.** Two paragraphs were written reconciling the impossible before the md5s were compared.

### The real chain

Against the loaded binary the fault is `_O2ColorSpaceGetModel+4`, and that offset is

    4a54:  8b 47 08   movl 0x8(%rdi), %eax

which is `self->_type`, a load that certainly can fault. The caller, from the stack, is
`+[NSColor colorWithCGColor:]+0x1e`:

```objc
+ (NSColor *) colorWithCGColor: (CGColorRef) cgColor {
    if (cgColor == NULL)
        return nil;

    switch (CGColorSpaceGetModel(CGColorGetColorSpace(cgColor))) {
```

It guards the COLOUR and not its COLOUR SPACE. `CGColorGetColorSpace` answers NULL,
`CGColorSpaceGetModel` is `O2ColorSpaceGetModel`, and that was `return self->_type;` with nothing
in front of it.

### The fix, and what it does not fix

cocotron 0139 makes the three C accessors answer for NULL the way CoreGraphics does:
`O2ColorSpaceGetModel` returns `kCGColorSpaceModelUnknown`, which is -1 and sends the switch above
to its default, `O2ColorSpaceGetNumberOfComponents` returns 0, and `O2ColorSpaceIsPlatformRGB`
returns NO. `O2ColorSpaceGetName` already guarded.

After it the Editor pane opens and renders: text size, typeface, typography, line length limit,
indentation, and the seven highlight colour swatches, which are the colours that needed a colour
space at all. The guards fire 20 times each in one drive, so the NULL is ordinary on that path.

THE CAUSE IS STILL UPSTREAM. Something creates a CGColor with no colour space: `O2ColorCreate` is
reached with a NULL colour space too, at `O2ColorCreate+60`. `CIDER_TRACE_COLORSPACE` prints the
return address of whoever passes NULL, which is how the next person finds it. This change stops an
application dying four layers from the cause; it does not close the cause.

### Two rendering defects now visible on that pane

Only visible because the pane opens at all, neither chased:

- the line length row shows the raw key `Editor_Preferences_Line_Lengt` beside the popup, so a
  localised string is not being looked up
- the `Highlight color:` label sits far above its swatches

## What the pane leads to next: the whole view controller presentation family is absent

With the pane open, the Custom Patterns button is reachable. Its frame came from the tree
(`win 129x23@253,35 top 798..821`) and the window origin from a row scan of the capture that finds
a run exactly 600 wide at x 200..799 and a 28 tall menu band at y 144..171, which against the
tree's `top 22..50` puts the window top at 122. The click at output (517, 931) lands dead on the
button, which the capture shows highlighted.

Nothing opens. The log says why:

    cider: UNRECOGNIZED -[IAEditorPreferencesContentViewController presentViewControllerAsSheet:]

`-[NSViewController presentViewControllerAsSheet:]` does not exist in this AppKit, and neither
does any of its family: `presentViewController:animator:`, `dismissViewController:`,
`presentViewControllerAsModalWindow:`, `presentViewController:asPopoverRelativeToRect:...`.
`grep` for any of them in `NSViewController.m` and its header returns nothing at all.

So the two `target` bindings in `CustomPatternsPreferences.nib`, which are the only `NSControl`
cases of cocotron 0138 in the roster that are safe to drive, are still out of reach: not because
of the binding, and no longer because of the crash, but because the sheet that would carry them
cannot be presented. That family is the next thing to implement if the `NSControl` half of 0138 is
to be exercised at all.

## The sheet now presents, and the remaining defect is between the click and the action

cocotron 0140 implements the presentation family. Same drive, after it: no UNRECOGNIZED, and
window 26 maps at 390x329, which is the 390x307 view of `CustomPatternsPreferences.nib` plus a
title bar. The capture shows the sheet over the Editor pane with its introduction label, an empty
pattern table, the add and remove buttons, and a blue Done.

**The add button still does nothing, and three things rule out the obvious explanations.**

1. **The binding is established and carries its selector.** `CIDER_TRACE_CONTROL` shows
   `target -> ...self.customPatternsTableViewController ... options=NSSelectorName` on both
   buttons, so cocotron 0138 gave them their actions and pointed them at the table controller.
2. **The click lands on the button.** `TRACE_INPUT` shows it arriving at the sheet surface, window
   26, at `x=32 y=298`. The sheet is 390x329 with a 22 point title bar, so that is content y 276
   from the top of a 307 tall view, which is 31 from the bottom, and `addButton` spans 20 to 41.
   Dead centre. The first attempt at `y=666` arrived at content y 48, seven points above the
   button, and that miss is how the offset was measured rather than guessed.
3. **The action is never sent.** `CIDER_TRACE_MSGSEND=IACustomPatterns` prints 207 messages to that
   class over the drive and not one of them is `addPattern:`.

So the sheet is presented, the control is wired, and the click arrives: what fails is between the
click and the action.

### One hypothesis tested and REFUTED

`-[NSWindow _attachSheetContextOrderFrontAndAnimate:]` ends with `[self makeKeyWindow]`, which
makes the PARENT key rather than the sheet. On macOS the sheet takes key, and a control on a
non-key window does not track the mouse, so this looked like the whole answer.

Changed to `[sheet makeKeyWindow]`, rebuilt, re-driven: the capture changes slightly, so the
change is not inert, and `addPattern:` is still never sent. **Reverted**, because a change to the
path every sheet in the roster uses does not earn its place on a hypothesis that did not pay out.
Recorded here so the next reader does not spend the same hour on it.

## CORRECTION: the action DOES fire, and the failure above was my own aim

The section above says the add button sends no action. That is wrong, and the way it went wrong is
worth more than the conclusion was.

`CIDER_TRACE_CONTROL` on a drive clicking output (337, 666):

```
CIDER_CONTROL mouseDown self=0x… class=NSKVONotifying_NSButton title=Add Pattern… enabled=1 frame={{20, 38}, {25, 19}}
CIDER_CONTROL send class=NSKVONotifying_NSButton action=addPattern: target=NSKVONotifying_IACustomPatternsTableViewController enabled=1
```

The button receives the click, is enabled, and sends `addPattern:` to the controller its target
binding names. **That verifies the NSControl half of cocotron 0138 end to end**, which had been
open since the binding fix landed.

**How I talked myself out of a working click.** The nib gives `addButton` the frame
`{{20, 20}, {25, 21}}`. The LAID OUT frame, which `CIDER_CONTROL drawRect` prints, is
`{{20, 38}, {25, 19}}`, eighteen points higher and two shorter. My first click at output y 666
arrived at content y 48, inside the real span of 38 to 57, and was on target all along. I then
measured the arrival with `TRACE_INPUT`, compared it against the NIB frame rather than the live
one, decided it was seven points high, and "corrected" it to y 683, which is content y 31 and
lands BELOW the button. The drive that reported `addPattern:` never sent was that corrected one.

So the rule in memory, never measure a coordinate by eye, has a second half: **a frame from the
archive is not the frame on screen.** Take it from a trace of the running view, which is what
`CIDER_TRACE_TREE` and `CIDER_CONTROL drawRect` are for. An eighteen point error from the nib is
just as wrong as an eighteen point error from the eye, and it cost two drives and one confident
false conclusion.

The two buttons behave correctly in one more respect: `Remove Pattern` is drawn disabled, because
its `enabled` binding reads `canRemovePattern` and the list is empty.

## What is still open on this pane

`addPattern:` fires and no row appears in the table. Whether that is a table view that does not
reload or an add that needs something else has not been measured. The pattern list is still empty
afterwards, so these drives leave no persisted state behind.
