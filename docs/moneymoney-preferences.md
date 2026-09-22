# MoneyMoney Preferences: five panes driven, three correct, and the window that never grows

No credentials are involved anywhere in this. Nothing was typed into any field, the Set Database
Password button was not touched, and MoneyMoney was never asked to talk to a bank.

Command comma opens the Preferences window and it renders: a floating 406x331 panel with its shadow
over the main window, a five item toolbar with icons, and the General pane complete. Clicking each
toolbar item switches the pane, so the surface is interactive.

## What each pane looks like

- **General**: correct. Five checkboxes, a Language pop-up reading English, and the indented
  Participate in beta tests box below it.
- **Security**: the first paragraph is drawn OVER the toolbar labels.
- **Payments**: correct. Three options, each with its explanatory paragraph.
- **PSD2**: the worst of them. The content starts above the toolbar, the title bar is not visible at
  all, and two paragraphs sit across the toolbar icons. Everything below that, the three links, the
  fee paragraph, the two buttons and the gear pop-up, is legible and in the right place.
- **Extensions**: correct. An empty list box, Restore Purchases with its caption, and a checked
  Verify digital signatures of extensions.

## Why the two overlap

The window is 406x331 and never changes. The pane content views DO change, measured from the view
tree of the window while each pane is up:

    406x253@0,0   top 78..331
    406x265@0,0   top 66..331
    406x286@0,0   top 45..331

Each pane is a different height, anchored at the BOTTOM of a window that stays 331 tall, so a taller
pane grows upward into the toolbar. On a Mac the window grows instead and the toolbar stays above the
content.

## The application does not ask

`CIDER_TRACE_TOOLBAR` prints every `-[NSWindow setFrame:display:animate:]`, which is where
`setFrame:display:`, `setContentSize:`, `setFrameOrigin:` and the animator proxy all end up. Across a
run that opened Preferences and clicked all four other panes, the Preferences window received
exactly three:

    CIDER_SETFRAME class=MMWindow to={697.0,-24.0 406.0x346.0} didSize=1 platform=NIL
    CIDER_SETFRAME class=MMWindow to={697.0,-56.0 406.0x378.0} didSize=1 platform=NIL
    CIDER_SETFRAME class=MMWindow to={697.0,-9.0 406.0x331.0} didSize=1 platform=NIL

all three at construction, before the platform window exists, and the last of them is the 331 the
window keeps. **At pane switch time there are none at all.** So this is not a resize we drop: it is
a resize the application never requests.

What has been eliminated, each by reading the code rather than guessing: `setContentSize:` calls
`setFrame:display:` which calls the traced method; `setFrameOrigin:` and `setFrameTopLeftPoint:` do
the same; `-[NSWindow animator]` returns self and would therefore also reach it, and the log carries
zero `animator] unimplemented` lines for this application.

So the branch that would resize is not reached, and why is not yet known. The next step is the
application side: MoneyMoney decides somewhere whether a pane change needs a new window size, and
what it reads to decide that is the question.

## The instrument that made the tree readable

Until cocotron 0106 the view tree dumper hung off `-flushWindow`, and a settled window never flushes
again, so a pane swapped in by a click could not be dumped. The three content view sizes above come
from the dumper running off the event pump instead.
