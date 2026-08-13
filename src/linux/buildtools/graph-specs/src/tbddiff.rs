//! THE SUPPLY SIDE OF THE libSystem SYMBOL GAP.
//!
//! THE RUST REWRITE of the python tbd-diff (#98). It parses the SDK libSystem.tbd re-export
//! closure to get the OFFICIAL macOS export set, extracts the ACTUAL export set from the built
//! dylibs, and diffs them, optionally intersected with a demand list so the output is exactly the
//! symbols that real binaries import, macOS provides, and cider still lacks.
//!
//! NO THIRD PARTY YAML, same as the python: the .tbd files are regular enough to parse directly.
//! It handles tbd-version 4 (the YAML-ish 14.4 SDK) and tbd-version 5 (JSON).
//!
//! THE EXPORTS TRIE, NOT nm, and that is not a detail: the trie includes RE-EXPORT aliases, and
//! cider exports _memcpy as a re-export of __platform_memmove. Those never appear in nm -gU, so
//! an nm-based scan wildly under-reports the real export surface.
//!
//! WHAT THE GATE COULD AND COULD NOT USE. The real Apple SDK is NOT realised in this store, only
//! its .drv, so there is no libSystem.tbd to point --sdk at and a byte comparison on the real
//! input was impossible. It is gated instead on a hand-built FIXTURE SDK that exercises every
//! branch the parser has: a v4 root with quoted install-name and a multi-line bracket list, a v4
//! leaf with target filtering, weak-symbols and a $ld$ pseudo-symbol, a v5 JSON leaf, a demand
//! file, and a cider root holding a file that is not a Mach-O so the objdump failure path runs.
//!
//! Usage:
//!   cider-tbd-diff --sdk <apple-sdk-path> [--arch x86_64] [--platform macos]
//!                  [--root <libSystem.tbd or dir>] [--cider-root <dir>]
//!                  [--demand <symbol-demand.json>] [--out report.md] [--json out.json]

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::process::{Command, ExitCode};

fn is_file(p: &str) -> bool {
    fs::metadata(p).map(|m| m.is_file()).unwrap_or(false)
}

fn is_dir(p: &str) -> bool {
    fs::metadata(p).map(|m| m.is_dir()).unwrap_or(false)
}

fn basename(p: &str) -> &str {
    match p.trim_end_matches('/').rfind('/') {
        Some(i) => &p[i + 1..],
        None => p,
    }
}

/// os.walk, pre-order, readdir order, not following symlinked directories.
fn walk(dir: &str, out: &mut Vec<(String, Vec<String>, Vec<String>)>) {
    let rd = match fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return,
    };
    let mut dirs = Vec::new();
    let mut files = Vec::new();
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let p = format!("{dir}/{name}");
        if is_dir(&p) {
            dirs.push(name);
        } else {
            files.push(name);
        }
    }
    out.push((dir.to_string(), dirs.clone(), files));
    for d in dirs {
        let p = format!("{dir}/{d}");
        if !fs::symlink_metadata(&p).map(|m| m.file_type().is_symlink()).unwrap_or(false) {
            walk(&p, out);
        }
    }
}

/// Locate the MacOSX*.sdk directory inside an apple-sdk store path.
fn find_sdk_root(sdk: &str) -> String {
    if is_file(&format!("{sdk}/usr/lib/libSystem.tbd")) {
        return sdk.to_string();
    }
    let mut all = Vec::new();
    walk(sdk, &mut all);
    for (dirpath, dirs, _files) in all {
        for d in dirs {
            if d.ends_with(".sdk") {
                let cand = format!("{dirpath}/{d}");
                if is_file(&format!("{cand}/usr/lib/libSystem.tbd")) {
                    return cand;
                }
            }
        }
    }
    sdk.to_string()
}

fn strip_quotes(s: &str) -> &str {
    s.trim_matches(|c| c == '\'' || c == '"')
}

/// True if any `arch-platform` target token matches.
fn target_matches(targets: &[String], arch: &str, platform: &str) -> bool {
    let want = format!("{arch}-{platform}");
    targets.iter().any(|t| strip_quotes(t.trim()) == want)
}

/// lines[i] contains a '[': accumulate through the matching ']'. Returns (items, next index).
fn collect_bracket_list(lines: &[&str], mut i: usize) -> (Vec<String>, usize) {
    let mut buf: Vec<&str> = Vec::new();
    let mut depth: i64 = 0;
    while i < lines.len() {
        let seg = lines[i];
        depth += seg.matches('[').count() as i64 - seg.matches(']').count() as i64;
        buf.push(seg);
        i += 1;
        if depth <= 0 {
            break;
        }
    }
    let text = buf.join(" ");
    let start = text.find('[').map(|k| k + 1).unwrap_or(0);
    let end = text.rfind(']').unwrap_or(text.len());
    let inside = if start <= end { &text[start..end] } else { "" };
    let items: Vec<String> = inside
        .split(',')
        .map(|x| strip_quotes(x.trim()).to_string())
        .filter(|x| !x.is_empty())
        .collect();
    (items, i)
}

struct Tbd {
    install_names: Vec<String>,
    reexports: Vec<String>,
    symbols: BTreeSet<String>,
}

fn parse_tbd(path: &str, arch: &str, platform: &str) -> Tbd {
    let raw = fs::read_to_string(path).unwrap_or_default();
    // tbd-version 5 is JSON.
    let head: String = raw.chars().take(64).collect();
    if raw.trim_start().starts_with('{') || head.contains("tapi-tbd-v5") {
        return parse_tbd_v5(&raw, arch, platform);
    }
    let lines: Vec<&str> = raw.lines().collect();
    let mut install_names = Vec::new();
    let mut reexports = Vec::new();
    let mut symbols = BTreeSet::new();
    // In tbd v4 top-level keys sit at column 0 and a section content is indented, so the section
    // is tracked by watching unindented `key:` lines. That is robust to intervening keys a
    // heuristic reset would trip over.
    let mut section: Option<String> = None;
    let mut cur_targets: Option<Vec<String>> = None;
    let mut i = 0;
    while i < lines.len() {
        let ln = lines[i];
        let s = ln.trim();
        let indented = ln.starts_with(' ') || ln.starts_with('\t');
        if !indented && is_top_key(s) {
            let key = s.split(':').next().unwrap_or("");
            section = match key {
                "exports" | "reexports" | "reexported-libraries" => Some(key.to_string()),
                _ => None,
            };
            if let Some(name) = install_name_of(s) {
                install_names.push(name);
            }
            i += 1;
            continue;
        }
        if section.is_none() {
            i += 1;
            continue;
        }
        // Inside a section: entries begin with `- targets:`.
        if s.contains("targets:") {
            let (t, next) = collect_bracket_list(&lines, i);
            cur_targets = Some(t);
            i = next;
            continue;
        }
        let in_target = match &cur_targets {
            None => true,
            Some(t) => target_matches(t, arch, platform),
        };
        let sec = section.clone().unwrap_or_default();
        if sec == "reexported-libraries" && s.contains("libraries:") {
            let (libs, next) = collect_bracket_list(&lines, i);
            if in_target {
                reexports.extend(libs);
            }
            i = next;
            continue;
        }
        if (sec == "exports" || sec == "reexports")
            && (s.contains("symbols:") || s.contains("weak-symbols:"))
        {
            let (syms, next) = collect_bracket_list(&lines, i);
            if in_target {
                for sym in syms {
                    // linker-directive pseudo-symbols
                    if sym.starts_with("$ld$") {
                        continue;
                    }
                    symbols.insert(sym);
                }
            }
            i = next;
            continue;
        }
        i += 1;
    }
    Tbd { install_names, reexports, symbols }
}

/// ^[A-Za-z_][A-Za-z0-9_-]*:
fn is_top_key(s: &str) -> bool {
    let b = s.as_bytes();
    if b.is_empty() || !(b[0].is_ascii_alphabetic() || b[0] == b'_') {
        return false;
    }
    let mut i = 1;
    while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_' || b[i] == b'-') {
        i += 1;
    }
    i < b.len() && b[i] == b':'
}

/// ^install-name:\s*'?([^'\n]+?)'?\s*$
fn install_name_of(s: &str) -> Option<String> {
    let rest = s.strip_prefix("install-name:")?;
    let v = rest.trim();
    if v.is_empty() {
        return None;
    }
    let v = v.strip_prefix('\'').unwrap_or(v);
    let v = v.strip_suffix('\'').unwrap_or(v);
    let v = v.trim();
    if v.is_empty() {
        return None;
    }
    Some(strip_quotes(v).to_string())
}

fn parse_tbd_v5(raw: &str, arch: &str, platform: &str) -> Tbd {
    let mut install_names = Vec::new();
    let mut reexports = Vec::new();
    let mut symbols = BTreeSet::new();
    let data: serde_json::Value = match serde_json::from_str(raw) {
        Ok(v) => v,
        Err(_) => return Tbd { install_names, reexports, symbols },
    };
    let want = format!("{arch}-{platform}");
    let main = data.get("main_library").cloned().unwrap_or(serde_json::Value::Null);
    if let Some(a) = main.get("install_names").and_then(|v| v.as_array()) {
        for lib in a {
            if let Some(n) = lib.get("name").and_then(|v| v.as_str()) {
                install_names.push(n.to_string());
            }
        }
    }
    if let Some(a) = main.get("reexported_libraries").and_then(|v| v.as_array()) {
        for grp in a {
            let tgts: Vec<&str> =
                grp.get("targets").and_then(|v| v.as_array()).map(|a| a.iter().filter_map(|x| x.as_str()).collect()).unwrap_or_default();
            if tgts.contains(&want.as_str()) {
                if let Some(names) = grp.get("names").and_then(|v| v.as_array()) {
                    reexports.extend(names.iter().filter_map(|x| x.as_str()).map(|s| s.to_string()));
                }
            }
        }
    }
    if let Some(a) = main.get("exported_symbols").and_then(|v| v.as_array()) {
        for grp in a {
            let tgts: Vec<&str> =
                grp.get("targets").and_then(|v| v.as_array()).map(|a| a.iter().filter_map(|x| x.as_str()).collect()).unwrap_or_default();
            if tgts.contains(&want.as_str()) || tgts.is_empty() {
                for kind in ["global", "data", "text", "weak"] {
                    if let Some(list) = grp.get(kind).and_then(|v| v.as_array()) {
                        for sym in list.iter().filter_map(|x| x.as_str()) {
                            if !sym.starts_with("$ld$") {
                                symbols.insert(sym.to_string());
                            }
                        }
                    }
                }
            }
        }
    }
    Tbd { install_names, reexports, symbols }
}

/// Map an install name to its .tbd in the SDK.
fn tbd_path_for_install_name(sdk_root: &str, install_name: &str) -> Option<String> {
    let rel = install_name.trim_start_matches('/');
    let base = format!("{sdk_root}/{rel}");
    let first = if base.ends_with(".dylib") {
        format!("{}.tbd", &base[..base.len() - ".dylib".len()])
    } else {
        base.clone()
    };
    for cand in [first, format!("{base}.tbd"), base] {
        if is_file(&cand) {
            return Some(cand);
        }
    }
    None
}

/// Walk the reexport closure from root_tbd; {symbol: install name}, first owner wins.
fn collect_official(
    sdk_root: &str,
    root_tbd: &str,
    arch: &str,
    platform: &str,
) -> (Vec<(String, String)>, HashMap<String, String>) {
    let mut order: Vec<(String, String)> = Vec::new();
    let mut supply: HashMap<String, String> = HashMap::new();
    let mut seen: BTreeSet<String> = BTreeSet::new();
    let mut stack = vec![root_tbd.to_string()];
    while let Some(tbd) = stack.pop() {
        if seen.contains(&tbd) || tbd.is_empty() || !is_file(&tbd) {
            continue;
        }
        seen.insert(tbd.clone());
        let parsed = parse_tbd(&tbd, arch, platform);
        let owner = parsed.install_names.first().cloned().unwrap_or_else(|| tbd.clone());
        for sym in &parsed.symbols {
            if !supply.contains_key(sym) {
                supply.insert(sym.clone(), owner.clone());
                order.push((sym.clone(), owner.clone()));
            }
        }
        for rex in &parsed.reexports {
            if let Some(next) = tbd_path_for_install_name(sdk_root, rex) {
                stack.push(next);
            }
        }
    }
    (order, supply)
}

/// Every symbol exported by every dylib under `root`, through the exports trie.
fn collect_cider(root: &str, arch: &str) -> Result<(BTreeSet<String>, usize), String> {
    let objdump = which("llvm-objdump")
        .ok_or_else(|| "error: need llvm-objdump on PATH (nix shell nixpkgs#llvm)".to_string())?;
    let mut exported = BTreeSet::new();
    let mut dylibs = Vec::new();
    let mut all = Vec::new();
    walk(root, &mut all);
    for (dp, _dirs, files) in all {
        for f in files {
            if f.contains(".dylib") {
                dylibs.push(format!("{dp}/{f}"));
            }
        }
    }
    for lib in &dylibs {
        let out = match Command::new(&objdump)
            .args(["--macho", "--exports-trie", &format!("--arch={arch}"), lib])
            .output()
        {
            Ok(o) => String::from_utf8_lossy(&o.stdout).into_owned(),
            Err(_) => continue,
        };
        for line in out.lines() {
            if let Some(at) = line.find("[re-export]") {
                let rest = &line[at + "[re-export]".len()..];
                let rest = rest.trim_start();
                let sym: String = rest.chars().take_while(|c| !c.is_whitespace()).collect();
                if !sym.is_empty() {
                    exported.insert(sym);
                    continue;
                }
            }
            // ^0x[0-9A-Fa-f]+\s+(\S+) on the stripped line, symbol must start with _
            let t = line.trim();
            if let Some(rest) = t.strip_prefix("0x") {
                let hex_len = rest.chars().take_while(|c| c.is_ascii_hexdigit()).count();
                if hex_len > 0 {
                    let after = &rest[hex_len..];
                    if after.starts_with(char::is_whitespace) {
                        let sym: String =
                            after.trim_start().chars().take_while(|c| !c.is_whitespace()).collect();
                        if sym.starts_with('_') {
                            exported.insert(sym);
                        }
                    }
                }
            }
        }
    }
    Ok((exported, dylibs.len()))
}

fn which(x: &str) -> Option<String> {
    for p in std::env::var("PATH").unwrap_or_default().split(':') {
        let cand = format!("{p}/{x}");
        if is_file(&cand) {
            return Some(cand);
        }
    }
    None
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let get = |name: &str| -> Option<String> {
        argv.iter().position(|a| a == name).and_then(|i| argv.get(i + 1)).cloned()
    };
    let sdk = match get("--sdk") {
        Some(s) => s,
        None => {
            // argparse prints its own usage and exits 2; this is the one place the two differ,
            // and it is the one place there is nothing to reproduce.
            eprintln!("cider-tbd-diff: --sdk is required");
            return ExitCode::from(2);
        }
    };
    let arch = get("--arch").unwrap_or_else(|| "x86_64".to_string());
    let platform = get("--platform").unwrap_or_else(|| "macos".to_string());

    let sdk_root = find_sdk_root(&sdk);
    let root_tbd = get("--root").unwrap_or_else(|| format!("{sdk_root}/usr/lib/libSystem.tbd"));
    if !is_file(&root_tbd) {
        eprintln!("error: no root tbd at {root_tbd}");
        return ExitCode::FAILURE;
    }

    let (official_order, official) = collect_official(&sdk_root, &root_tbd, &arch, &platform);
    let demand: Option<BTreeMap<String, i64>> = match get("--demand") {
        None => None,
        Some(p) => {
            let text = match fs::read_to_string(&p) {
                Ok(t) => t,
                Err(e) => {
                    eprintln!("cannot read {p}: {e}");
                    return ExitCode::FAILURE;
                }
            };
            let v: serde_json::Value = serde_json::from_str(&text).unwrap_or(serde_json::Value::Null);
            let mut m = BTreeMap::new();
            if let Some(a) = v.get("symbols").and_then(|x| x.as_array()) {
                for e in a {
                    if let Some(s) = e.get("symbol").and_then(|x| x.as_str()) {
                        let refs = e.get("refs").and_then(|x| x.as_i64()).unwrap_or(0);
                        m.insert(s.to_string(), refs);
                    }
                }
            }
            Some(m)
        }
    };

    let mut cider: Option<BTreeSet<String>> = None;
    let mut n_dylibs = 0usize;
    if let Some(cr) = get("--cider-root") {
        if is_dir(&cr) {
            match collect_cider(&cr, &arch) {
                Ok((c, n)) => {
                    cider = Some(c);
                    n_dylibs = n;
                }
                Err(e) => {
                    eprintln!("{e}");
                    return ExitCode::FAILURE;
                }
            }
        }
    }

    let mut lines: Vec<String> = Vec::new();
    lines.push(format!("# libSystem symbol gap ({arch}-{platform})\n"));
    lines.push(format!(
        "Generated by `cider-tbd-diff`. Supply side: the SDK `libSystem.tbd` re-export \
         closure ({}).\n",
        basename(&sdk_root)
    ));
    lines.push(format!("- Official exported symbols (SDK closure): **{}**", official.len()));
    if let Some(c) = &cider {
        lines.push(format!("- Darling exported symbols ({n_dylibs} dylibs): **{}**", c.len()));
    }
    if let Some(d) = &demand {
        lines.push(format!("- Demanded symbols (from binaries): **{}**", d.len()));
    }
    lines.push(String::new());

    let mut report = serde_json::Map::new();
    report.insert("arch".into(), serde_json::Value::String(arch.clone()));
    report.insert("platform".into(), serde_json::Value::String(platform.clone()));
    report.insert("official_count".into(), serde_json::Value::from(official.len()));

    if let Some(c) = &cider {
        let missing: Vec<(String, String)> =
            official_order.iter().filter(|(s, _)| !c.contains(s)).cloned().collect();
        report.insert("cider_count".into(), serde_json::Value::from(c.len()));
        report.insert("missing_count".into(), serde_json::Value::from(missing.len()));
        lines.push(format!("## Missing from Darling (official − cider): {}\n", missing.len()));
        if let Some(d) = &demand {
            let mut worklist: Vec<(i64, String, String)> = missing
                .iter()
                .filter(|(s, _)| d.contains_key(s))
                .map(|(s, o)| (*d.get(s).unwrap_or(&0), s.clone(), o.clone()))
                .collect();
            worklist.sort_by(|a, b| b.cmp(a));
            report.insert("demanded_missing_count".into(), serde_json::Value::from(worklist.len()));
            lines.push(format!(
                "### Demanded work list (needed ∩ macOS14 − cider): **{}**\n",
                worklist.len()
            ));
            lines.push("| # refs | symbol | owner |".to_string());
            lines.push("|---:|:---|:---|".to_string());
            for (refs, sym, owner) in &worklist {
                lines.push(format!("| {refs} | `{sym}` | `{owner}` |"));
            }
            lines.push(String::new());
            let not_in_sdk: Vec<&String> =
                d.keys().filter(|s| !official.contains_key(*s)).collect();
            report.insert("demanded_not_in_sdk".into(), serde_json::Value::from(not_in_sdk.len()));
            lines.push(format!(
                "### Demanded but absent from libSystem tbd closure: **{}** (likely \
                 framework-owned)\n",
                not_in_sdk.len()
            ));
        }
    } else {
        lines.push(
            "_(no --cider-root given; supply-only run. Provide the built Darling dylibs to \
             compute the gap.)_\n"
                .to_string(),
        );
    }

    let text = lines.join("\n") + "\n";
    match get("--out") {
        Some(out) => {
            if let Err(e) = fs::write(&out, &text) {
                eprintln!("cannot write {out}: {e}");
                return ExitCode::FAILURE;
            }
            eprintln!("wrote {out}");
        }
        None => print!("{text}"),
    }
    if let Some(jp) = get("--json") {
        let rendered = serde_json::to_string_pretty(&serde_json::Value::Object(report))
            .unwrap_or_else(|_| "{}".to_string());
        if let Err(e) = fs::write(&jp, rendered) {
            eprintln!("cannot write {jp}: {e}");
            return ExitCode::FAILURE;
        }
        eprintln!("wrote {jp}");
    }
    ExitCode::SUCCESS
}
