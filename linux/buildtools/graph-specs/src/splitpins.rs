//! SPLIT vendor/src INTO A PACKAGE PER PIN.
//!
//! THE RUST REWRITE of the python buck-split-pins (#98), and the LAST python in scripts/. It
//! operates on the buck2 tree rather than on the cmake reference, which is why it is ported and
//! not deleted like the frozen generators were.
//!
//! vendor/src/BUCK holds every materialized pin, and the Nix-lowered path has to PARSE it. One
//! package per pin keeps that small enough to evaluate. Moving a block is not a cut and paste:
//!   a GLOB cannot cross a package boundary, so a block whose glob reaches a sibling pin STAYS;
//!   a FILE reference the new package does not own becomes a LABEL, backed by an export_file in
//!     the owner, recorded as a hint because vendor/src cannot be walked to resolve a name;
//!   a bare :name meant "this package", which is no longer vendor/src;
//!   every moved target needs visibility, and every target left behind that a pin package now
//!     names needs it too, which is the direction people forget.
//!
//! ONE TIE-BREAK IS MINE, not the python: pin_of counts the owners of the paths a block names and
//! takes the most common, and the python counts them in SET ITERATION ORDER, so a tie would be
//! decided by string hashing. Measured on this tree with three randomised hash seeds, the answer
//! is stable, so no tie arises here; ties break by name below rather than by luck.
//!
//! Usage:
//!   cider-split-pins --list                  # what is in vendor/src/BUCK, by pin
//!   cider-split-pins --all [--dry-run]
//!   cider-split-pins --only a,b [--dry-run]

#[path = "ninjaref.rs"]
mod ninjaref;
use ninjaref::repo_root;

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::process::{Command, ExitCode};

const SKIP_DIRS: &[&str] = &["buck-out", ".git", ".jj", ".direnv", "build"];
/// Namespaces the SDK maps cover, in the order cider-sdk-header-roots expects them.
const NS: &[&str] = &[".", "mach", "i386", "machine", "libkern", "sys", "security_libDER"];
/// Prefixes that are never a source path: a label, a compiler flag, or a typed extra-dep.
const NOT_A_PATH: &[&str] =
    &["//", ":", "-", "gen:", "dylib:", "dep:", "objs:", "ldflag:", "toolchains//"];

const USAGE: &str = "\
cider-split-pins: split vendor/src into a package per pin.

  cider-split-pins --list                  # what is in vendor/src/BUCK, by pin
  cider-split-pins --all [--dry-run]
  cider-split-pins --only a,b [--dry-run]
";

fn is_file(p: &str) -> bool {
    fs::metadata(p).map(|m| m.is_file()).unwrap_or(false)
}

fn is_dir(p: &str) -> bool {
    fs::metadata(p).map(|m| m.is_dir()).unwrap_or(false)
}

fn owner_of(path: &str) -> &str {
    path.split('/').next().unwrap_or(path)
}

/// Every string literal, ESCAPES INCLUDED. A plain "([^"]+)" desynchronises on the first \" and
/// the flag lists are full of them, after which its strings are the text BETWEEN strings.
fn strings_in(text: &str) -> Vec<String> {
    let b = text.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] != b'"' {
            i += 1;
            continue;
        }
        let start = i + 1;
        let mut j = start;
        loop {
            if j >= b.len() {
                return out;
            }
            if b[j] == b'\\' && j + 1 < b.len() {
                j += 2;
                continue;
            }
            if b[j] == b'"' {
                break;
            }
            j += 1;
        }
        out.push(text[start..j].to_string());
        i = j + 1;
    }
    out
}

fn flatten(rel: &str) -> String {
    let mut out = String::new();
    let mut run = false;
    for c in rel.chars() {
        if c.is_ascii_alphanumeric() || c == '_' || c == '.' || c == '+' || c == '-' {
            out.push(c);
            run = false;
        } else if !run {
            out.push('_');
            run = true;
        }
    }
    out
}

fn is_name_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'.' || c == b'+' || c == b'-'
}

fn name_run(b: &[u8], i: usize) -> usize {
    let mut j = i;
    while j < b.len() && is_name_char(b[j]) {
        j += 1;
    }
    j
}

/// [(marker, start, end)] for every generated block, outermost first.
fn blocks(text: &str) -> Vec<(String, usize, usize)> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < text.len() {
        let at = match text[i..].find("# BEGIN generated: ") {
            Some(a) => i + a,
            None => break,
        };
        if at != 0 && text.as_bytes()[at - 1] != b'\n' {
            i = at + 1;
            continue;
        }
        let after = at + "# BEGIN generated: ".len();
        let line_end = match text[after..].find('\n') {
            Some(k) => after + k,
            None => break,
        };
        let marker = text[after..line_end].to_string();
        if !marker.is_empty() {
            let end_marker = format!("# END generated: {marker}\n");
            if let Some(k) = text[line_end + 1..].find(&end_marker) {
                out.push((marker, at, line_end + 1 + k + end_marker.len()));
            }
        }
        i = line_end + 1;
    }
    out
}

/// (files, glob dirs) a block really names, by checking the disk. Shape is not enough to tell a
/// path from anything else: an install_name reads as an absolute path and a header_map KEY as a
/// relative one, so a string counts only if it RESOLVES under vendor/src.
fn pin_paths(buck_src_dir: &str, body: &str) -> (BTreeSet<String>, BTreeSet<String>) {
    let mut files = BTreeSet::new();
    let mut globs = BTreeSet::new();
    for s in strings_in(body) {
        if NOT_A_PATH.iter().any(|p| s.starts_with(p)) || s.contains(' ') || !s.contains('/') {
            continue;
        }
        if s.contains('*') {
            let head = s.split('*').next().unwrap_or("").trim_end_matches('/');
            if !head.is_empty() && is_dir(&format!("{buck_src_dir}/{head}")) {
                globs.insert(head.to_string());
            }
        } else if is_file(&format!("{buck_src_dir}/{s}")) {
            files.insert(s);
        }
    }
    (files, globs)
}

/// `^\s+"([A-Za-z0-9_.+-]+)/[^"]*\.(c|cc|cpp|m|mm|S|s)",$`
fn source_owners(body: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in body.split('\n') {
        let t = line.trim_start();
        if t.len() == line.len() || !t.starts_with('"') || !line.ends_with("\",") {
            continue;
        }
        let inner = &t[1..t.len() - 2];
        if inner.contains('"') {
            continue;
        }
        let slash = match inner.find('/') {
            Some(k) if k > 0 => k,
            _ => continue,
        };
        let pin = &inner[..slash];
        if !pin.bytes().all(is_name_char) {
            continue;
        }
        let ext_ok = [".c", ".cc", ".cpp", ".m", ".mm", ".S", ".s"]
            .iter()
            .any(|e| inner.ends_with(e));
        if ext_ok {
            out.push(pin.to_string());
        }
    }
    out
}

/// Which pin a block belongs to: the one holding its SOURCES, then the DOMINANT pin among
/// everything else it names.
fn pin_of(buck_src_dir: &str, body: &str) -> Option<String> {
    let srcs = source_owners(body);
    if !srcs.is_empty() {
        return Some(most_common(&srcs));
    }
    let (files, globs) = pin_paths(buck_src_dir, body);
    let owners: Vec<String> =
        files.iter().chain(globs.iter()).map(|p| owner_of(p).to_string()).collect();
    if owners.is_empty() {
        None
    } else {
        Some(most_common(&owners))
    }
}

/// Counter.most_common(1): the highest count, ties by FIRST SEEN, which for the set-derived case
/// is the python hash order and here is the sorted one.
fn most_common(items: &[String]) -> String {
    let mut counts: Vec<(String, usize)> = Vec::new();
    for it in items {
        match counts.iter_mut().find(|(k, _)| k == it) {
            Some((_, n)) => *n += 1,
            None => counts.push((it.clone(), 1)),
        }
    }
    counts.sort_by(|a, b| b.1.cmp(&a.1));
    counts[0].0.clone()
}

/// `^\s*name = "([A-Za-z0-9_.+-]+)",$`
fn target_names(body: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in body.split('\n') {
        let t = line.trim_start();
        let rest = match t.strip_prefix("name = \"") {
            Some(r) => r,
            None => continue,
        };
        let b = rest.as_bytes();
        let e = name_run(b, 0);
        if e > 0 && rest[e..].starts_with("\",") && rest.len() == e + 2 {
            out.push(rest[..e].to_string());
        }
    }
    out
}

/// [(start, end, body)] for every top-level rule call, comments above included.
fn rule_calls(text: &str) -> Vec<(usize, usize, String)> {
    let mut out = Vec::new();
    let bytes = text.as_bytes();
    let mut line_start = 0usize;
    while line_start < text.len() {
        let line_end = match text[line_start..].find('\n') {
            Some(k) => line_start + k,
            None => text.len(),
        };
        let line = &text[line_start..line_end];
        // ^[a-z_][a-z_0-9]*\($ : a rule call opening at column 0.
        let head_ok = {
            let b = line.as_bytes();
            if b.is_empty() || !(b[0].is_ascii_lowercase() || b[0] == b'_') {
                false
            } else {
                let mut k = 1;
                while k < b.len() && (b[k].is_ascii_lowercase() || b[k].is_ascii_digit() || b[k] == b'_') {
                    k += 1;
                }
                k + 1 == b.len() && b[k] == b'('
            }
        };
        if !head_ok {
            line_start = line_end + 1;
            continue;
        }
        // ... up to the first line that is exactly ")".
        let mut j = line_end + 1;
        let mut end = None;
        while j <= text.len() {
            let le = match text[j..].find('\n') {
                Some(k) => j + k,
                None => break,
            };
            if &text[j..le] == ")" {
                end = Some(le + 1);
                break;
            }
            j = le + 1;
        }
        let e = match end {
            Some(e) => e,
            None => {
                line_start = line_end + 1;
                continue;
            }
        };
        // The comments directly above belong to the call, but a generated marker does not.
        let mut start = line_start;
        while start > 0 {
            let prev = text[..start - 1].rfind('\n').map(|k| k + 1).unwrap_or(0);
            let seg = &text[prev..start];
            if seg.trim_start().starts_with('#') && !seg.contains("generated:") {
                start = prev;
            } else {
                break;
            }
        }
        let _ = bytes;
        out.push((start, e, text[start..e].to_string()));
        line_start = e;
    }
    out
}

fn read_split_pins(path: &str) -> BTreeSet<String> {
    fs::read_to_string(path)
        .map(|t| {
            t.lines()
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty() && !l.starts_with('#'))
                .collect()
        })
        .unwrap_or_default()
}

fn write_split_pins(path: &str, pins: &BTreeSet<String>) -> Result<(), String> {
    let mut s = String::new();
    s.push_str("# Pins that have their own package, vendor/src/<pin>/BUCK.\n");
    s.push_str("# THIS FILE IS THE SWITCH: the SDK maps name a listed pin's headers by\n");
    s.push_str("# label instead of by path, and gen-buck-from-ninja (deleted) writes a listed\n");
    s.push_str("# pin's blocks into its own package. cider-split-pins keeps it.\n");
    for pin in pins {
        s.push_str(pin);
        s.push('\n');
    }
    fs::write(path, s).map_err(|e| format!("cannot write {path}: {e}"))
}

struct Ctx {
    repo: String,
    buck_src: String,
    buck_src_dir: String,
    split_pins: String,
    hints_path: String,
}

fn add_hint(hints: &mut BTreeMap<String, BTreeMap<String, String>>, pkg: &str, path_in_pkg: &str) -> String {
    let name = flatten(path_in_pkg);
    hints.entry(pkg.to_string()).or_default().insert(name.clone(), path_in_pkg.to_string());
    format!("//{pkg}:{name}")
}

/// How `pkg` refers to a vendor/src-relative file it does not own.
fn label_for_file(
    path: &str,
    pkg: &str,
    pins: &BTreeSet<String>,
    hints: &mut BTreeMap<String, BTreeMap<String, String>>,
) -> String {
    let pin = owner_of(path);
    let (owner, rel) = if pins.contains(pin) {
        (format!("vendor/src/{pin}"), path[pin.len() + 1..].to_string())
    } else {
        ("vendor/src".to_string(), path.to_string())
    };
    if owner == pkg {
        return rel;
    }
    add_hint(hints, &owner, &rel)
}

/// Turn every file reference the package does not own into a label. Globs are left alone: movable
/// has already guaranteed they are local, and a glob has no label form.
fn labelize(
    ctx: &Ctx,
    body: &str,
    pkg: &str,
    pins: &BTreeSet<String>,
    hints: &mut BTreeMap<String, BTreeMap<String, String>>,
) -> String {
    let (files, _globs) = pin_paths(&ctx.buck_src_dir, body);
    let own: Option<&str> = pkg.strip_prefix("vendor/src/");
    let mut ordered: Vec<&String> = files.iter().collect();
    // Longest first, so a path that is a prefix of another does not eat it.
    ordered.sort_by(|a, b| b.len().cmp(&a.len()).then(a.cmp(b)));
    let mut body = body.to_string();
    for path in ordered {
        if let Some(own) = own {
            if path == own || path.starts_with(&format!("{own}/")) {
                continue; // its own pin: already package-relative
            }
        } else if !pins.contains(owner_of(path)) {
            continue; // vendor/src still owns it
        }
        let label = label_for_file(path, pkg, pins, hints);
        body = body.replace(&format!("\"{path}\""), &format!("\"{label}\""));
    }
    body
}

/// Give every moved target visibility = ["PUBLIC"]. Inside one package a target needs none; the
/// moment it lives in its own package every consumer is a stranger.
fn ensure_visibility(body: &str) -> String {
    let mut out = String::new();
    let mut last = 0;
    for (start, end, call) in rule_calls(body) {
        let call = if !call.contains("visibility = ") {
            match call.rfind(")\n") {
                Some(i) => format!("{}    visibility = [\"PUBLIC\"],\n)\n", &call[..i]),
                None => call,
            }
        } else {
            call
        };
        out.push_str(&body[last..start]);
        out.push_str(&call);
        last = end;
    }
    out.push_str(&body[last..]);
    out
}

/// A block's text as the pin's own package must spell it.
fn rewrite_for_pin(
    ctx: &Ctx,
    body: &str,
    pin: &str,
    names: &HashMap<String, String>,
    pins: &BTreeSet<String>,
    hints: &mut BTreeMap<String, BTreeMap<String, String>>,
) -> String {
    // Files in OTHER packages first, while the paths are still whole.
    let body = labelize(ctx, body, &format!("vendor/src/{pin}"), pins, hints);
    // The pin DIRECTORY itself, BEFORE the prefix strip: a pin holding a directory of its own
    // name would otherwise lose it.
    let mut out = String::new();
    for (i, line) in body.split('\n').enumerate() {
        if i > 0 {
            out.push('\n');
        }
        let t = line.trim_start();
        let indent = &line[..line.len() - t.len()];
        let replaced = ["root = ", "out_base = "].iter().find_map(|k| {
            t.strip_prefix(*k).and_then(|rest| {
                if rest == format!("\"{pin}\"") {
                    Some(format!("{indent}{k}\"\""))
                } else {
                    None
                }
            })
        });
        match replaced {
            Some(r) => out.push_str(&r),
            None => out.push_str(line),
        }
    }
    // Its own pin's paths are package-relative there.
    let body = out.replace(&format!("\"{pin}/"), "\"");
    // A bare :name meant "this package", which is no longer vendor/src.
    let mut res = String::new();
    let b = body.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'"' {
            let mut j = i + 1;
            let prefix = if body[j..].starts_with("gen:") {
                j += 4;
                "gen:"
            } else {
                ""
            };
            if j < b.len() && b[j] == b':' {
                let ns = j + 1;
                let ne = name_run(b, ns);
                if ne > ns && ne < b.len() && b[ne] == b'"' {
                    let name = &body[ns..ne];
                    let dest = names.get(name);
                    if dest.map(|d| d == pin).unwrap_or(false) {
                        res.push_str(&body[i..=ne]);
                    } else {
                        let pkg = match dest {
                            Some(d) => format!("//vendor/src/{d}"),
                            None => "//vendor/src".to_string(),
                        };
                        res.push_str(&format!("\"{prefix}{pkg}:{name}\""));
                    }
                    i = ne + 1;
                    continue;
                }
            }
        }
        let c = body[i..].chars().next().unwrap();
        res.push(c);
        i += c.len_utf8();
    }
    ensure_visibility(&res)
}

fn walk_buck(repo: &str, dir: &str, out: &mut Vec<String>) {
    let rd = match fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return,
    };
    let mut dirs = Vec::new();
    let mut here: Vec<String> = Vec::new();
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let p = format!("{dir}/{name}");
        if is_dir(&p) {
            if !SKIP_DIRS.contains(&name.as_str())
                && !fs::symlink_metadata(&p).map(|m| m.file_type().is_symlink()).unwrap_or(false)
            {
                dirs.push(p);
            }
        } else if name == "BUCK" || name == "extra-deps.json" || name == "buck-test.nu" {
            here.push(p);
        }
    }
    out.extend(here);
    for d in dirs {
        walk_buck(repo, &d, out);
    }
}

/// Give a vendor/src target PUBLIC visibility once another package names it. Visibility cuts both
/// ways, and this is the direction people forget.
fn publicise_referenced(ctx: &Ctx) -> Result<usize, String> {
    let mut wanted: HashSet<String> = HashSet::new();
    let mut files = Vec::new();
    walk_buck(&ctx.repo, &ctx.repo, &mut files);
    for f in &files {
        if !f.ends_with("/BUCK") || f == &ctx.buck_src {
            continue;
        }
        let text = match fs::read_to_string(f) {
            Ok(t) => t,
            Err(_) => continue,
        };
        // "(?:[a-z]+:)?//vendor/src:([A-Za-z0-9_.+-]+)"
        for s in strings_in(&text) {
            let core = match s.find("//vendor/src:") {
                Some(0) => &s[..],
                Some(k) => {
                    let head = &s[..k];
                    if head.ends_with(':') && head[..head.len() - 1].bytes().all(|c| c.is_ascii_lowercase()) {
                        &s[k..]
                    } else {
                        continue;
                    }
                }
                None => continue,
            };
            let name = &core["//vendor/src:".len()..];
            if !name.is_empty() && name.bytes().all(is_name_char) {
                wanted.insert(name.to_string());
            }
        }
    }
    let text = fs::read_to_string(&ctx.buck_src).map_err(|e| format!("cannot read: {e}"))?;
    let mut out = String::new();
    let mut last = 0;
    let mut n = 0;
    for (start, end, call) in rule_calls(&text) {
        if call.contains("visibility = ") || !target_names(&call).iter().any(|t| wanted.contains(t))
        {
            continue;
        }
        out.push_str(&text[last..start]);
        match call.rfind(")\n") {
            Some(i) => {
                out.push_str(&call[..i]);
                out.push_str("    visibility = [\"PUBLIC\"],\n)\n");
            }
            None => out.push_str(&call),
        }
        last = end;
        n += 1;
    }
    if n > 0 {
        out.push_str(&text[last..]);
        fs::write(&ctx.buck_src, out).map_err(|e| format!("cannot write: {e}"))?;
    }
    Ok(n)
}

/// Point every reference at a moved target's new package. Returns files touched.
fn repoint(ctx: &Ctx, names: &HashMap<String, String>) -> usize {
    if names.is_empty() {
        return 0;
    }
    let mut files = Vec::new();
    walk_buck(&ctx.repo, &ctx.repo, &mut files);
    let mut touched = 0;
    for f in &files {
        let orig = match fs::read_to_string(f) {
            Ok(t) => t,
            Err(_) => continue,
        };
        // //vendor/src:(name)(?![A-Za-z0-9_.+-]) : the maximal name run must BE a moved name.
        let mut t = String::new();
        let b = orig.as_bytes();
        let mut i = 0;
        while i < b.len() {
            if orig[i..].starts_with("//vendor/src:") {
                let ns = i + "//vendor/src:".len();
                let ne = name_run(b, ns);
                let name = &orig[ns..ne];
                if let Some(dest) = names.get(name) {
                    t.push_str(&format!("//vendor/src/{dest}:{name}"));
                    i = ne;
                    continue;
                }
            }
            let c = orig[i..].chars().next().unwrap();
            t.push(c);
            i += c.len_utf8();
        }
        // `:name` meant "this package" only inside vendor/src/BUCK itself.
        if f == &ctx.buck_src {
            let src = t.clone();
            let b = src.as_bytes();
            let mut o = String::new();
            let mut i = 0;
            while i < b.len() {
                if b[i] == b'"' {
                    let mut j = i + 1;
                    let prefix = if src[j..].starts_with("gen:") {
                        j += 4;
                        "gen:"
                    } else {
                        ""
                    };
                    if j < b.len() && b[j] == b':' {
                        let ns = j + 1;
                        let ne = name_run(b, ns);
                        if ne > ns && ne < b.len() && b[ne] == b'"' {
                            let name = &src[ns..ne];
                            if let Some(dest) = names.get(name) {
                                o.push_str(&format!("\"{prefix}//vendor/src/{dest}:{name}\""));
                                i = ne + 1;
                                continue;
                            }
                        }
                    }
                }
                let c = src[i..].chars().next().unwrap();
                o.push(c);
                i += c.len_utf8();
            }
            t = o;
        }
        if t != orig {
            if fs::write(f, t).is_ok() {
                touched += 1;
            }
        }
    }
    touched
}

/// Keep out_base in step with a defs that became a label: a source short_path is relative to the
/// package that DECLARES it, so an out_base still carrying the pin stops matching.
fn fix_mig_out_base(ctx: &Ctx, text: &str) -> usize {
    let mut out = String::new();
    let mut last = 0;
    let mut n = 0;
    for (start, end, call) in rule_calls(text) {
        let mut pin: Option<String> = None;
        for line in call.split('\n') {
            let t = line.trim_start();
            if let Some(rest) = t.strip_prefix("defs = \"//vendor/src/") {
                let b = rest.as_bytes();
                let e = name_run(b, 0);
                if e > 0 && rest[e..].starts_with(':') {
                    pin = Some(rest[..e].to_string());
                    break;
                }
            }
        }
        let pin = match pin {
            Some(p) => p,
            None => continue,
        };
        let mut fixed = String::new();
        for (i, line) in call.split('\n').enumerate() {
            if i > 0 {
                fixed.push('\n');
            }
            let t = line.trim_start();
            let indent = &line[..line.len() - t.len()];
            if let Some(rest) = t.strip_prefix("out_base = ") {
                if let Some(tail) = rest.strip_prefix(&format!("\"{pin}/")) {
                    fixed.push_str(&format!("{indent}out_base = \"{tail}"));
                    continue;
                }
                if rest == format!("\"{pin}\"") {
                    fixed.push_str(&format!("{indent}out_base = \"\""));
                    continue;
                }
            }
            fixed.push_str(line);
        }
        if fixed == call {
            continue;
        }
        out.push_str(&text[last..start]);
        out.push_str(&fixed);
        last = end;
        n += 1;
    }
    if n > 0 {
        out.push_str(&text[last..]);
        let _ = fs::write(&ctx.buck_src, out);
    }
    n
}

fn read_hints(path: &str) -> BTreeMap<String, BTreeMap<String, String>> {
    fs::read_to_string(path).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

fn write_hints(path: &str, hints: &BTreeMap<String, BTreeMap<String, String>>) -> Result<(), String> {
    let s = serde_json::to_string_pretty(hints).map_err(|e| e.to_string())? + "\n";
    fs::write(path, s).map_err(|e| format!("cannot write {path}: {e}"))
}

fn cider_tool(repo: &str, name: &str) -> Result<String, String> {
    let out = Command::new("nix")
        .args(["build", ".#specs-tool", "--no-link", "--print-out-paths"])
        .current_dir(repo)
        .output()
        .map_err(|e| format!("cannot run nix: {e}"))?;
    if !out.status.success() {
        eprint!("{}", String::from_utf8_lossy(&out.stderr));
        return Err(format!("cannot build .#specs-tool, so {name} cannot be run"));
    }
    let path = String::from_utf8_lossy(&out.stdout).trim().split('\n').next().unwrap_or("").to_string();
    Ok(format!("{path}/bin/{name}"))
}

struct Movable {
    order: Vec<String>,
    move_: BTreeMap<String, Vec<(String, usize, usize)>>,
    stuck: Vec<(String, String, Vec<String>)>,
}

/// A block moves once every GLOB it runs is inside the pin it is moving to.
fn movable(ctx: &Ctx, text: &str, pins: &BTreeSet<String>) -> Movable {
    let mut m = Movable { order: Vec::new(), move_: BTreeMap::new(), stuck: Vec::new() };
    for (marker, a, b) in blocks(text) {
        let body = &text[a..b];
        let pin = match pin_of(&ctx.buck_src_dir, body) {
            Some(p) if pins.contains(&p) => p,
            _ => continue,
        };
        let foreign: Vec<String> = pin_paths(&ctx.buck_src_dir, body)
            .1
            .into_iter()
            .filter(|g| owner_of(g) != pin)
            .collect();
        if !foreign.is_empty() {
            m.stuck.push((marker, pin, foreign));
            continue;
        }
        if !m.move_.contains_key(&pin) {
            m.order.push(pin.clone());
        }
        m.move_.entry(pin).or_default().push((marker, a, b));
    }
    m
}

/// Calls left in vendor/src/BUCK that GLOB into exactly one migrated pin: a glob cannot cross a
/// package boundary, so these travel one TARGET at a time.
fn orphan_roots(ctx: &Ctx, text: &str, pins: &BTreeSet<String>) -> Vec<(usize, usize, String, Vec<String>)> {
    let mut found = Vec::new();
    for (start, end, body) in rule_calls(text) {
        let owners: BTreeSet<String> =
            pin_paths(&ctx.buck_src_dir, &body).1.iter().map(|g| owner_of(g).to_string()).collect();
        let migrated: Vec<&String> = owners.iter().filter(|o| pins.contains(*o)).collect();
        if migrated.len() != 1 || owners.len() != 1 {
            continue;
        }
        let names = target_names(&body);
        if !names.is_empty() {
            found.push((start, end, migrated[0].clone(), names));
        }
    }
    found
}

fn die(msg: String) -> ExitCode {
    eprintln!("{msg}");
    ExitCode::FAILURE
}

fn migrate(ctx: &Ctx, pins: &[String], dry: bool) -> Result<i32, String> {
    let text = fs::read_to_string(&ctx.buck_src).map_err(|e| format!("cannot read: {e}"))?;
    let want: BTreeSet<String> = pins.iter().cloned().collect();
    let m = movable(ctx, &text, &want);
    let n: usize = m.move_.values().map(|v| v.len()).sum();
    println!("{n} block(s) move into {} package(s); {} stay behind", m.move_.len(), m.stuck.len());
    for (marker, pin, foreign) in &m.stuck {
        let owners: BTreeSet<&str> = foreign.iter().map(|p| owner_of(p)).collect();
        let names: Vec<&str> = owners.into_iter().collect();
        println!("    STAYS {marker:32} ({pin}) names {}", names.join(" "));
    }
    if dry {
        for (pin, items) in &m.move_ {
            let bytes: usize = items.iter().map(|(_, a, b)| b - a).sum();
            println!("    {pin:22} {:3} block(s), {}k", items.len(), bytes / 1024);
        }
        return Ok(0);
    }
    if m.move_.is_empty() {
        return Ok(0);
    }

    // Which target names move, and where to.
    let mut names: HashMap<String, String> = HashMap::new();
    for (pin, items) in &m.move_ {
        for (_marker, a, b) in items {
            for name in target_names(&text[*a..*b]) {
                names.insert(name, pin.clone());
            }
        }
    }
    let mut all_pins = read_split_pins(&ctx.split_pins);
    all_pins.extend(m.move_.keys().cloned());
    let mut hints = read_hints(&ctx.hints_path);

    // 1. Cut each block out and write it into its pin's package.
    let mut spans: Vec<(usize, usize, String)> = Vec::new();
    for (pin, items) in &m.move_ {
        for (_marker, a, b) in items {
            spans.push((*a, *b, pin.clone()));
        }
    }
    spans.sort();
    let mut per_pin: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut keep = String::new();
    let mut last = 0;
    for (a, b, pin) in &spans {
        let body = rewrite_for_pin(ctx, &text[*a..*b], pin, &names, &all_pins, &mut hints);
        per_pin.entry(pin.clone()).or_default().push(body);
        keep.push_str(&text[last..*a]);
        last = *b;
    }
    keep.push_str(&text[last..]);
    // 1b. What stays behind still names files that just changed owner.
    let kept = labelize(ctx, &keep, "vendor/src", &all_pins, &mut hints);
    fs::write(&ctx.buck_src, kept).map_err(|e| format!("cannot write: {e}"))?;
    write_hints(&ctx.hints_path, &hints)?;
    for (pin, bodies) in &per_pin {
        let d = format!("{}/{pin}", ctx.buck_src_dir);
        let _ = fs::create_dir_all(&d);
        let f = format!("{d}/BUCK");
        let head = if is_file(&f) {
            String::new()
        } else {
            format!(
                "# Targets over the {pin} pin, materialized by scripts/buck-src.nu. The tree\n\
                 # itself is gitignored (content is pinned in nix/submodules.json); this file is\n\
                 # committed. One package per pin keeps what the Nix-lowered path has to parse\n\
                 # small enough to evaluate (plan/buck2-port.md phase 3).\n\n"
            )
        };
        let existing = fs::read_to_string(&f).unwrap_or_default();
        let sep = if existing.trim().is_empty() { "" } else { "\n\n" };
        let body = format!("{head}{}{sep}{}", existing.trim_end_matches('\n'), bodies.join("\n"));
        fs::write(&f, body).map_err(|e| format!("cannot write {f}: {e}"))?;
        println!("  vendor/src/{pin}: {} block(s)", bodies.len());
    }

    // 1c. Hand-written calls that glob a migrated pin travel as single TARGETS.
    let text = fs::read_to_string(&ctx.buck_src).map_err(|e| format!("cannot read: {e}"))?;
    let mut orphans = orphan_roots(ctx, &text, &all_pins);
    orphans.sort_by(|a, b| (a.0, a.1).cmp(&(b.0, b.1)));
    if !orphans.is_empty() {
        for (_s, _e, pin, tnames) in &orphans {
            for t in tnames {
                names.insert(t.clone(), pin.clone());
            }
        }
        let mut by_pin: BTreeMap<String, Vec<String>> = BTreeMap::new();
        let mut keep = String::new();
        let mut last = 0;
        for (start, end, pin, _t) in &orphans {
            by_pin
                .entry(pin.clone())
                .or_default()
                .push(rewrite_for_pin(ctx, &text[*start..*end], pin, &names, &all_pins, &mut hints));
            keep.push_str(&text[last..*start]);
            last = *end;
        }
        keep.push_str(&text[last..]);
        fs::write(&ctx.buck_src, keep).map_err(|e| format!("cannot write: {e}"))?;
        for (pin, bodies) in &by_pin {
            let f = format!("{}/{pin}/BUCK", ctx.buck_src_dir);
            if let Some(parent) = std::path::Path::new(&f).parent() {
                let _ = fs::create_dir_all(parent);
            }
            let existing = fs::read_to_string(&f).unwrap_or_default();
            let sep = if existing.trim().is_empty() { "" } else { "\n\n" };
            let body = format!("{}{sep}{}", existing.trim_end_matches('\n'), bodies.join("\n"));
            fs::write(&f, body).map_err(|e| format!("cannot write {f}: {e}"))?;
        }
        let pin_list: Vec<&String> = by_pin.keys().collect();
        println!(
            "  {} hand-written target(s) moved into {} package(s): {}",
            orphans.len(),
            by_pin.len(),
            pin_list.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(" ")
        );
        write_hints(&ctx.hints_path, &hints)?;
    }

    // 2. The switch, then everything that referred to a moved target.
    let mut updated = read_split_pins(&ctx.split_pins);
    updated.extend(m.move_.keys().cloned());
    write_split_pins(&ctx.split_pins, &updated)?;
    println!("  repointed references in {} file(s)", repoint(ctx, &names));
    println!("  opened up {} vendor/src target(s) now named from outside", publicise_referenced(ctx)?);
    let text = fs::read_to_string(&ctx.buck_src).map_err(|e| format!("cannot read: {e}"))?;
    println!("  fixed out_base on {} mig target(s)", fix_mig_out_base(ctx, &text));

    // 3. The SDK maps, naming the migrated pins' headers by label.
    let sdk_gen = cider_tool(&ctx.repo, "cider-sdk-header-roots")?;
    let out = Command::new(&sdk_gen)
        .args(NS)
        .current_dir(&ctx.repo)
        .output()
        .map_err(|e| format!("cannot run {sdk_gen}: {e}"))?;
    if !out.status.success() {
        eprint!("{}", String::from_utf8_lossy(&out.stderr));
        return Ok(1);
    }
    fs::write(format!("{}/buck/generated/sdk_headers.bzl", ctx.repo), &out.stdout)
        .map_err(|e| format!("cannot write sdk_headers.bzl: {e}"))?;
    let _ = Command::new(&sdk_gen)
        .arg("--framework-roots")
        .args(NS)
        .current_dir(&ctx.repo)
        .status();

    // 4. An export_file for every label that now points into a pin package.
    let exports = cider_tool(&ctx.repo, "cider-exports")?;
    let _ = Command::new(&exports).current_dir(&ctx.repo).status();
    let _ = Command::new(format!("{}/scripts/buck-fix-loads.nu", ctx.repo))
        .current_dir(&ctx.repo)
        .status();
    println!("migration written; build and iterate");
    Ok(0)
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let repo = match repo_root() {
        Ok(r) => r,
        Err(e) => return die(e),
    };
    let ctx = Ctx {
        buck_src: format!("{repo}/vendor/src/BUCK"),
        buck_src_dir: format!("{repo}/vendor/src"),
        split_pins: format!("{repo}/buck/generated/split-pins.txt"),
        hints_path: format!("{repo}/buck/generated/export-hints.json"),
        repo,
    };
    let text = match fs::read_to_string(&ctx.buck_src) {
        Ok(t) => t,
        Err(e) => return die(format!("cannot read {}: {e}", ctx.buck_src)),
    };
    let dry = argv.iter().any(|a| a == "--dry-run");

    if argv.iter().any(|a| a == "--list") {
        let mut by_pin: Vec<(String, Vec<(String, usize)>)> = Vec::new();
        for (marker, a, b) in blocks(&text) {
            let pin = pin_of(&ctx.buck_src_dir, &text[a..b]).unwrap_or_else(|| "(none)".to_string());
            match by_pin.iter_mut().find(|(p, _)| *p == pin) {
                Some((_, v)) => v.push((marker, b - a)),
                None => by_pin.push((pin, vec![(marker, b - a)])),
            }
        }
        // sorted(key=-total), which is STABLE, so equal totals keep first-seen order.
        by_pin.sort_by_key(|(_, items)| std::cmp::Reverse(items.iter().map(|(_, n)| *n).sum::<usize>()));
        for (pin, items) in &by_pin {
            let total: usize = items.iter().map(|(_, n)| *n).sum();
            println!("{total:8} bytes  {pin:24} {} block(s)", items.len());
        }
        return ExitCode::SUCCESS;
    }

    let mut candidates: BTreeSet<String> = BTreeSet::new();
    for (_marker, a, b) in blocks(&text) {
        if let Some(p) = pin_of(&ctx.buck_src_dir, &text[a..b]) {
            if !p.contains('/') && p != ".." {
                candidates.insert(p);
            }
        }
    }
    if argv.iter().any(|a| a == "--all") {
        let all: Vec<String> = candidates.into_iter().collect();
        return match migrate(&ctx, &all, dry) {
            Ok(0) => ExitCode::SUCCESS,
            Ok(c) => ExitCode::from(c as u8),
            Err(e) => die(e),
        };
    }
    if let Some(i) = argv.iter().position(|a| a == "--only") {
        let want: BTreeSet<String> = match argv.get(i + 1) {
            Some(v) => v.split(',').map(|s| s.to_string()).collect(),
            None => return die("--only wants a comma separated list".to_string()),
        };
        let unknown: Vec<&String> = want.iter().filter(|w| !candidates.contains(*w)).collect();
        if !unknown.is_empty() {
            eprintln!(
                "no movable blocks for: {}",
                unknown.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(" ")
            );
            return ExitCode::FAILURE;
        }
        let list: Vec<String> = want.into_iter().collect();
        return match migrate(&ctx, &list, dry) {
            Ok(0) => ExitCode::SUCCESS,
            Ok(c) => ExitCode::from(c as u8),
            Err(e) => die(e),
        };
    }
    eprintln!("{USAGE}");
    ExitCode::FAILURE
}
