#!/usr/bin/env python3
"""What LibreOffice needs that this fork has but does not MEAN, as one work list.

The missing-symbol sweep (docs/libreoffice-gap.md) is a different question and is already
answered. It finds what the linker cannot resolve, and it is exhausted: the walls since then have
all been things that LINK CLEANLY AND DO NOTHING.

    a C function that exists and prints STUB and returns nil
    an ObjC method that exists and calls NSUnimplementedMethod
    a selector no class here implements at all

None of those three is an undefined symbol, so none can be found by comparing symbol tables. This
finds them instead, by reading our own sources for the markers we already write, and intersecting
with what the application actually references.

Usage:
    scripts/lo-work-list.py <app-bundle> <source-root>...
"""
import os
import re
import subprocess
import sys

# A function body that contains one of these is present, linkable, and useless.
STUB_MARKERS = ("printf(\"STUB", "NSUnimplementedMethod(", "NSInvalidAbstractInvocation(")

C_FUNC = re.compile(
    r'^[A-Za-z_][A-Za-z0-9_ \t\*]*?\b([A-Za-z_][A-Za-z0-9_]*)\s*\([^;{]*\)\s*\{', re.M)
OBJC_METHOD = re.compile(r'^[-+]\s*\(([^)]*)\)\s*([^{;]+)\{', re.M)


def body_of(text, brace_pos):
    """The text between the brace at brace_pos and its match, or a bounded slice."""
    depth, i, n = 0, brace_pos, len(text)
    while i < n:
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[brace_pos:i]
        i += 1
    return text[brace_pos:brace_pos + 4000]


def selector_of(decl):
    """The selector from an ObjC method declaration, e.g. 'setFoo: (int) x bar: (int) y'."""
    parts = re.findall(r'([A-Za-z_][A-Za-z0-9_]*:)', decl)
    if parts:
        return "".join(parts)
    m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*$', decl.strip())
    return m.group(1) if m else None


def scan_sources(roots):
    """(stub_c_functions, stub_selectors, all_defined_selectors)"""
    stub_funcs, stub_sels, all_sels = {}, {}, set()
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in ("buck-out", ".git", ".jj", "submodules")]
            for name in filenames:
                if not name.endswith((".m", ".c", ".mm")):
                    continue
                path = os.path.join(dirpath, name)
                try:
                    text = open(path, errors="ignore").read()
                except OSError:
                    continue
                for m in OBJC_METHOD.finditer(text):
                    sel = selector_of(m.group(2))
                    if not sel:
                        continue
                    all_sels.add(sel)
                    body = body_of(text, m.end() - 1)
                    if any(k in body for k in STUB_MARKERS):
                        stub_sels.setdefault(sel, path)
                for m in C_FUNC.finditer(text):
                    fn = m.group(1)
                    if fn in ("if", "for", "while", "switch", "return", "sizeof"):
                        continue
                    body = body_of(text, m.end() - 1)
                    if any(k in body for k in STUB_MARKERS):
                        stub_funcs.setdefault(fn, path)
    return stub_funcs, stub_sels, all_sels


def app_machos(bundle):
    out = []
    for dirpath, _dirnames, filenames in os.walk(bundle):
        for name in filenames:
            p = os.path.join(dirpath, name)
            if os.path.islink(p) or not os.path.isfile(p):
                continue
            try:
                with open(p, "rb") as f:
                    if f.read(4) not in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
                        continue
            except OSError:
                continue
            out.append(p)
    return out


def app_imports_and_selectors(bundle):
    imports, selectors = set(), set()
    for path in app_machos(bundle):
        try:
            r = subprocess.run(["llvm-nm", "-u", path], capture_output=True, text=True, timeout=120)
            for line in r.stdout.splitlines():
                s = line.strip()
                if s.startswith("U "):
                    s = s[2:].strip()
                if s.startswith("_"):
                    imports.add(s[1:])
        except Exception:
            pass
        # Selector names live in their own cstring section, which is exactly the set of
        # selectors this binary can send.
        try:
            r = subprocess.run(
                ["llvm-objdump", "--macho", "--section", "__TEXT,__objc_methname", path],
                capture_output=True, text=True, timeout=180)
            for line in r.stdout.splitlines():
                m = re.match(r'^[0-9a-f]+\s+(.+)$', line.strip())
                if m:
                    selectors.add(m.group(1).strip())
        except Exception:
            pass
    return imports, selectors


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    bundle, roots = sys.argv[1], sys.argv[2:]

    print("reading the application...", file=sys.stderr)
    imports, selectors = app_imports_and_selectors(bundle)
    print(f"  {len(imports)} imported symbols, {len(selectors)} selector names", file=sys.stderr)

    print("reading our sources...", file=sys.stderr)
    stub_funcs, stub_sels, all_sels = scan_sources(roots)
    print(f"  {len(stub_funcs)} stubbed C functions, {len(stub_sels)} stubbed methods, "
          f"{len(all_sels)} methods defined", file=sys.stderr)

    wanted_funcs = sorted(f for f in stub_funcs if f in imports)
    wanted_sels = sorted(s for s in stub_sels if s in selectors)
    # A selector the application can send that NOTHING here defines. Heuristic by nature: the
    # application also sends selectors to its own classes, so this over-reports and is ranked
    # last for that reason.
    absent = sorted(s for s in selectors
                    if s not in all_sels and re.match(r'^[a-z][A-Za-z0-9_:]*$', s)
                    and (s.startswith("accessibility") or s.startswith("set") or ":" not in s))

    print(f"\n== STUBBED C FUNCTIONS THE APPLICATION IMPORTS: {len(wanted_funcs)}")
    for f in wanted_funcs:
        print(f"     {f}   [{stub_funcs[f]}]")

    print(f"\n== STUBBED METHODS WHOSE SELECTOR THE APPLICATION USES: {len(wanted_sels)}")
    for s in wanted_sels:
        print(f"     {s}   [{stub_sels[s]}]")

    print(f"\n== SELECTORS THE APPLICATION USES THAT NOTHING HERE DEFINES: {len(absent)}"
          f"  (heuristic, includes the application's own)")
    for s in absent[:60]:
        print(f"     {s}")
    if len(absent) > 60:
        print(f"     ... and {len(absent) - 60} more")


if __name__ == "__main__":
    main()
