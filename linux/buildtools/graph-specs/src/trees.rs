//! {staged tree: [(link name, link target)]} back out of the per farm tables.
//!
//! TWO FORMS, because the dump writes names only when a target is derivable from its name and
//! falls back to explicit two columns when it is not. Reading the wrong one would not fail, it
//! would silently resolve every link to nonsense, so the form is taken from the INDEX rather
//! than guessed from the line.
//!
//! SHARED BY THREE BINARIES of this crate: the sources pass, which asks what each group reads;
//! the equivalence check, which compares two dumps by meaning; and the codegen closure, which
//! asks which files must keep their real bytes. All three had their own copy of these twenty
//! lines at some point, and a copy of a rule whose failure mode is SILENT is exactly the drift
//! this crate keeps refusing to accept.
//!
//! THE ORDER IS THE GRAPH ORDER, and the return type is a Vec rather than a map on purpose: one
//! caller wants a HashMap, another a BTreeMap, and building the map here would force a choice
//! that changes iteration order for somebody.

use serde_json::{Map, Value};
use std::fs;

pub fn read_trees(graph: &Value, data: &str) -> Result<Vec<(String, Vec<(String, String)>)>, String> {
    let empty = Map::new();
    let staged_trees = graph.get("stagedTrees").and_then(|v| v.as_object()).unwrap_or(&empty);
    let mut out: Vec<(String, Vec<(String, String)>)> = Vec::new();
    for (path, meta) in staged_trees {
        let mut links: Vec<(String, String)> = Vec::new();
        let n = meta.get("n").and_then(|v| v.as_i64()).unwrap_or(0);
        if n > 0 {
            let table = meta.get("table").and_then(|v| v.as_str()).unwrap_or("");
            let full = format!("{data}/{table}");
            // The python raises SystemExit(2) with this wording; both callers print it and exit 2.
            if !std::path::Path::new(&full).exists() {
                return Err(format!("missing table {full}"));
            }
            let text = match fs::read_to_string(&full) {
                Ok(t) => t,
                Err(e) => return Err(format!("cannot read {full}: {e}")),
            };
            let lines: Vec<&str> = if text.is_empty() {
                Vec::new()
            } else {
                text.split_inclusive('\n').collect()
            };
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
        out.push((path.clone(), links));
    }
    Ok(out)
}
