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

**Opening Date had no control at all** in the Edit Account dialog, only its label. FIXED by
cocotron 0117: it now reads `9/22/2026` in a bezeled field with its stepper, confirmed on the
dialog itself. The cause is written up under the date field that was never there, below.

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

**All Transactions raised a fatal signal once and has not since.** In the run where the alert had
been stretched across the output, clicking All Transactions put up the wxWidgets crash reporter,
`Debug report "MoneyManagerEx"`, and the daemon log carried one `sigexc: have RIP 0x75E1CD6473AF pid
2 sig 11`. There was no core, because wx handles the signal itself, and the report xml it writes has
no stack in it. That dialog at least renders correctly: group boxes, a checked file list, a notes
field, Cancel and OK.

Three runs of the same two clicks after the fixed-size window change: no signal, no new debug report,
and the capture byte identical at 43318 each time, with All Transactions selected in the Navigator
and an empty transaction pane, which is right for a database with no transactions in it. One
occurrence against three clean runs is not a proof that the geometry caused it, and it is recorded
that way rather than claimed.

**And the alert now floats.** The same MMEX Instance Check appears as a 324x353 panel with its
shadow and rounded corners, centred, exactly once, with nothing stale above it and no black column
beside it.

## The Tools menu and the Category Manager

Reached from the populated main window, both never driven before.

**The Tools menu opens complete**: Download Rates, Payee Manager, Category Manager, Tag Manager,
Currency Manager, a Merge submenu, Budget Planner, Scheduled Transactions, Assets, Theme Manager,
Date Range Manager, Transaction Report, General Report Manager, Custom Field Manager, a greyed
Refresh WebApp and a Database submenu, with its separators and both submenu arrows.

**The Category Manager is a populated tree** in a floating 462x570 panel: a toolbar of Collapse All,
Expand All, a toggled Show All, a tree button and Clear Settings; the Categories root expanded over
Automobile, Bills, Education, Food, Gifts, Healthcare, Homeneeds, Income, Insurance, Investment,
Leisure, Miscellaneous, Other Expenses, Other Income and Taxes, each with its disclosure triangle
where it has children; a scrollbar, a Search field, and New, Edit, Delete and Close.

**And it is interactive in the two ways that matter for a tree.** Clicking Food selects it, full
width in blue. Clicking the disclosure triangle beside Automobile expands it in place, adding Gas,
Maintenance, Parking and Registration and pushing the rest down. The application sees the selection
too: Edit goes from greyed to enabled and Delete from enabled to greyed the moment a row is picked.

That is the row click of cocotron 0101 working on a tree rather than a flat list, and the selection
notification reaching the application behind it.

## The Date Range Manager

Tools then Date Range Manager, a third surface off the same menu.

**Manage checking date ranges renders complete**: a two column table of thirty named ranges with
their shorthand, alternating stripes, from All to week and All to month down through Current
financial year, Today, From statement, a ==== More date ranges separator row, the From current year
family, the Previous family, From 1 year ago down to Year before last; a column of Top, an up
chevron, Edit, a down chevron, Bottom, New and Delete down the right side; and Save, Restore
default ranges and Cancel along the bottom.

**A row click reaches the application.** Clicking From current year to week paints it full width in
blue, and Edit and Bottom go from grey to black in the same frame. Top stays grey. That is again
cocotron 0101, this time on a two column list where the click lands in the second column as often
as the first.

**Resized to 1000x600** the main window behind reflows its toolbar and the dialog keeps its size and
its selection. A wx modal dialog is fixed by construction, so keeping its size IS the correct answer
here; what had to be shown was that the window behind it resizes with the dialog up, and it does.

## New Transaction, and the graphics context that was freed under the caller

Clicking the plus button on the toolbar of the populated main window killed the application with
SIGSEGV, five times out of five. wxWidgets installs its own fatal signal handler, so there was no
core, cocotron's `_CiderAppFatalSignal` never ran (wx had replaced it), and the wx debug report
zip contained one line of XML and no stack at all.

**How the stack was recovered.** The process does not actually exit: it sits showing its Debug
report dialog. A watcher polled `ciderd.log` for `sigexc: have RIP`, and the moment it appeared
copied `/proc/<pid>/maps` and 8 KB of `/proc/<pid>/mem` around rsp for every cider process. Several
processes match; the right one is the one whose libobjc base equals `RIP` minus the offset of the
faulting function. Then the frame pointer chain walks cleanly.

**Where it died.** libobjc `objc_retain` plus 0x2f:

    439f: movq (%rdi), %rax                 ; rax = obj->isa
    43a2: movabsq $0x7ffffffffff8, %rcx
    43ac: andq %rax, %rcx                   ; rcx = isa & ISA_MASK
    43af: movq 0x20(%rcx), %rdx             ; FAULT

The registers confirm it arithmetically: the isa word read back as 0x3000076D29919093, masking
gives 0x76D29919090, and CR2, the last and unlabelled greg in the sigexc dump, is exactly that plus
0x20. On a second run the isa read back as 0. Different garbage each run, which is what a freed
object looks like.

**The full stack:**

    objc_retain
    __CFBasicHashReplaceValue + 0x5d
    -[__NSCFDictionary setObject:forKey:] + 0x246
    wxRendererMac::DrawMacCell + 0x3f8
    wxRendererMac::DrawComboBox + 0x6d
    mmTagTextCtrl::createDropButton + 0x28b
    mmTagTextCtrl::mmTagTextCtrl + 0xa23
    TrxDialog::createControls + 0x289b
    TrxDialog::create + 0x73
    TrxDialog::TrxDialog + 0x339
    mmFrame::OnNewTransaction + 0xec
    ... wxEvtHandler::ProcessEvent ... wxAuiToolBar::OnLeftUp

**The defect.** Disassembling DrawMacCell and resolving its selrefs and classrefs gives the exact
idiom, the one every drawing routine uses:

    e4a: objc_msgSend NSGraphicsContext currentContext            -> r13 = prev
    e69: objc_msgSend NSGraphicsContext graphicsContextWithCGContext:flipped:
    e83: objc_msgSend NSGraphicsContext setCurrentContext: new
    eb7: objc_msgSend cell drawWithFrame:inView:
    f32: objc_msgSend NSGraphicsContext setCurrentContext: r13    -> return address 0x...f38

`+[NSGraphicsContext currentContext]` returned the object straight out of the thread dictionary
with no retain and no autorelease. The thread dictionary was its only owner. So the call at e83
replaced the dictionary entry, released the old value, and freed the context the caller was still
holding in r13; the restore at f32 then retained freed memory.

cocotron 0109 returns `[[current retain] autorelease]` instead. The fix is four lines and the
idiom it repairs is not specific to Money Manager Ex: every wx native cell render goes through
DrawMacCell, and save, set, draw, restore is how AppKit drawing is written everywhere.

**After cocotron 0109, measured.** Five runs before the fix, five crashes. After it: `sigexc` count
0 in a 293 line `ciderd.log` (the crashing runs produced over 3000 lines, so the log is not silent,
it simply has nothing to report), and the New Transaction dialog appears, with its title bar, a
Transaction Details group box, and Save, Save and New and Cancel.

**It is not finished.** The Transaction Details box is EMPTY. Every field the dialog is supposed to
carry, date, account, payee, category, amount, notes and the tag control whose construction was
crashing, is missing. So the application no longer dies and the dialog is now reachable, but it
does not yet render correctly. That is the next thread, not a completed one.

## The New Transaction dialog, and the box that was not a container

After cocotron 0109 the dialog appeared and its Transaction Details box was empty. Four more defects
stood between that and a form, and three of them were in my own instruments.

**The tree dumper killed the application it was watching.** Every run with `CIDER_TRACE_TREE` set
ended `cider-app exit=255` on Unhandled unknown exception, 4 of 4, against 2 of 2 healthy without
it. `CiderDumpViewTree` sends `-fontName` to whatever a control answers for `-font`, a wx control
answers a CoreText `KTFont_FT`, which does not implement it, and the raise escaped through
`-flushWindow` into the application draw, where wx terminates. cocotron 0111 asks only a real
`NSFont` and wraps the whole dump in `@try`, so a probe can no longer take the application down.
I had also patched the guard into the wrong function twice: there are two dumpers in `NSWindow.m`
and a first-match replace kept landing on the one nothing calls.

**With the dumper alive, the tree named it in one line:**

    wxNSBox            397x469@10,10
      wxNSBoxContentView   1x1@0,0
      wxNSStaticTextView   30x14@46,-1008   text: Date
      wxNSPopUpButton     233x22@130,-1045
      ... every field, down to 28x24@335,-1294

Every control existed, none was hidden, and all of them sat about a thousand points below the box.

**Two defects, and a refuted guess.** The content view was 1x1: `-[NSBox setContentView:]` carried
a comment reading FIX, adjust size and never sized the view it adopted, so a view created in code
kept its 1x1 frame forever. That is cocotron 0113, which also computes the content rect from the
same groove geometry `-drawRect:` paints. Fixing it did not change the picture. I also guessed the
box was painting over its own fields because `-sortSubviewsUsingFunction:context:` was
unimplemented, which is how wx raises and lowers a control; implementing it (cocotron 0112) was
right on its own terms and made no difference here. That guess is withdrawn.

**What actually moved them** is that wx converts a top down y into a bottom up one using the parent
bounds height, and only when the parent is NOT flipped. Disassembling `wxToNSRect` confirms the
arithmetic exactly: `y_out = boundsHeight - (y + height)`. `CIDER_TRACE_BOXKIDS`, added in cocotron
0112, printed the box as correct at the time of every call:

    CIDER_BOXKID wxNSStaticTextView asked={46,-1255 48x14} box=wxNSBox bounds=397x469@0,0 flipped=0

An `NSBox` is the only unflipped container an application like this has. `wxNSBoxContentView` IS
flipped, and on a Mac these children never get converted at all, because a box puts what you add to
it inside its content view. Ours added them to the box. cocotron 0113 forwards `-addSubview:` to
the content view, and the count of children landing on the box went from 301 to 7 in the same
drive.

**The dialog now renders**: Date, Type, Amount, Account, Payee, Category, Tags, Status, Number,
Notes and Color, with their combo boxes, popups, text fields, the round buttons down the right
side, a Notes text area, and Save, Save and New and Cancel. Resized to 1000x600 the main window
reflows behind it and the dialog keeps its size and every field.

**Two defects remain on it.** The Tags row draws a solid black rectangle where its text control
should be. And the Date row shows only the weekday, Saturday, with no date and no visible
`wxNSDatePicker`, which is the same missing control as Opening Date in Edit Account.

## A surface that wrote its pixels in an order it did not read them in

The tag drop button next to the Tags row came out bright purple. The numbers name it without any
guessing:

    the button          srgb(122,0,255)
    accent blue, as it renders in iA Writer and in the mmex table selection    srgb(0,122,255)

Red and green swapped, exactly. As one 32-bit pixel that is the bytes FF 00 7A FF written alpha
first and read back as B, G, R, A.

`CIDER_TRACE_IMAGESOURCE` says wx asks for that button as `18x18 info=0x6`, which is
`kCGImageAlphaNoneSkipFirst` with byte order **Default**, and for the tag text area as `210x18` in
the same format. `O2Image.m` already treats Default as the order the components are named in, A
then R then G then B in memory, on every machine, with a long comment about the LibreOffice folder
icon that came out violet. `O2Surface.m` still picked the host order for the same value. So a single
surface object read its own pixels back in an order it had not written them in.

cocotron 0114 gives the writer the same default as the reader, and adds the big endian case to
`kCGImageAlphaPremultipliedFirst`, which had none and would otherwise have fallen through to no
writer at all once the default was coerced. After it the button is exactly `srgb(0,122,255)`, the
same 106 pixels, so only the colour moved.

**The black Tags box is a different defect** and is still open: 3570 pixels of pure black inside the
control border, unchanged by the byte order fix.

## The black Tags box, characterised

The Tags row is a solid black rectangle. It is not dead: clicking it and typing `food` brings up a
`New tag entered` dialog asking `Create new tag 'food'?`, so the control takes keyboard input and
the application sees it. Only the painting is wrong.

**What it is.** `mmTagTextCtrl` embeds a `wxStyledTextCtrl`, which is Scintilla. The tree shows it
as a `wxNSView 210x18` with two hidden `wxNSScroller`s, which is that shape exactly.

**What is drawn there, in order**, from `CIDER_TRACE_PAINT=110,250,230,60` on the dialog surface:

    path   blend=17  229x18 at 116,278   c=1.000,1.000     the white background, correct
    image  blend=0   210x18 at 117,255                     an image blitted over it

So a correct white fill is covered by a 210x18 image. And that image is all zeros, which as an
opaque XRGB pixel is black.

**Nothing is ever written into it.** `CIDER_TRACE_SURFACE_WIDTH=210` (cocotron 0115) counts every
span that reaches a surface of that width: ZERO. The same probe with `=18` reports 60 writes to the
drop button surface with pixels `a=ff,r=00,g=7a,b=ff`, so the instrument speaks and the port writes
pixels correctly when anything asks it to. `CIDER_TRACE_PAINT` agrees: no path, image or shading
ever targets a 210x18 surface.

**Who makes the buffer**, from the creation backtrace also added in cocotron 0115:

    wxStyledTextCtrl::OnPaint -> wxBufferedPaintDC -> wxSharedDCBufferManager::GetBuffer   x1
    ScintillaWX::DoPaint -> Scintilla::Editor::Paint -> SurfaceImpl::InitPixMap            x2
    wxBufferedDC::UnMask -> wxGCDCImpl::DoBlit -> wxBitmap::GetSubBitmap                   x3

So Scintilla really does reach `Editor::Paint` and allocate its own pixmaps, and then draws into
none of them.

**What is NOT the cause.** The update region is correct: `CIDER_TRACE_FRAMES=wxNSView` prints
`CIDER_RECTS wxNSView count=1 first=210x18 at 0,0` for that view, so wx is told its whole client
area is dirty. The byte order fix of cocotron 0114 does not touch it either.

**The next step** is why `Editor::Paint` returns without drawing when it has a non empty area and a
pixmap. The candidate worth measuring first is `paintAbandoned`, which Scintilla sets when the
scrollbar state changes during a paint: it then returns having drawn nothing, repaints to the
window instead, and the buffered DC blits its untouched buffer over the top. That would explain
every measurement above, and this port has two scrollers on that control that are both hidden.

## The date field that was never there

Both the Edit Account Opening Date row and the New Transaction Date row had a label and no control.
The tree said why in one line: `wxNSDatePicker 16x16@0,0`, inside a parent that was also 16x16.

**Three defects in a row, each one hiding the next.**

`NSDatePicker` never overrode `+cellClass`. `-[NSControl initWithFrame:]` builds its cell from that,
and `NSControl` answers it out of a dictionary keyed by the class NAME, so registering one would
have missed the subclass anyway: wxWidgets instantiates `wxNSDatePicker`. With no cell the control
measures nothing, wx reads 0 from `GetBestRect`, which calls `sizeToFit`, and falls back to 16x16.

Giving it `NSDatePickerCell` then terminated the application, because that class had ONLY
`-initWithCoder:`. A cell built in code had no calendar, no text colour and no elements, and the
first thing `-_attributedStrings` does with those is put the text colour into an attributes
dictionary, which raises on nil.

With an initialiser it terminated again, and `CIDER_TRACE_EXCEPTIONS` named it without any
guessing: `-[__NSCFConstantString timeIntervalSinceReferenceDate]: unrecognized selector`. An
`NSCell` object value is whatever was set, and a cell that starts life as a text cell holds an empty
STRING; `-dateValue` handed that straight to `NSCalendar`.

cocotron 0117 adds the cell class, an initialiser with the same defaults the archive path ends up
with, a `-dateValue` that insists on a date, a `-textColor` that never answers nil, and a `-cellSize`
that measures what the cell actually draws.

**After it** the Date row reads `9/22/2026` in a bezeled field with its stepper, and the weekday
label beside it reads Tuesday, which is what that date is. It had read Saturday before, from a
control the application could never fill.

**Confirmed on both surfaces.** Edit Account, reached from the populated main window by expanding
Bank Accounts, selecting CiderBank, then Accounts and Edit Account and choosing the account in the
Choose Account to Edit list, shows Account Name, Account Type, Account Status, Initial Balance,
`Opening Date: 9/22/2026`, Currency: Australian dollar, a ticked Favorite Account, a notes area and
OK and Cancel.

**And the account register is new coverage.** Selecting CiderBank in the tree opens Account View:
CiderBank with its balance line, an All filter, a date range field, the column header row of SN,
ID, Date, Number, Category, Tags and Withdrawal, and New, Edit, Duplicate, Delete, Enter and Skip
along the bottom with a Search field.

## The keystroke that killed the application

Typing into the New Transaction dialog ended the process. Not a crash and not an exception: a clean
`cider-app exit=0` with every capture from the first keystroke onward black, and the reason printed
at the very end of the log:

    abort_with_payload: reason: dyld cache load error: shared cache file open() failed
    Symbol not found: _CGEventSourceKeyState
      Referenced from: /Applications/mmex.app/Contents/MacOS/mmex
      Expected in: /System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics

`CGEventSourceKeyState` is DECLARED in our own `CGEventSource.h` and was never defined, so the
first application to reach it died on the lazy bind rather than getting a wrong answer. cocotron
0118 defines it.

Only the modifiers can be answered at all. Input in this port arrives from the compositor straight
into AppKit as NSEvents and never passes through a CGEvent source, so there is no table of pressed
keys; an ordinary key answers NO, which is what it is for all but the instant it is held, and the
modifier keys are answered from the flag state the file already keeps.

After it, typing works: Amount takes `12.34` and shows it right aligned, and the Payee combo takes
its text. Save with Account and Category still empty leaves the dialog open, which is Money Manager
Ex refusing an incomplete transaction rather than anything about the port.

## What this still does not cover

The Dashboard pane on the right is empty. Money Manager Ex renders it as HTML in a `wxWebView`,
which is `WKWebView` here, and this port stubs WebKit, so there is nothing to draw. The stubs at
least answer nil now rather than a leftover register.

Opening an account register, entering a transaction, and everything reached from the Navigator tree.

No credentials of any kind are involved here. Money Manager Ex is a local finance tracker with a
SQLite file; it is not MoneyMoney and it talks to no bank.
