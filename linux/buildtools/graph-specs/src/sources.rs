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
#[allow(dead_code)]
mod sha256;
// SHARED with the equivalence check and the codegen closure: one reader for the farm tables.
#[path = "trees.rs"]
mod trees;
// THE ANSWER ITSELF, split out so the checks that verify it can use the same code rather than
// a second implementation of the same rule. See src/srcset.rs.
#[path = "srcset.rs"]
mod srcset;

use serde_json::{Map, Value};
use sha256::sha256_hex16;
use srcset::{group_of, UNGROUPED};
use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::ExitCode;

fn die(msg: String) -> ExitCode {
    eprintln!("{msg}");
    ExitCode::from(2)
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


    // THE COMPUTATION LIVES IN srcset.rs, so the checks that verify this answer run the same
    // code rather than a second implementation of the same rule.
    let trees = match trees::read_trees(&graph, data) {
        Ok(v) => v,
        Err(e) => return die(e),
    };
    let per_target = srcset::target_sources(&graph, &trees, data);

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

