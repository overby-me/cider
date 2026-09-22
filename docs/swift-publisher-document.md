# Swift Publisher, from the template gallery into a document

A path never driven before this. Everything here was measured at 1400x900; the size matters and is
explained below.

## It opens, and it renders

Close the welcome window, leave the College brochure selected in the Template Gallery, press
Choose, and dismiss the licence notice with Try It. The document window that appears is complete:

- the title bar reads Untitled - Swift Publisher 5;
- the toolbar carries View, Editing Tools, Zoom, Preview Mode, Insert, Share, Print, Text Styles,
  Fonts and Inspector, with their icons;
- a zoom control reading 75 percent, a page navigator reading 1 / 2 with both arrows, and a Content
  Pages popup;
- a page thumbnail strip with BOTH pages drawn, page one ringed as selected;
- rulers down the left and across the top, numbered;
- the brochure page itself: three columns of text laid out and hyphenated, the headings American
  Association for Better Learners, STUDY, ABROAD and periods of architecture, and the address
  block;
- the Inspector: US Letter, Inches, Orientation with portrait ticked, Simulate paper color,
  Document Margins with four spinners, Info with Title, Author and Description, the layer and grid
  buttons, and Background.

## The size it asks for, which is not a defect

At the roster sizes the top of the window is cut off. That is the application, not the port.
`CIDER_WAYLAND_TRACE_GEOMETRY` prints what each frame change was asked for and what the window
kept:

    asked=1256x684  kept=1256x753  min=1000x753
    asked=1000x600  kept=1000x753  min=1000x753
    asked=1400x900  kept=1400x900  min=1000x753

The document window sets a minimum of 1000x753. On a 684 point screen AppKit correctly clamps UP to
the minimum and 69 points go off the top. At 1400x900 nothing is clamped and the whole window fits.

## The photographs do not appear, and the reason is not in our drawing

The College brochure should show a cyan photograph of the Colosseum in a dark frame, and a second
photograph filling the right hand column. The shipped preview in the gallery shows both, and it is
the control for what the page is supposed to look like.

We render a flat dark rectangle where the framed photograph belongs and nothing at all in the right
column. The flat rectangle is exactly `srgb(42,43,43)`, sampled, and `CIDER_TRACE_PAINT` names it:

    CIDER_PAINT path blend=0 239x174 at 624,140 ... n=4 c=0.165,0.168,0.168,1.000

a PATH fill in that colour, issued by the application.

**The images decode.** `CGImageSourceCreateImageAtIndex` now says so directly, and after the
document opens it reports `O2ImageSource_JPEG index=0 -> ok 519x519` fifty nine times and
`ok 680x510` twenty times, with ZERO failures anywhere in the run. The application decodes the same
photograph over and over, which is what an application does when it is trying to draw it.

**And nothing ever draws them.** With `CIDER_TRACE_PAINT=0,0,4000,4000`, which covers every surface
including offscreen ones, the largest image drawn after the document opens is 85x65, and the rest
are the 61x47 page thumbnails and chrome icons of 40x40 and smaller. No image anywhere near 519x519
or scaled to the 239x174 box is ever drawn.

## What is refuted

**It is not the layer path.** Swift Publisher logs `CGLCreateContext failed with 10004, so this
view has no layer context` five times, and a layer with no renderer shows only its background,
which would explain a flat rectangle exactly. It is still wrong: a trace in `-[CALayer
setContents:]` (cocotron 0120) reports ZERO calls from Swift Publisher across the whole run, while
the same trace fires three times under iTerm2, so the instrument speaks. The application never puts
an image in a layer.

**It is not a decode failure**, by the count above.

**It is not a hollow bundle.** The staged application is 770M and the template is a 304K plist of
base64 data.

## The next thing to measure

The application decodes the photograph and then decides to fill a rectangle rather than draw it. The
question is what it asks about the image between those two points. `CGImageSourceCopyPropertiesAtIndex`
is the candidate: an earlier round already had to add PixelWidth and PixelHeight there because Swift
Publisher logged `key 'PixelWidth' ... returns nil` a hundred times per document load, and a layout
application that cannot learn something else it needs about a picture has the same reason to refuse
to place it. Nothing in the current log complains, so whatever it is, it is being answered without
protest and answered wrongly.
