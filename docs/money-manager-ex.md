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

## What this does not cover

The wizard was opened and not completed, so everything past its first page is still unexercised:
the currency and account pages, and the main window populated with real data. The Navigator panel
is empty because no database was loaded before this, and whether it fills correctly after the
wizard finishes is unmeasured.

No credentials of any kind are involved here. Money Manager Ex is a local finance tracker with a
SQLite file; it is not MoneyMoney and it talks to no bank.
