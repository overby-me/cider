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

## Where to look next

The menu opens, so the menu bar, the tracking window and the item titles and enablement all reach
AppKit. What does not happen is the item being chosen. The next measurement is the selection path
itself: what `-[NSMenu performActionForItemAtIndex:]` is given, and whether the item carries the
target and action LibreOffice set on it, because an item whose action is dispatched down a
responder chain that cannot find its target fails exactly this way and fails silently.
