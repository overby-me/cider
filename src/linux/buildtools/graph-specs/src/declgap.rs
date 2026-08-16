//! HOW MUCH OF THE PER-TARGET SOURCE SET DOES buck2 ACTUALLY DECLARE?
//!
//! The pass builds a target set from four rules. Two of them are buck2 SPEAKING:
//!
//!   argv       project-relative tokens in the target own actions: the .c and .defs files, the
//!              scripts a codegen edge runs, the .exp symbol lists a link reads.
//!   trees      the link TARGETS of every staged tree it consumes, which is where the header
//!              cones live. buck2 does state these, via BXL rather than aquery.
//!
//! The other two are the pass COMPENSATING, and they are the gap:
//!
//!   roots      any project directory used as an include root, taken WHOLESALE, because a
//!              compile can read anything under one and no per-file set could know what.
//!   quoted     an include in double quotes resolved against the INCLUDING FILE own directory,
//!              to a fixpoint. buck2 never records this; the C preprocessor rule is not in the
//!              build definition at all.
//!
//! This measures the last two against the current graph rather than trusting the numbers in the
//! generator comments, which were measured on an older one.
//!
//! IT VERIFIES ITS OWN PARTITION. The four parts are recomputed here rather than instrumented
//! into the generator, so they could drift from what the generator really does and the answer
//! would look precise and be wrong. Every target argv|trees|roots|quoted is compared against
//! the generator own output for that target, and any mismatch is a hard failure.
//!
//! Usage:
//!   cider-declaration-gap <graph.json> <graph-data-dir>    (cwd = project root)
//!
//! THE RUST REWRITE of the python buck-declaration-gap (#98). The python imported the generator
//! module to get both the helpers and the truth; this calls the SAME code, src/srcset.rs, for
//! the same reason: a second implementation of the rule would be a second thing to keep in
//! step, and catching that drift is the entire point of the check.
//!
//! TWO THINGS WERE TRUE OF THE PYTHON WHEN THIS WAS PORTED, and both are findings rather than
//! porting notes:
//!
//!   IT COULD NOT RUN AT ALL. It called target_sources with four arguments after the generator
//!   grew a fifth, `data`, so every invocation died with a TypeError. Repairing that one call
//!   was what made a baseline possible.
//!
//!   AND ONCE REPAIRED IT FAILS, correctly: 11 targets do not match the generator, three of
//!   them printed, and the largest is root//vendor/rust:libc missing 386 files. The partition
//!   this file recomputes no longer describes the real pass. That is the check working, and it
//!   is reported rather than fixed, because deciding which side is wrong is a separate job.
//!
//! GATED against the python on the real graph: same counts, same three mismatch lines with the
//! same numbers, same FAIL line, same exit code. The ONE difference is that the python
//! generator prints six SUBPHASE timing lines from inside its own target_sources; those are
//! wall-clock values that could never be byte identical, and they belong to the generator
//! rather than to this check.

// SHARED: the farm table reader and the source set computation, so this checks the generator
// rather than a copy of it.
#[path = "trees.rs"]
mod trees;
#[path = "srcset.rs"]
mod srcset;
use srcset::{dirname, include_roots, normpath, project_candidates, strs, Fs};

use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::process::ExitCode;

fn die(msg: String) -> ExitCode {
    eprintln!("{msg}");
    ExitCode::from(2)
}

/// Every file under a directory, cached: an include root is taken WHOLESALE, so the question
/// asked of it is "what is in there", once per root rather than once per target.
struct Under {
    cache: HashMap<String, BTreeSet<String>>,
}

impl Under {
    fn new() -> Self {
        Under { cache: HashMap::new() }
    }
    fn of(&mut self, d: &str) -> &BTreeSet<String> {
        if !self.cache.contains_key(d) {
            let mut found = BTreeSet::new();
            let mut stack = vec![d.to_string()];
            while let Some(dir) = stack.pop() {
                if let Ok(rd) = fs::read_dir(&dir) {
                    for ent in rd.flatten() {
                        let p = ent.path().to_string_lossy().into_owned();
                        match fs::symlink_metadata(&p) {
                            Ok(m) if m.is_dir() => stack.push(p),
                            Ok(_) => {
                                found.insert(p);
                            }
                            Err(_) => {}
                        }
                    }
                }
            }
            self.cache.insert(d.to_string(), found);
        }
        &self.cache[d]
    }
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.len() != 2 {
        eprintln!("  cider-declaration-gap <graph.json> <graph-data-dir>    (cwd = project root)");
        return ExitCode::from(2);
    }
    let (graph_path, data) = (&argv[0], &argv[1]);
    let raw = match fs::read_to_string(graph_path) {
        Ok(t) => t,
        Err(e) => return die(format!("cannot read {graph_path}: {e}")),
    };
    let graph: Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => return die(format!("cannot parse {graph_path}: {e}")),
    };
    let trees_vec = match trees::read_trees(&graph, data) {
        Ok(v) => v,
        Err(e) => return die(e),
    };

    let empty = Map::new();
    let actions = graph.get("actions").and_then(|v| v.as_array()).cloned().unwrap_or_default();
    let staged = graph.get("staged").and_then(|v| v.as_object()).unwrap_or(&empty);
    let producers = graph.get("producers").and_then(|v| v.as_object()).unwrap_or(&empty);
    eprintln!("{} actions, {} staged trees", actions.len(), trees_vec.len());

    // The generator own answer, which this partition has to reproduce exactly.
    let truth = srcset::target_sources(&graph, &trees_vec, data);
    eprintln!("{} targets in the closure", truth.len());

    let mut known: HashSet<String> = producers.keys().cloned().collect();
    known.extend(staged.keys().cloned());
    known.extend(trees_vec.iter().map(|(p, _)| p.clone()));
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

    // The destinations each staged farm links point at, minus the ones that are build outputs.
    let mut tree_srcs: HashMap<String, BTreeSet<String>> = HashMap::new();
    for (path, links) in &trees_vec {
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

    // FIRST APPEARANCE ORDER, which is python's dict insertion order: it decides which three
    // mismatches get printed, and nothing else.
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
    let mut under = Under::new();
    let mut root_dirs: Vec<(String, usize)> = Vec::new();   // include root -> targets, first seen order
    let mut root_files: BTreeSet<String> = BTreeSet::new();
    let mut quoted_edges: BTreeSet<(String, String)> = BTreeSet::new();
    let mut quoted_files: BTreeSet<String> = BTreeSet::new();
    let mut targets_with_roots = 0usize;
    let mut targets_with_quoted = 0usize;
    let mut union: BTreeSet<String> = BTreeSet::new();
    let mut mismatches = 0usize;

    for label in &order {
        let acts = &by_target[label];
        let mut argv_srcs: BTreeSet<String> = BTreeSet::new();
        let mut roots_here: BTreeSet<String> = BTreeSet::new();
        for &i in acts {
            for tok in strs(&actions[i], "argv") {
                for cand in project_candidates(&tok) {
                    if fsc.lexists(&cand) {
                        argv_srcs.insert(cand);
                        break;
                    }
                }
            }
            for d in include_roots(&strs(&actions[i], "argv")) {
                if !d.starts_with('/') && !d.starts_with('@') && !d.starts_with("buck-out/")
                    && fs::metadata(&d).map(|m| m.is_dir()).unwrap_or(false)
                {
                    roots_here.insert(d);
                }
            }
        }

        let mut tree_side: BTreeSet<String> = BTreeSet::new();
        let mut owners: BTreeSet<String> = BTreeSet::new();
        for &i in acts {
            for inp in strs(&actions[i], "inputs") {
                if let Some(o) = owner_of(&inp) {
                    owners.insert(o);
                }
            }
        }
        for o in &owners {
            if let Some(set) = tree_srcs.get(o) {
                for d in set {
                    tree_side.insert(d.clone());
                }
                for dest in set.clone() {
                    if let Some(sub) = owner_of(&dest) {
                        if let Some(s2) = tree_srcs.get(&sub) {
                            for d in s2 {
                                tree_side.insert(d.clone());
                            }
                        }
                    }
                }
            }
        }

        let declared: BTreeSet<String> = argv_srcs.union(&tree_side).cloned().collect();
        let mut roots: BTreeSet<String> = BTreeSet::new();
        for d in &roots_here {
            for f in under.of(d) {
                roots.insert(f.clone());
            }
        }
        roots = roots.difference(&declared).cloned().collect();

        // The fixpoint runs over declared|roots, exactly as the generator runs it over srcs.
        let srcs: BTreeSet<String> = declared.union(&roots).cloned().collect();
        let mut quoted: BTreeSet<String> = BTreeSet::new();
        let mut pending: Vec<String> = srcs.iter().cloned().collect();
        while !pending.is_empty() {
            let mut nxt: Vec<String> = Vec::new();
            for f in &pending {
                for r in fsc.quoted_includes(f) {
                    if !srcs.contains(&r) && !quoted.contains(&r) {
                        quoted.insert(r.clone());
                        quoted_edges.insert((f.clone(), r.clone()));
                        nxt.push(r);
                    }
                }
            }
            pending = nxt;
        }

        // THE CHECK THAT CAN FAIL: this partition must be the generator set, exactly.
        let mine: BTreeSet<String> = srcs.union(&quoted).cloned().collect();
        let theirs: BTreeSet<String> = truth.get(label).cloned().unwrap_or_default().into_iter().collect();
        if mine != theirs {
            mismatches += 1;
            if mismatches <= 3 {
                eprintln!(
                    "MISMATCH {label}: +{} -{}",
                    mine.difference(&theirs).count(),
                    theirs.difference(&mine).count()
                );
            }
        }

        for f in &mine {
            union.insert(f.clone());
        }
        if !roots.is_empty() {
            targets_with_roots += 1;
            for d in &roots_here {
                match root_dirs.iter_mut().find(|(k, _)| k == d) {
                    Some((_, n)) => *n += 1,
                    None => root_dirs.push((d.clone(), 1)),
                }
            }
            for f in &roots {
                root_files.insert(f.clone());
            }
        }
        if !quoted.is_empty() {
            targets_with_quoted += 1;
            for f in &quoted {
                quoted_files.insert(f.clone());
            }
        }
    }

    if mismatches > 0 {
        eprintln!(
            "\nFAIL: {mismatches} target(s) do not match the generator. The partition below does not describe the real pass, so none of it can be trusted."
        );
        return ExitCode::from(1);
    }

    println!();
    println!("partition verified against the generator on all {} targets", truth.len());
    println!();
    println!("union of everything the closure reaches: {} files", union.len());
    println!();
    println!("THE GAP, what buck2 did not declare:");
    println!(
        "  wholesale include roots : {} director(ies), {} file(s) reached only that way, used by {} of {} targets",
        root_dirs.len(),
        root_files.len(),
        targets_with_roots,
        truth.len()
    );
    // STABLE sort by count descending, so equal counts keep first-seen order, which is what
    // python's sorted() does over a dict.
    let mut ranked = root_dirs.clone();
    ranked.sort_by(|a, b| b.1.cmp(&a.1));
    let counts: Vec<(String, usize, usize)> =
        ranked.iter().map(|(d, n)| (d.clone(), under.of(d).len(), *n)).collect();
    for (d, files, n) in counts {
        println!("      {d}  ({files} files, {n} target(s))");
    }
    println!(
        "  quoted includes         : {} file(s) over {} edge(s), reached by {} target(s)",
        quoted_files.len(),
        quoted_edges.len(),
        targets_with_quoted
    );
    for (src, dst) in &quoted_edges {
        println!("      {src}\n        -> {dst}");
    }
    let gap: BTreeSet<String> = root_files.union(&quoted_files).cloned().collect();
    println!();
    println!(
        "  total undeclared: {} of {} files ({:.3} percent)",
        gap.len(),
        union.len(),
        100.0 * gap.len() as f64 / std::cmp::max(1, union.len()) as f64
    );
    ExitCode::SUCCESS
}
