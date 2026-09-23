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
