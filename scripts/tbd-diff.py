#!/usr/bin/env python3
"""tbd-diff.py - the supply side of the Phase B symbol gap.

Parses the SDK's libSystem.tbd re-export closure to get the *official*
macOS-14 export set, extracts Darling's *actual* export set from our built
system dylibs, and diffs them - optionally intersected with the demand list
from symbol-demand.sh so the output is exactly the symbols that (a) real
binaries import, (b) macOS 14 provides, and (c) Darling still lacks.

No third-party deps (no PyYAML): the .tbd files are regular enough to parse
directly. Handles tbd-version 4 (YAML-ish, the 14.4 SDK) and tbd-version 5
(JSON) shells.

Usage:
  scripts/tbd-diff.py --sdk <apple-sdk-path> \
      [--arch x86_64] [--platform macos] \
      [--root <libSystem.tbd or dir>] \
      [--darling-root <darling prefix or dir of dylibs>] \
      [--demand <symbol-demand.json>] \
      [--out plan/symbol-gap.md] [--json out.json]

Typical:
  SDK=$(nix eval --raw 'github:NixOS/nixpkgs/<rev>#legacyPackages.x86_64-darwin.apple-sdk.outPath')
  scripts/tbd-diff.py --sdk "$SDK" \
    --darling-root result/libexec/darling/usr/lib \
    --demand scratch/demand.json --out plan/symbol-gap.md
"""

import argparse
import json
import os
import re
import subprocess
import sys


def find_sdk_root(sdk):
    """Locate the MacOSX*.sdk directory inside an apple-sdk store path."""
    if os.path.isfile(os.path.join(sdk, "usr", "lib", "libSystem.tbd")):
        return sdk
    for dirpath, dirnames, _ in os.walk(sdk):
        for d in dirnames:
            if d.endswith(".sdk"):
                cand = os.path.join(dirpath, d)
                if os.path.isfile(os.path.join(cand, "usr", "lib", "libSystem.tbd")):
                    return cand
    return sdk


def _target_matches(targets, arch, platform):
    """True if any `arch-platform` target token matches (arch e.g. x86_64)."""
    want = f"{arch}-{platform}"
    for t in targets:
        t = t.strip().strip("'\"")
        if t == want:
            return True
    return False


def _collect_bracket_list(lines, i):
    """Given lines[i] contains a '[', accumulate through the matching ']'.
    Returns (items, next_index)."""
    buf = []
    depth = 0
    while i < len(lines):
        seg = lines[i]
        depth += seg.count("[") - seg.count("]")
        buf.append(seg)
        i += 1
        if depth <= 0:
            break
    text = " ".join(buf)
    inside = text[text.find("[") + 1 : text.rfind("]")]
    items = [x.strip().strip("'\"") for x in inside.split(",")]
    return [x for x in items if x], i


def parse_tbd_v4(path, arch, platform):
    """Return (install_names, reexports, symbols) for the given target.

    install_names: list (this file's install-name(s))
    reexports:     list of install names re-exported (target-filtered)
    symbols:       set of exported symbols (target-filtered, real symbols only)
    """
    with open(path, "r", errors="replace") as fh:
        raw = fh.read()

    # tbd-version 5 is JSON.
    if raw.lstrip().startswith("{") or "tapi-tbd-v5" in raw[:64]:
        return parse_tbd_v5(raw, arch, platform)

    lines = raw.splitlines()
    install_names = []
    reexports = []
    symbols = set()

    # In tbd v4, top-level keys sit at column 0 (no indentation); the content
    # of a section (its list entries and their `targets:`/`symbols:`/
    # `libraries:` fields) is indented. Track the current top-level section by
    # watching for unindented `key:` lines; treat everything indented as its
    # content. This is robust to intervening keys (objc-classes,
    # allowable-clients, ...) that a heuristic reset would trip over.
    section = None       # "exports" | "reexports" | "reexported-libraries" | None
    cur_targets = None   # per-entry targets, reset at each `- targets:` item

    def in_target():
        return cur_targets is None or _target_matches(cur_targets, arch, platform)

    i = 0
    while i < len(lines):
        ln = lines[i]
        s = ln.strip()
        indented = ln[:1] in (" ", "\t")

        # Top-level key (column 0) -> (re)set section context.
        if not indented and re.match(r"^[A-Za-z_][A-Za-z0-9_-]*:", s):
            key = s.split(":", 1)[0]
            if key in ("exports", "reexports", "reexported-libraries"):
                section = key
            else:
                section = None
            m = re.match(r"^install-name:\s*'?([^'\n]+?)'?\s*$", s)
            if m:
                install_names.append(m.group(1).strip().strip("'\""))
            i += 1
            continue

        if section is None:
            i += 1
            continue

        # Inside a section: entries begin with `- targets:`; each has one of
        # symbols/weak-symbols (exports) or libraries (reexported-libraries).
        if "targets:" in s:
            cur_targets, i = _collect_bracket_list(lines, i)
            continue

        if section == "reexported-libraries" and "libraries:" in s:
            libs, i = _collect_bracket_list(lines, i)
            if in_target():
                reexports.extend(libs)
            continue

        if section in ("exports", "reexports") and \
           ("symbols:" in s or "weak-symbols:" in s):
            syms, i = _collect_bracket_list(lines, i)
            if in_target():
                for sym in syms:
                    if sym.startswith("$ld$"):   # linker-directive pseudo-symbols
                        continue
                    symbols.add(sym)
            continue

        i += 1

    return install_names, reexports, symbols


def parse_tbd_v5(raw, arch, platform):
    """Minimal tbd-v5 (JSON) parser."""
    data = json.loads(raw)
    install_names, reexports, symbols = [], [], set()
    want = f"{arch}-{platform}"
    for lib in data.get("main_library", {}).get("install_names", []):
        install_names.append(lib.get("name"))
    main = data.get("main_library", {})
    for grp in main.get("reexported_libraries", []):
        if want in grp.get("targets", []):
            reexports.extend(grp.get("names", []))
    for grp in main.get("exported_symbols", []):
        tgts = grp.get("targets", [])
        if want in tgts or not tgts:
            for kind in ("global", "data", "text", "weak"):
                for sym in grp.get(kind, []):
                    if not sym.startswith("$ld$"):
                        symbols.add(sym)
    return install_names, reexports, symbols


def tbd_path_for_install_name(sdk_root, install_name):
    """Map an install name (/usr/lib/system/libx.dylib) to its .tbd in the SDK."""
    rel = install_name.lstrip("/")
    base = os.path.join(sdk_root, rel)
    for cand in (base[:-6] + ".tbd" if base.endswith(".dylib") else base,
                 base + ".tbd", base):
        if os.path.isfile(cand):
            return cand
    return None


def collect_official(sdk_root, root_tbd, arch, platform):
    """Walk the reexport closure from root_tbd; return {symbol: install_name}."""
    supply = {}
    seen = set()
    stack = [root_tbd]
    while stack:
        tbd = stack.pop()
        if tbd in seen or not tbd or not os.path.isfile(tbd):
            continue
        seen.add(tbd)
        names, reexports, symbols = parse_tbd_v4(tbd, arch, platform)
        owner = names[0] if names else tbd
        for sym in symbols:
            supply.setdefault(sym, owner)
        for rex in reexports:
            nxt = tbd_path_for_install_name(sdk_root, rex)
            if nxt:
                stack.append(nxt)
    return supply


def collect_darling(root, arch):
    """nm every dylib under `root`; return set of defined external symbols."""
    nm = which("llvm-nm") or which("nm")
    if not nm:
        sys.exit("error: need llvm-nm or nm on PATH")
    defined = set()
    dylibs = []
    for dp, _, files in os.walk(root):
        for f in files:
            if f.endswith(".dylib") or f.endswith(".B.dylib") or ".dylib." in f:
                dylibs.append(os.path.join(dp, f))
    for lib in dylibs:
        try:
            out = subprocess.run(
                [nm, f"--arch={arch}", "-gU", lib],
                capture_output=True, text=True, timeout=120).stdout
        except Exception:
            continue
        for line in out.splitlines():
            parts = line.split()
            # "<addr> <type> <name>" for defined; type in T/D/B/S/etc.
            if len(parts) >= 3 and parts[1] in ("T", "D", "B", "S", "R", "G", "I"):
                defined.add(parts[2])
            elif len(parts) == 2 and parts[0] in ("T", "D", "B", "S", "R", "G", "I"):
                defined.add(parts[1])
    return defined, len(dylibs)


def which(x):
    for p in os.environ.get("PATH", "").split(os.pathsep):
        cand = os.path.join(p, x)
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def load_demand(path):
    if not path:
        return None
    with open(path) as fh:
        data = json.load(fh)
    return {e["symbol"]: e.get("refs", 0) for e in data.get("symbols", [])}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sdk", required=True)
    ap.add_argument("--arch", default="x86_64")
    ap.add_argument("--platform", default="macos")
    ap.add_argument("--root", help="root .tbd (default: <sdk>/usr/lib/libSystem.tbd)")
    ap.add_argument("--darling-root", help="dir of Darling's built dylibs")
    ap.add_argument("--demand", help="symbol-demand.json to intersect with")
    ap.add_argument("--out", help="write markdown report here")
    ap.add_argument("--json", help="write json report here")
    args = ap.parse_args()

    sdk_root = find_sdk_root(args.sdk)
    root_tbd = args.root or os.path.join(sdk_root, "usr", "lib", "libSystem.tbd")
    if not os.path.isfile(root_tbd):
        sys.exit(f"error: no root tbd at {root_tbd}")

    official = collect_official(sdk_root, root_tbd, args.arch, args.platform)
    demand = load_demand(args.demand)

    darling = None
    n_dylibs = 0
    if args.darling_root and os.path.isdir(args.darling_root):
        darling, n_dylibs = collect_darling(args.darling_root, args.arch)

    lines = []
    lines.append(f"# libSystem symbol gap ({args.arch}-{args.platform})\n")
    lines.append("Generated by `scripts/tbd-diff.py`. Supply side: the SDK "
                 f"`libSystem.tbd` re-export closure ({os.path.basename(sdk_root)}).\n")
    lines.append(f"- Official exported symbols (SDK closure): **{len(official)}**")
    if darling is not None:
        lines.append(f"- Darling exported symbols ({n_dylibs} dylibs): **{len(darling)}**")
    if demand is not None:
        lines.append(f"- Demanded symbols (from binaries): **{len(demand)}**")
    lines.append("")

    report = {"arch": args.arch, "platform": args.platform,
              "official_count": len(official)}

    if darling is not None:
        missing = {s: official[s] for s in official if s not in darling}
        report["darling_count"] = len(darling)
        report["missing_count"] = len(missing)
        lines.append(f"## Missing from Darling (official − darling): {len(missing)}\n")

        if demand is not None:
            worklist = sorted(
                ((demand.get(s, 0), s, official[s]) for s in missing if s in demand),
                reverse=True)
            report["demanded_missing_count"] = len(worklist)
            lines.append(f"### Demanded work list (needed ∩ macOS14 − darling): "
                         f"**{len(worklist)}**\n")
            lines.append("| # refs | symbol | owner |")
            lines.append("|---:|:---|:---|")
            for refs, sym, owner in worklist:
                lines.append(f"| {refs} | `{sym}` | `{owner}` |")
            lines.append("")

            # Demanded symbols not present in the SDK closure at all (framework
            # symbols, or our categorization gaps).
            not_in_sdk = sorted(s for s in demand if s not in official)
            report["demanded_not_in_sdk"] = len(not_in_sdk)
            lines.append(f"### Demanded but absent from libSystem tbd closure: "
                         f"**{len(not_in_sdk)}** (likely framework-owned)\n")
    else:
        lines.append("_(no --darling-root given; supply-only run. Provide the "
                     "built Darling dylibs to compute the gap.)_\n")

    text = "\n".join(lines) + "\n"
    if args.out:
        with open(args.out, "w") as fh:
            fh.write(text)
        print(f"wrote {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(report, fh, indent=2)
        print(f"wrote {args.json}", file=sys.stderr)


if __name__ == "__main__":
    main()
