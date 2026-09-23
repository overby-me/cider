# CMake text loses every descender, and the gates have been passing it

Found on 2026-09-23 while driving the CMake application menu, which is the first Qt menu command
this port has invoked (`CIDER_MENU track item=About CMake enabled=1 action=qt_itemFired: target=nil`,
and the About dialog does open and render).

## What it looks like

In the About dialog:

    CMake suite maintained and suDDorted bv Kitware (kitware.com/cmake)
    The Qt Toolkit is CoDvriqht (C) The Qt ComDanv Ltd.

for

    CMake suite maintained and supported by Kitware (kitware.com/cmake)
    The Qt Toolkit is Copyright (C) The Qt Company Ltd.

and in the main window, which is the capture the roster-input gate has been marking CONTENT for a
long time:

    Press ConfiQure to uDdate and disDlav new values in red, then Dress Generate to Qenerate
    selected build files.
    GrouDed

Every letter that changes is one with a DESCENDER, and it changes into the letter that is left when
the part below the baseline is removed: `p` reads as a `D`, `g` as a `q`, `y` as a `v`. Nothing
without a descender is affected, so this is not a font substitution and not a garbled string.

## Why no gate caught it

`capture-is-black.py` answers CONTENT or BLACK, and this capture is full of content. The roster
baseline compares the whole file byte for byte, so it locks the defect IN rather than reporting it:
the bytes have been stable for weeks because the clipping is deterministic. Looking at the capture
is the only thing that finds this, which is what the standing instruction to LOOK at every capture
is for, and it still took until a sixth application was driven down a new path for anyone to read
the words rather than check the picture was not black.

## Where to look

It is Qt only. The same glyphs render correctly in LibreOffice (`Default Paragraph Style`), iA
Writer (`EmptyProbe.md`) and Money Manager Ex in the same session, so the rasteriser can draw a
descender; something about the way Qt asks for them loses the part below the baseline.

The shape of it says the glyph IMAGE is being cut, not the layout: the letters keep their positions
and their advance, and only the pixels below the baseline are gone. Qt 5.15 caches glyphs by
rendering each one into a cell sized from the font metrics it is given, so the first thing to
measure is what this port reports for that font's descender and for the glyph bounding rects, and
whether the cell Qt allocates is exactly the ascent with no room under the baseline.


## The glyph boxes are RIGHT, so the cell is not the problem

First hypothesis, and refuted. Qt 5.15 sizes the cell it renders each glyph into from the bounding
rect, so a rect with no room under the baseline would explain everything. `CIDER_TRACE_GLYPHBOX`
(cocotron 0132) prints every rect `-getBoundingRects:forGlyphs:count:` hands back. In one CMake
start:

    483 boxes, 215 with a negative origin y, and the deepest value is -2.62, on 43 of them

which is a real descender depth for an 11 point font, not antialiasing overshoot (the -0.16 and
-0.18 crowd is that). So the boxes report descent correctly and Qt is being told to allocate room.

The surface probe agrees that Qt uses that path: `CIDER_TRACE_SURFACE_WIDTH=any` on CMake names
10x10, 14x11, 8x9, 5x9, 6x9, 9x9, 12x9, 7x10, 4x11 and 11x12, which is one cell per glyph, sized
per glyph.

So the cell has room and the glyph still loses its descender, which leaves WHERE the glyph is drawn
inside the cell. Qt positions it by setting a text position derived from the bounding rect and then
showing the glyph; `O2ContextSetTextPosition` stores that into `_textMatrix.tx/ty`, and the next
measurement is what the rasteriser does with it: if the baseline lands on the bottom edge of the
cell rather than `-rect.origin.y` above it, everything below the line falls outside and everything
above survives, which is exactly the shape on screen.