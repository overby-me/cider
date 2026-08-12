//! Assemble the port's action graph from what buck2 can be asked, for the Nix endpoint. The
//! Rust rewrite of the python graph dump (buck2-graph-dump.py, deleted by #99).
//!
//! Run INSIDE nix/lib/ciderBuck2Graph.nix, right after a build, with the project root as the
//! working directory. Three buck2 interfaces are needed because no single one answers
//! everything (see buck/bxl/probe.bxl for what was tried):
//!
//!   * `aquery --output-all-attributes` -- the command line, at ANALYSIS time, without
//!     executing anything. Its `cmd` is rendered by joining the real argv with ", " (comma plus
//!     space), which is lossy in general: an argument containing that sequence cannot be told
//!     from two arguments. It HAS been lossy for this port, once -- perl's versions.h passed a
//!     C initializer carrying the separator and the Nix lowering replayed a different command
//!     than buck2 ran. The flags that carry commas (-Wl,-alias_list,<file>) never carry
//!     comma-space, and configure_file now passes its values in a file, so nothing in the tree
//!     carries it. scripts/buck-argv-roundtrip-check.nu holds both halves of that. See unjoin.
//!   * `log what-ran --format json` -- the same commands, but only for actions that actually
//!     RAN. Kept as the checker, not as the source: using it as the source is what forced the
//!     graph derivation to compile everything before it could learn anything.
//!   * `audit output <path>` -- which action produced a buck-out path. That is what separates
//!     an action's OWN outputs from the artifacts it consumes, which no argv makes explicit.
//!   * `aquery` -- every action's kind, including the in-process ones (symlinked_dir, write,
//!     copy) that never appear in what-ran.
//!
//! The in-process artifacts are then copied out DEREFERENCED: a staged include root is a farm
//! of relative symlinks into the project, which mean nothing once the tree is a store path.
//!
//! The graph comes out MACHINE-INDEPENDENT. An argv names its tools by absolute path, and under
//! Nix those are store paths, which would tie the dump to the machine that made it. Each is
//! replaced by a named placeholder the consumer substitutes from its own inputs, and anything
//! left pointing into the store afterwards is reported, because a silent one would be a machine
//! dependency nobody notices until the cache misses.
//!
//! WHAT THE PORT HAD TO PRESERVE EXACTLY, since graph.json is read at EVALUATION by every
//! lowered derivation and one byte moves all of them: python's json.dump with indent=2 and
//! sort_keys=True (pyjson::dumps_indent2_sorted), the dict iteration orders that decide which
//! duplicate wins, and the Kahn order with its identity tie break.
//!
//! Usage:
//!   cider-graph-dump <isolation-dir> <out-dir> [--placeholder NAME=PATH ...] <target> ...

use std::collections::{BTreeMap, BTreeSet, BinaryHeap, HashMap, HashSet};
use std::cmp::Reverse;
use std::env;
use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::Command;

use serde_json::{Map, Value};

#[path = "pyjson.rs"]
mod pyjson;
#[path = "pat.rs"]
mod pat;
#[path = "sha256.rs"]
mod sha256;
#[path = "pypath.rs"]
mod pypath;

use sha256::sha256_hex16;

const USAGE: &str = "Usage:\n  cider-graph-dump <isolation-dir> <out-dir> \
[--placeholder NAME=PATH ...] <target> ...";

fn die(msg: &str) -> ! {
    eprintln!("{msg}");
    std::process::exit(1);
}

fn buck2(isolation: &str, args: &[&str]) -> String {
    let out = Command::new("buck2")
        .arg("--isolation-dir")
        .arg(isolation)
        .args(args)
        .output()
        .unwrap_or_else(|e| die(&format!("buck2 could not be run: {e}")));
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        // By CHARACTER, like python's err[-2000:], and never through a byte slice that could
        // land inside a UTF-8 sequence and panic while reporting somebody else's failure.
        let tail: String = if err.chars().count() > 2000 {
            err.chars().skip(err.chars().count() - 2000).collect()
        } else {
            err.to_string()
        };
        eprintln!("{tail}");
        let named: Vec<&str> = args.iter().take(2).copied().collect();
        die(&format!("buck2 {} failed", named.join(" ")));
    }
    String::from_utf8(out.stdout)
        .unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned())
}

/// `root//pkg:name (<cfg>) (c_compile src/lock.c)` -> a stable, filesystem-safe id.
fn action_id(identity: &str) -> String {
    pat::sanitise(identity).trim_matches('_').to_string()
}

/// --placeholder NAME=PATH ... -> ([(PATH, "@NAME@")], remaining argv).
///
/// Flags are stripped here so the rest of argv is targets and nothing else: a stray flag reaches
/// buck2 as a target pattern and the error names the flag, not the mistake.
///
/// A VEC, NOT A MAP, and in argv order, because `portable` sorts these by length with a STABLE
/// sort and two placeholder paths of equal length would otherwise be applied in an order that
/// depends on the hash of their names.
fn parse_placeholders(argv: &[String]) -> (Vec<(String, String)>, Vec<String>) {
    let mut subs: Vec<(String, String)> = Vec::new();
    let mut rest = Vec::new();
    let mut i = 0;
    while i < argv.len() {
        if argv[i] == "--check-against-what-ran" {
            i += 1;
            continue;
        }
        if argv[i] == "--placeholder" && i + 1 < argv.len() {
            let (name, path) = match argv[i + 1].split_once('=') {
                Some((n, p)) => (n, p),
                None => (argv[i + 1].as_str(), ""),
            };
            if !path.is_empty() {
                subs.push((path.to_string(), format!("@{name}@")));
            }
            i += 2;
            continue;
        }
        rest.push(argv[i].clone());
        i += 1;
    }
    (subs, rest)
}

/// aquery's `cmd` back into an argv.
///
/// It is rendered as "[a, b, c]" -- the real argv joined with comma-space. Reversing that is
/// only sound while no argument contains the separator, and THAT IS AN ASSUMPTION, not a
/// guarantee. check_against_what_ran verifies it, but only for actions that actually ran in the
/// last invocation; the graph comes from analysis, where most never do.
///
/// It has been wrong once. perl's versions.h passed VERSIONS as the C initializer
/// ` "5.18", "5.28",`, which came back as two arguments and killed the Nix lowering, while the
/// host, which never round-trips through this rendering, built it fine. The fix was to stop the
/// rule putting a comma-space in an argument at all (buck/rules/codegen.bzl), because the
/// ambiguity cannot be resolved after the fact. If this bites again the answer is the same.
fn unjoin(cmd: &str) -> Vec<String> {
    let mut inner = cmd.trim();
    if inner.starts_with('[') && inner.ends_with(']') {
        inner = &inner[1..inner.len() - 1];
    }
    if inner.is_empty() {
        return Vec::new();
    }
    inner.split(", ").map(|s| s.to_string()).collect()
}

/// Longest first, so a resource root inside a compiler prefix is not half-replaced.
fn portable(value: &str, subs: &[(String, String)]) -> String {
    let mut order: Vec<&(String, String)> = subs.iter().collect();
    // Stable, like python's sorted(key=len, reverse=True): equal lengths keep argv order.
    order.sort_by(|a, b| b.0.len().cmp(&a.0.len()));
    let mut v = value.to_string();
    for (path, name) in order {
        v = v.replace(path.as_str(), name);
    }
    v
}

struct Action {
    id: String,
    identity: String,
    argv: Vec<String>,
    outputs: Vec<String>,
    inputs: Vec<String>,
    input_targets: Vec<String>,
}

impl Action {
    fn target(&self) -> &str {
        match self.identity.split_once(" (") {
            Some((t, _)) => t,
            None => &self.identity,
        }
    }

    fn to_value(&self) -> Value {
        let mut m = Map::new();
        m.insert("id".into(), Value::String(self.id.clone()));
        m.insert("identity".into(), Value::String(self.identity.clone()));
        m.insert("argv".into(), strs(&self.argv));
        // The only env buck2 sets is TMPDIR and BUCK_SCRATCH_PATH, and the consumer makes its
        // own in its own sandbox, so nothing is lost by aquery not carrying env at all.
        m.insert("env".into(), Value::Object(Map::new()));
        m.insert("outputs".into(), strs(&self.outputs));
        m.insert("inputs".into(), strs(&self.inputs));
        m.insert("input_targets".into(), strs(&self.input_targets));
        Value::Object(m)
    }
}

fn strs(v: &[String]) -> Value {
    Value::Array(v.iter().map(|s| Value::String(s.clone())).collect())
}

/// {target label: pin} for the pins that can safely become ONE derivation each.
///
/// buck-src is 59 percent of the actions and changes only when a submodule pin is bumped, so one
/// derivation per target there buys nothing and costs a staging pass per target. Merging a pin's
/// targets is the fix -- but CONTRACTING A DAG CAN CREATE CYCLES, and here it does: 42 of 157
/// pins land in one strongly connected component covering the system cone, which are mutually
/// dependent at target level even though the target graph itself is acyclic. Merging those is
/// not suboptimal, it is invalid, and in Nix it surfaces as a bare "infinite recursion" from the
/// dependency staging line with no indication of the cause.
///
/// So the answer is computed HERE, where the whole graph is in hand, and only pins that are in
/// no cycle are offered. The other 115 are safe, JavaScriptCore among them, which is the worst
/// case this exists for: 1,088 compiles that used to run one at a time.
fn coarse_pin_map(ran: &[Action]) -> BTreeMap<String, String> {
    let mut producer: HashMap<&str, &str> = HashMap::new();
    for a in ran {
        for o in &a.outputs {
            producer.insert(o.as_str(), a.target());
        }
    }

    // A target already inside a per-pin package names its pin in the PACKAGE PATH. Do not look
    // at source roots there: buck-src/python keeps its sources under Python-2.7.16/, which
    // would file that target under a Python-2.7.16 pin instead of python.
    let mut first_root: HashMap<&str, String> = HashMap::new();
    for a in ran {
        let t = a.target();
        if !first_root.contains_key(t) {
            if let Some(root) = pat::compile_root(&a.identity) {
                first_root.insert(t, root);
            }
        }
    }

    let pin_of = |label: &str| -> Option<String> {
        if !label.starts_with("root//buck-src") {
            return None;
        }
        let pkg = label.split(':').next().unwrap_or(label);
        let pkg = &pkg["root//buck-src".len()..];
        if !pkg.is_empty() {
            return Some(pkg.trim_start_matches('/').split('/').next().unwrap_or("").to_string());
        }
        first_root.get(label).cloned()
    };

    // EVERY label, not only the ones that own actions. A declared input can name a target with
    // no actions at all, and the lowering maps declared labels through the same grouping (it
    // must, or the dependency vanishes). Keying only on targets seen in the action list left 30
    // pins looking acyclic that are not, which is the direction that ends in infinite recursion
    // an hour into a build.
    let mut node_cache: HashMap<String, String> = HashMap::new();
    let mut node_of = |label: &str, cache: &mut HashMap<String, String>| -> String {
        if let Some(n) = cache.get(label) {
            return n.clone();
        }
        let n = match pin_of(label) {
            Some(p) => format!("pin:{p}"),
            None => label.to_string(),
        };
        cache.insert(label.to_string(), n.clone());
        n
    };

    let mut edges: HashMap<&str, BTreeSet<String>> = HashMap::new();
    for a in ran {
        let t = a.target();
        let s = edges.entry(t).or_default();
        for i in &a.inputs {
            if let Some(p) = producer.get(i.as_str()) {
                if *p != t {
                    s.insert((*p).to_string());
                }
            }
        }
        for d in &a.input_targets {
            if d != t {
                s.insert(d.clone());
            }
        }
    }

    // The same edges with every target replaced by its pin. A cycle here means two pins each
    // hold a target depending on the other.
    let mut pe: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for (t, deps) in &edges {
        let nt = node_of(t, &mut node_cache);
        let mut mapped = BTreeSet::new();
        for d in deps {
            let nd = node_of(d, &mut node_cache);
            if nd != nt {
                mapped.insert(nd);
            }
        }
        pe.entry(nt).or_default().extend(mapped);
    }

    let cyclic = tarjan_cyclic(&pe);

    let mut out = BTreeMap::new();
    for a in ran {
        let label = a.target();
        let n = node_of(label, &mut node_cache);
        if let Some(pin) = n.strip_prefix("pin:") {
            if !cyclic.contains(&n) {
                out.insert(label.to_string(), pin.to_string());
            }
        }
    }
    let pins: BTreeSet<&String> = out.values().collect();
    let refused = cyclic.iter().filter(|n| n.starts_with("pin:")).count();
    eprintln!(
        "  {} coarsenable pin(s) over {} target(s); {} pin(s) refused for cycles",
        pins.len(),
        out.len(),
        refused
    );
    out
}

/// Every node that lies in a strongly connected component of more than one node. Tarjan,
/// iterative because the graph is deep enough to blow a recursive implementation.
fn tarjan_cyclic(pe: &BTreeMap<String, BTreeSet<String>>) -> HashSet<String> {
    let mut index: HashMap<&str, usize> = HashMap::new();
    let mut low: HashMap<&str, usize> = HashMap::new();
    let mut onstack: HashSet<&str> = HashSet::new();
    let mut stack: Vec<&str> = Vec::new();
    let mut counter = 0usize;
    let mut cyclic: HashSet<String> = HashSet::new();

    // The work stack holds a POSITION into a materialised neighbour list rather than an
    // iterator: an iterator borrowed from `pe` cannot survive the push that descends into the
    // next node.
    let neighbours = |n: &str| -> Vec<&str> {
        pe.get(n).map(|s| s.iter().map(|x| x.as_str()).collect()).unwrap_or_default()
    };

    for root in pe.keys() {
        let root = root.as_str();
        if index.contains_key(root) {
            continue;
        }
        index.insert(root, counter);
        low.insert(root, counter);
        counter += 1;
        stack.push(root);
        onstack.insert(root);
        let mut work: Vec<(&str, Vec<&str>, usize)> = vec![(root, neighbours(root), 0)];
        while !work.is_empty() {
            let last = work.len() - 1;
            let v = work[last].0;
            let mut descended: Option<&str> = None;
            while work[last].2 < work[last].1.len() {
                let w = work[last].1[work[last].2];
                work[last].2 += 1;
                if !index.contains_key(w) {
                    index.insert(w, counter);
                    low.insert(w, counter);
                    counter += 1;
                    stack.push(w);
                    onstack.insert(w);
                    descended = Some(w);
                    break;
                }
                if onstack.contains(w) {
                    let iw = index[w];
                    let lv = low[v];
                    low.insert(v, lv.min(iw));
                }
            }
            if let Some(w) = descended {
                work.push((w, neighbours(w), 0));
                continue;
            }
            work.pop();
            if let Some((parent, _, _)) = work.last() {
                let lp = low[*parent];
                let lv = low[v];
                low.insert(*parent, lp.min(lv));
            }
            if low[v] == index[v] {
                let mut comp: Vec<&str> = Vec::new();
                loop {
                    let w = stack.pop().unwrap();
                    onstack.remove(w);
                    comp.push(w);
                    if w == v {
                        break;
                    }
                }
                if comp.len() > 1 {
                    for w in comp {
                        cyclic.insert(w.to_string());
                    }
                }
            }
        }
    }
    cyclic
}

/// The same actions, in a TOPOLOGICAL order that does not change between runs (#72).
///
/// THE PROBLEM: aquery does not hand these back in a stable order. Two dumps of an unchanged
/// tree produced graph.json files of exactly the same size, 307,041,054 bytes, that
/// scripts/buck-graph-equiv.py called the same graph on every dimension, and which still
/// differed at byte 49 because the action list started with a different action. The lowering
/// reads graph.json at EVALUATION, so a byte difference moves every lowered derivation.
///
/// WHY NOT sort by identity, which is the obvious fix and is WRONG: ciderBuck2Lower.nix requires
/// this list to be GLOBALLY TOPOLOGICAL and says so. Coarse pin regrouping is only valid because
/// of it, and #52 concurrency correctness rests on it, since an action reading none of its
/// siblings outputs cannot depend on anything already launched. A plain sort breaks that into a
/// RACE rather than an error, which is the worst kind of regression to ship.
///
/// So: Kahn, with the ready set kept in a heap keyed on identity. Topological because it is
/// Kahn, deterministic because the tie break is total and the identities are unique.
fn deterministic_action_order(actions: Vec<Action>) -> Vec<Action> {
    let mut producer: HashMap<&str, usize> = HashMap::new();
    for (i, a) in actions.iter().enumerate() {
        for o in &a.outputs {
            producer.insert(o.as_str(), i);
        }
    }

    let mut indegree = vec![0usize; actions.len()];
    let mut dependents: HashMap<usize, Vec<usize>> = HashMap::new();
    for (i, a) in actions.iter().enumerate() {
        let mut deps: BTreeSet<usize> = BTreeSet::new();
        for inp in &a.inputs {
            if let Some(&j) = producer.get(inp.as_str()) {
                // j == i happens when an action lists its own output as an input; it is not a
                // dependency on anything and would deadlock the queue.
                if j != i {
                    deps.insert(j);
                }
            }
        }
        indegree[i] = deps.len();
        for j in deps {
            dependents.entry(j).or_default().push(i);
        }
    }

    let mut ready: BinaryHeap<Reverse<(String, usize)>> = actions
        .iter()
        .enumerate()
        .filter(|(i, _)| indegree[*i] == 0)
        .map(|(i, a)| Reverse((a.identity.clone(), i)))
        .collect();

    let mut order: Vec<usize> = Vec::with_capacity(actions.len());
    while let Some(Reverse((_, i))) = ready.pop() {
        order.push(i);
        if let Some(ks) = dependents.get(&i) {
            for &k in ks {
                indegree[k] -= 1;
                if indegree[k] == 0 {
                    ready.push(Reverse((actions[k].identity.clone(), k)));
                }
            }
        }
    }

    if order.len() != actions.len() {
        // Loudly, because a silently truncated action list is a graph that builds most of the
        // port and then fails somewhere unrelated.
        die(&format!(
            "graph dump: {} of {} actions ordered; the action graph has a cycle",
            order.len(),
            actions.len()
        ));
    }
    let mut slots: Vec<Option<Action>> = actions.into_iter().map(Some).collect();
    order.into_iter().map(|i| slots[i].take().unwrap()).collect()
}

/// Re-verify the join on whatever the last invocation actually executed.
fn check_against_what_ran(isolation: &str, ran: &[Action], subs: &[(String, String)]) -> usize {
    let mut truth: HashMap<String, Vec<String>> = HashMap::new();
    for line in buck2(isolation, &["log", "what-ran", "--format", "json"]).lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let ev: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let cmd = ev
            .get("reproducer")
            .and_then(|r| r.get("details"))
            .and_then(|d| d.get("command"))
            .and_then(|c| c.as_array());
        if let (Some(cmd), Some(ident)) = (cmd, ev.get("identity").and_then(|i| i.as_str())) {
            truth.insert(
                ident.to_string(),
                cmd.iter()
                    .map(|c| portable(c.as_str().unwrap_or_default(), subs))
                    .collect(),
            );
        }
    }
    if truth.is_empty() {
        eprintln!("  NOTE: nothing ran in the last invocation, so the join went unverified");
        return 0;
    }
    let by_identity: HashMap<&str, &Vec<String>> =
        ran.iter().map(|a| (a.identity.as_str(), &a.argv)).collect();
    let mut common = 0usize;
    let mut bad: Vec<&str> = Vec::new();
    for (ident, argv) in &truth {
        if let Some(mine) = by_identity.get(ident.as_str()) {
            common += 1;
            if *mine != argv {
                bad.push(ident.as_str());
            }
        }
    }
    eprintln!("  verified {}/{} commands against what-ran", common - bad.len(), common);
    for ident in bad.iter().take(3) {
        eprintln!("  MISMATCH {ident}");
    }
    bad.len()
}

/// Every (dir, files) pair under a staged tree, symlinked subdirectories NOT descended into and
/// NOT listed, which is what python's os.walk(followlinks=False) does and what keeps a farm of
/// file links from turning into a walk of the project.
fn walk_files(root: &str, out: &mut Vec<(String, Vec<String>)>) {
    let mut dirs = Vec::new();
    let mut files = Vec::new();
    let rd = match fs::read_dir(root) {
        Ok(rd) => rd,
        Err(_) => return,
    };
    for ent in rd.flatten() {
        let name = match ent.file_name().to_str() {
            Some(n) => n.to_string(),
            None => continue,
        };
        let full = pypath::join2(root, &name);
        if fs::metadata(&full).map(|m| m.is_dir()).unwrap_or(false) {
            dirs.push(name);
        } else {
            files.push(name);
        }
    }
    out.push((root.to_string(), files));
    for name in dirs {
        let sub = pypath::join2(root, &name);
        if !fs::symlink_metadata(&sub).map(|m| m.file_type().is_symlink()).unwrap_or(false) {
            walk_files(&sub, out);
        }
    }
}

fn is_link(p: &str) -> bool {
    fs::symlink_metadata(p).map(|m| m.file_type().is_symlink()).unwrap_or(false)
}

fn main() {
    let raw_argv: Vec<String> = env::args().collect();
    let check_flag = raw_argv.iter().any(|a| a == "--check-against-what-ran");
    let (subs, argv) = parse_placeholders(&raw_argv);
    if argv.len() < 4 {
        die(USAGE);
    }
    let isolation = argv[1].clone();
    let outdir = argv[2].clone();
    let targets: Vec<String> = argv[3..].to_vec();

    // 1. Every action, from ANALYSIS. No build has to have happened for this.
    let query = format!("deps({})", targets.join(" + "));
    let raw = buck2(&isolation, &["aquery", "--output-all-attributes", "--json", &query]);
    let aq: Value = serde_json::from_str(&raw)
        .unwrap_or_else(|e| die(&format!("aquery did not return JSON: {e}")));
    let aq = match aq.as_object() {
        Some(m) => m,
        None => die("aquery did not return a JSON object"),
    };
    drop(raw);

    let attr_str = |attrs: &Value, key: &str| -> String {
        attrs.get(key).and_then(|v| v.as_str()).unwrap_or_default().to_string()
    };

    let mut ran: Vec<Action> = Vec::new();
    for (node, attrs) in aq.iter() {
        let cmd = attr_str(attrs, "cmd");
        if cmd.is_empty() {
            continue; // analysis nodes, and the actions buck2 performs in-process
        }
        let target = match node.split_once("target: `") {
            Some((_, rest)) => rest.split('`').next().unwrap_or(rest),
            None => node.split('`').next().unwrap_or(node),
        };
        let identity = format!(
            "{target} ({} {})",
            attr_str(attrs, "category"),
            attr_str(attrs, "identifier")
        )
        .replace(" )", ")");
        ran.push(Action {
            id: action_id(&identity),
            identity,
            argv: unjoin(&cmd).iter().map(|c| portable(c, &subs)).collect(),
            outputs: Vec::new(),
            inputs: Vec::new(),
            input_targets: Vec::new(),
        });
    }

    // 2. Every buck-out path any command names, and which action produced it.
    let mut referenced_set: BTreeSet<String> = BTreeSet::new();
    for a in &ran {
        for arg in &a.argv {
            for m in pat::buck_out_paths(arg) {
                referenced_set.insert(m);
            }
        }
    }
    let referenced: Vec<String> = referenced_set.into_iter().collect();
    let mut producer: BTreeMap<String, Option<String>> = BTreeMap::new();
    for path in &referenced {
        // `audit output` prints the producing action, or nothing for a path no action claims
        // (a scratch dir, say).
        let out = buck2(&isolation, &["audit", "output", path]);
        let last = out.trim().lines().last().map(|l| l.trim().to_string());
        producer.insert(path.clone(), last);
    }

    // 3. Every action's KIND, so the in-process ones can be told apart. Same query as step 1:
    //    aquery keys its json by the "(target: ..., id: N)" string audit output prints, which is
    //    what joins the two vocabularies.
    let mut kinds: BTreeMap<String, String> = BTreeMap::new();
    let mut node_of_order: Vec<(String, String, String)> = Vec::new();
    let mut node_of: HashMap<(String, String, String), String> = HashMap::new();
    for (node, attrs) in aq.iter() {
        let kind = attr_str(attrs, "kind");
        if !kind.is_empty() {
            kinds.insert(node.clone(), kind);
        }
        // The two vocabularies meet here. `audit output` names an action as
        // "(target: `T`, id: N)"; what-ran names the same one as "T (category identifier)".
        // aquery is the only place that carries both, so it is what joins them.
        if let Some(target) = pat::node_target(node) {
            let category = attr_str(attrs, "category");
            if !category.is_empty() {
                let key = (target, category, attr_str(attrs, "identifier"));
                if !node_of.contains_key(&key) {
                    node_of_order.push(key.clone());
                }
                node_of.insert(key, node.clone());
            }
        }
    }
    let mut node_by_identity: HashMap<String, String> = HashMap::new();
    for key in &node_of_order {
        let (target, category, identifier) = key;
        let node = node_of[key].clone();
        node_by_identity.insert(
            format!("{target} ({category} {identifier})").trim_end().to_string(),
            node.clone(),
        );
        node_by_identity.insert(format!("{target} ({category})"), node);
    }

    let unjoined: Vec<&str> = ran
        .iter()
        .filter(|a| !node_by_identity.contains_key(&a.identity))
        .map(|a| a.identity.as_str())
        .collect();
    if !unjoined.is_empty() {
        eprintln!(
            "  WARNING: {} action(s) did not join to an aquery node, so their outputs cannot be \
             told from their inputs:",
            unjoined.len()
        );
        for ident in unjoined.iter().take(5) {
            eprintln!("    {ident}");
        }
    }

    // 3b. An action's DECLARED inputs, which argv does not always name.
    //
    // Scraping buck-out paths out of the command line works for a compile or a link, where every
    // input is an argument. It fails completely for an action that reads its inputs from a FILE:
    // the prefix passes a manifest and nothing else, so its 5,537 inputs are invisible to argv,
    // and lowering it would run the builder against a staging tree that holds none of them.
    let mut input_targets: HashMap<&str, Vec<String>> = HashMap::new();
    for (node, attrs) in aq.iter() {
        let decl = attr_str(attrs, "buck.all_ineligible_for_dedup_inputs");
        if decl.is_empty() {
            continue;
        }
        let mut seen: Vec<String> = Vec::new();
        for target in pat::declared_input_targets(&decl) {
            // Same spelling the rest of the dump uses: aquery writes the configuration after
            // the label, and everything downstream groups actions by the bare label.
            let target = target.split(" (").next().unwrap_or(&target).to_string();
            if !seen.contains(&target) {
                seen.push(target);
            }
        }
        if !seen.is_empty() {
            input_targets.insert(node.as_str(), seen);
        }
    }

    let mut staged: BTreeMap<String, String> = BTreeMap::new();
    for a in ran.iter_mut() {
        let mut paths: BTreeSet<String> = BTreeSet::new();
        for arg in &a.argv {
            for m in pat::buck_out_paths(arg) {
                paths.insert(m);
            }
        }
        let node = node_by_identity.get(&a.identity);
        // By action, not by target: a target's compile and its archive both name the object
        // file, and only one of them writes it. Both sides being absent counts as EQUAL, which
        // is what the python's dict.get comparison does.
        let owns = |p: &String| -> bool {
            producer.get(p).cloned().flatten().as_ref() == node.map(|n| n as &String)
        };
        for p in paths {
            if owns(&p) {
                a.outputs.push(p);
            } else {
                a.inputs.push(p);
            }
        }
        let own = a.target().to_string();
        a.input_targets = node
            .and_then(|n| input_targets.get(n.as_str()))
            .map(|v| v.iter().filter(|t| **t != own).cloned().collect())
            .unwrap_or_default();
        for p in &a.inputs {
            let prod = producer.get(p).cloned().flatten().unwrap_or_default();
            let kind = kinds.get(&prod).cloned().unwrap_or_default();
            if kind.to_lowercase() != "run" {
                staged.insert(p.clone(), prod); // an in-process artifact: it has to travel as DATA
            }
        }
    }

    // 4a. Which artifact is which TARGET's output, from analysis: `targets --show-full-output`
    //     answers it without building, where the build report would have required exactly the
    //     build this dump exists to avoid.
    let mut target_outputs_order: Vec<String> = Vec::new();
    let mut target_outputs: HashMap<String, Vec<String>> = HashMap::new();
    let root = env::current_dir()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| ".".to_string());
    let mut args: Vec<&str> = vec!["targets", "--show-full-output"];
    for t in &targets {
        args.push(t.as_str());
    }
    for line in buck2(&isolation, &args).lines() {
        let line = line.trim_start();
        let Some(sp) = line.find(char::is_whitespace) else { continue };
        let label = &line[..sp];
        let path = line[sp..].trim();
        if path.is_empty() {
            continue;
        }
        // Project-relative, like every other path in the graph.
        let prefix = format!("{root}/");
        let path = path.strip_prefix(&prefix).unwrap_or(path).to_string();
        if !target_outputs.contains_key(label) {
            target_outputs_order.push(label.to_string());
        }
        target_outputs.entry(label.to_string()).or_default().push(path);
    }

    // 4b. A target's own DEFAULT output can also be in-process (a staged lib directory that no
    //     command writes and no command consumes, so nothing above has seen it).
    let written: HashSet<&String> = ran.iter().flat_map(|a| a.outputs.iter()).collect();
    for label in &target_outputs_order {
        for p in &target_outputs[label] {
            if !written.contains(p) && !staged.contains_key(p) {
                staged.insert(p.clone(), producer.get(p).cloned().flatten().unwrap_or_default());
            }
        }
    }
    drop(written);

    // 4c. MATERIALIZE what has to travel as data. By PROVIDER, through BXL, not by building
    //     targets: `buck2 build <target>` produces a target's DEFAULT output and nothing else,
    //     and these artifacts hang off other providers. darling-config.h is action id 2 of
    //     //darwin/include:cider_config, reachable through no subtarget, and it simply went
    //     missing when a consumer came to include it.
    eprintln!("materializing in-process artifacts through BXL");
    let mut bxl_args: Vec<String> = vec![
        "--isolation-dir".into(),
        isolation.clone(),
        "bxl".into(),
        "//buck/bxl/materialize.bxl:main".into(),
        "--".into(),
    ];
    for t in &targets {
        bxl_args.push("--targets".into());
        bxl_args.push(t.clone());
    }
    let bxl = Command::new("buck2")
        .args(&bxl_args)
        .output()
        .unwrap_or_else(|e| die(&format!("buck2 bxl could not be run: {e}")));
    if !bxl.status.success() {
        // THE WHOLE STDERR, not a tail. When a materialization fails buck2 ends with a LIST of
        // every target it could not build: that list is thousands of characters, so a tail is
        // all list and the actual cause, which buck2 prints FIRST, is cut off. Three skeleton
        // graph runs were diagnosed from a truncated message that ended mid word.
        eprintln!("{}", String::from_utf8_lossy(&bxl.stderr));
        die("materialization failed");
    }
    eprintln!("  {}", String::from_utf8_lossy(&bxl.stdout).trim());

    // 4. Copy the in-process artifacts out, dereferenced.
    let staged_dir = pypath::join2(&outdir, "staged");
    let _ = fs::create_dir_all(&staged_dir);
    let mut copied: BTreeMap<String, String> = BTreeMap::new();
    let mut trees: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
    let mut tree_deps: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut missing: Vec<String> = Vec::new();
    for path in staged.keys() {
        let p = Path::new(path);
        if !p.exists() && !is_link(path) {
            // Collected and made FATAL below, since it stopped being hypothetical. A graph
            // missing an in-process artifact still exits 0 and still lowers; the failure lands
            // an hour later as a runner script or a header that is simply not there. One BXL
            // change dropped 30 of them and the build reported success.
            missing.push(path.clone());
            continue;
        }
        if p.is_dir() {
            // A staged include root is a farm of SYMLINKS into the project -- 3,591 of them and
            // not one real file, in the SDK root. Recording where each one points, rather than
            // copying what it points AT, keeps the graph to names: it drops ~200 MB of
            // duplicated headers, and it means a source edit does not change the graph at all.
            let mut links: Vec<(String, String)> = Vec::new();
            let mut real: Vec<String> = Vec::new();
            let mut walked = Vec::new();
            walk_files(path, &mut walked);
            for (dirpath, files) in &walked {
                for name in files {
                    let full = pypath::join2(dirpath, name);
                    let rel = pypath::relpath(&full, path);
                    if is_link(&full) {
                        // Verbatim, so the recreated link resolves exactly as buck2's did: the
                        // staged directory sits at the same depth in the consumer's tree.
                        match fs::read_link(&full).ok().and_then(|t| t.to_str().map(String::from)) {
                            Some(t) => links.push((rel, t)),
                            None => die(&format!("non-UTF-8 symlink target under {path}")),
                        }
                    } else {
                        real.push(rel);
                    }
                }
            }
            if !real.is_empty() {
                // Content buck2 generated rather than linked (a mig runner script, a written
                // header). It has to travel as data, but it comes from the RULES, not from the
                // sources, so it does not make the graph source-dependent.
                let dest = pypath::join2(&staged_dir, &pat::sanitise(path));
                for rel in &real {
                    let d = pypath::join2(&dest, rel);
                    let _ = fs::create_dir_all(pypath::dirname(&d));
                    if let Err(e) = fs::copy(pypath::join2(path, rel), &d) {
                        die(&format!("could not copy {path}/{rel}: {e}"));
                    }
                }
                copied.insert(path.clone(), pypath::relpath(&dest, &outdir));
            }
            // Where those links POINT, resolved here rather than in Nix. A link value is
            // relative and full of "..", and the consumer has to know which buck-out artifacts a
            // farm depends on. Doing it in Nix cost 25% of a two-minute evaluation.
            let mut deps: BTreeSet<String> = BTreeSet::new();
            for (rel, target) in &links {
                let here = pypath::join2(path, rel);
                let r = pypath::normpath(&pypath::join2(pypath::dirname(&here), target));
                if r.starts_with("buck-out/") {
                    deps.insert(r);
                }
            }
            trees.insert(path.clone(), links);
            if !deps.is_empty() {
                tree_deps.insert(path.clone(), deps.into_iter().collect());
            }
        } else {
            let dest = pypath::join2(&staged_dir, &pat::sanitise(path));
            let _ = fs::create_dir_all(pypath::dirname(&dest));
            if is_link(path) && !p.exists() {
                let t = fs::read_link(path)
                    .ok()
                    .and_then(|t| t.to_str().map(String::from))
                    .unwrap_or_else(|| die(&format!("non-UTF-8 symlink target: {path}")));
                trees.insert(path.clone(), vec![(String::new(), t)]);
                continue;
            }
            if let Err(e) = fs::copy(path, &dest) {
                die(&format!("could not copy {path}: {e}"));
            }
            copied.insert(path.clone(), pypath::relpath(&dest, &outdir));
        }
    }

    // The link MAPS travel as files, not as JSON, and the reason is measured. Inline they were
    // 3,581,461 entries and 499 MB of a 1.62 GB graph.json, and builtins.fromJSON is strict, so
    // every evaluation parsed all of them into Nix values whether or not a tree was ever staged.
    //
    // A tab separates the two columns, so neither field may contain one, and neither may contain
    // a newline. Nothing in buck2's output does. Assert rather than trust it: a corrupted table
    // would surface as a dangling symlink an hour into a build.
    //
    // NAMED BY CONTENT, not by farm index. Measured on the real output: 5,254 farms wrote 10,508
    // files and 125.5 MB, but only 1,316 of those files were distinct, so 96 percent of the data
    // output was the same table staged again under another number. Two farms that stage the same
    // links get one file here, which takes the data output to about 5 MB.
    let mut tree_index: BTreeMap<String, Map<String, Value>> = BTreeMap::new();
    let mut written_tables: HashMap<(String, String), String> = HashMap::new();

    for (path, links) in &trees {
        let mut entry = Map::new();
        if links.is_empty() {
            entry.insert("n".into(), Value::from(0u64));
            tree_index.insert(path.clone(), entry);
            continue;
        }
        for (name, target) in links {
            if name.contains('\t') || name.contains('\n') || target.contains('\t') || target.contains('\n') {
                die(&format!(
                    "link name or target holds a tab or newline: {path} {name:?} -> {target:?}"
                ));
            }
        }
        let _ = fs::create_dir_all(pypath::join2(&outdir, "treelinks"));

        // DERIVABLE TARGETS. A link target is almost always ("../" * up) + prefix + the link
        // NAME itself, with the name repeated verbatim at the end, and measured on the real
        // tables the two variables are constant per tree: in the largest, all 8,687 links have
        // (up minus the name depth) equal to 8 and the same prefix. Storing the target anyway
        // made treelinks 467 MB, of which the names alone are 33 percent. So when the rule
        // holds, write names ONLY and let the staging script rebuild the target; when it does
        // not, fall back to the explicit two-column form so nothing is lost.
        let mut derive: Option<(i64, String)> = None;
        let mut derivable = true;
        for (name, target) in links {
            let mut up: i64 = 0;
            let mut rest = target.as_str();
            while let Some(r) = rest.strip_prefix("../") {
                up += 1;
                rest = r;
            }
            if !rest.ends_with(name.as_str()) || rest.starts_with('/') {
                derivable = false;
                break;
            }
            let k = up - name.matches('/').count() as i64;
            let pre = rest[..rest.len() - name.len()].to_string();
            match &derive {
                None => derive = Some((k, pre)),
                Some((dk, dp)) => {
                    if (k, &pre) != (*dk, dp) {
                        derivable = false;
                        break;
                    }
                }
            }
        }
        let derive = if derivable { derive } else { None };

        // PROVE it before relying on it. The rule above is derived from the data, so a farm that
        // satisfies it by accident, or a future change to how targets are built, must not be
        // able to silently write a table that stages the wrong tree. Reconstructing every target
        // here is the same arithmetic the staging script will do.
        if let Some((k, prefix)) = &derive {
            for (name, target) in links {
                let ups = (k + name.matches('/').count() as i64).max(0) as usize;
                let rebuilt = format!("{}{prefix}{name}", "../".repeat(ups));
                if &rebuilt != target {
                    die(&format!(
                        "treelinks: derived target does not reproduce the real one for {path}: \
                         {name:?} is {target:?} but the rule gives {rebuilt:?}"
                    ));
                }
            }
        }

        let mut sorted: Vec<&(String, String)> = links.iter().collect();
        sorted.sort_by(|a, b| a.0.cmp(&b.0));
        let table: String = if derive.is_some() {
            sorted.iter().map(|(n, _)| format!("{n}\n")).collect()
        } else {
            sorted.iter().map(|(n, t)| format!("{n}\t{t}\n")).collect()
        };
        // The directories to make, ONCE and sorted, so the staging script does not run a dirname
        // subshell per link at BUILD time as well.
        let dirs: BTreeSet<&str> = links
            .iter()
            .map(|(n, _)| pypath::dirname(n))
            .filter(|d| !d.is_empty())
            .collect();
        let dirs_text: String = dirs.iter().map(|d| format!("{d}\n")).collect();

        entry.insert("n".into(), Value::from(links.len() as u64));
        entry.insert(
            "table".into(),
            Value::String(write_once(&outdir, &table, ".tsv", &mut written_tables)),
        );
        entry.insert(
            "dirs".into(),
            Value::String(write_once(&outdir, &dirs_text, ".dirs", &mut written_tables)),
        );
        if let Some((k, prefix)) = &derive {
            // The reader is told HOW to read the table here rather than by a header line in it,
            // so the staging script never parses a format marker.
            entry.insert("k".into(), Value::from(*k));
            entry.insert("prefix".into(), Value::String(prefix.clone()));
        }
        tree_index.insert(path.clone(), entry);
    }

    if !missing.is_empty() {
        for path in missing.iter().take(20) {
            eprintln!("  MISSING artifact {path}");
        }
        if missing.len() > 20 {
            eprintln!("  ... and {} more", missing.len() - 20);
        }
        die(&format!(
            "{} in-process artifact(s) were never materialised. Each one has to be reachable \
             from a provider that buck/bxl/materialize.bxl ensures, which means the rule making \
             it must declare it through InProcInfo.",
            missing.len()
        ));
    }

    // WHICH PROJECT FILES EACH TARGET READS IS NOT COMPUTED HERE. It is the only answer that
    // depends on source file CONTENTS, because a quoted include is found by parsing #include
    // "..." out of the file, and this dump runs against a SKELETON when the caller asks for one,
    // which the minimal endpoint does, so that editing a .c cannot rerun it. That pass is the
    // sources binary of this crate and runs against the real tree, reading this graph plus the
    // link tables.
    let ncommands = ran.len();
    let coarse = coarse_pin_map(&ran);

    // Anything still pointing into the store is a machine dependency: name it rather than
    // letting it travel silently.
    let mut leftover: BTreeSet<String> = BTreeSet::new();
    for a in &ran {
        for s in &a.argv {
            for m in pat::store_paths(s) {
                leftover.insert(m);
            }
        }
    }

    let ordered = deterministic_action_order(ran);

    let mut graph = Map::new();
    graph.insert("targets".into(), strs(&targets));
    // Deterministically ordered, and still topological: see deterministic_action_order.
    graph.insert(
        "actions".into(),
        Value::Array(ordered.iter().map(|a| a.to_value()).collect()),
    );
    graph.insert("staged".into(), map_of_strings(&copied));
    // {staged tree: {n, table, dirs}} -- the links themselves are in the table file.
    graph.insert(
        "stagedTrees".into(),
        Value::Object(
            tree_index
                .iter()
                .map(|(k, v)| (k.clone(), Value::Object(v.clone())))
                .collect(),
        ),
    );
    // {staged tree: [buck-out paths its links resolve to]}, precomputed.
    graph.insert(
        "stagedTreeDeps".into(),
        Value::Object(tree_deps.iter().map(|(k, v)| (k.clone(), strs(v))).collect()),
    );
    graph.insert(
        "producers".into(),
        Value::Object(
            producer
                .iter()
                .map(|(k, v)| {
                    (
                        k.clone(),
                        match v {
                            Some(s) => Value::String(s.clone()),
                            None => Value::Null,
                        },
                    )
                })
                .collect(),
        ),
    );
    // {target label: pin} for the buck-src pins that may be merged into one derivation each.
    // Only pins in NO dependency cycle appear; see coarse_pin_map.
    graph.insert("coarsePinOf".into(), map_of_strings(&coarse));
    graph.insert("kinds".into(), map_of_strings(&kinds));
    graph.insert(
        "targetOutputs".into(),
        Value::Object(
            target_outputs_order
                .iter()
                .map(|l| (l.clone(), strs(&target_outputs[l])))
                .collect(),
        ),
    );
    let mut placeholders: Vec<String> = subs.iter().map(|(_, n)| n.clone()).collect();
    placeholders.sort();
    graph.insert("placeholders".into(), strs(&placeholders));

    for m in &leftover {
        eprintln!("  NOTE: store path left in the graph: {m}");
    }

    let text = pyjson::dumps_indent2_sorted(&Value::Object(graph));
    let mut fh = fs::File::create(pypath::join2(&outdir, "graph.json"))
        .unwrap_or_else(|e| die(&format!("cannot write graph.json: {e}")));
    if fh.write_all(text.as_bytes()).and_then(|_| fh.write_all(b"\n")).is_err() {
        die("cannot write graph.json");
    }
    drop(fh);

    println!(
        "graph: {ncommands} command action(s), {} staged artifact(s), {} referenced path(s)",
        copied.len(),
        referenced.len()
    );
    let total_links: u64 = tree_index
        .values()
        .map(|t| t["n"].as_u64().unwrap_or(0))
        .sum();
    println!(
        "  {} staged tree(s) holding {total_links} link(s), written as tables beside the graph \
         rather than inside it",
        tree_index.len()
    );
    if !written_tables.is_empty() {
        let slots = 2 * tree_index.values().filter(|t| t["n"].as_u64().unwrap_or(0) != 0).count();
        println!(
            "  {} distinct table file(s) for {slots} farm slots, named by content so identical \
             farms share one file",
            written_tables.len()
        );
    }

    // The join is only sound while no argument contains the separator. Check it against whatever
    // the last invocation ran rather than assuming it stays true.
    if check_flag && check_against_what_ran(&isolation, &ordered, &subs) > 0 {
        eprintln!("  aquery's rendering no longer round-trips; the dump is not trustworthy");
        std::process::exit(1);
    }
}

fn map_of_strings(m: &BTreeMap<String, String>) -> Value {
    Value::Object(m.iter().map(|(k, v)| (k.clone(), Value::String(v.clone()))).collect())
}

/// Write text once under a content derived name and return its relative path.
fn write_once(
    outdir: &str,
    text: &str,
    ext: &str,
    written: &mut HashMap<(String, String), String>,
) -> String {
    let key = (ext.to_string(), text.to_string());
    if let Some(rel) = written.get(&key) {
        return rel.clone();
    }
    let rel = format!("treelinks/{}{ext}", sha256_hex16(text.as_bytes()));
    written.insert(key, rel.clone());
    if let Err(e) = fs::write(pypath::join2(outdir, &rel), text) {
        die(&format!("cannot write {rel}: {e}"));
    }
    rel
}
