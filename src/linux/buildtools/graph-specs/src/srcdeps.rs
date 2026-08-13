//! WHAT PROJECT FILES DOES EACH LOWERED TARGET ACTUALLY READ? (the audit, not the rule)
//!
//! nix/lib/ciderBuck2Lower.nix once gave every lowered target the WHOLE filtered project as its
//! source, so editing any file it did not exclude relowered all of them. This measures whether a
//! precise set can be computed at all and what it buys, and it AUDITS THE COMPLETENESS of the
//! answer: naming individual files is only safe if every directory on an include path is a
//! staged tree whose exact contents the link map records, so it classifies every include root
//! and reports the project ones, which have to be taken wholesale.
//!
//! Where the headers really are is the link MAP the dump records per staged tree (stagedTrees,
//! which the dumper gets from BXL rather than aquery). A staging action arrives from aquery as
//! kind symlinkeddir with four attributes and no cmd and no inputs at all: it has no argv for a
//! header to be named in, so nothing computed from argvs alone would have staged a single one.
//!
//! THE ARGV RULES HERE ARE DELIBERATELY LOCAL, and that is the one place this binary does not
//! reuse src/srcset.rs. srcset carries the rule the lowering SHIPS, which has moved on twice
//! since this audit was written: it splits comma joined -Wl, tokens, and its include_roots does
//! not read a GLUED -iquote. THE RUST REWRITE of the python buck-lower-srcdeps (#98) reproduces
//! it byte for byte, which is what makes the port checkable, so it keeps that script own two
//! scrapers, and the usage line it prints still says .py because the gate compares it. What IS
//! shared is everything whose behaviour is identical: the farm table reader (trees.rs), normpath
//! and the memoised lexists (srcset.rs).
//!
//! THE REPO ROOT cannot come from the executable: the python took it from __file__, and this
//! lives in the store or in target/release. It is $CIDER_REPO, else the working directory, and
//! it is CHECKED rather than assumed, because a wrong root would not fail, it would report a
//! coarse baseline of zero and a union of nothing.
//!
//! Usage:
//!   cider-lower-srcdeps <graph.json> <graph-data-dir> [--target LABEL] [--list] [--top N]

#[path = "trees.rs"]
mod trees;
#[path = "srcset.rs"]
mod srcset;
use srcset::{normpath, Fs};

use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::process::ExitCode;

// The lowering own exclusion list, so "coarse" here is the CURRENT baseline rather than the
// unfiltered repo. Keep in step with nix/lib/ciderBuck2Lower.nix.
const COARSE_EXCLUDE: &[&str] = &[
    "plan", "docs", "nix", "scripts", "docs/changelog.md", "README.md", "CONTRIBUTORS.md",
    "LICENSE", ".vscode", ".claude", ".tangled", ".gdbinit", ".dfx-boot.log",
    ".git", ".jj", ".direnv", "buck-out", "result-graph-ref", "flake.nix", "flake.lock",
];

// Flags that carry a path in the SAME token.
const GLUED: &[&str] = &["-I", "-F", "-L", "-iquote"];

// The four project trees worth reporting an argv token against when it names one and is not
// there on disk.
const PROJECT_TOPS: &[&str] = &["vendor/src", "vendor/pins", "src/darwin", "vendor/rust"];

fn target_of(identity: &str) -> &str {
    identity.split(" (").next().unwrap_or(identity)
}

fn skip_prefix(s: &str) -> bool {
    s.starts_with('/') || s.starts_with('@') || s.starts_with("buck-out/")
}

/// Every project-relative path a single argv token might be.
///
/// A token starting with @ is a PLACEHOLDER the dump substituted for an absolute store path
/// (@CLANG@, @RESOURCE_DIR@, @LD64@). Treating those as project-relative is what made the first
/// run of this report claim 5,449 project include roots when the real number is two.
fn candidate_paths<'a>(tok: &'a str, out: &mut Vec<&'a str>) {
    out.clear();
    if tok.is_empty() || skip_prefix(tok) {
        return;
    }
    out.push(tok);
    for g in GLUED {
        if tok.starts_with(g) && tok.len() > g.len() {
            let rest = &tok[g.len()..];
            if !skip_prefix(rest) {
                out.push(rest);
            }
        }
    }
}

/// Every directory an action puts on the include path, as written.
fn include_roots<'a>(argv: &[&'a str], out: &mut Vec<&'a str>) {
    out.clear();
    for (i, t) in argv.iter().enumerate() {
        if matches!(*t, "-I" | "-isystem" | "-F" | "-iquote") {
            if i + 1 < argv.len() {
                out.push(argv[i + 1]);
            }
        } else if (t.starts_with("-I") || t.starts_with("-F")) && t.len() > 2 {
            out.push(&t[2..]);
        } else if t.starts_with("-iquote") && t.len() > "-iquote".len() {
            out.push(&t["-iquote".len()..]);
        }
    }
}

/// posixpath.dirname, which keeps the root slash. srcset::dirname is a plain rfind and returns
/// "" for "/a", so it is not this function, and the difference would be silent.
fn pdirname(p: &str) -> &str {
    let i = match p.rfind('/') {
        Some(i) => i + 1,
        None => return "",
    };
    let head = &p[..i];
    if !head.is_empty() && head.bytes().any(|b| b != b'/') {
        head.trim_end_matches('/')
    } else {
        head
    }
}

/// posixpath.join of exactly two parts, including the rule that an absolute second part WINS.
fn pjoin(a: &str, b: &str) -> String {
    if b.starts_with('/') {
        b.to_string()
    } else if a.is_empty() || a.ends_with('/') {
        format!("{a}{b}")
    } else {
        format!("{a}/{b}")
    }
}

/// One directory, classified the way os.walk classifies it.
///
/// os.walk asks entry.is_dir(), which FOLLOWS the link, so a symlink to a directory counts as a
/// DIRECTORY and its files are never counted; followlinks=False then refuses to descend into it,
/// which the caller does by testing the link separately. A broken link raises inside is_dir and
/// lands among the files. Getting this from the dirent type instead would count every symlinked
/// directory as one file.
fn scan_dir(abs: &str) -> (Vec<String>, Vec<String>) {
    let mut dirs = Vec::new();
    let mut files = Vec::new();
    let rd = match fs::read_dir(abs) {
        Ok(r) => r,
        Err(_) => return (dirs, files), // os.walk with onerror=None swallows this too.
    };
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let p = format!("{abs}/{name}");
        if fs::metadata(&p).map(|m| m.is_dir()).unwrap_or(false) {
            dirs.push(name);
        } else {
            files.push(name);
        }
    }
    (dirs, files)
}

fn is_symlink(p: &str) -> bool {
    fs::symlink_metadata(p).map(|m| m.file_type().is_symlink()).unwrap_or(false)
}

/// Every file under a project directory, as repo-relative paths. The TOP is walked even when it
/// is itself a symlink, because os.walk only refuses to descend into links it finds INSIDE.
fn under(repo: &str, d: &str) -> HashSet<String> {
    let mut out = HashSet::new();
    let mut stack = vec![(format!("{repo}/{d}"), normpath(d))];
    while let Some((abs, rel)) = stack.pop() {
        let (dirs, files) = scan_dir(&abs);
        for f in files {
            out.insert(pjoin(&rel, &f));
        }
        for sub in dirs {
            let p = format!("{abs}/{sub}");
            if !is_symlink(&p) {
                let r = pjoin(&rel, &sub);
                stack.push((p, r));
            }
        }
    }
    out
}

/// The coarse baseline: what every target depends on today.
///
/// The python also re-tests the FIRST SEGMENT of every directory it reaches against the same
/// list. That test can never fire: the excluded names are pruned from the root own dirnames
/// before the walk can descend into any of them.
fn coarse_count(repo: &str) -> usize {
    let (dirs, files) = scan_dir(repo);
    let mut n = files.iter().filter(|f| !COARSE_EXCLUDE.contains(&f.as_str())).count();
    let mut stack: Vec<String> = Vec::new();
    for d in dirs {
        if COARSE_EXCLUDE.contains(&d.as_str()) {
            continue;
        }
        let p = format!("{repo}/{d}");
        if !is_symlink(&p) {
            stack.push(p);
        }
    }
    while let Some(cur) = stack.pop() {
        let (dirs, files) = scan_dir(&cur);
        n += files.len();
        for d in dirs {
            let p = format!("{cur}/{d}");
            if !is_symlink(&p) {
                stack.push(p);
            }
        }
    }
    n
}

/// Longest known prefix, so a file named inside a generated directory resolves.
fn owner_of<'a>(known: &HashSet<String>, path: &'a str) -> Option<&'a str> {
    if known.contains(path) {
        return Some(path);
    }
    let cuts: Vec<usize> = path.match_indices('/').map(|(i, _)| i).collect();
    for i in cuts.iter().rev() {
        let p = &path[..*i];
        if known.contains(p) {
            return Some(p);
        }
    }
    None
}

/// A staged tree links, resolved to the paths they actually point at.
fn tree_sources_of(links: &[(String, String)], tree_path: &str) -> HashSet<String> {
    // The python holds the links in a DICT, so a repeated name keeps only the LAST target.
    let mut last: HashMap<&str, &str> = HashMap::new();
    for (rel, tgt) in links {
        last.insert(rel.as_str(), tgt.as_str());
    }
    let mut out = HashSet::new();
    for (rel, tgt) in last {
        let link = pjoin(tree_path, rel);
        let dest = normpath(&pjoin(pdirname(&link), tgt));
        if !dest.starts_with("buck-out/") && !dest.starts_with('/') {
            out.insert(dest);
        }
    }
    out
}

fn strv<'a>(a: &'a Value, k: &str) -> Vec<&'a str> {
    a.get(k)
        .and_then(|v| v.as_array())
        .map(|v| v.iter().filter_map(|x| x.as_str()).collect())
        .unwrap_or_default()
}

/// A python list-of-strings repr, for the "did you mean" line.
fn py_list(items: &[&String]) -> String {
    let mut s = String::from("[");
    for (i, it) in items.iter().enumerate() {
        if i > 0 {
            s.push_str(", ");
        }
        if it.contains('\'') && !it.contains('"') {
            s.push('"');
            s.push_str(it);
            s.push('"');
        } else {
            s.push('\'');
            s.push_str(&it.replace('\\', "\\\\").replace('\'', "\\'"));
            s.push('\'');
        }
    }
    s.push(']');
    s
}

fn pct(num: usize, den: usize) -> String {
    format!("{:.2}%", (num as f64) / (den as f64) * 100.0)
}

fn die(msg: String) -> ExitCode {
    eprintln!("{msg}");
    ExitCode::FAILURE
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let mut args: Vec<String> = argv.iter().filter(|a| !a.starts_with("--")).cloned().collect();
    let mut want: Option<String> = None;
    for (i, a) in argv.iter().enumerate() {
        if a == "--target" && i + 1 < argv.len() {
            let w = argv[i + 1].clone();
            args.retain(|x| *x != w);
            want = Some(w);
        }
    }
    // int() in the python, so a non-numeric --top was a traceback there and is a message here.
    let mut top_n: i64 = 10;
    for (i, a) in argv.iter().enumerate() {
        if a == "--top" && i + 1 < argv.len() {
            let v = &argv[i + 1];
            top_n = match v.trim().parse::<i64>() {
                Ok(n) => n,
                Err(_) => return die(format!("--top wants an integer, got {v}")),
            };
            args.retain(|x| x != v);
        }
    }
    if args.len() < 2 {
        println!(
            "usage: buck-lower-srcdeps.py <graph.json> <graph-data-dir> [--target LABEL] [--list]"
        );
        return ExitCode::from(2);
    }

    let repo = match std::env::var("CIDER_REPO") {
        Ok(v) if !v.is_empty() => v,
        _ => match std::env::current_dir() {
            Ok(d) => d.to_string_lossy().into_owned(),
            Err(e) => return die(format!("cannot read the working directory: {e}")),
        },
    };
    let repo = repo.trim_end_matches('/').to_string();
    if !std::path::Path::new(&format!("{repo}/flake.nix")).exists()
        || !std::path::Path::new(&format!("{repo}/scripts")).exists()
    {
        return die(format!(
            "{repo} does not look like the cider tree (no flake.nix and scripts/).\n\
             Run this from the repo root, or set CIDER_REPO."
        ));
    }

    let text = match fs::read_to_string(&args[0]) {
        Ok(t) => t,
        Err(e) => return die(format!("cannot read {}: {e}", args[0])),
    };
    let graph: Value = match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(e) => return die(format!("cannot parse {}: {e}", args[0])),
    };
    drop(text);

    let actions: &Vec<Value> = match graph.get("actions").and_then(|v| v.as_array()) {
        Some(a) => a,
        None => return die("graph has no actions".to_string()),
    };
    let staged_keys: Vec<&str> = graph
        .get("staged")
        .and_then(|v| v.as_object())
        .map(|o| o.keys().map(|k| k.as_str()).collect())
        .unwrap_or_default();
    // THE ONE MODE THAT IS NOT BYTE IDENTICAL, and it is the missing data directory. The python
    // has no handling here at all: open() raises, and it dies with a traceback naming its own
    // frames and exit 1. Reproducing that would mean printing fake python frames, so this prints
    // the same missing path as a message and keeps the exit code. Stdout is empty in both.
    let trees_in = match trees::read_trees(&graph, &args[1]) {
        Ok(t) => t,
        Err(e) => return die(e),
    };
    let staged_trees: HashMap<&str, &Vec<(String, String)>> =
        trees_in.iter().map(|(p, l)| (p.as_str(), l)).collect();

    // Targets in graph order, and each target actions with it.
    let mut order: Vec<&str> = Vec::new();
    let mut by_target: HashMap<&str, Vec<&Value>> = HashMap::new();
    let mut producer: HashMap<&str, &str> = HashMap::new();
    let mut outputs_of: HashMap<&str, Vec<&str>> = HashMap::new();
    for a in actions {
        let ident = a.get("identity").and_then(|v| v.as_str()).unwrap_or("");
        let label = target_of(ident);
        by_target
            .entry(label)
            .or_insert_with(|| {
                order.push(label);
                Vec::new()
            })
            .push(a);
        for o in strv(a, "outputs") {
            producer.insert(o, label);
            outputs_of.entry(label).or_default().push(o);
        }
    }

    let mut known: HashSet<String> = HashSet::new();
    known.extend(producer.keys().map(|k| k.to_string()));
    known.extend(staged_keys.iter().map(|k| k.to_string()));
    known.extend(staged_trees.keys().map(|k| k.to_string()));

    // THE COMPLETENESS QUESTION. An -I pointing straight at a project directory lets the compile
    // read anything under it, and no per-file set computed from argvs could know what. So
    // classify every include root, and take the project ones WHOLESALE.
    let mut root_class: [usize; 3] = [0, 0, 0]; // staged, absolute, project
    let mut project_order: Vec<String> = Vec::new();
    let mut project_roots: HashMap<String, usize> = HashMap::new();
    let mut roots: Vec<&str> = Vec::new();
    for a in actions {
        let av = strv(a, "argv");
        include_roots(&av, &mut roots);
        for p in &roots {
            if p.starts_with("buck-out/") {
                root_class[0] += 1;
            } else if p.starts_with('/') || p.starts_with('@') {
                root_class[1] += 1;
            } else {
                root_class[2] += 1;
                match project_roots.get_mut(*p) {
                    Some(n) => *n += 1,
                    None => {
                        project_order.push(p.to_string());
                        project_roots.insert(p.to_string(), 1);
                    }
                }
            }
        }
    }

    let mut whole_dirs: HashMap<String, HashSet<String>> = HashMap::new();
    for d in &project_order {
        let abs = format!("{repo}/{d}");
        if fs::metadata(&abs).map(|m| m.is_dir()).unwrap_or(false) {
            whole_dirs.insert(d.clone(), under(&repo, d));
        }
    }

    let mut fsx = Fs::new();
    let mut ts_cache: HashMap<String, HashSet<String>> = HashMap::new();
    let mut precise: HashMap<&str, HashSet<String>> = HashMap::new();
    let mut missing_tokens: HashSet<String> = HashSet::new();
    let mut cands: Vec<&str> = Vec::new();
    for label in &order {
        let acts = &by_target[*label];
        let mut srcs: HashSet<String> = HashSet::new();
        // 1. What this target own commands name.
        for a in acts {
            let av = strv(a, "argv");
            for tok in &av {
                candidate_paths(*tok, &mut cands);
                for cand in &cands {
                    if fsx.lexists(&format!("{repo}/{cand}")) {
                        srcs.insert(cand.to_string());
                        break;
                    }
                    let top = cand.split('/').next().unwrap_or("");
                    if PROJECT_TOPS.contains(&top) {
                        // Names a project tree but is not on disk: worth seeing.
                        missing_tokens.insert(cand.to_string());
                    }
                }
            }
            // 1b. And any project directory it puts on the include path, in full.
            include_roots(&av, &mut roots);
            for p in &roots {
                if let Some(files) = whole_dirs.get(*p) {
                    srcs.extend(files.iter().cloned());
                }
            }
        }
        // 2. The staged trees it consumes, which is where headers live.
        let mut owners: HashSet<&str> = HashSet::new();
        for a in acts {
            for i in strv(a, "inputs") {
                if let Some(o) = owner_of(&known, i) {
                    owners.insert(o);
                }
            }
        }
        // input_targets covers actions that read their inputs from a manifest file rather than
        // naming them, which is how the prefix target works. The python scans every producer
        // entry per input target; the map is the same relation, indexed.
        for a in acts {
            for t in strv(a, "input_targets") {
                for o in outputs_of.get(t).map(|v| v.as_slice()).unwrap_or(&[]) {
                    if staged_trees.contains_key(o) {
                        owners.insert(o);
                    }
                }
            }
        }
        for o in owners {
            if let Some(links) = staged_trees.get(o) {
                let ts = match ts_cache.get(o) {
                    Some(v) => v.clone(),
                    None => {
                        let v = tree_sources_of(links.as_slice(), o);
                        ts_cache.insert(o.to_string(), v.clone());
                        v
                    }
                };
                srcs.extend(ts.iter().cloned());
                // One level out: a farm can link at another farm output.
                for dest in &ts {
                    if let Some(sub) = owner_of(&known, dest) {
                        if let Some(sublinks) = staged_trees.get(sub) {
                            let sts = match ts_cache.get(sub) {
                                Some(v) => v.clone(),
                                None => {
                                    let v = tree_sources_of(sublinks.as_slice(), sub);
                                    ts_cache.insert(sub.to_string(), v.clone());
                                    v
                                }
                            };
                            srcs.extend(sts.iter().cloned());
                        }
                    }
                }
            }
        }
        precise.insert(label, srcs);
    }

    let coarse = coarse_count(&repo);

    let mut union: HashSet<&String> = HashSet::new();
    for v in precise.values() {
        union.extend(v.iter());
    }
    // (count, label) descending, which is what reverse=True does to the whole tuple: ties break
    // by label DESCENDING, and the largest-targets list shows it.
    let mut counts: Vec<(usize, &str)> =
        order.iter().map(|l| (precise[*l].len(), *l)).collect();
    counts.sort_by(|a, b| b.cmp(a));

    println!("graph:            {}", args[0]);
    println!("targets:          {}", precise.len());
    println!("coarse baseline:  {coarse} project files, for EVERY target");
    println!("union of precise: {} files across all targets", union.len());
    if !counts.is_empty() {
        let mid = counts[counts.len() / 2].0;
        println!(
            "per target:       max {}, median {mid}, min {}",
            counts[0].0,
            counts[counts.len() - 1].0
        );
        println!("median target reads {} of the coarse source", pct(mid, coarse));
    }
    if !missing_tokens.is_empty() {
        println!(
            "\nargv tokens naming a project tree but absent on disk: {}",
            missing_tokens.len()
        );
        let mut ms: Vec<&String> = missing_tokens.iter().collect();
        ms.sort();
        for m in ms.iter().take(5) {
            println!("    ? {m}");
        }
    }

    // The audit that decides whether any of the above can be trusted.
    println!("\ninclude roots, by where they point:");
    for (i, k) in ["staged", "absolute", "project"].iter().enumerate() {
        println!("  {:8}  {k}", root_class[i]);
    }
    if !project_order.is_empty() {
        println!("  the project ones, taken WHOLESALE above:");
        // sorted(key=-count) is STABLE, so equal counts keep first-seen order.
        let mut ds: Vec<&String> = project_order.iter().collect();
        ds.sort_by_key(|d| std::cmp::Reverse(project_roots[*d]));
        for d in ds {
            let n = project_roots[d];
            let size = whole_dirs.get(d).map(|s| s.len()).unwrap_or(0);
            let tail = if whole_dirs.contains_key(d) { "" } else { "  [not a directory here]" };
            println!("    {n:6}x  {d}  ({size} files){tail}");
        }
    }

    println!("\nlargest {top_n} targets by project-file count:");
    let end = if top_n < 0 {
        counts.len().saturating_sub((-top_n) as usize)
    } else {
        std::cmp::min(top_n as usize, counts.len())
    };
    for (n, label) in &counts[..end] {
        println!("  {n:7}  {label}");
    }

    if let Some(want) = want {
        let got = precise.get(want.as_str());
        let got = match got {
            Some(g) => g,
            None => {
                // The python scans precise, which is insertion ordered, so this is graph order.
                let near_owned: Vec<String> =
                    order.iter().filter(|k| k.contains(&want)).map(|k| k.to_string()).collect();
                let refs: Vec<&String> = near_owned.iter().take(3).collect();
                let hint = if near_owned.is_empty() {
                    String::new()
                } else {
                    format!("; did you mean {}", py_list(&refs))
                };
                println!("\nno such target: {want}{hint}");
                return ExitCode::from(1);
            }
        };
        let hdr = got
            .iter()
            .filter(|p| {
                p.ends_with(".h")
                    || p.ends_with(".hpp")
                    || p.ends_with(".hh")
                    || p.ends_with(".defs")
                    || p.ends_with(".inc")
            })
            .count();
        println!("\n{want}");
        println!("  project files: {}  ({hdr} headers)", got.len());
        println!("  vs coarse:     {} of {coarse}", pct(got.len(), coarse));
        if argv.iter().any(|a| a == "--list") {
            let mut ps: Vec<&String> = got.iter().collect();
            ps.sort();
            for p in ps {
                println!("    {p}");
            }
        }
    }
    ExitCode::SUCCESS
}
