//! Which PROJECT FILES each target reads, so a lowered derivation can take a subset instead of
//! the whole tree. The Rust rewrite of scripts/buck2-graph-sources.py, task #99.
//!
//! Every lowered target used to depend on the whole filtered project, 306,019 files, so a
//! one-line source edit relowered all of them. With this the median target names about 4,000.
//!
//! THE RULE, and scripts/buck-lower-srcdeps.py audits its completeness:
//!   project-relative tokens in the target's own argvs;
//!   plus every link TARGET of each staged tree it consumes, which is where the header cones
//!     live, NOT the staging actions' argvs, since those carry no command at all;
//!   plus, WHOLESALE, any project directory used as an include root, because a compile can read
//!     anything under one and no per-file set could know what;
//!   plus, WHOLESALE, a rustc crate's own directory, because a crate names only its ROOT and
//!     finds the rest through `mod`, which no #include scanner can see;
//!   plus a fixpoint over QUOTED includes, which resolve against the INCLUDING FILE's own
//!     directory and are therefore invisible to every buck2 declaration.
//!
//! BUILT BY NIX, NOT BY BUCK2. Second binary of this crate so src/pyjson.rs is shared rather
//! than copied.
//!
//! VERIFIED against the python over the REAL 147 MB graph and the real working tree: 717 output
//! files, byte for byte.
//!
//! NOTE THE JSON MODE. This tool writes with sort_keys=True and a TRAILING NEWLINE, where
//! buck-graph-to-specs writes insertion order and no newline. Both are python defaults for the
//! call each makes, and getting them the wrong way round is a silent hash change.

#[path = "pyjson.rs"]
mod pyjson;
// Shared with the dump binary rather than copied into it: one implementation, one set of
// expectations checked against hashlib.
#[path = "sha256.rs"]
mod sha256;
use sha256::sha256_hex16;

use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::io::Write;
use std::path::Path;
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
const UNGROUPED: &[&str] = &["buck-src/", "pins/", "buck-rust/"];

fn group_of(p: &str) -> Option<String> {
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

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() != 3 {
        eprintln!("  cider-graph-sources <graph.json> <graph-data-dir> <out-dir>     (cwd = project root)");
        return ExitCode::from(2);
    }
    let (graph_path, data, outdir) = (&args[0], &args[1], Path::new(&args[2]));
    if let Err(e) = fs::create_dir_all(outdir) {
        return die(format!("cannot create {}: {e}", outdir.display()));
    }
    let raw = match fs::read_to_string(graph_path) {
        Ok(t) => t,
        Err(e) => return die(format!("cannot read {graph_path}: {e}")),
    };
    let graph: Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => return die(format!("cannot parse {graph_path}: {e}")),
    };

    // {staged tree: {link name: link target}} back out of the per farm tables. TWO FORMS,
    // because the dump writes names only when a target is derivable from its name and falls back
    // to explicit two columns when it is not. Reading the wrong one would not fail, it would
    // silently resolve every link to nonsense, so the form is taken from the INDEX.
    let empty = Map::new();
    let staged_trees = graph.get("stagedTrees").and_then(|v| v.as_object()).unwrap_or(&empty);
    let mut trees: HashMap<String, Vec<(String, String)>> = HashMap::new();
    for (path, meta) in staged_trees {
        let mut links: Vec<(String, String)> = Vec::new();
        let n = meta.get("n").and_then(|v| v.as_i64()).unwrap_or(0);
        if n > 0 {
            let table = meta.get("table").and_then(|v| v.as_str()).unwrap_or("");
            let text = match fs::read_to_string(format!("{data}/{table}")) {
                Ok(t) => t,
                Err(e) => return die(format!("cannot read {data}/{table}: {e}")),
            };
            let lines: Vec<&str> = if text.is_empty() { Vec::new() } else { text.split_inclusive('\n').collect() };
            if let Some(k) = meta.get("k").and_then(|v| v.as_i64()) {
                let pre = meta.get("prefix").and_then(|v| v.as_str()).unwrap_or("");
                for line in lines {
                    let rel = line.strip_suffix('\n').unwrap_or(line);
                    let ups = "../".repeat((k as usize) + rel.matches('/').count());
                    links.push((rel.to_string(), format!("{ups}{pre}{rel}")));
                }
            } else {
                for line in lines {
                    let line = line.strip_suffix('\n').unwrap_or(line);
                    let (name, target) = match line.find('\t') {
                        Some(i) => (&line[..i], &line[i + 1..]),
                        None => (line, ""),
                    };
                    links.push((name.to_string(), target.to_string()));
                }
            }
        }
        trees.insert(path.clone(), links);
    }

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

    let union: BTreeSet<String> = per_target.values().flatten().cloned().collect();
    let union: Vec<String> = union.into_iter().collect();

    // TWO FILES, for the same reason the dump split this out of graph.json: the per-target
    // breakdown is millions of entries and only the narrowSources path ever looks at it, while
    // every evaluation wants the union.
    let mut m = Map::new();
    m.insert(
        "projectSources".into(),
        Value::Array(union.iter().map(|s| Value::String(s.clone())).collect()),
    );
    if let Err(e) = write_json(outdir.join("sources.json"), &Value::Object(m)) {
        return die(format!("write sources.json: {e}"));
    }

    // 357 MB THAT NOTHING AUTOMATED READS. Off by default; a hand-run tool can ask for it.
    let want_targets = std::env::var("CIDER_EMIT_TARGET_SOURCES").ok().as_deref() == Some("1")
        || std::env::var("DARLING_EMIT_TARGET_SOURCES").ok().as_deref() == Some("1");
    if !want_targets {
        eprintln!("  skipping target-sources.json (set CIDER_EMIT_TARGET_SOURCES=1 to emit)");
    } else {
        let mut m = Map::new();
        for (k, v) in &per_target {
            m.insert(k.clone(), Value::Array(v.iter().map(|s| Value::String(s.clone())).collect()));
        }
        if let Err(e) = write_json(outdir.join("target-sources.json"), &Value::Object(m)) {
            return die(format!("write target-sources.json: {e}"));
        }
    }

    // PER-TARGET FILE LISTS AS FILES, and an INDEX naming them (#54). Named by CONTENT, like the
    // treelinks tables since #63, so targets that read exactly the same set share a file.
    let subdir = outdir.join("subsets");
    if let Err(e) = fs::create_dir_all(&subdir) {
        return die(format!("cannot create subsets: {e}"));
    }
    let mut written: HashMap<String, String> = HashMap::new();
    let mut index: Map<String, Value> = Map::new();
    for (label, files) in &per_target {
        let mut text = String::new();
        for p in files {
            text.push_str(p);
            text.push('\n');
        }
        let rel = match written.get(&text) {
            Some(r) => r.clone(),
            None => {
                let r = format!("subsets/{}.txt", sha256_hex16(text.as_bytes()));
                written.insert(text.clone(), r.clone());
                if let Err(e) = fs::write(outdir.join(&r), &text) {
                    return die(format!("write {r}: {e}"));
                }
                r
            }
        };
        index.insert(label.clone(), Value::String(rel));
    }
    if let Err(e) = write_json(outdir.join("target-subsets.json"), &Value::Object(index.clone())) {
        return die(format!("write target-subsets.json: {e}"));
    }
    println!(
        "  {} target subset(s) sharing {} distinct list file(s)",
        index.len(),
        written.len()
    );

    // exists and NOT lexists, to match the builtins.pathExists this replaces: a dangling symlink
    // is false to Nix, and staging one would point at nothing.
    let mut groups_json: Map<String, Value> = Map::new();
    let mut edge_count = 0usize;
    let mut distinct_groups: BTreeSet<String> = BTreeSet::new();
    let mut distinct_shallow: BTreeSet<String> = BTreeSet::new();
    for (label, files) in &per_target {
        let g: BTreeSet<String> = files.iter().filter_map(|p| group_of(p)).collect();
        let mut shallow: Vec<String> = Vec::new();
        for p in files {
            if !UNGROUPED.iter().any(|u| p.starts_with(u))
                && group_of(p).is_none()
                && p != "."
                && Path::new(p).exists()
            {
                shallow.push(p.clone());
            }
        }
        shallow.sort();
        edge_count += g.len();
        distinct_groups.extend(g.iter().cloned());
        distinct_shallow.extend(shallow.iter().cloned());
        let mut o = Map::new();
        o.insert("groups".into(), Value::Array(g.into_iter().map(Value::String).collect()));
        o.insert("shallow".into(), Value::Array(shallow.into_iter().map(Value::String).collect()));
        groups_json.insert(label.clone(), Value::Object(o));
    }
    if let Err(e) = write_json(outdir.join("target-groups.json"), &Value::Object(groups_json)) {
        return die(format!("write target-groups.json: {e}"));
    }
    println!(
        "  {edge_count} target-to-group edge(s) over {} distinct group(s), and {} file(s) in no group",
        distinct_groups.len(),
        distinct_shallow.len()
    );

    let total: usize = per_target.values().map(|v| v.len()).sum();
    println!(
        "sources: {} distinct project source(s), from {total} per-target entries across {} target(s)",
        union.len(),
        per_target.len()
    );
    if union.is_empty() {
        return die("sources: the union is empty, which cannot be right".into());
    }
    ExitCode::SUCCESS
}

/// sort_keys=True AND a trailing newline, which is what every json.dump call in this tool asks
/// for. The spec generator writes neither; mixing them up is a silent hash change.
fn write_json(path: std::path::PathBuf, v: &Value) -> std::io::Result<()> {
    let mut f = fs::File::create(path)?;
    f.write_all(pyjson::dumps_sorted(v).as_bytes())?;
    f.write_all(b"\n")
}
