# iA Writer Preferences: the Shortcuts group overlaps, and one fix was withdrawn

The General pane opens from `⌘,` and renders: the toolbar of nine panes, Appearance, Dock icon,
File extensions, the three Window checkboxes, Title bar, Toolbar, Enable URL commands and its
explanation. Two groups are drawn on top of each other: Get Ready Made Shortcuts, its `Shortcuts:`
label, its description and its Manage button all land in the same vertical band as the Title bar and
Toolbar rows.

## What is measured

`CIDER_TRACE_TREE` on the Preferences window, container `NSView 600x456` holding 58 constraints:

    NSTextField 395x16@205,121  measured=910  text: Shortcuts make it easy to get tasks done...
    NSTextField 64x0@133,145    measured=60   text: Shortcuts:
    NSButton   176x23@205,145                 Get Ready Made Shortcuts
    IAAutoResizablePopUpButton 91x22@205,155  Title bar
    IAAutoResizablePopUpButton 91x22@207,118  Toolbar

So a label 64 wide and ZERO high, a description one line tall whose text measures 910 points at a
width of 395, and both sitting between the two popups they collide with.

`CIDER_TRACE_LAYOUT` says why the label is flat. It has no size rule at all; it has a `.top` that
comes down a chain and a `.firstBaseline` pinned to a button:

    p0 ... NSTextField.top = IAAutoResizablePopUpButton.bottom * 1 + 30 -> top = 155
    p0 ... NSTextField.firstBaseline = NSButton.firstBaseline * 1 + 0   -> firstBaseline = 145
    p1 ... top = 153
    p2 ... top = 88
    NSTextField pass=2 {133 145 64 8} -> {133 145 64 0} y[o1 s1 f1 c0]=145,0,88,0

The baseline fixes the origin at 145 and never moves. The far edge comes down a chain of top equals
bottom rules and slides 155, 153, 88 as the popup above it is re-solved. By pass 2 the two edges have
CROSSED, `size = far - origin` is negative, and the frame ends up zero high.

## The fix that was tried and WITHDRAWN

`CiderResolveAxis` computes `size = far - origin` with no sign check. Falling back to the intrinsic
size when that is not positive is defensible on its own terms, and it worked for what it claimed:
the `Shortcuts:` label rendered instead of being invisible.

It also made the iA Writer MAIN window worse. The roster sweep caught it at once:

    ia: CONTENT 29784 bytes  CHANGED from 31129, LOOK AT IT

and the capture shows the Locations sidebar grown from about 247 to 310 wide, pushing the file list
right and CLIPPING the date column: `9`, `9/`, `9/3/` where `9/7/26` and `9/4/26` and `9/3/26` belong.
Some view that was correctly resolving to nothing now takes its intrinsic width. Reverted, and the
baseline re-measured at 31136 unchanged.

**That is the third withdrawal in this solver.** Dependency ordered solving was tried and withdrawn
twice before. The pattern is consistent: a local rule that is right for the case in front of you
changes some other view that was quietly depending on the old answer, and only the byte compared
baselines catch it.

## What a real fix needs

Not another local rule. The crossing is a SYMPTOM of the chain not having converged: the far edge is
read from a neighbour that has not been placed yet in that pass. Either the passes must run until
the chain is stable rather than a fixed eight, or an axis whose inputs moved during the pass must be
re-solved rather than committed. Both are changes to how the solver is driven, and either needs the
whole roster measured, not one window.

## Also seen, and not caused by any of this

One `run-dts-batch.sh` in this series reported 68 of 69 with

    133 System_Library_Frameworks_Security_framework_test_test_SecTrustEvaluateWithError

Exit 133 is SIGTRAP, the case is in the Security framework, and the only change in the tree was in
the AppKit constraint solver. An immediate re-run gave 69 of 69. That is the SECOND time this batch
has produced a one off failure in a case unrelated to the change under test (the first was a SIGFPE
inside libsystem_malloc during dyld init in a CoreGraphics only case). Recorded rather than hidden:
a single red case in this batch is worth re-running before it is believed.

## A separate defect on the same window, characterised and not fixed

Showing the Library again leaves GHOST TEXT: every sidebar label drawn twice, about seven points
apart, Locations at y 94 and again at 101, Favorites at 131 and 139. The end of run resize forces a
full repaint and it comes back clean, so it is incremental repaint residue rather than a layout
error, and a fresh launch is clean too.

It only happens ONE WAY. Driving Hide Library and then Show Library inside a single process is
clean: the sidebar returns with every label drawn once. The ghost appears when the library was
hidden AT LAUNCH (iA Writer persists the setting) and is then shown, which is a different path,
because the sidebar was never laid out at full size in that process. What has not been measured is
which rect was invalidated when the pane came back.
