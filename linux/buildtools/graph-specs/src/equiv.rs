//! ARE TWO DUMPED GRAPHS THE SAME GRAPH, IGNORING HOW THEY ARE ENCODED?
//!
//! Written for #56, where the graph stopped being dumped from the project and started being
//! dumped from a skeleton (build files verbatim, every other file present but empty). The claim
//! that made that safe is that buck2 analysis cannot read a source file, and a claim like that
//! is worth exactly as much as the check behind it. So this compares the two dumps by MEANING:
//! every action with its argv, env, inputs and outputs; every staged artifact by content hash;
//! and every staged farm by its reconstructed links.
//!
//! Reconstructed, because the tables have two encodings since #58: names only when the target
//! is derivable from the name, and two columns when it is not. Comparing the files byte for
//! byte would report a difference that is purely how it is written down, which is the kind of
//! false positive that trains you to ignore a check.
//!
//! Keys the dump no longer writes are simply absent from both sides and are reported as such
//! rather than silently skipped, since "the key vanished" is a real answer.
//!
//! Usage:
//!   cider-graph-equiv <old-graph> <old-data> <new-graph> <new-data>
//!
//! Exit 0 when the graphs agree, 1 when they do not, 2 on infrastructure trouble.
//!
//! THE RUST REWRITE of the python buck-graph-equiv (#98). It is here rather than in nushell
//! because it is a HASH JOIN over data it computes: two maps of 8,704 actions keyed by identity,
//! plus one sha256 per staged artifact. A nushell record is not a hash map, and 100,001 lookups
//! into a 12,001 key record measured 51.8 seconds.
//!
//! BYTE IDENTICAL TO THE PYTHON, in both the agreeing and the differing case. The differing case
//! is the one that matters, because it is the only path that prints VALUES, and python prints
//! them with str(), which for a dict is its repr: single quoted keys, ", " between items. That
//! renderer is py_str below and it is why this file is longer than the python.

// SHARED, so it carries a helper this binary does not call. Allowed rather than split: one
// implementation of the hash is the whole point of the module.
#[path = "sha256.rs"]
#[allow(dead_code)]
mod sha256;
use sha256::sha256;

use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;
use std::process::ExitCode;

fn die(msg: String) -> ExitCode {
    eprintln!("{msg}");
    ExitCode::from(2)
}

fn load(graph: &str) -> Result<Value, String> {
    let path = Path::new(graph).join("graph.json");
    if !path.exists() {
        return Err(format!("no graph.json in {graph}"));
    }
    let raw = fs::read_to_string(&path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    serde_json::from_str(&raw).map_err(|e| format!("cannot parse {}: {e}", path.display()))
}

/// {farm: {link name: link target}}, from either table encoding.
fn links_of(g: &Value, data: &str) -> Result<BTreeMap<String, BTreeMap<String, String>>, String> {
    let empty = Map::new();
    let trees = g.get("stagedTrees").and_then(|v| v.as_object()).unwrap_or(&empty);
    let mut out: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    for (path, meta) in trees {
        let mut links: BTreeMap<String, String> = BTreeMap::new();
        let n = meta.get("n").and_then(|v| v.as_i64()).unwrap_or(0);
        if n > 0 {
            let table = meta.get("table").and_then(|v| v.as_str()).unwrap_or("");
            let tp = Path::new(data).join(table);
            if !tp.exists() {
                return Err(format!("missing table {}", tp.display()));
            }
            let text = fs::read_to_string(&tp).map_err(|e| format!("cannot read {}: {e}", tp.display()))?;
            match meta.get("k").and_then(|v| v.as_i64()) {
                Some(k) => {
                    let pre = meta.get("prefix").and_then(|v| v.as_str()).unwrap_or("");
                    for line in text.split_inclusive('\n') {
                        let rel = line.strip_suffix('\n').unwrap_or(line);
                        let ups = "../".repeat(k as usize + rel.matches('/').count());
                        links.insert(rel.to_string(), format!("{ups}{pre}{rel}"));
                    }
                }
                None => {
                    for line in text.split_inclusive('\n') {
                        let line = line.strip_suffix('\n').unwrap_or(line);
                        let (name, target) = match line.find('\t') {
                            Some(i) => (&line[..i], &line[i + 1..]),
                            None => (line, ""),
                        };
                        links.insert(name.to_string(), target.to_string());
                    }
                }
            }
        }
        out.insert(path.clone(), links);
    }
    Ok(out)
}

/// {path relative to <data>/staged: full sha256 hex} for every staged artifact.
fn staged_hashes(data: &str) -> BTreeMap<String, String> {
    let root = Path::new(data).join("staged");
    let mut out = BTreeMap::new();
    let mut stack = vec![root.clone()];
    while let Some(dir) = stack.pop() {
        let rd = match fs::read_dir(&dir) {
            Ok(r) => r,
            Err(_) => continue,
        };
        for ent in rd.flatten() {
            let p = ent.path();
            // symlink_metadata, so a link is never followed into another tree; the python
            // reaches these through os.walk, which does not follow directory symlinks either.
            let md = match fs::symlink_metadata(&p) {
                Ok(m) => m,
                Err(_) => continue,
            };
            if md.is_dir() {
                stack.push(p);
            } else if md.is_file() {
                if let Ok(bytes) = fs::read(&p) {
                    let rel = p.strip_prefix(&root).unwrap_or(&p).to_string_lossy().into_owned();
                    let d = sha256(&bytes);
                    let hex: String = d.iter().map(|b| format!("{b:02x}")).collect();
                    out.insert(rel, hex);
                }
            }
        }
    }
    out
}

/// Actions keyed by identity so a reordering is not a difference. The identity is unique per
/// action by construction (it is what the dump derives its action ids from).
fn by_identity(g: &Value) -> BTreeMap<String, Value> {
    let mut out = BTreeMap::new();
    if let Some(acts) = g.get("actions").and_then(|v| v.as_array()) {
        for act in acts {
            let ident = act.get("identity").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let mut m = Map::new();
            m.insert("argv".into(), act.get("argv").cloned().unwrap_or(Value::Null));
            m.insert("env".into(), act.get("env").cloned().unwrap_or(Value::Null));
            m.insert("inputs".into(), sorted_strings(act.get("inputs")));
            m.insert("outputs".into(), sorted_strings(act.get("outputs")));
            out.insert(ident, Value::Object(m));
        }
    }
    out
}

fn sorted_strings(v: Option<&Value>) -> Value {
    let mut items: Vec<String> = v
        .and_then(|x| x.as_array())
        .map(|a| a.iter().map(py_str).collect())
        .unwrap_or_default();
    items.sort();
    Value::Array(items.into_iter().map(Value::String).collect())
}

/// python's str(): a string is itself, everything else is its repr.
fn py_str(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        other => py_repr(other),
    }
}

/// python's repr(), for the value kinds a graph holds. Single quoted strings, ", " between
/// items, True/False/None. This is what str(dict) prints, and the sample lines quote it.
fn py_repr(v: &Value) -> String {
    match v {
        Value::Null => "None".into(),
        Value::Bool(true) => "True".into(),
        Value::Bool(false) => "False".into(),
        Value::Number(n) => n.to_string(),
        Value::String(s) => py_quote(s),
        Value::Array(a) => {
            let inner: Vec<String> = a.iter().map(py_repr).collect();
            format!("[{}]", inner.join(", "))
        }
        Value::Object(o) => {
            let inner: Vec<String> = o
                .iter()
                .map(|(k, val)| format!("{}: {}", py_quote(k), py_repr(val)))
                .collect();
            format!("{{{}}}", inner.join(", "))
        }
    }
}

/// python quotes a string with ' unless it contains one and no ", which is the only case that
/// switches to ". Backslash and the quote in use are escaped, and so are the control characters
/// python spells with a short escape.
fn py_quote(s: &str) -> String {
    let quote = if s.contains('\'') && !s.contains('"') { '"' } else { '\'' };
    let mut out = String::with_capacity(s.len() + 2);
    out.push(quote);
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c == quote => {
                out.push('\\');
                out.push(c);
            }
            c => out.push(c),
        }
    }
    out.push(quote);
    out
}

/// python's str(x)[:n], which slices CHARACTERS and not bytes.
fn head(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// True when they differ. Prints a few concrete examples, never a wall of diff.
fn report_map(name: &str, a: &BTreeMap<String, String>, b: &BTreeMap<String, String>) -> bool {
    if a == b {
        println!("  {name}: identical");
        return false;
    }
    let ka: BTreeSet<&String> = a.keys().collect();
    let kb: BTreeSet<&String> = b.keys().collect();
    let only_a: Vec<&&String> = ka.difference(&kb).collect();
    let only_b: Vec<&&String> = kb.difference(&ka).collect();
    let changed: Vec<&&String> = ka
        .intersection(&kb)
        .filter(|k| a.get(**k) != b.get(**k))
        .collect();
    println!(
        "  {name}: DIFFERS -- {} only in old, {} only in new, {} changed",
        only_a.len(),
        only_b.len(),
        changed.len()
    );
    for k in only_a.iter().take(3) {
        println!("    - {k}");
    }
    for k in only_b.iter().take(3) {
        println!("    + {k}");
    }
    for k in changed.iter().take(3) {
        println!("    ~ {k}");
        println!("        old: {}", head(a.get(**k).map(|s| s.as_str()).unwrap_or(""), 160));
        println!("        new: {}", head(b.get(**k).map(|s| s.as_str()).unwrap_or(""), 160));
    }
    true
}

/// The same report over maps whose values are JSON, rendered the way python's str() would.
fn report_json(name: &str, a: &BTreeMap<String, Value>, b: &BTreeMap<String, Value>) -> bool {
    let sa: BTreeMap<String, String> = a.iter().map(|(k, v)| (k.clone(), py_str(v))).collect();
    let sb: BTreeMap<String, String> = b.iter().map(|(k, v)| (k.clone(), py_str(v))).collect();
    // Equality is decided on the VALUES, not on their rendering, so a formatting difference
    // could never be reported as a graph difference.
    if a == b {
        println!("  {name}: identical");
        return false;
    }
    let differed = report_map_quiet(name, a, b, &sa, &sb);
    differed
}

fn report_map_quiet(
    name: &str,
    a: &BTreeMap<String, Value>,
    b: &BTreeMap<String, Value>,
    sa: &BTreeMap<String, String>,
    sb: &BTreeMap<String, String>,
) -> bool {
    let ka: BTreeSet<&String> = a.keys().collect();
    let kb: BTreeSet<&String> = b.keys().collect();
    let only_a: Vec<&&String> = ka.difference(&kb).collect();
    let only_b: Vec<&&String> = kb.difference(&ka).collect();
    let changed: Vec<&&String> = ka
        .intersection(&kb)
        .filter(|k| a.get(**k) != b.get(**k))
        .collect();
    println!(
        "  {name}: DIFFERS -- {} only in old, {} only in new, {} changed",
        only_a.len(),
        only_b.len(),
        changed.len()
    );
    for k in only_a.iter().take(3) {
        println!("    - {k}");
    }
    for k in only_b.iter().take(3) {
        println!("    + {k}");
    }
    for k in changed.iter().take(3) {
        println!("    ~ {k}");
        println!("        old: {}", head(sa.get(**k).map(|s| s.as_str()).unwrap_or(""), 160));
        println!("        new: {}", head(sb.get(**k).map(|s| s.as_str()).unwrap_or(""), 160));
    }
    true
}

/// A top-level graph key: present in both, absent from both, or one of each. python compares
/// them as dicts when both are dicts and falls back to str() otherwise, and the fallback is
/// what prints when a key exists on one side only.
fn report_key(name: &str, a: Option<&Value>, b: Option<&Value>) -> bool {
    match (a, b) {
        (None, None) => {
            println!("  {name}: absent from both");
            false
        }
        (Some(x), Some(y)) if x == y => {
            println!("  {name}: identical");
            false
        }
        (Some(Value::Object(x)), Some(Value::Object(y))) => {
            let ma: BTreeMap<String, Value> = x.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
            let mb: BTreeMap<String, Value> = y.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
            report_json(name, &ma, &mb)
        }
        (x, y) => {
            let sx = x.map(py_str).unwrap_or_else(|| "<absent>".into());
            let sy = y.map(py_str).unwrap_or_else(|| "<absent>".into());
            println!("  {name}: DIFFERS -- {} vs {}", head(&sx, 200), head(&sy, 200));
            true
        }
    }
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().collect();
    if argv.len() != 5 {
        eprintln!("usage: cider-graph-equiv <old-graph> <old-data> <new-graph> <new-data>");
        return ExitCode::from(2);
    }
    let (og, od, ng, nd) = (&argv[1], &argv[2], &argv[3], &argv[4]);
    let a = match load(og) {
        Ok(v) => v,
        Err(e) => return die(e),
    };
    let b = match load(ng) {
        Ok(v) => v,
        Err(e) => return die(e),
    };

    let mut bad = false;
    println!("graph equivalence:");

    bad |= report_json("actions", &by_identity(&a), &by_identity(&b));

    for key in [
        "kinds",
        "producers",
        "targetOutputs",
        "staged",
        "stagedTreeDeps",
        "coarsePinOf",
        "placeholders",
        "targets",
    ] {
        bad |= report_key(key, a.get(key), b.get(key));
    }

    let la = match links_of(&a, od) {
        Ok(v) => v,
        Err(e) => return die(e),
    };
    let lb = match links_of(&b, nd) {
        Ok(v) => v,
        Err(e) => return die(e),
    };
    let sa: BTreeMap<String, Value> = la
        .into_iter()
        .map(|(k, v)| {
            let mut m = Map::new();
            for (n, t) in v {
                m.insert(n, Value::String(t));
            }
            (k, Value::Object(m))
        })
        .collect();
    let sb: BTreeMap<String, Value> = lb
        .into_iter()
        .map(|(k, v)| {
            let mut m = Map::new();
            for (n, t) in v {
                m.insert(n, Value::String(t));
            }
            (k, Value::Object(m))
        })
        .collect();
    bad |= report_json("staged farm links", &sa, &sb);

    bad |= report_map("staged artifact contents", &staged_hashes(od), &staged_hashes(nd));

    println!("VERDICT: {}", if bad { "DIFFERENT" } else { "the same graph" });
    if bad {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
}
