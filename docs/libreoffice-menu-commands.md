# LibreOffice menu commands, from a dead menu to a table on the page

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
