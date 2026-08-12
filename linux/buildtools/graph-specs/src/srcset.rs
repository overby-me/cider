//! THE PER-TARGET SOURCE SET, shared by the sources pass and by the checks that verify it.
//!
//! This is the half of cider-graph-sources that ANSWERS THE QUESTION, split out from the half
//! that writes files, because two other tools need exactly this answer and a second
//! implementation of it would be a second thing to keep in step. buck-declaration-gap compares
//! its own four-way partition against this, and buck-lower-srcdeps audits its completeness;
//! both used to import the python module for the same reason.
//!
//! THE RULE, unchanged from the python and from the binary this came out of:
//!   project-relative tokens in the target own argvs;
//!   plus every link TARGET of each staged tree it consumes, which is where the header cones
//!     live, NOT the staging actions argvs, since those carry no command at all;
//!   plus, WHOLESALE, any project directory used as an include root, because a compile can read
//!     anything under one and no per-file set could know what;
//!   plus, WHOLESALE, a rustc crate own directory, because a crate names only its ROOT and
//!     finds the rest through mod, which no include scanner can see;
//!   plus a fixpoint over QUOTED includes, which resolve against the INCLUDING FILE own
//!     directory and are therefore invisible to every buck2 declaration.
//!
//! EXTRACTING IT MOVED NO BEHAVIOUR, and that is checked rather than asserted: nix build
//! .#graph-sources gives the same content addressed output path as before the split.

#![allow(dead_code)]
// THE SHARED MODULES ARE THE BINARY'S, not this one's: a module included by `#[path]` cannot
// re-include its siblings without giving every binary two copies of them. What this file needs
// from them is passed in or re-exported by the including binary.

use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::process::ExitCode;

// ---------------------------------------------------------------- argv scraping

const GLUED: &[&str] = &["-I", "-F", "-L", "-iquote"];

fn skip_prefix(s: &str) -> bool {
    s.starts_with('/') || s.starts_with('@') || s.starts_with("buck-out/")
}

/// Candidate project paths hiding in one argv token.
fn project_candidates(tok: &str) -> Vec<String> {
    let mut out = Vec::new();
    if tok.is_empty() || skip_prefix(tok) {
        return out;
    }
    out.push(tok.to_string());
    for g in GLUED {
        if tok.starts_with(g) && tok.len() > g.len() {
            let rest = &tok[g.len()..];
            if !skip_prefix(rest) {
                out.push(rest.to_string());
            }
        }
    }
    // A COMMA JOINED -Wl, TOKEN HIDES A FILE. darwin.bzl emits link_flag_files as
    // `<flag>,<path>` in ONE argv token, so `-Wl,-alias_list,darwin/libm/Exports/x.alias` never
    // matched anything and the alias file stayed out of the narrowed union. The link then died
    // with `ld: can't open alias file`, naming a path that is right there in the tree.
    if let Some(rest) = tok.strip_prefix("-Wl,") {
        if rest.contains(',') {
            for part in rest.split(',') {
                if !part.is_empty() && !skip_prefix(part) && !part.starts_with('-') {
                    out.push(part.to_string());
                }
            }
        }
    }
    out
}

fn include_roots(argv: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    for (i, t) in argv.iter().enumerate() {
        if matches!(t.as_str(), "-I" | "-isystem" | "-F" | "-iquote") {
            if i + 1 < argv.len() {
                out.push(argv[i + 1].clone());
            }
        } else if (t.starts_with("-I") || t.starts_with("-F")) && t.len() > 2 {
            out.push(t[2..].to_string());
        }
    }
    out
}

/// EVERY PATH TEST MEMOISED. In the python this function was 27.9s of a 64s derivation, and the
/// cost was not parsing, writing, reading contents or the fixpoint: it was the sheer NUMBER of
/// path tests, on the order of ten million lexists. The same candidate recurs constantly across
/// actions, so a map collapses those to one syscall per DISTINCT path. Safe because nothing
/// writes to the tree while this runs.
struct Fs {
    lex: HashMap<String, bool>,
    dir: HashMap<String, bool>,
    quoted: HashMap<String, Vec<String>>,
    whole: HashMap<String, Vec<String>>,
    manifest: HashMap<String, Vec<String>>,
}

/// os.path.normpath: purely textual, no symlink resolution, and it strips a trailing slash.
fn normpath(p: &str) -> String {
    let absolute = p.starts_with('/');
    let mut out: Vec<&str> = Vec::new();
    for seg in p.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                if let Some(last) = out.last() {
                    if *last != ".." {
                        out.pop();
                        continue;
                    }
                }
                if absolute {
                    continue;
                }
                out.push("..");
            }
            s => out.push(s),
        }
    }
    let joined = out.join("/");
    if absolute {
        format!("/{joined}")
    } else if joined.is_empty() {
        ".".to_string()
    } else {
        joined
    }
}

fn dirname(p: &str) -> &str {
    match p.rfind('/') {
        Some(i) => &p[..i],
        None => "",
    }
}

const C_FAMILY: &[&str] = &[
    ".c", ".cc", ".cpp", ".cxx", ".m", ".mm", ".h", ".hpp", ".hh", ".inc",
];

impl Fs {
    fn new() -> Fs {
        Fs {
            lex: HashMap::new(),
            dir: HashMap::new(),
            quoted: HashMap::new(),
            whole: HashMap::new(),
            manifest: HashMap::new(),
        }
    }

    fn lexists(&mut self, p: &str) -> bool {
        if let Some(v) = self.lex.get(p) {
            return *v;
        }
        let v = fs::symlink_metadata(p).is_ok();
        self.lex.insert(p.to_string(), v);
        v
    }

    fn isdir(&mut self, p: &str) -> bool {
        if let Some(v) = self.dir.get(p) {
            return *v;
        }
        let v = fs::metadata(p).map(|m| m.is_dir()).unwrap_or(false);
        self.dir.insert(p.to_string(), v);
        v
    }

    /// Every file under a directory. os.walk with followlinks=False: a symlinked DIRECTORY is
    /// not descended, a symlinked FILE is a file.
    fn under(&mut self, d: &str) -> Vec<String> {
        if let Some(v) = self.whole.get(d) {
            return v.clone();
        }
        let mut found = Vec::new();
        let mut stack = vec![d.to_string()];
        while let Some(cur) = stack.pop() {
            let entries = match fs::read_dir(&cur) {
                Ok(e) => e,
                Err(_) => continue,
            };
            for e in entries.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                let p = if cur.is_empty() { name.clone() } else { format!("{cur}/{name}") };
                match e.file_type() {
                    Ok(ft) if ft.is_dir() => stack.push(p),
                    Ok(_) => found.push(p),
                    Err(_) => {}
                }
            }
        }
        self.whole.insert(d.to_string(), found.clone());
        found
    }

    /// Existing project files a quoted include in `rel` resolves to, against the INCLUDING
    /// FILE's own directory, which is what the C preprocessor does and what no buck2
    /// declaration records.
    ///
    /// LEXISTS, AND THE DESTINATION TOO. This test used to be exists, which FOLLOWS the link, so
    /// a header that is a symlink to a sibling subtree read as absent whenever the staged tree
    /// did not carry the destination, and the header was dropped. Recording the link alone would
    /// stage something pointing at nothing, so record BOTH.
    fn quoted_includes(&mut self, rel: &str) -> Vec<String> {
        if let Some(v) = self.quoted.get(rel) {
            return v.clone();
        }
        let mut found: Vec<String> = Vec::new();
        if C_FAMILY.iter().any(|e| rel.ends_with(e)) {
            let data = fs::read(rel).unwrap_or_default();
            let base = dirname(rel).to_string();
            for target in scan_quoted_includes(&data) {
                let joined = if base.is_empty() { target.clone() } else { format!("{base}/{target}") };
                let res = normpath(&joined);
                // Escaping the project entirely is a system header by another name.
                if res.starts_with("..") || !self.lexists(&res) {
                    continue;
                }
                found.push(res.clone());
                if fs::symlink_metadata(&res).map(|m| m.file_type().is_symlink()).unwrap_or(false) {
                    if let Ok(t) = fs::read_link(&res) {
                        let t = t.to_string_lossy().into_owned();
                        let d = dirname(&res).to_string();
                        let joined = if d.is_empty() { t } else { format!("{d}/{t}") };
                        let dest = normpath(&joined);
                        if !dest.starts_with("..") && !dest.starts_with('/') && self.lexists(&dest) {
                            found.push(dest);
                        }
                    }
                }
            }
        }
        self.quoted.insert(rel.to_string(), found.clone());
        found
    }

    /// Project files a staged TSV names, for an action that reads its inputs from a FILE. A
    /// SOURCE ONLY TARGET IS INVISIBLE EVERYWHERE ELSE: //etc:resolv.conf appears in neither the
    /// argv nor the declared inputs, and the narrowed union dropped it, failing the prefix on
    /// `cp: cannot stat 'etc/resolv.conf'` at the very last derivation of a 2,333 builder run.
    /// Any column that names an existing project file counts, which also covers the two column
    /// farm tables without needing to know which form a given TSV is in.
    fn manifest_sources(&mut self, data: &str, path: &str) -> Vec<String> {
        if let Some(v) = self.manifest.get(path) {
            return v.clone();
        }
        let mut found = Vec::new();
        let staged = format!("{}/staged/{}", data, staged_name(path));
        if let Ok(text) = fs::read_to_string(&staged) {
            for line in text.split('\n') {
                let line = line.strip_suffix('\n').unwrap_or(line);
                for col in line.split('\t') {
                    if !col.is_empty()
                        && !skip_prefix(col)
                        && !col.starts_with("..")
                        && self.lexists(col)
                    {
                        found.push(col.to_string());
                    }
                }
            }
        }
        self.manifest.insert(path.to_string(), found.clone());
        found
    }
}

/// Where linux/buildtools/graph-specs/src/dump.rs parked a staged artifact. Same rule as the dump:
/// re.sub(r"[^A-Za-z0-9_.-]+", "_", path), which collapses RUNS to a single underscore.
fn staged_name(path: &str) -> String {
    let mut out = String::new();
    let mut in_run = false;
    for c in path.chars() {
        if c.is_ascii_alphanumeric() || c == '_' || c == '.' || c == '-' {
            out.push(c);
            in_run = false;
        } else if !in_run {
            out.push('_');
            in_run = true;
        }
    }
    out
}

/// ^[ \t]*#[ \t]*include[ \t]*"([^"]+)" with re.M, over BYTES.
fn scan_quoted_includes(data: &[u8]) -> Vec<String> {
    let mut out = Vec::new();
    let mut line_start = 0usize;
    let n = data.len();
    let mut i = 0usize;
    while line_start <= n {
        let line_end = match data[line_start..].iter().position(|&b| b == b'\n') {
            Some(k) => line_start + k,
            None => n,
        };
        let line = &data[line_start..line_end];
        i = 0;
        while i < line.len() && (line[i] == b' ' || line[i] == b'\t') {
            i += 1;
        }
        if i < line.len() && line[i] == b'#' {
            i += 1;
            while i < line.len() && (line[i] == b' ' || line[i] == b'\t') {
                i += 1;
            }
            if line[i..].starts_with(b"include") {
                i += 7;
                while i < line.len() && (line[i] == b' ' || line[i] == b'\t') {
                    i += 1;
                }
                if i < line.len() && line[i] == b'"' {
                    i += 1;
                    if let Some(k) = line[i..].iter().position(|&b| b == b'"') {
                        out.push(String::from_utf8_lossy(&line[i..i + k]).into_owned());
                    }
                }
            }
        }
        if line_end >= n {
            break;
        }
        line_start = line_end + 1;
    }
    out
}

// ---------------------------------------------------------------- grouping

/// buck-src, pins and buck-rust are deliberately ungrouped, each for its own reason: the first
/// two are pins staged wholesale by revision and a group there would collide with those
/// symlinks, and buck-rust is gitignored and comes from the vendor derivation, so a
/// builtins.path at one would fail with "not tracked by Git".
pub const UNGROUPED: &[&str] = &["buck-src/", "pins/", "buck-rust/"];

pub fn group_of(p: &str) -> Option<String> {
    if UNGROUPED.iter().any(|u| p.starts_with(u)) {
        return None;
    }
    let segs: Vec<&str> = p.split('/').collect();
    if segs.len() >= 4 {
        Some(segs[..3].join("/"))
    } else {
        None
    }
}

// ---------------------------------------------------------------- main

fn die(msg: String) -> ExitCode {
    eprintln!("{msg}");
    ExitCode::FAILURE
}

fn strs(a: &Value, k: &str) -> Vec<String> {
    a.get(k)
        .and_then(|v| v.as_array())
        .map(|v| v.iter().filter_map(|x| x.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default()
}


/// {target label: sorted project files it reads}.
pub fn target_sources(
    graph: &Value,
    trees_in: &[(String, Vec<(String, String)>)],
    data: &str,
) -> BTreeMap<String, Vec<String>> {
    // KEPT WHEN THE TABLE READER MOVED OUT: the three lookups below still borrow it as the
    // empty default, and the compiler only says "cannot find value empty" fifty lines later.
    let empty = Map::new();

    // The staged farm tables, through the SHARED reader: three binaries of this crate need
    // exactly this and a copy of a rule whose failure mode is silent is how they drift apart.
    // The farm tables arrive already read, through the SHARED reader in trees.rs.
    let trees: HashMap<String, Vec<(String, String)>> =
        trees_in.iter().cloned().collect();

    let staged = graph.get("staged").and_then(|v| v.as_object()).unwrap_or(&empty);
    let producers = graph.get("producers").and_then(|v| v.as_object()).unwrap_or(&empty);
    let actions = graph.get("actions").and_then(|v| v.as_array()).cloned().unwrap_or_default();

    let mut known: HashSet<String> = producers.keys().cloned().collect();
    known.extend(staged.keys().cloned());
    known.extend(trees.keys().cloned());

    let owner_of = |path: &str| -> Option<String> {
        let segs: Vec<&str> = path.split('/').collect();
        for n in (1..=segs.len()).rev() {
            let pfx = segs[..n].join("/");
            if known.contains(&pfx) {
                return Some(pfx);
            }
        }
        None
    };

    // The destinations each staged farm's links point at.
    let mut tree_srcs: HashMap<String, BTreeSet<String>> = HashMap::new();
    for (path, links) in &trees {
        let mut out = BTreeSet::new();
        for (rel, tgt) in links {
            let joined = format!("{path}/{rel}");
            let d = dirname(&joined).to_string();
            let full = if d.is_empty() { tgt.clone() } else { format!("{d}/{tgt}") };
            let dest = normpath(&full);
            if !dest.starts_with("buck-out/") && !dest.starts_with('/') {
                out.insert(dest);
            }
        }
        tree_srcs.insert(path.clone(), out);
    }

    // ONCE PER OWNER, NOT ONCE PER TARGET. The closure of a farm is a property of the FARM; the
    // python measured this at 10.8s of 25.2s before it was cached.
    let mut closure_cache: HashMap<String, BTreeSet<String>> = HashMap::new();

    // by_target uses the SIMPLE split, not the strict identity regex the spec generator uses.
    // Kept as it is: changing it here would regroup this map against that one.
    let mut order: Vec<String> = Vec::new();
    let mut by_target: HashMap<String, Vec<usize>> = HashMap::new();
    for (i, a) in actions.iter().enumerate() {
        let ident = a.get("identity").and_then(|v| v.as_str()).unwrap_or("");
        let label = match ident.find(" (") {
            Some(k) => &ident[..k],
            None => ident,
        };
        if !by_target.contains_key(label) {
            order.push(label.to_string());
        }
        by_target.entry(label.to_string()).or_default().push(i);
    }

    let mut fsc = Fs::new();
    let mut per_target: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for label in &order {
        let acts = &by_target[label];
        let mut srcs: BTreeSet<String> = BTreeSet::new();

        for &i in acts {
            for tok in strs(&actions[i], "argv") {
                for cand in project_candidates(&tok) {
                    if fsc.lexists(&cand) {
                        srcs.insert(cand);
                        break;
                    }
                }
            }
        }
        for &i in acts {
            for d in include_roots(&strs(&actions[i], "argv")) {
                if !skip_prefix(&d) && fsc.isdir(&d) {
                    srcs.extend(fsc.under(&d));
                }
            }
        }
        // A RUST CRATE NAMES ONLY ITS ROOT. rustc gets lib.rs in argv and finds everything else
        // through `mod`, which the #include scanner cannot see: of 77,709 recorded sources the
        // whole server crate contributed exactly ONE, and the narrowed endpoint died with
        // "file not found for module `xnu`" after 1,462 green builders.
        for &i in acts {
            let ident = actions[i].get("identity").and_then(|v| v.as_str()).unwrap_or("");
            if !ident.contains("(rustc ") {
                continue;
            }
            for tok in strs(&actions[i], "argv") {
                if tok.ends_with(".rs") && !skip_prefix(&tok) {
                    let d = dirname(&tok).to_string();
                    if !d.is_empty() && fsc.isdir(&d) {
                        srcs.extend(fsc.under(&d));
                    }
                }
            }
        }
        for &i in acts {
            for inp in strs(&actions[i], "inputs") {
                if inp.ends_with(".tsv") && staged.contains_key(&inp) {
                    srcs.extend(fsc.manifest_sources(data, &inp));
                }
            }
        }
        let mut owners: BTreeSet<String> = BTreeSet::new();
        for &i in acts {
            for inp in strs(&actions[i], "inputs") {
                if let Some(o) = owner_of(&inp) {
                    owners.insert(o);
                }
            }
        }
        for o in &owners {
            if !tree_srcs.contains_key(o) {
                continue;
            }
            let hit = match closure_cache.get(o) {
                Some(h) => h.clone(),
                None => {
                    let mut h = tree_srcs[o].clone();
                    for dest in &tree_srcs[o] {
                        if let Some(sub) = owner_of(dest) {
                            if let Some(s) = tree_srcs.get(&sub) {
                                h.extend(s.iter().cloned());
                            }
                        }
                    }
                    closure_cache.insert(o.clone(), h.clone());
                    h
                }
            };
            srcs.extend(hit);
        }
        // TO A FIXPOINT, because headers include headers.
        let mut pending: Vec<String> = srcs.iter().cloned().collect();
        while !pending.is_empty() {
            let mut nxt = Vec::new();
            for f in &pending {
                for r in fsc.quoted_includes(f) {
                    if srcs.insert(r.clone()) {
                        nxt.push(r);
                    }
                }
            }
            pending = nxt;
        }
        per_target.insert(label.clone(), srcs.into_iter().collect());
    }
    per_target
}
