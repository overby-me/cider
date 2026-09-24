#!/usr/bin/env bash
# CLEAR THE START CENTER FRAME LIBREOFFICE PERSISTS, so a repeated drive measures one state.
#
# WHY THIS EXISTS. One drive on a 1256x850 output left 0,50,1256,634 in ooSetupFactoryWindowAttributes,
# and every later run at 1256x684 then FITS where it used to overhang: 128609 bytes instead of 136647,
# reproducible either way, with nothing in the port changed. The sweep baseline was reading residue.
set -u
PREFIX=${1:-/tmp/cider-lo-1000/prefix}
F="$PREFIX/Users/root/Library/Application Support/LibreOffice/4/user/registrymodifications.xcu"
[ -f "$F" ] || exit 0
python3 - "$F" <<'PY'
import re, sys
path = sys.argv[1]
before = open(path, encoding="utf-8").read()
after = re.sub(
    r'<item oor:path="[^"]*Factory\[.com\.sun\.star\.frame\.StartModule.\]">'
    r'<prop oor:name="ooSetupFactoryWindowAttributes".*?</item>',
    "", before, flags=re.S)
if after != before:
    open(path, "w", encoding="utf-8").write(after)
PY
