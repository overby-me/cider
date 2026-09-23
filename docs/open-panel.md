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


## The round trip works, and a document window DOES show its content

Driven all the way through: File, Open, expand `Documents`, click `Cider.md`, click Open.

`Documents` expands to `Cider.md`, `EmptyProbe.md`, `IndexProbe.md` and `probe.txt`, each without a
disclosure triangle because they are files, and nothing else in that directory is listed because the
panel filters to the types iA Writer accepts. Clicking Open then opens a SECOND iA Writer window,
and **its editor pane shows the text of the file**.

**That corrects the standing note in memory** which says the content never reaches a mapped window
and the editor pane is always empty. That note is about clicking a file in the LIBRARY pane, and it
remains true for that path as far as this drive goes: the first window still shows an empty editor.
What is new is that the File, Open path produces a window whose editor DOES render the document.
Nobody had driven it, because the menu could not invoke a command until 2026-09-23.

## And the newlines are lost

The file is exactly

    # Cider\n\nA document iA Writer can open.\n

forty bytes, checked with `od -c` on the real file at
`/tmp/cider-ia-1000/prefix/Users/root/Documents/Cider.md`. A text storage reaching `len=40` appears
in the `CIDER_TRACE_TEXT` log, so the string arrives whole, newlines included.

The editor draws it as two visual lines, magnified four times to read rather than guessed at:

    # CiderA document iA Wr
    open.

The heading and the paragraph are run together, so both newlines are gone; the break after `Wr` is
the window edge, not the file. The window is tiled narrow by the compositor, which is why the middle
of the sentence is off screen to the right.

What is measured so far, and where it stops:

- Glyph generation is 1:1 and asks an `NSFont`: `CIDER_TEXTGLYPH font=NSFont glyphRange=n chars=n
  zeros=0` for every run. `-[NSFont getGlyphs:forCharacters:length:]` maps every character below
  space to `NSControlGlyph`, so a newline should arrive at the typesetter as one.
- `-[NSTypesetter actionForControlCharacterAtIndex:]` answers `NSTypesetterParagraphBreakAction`
  for it, both through `newlineCharacterSet` and an explicit case.
- `NSTypesetter_concrete` acts on that only inside `if (glyph == NSControlGlyph)`, and on a break it
  sets `_paragraphBreak` and advances the scan rect.

So every link in the chain reads correctly and the line still does not break, which means the next
measurement has to be inside that loop rather than around it: whether the newline glyph reaches
`glyph == NSControlGlyph` at all for THIS run. The document is laid out in short runs split by iA
Writer own markdown attributes, so it cannot be picked out of the log by length alone; the probe has
to name the character.
