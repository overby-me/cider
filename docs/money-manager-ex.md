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

**The Account Type control draws an empty box.** It is empty on wizard page two and both the Account
Type and Account Status controls are empty in the Edit Account dialog. It is not an
`NSPopUpButton` reached through `-[NSPopUpButtonCell setMenu:]`, because a trace on that selector and
on every menu item added to a pop-up printed nothing for it while printing four lines for the save
panel. What it actually is has not been established.

**The paragraphs on page two are cut off.** "General bank accounts cover a wide variety of account",
"Investment and Share accounts are specialized accounts that" and "Term and asset accounts are
specialized bank accounts. They are intended for monitoring assets or term" each stop mid sentence,
at a different x, on one line. The intro paragraphs on page one wrap correctly over two lines, so
multi line static text works in general; these three look like text that was never wrapped and is
clipped by a view narrower than the line, which points at text measurement rather than at drawing.

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

**Honest status of that fix.** Three runs of the transition after it: all three opened the dialog,
and none of them took the activation path at all, so they neither exercise the guard nor prove it.
The case for it is the correlation above and the protocol rule, not a converted failure. The guard
prints `cider-wayland-activation ask=dropped requester=... gone` when it fires, so the next run that
would have died says so instead.

## What this still does not cover

The populated main window past the Edit Account dialog, the Navigator filled with accounts, and
everything after that.

No credentials of any kind are involved here. Money Manager Ex is a local finance tracker with a
SQLite file; it is not MoneyMoney and it talks to no bank.
