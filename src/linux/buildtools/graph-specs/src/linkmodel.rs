//! MAKE EVERY darwin_dylib LINK MODEL MATCH THE REFERENCE: order, and upward deps.
//!
//! THE RUST REWRITE of the python buck-fix-link-model (#98). It is Rust because it reads the
//! 131 MB frozen build.ninja through src/ninjaref.rs and then joins it against every declared
//! dylib in the tree, which is the hash-join shape this port measured nushell out of.
//!
//! ld64 records LC_LOAD_DYLIB in the order the libraries appear on the command line, and dyld
//! initializes depth-first through that order. So the order is not cosmetic: it decides which
//! image initializer runs FIRST, and dyld aborts the process if that image is not libSystem.
//!
//! The port had libsystem_trace naming libplatform before libobjc where the reference names
//! libobjc first, because the generator followed the ninja edge input order rather than
//! LINK_LIBRARIES. That was enough to send dyld into libc++ ahead of libSystem, and the guest
//! died at every boot.
//!
//! It rewrites two properties of existing blocks and nothing else:
//!   ORDER, see above;
//!   UPWARD dependencies, which dyld links but does not descend into, and which are the only
//!     reason libSystem own initializer can run first.
//! Regenerating the blocks would be the obvious alternative and is not safe here: the generator
//! cannot yet reproduce some of what the committed blocks carry.
//!
//! Usage:
//!   cider-fix-link-model [--check]

#[path = "ninjaref.rs"]
mod ninjaref;
use ninjaref::{basename, final_registry, firstpass_registry, firstpass_stem, read_edges, repo_root,
               upwards_of, walk_buck_files, Edge};

use std::collections::{HashMap, HashSet};
use std::fs;
use std::process::ExitCode;

/// {dylib name: {sibling label: position}} from the reference LINK_LIBRARIES.
fn link_order(
    edges: &[Edge],
    reg: &HashMap<String, String>,
    final_reg: &HashMap<String, String>,
) -> HashMap<String, HashMap<String, usize>> {
    let mut out: HashMap<String, HashMap<String, usize>> = HashMap::new();
    for e in edges {
        let libs = match e.vars.get("LINK_LIBRARIES") {
            Some(l) if !l.is_empty() => l,
            _ => continue,
        };
        let produced = match e.outputs.first() {
            Some(o) => basename(o).to_string(),
            None => continue,
        };
        let mut ranks: HashMap<String, usize> = HashMap::new();
        for (n, tok) in libs.split_whitespace().enumerate() {
            let base = basename(tok);
            if !base.ends_with(".dylib") {
                continue;
            }
            let label = match firstpass_stem(base) {
                Some(stem) => reg.get(stem),
                None => final_reg.get(base),
            };
            if let Some(l) = label {
                ranks.entry(l.clone()).or_insert(n);
            }
        }
        if !ranks.is_empty() {
            // setdefault: the FIRST edge that produces this artifact decides the order.
            out.entry(produced).or_insert(ranks);
        }
    }
    out
}

/// {dylib name: {label}} from the reference -Wl,-upward_library flags.
fn upward_sets(
    edges: &[Edge],
    reg: &HashMap<String, String>,
    final_reg: &HashMap<String, String>,
) -> HashMap<String, HashSet<String>> {
    let mut out: HashMap<String, HashSet<String>> = HashMap::new();
    for e in edges {
        let (labels, _missing) = upwards_of(&e.vars, reg, final_reg);
        if labels.is_empty() {
            continue;
        }
        let produced = match e.outputs.first() {
            Some(o) => basename(o).to_string(),
            None => continue,
        };
        out.entry(produced).or_default().extend(labels);
    }
    out
}

/// darwin_dylib\(\n(?:.*?\n)*?\)\n : from the opening line to the first line that is just ")".
fn blocks(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0;
    while let Some(at) = text[i..].find("darwin_dylib(\n") {
        let start = i + at;
        let mut j = start + "darwin_dylib(\n".len();
        let mut end = None;
        while j <= text.len() {
            let line_end = match text[j..].find('\n') {
                Some(k) => j + k,
                None => break,
            };
            if &text[j..line_end] == ")" {
                end = Some(line_end + 1);
                break;
            }
            j = line_end + 1;
        }
        match end {
            Some(e) => {
                out.push(text[start..e].to_string());
                i = e;
            }
            None => break,
        }
    }
    out
}

struct Siblings {
    whole: String,
    head: String,
    body: String,
    tail: String,
}

/// (    siblings = \[\n)((?:        "[^"]+",\n)+)(    \],\n)
fn siblings(block: &str) -> Option<Siblings> {
    let head = "    siblings = [\n";
    let mut from = 0;
    while let Some(at) = block[from..].find(head) {
        let start = from + at;
        let mut j = start + head.len();
        let body_start = j;
        loop {
            let line_end = match block[j..].find('\n') {
                Some(k) => j + k,
                None => break,
            };
            // One `        "<no quote inside>",` line, which is what "[^"]+" means here.
            let line = &block[j..line_end];
            let ok = line.starts_with("        \"")
                && line.ends_with("\",")
                && line.len() > 11
                && !line[9..line.len() - 2].contains('"');
            if !ok {
                break;
            }
            j = line_end + 1;
        }
        if j > body_start && block[j..].starts_with("    ],\n") {
            return Some(Siblings {
                whole: block[start..j + "    ],\n".len()].to_string(),
                head: head.to_string(),
                body: block[body_start..j].to_string(),
                tail: "    ],\n".to_string(),
            });
        }
        from = start + 1;
    }
    None
}

fn quoted_values(body: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0;
    while let Some(at) = body[i..].find('"') {
        let start = i + at + 1;
        match body[start..].find('"') {
            Some(k) => {
                let inner = &body[start..start + k];
                if !inner.is_empty() {
                    out.push(inner.to_string());
                }
                i = start + k + 1;
            }
            None => break,
        }
    }
    out
}

fn quoted_after(block: &str, key: &str) -> Option<String> {
    let at = block.find(key)?;
    let rest = &block[at + key.len()..];
    let start = rest.find('"')? + 1;
    let end = rest[start..].find('"')? + start;
    if end == start {
        return None;
    }
    Some(rest[start..end].to_string())
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let check = argv.iter().any(|a| a == "--check");
    let root = match repo_root() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let edges = match read_edges(&root) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let reg = firstpass_registry(&root);
    let final_reg = final_registry(&root);
    let orders = link_order(&edges, &reg, &final_reg);
    let upwards = upward_sets(&edges, &reg, &final_reg);

    let mut changed = 0usize;
    let mut stale: Vec<String> = Vec::new();
    let empty_ranks: HashMap<String, usize> = HashMap::new();
    let empty_up: HashSet<String> = HashSet::new();

    for (pkg, path) in walk_buck_files(&root) {
        let text = match fs::read_to_string(&path) {
            Ok(t) => t,
            Err(_) => continue,
        };
        let mut new_text = text.clone();
        for block in blocks(&text) {
            let dylib = match quoted_after(&block, "dylib_name = ") {
                Some(d) => d,
                None => continue,
            };
            let sibs = match siblings(&block) {
                Some(s) => s,
                None => continue,
            };
            let ranks = orders.get(&dylib);
            let up = upwards.get(&dylib).unwrap_or(&empty_up);
            if ranks.is_none() && up.is_empty() {
                continue;
            }
            let ranks = ranks.unwrap_or(&empty_ranks);
            let labels = quoted_values(&sibs.body);
            // Anything the reference does not name keeps its position at the end, in the order
            // it already had, so this only ever moves what the reference orders.
            let mut order: Vec<usize> = (0..labels.len()).collect();
            order.sort_by_key(|i| (*ranks.get(&labels[*i]).unwrap_or(&(1usize << 30)), *i));
            let kept: Vec<String> =
                order.iter().map(|i| labels[*i].clone()).filter(|l| !up.contains(l)).collect();
            let moved: Vec<String> =
                order.iter().map(|i| labels[*i].clone()).filter(|l| up.contains(l)).collect();
            if kept == labels && moved.is_empty() {
                continue;
            }
            let body: String = kept.iter().map(|l| format!("        \"{l}\",\n")).collect();
            let mut new_sibs = format!("{}{}{}", sibs.head, body, sibs.tail);
            if !moved.is_empty() {
                new_sibs.push_str("    upward = [\n");
                for l in &moved {
                    new_sibs.push_str(&format!("        \"{l}\",\n"));
                }
                new_sibs.push_str("    ],\n");
            }
            let new_block = block.replace(&sibs.whole, &new_sibs);
            new_text = new_text.replace(&block, &new_block);
            changed += 1;
        }
        if new_text != text {
            if check {
                let rel = if pkg == "." { "BUCK".to_string() } else { format!("{pkg}/BUCK") };
                stale.push(rel);
            } else if let Err(e) = fs::write(&path, &new_text) {
                eprintln!("cannot write {path}: {e}");
                return ExitCode::FAILURE;
            }
        }
    }

    if check {
        for s in &stale {
            println!("  STALE {s}");
        }
        println!("{} file(s) whose link model differs from the reference", stale.len());
        return if stale.is_empty() { ExitCode::SUCCESS } else { ExitCode::FAILURE };
    }
    println!("fixed the link model of {changed} dylib target(s)");
    ExitCode::SUCCESS
}
