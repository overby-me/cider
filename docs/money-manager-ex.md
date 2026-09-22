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

## What this still does not cover

Past the New Database Wizard sits the Add Account Wizard, which is open and unexercised. The
populated main window and the Navigator filled with accounts are reachable from there and have not
been driven yet.

No credentials of any kind are involved here. Money Manager Ex is a local finance tracker with a
SQLite file; it is not MoneyMoney and it talks to no bank.
