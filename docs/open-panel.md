# The open panel works, and this is the first time it has been driven

`NSOpenPanel` is reached by every document application and had never been opened in a drive. iA
Writer, File then Open (`CIDER_MENU track item=Open… enabled=1 action=openDocument: target=nil`),
at the roster size.

## It renders

A titled `Open` panel with its three window buttons, a bordered outline view showing `root` expanded
over Applications, Desktop, Developer, Documents, Downloads, Library, Movies and Music, each with a
disclosure triangle, a vertical scroller with a real thumb, and Cancel and Open along the bottom
with Open drawn as the default button. UNRECOGNIZED is 0 for the whole run.

## It is interactive

Clicking the disclosure triangle beside Applications turns it from a right pointing triangle to a
down pointing one, inserts `Demos` and `Utilities` indented beneath it, and pushes Desktop and
everything below it down. That is `NSOutlineView` expansion inside the panel, working.

Worth noting rather than filing: `Applications` shows only its two plain directories and not
`iA Writer.app`. That is correct. An open panel treats a bundle as a FILE and filters it against the
allowed types, and iA Writer asks for text documents.

## It returns

Cancel dismisses the panel and leaves the main window intact, file list and all, with the process
still pumping events. So the panel is not a one way door.

## What is not settled

The outline view starts very slightly scrolled: one row above `root` is cut off by the top edge and
the scroller thumb sits a little below the top. That is ordinary for a scroll view part way through
a scroll and it is recorded here so the next reader does not have to decide whether it matters from
memory. Whether the panel RESIZES has not been measured; the drive harness resizes the application
toplevel, not a panel.
