#!/usr/bin/env python3
# WHICH MENU ITEMS CAN NEVER FIRE.
#
# An NSMenuItem that ends up with a real target and NO action is DISABLED, so the command is
# unreachable. Reads the CIDER_ITEMSET lines that CIDER_TRACE_MENUITEM_DECODE=1 writes and reports
# every title in that state.
#
# The trace covers all three routes an action can arrive by: initWithTitle:action:keyEquivalent:,
# setAction: and the decoder. Before cocotron 0137 it was blind to the initialiser, and that
# blindness reported 25 defects where there were 10.
#
# Targets that are CORRECT with no action, and are excluded:
#   NSMenu             a menu bar item, whose target is its own submenu
#   NSPopUpButtonCell  a popup item, whose target is the cell
import re, sys, os

EXPECTED_ACTIONLESS = ("NSMenu", "NSPopUpButtonCell")

def analyse(path):
    action, target, titles = set(), {}, set()
    for line in open(path, errors="replace"):
        m = re.match(r"CIDER_ITEMSET (init|action|target) title=(.*?) (?:sel|to)=(\S*)\s*$", line)
        if not m:
            continue
        kind, title, value = m.groups()
        titles.add(title)
        if kind in ("init", "action") and value not in ("NULL", "(null)"):
            action.add(title)
        elif kind == "target" and value not in ("nil", "(nil)"):
            target[title] = value
    dead = sorted(t for t, cls in target.items()
                  if t not in action and not cls.replace("NSKVONotifying_", "").startswith(EXPECTED_ACTIONLESS))
    return titles, dead

if len(sys.argv) < 2:
    print("usage: menu-action-analyse.py <app.log> [app.log...]")
    sys.exit(2)

rc = 0
for path in sys.argv[1:]:
    if not os.path.exists(path):
        print("MISSING %s" % path); rc = 1; continue
    titles, dead = analyse(path)
    if not titles:
        # A LOG WITH NO TRACE AT ALL IS NOT A PASS. Either the drive never ran or the switch was
        # not set, and both are silent in exactly the same way an application with no defect is.
        print("NOTRACE %-34s no CIDER_ITEMSET lines at all, was CIDER_TRACE_MENUITEM_DECODE set" % path)
        rc = 1; continue
    print("%-7s %-34s titles=%-4d unreachable=%d"
          % ("DEAD" if dead else "OK", path, len(titles), len(dead)))
    for t in dead:
        print("          %s" % t)
    if dead:
        rc = 1
sys.exit(rc)
