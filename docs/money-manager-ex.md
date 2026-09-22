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

## What this still does not cover

The wizard was never completed, because finishing it needs a currency selected in the Currency
Manager and that click was not driven. So the populated main window, the Navigator filled with
accounts, and everything past the wizard remain unexercised.

No credentials of any kind are involved here. Money Manager Ex is a local finance tracker with a
SQLite file; it is not MoneyMoney and it talks to no bank.
