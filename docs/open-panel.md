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

Every link in the chain read correctly and the line still did not break, so the probe went INSIDE
that loop and named the character. `CIDER_TEXTCTL`, on the run that opens the document:

    CIDER_TEXTCTL char=U+000A glyph=0        isControlGlyph=0 index=7
    CIDER_TEXTCTL char=U+000A glyph=0        isControlGlyph=0 index=8
    CIDER_TEXTCTL char=U+000A glyph=0        isControlGlyph=0 index=39
    CIDER_TEXTCTL char=U+0000 glyph=16777215 isControlGlyph=1 index=13
    CIDER_TEXTCTL char=U+0008 glyph=16777215 isControlGlyph=1 index=15

Indices 7, 8 and 39 are exactly the three newlines in the file. They arrive as glyph 0; other
control characters arrive as `NSControlGlyph`. So the mapping happens for some runs and not others,
and the difference is the FONT: `CIDER_TEXTGLYPH` counts **1861 runs answered by NSFont and 89 by
KTFont_FT**, and the document newlines fall in the KTFont ones.

`-[NSFont getGlyphs:forCharacters:length:]` maps everything below space to `NSControlGlyph` inside
its own method. `-[KTFont getGlyphs:forCharacters:length:]` is a two level table lookup and answers
0 for a character no face draws. `_CiderGetGlyphsFromFont` already knew these two disagree, and
adapts the ELEMENT WIDTH between them, but it copied the narrow glyphs straight across. cocotron
0135 applies the same control character rule where that widening happens.

After it the three newlines arrive as `glyph=16777215 isControlGlyph=1` and the editor draws

    # Cider

    A document iA Writer ca

which is the file, with the heading on its own line and the blank line kept. The tail is off screen
because the compositor tiles the window narrow.

## AND THE APPLICATION DIES SHORTLY AFTER, which is not the fix

Correcting the section above: the round trip opens a document window that shows its text, and then
iA Writer terminates.

    Terminating app due to uncaught exception NSException, reason: Cannot remove a nil key
      -[__NSCFDictionary removeObjectForKey:]
      __36-[IAFileBookmarkHistory willUpdate:]_block_invoke
      -[IAFileBookmarkStore update:]
      __64-[IAFileBookmarkStore addURL:progressHandler:completionHandler:]_block_invoke_3
      -[NSBlockOperation main]

**It is not caused by 0135.** All four runs of this sequence terminate the same way, including the
three taken BEFORE that change, and the earlier captures simply landed before the operation queue
got there. Shortening the wait after Open from 32 to 10 catches the window every time.

So opening a document from the panel always ends in that exception, on an operation queue, inside iA
Writer own bookmark history. The key it removes comes from something this port answers nil for, and
naming that is the next measurement on this thread.

## Correcting the paragraph above: the rate is 4 of 5, and the crash arrives LATE

Two things in the section above are wrong and both were found by re-measuring rather than by
re-reading.

**It is not every run.** A fifth recorded drive of the same sequence, `captures/ia-fixed2`, ran to
`t=281.62` and did not terminate. So the rate is 4 of 5, not 5 of 5.

**It arrives between four and five minutes in.** The termination timestamps, read against the
`nextevent ... t=` clock in the same log:

| capture | last t | terminated at |
|---|---|---|
| `ia-openfile` | 299.23 | 299.23 |
| `ia-textline` | 269.38 | 269.38 |
| `ia-fixed` | (log truncated) | 229.13 |
| `ia-fixed2` | 281.62 | never |

Four drives taken today with `LIMIT=110` all ended at `t≈108` with a live document window and no
exception. **That is the harness stopping short, not the defect going away**, and it is worth
writing down because those four runs look exactly like a fix. Any drive meant to reach this needs
`LIMIT` above 300.

## The crash site, arithmetic rather than assertion

`__36-[IAFileBookmarkHistory willUpdate:]_block_invoke + 266` against the extracted x86_64 slice:
the block begins at `0x33bd`, and `0x33bd + 0x10a = 0x34c7`, the return address of the
`removeObjectForKey:` call at `0x34c5`. `-[IAFileBookmarkHistory willUpdate:] + 423` lands the same
way on the `enumerateObjectsWithOptions:usingBlock:` call. So the block is

```objc
[[changeSet bookmarks] enumerateObjectsWithOptions:NSEnumerationReverse
                                        usingBlock:^(IAFileBookmark *bm, NSUInteger idx, BOOL *stop) {
    if ([knownIdentifiers containsObject:[bm identifier]] &&
        errors[[bm identifier]] != nil)
        return;
    [mutableBookmarks removeObjectAtIndex:idx];
    [errors removeObjectForKey:[bm identifier]];   // <- raises here
}];
```

and the nil key is `[bm identifier]`. The block descriptor names the argument type `IAFileBookmark`,
and both `-[IAFileBookmark identifier]` and `-[IAFileBookmarkHistoryItem identifier]` are plain
stored-ivar loads, `movq 0x8(%rdi), %rax`.

## Where the identifier comes from, and the three port answers that could be nil

`-[IAFileBookmarkStore addURL:progressHandler:completionHandler:]` runs on a background queue and
reads, in order: `_refreshBookmarks:errors:`, then `indexOfObjectPassingTest:` with a block that
compares `[[bm URL] isSanitizedPathEqual:]`, then `_validateURL:bookmarkIdentifier:bookmarks:...`.
On a miss it takes the CREATE branch, `bookmarkDataWithURL:error:` then `[[NSUUID UUID] UUIDString]`
then `initWithIdentifier:URL:data:`; on a hit it takes the REPLACE branch, which reuses
`[existing identifier]`. `_block_invoke_3` then builds the change set with `initWithBookmarks:errors:`
and calls `update:`, whose first act is `[self willUpdate:changeSet]`.

That leaves exactly three ways this port could hand the application a nil identifier, and
`tests/foundation/probe_bookmark_identity.m` asks all three directly.

**All three answer correctly. 23 checks, 0 mismatched, each with a control.** `NSUUID` produces a
36 character string and two calls DIFFER; the identifier survives both a plain and a
`requiringSecureCoding` archive round trip, while the control asking for the wrong class answers
nil; reverse enumeration visits every element, starts at the last index, hands out no nil element
and no nil identifier, and `valueForKey:` plus `NSSet` behave on both sides of a membership test.

So the nil identifier is not NSUUID, not the keyed decode and not the enumeration, and the next
measurement has to come from the running application.

## What a run with the bookmark classes traced showed, and what it does not settle

`CIDER_TRACE_MSGSEND=IAFileBookmark` on a full open sequence: `addURL:progressHandler:completionHandler:`
ran, `willUpdate:` ran, `applyChangeSet:` ran, and **not one `IAFileBookmark` instance was ever
created** in that process. The only sends to the class were `+class` and `+initialize`; neither
`+bookmarkDataWithURL:error:` nor `-initWithIdentifier:URL:data:` appears. The bookmarks the change
set carried were therefore empty, which is why that run did not raise.

**That run reached only `t=138`,** so it is inside the window where a non-crashing run and a
crashing one look the same, and it bounds less than it appears to. It is recorded because it names
the next thing to look at: the store restores its `bookmarks` through `IAKeyValueStore`, with
`underlyingStore`, `registerDefaults:`, `valueTransformerNames` and
`_readValueFromUnderlyingStoreKey:forKey:` all in the trace, and that is a fourth construction path
the probe does not cover.
