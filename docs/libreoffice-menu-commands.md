# Menu commands: three defects between a click and an action

(The file is named after LibreOffice because that is where the thread started. It now covers
LibreOffice, iA Writer and MoneyMoney, because each application found a different one of the three.)


Driven on the Writer document window at the roster size. The end state, measured:

    CIDER_MENU track item=Insert Table… enabled=1 action=menuItemTriggered: target=SalNSMenuItem
    CIDER_MENU trackDone on NSMainMenuView item=Insert Table…

and the Insert Table dialog opens, and its Insert button puts a 2x2 table on the page with the
cursor in `Table1:A1` and the Table toolbar along the bottom. Before this, no menu command in
LibreOffice could be invoked at all, by mouse or by keyboard.

## The menus themselves were always right

The Table menu opens complete and with correct state: `Insert Table…` with its `⌘F12`, the Insert,
Delete, Select and Size submenus with their arrows, then Merge Cells, Split Cells…, Merge Table,
Split Table…, Protect Cells, Unprotect Cells, AutoFormat Styles…, Number Format…, Header Rows
Repeat Across Pages, Row to Break Across Pages and Sort… all GREYED because no table is selected,
and Number Recognition, Convert and Edit Formula black because they do not need one. That is real
enablement read from the application, not a flat list.

## The defect: tracking judged the event BEFORE the one it had just hit tested

`-[NSMenuView trackForEvent:]` runs one pass per event, and the pass was built in this order:

1. hit test the event, select the item under the pointer, open or close submenus
2. release the event, redisplay
3. **fetch the next event**, blocking
4. decide what the fetched event means, using the view and the selection from step 1

Step 4 therefore judged an event against the selection the PREVIOUS event had established. That is
invisible while the pointer is being dragged, because the stream of mouse-moved events keeps the
selection one step ahead of the release. It is fatal for a plain click: press and release arrive
back to back with no motion between them, so the selection has never moved to the item being
clicked.

Two symptoms came out of that one cause:

- The release over the bar item was judged with a stack of exactly 2 (the bar plus the submenu that
  had just opened), so the `[viewStack count] <= 2` arm ended tracking and returned the BAR item.
  LibreOffice received the action of `Table` for every item in the Table menu. A menu bar menu could
  never be sticky.
- After the first fix that kept a parent open, the release over `Insert Table…` was judged against
  that same stale bar item, which has a submenu, so tracking stayed open forever instead.

## The fix, cocotron 0123

Three changes to `trackForEvent:`, all about ordering:

- The decision moves to sit immediately after the hit test of the SAME event, before the fetch. The
  `count--` compensation for the keyboard path moves with it.
- A release over an item that owns a submenu leaves the menu open rather than ending tracking. That
  is how a menu becomes sticky, and the click after it is what chooses.
- The loop breaks as soon as the decision is `STATE_EXIT`. The `while` test is past the blocking
  fetch, so deciding early and running on meant blocking for an event that would never come. This
  one only appeared after the reorder, and it looked exactly like the original hang.

## What was ruled out on the way, and one claim withdrawn

`-[SalFrameWindow sendEvent:] unimplemented` appears twice every half second and looks like the
obvious culprit. It is not. The type is 15, `NSApplicationDefined`: an application posting to itself
to wake its own loop, 119 times in one drive. cocotron 0121 handles that case and names the type for
anything genuinely unknown.

**Withdrawn:** an earlier reading of the `cider-appmouse` probe said LibreOffice loses every click
into an open menu, because the backend reported 8 button events for window 8 while
`-[NSApplication sendEvent:]` saw 4. That was wrong. A tracking loop reads its own events straight
out of the queue with `nextEventMatchingMask:`, so a click into an open menu is SUPPOSED to bypass
`-[NSApplication sendEvent:]`. Nothing was being dropped.

**Withdrawn:** the tracking loop was said not to process the second click's mouse up. It did. The
loop fetches with a mask of `0x2464`, which has no `NSLeftMouseDown` bit in it, so it never sees a
press at all and the one hit test per click IS the release.

## Driving it reproducibly

The Start Center click that opens Writer is position dependent and the window resizes during
startup. At 1000x600 after a 40 step settle, `Writer Document` is at `100,189`;  `100,273` lands on
`Impress Presentation` and gives you the template picker instead. Full sequence:

    wait:40 click:100,189 wait:45 click:393,35 wait:20 click:428,16 wait:30 shot:dialog
    click:685,518 wait:30 shot:tableinserted

## What this unblocks, and the control

Every menu driven command in every AppKit application on the roster goes through this one loop.

**Money Manager Ex is the regression control and it passes.** Tools then Date Range Manager, driven
after the change:

    CIDER_MENU track item=Date Range Manager… enabled=1 action=clickedAction: target=wxNSMenuItem
    CIDER_MENU trackDone on NSMainMenuView item=Date Range Manager…

and Manage checking date ranges opens with all thirty ranges. The Tools menu also stays open after
the click that opens it, which is the new sticky behaviour, and `CIDER_MENU submenuNow index=3
branch=yes` shows the stack does reach 2 there just as it does in LibreOffice.

**Why that command worked BEFORE the fix is not explained here, and no explanation is offered.** An
earlier draft of this file claimed wx opened it from a menu whose stack was 1 rather than 2. The
trace above refutes that outright. Deciding it would mean rebuilding the old tree and driving it
again, which has not been done, so it is left open rather than guessed at a second time.

iA Writer, Swift Publisher, MoneyMoney, iTerm2, LibreOffice, Money Manager Ex and CMake all pass
roster-input after the change, with every capture looked at.

## And driving iA Writer found a second, independent defect

With 0123 in place the first native AppKit menu command driven was iA Writer, View then Hide
Library. It chose a SEPARATOR:

    CIDER_MENU stack depth=2 [0 NSMainMenuView sel=5] [1 NSSubmenuView sel=0]
    CIDER_MENU track item=(null) enabled=1 action=none target=nil

`item=(null)` with `enabled=1` is the tell. The item was not nil; it had a nil title, no action and
no target, which is a separator that also reports itself enabled.

The probe that settled it printed both arrays:

    CIDER_MENU atSelected NSSubmenuView sel=0 visible=23 menu=View all=26
    CIDER_MENU   visible[0] title=(nil) sep=1 hidden=0 action=none
    CIDER_MENU   visible[1] title=Hide Library sep=0 hidden=0 action=toggleLibrary:
    CIDER_MENU row[0] y=3.0..27.0 h=24.0 flipped=1 point=26.0 title=Enable Dark Mode

Twenty six items in the menu, twenty three visible. `-drawRect:` and the sizing walk
`-visibleItemArray`; `-itemIndexAtPoint:` and `-rectOfItemAtIndex:` walked `[[self menu] itemArray]`.
So a HIDDEN item did two things at once: it took a 24 point band at the top of the menu that is
never painted, and it shifted every index after it into a different array than
`-itemAtSelectedIndex` reads. iA Writer hides `Enable Dark Mode` at the head of its View menu, so a
click on the first drawn row landed in the invisible row above it.

cocotron 0124 walks `-visibleItemArray` in all three. After it:

    CIDER_MENU stack depth=2 [0 NSMainMenuView sel=5] [1 NSSubmenuView sel=1]
    CIDER_MENU track item=Hide Library enabled=1 action=toggleLibrary: target=nil

**This one needed no hidden item to be visible in the capture.** The menu drew correctly the whole
time. Only the mapping from a point back to an item was wrong, and nothing on screen said so.

## The action fires, and the proof arrived as a failing gate

`toggleLibrary:` with a nil target goes to `-[NSApplication sendAction:to:from:]`, which walks the
key window responder chain, the main window chain, the current document, NSApp, the application
delegate and the document controller.

**A claim made here first and withdrawn within the hour:** that the action was dispatched and
nothing happened, because the Locations pane was still in the shot taken thirty steps after the
click. It was not nothing. The very next roster sweep reported

    ia: CONTENT 10064 bytes  captures/sweep-ia/d1-start.png   CHANGED from 31129, LOOK AT IT

and the capture is iA Writer with the library GONE: no Locations pane, no file list. The command had
worked, iA Writer had persisted the hidden library, and the fresh launch came up without it. The
shot right after the click was simply taken before the window redrew.

So the lesson is the one about instruments again, in a new shape: **a shot taken n steps after an
action bounds how long the effect may take, and nothing more.** The state that outlives the process
is the stronger witness, and here it arrived as a baseline regression on an unrelated gate.

It also means a drive that invokes a real command can move a roster baseline, because these
applications remember what was done to them. The library was toggled back and the sweep re-measured
before anything was committed.

## Two things left open by this thread

**The show path leaves ghost text.** Driving View then Show Library back on works, and the sidebar
returns live this time, but every label is drawn TWICE, offset by about seven points: Locations at
y=94 and again at y=101, Favorites at 131 and 139, and so on. The control is free and decisive: the
end of run resize forces a full repaint and the sidebar is drawn once. So this is incremental
repaint residue, not a layout error, and a fresh launch is clean too (the sweep re-measured at 31136
unchanged). What has NOT been measured is which rect was invalidated when the pane came back.

**NSMainMenuView has the same two arrays as NSSubmenuView and has not been unified.** Its
`-drawRect:` and its geometry both walk `[[self menu] itemArray]`, so they agree with each other,
but the inherited `-itemAtSelectedIndex` reads `-visibleItemArray`. That is the identical defect
0124 fixed one level down, waiting for a menu BAR with a hidden item in it. No roster application
has one: iA Writer measured `all=10 visible=10`. It is left alone deliberately, because fixing it
means moving the drawing as well as the hit test, and nothing available can show the difference.

## The third defect: a cached rect belongs to the view it was measured in

Found by driving a THIRD application. MoneyMoney, application menu then About MoneyMoney:

    CIDER_MENU check NSSubmenuView#4 windowframe=196x395@0,157 point=76,15 bounds=196x395 inside=1
    CIDER_MENU stack depth=2 [0 NSMainMenuView sel=0] [1 NSSubmenuView sel=9223372036854775807]
    CIDER_MENU track item=nil enabled=-1 action=none target=nil

The release landed inside the menu and selected NOTHING. `-itemIndexAtPoint:` was never reached.

The tracking loop caches the rect of the item it last hit, to skip the lookup while the pointer
stays in the same row:

    if (NSMouseInRect(checkPoint, lastRect, [self isFlipped]))
        break;

`lastRect` is in the coordinate space of whichever view produced it, and `checkPoint` is in the
space of whichever view is being tested now. When the two are different views the comparison is
meaningless, and it silently means yes whenever the numbers happen to overlap.

That is why the APPLICATION menu is the one that broke. It is the leftmost item in the bar, so its
rect starts at x 0 and is about 108 points wide and 28 tall. The point in its own open menu was
(76,15), which is inside that. `View` in iA Writer sits at x 275 and `Table` in LibreOffice at
x 369, so their bar rects contain nothing near the left edge of the menus they open, and both
worked by luck of position.

cocotron 0125 remembers which view the rect came from and only trusts it for that view, and tests
with `[checkView isFlipped]` rather than the tracking view's. After it:

    CIDER_MENU stack depth=2 [0 NSMainMenuView sel=0] [1 NSSubmenuView sel=0]
    CIDER_MENU track item=About MoneyMoney enabled=1 action=none target=NSKVONotifying_AboutWindowController

**Three applications, three different defects, all between the click and the action.** None of them
was visible in a capture: every menu drew correctly throughout.

## Swift Publisher confirms the fix on a second leftmost bar item

Swift Publisher 5 was driven next precisely because its application menu is also the leftmost item,
the case 0125 fixed. It works end to end:

    CIDER_MENU mouseDown on NSMainMenuView at 62,13 bounds=1000x28 items=9
    CIDER_MENU submenuNow index=0 branch=yes
    CIDER_MENU track item=About Swift Publisher 5 enabled=1 action=aboutWindow: target=nil

and the About panel renders: the application icon, Swift Publisher 5, Version 5.7.8 (v4827) and the
BeLight copyright line, in a rounded floating panel with its shadow. Four applications now invoke
menu commands: LibreOffice, Money Manager Ex, iA Writer and Swift Publisher.

**WITHDRAWN, and it cost four drives.** Swift Publisher was first reported here as an application
whose menu bar receives no clicks at all, because clicking at capture y 17 produced no `mouseDown`
while clicks elsewhere in the same window worked. That was wrong, and so was the oversize window
theory built on top of it. The bar is simply NOT at y 17. Its own trace said so all along:

    CIDER_MENU bar drawRect ... inwindow=1000x28@0,568      window height 618

which places it at capture rows 22 to 50. A click at y 35 opens it every time. The y 17 came from
reading the text position off the rendered image by eye, and the estimate was 18 points high.

**Never take a coordinate off a capture by eye when a trace can give it exactly.** The frame is in
the log; the picture is for deciding whether something looks right, not for measuring where it is.

## Still open: an item with a target and no action

`About MoneyMoney` above ends with `action=none` and a real target. `-[NSMenuView mouseDown:]` then
calls `[NSApp sendAction: NULL to: target from: item]`, which does nothing, and no About window
appears. This is not the tracking loop: tracking now returns exactly the right item.

Of the 93 MoneyMoney menu items the `CIDER_MENUITEM` trace covers, NONE has a null action, and one
carries `makeKeyAndOrderFront:` with a window controller target, which is what About wants. So the
selector exists somewhere in the nib and did not reach this item.

Swift Publisher sharpens it into a contrast worth keeping: its About carries
`action=aboutWindow: target=nil` and works, MoneyMoney carries `action=none` and a REAL target and
does nothing.

Four hypotheses were put to it, with the instruments cocotron 0126 adds. All four are refuted, and
the answer is not yet known.

**1. The decoder loses the NSAction key.** Refuted. `CIDER_TRACE_NIB` now dumps the keys a menu item
carries, and the About item carries exactly nine:

    CIDER_NIB container 16 NSMenuItem values=9 at=381 of 7934
    CIDER_NIB   itemkey NSMenu kind=10
    CIDER_NIB   itemkey NSAllowsKeyEquivalentLocalization kind=5
    CIDER_NIB   itemkey NSAllowsKeyEquivalentMirroring kind=5
    CIDER_NIB   itemkey NSTitle kind=10
    CIDER_NIB   itemkey NSKeyEquiv kind=10
    CIDER_NIB   itemkey NSMnemonicLoc kind=2
    CIDER_NIB   itemkey NSOnImage kind=10
    CIDER_NIB   itemkey NSMixedImage kind=10
    CIDER_NIB   itemkey NSHiddenInRepresentation kind=4

There is no `NSAction` and no `NSTarget` in the archive at all. Across the whole MainMenu, only 17 of
146 items carry an action key, and all 17 are `submenuAction:` on a submenu parent.

**2. A control connector carries it and did not run.** Refuted. `CIDER_CONNECT` prints every
connection by kind with the source and its title. There are 105 control connectors, 81 of them with
an `NSMenuItem` source, and exactly 81 `setAction:` calls land on menu items. Every connector that
exists ran. None of them names About, Imprint, Help and FAQ, Report an Issue or Show Database in
Finder.

**3. The application sets it at runtime.** Refuted. `CIDER_ITEMSET` traces both setters. The About
item receives `setTarget: nil` during decode and `setTarget: AboutWindowController` later, and
`setAction:` is NEVER called on it. The late write comes in a burst with Help and FAQ, Report an
Issue, Show Database in Finder and Supported Banks, all re-targeted to `MainWindowController`, with
no connector firing anywhere near it. That is the shape of an application loop that re-targets items
whose action it already expects to be there.

**4. A menu delegate fills the items in lazily.** Refuted. `CIDER_MENUUPDATE` now prints the
delegate and which of the three population selectors it answers:

    CIDER_MENUUPDATE MoneyMoney items=20 autoenables=1 delegate=NSKVONotifying_MainWindowController needsUpdate=0 count=0 updateItem=0

The delegate is real and implements none of them. (Worth keeping anyway: `-[NSMenu update]` calls
`menuNeedsUpdate:` and never the `numberOfItemsInMenu:` plus `menu:updateItem:atIndex:shouldCancel:`
pair, so an application that populates a menu that way would get nothing. No roster application does,
so that gap is recorded rather than filled.)

So a group of about eighteen MoneyMoney items have no action from the archive, no action from a
connector, no action from the application and no delegate to supply one, and on a Mac they work.
Something supplies that selector and this port has not found it. The next candidate is the
application binary itself: disassemble the re-targeting loop and see what it reads before it writes
the target.

## iTerm2 is the fifth, and its About window was a crash

Two corrections first, both mine, both from this one application.

**`LAUNCHD` unset is launchd OFF, not ON.** `app-drive.sh` reads
`CIDER_NO_LAUNCHD="${LAUNCHD:-1}"`, so omitting the variable disables launchd. iTerm2 needs it, so
three drives in a row came back with the Session Ended warning and I blamed, in order, the size of
the guest environment (refuted: the dialog appears without `TRACE_ENV` too) and a targeted container
kill versus roster-input global reap (refuted: the dialog appears after a global reap too). The
roster row passes `0` explicitly and that is why the gate has always worked. `LAUNCHD=0` fixes it.

**That dialog blocking the menu bar is correct, and dismissing it quits the application.** Clicking
OK closes the last window and iTerm2 exits 0. A black capture after that is an application that
ended, not a fault.

With launchd on, the application menu opens complete: About iTerm2, Show Tip of the Day, Check for
Updates…, Toggle Debug Logging, Copy Performance Stats, Preferences… ⌘,, Services, the three hide
items, Secure Keyboard Entry ⌥⌘S, the two default-term items with their four-modifier equivalents,
Install Shell Integration, Remove Recent Profiles from Dock Menu and Quit iTerm2 ⌘Q.

And choosing About killed the application:

    cider: UNRECOGNIZED -[NSTextView setAlignment:range:]
    Terminating app due to uncaught exception ... unrecognized selector sent to instance

The backtrace is the whole menu path working perfectly and then falling off the end of AppKit:

    +[iTermAboutWindowController sharedInstance]
    -[iTermApplicationDelegate showAbout:]
    -[NSApplication sendAction:to:from:]
    -[NSMenuView mouseDown:]

cocotron 0127 implements it. The private `-_setAlignment:range:` already did the work, but it is
written for the SELECTED range: it overwrites the typing attributes to match, and it indexes the
storage without checking the range. A public entry point can afford neither, so the new method
clamps the range to the storage and restores the typing attributes when the range does not contain
the insertion point.

After it, UNRECOGNIZED is 0 and the About window renders: the icon, iTerm2, By George Nachman and
Contributors, Build 3.5.14, the What's New and Home Page and Report a bug and Credits links, and the
sponsors banner with the Whitebox link and the CodeRabbit logo, over a live `Cider [~]#` prompt.

**Five applications now invoke menu commands**: LibreOffice, Money Manager Ex, iA Writer, Swift
Publisher and iTerm2. Four of the five found a defect nobody had seen, and none of the four was
visible in any capture.
