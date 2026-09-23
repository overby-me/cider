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


## What it really is, and a fix that was tried and WITHDRAWN

**Withdrawn: the letters are not substituted and the descenders are not missing.** The first write
up above says `p` reads as `D`, `g` as `q` and `y` as `v`, as though the part below the baseline
were gone. That came from reading 11 point antialiased text by eye at 1:1, which this repository
already carries a note against. Magnified 14 times and then printed as an ink map, the truth is
different: the descender glyphs are drawn at the RIGHT size but THREE ROWS TOO LOW, so the bowl of a
`g` sits where its tail belongs and the tail runs off the bottom of its cell. That is why it reads
as a smaller letter.

**Withdrawn twice more, both the same sampling trap.** `uniq -c | sort -rn | head` showed
`top == rows` for every glyph and `render == bitmap` for every blit, and I read both as "all". They
were the most FREQUENT rows, which are the letters with no descender. Counted properly, **7 blits of
200 are short and every one loses exactly its descender rows** (`bitmap=6x10 ... render=6x7`).

So the measured facts are: the glyph bitmap is correct, the bounding box is correct, the cell has
room, and the baseline is placed on the cell floor so the rows below it are clipped.

**And the fix that follows from that was wrong.** Qt sets a text position immediately before the
draw and passes zero to `CTFontDrawGlyphs`:

    CIDER_TEXTPOS set=0.00,2.17
    CIDER_TEXTDRAW ctfont count=1 first=0.00,0.00 size=12.00
    CIDER_TEXTPOS set=0.00,0.00      <- ours, overwriting it

Offsetting each glyph by the current text position fixed CMake completely: short blits 0 of 200, the
`g` bowl the same seven rows as the `o` beside it, and the sentence reading `Press Configure to
update and display new valu`. **It also destroyed LibreOffice.** The roster sweep caught it at once,
`lo CHANGED from 137276 to 124510`, and the Start Centre came back with almost every label reduced
to scattered fragments.

Quartz documents these positions as USER SPACE, absolute, which is what LibreOffice relies on, so
the offsetting is simply wrong and the CMake improvement was a coincidence of whatever value
happened to be sitting in the text position. Reverted, and all seven baselines re-measured
unchanged.

**What is still not known** is where the 2.17 comes from and why Qt expects it to survive. That is
the next measurement, and it is a question about the ORDER of the two calls rather than about the
rasteriser, which every instrument here now agrees is correct.

The instruments are kept, because they are what made the above measurable rather than arguable:
`CIDER_TRACE_TEXTCTM` now prints what the caller asked for (`CIDER_TEXTPOS`) and which entry point
was used (`CIDER_TEXTDRAW`), and `CIDER_TRACE_GLYPHRUN` prints the FreeType slot per glyph
(`CIDER_GLYPHSLOT`) so a bitmap rendered too small can be told from one placed too low. Their per
line caps went from 40 to 400, because 40 hid the descender glyphs behind the ordinary ones three
separate times.


## FIXED, on the second attempt, and the difference is one line

The first attempt above offset each glyph by the current text position. That was the right rule with
a missing half. `O2ContextShowGlyphsAtPoint` SETS the text position as it draws, so every call
measured from where the last one ended and LibreOffice walked off its own cells.

The callers say what the rule has to be. Adding the frames to `CIDER_TEXTPOS` names them:

    CIDER_TEXTPOS set=1.00,1.27 <- QTextureGlyphCache::calculateSubPixelPositionCount
    CIDER_TEXTDRAW ctfont count=1 first=0.00,0.00

Qt sets the position and passes zero, once per subpixel variant, x stepping 1.00, 1.08, 1.16, 1.25
with y fixed at the lift it wants under the baseline. LibreOffice arrives through SKIA, which never
sets the position and passes the offsets itself:

    CIDER_TEXTDRAW ctfont count=1 first=1.00,2.00 <- SkScalerContext_Mac::Offscreen::getCG

One rule serves both: **a glyph position is an offset from the text position, and the call must not
move it.** cocotron 0134 reads the base once, offsets every glyph by it, and restores it at the end.

Measured after: the roster sweep has LibreOffice unchanged at 137276 and CMake moved from 33544 to
34456, which is more ink because the descenders are there. The window now reads

    Press Configure to update and display new values in red, then press Generate to generate
    selected build files.

with Grouped, Advanced and the rest correct, where it read ConfiQure, uDdate, disDlav, Dress and
Qenerate for weeks. The baseline is updated with the reason beside it.