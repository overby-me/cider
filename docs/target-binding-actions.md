# The action of a target binding travels in the options

Interface Builder wires a control or a menu item to code in two ways, and until 2026-09-23 this
port understood only one of them.

## The two wirings

**A control connector.** `NSNibControlConnector` carries the selector in its `NSLabel`, the
sending object in `NSSource` and the receiver in `NSDestination`. We decode it, and it is what
almost every menu item in almost every nib uses.

**A target binding.** `NSNibBindingConnector` with `NSBinding` equal to `target`. The receiving
object arrives as the binding destination, reached through `NSKeyPath` (usually the literal
`self`), and **the selector arrives as the `NSSelectorName` entry of the options dictionary.**

The second one is what Interface Builder produces when you bind a menu item to an object in the
bindings inspector rather than dragging a connection, and it is the only way to point an item at
something reached by a key path.

## What was wrong

`-[NSObject bind:toObject:withKeyPath:options:]` built a `_NSKVOBinder`, and the binder applied
the observed value to the `target` key. So the item ended up with the correct target and the
options were dropped on the floor.

An `NSMenuItem` with a target and no action is **disabled**. The command was therefore not merely
mis-wired: it was unreachable, greyed, and a click on it did nothing.

Neither `NSTargetBinding` nor `NSSelectorNameBindingOption` existed anywhere in this AppKit, so
nothing had ever read that option. `grep -rn NSSelectorName vendor/src/cocotron/AppKit` returned
nothing at all before cocotron 0138.

## How it was found, and two wrong turns on the way

The symptom was a recorded note that MoneyMoney ends up with about eighteen menu items carrying a
real target and a NULL action.

**First wrong turn: the instrument.** `CIDER_TRACE_MENUITEM_DECODE` hooked `setTarget:` and
`setAction:` only, and `-[NSMenuItem initWithTitle:action:keyEquivalent:]` assigns `_action`
directly. Every item an application builds in code therefore read as actionless. Tracing the
initialiser (cocotron 0137) took the count from 25 down to 10; the other 15 were menu bar items
whose target is their own `NSMenu` and popup items whose target is the cell, both correct.

**Second wrong turn: the conclusion.** With the archive showing no control connector and no
`NSAction` key for those ten, the note concluded that the nib gives them nothing and the
application must build them in code. The nib gives them everything. What the accounting had never
looked at was the 230 `NSNibBindingConnector` entries sitting alongside the 81 control connectors.

The measurement that settled it: ten `target` bindings in the archive, ten items measured at
runtime with a target and no action, one to one, and the trace of the late `setTarget:` burst
shows them arriving in a block of their own after the app finished its own action-then-target
pairs.

## How much of the roster this reaches

Counted over the staged applications, `target` and `doubleClickTarget` bindings in every nib the
dumper can read:

| application | nibs read | target bindings | all naming a selector |
| --- | --- | --- | --- |
| MoneyMoney | 90 | 23 | yes |
| iA Writer | 47 | 2 | yes |
| Swift Publisher 5 | 104 | 0 | n/a |
| iTerm2 | 451 | 0 | n/a |
| CMake | 0 | 0 | n/a |

MoneyMoney's 23 are ten in the English `MainMenu.nib`, the same ten in the German one, and three
that are not menu items at all: two buttons in `PreferencesWindow.nib` (`purchase:`,
`showPurchaseHelp:`) and one in `SpotlightWindow.nib` (`showInFinder:`). iA Writer's two are the
Add Pattern and Remove Pattern buttons in `CustomPatternsPreferences.nib`.

A caveat on the zeros: 118 of Swift Publisher's 222 nibs are the older keyed archive format that
`scripts/nibdump.py` asserts on, nearly all of them inside Sparkle. That zero covers the 104 it
can read.

## The ten MoneyMoney commands

| item | destination | selector |
| --- | --- | --- |
| About MoneyMoney | AboutWindowController | `showAboutWindow:` |
| Encrypt File for Sending... | MainWindowController | `encryptFileForSupport:` |
| Help and FAQ... | MainWindowController | `openGeneralHelp:` |
| Imprint... | MainWindowController | `showImprint:` |
| License Agreement... | MainWindowController | `showLicenseAgreement:` |
| Privacy Policy... | MainWindowController | `showPrivacyPolicy:` |
| Report an Issue... | MainWindowController | `reportIssue:` |
| Show Database in Finder... | MainWindowController | `openDatabaseInFinder:` |
| Supported Banks (Europe)... | MainWindowController | `openPsd2Help:` |
| Supported Banks (Germany)... | MainWindowController | `openBankHelp:` |

That is the whole application menu and the whole Help menu, which is why the symptom looked like a
menu defect rather than a bindings one.

## Verified end to end

Driving the application menu and choosing the first item, after cocotron 0138:

- tracking returns `item=About MoneyMoney enabled=1 action=showAboutWindow:`
- `AboutWindow.nib` loads and connects its six outlets
- window 5, an `MMPanel` titled About MoneyMoney, 640x362, maps at t=123
- the capture shows the About window over the main window with the illustration, the logo, the
  version line, the copyright and both buttons

Before the change the item was disabled and a click on it did nothing.

ONE DETAIL IN THAT CAPTURE IS NOT RIGHT, and it belongs to the application rather than to this
change. The line reads `Bank server settings from` with nothing after it. The nib placeholder for
that label is `Bank server settings from xx.xx.xxxx` and its outlet is `settingsTextField`, so the
application DID replace the string and formatted an empty date into it. Not chased yet; it is only
visible at all because the window now opens.

## How to check this for any application

```
python3 scripts/nibdump.py <some.nib>
```

and look for `NSNibBindingConnector` objects whose `NSBinding` is `target`. Their `NSOptions`
dictionary holds `NSSelectorName` next to the selector. At runtime,
`CIDER_TRACE_MENUITEM_DECODE=1` prints a `CIDER_ITEMSET action` line for every item that receives
one by any route, initialiser included.

## The one way this change could regress, measured

If an object carried BOTH a control connector and a target binding, whichever was established last
would win, and setting the action from the binding could overwrite a correct one. Counted over the
four nibs that hold all twenty five target bindings:

| nib | target bindings | control connectors | objects with both |
| --- | --- | --- | --- |
| MoneyMoney MainMenu.nib | 10 | 81 | 0 |
| MoneyMoney PreferencesWindow.nib | 2 | 19 | 0 |
| MoneyMoney SpotlightWindow.nib | 1 | 1 | 0 |
| iA Writer CustomPatternsPreferences.nib | 2 | 2 | 0 |

No object in the roster uses both wirings, which is what you would expect since Interface Builder
offers them as alternatives. The overlap is zero rather than assumed to be zero.

## Two adjacent things checked and found already correct

Both were suspected for the same reason as the `target` binding, and both turned out to be
implemented, which is worth recording so the next reader does not chase them again.

**The peer `enabled2`..`enabled5` bindings.** Across the 506 nibs scanned there are 158
`enabled2`, 110 `enabled3`, 66 `enabled4` and 2 `enabled5`, and none of those is a real property. `-[_NSBinder peerBinders]`
already strips a trailing digit when the key path does not resolve and groups the binder with its
base-name peers, so they are ANDed as they should be.

**`NSValueTransformerName`.** It is the most common option in the whole roster by a wide margin,
1191 uses across 506 nibs. `-[_NSBinder valueTransformer]` reads both it and
`NSValueTransformerBindingOption` and resolves the name through `NSValueTransformer`.

**The `argument` binding**, which pairs with `target` on five of the twenty five, is NOT
implemented: `argument` is not a property of an `NSButton`, so the write raises and is swallowed by
the catch in `-[_NSKVOBinder applyToSource]`, which `CIDER_TRACE_CONTROL` already reports. It
costs nothing for these five because each binds its argument to the control itself, which is the
sender the action would receive anyway. It would matter for a control that binds a DIFFERENT
object as the argument, and no roster application does.

## Option keys the roster actually uses

Counted over 506 readable nibs in MoneyMoney, iA Writer and iTerm2:

| option | uses |
| --- | --- |
| NSValueTransformerName | 1191 |
| NSNullPlaceholder | 584 |
| NSNotApplicablePlaceholder | 480 |
| NSMultipleValuesPlaceholder | 478 |
| NSNoSelectionPlaceholder | 478 |
| NSValidatesImmediately | 106 |
| NSDisplayPattern | 34 |
| NSSelectorName | 30 |
| NSContinuouslyUpdatesValue | 9 |
| NSAllowsEditingMultipleValuesSelection | 6 |
| NSConditionallySetsEnabled | 6 |
| NSRaisesForNotApplicableKeys | 2 |

The 30 `NSSelectorName` are 25 on `target` and 5 on `argument`, the five being the same five
objects that carry both.

## The two constants are still not declared, deliberately

`NSTargetBinding` (`@"target"`) and `NSSelectorNameBindingOption` (`@"NSSelectorName"`) are real
AppKit API and this port still does not declare either; cocotron 0138 compares against the string
literals instead. That is a real gap, and it is left open on purpose for now: no binary in the
staged roster imports either symbol (checked with `nm -u` over all seven), and declaring them means
editing `NSKeyValueBinding.h`, which rebuilds everything downstream of that header and would
invalidate the gate run the fix was measured on. Worth doing next time that header is touched for
another reason.

## A check that would have caught this

`scripts/checks/menu-action-analyse.py` reads the `CIDER_ITEMSET` lines from a drive made with
`CIDER_TRACE_MENUITEM_DECODE=1` and reports every menu item that ends up with a real target and no
action, which is the state that makes a command unreachable. It excludes the two targets that are
correctly actionless: `NSMenu`, for a menu bar item whose target is its own submenu, and
`NSPopUpButtonCell`, for a popup item.

It has a control on both sides, from the same application and the same 110 titles:

```
DEAD    captures/mm-decode2/app.log   titles=110  unreachable=10   (before cocotron 0138)
OK      captures/mm-bind/app.log      titles=110  unreachable=0    (after)
```

A log with no `CIDER_ITEMSET` lines reports `NOTRACE` and fails rather than passing, because a
drive that never ran and an application with no defect are otherwise identical, and a missing file
reports `MISSING`. All four outcomes were exercised before the script was committed.

It is not wired into the roster sweep yet. Doing so means adding `CIDER_TRACE_MENUITEM_DECODE=1`
to the sweep environment and running the analyser over each `captures/sweep-*/app.log`, which
would give the whole roster this coverage for the cost of one extra environment variable.
