//! RANK A PREFIX INSTALL ENTRIES BY THE BUILD COST ONLY THEY PULL IN.
//!
//! THE RUST REWRITE of the python buck-prefix-cost (#98). It is Rust rather than nushell for the
//! reason this port has measured twice: the work is a REACHABILITY CLOSURE over the action
//! graph, held as bitmasks, and then a join between those masks and a per-target action count.
//! A nushell record is not a hash map, and 900 roots times a few thousand targets is exactly the
//! shape that took 51.8 seconds for 100,001 lookups when it was tried.
//!
//! The minimal prefix is defined by SUBTRACTION: gen-prefix-min.nu takes the full prefix and
//! removes what is on an exclusion list, so anything expensive is included BY DEFAULT and has to
//! be noticed one entry at a time. That is how //buck-src:jsc survived, one line pulling 1,082
//! compiles of JavaScriptCore into a prefix whose stated job is to boot, run bash and run nix.
//!
//! TWO THINGS THIS MEASURES CAREFULLY, because the obvious versions of both are useless:
//!
//! COST IS ACTIONS, NOT TARGETS. jsc is 14 targets and 1,082 compiles: the target that does the
//! work, JavaScriptCore_obj, is ONE target holding 1,082 actions. A ranking by target count puts
//! jsc near the bottom and tells you nothing.
//!
//! COST IS EXCLUSIVE, NOT TOTAL. Nearly every entry reaches libc, libsystem and dyld, so ranking
//! by total reachable cost puts everything within a few percent of everything else. What made
//! jsc stand out is that its cone is reachable from NO OTHER entry, so deleting the one line
//! removes all of it. Entries sharing a cone are reported with cost 0 here, correctly.
//!
//! WHICH GRAPH IS NOT OPTIONAL, and that is the one piece of behaviour worth reading before
//! changing anything: --graph is required. Picking the newest dump out of the store was not a
//! choice at all, since nix pins every store path mtime to the epoch and all four graph
//! attributes build a derivation with the SAME NAME. It drew a 5,709 action demo, resolved 128
//! of 899 prefix labels, and still printed a ranking that looked entirely reasonable.
//!
//! THE EIGHTH BINARY of this crate rather than a crate of its own: it reads the same graph.json
//! and follows the same two conventions as the others, that an action identity is
//! <label> (<cfg>) (<action>) and that input_targets is the target level edge set. A crate of
//! its own would mean a second Cargo.lock and a second nix package for one file.
//!
//! THE REPO ROOT cannot come from the executable the way the python took it from __file__, so it
//! is $CIDER_REPO, else the working directory, checked rather than assumed.
//!
//! Usage:
//!   cider-prefix-cost --graph <path>           # required; a dir or a graph.json
//!   cider-prefix-cost                          # lists the candidates and exits
//!   cider-prefix-cost --graph <path> --prefix buck/prefix/BUCK --top 40

use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::process::ExitCode;

/// Minimum share of a prefix labels a graph must resolve before its numbers mean anything.
/// MEASURED, not picked round. Against a correct min graph the current prefix resolves 601 of
/// 899 labels, 67 percent. The 298 it does not are all ACTION-LESS targets, plists, bashrc,
/// profile, newsyslog.conf, installed by an export_file rule that never runs a build action.
/// The wrong graph that motivated this guard resolved 128 of 899, 14 percent.
const MIN_COVERAGE: f64 = 0.50;

/// Entries allowed to be expensive, because they ARE the goal.
const EXEMPT: &[&str] = &[
    "root//buck-src/dyld:dyld",
    "root//buck-src:bash",
    "root//linux/server:ciderd",
];

/// --check fails when a non-exempt entry exclusively pulls in more than this many actions.
/// Taken from the measured distribution: the three costliest entries are exactly the three
/// EXEMPT ones (dyld 644, bash 182, ciderd 136) and the worst non-exempt is iokitd at 32.
const DEFAULT_BUDGET: i64 = 60;

// ---------------------------------------------------------------- the two line patterns
//
// HAND ROLLED RATHER THAN A REGEX CRATE, and deliberately: this crate depends on serde_json and
// nothing else, and adding a dependency to match two fixed shapes would mean a second thing to
// vendor for the nix build. Both reproduce the python patterns exactly, including leftmost
// search semantics.

/// The right hand side of an install entry: "dest": "//pkg:name", python r'"\s*:\s*"(//[^"]+)"'.
fn label_in(line: &str) -> Option<&str> {
    let b = line.as_bytes();
    for start in 0..b.len() {
        if b[start] != b'"' {
            continue;
        }
        let mut i = start + 1;
        while i < b.len() && (b[i] as char).is_whitespace() {
            i += 1;
        }
        if i >= b.len() || b[i] != b':' {
            continue;
        }
        i += 1;
        while i < b.len() && (b[i] as char).is_whitespace() {
            i += 1;
        }
        if i >= b.len() || b[i] != b'"' {
            continue;
        }
        let open = i + 1;
        if !line[open..].starts_with("//") {
            continue;
        }
        match line[open..].find('"') {
            // [^"]+ wants at least one character, and "//" already supplies two.
            Some(rel) if rel > 0 => return Some(&line[open..open + rel]),
            _ => continue,
        }
    }
    None
}

/// The destination it installs at, python r'^\s*"([^"]+)"\s*:', anchored.
fn dest_in(line: &str) -> Option<&str> {
    let b = line.as_bytes();
    let mut i = 0;
    while i < b.len() && (b[i] as char).is_whitespace() {
        i += 1;
    }
    if i >= b.len() || b[i] != b'"' {
        return None;
    }
    let open = i + 1;
    let close = open + line[open..].find('"')?;
    if close == open {
        return None;
    }
    let mut j = close + 1;
    while j < b.len() && (b[j] as char).is_whitespace() {
        j += 1;
    }
    if j < b.len() && b[j] == b':' {
        Some(&line[open..close])
    } else {
        None
    }
}

// ---------------------------------------------------------------- bitmasks
//
// Bitmasks rather than sets, exactly as the python: a few thousand targets each reaching a few
// thousand others is millions of entries as a set per node, and a few hundred kilobytes as bits.
// Python ints grow on demand; here the universe is indexed up front, which changes nothing
// because every result is either a count or a sum over the SET of bits.
#[derive(Clone)]
struct Mask(Vec<u64>);

impl Mask {
    fn new(words: usize) -> Mask {
        Mask(vec![0; words])
    }
    fn set(&mut self, i: usize) {
        self.0[i / 64] |= 1u64 << (i % 64);
    }
    fn or_with(&mut self, other: &Mask) {
        for (a, b) in self.0.iter_mut().zip(other.0.iter()) {
            *a |= *b;
        }
    }
    /// Set bits, ascending, which is the order the python walks with m & -m.
    fn bits(&self) -> impl Iterator<Item = usize> + '_ {
        self.0.iter().enumerate().flat_map(|(w, v)| {
            let mut v = *v;
            std::iter::from_fn(move || {
                if v == 0 {
                    None
                } else {
                    let b = v.trailing_zeros() as usize;
                    v &= v - 1;
                    Some(w * 64 + b)
                }
            })
        })
    }
}

// ---------------------------------------------------------------- the store listing

/// Every built graph dump with its SIZE, largest first. All four graph attributes build a
/// derivation NAMED cider-buck2-graph, so nothing in the store path says which is which.
///
/// SIZE, not action count, and that is a deliberate downgrade: counting actions meant reading 27
/// dumps end to end, about 8 GB of I/O, to print a 12 line list.
fn candidate_graphs() -> Vec<(u64, String)> {
    let mut out: Vec<(u64, String)> = Vec::new();
    let rd = match fs::read_dir("/nix/store") {
        Ok(r) => r,
        Err(_) => return out,
    };
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        // glob("*-cider-buck2-graph"), which never matches a leading dot.
        if !name.ends_with("-cider-buck2-graph") || name.starts_with('.') {
            continue;
        }
        let p = format!("/nix/store/{name}/graph.json");
        if let Ok(m) = fs::metadata(&p) {
            out.push((m.len(), p));
        }
    }
    // sort(reverse=True) on (size, path) tuples: size descending, then path descending.
    out.sort_by(|a, b| b.cmp(a));
    out
}

fn print_candidates() {
    for (n, p) in candidate_graphs().iter().take(12) {
        println!("  {:>7.0} MB  {p}", *n as f64 / 1e6);
    }
}

/// sys.exit(msg): the message goes to stderr and the status is 1.
fn die(msg: String) -> ExitCode {
    eprintln!("{msg}");
    ExitCode::FAILURE
}

fn refuse_to_guess() -> ExitCode {
    println!("REFUSING TO GUESS which graph to read.\n");
    println!("Every graph attribute emits the same derivation NAME, so the store cannot tell");
    println!("them apart, and their mtimes are all the epoch. Pick the one you mean");
    println!("(about 455 MB is -all, 294 MB is -min, smaller is a demo or a skeleton):\n");
    print_candidates();
    die("\npass --graph <path>, or build the one you want:\n  \
         nix build .#cider-buck2-graph-min --print-out-paths --no-link   (minimal)\n  \
         nix build .#cider-buck2-graph-all --print-out-paths --no-link   (full)"
        .to_string())
}

// ---------------------------------------------------------------- argv

struct Args {
    graph: Option<String>,
    prefix: String,
    top: i64,
    check: bool,
    budget: i64,
    expensive: i64,
}

fn take_value(
    argv: &[String],
    i: &mut usize,
    inline: Option<String>,
    flag: &str,
) -> Result<String, String> {
    if let Some(v) = inline {
        return Ok(v);
    }
    *i += 1;
    argv.get(*i).cloned().ok_or_else(|| format!("{flag}: expected one argument"))
}

/// argparse, minus the parts that are python rather than behaviour: --help and the usage error
/// for an unknown flag print argparse own wording, which this does not imitate. Both forms
/// argparse accepts for a value are accepted here, --flag value and --flag=value.
fn parse_args() -> Result<Args, String> {
    let mut a = Args {
        graph: None,
        prefix: "buck/prefix-min/BUCK".to_string(),
        top: 25,
        check: false,
        budget: DEFAULT_BUDGET,
        expensive: 0,
    };
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < argv.len() {
        let (flag, inline) = match argv[i].split_once('=') {
            Some((f, v)) => (f.to_string(), Some(v.to_string())),
            None => (argv[i].clone(), None),
        };
        match flag.as_str() {
            "--graph" => a.graph = Some(take_value(&argv, &mut i, inline, &flag)?),
            "--prefix" => a.prefix = take_value(&argv, &mut i, inline, &flag)?,
            "--top" => {
                let v = take_value(&argv, &mut i, inline, &flag)?;
                a.top = v.trim().parse().map_err(|_| format!("--top: invalid int value: {v}"))?
            }
            "--budget" => {
                let v = take_value(&argv, &mut i, inline, &flag)?;
                a.budget =
                    v.trim().parse().map_err(|_| format!("--budget: invalid int value: {v}"))?
            }
            "--expensive" => {
                let v = take_value(&argv, &mut i, inline, &flag)?;
                a.expensive =
                    v.trim().parse().map_err(|_| format!("--expensive: invalid int value: {v}"))?
            }
            "--check" => a.check = true,
            other => return Err(format!("unrecognized argument: {other}")),
        }
        i += 1;
    }
    Ok(a)
}

fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => return die(e),
    };
    let graph = match &args.graph {
        Some(g) => g.clone(),
        None => return refuse_to_guess(),
    };
    let graph = if fs::metadata(&graph).map(|m| m.is_dir()).unwrap_or(false) {
        format!("{}/graph.json", graph.trim_end_matches('/'))
    } else {
        graph
    };
    if !std::path::Path::new(&graph).exists() {
        return die(format!("{graph} does not exist"));
    }

    let root = match std::env::var("CIDER_REPO") {
        Ok(v) if !v.is_empty() => v,
        _ => match std::env::current_dir() {
            Ok(d) => d.to_string_lossy().into_owned(),
            Err(e) => return die(format!("cannot read the working directory: {e}")),
        },
    };
    let root = root.trim_end_matches('/').to_string();
    if !std::path::Path::new(&format!("{root}/flake.nix")).exists() {
        return die(format!(
            "{root} does not look like the cider tree (no flake.nix).\n\
             Run this from the repo root, or set CIDER_REPO."
        ));
    }
    // os.path.join: an absolute --prefix wins over the root.
    let prefix = if args.prefix.starts_with('/') {
        args.prefix.clone()
    } else {
        format!("{root}/{}", args.prefix)
    };
    if !std::path::Path::new(&prefix).exists() {
        return die(format!("{prefix} does not exist"));
    }

    // ------------------------------------------------ the graph: label -> actions, label -> deps
    let text = match fs::read_to_string(&graph) {
        Ok(t) => t,
        Err(e) => return die(format!("cannot read {graph}: {e}")),
    };
    let g: Value = match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(e) => return die(format!("cannot parse {graph}: {e}")),
    };
    drop(text);
    let empty: Vec<Value> = Vec::new();
    let actions = g.get("actions").and_then(|v| v.as_array()).unwrap_or(&empty);
    if actions.is_empty() {
        return die(format!("{graph} has no actions; is it a graph dump?"));
    }
    let mut cost: HashMap<&str, i64> = HashMap::new();
    let mut deps: HashMap<&str, HashSet<&str>> = HashMap::new();
    for a in actions {
        let ident = a.get("identity").and_then(|v| v.as_str()).unwrap_or("");
        let label = ident.split(" (").next().unwrap_or(ident);
        *cost.entry(label).or_insert(0) += 1;
        if let Some(ins) = a.get("input_targets").and_then(|v| v.as_array()) {
            for d in ins.iter().filter_map(|v| v.as_str()) {
                if d != label {
                    deps.entry(label).or_default().insert(d);
                }
            }
        }
    }

    // ------------------------------------------------ the prefix: label -> where it installs
    let ptext = match fs::read_to_string(&prefix) {
        Ok(t) => t,
        Err(e) => return die(format!("cannot read {prefix}: {e}")),
    };
    let mut order: Vec<String> = Vec::new();
    let mut dests: HashMap<String, Vec<String>> = HashMap::new();
    for line in ptext.lines() {
        let lab = match label_in(line) {
            Some(l) => format!("root{l}"),
            None => continue,
        };
        let d = dest_in(line).unwrap_or("?").to_string();
        dests
            .entry(lab.clone())
            .or_insert_with(|| {
                order.push(lab.clone());
                Vec::new()
            })
            .push(d);
    }

    println!("graph:  {graph}");
    println!(
        "prefix: {}: {} distinct labels, {} entries",
        args.prefix,
        dests.len(),
        dests.values().map(|v| v.len()).sum::<usize>()
    );

    let known: Vec<&str> = order
        .iter()
        .map(|s| s.as_str())
        .filter(|l| cost.contains_key(l) || deps.contains_key(l))
        .collect();
    // THE GUARD THAT WOULD HAVE CAUGHT IT. Refusing to guess stops the tool choosing a wrong
    // graph; this stops it staying quiet about one it was HANDED.
    let coverage = if dests.is_empty() { 0.0 } else { known.len() as f64 / dests.len() as f64 };
    println!(
        "resolved: {} of {} labels ({:.0} percent) appear in this graph",
        known.len(),
        dests.len(),
        100.0 * coverage
    );
    if coverage < MIN_COVERAGE {
        println!();
        print_candidates();
        return die(format!(
            "\nthis graph resolves only {:.0} percent of the prefix's labels, below the {:.0} \
             percent floor.\nIt is the wrong graph for this prefix: a demo, a skeleton, or a dump \
             from another target list.\nPick one of the above with --graph.",
            100.0 * coverage,
            100.0 * MIN_COVERAGE
        ));
    }
    if known.is_empty() {
        return die("no prefix label appears in the graph; wrong graph for this prefix?".to_string());
    }

    // ------------------------------------------------ reachability
    // The universe is every label that can appear in a mask: a node with actions, a node with
    // dependencies, or a node named as one.
    let mut index: HashMap<&str, usize> = HashMap::new();
    let mut rev: Vec<&str> = Vec::new();
    for t in cost.keys() {
        if !index.contains_key(*t) {
            index.insert(*t, rev.len());
            rev.push(*t);
        }
    }
    for (t, ds) in &deps {
        if !index.contains_key(*t) {
            index.insert(*t, rev.len());
            rev.push(*t);
        }
        for d in ds {
            if !index.contains_key(*d) {
                index.insert(*d, rev.len());
                rev.push(*d);
            }
        }
    }
    let words = rev.len().div_ceil(64);

    let no_deps: HashSet<&str> = HashSet::new();
    let mut reach: HashMap<&str, Mask> = HashMap::new();
    for start in &known {
        if reach.contains_key(*start) {
            continue;
        }
        let mut stack: Vec<(&str, bool)> = vec![(*start, false)];
        while let Some((node, expanded)) = stack.pop() {
            if reach.contains_key(node) {
                continue;
            }
            let children = deps.get(node).unwrap_or(&no_deps);
            let pending: Vec<&str> =
                children.iter().copied().filter(|c| !reach.contains_key(c)).collect();
            if !pending.is_empty() && !expanded {
                stack.push((node, true));
                stack.extend(pending.into_iter().map(|c| (c, false)));
                continue;
            }
            let mut m = Mask::new(words);
            m.set(index[node]);
            for c in children {
                // A cycle would leave a child unresolved; buck2 graphs are DAGs, and treating an
                // unresolved child as empty keeps this total rather than crashing.
                if let Some(cm) = reach.get(c) {
                    m.or_with(cm);
                }
            }
            reach.insert(node, m);
        }
    }
    let zero = Mask::new(words);

    // ------------------------------------------------ the OTHER question: what is expensive
    if args.expensive != 0 {
        // What is expensive, and who is asking for it. AppKit and CoreImage were 752 actions
        // pulled by pbcopy, pbpaste and open, and none of the three showed up in the exclusive
        // ranking, because the cost is shared so no single entry owns it.
        let mut in_cone: Vec<&str> = Vec::new();
        let mut seen = vec![false; rev.len()];
        let mut pullers: HashMap<&str, Vec<&str>> = HashMap::new();
        for label in &known {
            for i in reach.get(*label).unwrap_or(&zero).bits() {
                if !seen[i] {
                    seen[i] = true;
                    in_cone.push(rev[i]);
                }
                pullers.entry(rev[i]).or_default().push(*label);
            }
        }
        let cone_total: i64 = in_cone.iter().map(|t| *cost.get(t).unwrap_or(&0)).sum();
        println!("cone: {} targets, {cone_total} actions\n", in_cone.len());
        // THE ONE ORDER THE PYTHON DOES NOT FIX. It sorts a SET by -cost, and python sorts are
        // stable, so equal costs come out in set iteration order, which string hash
        // randomisation moves between runs. Ties are broken by name here, which is a choice the
        // python does not make rather than a difference in the ranking itself.
        in_cone.sort_by(|a, b| {
            cost.get(b).unwrap_or(&0).cmp(cost.get(a).unwrap_or(&0)).then_with(|| a.cmp(b))
        });
        // [:N] with a negative N drops from the END in python, so keep that rather than clamp.
        let end = if args.expensive < 0 {
            in_cone.len().saturating_sub((-args.expensive) as usize)
        } else {
            std::cmp::min(args.expensive as usize, in_cone.len())
        };
        for t in in_cone[..end].iter() {
            let c = *cost.get(t).unwrap_or(&0);
            if c == 0 {
                break;
            }
            println!("{c:>6} {:>5.1}%  {t}", 100.0 * c as f64 / cone_total as f64);
            let who = &pullers[t];
            // Few pullers means it is removable by dropping them; many means it is base.
            if who.len() <= 6 {
                let mut w: Vec<&str> = who.clone();
                w.sort();
                for x in w {
                    println!("{:>14}<- {x}", "");
                }
            } else {
                println!("{:>14}<- {} entries (shared base, not removable this way)", "", who.len());
            }
        }
        return ExitCode::SUCCESS;
    }

    // ------------------------------------------------ exclusive cost per entry
    // How many entries reach each target. A target reached by exactly one is exclusive to it.
    let mut hits = vec![0usize; rev.len()];
    for label in &known {
        for i in reach.get(*label).unwrap_or(&zero).bits() {
            hits[i] += 1;
        }
    }
    let mut rows: Vec<(i64, i64, i64, &str)> = Vec::new();
    for label in &known {
        let (mut excl_cost, mut excl_n, mut total) = (0i64, 0i64, 0i64);
        for i in reach.get(*label).unwrap_or(&zero).bits() {
            let c = *cost.get(rev[i]).unwrap_or(&0);
            total += c;
            if hits[i] == 1 {
                excl_cost += c;
                excl_n += 1;
            }
        }
        rows.push((excl_cost, excl_n, total, *label));
    }
    // sort(reverse=True) on the whole tuple, so ties break by label DESCENDING.
    rows.sort_by(|a, b| b.cmp(a));
    let total_actions: i64 = cost.values().sum();

    if args.check {
        let over: Vec<(i64, i64, i64, &str)> =
            rows.iter().filter(|r| !EXEMPT.contains(&r.3) && r.0 > args.budget).copied().collect();
        println!("budget: {} exclusive actions per non-exempt entry", args.budget);
        for (excl_cost, excl_n, _total, label) in &over {
            println!(
                "  OVER: {label} pulls {excl_cost} actions ({excl_n} targets) that nothing else \
                 in this prefix needs"
            );
            println!("        installs at {}", dests[*label][0]);
        }
        if !over.is_empty() {
            println!(
                "\nFAIL: {} entry(ies) over budget. Either the prefix needs them (add to EXEMPT, \
                 with the reason) or they are dead weight (add to EXCLUDE_LABELS in \
                 scripts/gen-prefix-min.nu).",
                over.len()
            );
            return ExitCode::FAILURE;
        }
        let worst = rows.iter().find(|r| !EXEMPT.contains(&r.3)).copied().unwrap_or((0, 0, 0, "none"));
        println!("PASS: worst non-exempt entry is {} at {} of {}", worst.3, worst.0, args.budget);
        return ExitCode::SUCCESS;
    }

    println!("total actions in graph: {total_actions}\n");
    println!("{:>10}{:>9}{:>9}  LABEL / where it installs", "EXCLUSIVE", "TARGETS", "TOTAL");
    let mut shown: i64 = 0;
    for (excl_cost, excl_n, total, label) in &rows {
        if *excl_cost == 0 {
            break;
        }
        let d = &dests[*label];
        let where_ = if d.len() > 1 {
            format!("{} (+{} more)", d[0], d.len() - 1)
        } else {
            d[0].clone()
        };
        println!("{excl_cost:>10}{excl_n:>9}{total:>9}  {label}\n{:>28}{where_}", "");
        shown += 1;
        if shown >= args.top {
            break;
        }
    }
    if shown == 0 {
        println!("  no entry has an exclusive cone: every label shares all of its cost");
    }
    let nonzero = rows.iter().filter(|r| r.0 != 0).count();
    println!(
        "\n{nonzero} of {} labels have an exclusive cone; the rest share every target they reach, \
         so removing one alone saves nothing.",
        known.len()
    );
    ExitCode::SUCCESS
}
