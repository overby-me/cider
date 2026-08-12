//! REGENERATE EVERY libSystem MEMBER DYLIB BLOCK FROM THE REFERENCE GRAPH.
//!
//! THE RUST REWRITE of the python regen-dylibs (#98). It is Rust because the member list comes
//! from read_edges over the frozen 131 MB build.ninja, which is src/ninjaref.rs, the live surface
//! of gen-buck-from-ninja that this tool used to import.
//!
//! Two kinds of member, and getting them mixed up registers a target twice:
//!   ones whose firstpass block was GENERATED inside a `# BEGIN generated: <t> dylibs` marker, so
//!     the whole pair is regenerated together;
//!   ones whose firstpass block is HAND-WRITTEN keep it, and only the final pass is generated.
//!
//! IT IS A DRIVER: the generation itself is still scripts/gen-buck-from-ninja.py, which this runs
//! as a subprocess exactly as the python did, and which is the last big file on the port list.
//! When that moves, this call site is the only thing that changes.
//!
//! Usage: cider-regen-dylibs [--dry-run]

#[path = "ninjaref.rs"]
mod ninjaref;
use ninjaref::{basename, firstpass_stem, read_edges, repo_root, walk_buck_files};

use std::collections::BTreeSet;
use std::fs;
use std::io::Write;
use std::process::{Command, ExitCode};

/// Fixtures, not libSystem members.
const NOT_MEMBERS: &[&str] = &["a", "b"];

/// Nothing is hand-tuned any more: the two things that used to need it are expressed in the
/// generator and in extra-deps.json. Kept for the next case that needs it.
const HAND_TUNED: &[&str] = &[];

fn buck_files(root: &str) -> Vec<String> {
    walk_buck_files(root).into_iter().map(|(_pkg, p)| p).collect()
}

/// (start, end) of every `# BEGIN generated: <x>` .. `# END generated: <x>` pair.
fn marker_spans(text: &str) -> Vec<(usize, usize)> {
    let mut spans = Vec::new();
    let mut i = 0;
    while i < text.len() {
        let at = match text[i..].find("# BEGIN generated: ") {
            Some(a) => i + a,
            None => break,
        };
        // ^ in the python pattern: the marker must start a line.
        if at != 0 && text.as_bytes()[at - 1] != b'\n' {
            i = at + 1;
            continue;
        }
        let after = at + "# BEGIN generated: ".len();
        let line_end = match text[after..].find('\n') {
            Some(k) => after + k,
            None => break,
        };
        let name = &text[after..line_end];
        // (.+) needs at least one character.
        if !name.is_empty() {
            let needle = format!("# END generated: {name}\n");
            if let Some(k) = text[line_end + 1..].find(&needle) {
                spans.push((at, line_end + 1 + k));
            }
        }
        i = line_end + 1;
    }
    spans
}

/// Every circular libSystem member, from the reference graph rather than from what the BUCK files
/// happen to contain: a member whose block was just deleted is exactly the one that needs
/// regenerating, and scanning the files would skip it.
fn members(root: &str) -> Result<Vec<String>, String> {
    let mut found: BTreeSet<String> = BTreeSet::new();
    for e in read_edges(root)? {
        for o in &e.outputs {
            if !o.contains('/') {
                continue;
            }
            if let Some(stem) = firstpass_stem(basename(o)) {
                found.insert(stem.to_string());
            }
        }
    }
    for n in NOT_MEMBERS.iter().chain(HAND_TUNED.iter()) {
        found.remove(*n);
    }
    Ok(found.into_iter().collect())
}

/// cmake targets that already own a `<t> dylibs` block. Libraries outside the circular cluster
/// are not members, so enumerating members misses them, and a stale label in one of their blocks
/// breaks every consumer.
fn generated_dylib_targets(root: &str) -> BTreeSet<String> {
    let mut found = BTreeSet::new();
    for f in buck_files(root) {
        let text = match fs::read_to_string(&f) {
            Ok(t) => t,
            Err(_) => continue,
        };
        for (start, _end) in marker_spans(&text) {
            let after = start + "# BEGIN generated: ".len();
            let line_end = match text[after..].find('\n') {
                Some(k) => after + k,
                None => continue,
            };
            let name = &text[after..line_end];
            // (\S+) dylibs, so exactly one non-space token followed by " dylibs".
            if let Some(t) = name.strip_suffix(" dylibs") {
                if !t.is_empty() && !t.chars().any(|c| c.is_whitespace()) {
                    found.insert(t.to_string());
                }
            }
        }
    }
    found
}

/// (targets to regenerate as a pair, targets where only the final is generated).
fn classify(root: &str) -> Result<(Vec<String>, Vec<String>), String> {
    let mut hand: BTreeSet<String> = BTreeSet::new();
    for f in buck_files(root) {
        let text = match fs::read_to_string(&f) {
            Ok(t) => t,
            Err(_) => continue,
        };
        let spans = marker_spans(&text);
        let b = text.as_bytes();
        let mut i = 0;
        while let Some(at) = text[i..].find("name = \"") {
            let start = i + at + "name = \"".len();
            i = start;
            let mut j = start;
            // [A-Za-z0-9_]+ here, NOT the dotted class the registries use.
            while j < b.len() && (b[j].is_ascii_alphanumeric() || b[j] == b'_') {
                j += 1;
            }
            let run = &text[start..j];
            if !run.ends_with("_firstpass") {
                continue;
            }
            if !(j + 1 < b.len() && b[j] == b'"' && b[j + 1] == b',') {
                continue;
            }
            let name = &run[..run.len() - "_firstpass".len()];
            // The python tests m.start(), which is where `name = "` begins, against the spans.
            let match_start = start - "name = \"".len();
            if !spans.iter().any(|(a, e)| *a <= match_start && match_start < *e) {
                hand.insert(name.to_string());
            }
        }
    }
    let mut all: BTreeSet<String> = members(root)?.into_iter().collect();
    all.extend(generated_dylib_targets(root));
    let pair: Vec<String> = all.iter().filter(|t| !hand.contains(*t)).cloned().collect();
    let hand_only: Vec<String> = all.iter().filter(|t| hand.contains(*t)).cloned().collect();
    Ok((pair, hand_only))
}

fn snapshot(root: &str) -> Vec<(String, String)> {
    buck_files(root)
        .into_iter()
        .map(|f| {
            let t = fs::read_to_string(&f).unwrap_or_default();
            (f, t)
        })
        .collect()
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let root = match repo_root() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let (pair, hand) = match classify(&root) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    println!("pair ({}): {}", pair.len(), pair.join(" "));
    println!("final-only ({}): {}", hand.len(), hand.join(" "));
    if argv.iter().any(|a| a == "--dry-run") {
        return ExitCode::SUCCESS;
    }

    let gen = format!("{root}/scripts/gen-buck-from-ninja.py");
    // Iterate to a FIXPOINT, for the same reason the build itself needs two passes: a target can
    // only name siblings whose targets already exist, and each pass both reads and writes the
    // same files, so one round leaves whatever came later in the order unresolved.
    let mut before = snapshot(&root);
    for pass_no in 1..=5 {
        for (args, group) in [
            (vec!["--dylibs", "--write"], &pair),
            (vec!["--dylibs", "--final-only", "--write"], &hand),
        ] {
            if group.is_empty() {
                continue;
            }
            let out = Command::new(&gen)
                .args(&args)
                .args(group.iter())
                .current_dir(&root)
                .output();
            let out = match out {
                Ok(o) => o,
                Err(e) => {
                    eprintln!("cannot run {gen}: {e}");
                    return ExitCode::FAILURE;
                }
            };
            if pass_no == 2 {
                let _ = std::io::stderr().write_all(&out.stderr);
            }
            if !out.status.success() {
                // Loudly: a generator crash mid-list leaves the remaining members untouched,
                // which reads exactly like "nothing to do".
                let _ = std::io::stderr().write_all(&out.stderr);
                eprintln!("FAILED (pass {pass_no}): {} {}", args.join(" "), group.join(" "));
                return ExitCode::from(out.status.code().unwrap_or(1) as u8);
            }
        }
        let after = snapshot(&root);
        if after == before {
            eprintln!("converged after {pass_no} pass(es)");
            break;
        }
        before = after;
    }
    let _ = Command::new(format!("{root}/scripts/buck-fix-loads.nu")).current_dir(&root).status();
    ExitCode::SUCCESS
}
