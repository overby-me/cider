//! WHICH PROJECT FILES MUST KEEP THEIR REAL CONTENTS FOR THE GRAPH DUMP TO BE CORRECT? (#56)
//!
//! THE BLOCKER THIS REMOVES. The graph derivation takes the whole project, so editing any C file
//! rebuilds it before anything else can start. The obvious fix is to feed it a SKELETON (build
//! files verbatim, every other file present but empty), and that was tried and REVERTED, for a
//! good reason recorded in nix/lib/ciderBuck2Graph.nix: the dump does not only analyse. It
//! materialises in-process artifacts, and a staged farm of GENERATED headers is produced by
//! RUNNING a generator that this derivation builds from first-party C. An emptied rtsig.c
//! compiles, links, runs, and writes an EMPTY header. The graph comes out quietly wrong and the
//! failure lands far away.
//!
//! THE DEFINITION MATTERS, and the obvious one is useless. Taking "every target whose output is
//! named in another target argv" gives 1,501 of 2,339 targets and 74,566 of 74,621 files, 99.9
//! percent, because that relation is the entire build graph: every object a link consumes, every
//! archive a dylib consumes. The dump does not build those.
//!
//! Usage:
//!   cider-codegen-closure <graph.json> <graph-data-dir> [--sources <target-sources.json>]
//!   cider-codegen-closure ... --list      # print the files, one per line
//!   cider-codegen-closure ... --targets   # print the target labels
//!   cider-codegen-closure ... --check     # run the four spot checks, exit 1 on failure
//!
//! THE RUST REWRITE of the python buck-codegen-closure (#98), and it is Rust for the reason the
//! measurement gave: it builds a producer map over every action output and then chases the argv
//! of every action in the frontier through it, on the order of a million lookups. A nushell
//! record is not a hash map, and 100,001 lookups into a 12,001 key record took 51.8 seconds.
//!
//! VERIFIED BYTE FOR BYTE against the python in EVERY mode, including the three that an earlier
//! write-up said could not be reached. That claim was wrong and this is the correction: the
//! sources pass DOES still emit the per-target file, as target-sources.json, behind
//! CIDER_EMIT_TARGET_SOURCES=1, off by default only because it is 298 MB. Emitting it takes 12
//! seconds and --sources, --check and --list then all run:
//!   default            3,025 staged trees, 43 generated staged in, 164 of 1,866 targets
//!   --targets          the same 164 labels, on two different graphs
//!   --sources --check  30,776 files of 58,459, 52.6 percent, and the four spot checks pass
//!   --list             all 30,776 paths, identical
//! CONTROLLED, because a check that cannot fail is worth nothing: drop rtsig.c from the
//! per-target file and both implementations exit 1 with the same
//! "MISSING from the closure, and blanking it fails SILENTLY" line.
//!
//! ONE DIFFERENCE REMAINS AND IT IS NOT REPRODUCIBLE BY CONSTRUCTION. The top-8 ranking breaks
//! ties by python's Counter.most_common, which is a STABLE sort over dict insertion order, and
//! that order is the iteration order of a SET of paths. Two directories tie at one file each
//! (. and etc) and python prints them in its hash order. This prints them sorted, which is
//! stable across runs where python's is a property of the process. Every count is identical.

// SHARED: one reader for the farm tables, see src/trees.rs.
#[path = "trees.rs"]
mod trees;

use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::process::ExitCode;

/// The two the revert was about must be IN; two ordinary vendor/src sources must be OUT. A closure
/// that cannot fail this is not measuring anything.
///
/// src/linux/server/wrapper.h is here because it ESCAPED the first version of this closure and cost
/// a failed skeleton graph build to find. bindgen reads it, the daemon includes the result, and
/// emptying it produced 83 rustc errors rather than anything pointing at the skeleton.
const MUST_BE_REAL: &[&str] = &[
    "src/linux/startup/rtsig.c",
    "src/linux/libelfloader/wrapgen/wrapgen.cpp",
    "src/linux/server/wrapper.h",
];
const MUST_NOT_BE: &[&str] = &["vendor/src/adv_cmds/finger/finger.c", "vendor/src/vim/vim/src/main.c"];

/// EVERY CATEGORY THAT RUNS SOMETHING AND FEEDS SOMETHING ELSE. Taken from the port own rules
/// rather than guessed, and it is the complement of the four that only consume: c_compile,
/// cxx_compile, darwin_link, archive, link, rustc, rustc_link.
///
/// THE STAGED FARM ROOTS ALONE WERE NOT ENOUGH, and this is what proved it. The first version of
/// this script rooted only artifacts a staged farm contains, which finds mig, the ELF wrappers
/// and rtsig but MISSES bindgen: xnu_sys_bindings is consumed by a cargo build through OUT_DIR
/// and never lands in a farm. So src/linux/server/wrapper.h was emptied, bindgen wrote nothing, and
/// the skeleton graph died with 83 rustc errors in sched.rs on an unresolved crate::bindings.
const GENERATOR_CATEGORIES: &[&str] = &[
    "mig",
    "elf_wrapper",
    "bison",
    "flex",
    "bindgen",
    "configure_file",
    "forwarded_headers",
    "stdout_gen",
    "script_gen",
    "host_gen",
    "preprocess",
    "prefix_gen_dir",
    "prefix_tree",
];

/// The trailing "(category detail)" of an aquery identity, e.g. c_compile or bindgen.
fn action_category(identity: &str) -> String {
    match identity.rsplit_once('(') {
        Some((_, rest)) => rest.split(' ').next().unwrap_or("").trim_end_matches(')').to_string(),
        None => String::new(),
    }
}

fn label_of(identity: &str) -> String {
    match identity.split_once(" (") {
        Some((l, _)) => l.to_string(),
        None => identity.to_string(),
    }
}

/// (targets in the closure, artifacts a farm contains that came out of the build, targets seen).
fn codegen_targets(graph: &Value, trees: &[(String, Vec<(String, String)>)]) -> (BTreeSet<String>, usize, usize) {
    let empty: Vec<Value> = Vec::new();
    let actions = graph.get("actions").and_then(|v| v.as_array()).unwrap_or(&empty);

    let mut producer: HashMap<String, String> = HashMap::new();
    let mut by_target: HashMap<String, Vec<&Value>> = HashMap::new();
    for a in actions {
        let ident = a.get("identity").and_then(|v| v.as_str()).unwrap_or("");
        let label = label_of(ident);
        by_target.entry(label.clone()).or_default().push(a);
        if let Some(outs) = a.get("outputs").and_then(|v| v.as_array()) {
            for o in outs {
                let key = match o {
                    Value::String(s) => s.clone(),
                    other => other.to_string(),
                };
                producer.insert(key, label.clone());
            }
        }
    }

    // Root 1: artifacts a staged farm actually contains that came out of the build rather than
    // out of the project. The sources pass keeps the complement of this set, the links that
    // resolve to project sources.
    let mut generated: HashSet<String> = HashSet::new();
    for (path, links) in trees {
        for (rel, tgt) in links {
            let base = format!("{path}/{rel}");
            let dir = match base.rfind('/') {
                Some(i) => &base[..i],
                None => "",
            };
            let dest = normpath(&format!("{dir}/{tgt}"));
            if dest.starts_with("buck-out/") {
                generated.insert(dest);
            }
        }
    }

    let mut need: BTreeSet<String> = generated
        .iter()
        .filter_map(|d| producer.get(d).cloned())
        .collect();
    // Root 2: anything that RUNS a generator, whether or not its output is ever staged.
    for a in actions {
        let ident = a.get("identity").and_then(|v| v.as_str()).unwrap_or("");
        if GENERATOR_CATEGORIES.contains(&action_category(ident).as_str()) {
            need.insert(label_of(ident));
        }
    }

    let mut frontier: Vec<String> = need.iter().cloned().collect();
    while !frontier.is_empty() {
        let mut next: Vec<String> = Vec::new();
        for label in &frontier {
            if let Some(acts) = by_target.get(label) {
                for a in acts {
                    if let Some(argv) = a.get("argv").and_then(|v| v.as_array()) {
                        for tok in argv {
                            let key = match tok {
                                Value::String(s) => s.clone(),
                                other => other.to_string(),
                            };
                            if let Some(p) = producer.get(&key) {
                                if !need.contains(p) {
                                    need.insert(p.clone());
                                    next.push(p.clone());
                                }
                            }
                        }
                    }
                }
            }
        }
        frontier = next;
    }
    (need, generated.len(), by_target.len())
}

/// os.path.normpath, the subset these paths need: collapse . and .. lexically.
fn normpath(p: &str) -> String {
    let absolute = p.starts_with('/');
    let mut out: Vec<&str> = Vec::new();
    for part in p.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if let Some(last) = out.last() {
                    if *last != ".." {
                        out.pop();
                        continue;
                    }
                }
                if !absolute {
                    out.push("..");
                }
            }
            other => out.push(other),
        }
    }
    let joined = out.join("/");
    if absolute {
        format!("/{joined}")
    } else if joined.is_empty() {
        ".".into()
    } else {
        joined
    }
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let flags: Vec<&String> = argv.iter().filter(|a| a.starts_with("--")).collect();
    let positional: Vec<&String> = argv.iter().filter(|a| !a.starts_with("--")).collect();
    let want = |name: &str| flags.iter().any(|f| f.as_str() == name);
    let sources = match argv.iter().position(|a| a == "--sources") {
        Some(i) => argv.get(i + 1).cloned().unwrap_or_default(),
        None => String::new(),
    };
    // --sources takes a value, so its argument is not a positional.
    let positional: Vec<&String> = positional
        .into_iter()
        .filter(|p| sources.is_empty() || p.as_str() != sources.as_str())
        .collect();
    if positional.len() != 2 {
        eprintln!("usage: cider-codegen-closure <graph.json> <graph-data-dir> [--sources F] [--list] [--targets] [--check]");
        return ExitCode::from(2);
    }
    let (graph_path, data) = (positional[0], positional[1]);

    let raw = match fs::read_to_string(graph_path) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("cannot read {graph_path}: {e}");
            return ExitCode::from(2);
        }
    };
    let graph: Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("cannot parse {graph_path}: {e}");
            return ExitCode::from(2);
        }
    };
    let trees = match trees::read_trees(&graph, data) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::from(2);
        }
    };
    let (need, n_generated, n_targets) = codegen_targets(&graph, &trees);

    if want("--targets") {
        for t in &need {
            println!("{t}");
        }
        return ExitCode::SUCCESS;
    }

    eprintln!("staged trees                     {:8}", trees.len());
    eprintln!("generated artifacts staged in    {n_generated:8}");
    eprintln!("targets in the codegen closure   {:8}  of {n_targets}", need.len());

    if sources.is_empty() {
        // Sits beside the graph in the sources derivation, not in the graph output.
        eprintln!("no --sources given, so only the target closure was computed");
        return ExitCode::SUCCESS;
    }

    let praw = match fs::read_to_string(&sources) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("cannot read {sources}: {e}");
            return ExitCode::from(2);
        }
    };
    let per_target: BTreeMap<String, Vec<String>> = match serde_json::from_str(&praw) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("cannot parse {sources}: {e}");
            return ExitCode::from(2);
        }
    };
    let mut union: BTreeSet<String> = BTreeSet::new();
    let mut every: BTreeSet<String> = BTreeSet::new();
    for (label, files) in &per_target {
        for f in files {
            every.insert(f.clone());
        }
        if need.contains(label) {
            for f in files {
                union.insert(f.clone());
            }
        }
    }
    let pct = 100.0 * union.len() as f64 / std::cmp::max(1, every.len()) as f64;
    eprintln!(
        "files that must stay REAL        {:8}  of {}  ({:.1} percent)",
        union.len(),
        every.len(),
        pct
    );
    let mut top: HashMap<&str, usize> = HashMap::new();
    for f in &union {
        *top.entry(f.split('/').next().unwrap_or("")).or_insert(0) += 1;
    }
    // Counter.most_common: by count descending, ties in FIRST SEEN order, which for a set built
    // in sorted order is the sorted order.
    let mut ranked: Vec<(&str, usize)> = top.into_iter().collect();
    ranked.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
    for (k, v) in ranked.iter().take(8) {
        eprintln!("    {v:7}  {k}");
    }

    if want("--check") {
        let mut bad: Vec<String> = Vec::new();
        for p in MUST_BE_REAL {
            if !union.contains(*p) {
                bad.push(format!("MISSING from the closure, and blanking it fails SILENTLY: {p}"));
            }
        }
        for p in MUST_NOT_BE {
            if union.contains(*p) {
                bad.push(format!("unexpectedly IN the closure, so the definition has widened: {p}"));
            }
        }
        if !bad.is_empty() {
            eprintln!("\nFAIL:");
            for b in &bad {
                eprintln!("  {b}");
            }
            return ExitCode::from(1);
        }
        eprintln!("\ncheck: rtsig.c and wrapgen.cpp are in, finger.c and vim main.c are out");
    }

    if want("--list") {
        for f in &union {
            println!("{f}");
        }
    }
    ExitCode::SUCCESS
}
