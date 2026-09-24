# Swift Publisher template gallery: the categories work and the thumbnails carry photographs

Two drives on 2026-09-23, aiming at `Open Recent` and hitting the category list instead. Both
results are worth keeping.

## The photographs DO render, in the gallery

Selecting `DISCS AND MEDIA` then `Photo & Video` loads six templates and three of the four visible
thumbnails carry real photographs: a portrait on a cracked-earth ground (`Ancient Stones`), two
people at a laptop (`Business Results`) and a mountain landscape (`California`). The fourth,
`Assorted`, is blank, and a first capture taken a few seconds earlier shows every thumbnail as a
dashed placeholder, so the blanks are a worker that has not finished rather than a decode that
failed.

**That bounds the standing open item.** The note on this roster says Swift Publisher renders
everything from a template except placed photographs. Whatever that defect is, it is NOT the image
decode or the drawing of a photograph: both work here, on the same assets, in the same process. It
belongs to the opened DOCUMENT path.

## Open Recent was not reached, and the reason is a measurement mistake

`Open Recent` sits at the bottom left of the gallery. Two drives aimed at it with coordinates read
off a capture and both landed in the category list several rows away: a click at `99,596` selected
`Music`, drawn at y 581, and a click at `99,661` selected `Photo & Video`, drawn at y 605. The
offsets are 15 and 56, so they are not a constant, which rules out a simple translation and means
the list scroll differed between the two runs.

This is the trap recorded in memory as **never measure a coordinate by eye**, and the correct
instrument is the application's own geometry rather than arithmetic on a screenshot. Whoever picks
this up should get the button frame from a trace first.

## Why this path matters

`strings` finds `bookmarkDataWithOptions...` referenced twice in the Swift Publisher binary and
twice in its ArtText plug-in. Before corefoundation 0131 every one of those calls answered nil with
no error. `Open Recent` is the obvious path that reaches them, and it is still unexercised.

## SOLVED: Open Recent was drawn off the screen and closed by its own tracking loop

The button frame came from `CIDER_TRACE_TREE` instead of from my eye, and settled the coordinate
question in one line:

    CIDER_TREE NSPopUpButton view=0x... 160x25@20,11 win 160x25@20,11 top 648..673

So the target is window x 20..180, top 648..673, and its centre is **100,660**. The window is
1256x684 at 0,0, the same size and origin as the capture, so for this window capture coordinates ARE
window coordinates. The two earlier misses were mine.

`CIDER_WAYLAND_TRACE_INPUT` then proved the click arrives exactly there, and proved something else
worth keeping: **the coordinates an application sees are local to the surface under the pointer.**
The welcome window close, aimed at output 1022,619, arrived as

    button=0x110 pressed=true x=849 y=572 window=2

and window 2 is at output 173,47. 1022-173 = 849, 619-47 = 572.

With the click landing on the button, the menu is created, mapped and **painted**:

    popup=ok number=3 size=72x38 level=6
    role number=3 ... class=NSPopUpWindow
    create=ok number=3 size=72x38 at=20,-27 level=6
    mapped=yes number=3 size=72x38
    pixels=drawn number=3 changed=2766/6600 colours=41
    present number=3 count=1 size=72x38

`at=20,-27` is twenty seven points **above the top of the output**. The pointer enters it, the
conversion to screen answers a negative y, and the menu closes:

    pointer=enter x=80 y=34 window=3
    screenloc local=80,34 focusWindow=3 frame=Some((20.0, -18.0, 38.0)) -> 100,-14
    hide number=3 visible=true

So the menu was never missing. It was built, painted, placed off screen, and then hidden by its own
tracking loop reading a nonsense mouse location. **Nothing in a capture could have shown any of
that.**

`-[NSPopUpWindow runTrackingWithEvent:]` shifts the frame so the selected item sits over the button,
which is the whole point of a popup button, and then set it without asking whether the result is on
the screen. cocotron 0136 clamps it to the screen visible frame, keeping the near edge when a menu
is larger than the screen rather than pushing it off the far one.

## And the whole round trip works

One step further, with `CIDER_TRACE_MENU` on. Click the button, then click the item:

    button=0x110 pressed=true x=100 y=660 window=1     the button
    pointer=enter x=35 y=20 window=3                    the menu surface
    button=0x110 pressed=true x=35 y=20 window=3        the item
    CIDER_POPUPPICK index=0 title=(none) pullsDown=1

So the popup is created, placed, painted, tracked, clicked and chosen, and the capture after it shows
the menu gone and the gallery intact with the application still running. An hour earlier the same
sequence produced a surface nobody could see.

`index=0 pullsDown=1` is correct: a pull-down popup removes its first item from the displayed copy,
and `-[NSPopUpButtonCell trackMouse...]` adds the one back afterwards. `title=(none)` is the trace
reading the title off that truncated copy and getting nil, while the item draws as `File…` on
screen, so the item carries an attributed title and no plain one. Recorded rather than chased: it
is a property of the trace, not of the pick.

## The File menu in an oversize window, and three items that read as their own keys

Driven at 1256x600, below the 618 Swift Publisher answers as its minimum, so the window overhangs
the screen by 18 and `backing=oversize` fires. New coverage on both counts: no gate had opened a
menu in a window taller than the screen, and this is the second toolkit to take that path after
LibreOffice.

What works: the Welcome Window closes from a click on its Close button at 1022,577, the File menu
drops from under its own title, the full item list draws with the right enabled and disabled states,
and the Page submenu opens beside its parent item. The positioner says `parent-top=618 local=134,48`
for the menu and `local=321,286` for the submenu, both against the height AppKit laid out in.

**Three items in the Page submenu read ADD_PAGE, REMOVE_PAGE and DUPLICATE_PAGE**, which look like
a localisation failure of ours and are not. The table the application uses is
`Contents/Resources/en.lproj/cc.strings`, and it has no entry for any of the three; there is no key
containing PAGE in it at all. The item between them resolves, which is the control:

    "INSERT_AS_VERB" = "Insert";

is in the table and draws as Insert. A missing entry makes `NSLocalizedString` answer the key, which
is what macOS does, so a real Mac shows the same three words. Nothing to fix here.
