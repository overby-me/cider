# Money Manager Ex

A wxWidgets application, and the only one on the roster. What the roster drives is its STARTUP
DIALOG and nothing else: a click on User Interface Language and an Escape. The whole application
behind that dialog had never been looked at until 2026-09-22.

## The main window, the save panel and the wizard all work

Driven from the startup dialog with a click on New Database, a typed filename, and a click on Save.

**The main window renders.** Menu bar with Money Manager EX, File, Accounts, Tools, View, Window
and Help; a toolbar of roughly fifteen coloured icons in two groups; a Navigator side panel with
its close button; a status bar.

**A native save panel opens over it.** Title Save, a focused Save As field with its blue focus
ring, a Where popup reading root, a disclosure button, and Cancel and Save with Save as the blue
default. That is an NSSavePanel driven by wxWidgets, which is worth stating because it means the
panel machinery works for a toolkit that did not write it.

**It is interactive end to end.** Typing `cidertest` into the field and clicking Save creates the
database and opens the New Database Wizard, which renders a photographic image, a dollar bill and
coins, in full colour beside three paragraphs of text with proper typographic quotes, and Back
greyed with Next as the blue default.

**It resizes.** At 1000x600 the main window reflows: the toolbar regroups, the Navigator panel
resizes, the status bar stays. The wizard dialog keeps its size and clips at the right edge, which
is what a dialog does when the screen shrinks under it, here and on a Mac.

All three criteria, on a surface that had never been exercised. Zero unrecognized selectors in
either run.

## The wizard past page one, its validation, and the Currency Manager

Driven further, three more surfaces and all of them correct. Zero unrecognized selectors in every
run.

**Wizard page two renders.** A "Base Currency for account" label with a Set Currency button, two
explanatory paragraphs, a User Name field, and the action button correctly changed from `Next >` to
**Finish**, with Back now enabled.

**Its validation works and draws.** Clicking Finish with no currency chosen puts up a modal alert,
"New Database" over "Base Currency Not Set", with OK as the blue default carrying a focus ring.
That is a wxWidgets application driving an NSAlert, and it is correct behaviour rather than a
failure: the wizard refuses to finish without a currency.

**The Currency Manager renders a populated table.** Clicking Set Currency opens it: an Online
Update control, a checked Show All box, a two column scrolling list of real data (AFN Afghan
afghani, ALL Albanian lek, DZD Algerian dinar, AOA Angolan kwanza, ARS Argentine peso, AMD Armenian
dram, AWG Aruban florin, AUD Australian dollar) with alternating row striping and a scrollbar, a
Search field, and Select greyed with Close beside it.

That table is worth noting for a second reason: it is a many row NSTableView in a non AppKit
toolkit, so it exercises the row view machinery added in cocotron 0100 from a completely different
direction.

**One thing left unresolved rather than claimed.** In the Currency Manager the centred title sits
immediately against the third traffic light at this dialog width. macOS centres a title too and
would crowd it in a narrow window, so this is recorded as unclear rather than as a defect; it wants
a comparison against a real Mac before anyone spends a build on it.

## The wizard finishes, and why it could not before

Driving the last two clicks of the wizard, pick a currency then Finish, did not complete it. The
click on the AUD row landed (CIDER_TABLE mouseDown class=wxCocoaOutlineView at=116.0,142.0 column=2
row=7 rows=168 columns=4, which is exactly the Australian dollar row) and nothing happened: no
highlight, no redraw, Select still greyed. Clicking Finish then put up the Base Currency Not Set
alert again, because from the application side no currency had ever been chosen.

The defect was ours and it was one line. NSTableView mouseDown: gated the whole click on the
delegate:

    if (![self delegateShouldSelectTableColumn: clickedColumnObject])
        return;

AppKit asks tableView:shouldSelectTableColumn: only when a COLUMN is about to be selected, from a
header click or from selectColumnIndexes:. It is never consulted for a click on a row.
selectColumn:byExtendingSelection: in the same file already asks it in the right place.

The arbiter is the shipping binary. In mmex, -[wxCocoaOutlineView
outlineView:shouldSelectTableColumn:] disassembles to

    pushq %rbp ; movq %rsp, %rbp ; xorl %eax, %eax ; popq %rbp ; retq

which is an unconditional NO, and it is the correct thing for wxWidgets to say: a wxDataViewCtrl has
no column selection. So in this port not one row of any wxDataViewCtrl in any wxWidgets application
could ever be selected by a mouse click, and the reason was invisible, because a guarded return
prints nothing and raises nothing. cocotron 0101 removes the gate.

**After the fix, measured on the same four clicks.** The AUD row highlights blue the moment it is
clicked. Select becomes usable. Clicking it closes the Currency Manager and the wizard button that
read Set Currency now reads **Australian dollar**, so the choice crossed back into the wizard.
Finish then completes: the main window title becomes `cider6.mmb - Money Manager Ex (1.9.3 64-bit)
macOS Sonoma 14.4.1` and the **Add Account Wizard** opens on top of it. The database was created.
Zero unrecognized selectors.

A static check of every staged roster binary found mmex the only one defining
shouldSelectTableColumn:, so no other application on the roster was losing clicks this way. The fix
is still the right one on AppKit semantics rather than for this one application.

## Past the wizard: the Add Account Wizard and the Edit Account dialog

Finishing the New Database Wizard opens the **Add Account Wizard** over the main window, whose title
is now `cider8.mmb - Money Manager Ex (1.9.3 64-bit) macOS Sonoma 14.4.1`. Driven through it:

- **Page one renders**, the introductory paragraphs wrapped over two lines each, with Back greyed,
  Next blue and Cancel beside them.
- **Page two is Account Type**, a label, a small pop-up control, and three explanatory paragraphs.
- **Page three is Name of the Account**, a focused text field with the caret in it, and the action
  button correctly changed from Next to Finish.
- **Typing lands and Finish completes it.** The wizard closes and the **Edit Account** dialog opens
  carrying what was entered: Account Name `CiderBank`, Currency **Australian dollar** picked up from
  the base currency chosen two dialogs earlier, Initial Balance 0.00, a checked Favorite Account box,
  a notes text area, and OK and Cancel.

Two defects are visible on those surfaces and both are recorded rather than claimed fixed.

**The Account Type control draws an empty box, and that turned out to be correct.** I recorded it
first as a defect and as not being an `NSPopUpButton`, and both claims were wrong. Clicking it opens
a nine item menu: an empty first item carrying the tick, then Checking, Credit Card, Cash, Loan,
Term, Investment, Shares and Asset. The application itself puts that empty item at index 0, an
`NSPopUpButton` with no selection of its own selects the first item, and so the button draws empty
until something is chosen. A Mac does the same. The trace that settled it reads

    CIDER_POPUP setmenu cell=0x... menu=0x... items=0 selected=-1
    CIDER_POPUP additem menu=0x... items=1 selected=-1 pulls=0
    CIDER_POPUP title  cell=0x... items=9 selected=0 item= super=

which is the empty menu wxWidgets hands over, the first item arriving, and the drawing reading an
item whose title really is the empty string.

The only thing cocotron 0102 changes here is that the selection exists at all: before it the cell
stayed at selectedIndex -1 for ever, so `selectedItem` was nil and nothing carried the tick.

**The paragraphs on page two were cut off, and that one was ours.** Each stopped at a word boundary
part way through, which reads as wrapping rather than as loss. The three strings in the binary each
begin with a newline and carry one more hard line break, and every one of them lost its LAST line.

`usedRectForTextContainer` unions the line fragments, and a line with no glyphs has no fragment, so
a string whose first line is empty gets a used rect that starts one line down:
`used=296.00x56.00@0.00,14.00` for five lines of text. `sizeOfAttributedString` took only the size,
answered 56, wx asked the cell for its best size and gave the label a frame four lines tall, and the
layout still drew from the top of the container, so the fifth line fell outside the frame. Measured
against the hard line breaks: 5 lines answered 56, 3 answered 28, 3 answered 28, all exactly one
line of 14 short, while strings that did not begin with a newline answered 112 for 8 lines, 42 for 3
and 56 for 4, all correct. cocotron 0103 adds the y offset back and they answer 70, 42 and 42.

After it, all three paragraphs render complete, both lines each, on the surface that showed one.

**Opening Date has no control at all** in the Edit Account dialog, only its label. `wxNSDatePicker`
is one of the classes this binary defines, so an unimplemented NSDatePicker is the first thing to
check there.

## An intermittent that kills the Wayland connection, and what it correlates with

The transition that opens the Add Account Wizard failed in 2 of the 4 runs that reached it, before
any change. The failure is total: the screen goes black, every later capture is 2578 bytes, the
application keeps running and its log fills with

    cider-wayland-session display=DEAD errno=104 protocol_error=0
    cider-wayland-window create=FAILED reason=never-configured number=6 display_dead=true

seven times over, while sway logs `error in client communication (pid ...)`. errno 104 is
ECONNRESET: the compositor killed the client. libwayland-server logs that line only after
`wl_resource_post_error`, so a request of ours was invalid, and the error event never reached us
because the socket was reset first.

**What separates the four runs is one line.** The two that died each sent exactly one
`cider-wayland-activation token=asked` in the whole run, at that transition, and never got an
`activate=sent` back. The two that survived sent none at all. The window creation sequence is
otherwise byte for byte identical in all four, down to the same object numbers.

`request_activation` spends the focused surface as the requester of an xdg-activation token. Pointer
focus is remembered from `wl_pointer.enter`, and a client that destroys its own surface gets no
leave, so the remembered surface can outlive the object: the wizard is hidden, which destroys its
surface, and the new dialog is made key in the same breath.
`xdg_activation_token_v1.set_surface` on a destroyed surface is a protocol error, and the
done handler in the same file already guards its own target against exactly this, with a comment
saying it costs the whole connection. The requester was never guarded. It is now.

**Then it was proved.** Six further runs of the same transition, all six with the guard firing:

    cider-wayland-window hide number=4 visible=true title="New Database Wizard"
    cider-wayland-activation ask=dropped requester=0x5c7be33c64c0 gone
    cider-wayland-window role number=6 ... title="Add Account Wizard"
    cider-wayland-window create=ok number=6 size=761x366
    cider-wayland-window mapped=yes number=6 size=761x366 t=194.61

The requester is the surface of the window hidden on the line above, and the line the guard replaced
is exactly where `token=asked` sat in the two runs that died. Six of six opened the dialog, none
died. Counting everything at that transition: before the guard 4 runs reached it, the 2 that sent
the request died and the 2 that did not lived; after it, 6 of 6 dropped a request whose requester
was already gone and all 6 opened the dialog.

I recorded this one commit earlier as correlation that neither exercised nor proved the guard. That
was accurate then and is superseded now.

## The populated main window, and the font descriptor that had no size

Clicking OK in the Edit Account dialog used to kill the application: black screen, and

    [guest kprintf] sigexc: have RIP 0x7187E8F01621 pid 2 sig 11

The core symbolicates to `CFDictionaryGetValue` and the stack to

    wxOSX_drawRect -> wxWidgetCocoaImpl::drawRect -> wxWindow::MacDoRedraw
      -> wxGenericTreeCtrl::OnPaint -> PaintLevel -> PaintItem
        -> wxGCDCImpl::DoDrawText -> wxMacCoreGraphicsContext::DoDrawText
          -> CFDictionaryGetValue(NULL, kCTStrokeWidthAttributeName)

The Navigator tree is the first thing in this application to draw text through Core Graphics rather
than through an AppKit control, which is why nothing before it failed this way.

The NULL is the font attributes dictionary. wxFontRefData builds it in SetFont, and
`wxFontRefData::Alloc` returns at its first branch when `GetPointSize()` is not positive:

    callq wxNativeFontInfo::GetPointSize
    testl %eax, %eax
    jle   <the end of the function>

`wxNativeFontInfo` keeps that size as a plain double filled in from the font descriptor, and
`CTFontCopyFontDescriptor` in this port built a descriptor with the family name and the traits and
**no size at all**. So the size was zero, Alloc never created the CTFont or the attributes, and the
first line of tree text dereferenced NULL. cocotron 0104 puts `kCTFontSizeAttribute` in the
descriptor, which is what a descriptor carries on macOS.

**After it, the populated main window.** The Navigator renders its whole tree with icons: Dashboard
selected in blue, All Transactions, Scheduled Transactions, Favorites, Bank Accounts, Assets, Budget
Planner, Transaction Report, Reports, General Report Manager and Help, with disclosure triangles on
the three that have children. The toolbar draws its full row of icons on both sides. Resized to
1000x600 the window reflows, the toolbar regroups and the tree is untouched.

That is all three criteria on the surface this whole sequence was aimed at, reached by clicking
through five dialogs: it renders, it is interactive, it resizes.

## Two things found past the main window

**Opening the last database works, and its instance alert renders.** The start dialog entry that was
greyed out is live once a database has been opened cleanly. Because the previous runs were killed,
the file is still marked open and Money Manager Ex puts up an MMEX Instance Check alert: warning
icon, bold title, four wrapped paragraphs and Yes and No. It renders correctly, Yes dismisses it and
the main window comes up populated.

**A window left alone on the output was tiled to fill it, and never said it would not resize.**
That alert is the only mapped toplevel at that moment, so sway gave it the whole output:

    cider-wayland-window create=ok number=2 size=324x353 at=466,165 level=5 style=0x1
    cider-wayland-window resized number=2 size=1256x684

The alert content then sat at the BOTTOM of the enlarged window, which is what a bottom-left origin
does, the top of the capture still held the pixels from before the resize, and there was black
either side, so the screenshot showed the alert twice.

The trace that named it prints what the window KEPT of what it was given:

    CIDER_WINFRAME NSPanel asked=1256x684 kept=324x353 min=324x353 max=324x353 didSize=1

`-[NSWindow platformWindow:frameChanged:didSize:]` clamps the frame back to the window's own min and
max, paints the size it kept, and the rest of the surface belongs to the window and is painted by
nobody. A compositor cannot know that, because nothing ever told it: this port never sent
`xdg_toplevel.set_min_size` or `set_max_size`. It does now, for any window without
`NSResizableWindowMask`, and equal min and max is also what a compositor reads to FLOAT a window
rather than tile it. The Money Manager Ex start dialog now appears as a 350x527 window with its
shadow, centred, which is what it looks like on a Mac. That is the one roster capture the change
moves, from 31713 bytes to 32124.

**All Transactions raises a fatal exception the application catches.** Clicking it in the Navigator
puts up the wxWidgets crash reporter, `Debug report "MoneyManagerEx"`, naming
`/private/tmp/MoneyManagerEx_dbgrpt-2-20260922T094854.zip`. That dialog itself renders correctly,
group boxes, a checked file list, a notes field and Cancel and OK. The daemon log carries one
`sigexc: have RIP 0x75E1CD6473AF pid 2 sig 11` for the run, and no core, because wx handles the
signal itself. The report xml it writes has no stack in it. Symbolicating that RIP needs a run whose
image map is captured, which has not been done yet.

## What this still does not cover

The Dashboard pane on the right is empty. Money Manager Ex renders it as HTML in a `wxWebView`,
which is `WKWebView` here, and this port stubs WebKit, so there is nothing to draw. The stubs at
least answer nil now rather than a leftover register.

Opening an account register, entering a transaction, and everything reached from the Navigator tree.

No credentials of any kind are involved here. Money Manager Ex is a local finance tracker with a
SQLite file; it is not MoneyMoney and it talks to no bank.
