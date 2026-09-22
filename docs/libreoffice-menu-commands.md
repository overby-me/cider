# LibreOffice menus open, and no item in them can be invoked

Driven on the Writer document window, launchd on, at the roster size.

## The menus themselves are right

The Table menu opens complete and with correct state: `Insert Table…` with its `⌘F12`, the Insert,
Delete, Select and Size submenus with their arrows, then Merge Cells, Split Cells…, Merge Table,
Split Table…, Protect Cells, Unprotect Cells, AutoFormat Styles…, Number Format…, Header Rows
Repeat Across Pages, Row to Break Across Pages and Sort… all GREYED because no table is selected,
and Number Recognition, Convert and Edit Formula black because they do not need one. That is real
enablement read from the application, not a flat list.

## Nothing in it can be invoked

Three separate attempts, all measured:

1. **Click `Insert Table…`.** The click lands on the item; the item never highlights; the menu
   closes; no window is created; no dialog appears.
2. **Press its accelerator `⌘F12`** instead, with the menu closed. Same: no window, no dialog.
3. **Click `Number Recognition`**, a plain toggle that needs no selection, then reopen the menu. The
   item is unchanged.

The window list is the strongest part of it. LibreOffice creates seven windows in a run and maps
two: the splash and the document window. Windows 3 to 7 are never mapped, one of them a
`dialog=true` `SalFrameWindow` of 1004x569. Crucially, **no window at all is created after the
command**, so the application is not failing to show a dialog it built. It never gets that far.

By contrast a menu item click works elsewhere: Money Manager Ex Tools then Date Range Manager opens
its dialog from exactly the same kind of click. So this is specific to LibreOffice.

## What was ruled out on the way

`-[SalFrameWindow sendEvent:] unimplemented` appears in the log twice every half second and looks
like the obvious culprit. It is not. That message comes from the default case of the event type
switch in `-[NSWindow sendEvent:]`, and the type is 15, `NSApplicationDefined`: an application
posting to itself to wake its own loop, 119 times in one drive. A window does nothing with one of
those on a Mac either. cocotron 0121 handles that case explicitly, and names the type in the
message for anything genuinely unknown, so the next reader is not sent after it again.

## Measured: tracking ends on the bar item, and the second click is not tracked at all

`CIDER_TRACE_MENU` answers it. The whole run contains exactly ONE tracking result:

    CIDER_MENU track item=Table enabled=1 action=menuItemTriggered: target=SalNSMenuItem
    CIDER_MENU trackDone on NSMainMenuView item=Table

So the first click, on the menu bar, tracks and finishes with the bar item `Table`, whose action
`menuItemTriggered:` is then sent to its `SalNSMenuItem`. The submenu opens
(`CIDER_MENU submenuNow index=7 branch=yes`). And the SECOND click, the one on `Insert Table…`
inside the open menu, produces no `track` line and no `trackDone` line at all: the menu view never
tracks it.

The items themselves are fine. `CIDER_MENUITEM` prints each one with a real action and a real
target, for example

    CIDER_MENUITEM Check for Updates... action=menuItemTriggered: itemtarget=SalNSMenuItem ...
    ... keyWindow=(nil) mainWindow=Untitled 1 controller=(nil)

so nothing is missing from the menu; what is missing is the click reaching it.

That is also why the accelerator fails for a different reason and the two look alike from outside:
one path never tracks the item, the other never matches the key equivalent.

**`CIDER_TRACE_MENU` could not be used for this until now.** It also gated a `CIDER_FLUSH` line in
`-[NSWindow flushWindow]`, which fires once per flush and crippled the application it was watching.
cocotron 0122 gives that line its own `CIDER_TRACE_FLUSH`.

## Where to look next

A menu opened from the menu bar and left open is sticky, and the click that follows has to be
tracked by the submenu's own `NSMenuView`, not by `NSMainMenuView`. Here nothing tracks it. The next
measurement is which view, if any, receives that second mouse down, because Money Manager Ex takes
the identical two-click sequence through Tools then Date Range Manager and opens its dialog.
