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
