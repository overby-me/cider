//! THE LIVE SURFACE OF scripts/gen-buck-from-ninja.py, and nothing else.
//!
//! That file is 2,508 lines, of which about 182 are read by other tools: the reference build
//! edges, the two registries that say which dylibs are already declared in BUCK files, and the
//! upward-dependency rule. The other ~2,326 lines emit BUCK from ninja and are a separate
//! problem. This module is that live surface, in Rust, so the tools that used to import the
//! python can be ported one at a time.
//!
//! WHAT IT READS. result-graph-ref/build.ninja, the frozen cmake-era reference: 131 MB and
//! 362,663 lines. It is a store symlink, so it dies at the next GC, which is exactly why every
//! consumer of it is on the port-or-archive list. Parsing it is a line loop and belongs in Rust
//! rather than nushell for the reason the port already measured: a nushell character loop over
//! this file would take an hour.
//!
//! THE ORDER OF THE BUCK WALK IS LOAD BEARING, which is why walk_buck_files is a pre-order DFS in
//! readdir order rather than anything tidier. Both registries assign into a map as they go, so a
//! duplicate key is decided by WHICH FILE IS REACHED FIRST, and os.walk yields the directory
//! itself and then recurses into its subdirectories in scandir order. A different order silently
//! resolves a sibling to a different label.

#![allow(dead_code)]

use std::collections::HashMap;
use std::fs;

pub const SKIP_DIRS: &[&str] = &["buck-out", ".git", ".jj", ".direnv", "build"];

pub struct Edge {
    pub outputs: Vec<String>,
    pub rule: String,
    pub inputs: Vec<String>,
    pub vars: HashMap<String, String>,
}

/// The repo root. The pythons took it from __file__; a binary in the store cannot, so it is
/// $CIDER_REPO, else the working directory, and it is checked rather than assumed.
pub fn repo_root() -> Result<String, String> {
    let root = match std::env::var("CIDER_REPO") {
        Ok(v) if !v.is_empty() => v,
        _ => std::env::current_dir()
            .map_err(|e| format!("cannot read the working directory: {e}"))?
            .to_string_lossy()
            .into_owned(),
    };
    let root = root.trim_end_matches('/').to_string();
    if !std::path::Path::new(&format!("{root}/flake.nix")).exists() {
        return Err(format!(
            "{root} does not look like the cider tree (no flake.nix).\n\
             Run this from the repo root, or set CIDER_REPO."
        ));
    }
    Ok(root)
}

/// Parse build.ninja into edges, exactly the way read_edges does.
pub fn read_edges(root: &str) -> Result<Vec<Edge>, String> {
    let path = format!("{root}/result-graph-ref/build.ninja");
    let text = fs::read_to_string(&path).map_err(|e| {
        format!("cannot read {path}: {e}\nresult-graph-ref is a store symlink; a GC removes it.")
    })?;
    let mut edges: Vec<Edge> = Vec::new();
    let mut have_cur = false;
    for line in text.split('\n') {
        if let Some(rest) = line.strip_prefix("build ") {
            let (head, rest) = match rest.find(": ") {
                Some(i) => (&rest[..i], &rest[i + 2..]),
                None => (rest, ""),
            };
            let (rule, inputs) = match rest.find(' ') {
                Some(i) => (&rest[..i], &rest[i + 1..]),
                None => (rest, ""),
            };
            let outs_part = head.split(" | ").next().unwrap_or("");
            edges.push(Edge {
                outputs: outs_part.split_whitespace().map(|s| s.to_string()).collect(),
                rule: rule.to_string(),
                inputs: inputs
                    .split_whitespace()
                    .filter(|i| *i != "|" && *i != "||")
                    .map(|s| s.to_string())
                    .collect(),
                vars: HashMap::new(),
            });
            have_cur = true;
        } else if have_cur && line.starts_with("  ") && line.contains(" = ") {
            let t = line.trim();
            if let Some(i) = t.find(" = ") {
                let k = &t[..i];
                // Undo NINJA own escaping before anything else looks at the value: it writes a
                // literal $ as $$, and CoreFoundation link carries
                // -Wl,-alias,_OBJC_CLASS_$___NSCFConstantString, so passing the escape through
                // hands ld64 a symbol name that does not exist.
                let v = t[i + 3..].replace("$$", "$").replace("$:", ":");
                if let Some(e) = edges.last_mut() {
                    e.vars.insert(k.to_string(), v);
                }
            }
        } else if line.trim().is_empty() {
            have_cur = false;
        }
    }
    Ok(edges)
}

/// Every BUCK file, in os.walk order: the directory itself, then its subdirectories in readdir
/// order. Returns (package, absolute path).
pub fn walk_buck_files(root: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    walk_dir(root, root, &mut out);
    out
}

fn walk_dir(root: &str, dir: &str, out: &mut Vec<(String, String)>) {
    let rd = match fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return,
    };
    let mut dirs: Vec<String> = Vec::new();
    let mut has_buck = false;
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let p = format!("{dir}/{name}");
        // os.walk asks entry.is_dir(), which FOLLOWS the link, and then refuses to descend into
        // a link. Both halves matter: a symlinked directory is neither walked nor counted as a
        // file.
        if fs::metadata(&p).map(|m| m.is_dir()).unwrap_or(false) {
            if !SKIP_DIRS.contains(&name.as_str())
                && !fs::symlink_metadata(&p).map(|m| m.file_type().is_symlink()).unwrap_or(false)
            {
                dirs.push(name);
            }
        } else if name == "BUCK" {
            has_buck = true;
        }
    }
    if has_buck {
        let pkg = if dir == root {
            ".".to_string()
        } else {
            dir[root.len() + 1..].to_string()
        };
        out.push((pkg, format!("{dir}/BUCK")));
    }
    for d in dirs {
        walk_dir(root, &format!("{dir}/{d}"), out);
    }
}

// ---------------------------------------------------------------- the two registries

fn is_name_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'.' || c == b'-'
}

/// The run of [A-Za-z0-9_.-] starting at i, and where it ends.
fn name_run(b: &[u8], i: usize) -> usize {
    let mut j = i;
    while j < b.len() && is_name_char(b[j]) {
        j += 1;
    }
    j
}

/// `,\s*\n\s*` : whitespace only, and at least one newline in it.
fn newline_gap(b: &[u8], mut i: usize) -> Option<usize> {
    let mut saw_nl = false;
    while i < b.len() && (b[i] as char).is_ascii_whitespace() {
        if b[i] == b'\n' {
            saw_nl = true;
        }
        i += 1;
    }
    if saw_nl {
        Some(i)
    } else {
        None
    }
}

fn quoted_at(text: &str, i: usize) -> Option<(String, usize)> {
    let b = text.as_bytes();
    if i >= b.len() || b[i] != b'"' {
        return None;
    }
    let end = text[i + 1..].find('"')? + i + 1;
    Some((text[i + 1..end].to_string(), end + 1))
}

/// firstpass NAME to buck label, for every firstpass dylib already declared.
///
/// Keyed by BOTH the target stem and the artifact stem, because they diverge: the Security
/// framework target is Security_firstpass while what a consumer links is
/// libSecurity_x86_64_firstpass.dylib.
pub fn firstpass_registry(root: &str) -> HashMap<String, String> {
    let mut reg: HashMap<String, String> = HashMap::new();
    for (pkg, path) in walk_buck_files(root) {
        let text = match fs::read_to_string(&path) {
            Ok(t) => t,
            Err(_) => continue,
        };
        let b = text.as_bytes();
        // Pass one: name = "<x>_firstpass", followed by dylib_name on a later line.
        let mut i = 0;
        while let Some(at) = text[i..].find("name = \"") {
            let start = i + at + "name = \"".len();
            i = start;
            let end = name_run(b, start);
            let run = &text[start..end];
            if end < b.len() && b[end] == b'"' && run.ends_with("_firstpass") {
                let stem_name = &run[..run.len() - "_firstpass".len()];
                if end + 1 < b.len() && b[end + 1] == b',' {
                    if let Some(j) = newline_gap(b, end + 2) {
                        if text[j..].starts_with("dylib_name = \"") {
                            if let Some((dylib, _)) = quoted_at(&text, j + "dylib_name = ".len()) {
                                let label = format!("//{pkg}:{stem_name}_firstpass");
                                reg.insert(stem_name.to_string(), label.clone());
                                let stem = dylib
                                    .strip_prefix("lib")
                                    .unwrap_or(&dylib)
                                    .to_string();
                                let stem = stem.strip_suffix(".dylib").unwrap_or(&stem).to_string();
                                let stem =
                                    stem.strip_suffix("_firstpass").unwrap_or(&stem).to_string();
                                reg.insert(stem, label);
                            }
                        }
                    }
                }
            }
        }
        // Pass two: a firstpass block with no dylib_name of its own takes the target spelling.
        let mut i = 0;
        while let Some(at) = text[i..].find("name = \"") {
            let start = i + at + "name = \"".len();
            i = start;
            let end = name_run(b, start);
            let run = &text[start..end];
            if end < b.len() && b[end] == b'"' && run.ends_with("_firstpass") {
                let stem_name = &run[..run.len() - "_firstpass".len()];
                reg.entry(stem_name.to_string())
                    .or_insert_with(|| format!("//{pkg}:{stem_name}_firstpass"));
            }
        }
    }
    reg
}

fn strip_arch(artifact: &str) -> String {
    // _(x86_64|i386|arm64|arm64e)(\.dylib)?$ replaced by the captured extension.
    let (stem, ext) = match artifact.strip_suffix(".dylib") {
        Some(s) => (s, ".dylib"),
        None => (artifact, ""),
    };
    for arch in ["x86_64", "i386", "arm64e", "arm64"] {
        let suffix = format!("_{arch}");
        if let Some(s) = stem.strip_suffix(&suffix) {
            return format!("{s}{ext}");
        }
    }
    artifact.to_string()
}

/// dylib basename to buck label, for every final-pass dylib already declared. A TEXT scan, so a
/// package that builds its targets from a Starlark table declares them with a buck-registry
/// pragma instead.
pub fn final_registry(root: &str) -> HashMap<String, String> {
    let mut reg: HashMap<String, String> = HashMap::new();
    for (pkg, path) in walk_buck_files(root) {
        let text = match fs::read_to_string(&path) {
            Ok(t) => t,
            Err(_) => continue,
        };
        let b = text.as_bytes();
        // A dev STUB builds an artifact with the SAME name as the framework it stands in for, so
        // it must be reachable by PATH and never by name.
        let mut stub_targets: Vec<String> = Vec::new();
        let mut i = 0;
        while let Some(at) = text[i..].find("buck-registry:") {
            let mut j = i + at + "buck-registry:".len();
            // The python pattern is #\s*buck-registry:\s*(\S+)\s*=\s*(\S+), so the hash and the
            // spacing are checked here rather than assumed.
            let hash_ok = text[..i + at]
                .rfind('#')
                .map(|h| text[h + 1..i + at].chars().all(|c| c.is_whitespace()))
                .unwrap_or(false);
            i = j;
            if !hash_ok {
                continue;
            }
            while j < b.len() && (b[j] as char).is_whitespace() {
                j += 1;
            }
            let k = nonspace_run(b, j);
            let first = &text[j..k];
            let mut m = k;
            while m < b.len() && (b[m] as char).is_whitespace() {
                m += 1;
            }
            if m >= b.len() || b[m] != b'=' {
                continue;
            }
            m += 1;
            while m < b.len() && (b[m] as char).is_whitespace() {
                m += 1;
            }
            let n = nonspace_run(b, m);
            if n == m || first.is_empty() {
                continue;
            }
            let second = &text[m..n];
            reg.insert(first.to_string(), format!("//{pkg}:{second}"));
            if first.contains("/dev-stubs/") {
                stub_targets.push(second.to_string());
            }
            i = n;
        }
        // name = "<x>_(final|dylib)", then dylib_name on a later line.
        let mut i = 0;
        while let Some(at) = text[i..].find("name = \"") {
            let start = i + at + "name = \"".len();
            i = start;
            let end = name_run(b, start);
            let run = &text[start..end];
            if end >= b.len() || b[end] != b'"' {
                continue;
            }
            let (stem_name, suffix) = if let Some(s) = run.strip_suffix("_final") {
                (s, "final")
            } else if let Some(s) = run.strip_suffix("_dylib") {
                (s, "dylib")
            } else {
                continue;
            };
            if end + 1 >= b.len() || b[end + 1] != b',' {
                continue;
            }
            let j = match newline_gap(b, end + 2) {
                Some(j) => j,
                None => continue,
            };
            if !text[j..].starts_with("dylib_name = \"") {
                continue;
            }
            let artifact = match quoted_at(&text, j + "dylib_name = ".len()) {
                Some((a, _)) => a,
                None => continue,
            };
            let target = format!("{stem_name}_{suffix}");
            if stub_targets.contains(&target) {
                continue;
            }
            let label = format!("//{pkg}:{target}");
            reg.insert(artifact.clone(), label.clone());
            // A framework per-arch slice and the lipo'd binary are two names for one library.
            let stripped = strip_arch(&artifact);
            if stripped != artifact {
                reg.entry(stripped).or_insert(label);
            }
        }
    }
    reg
}

fn nonspace_run(b: &[u8], i: usize) -> usize {
    let mut j = i;
    while j < b.len() && !(b[j] as char).is_whitespace() {
        j += 1;
    }
    j
}

pub fn basename(p: &str) -> &str {
    match p.rfind('/') {
        Some(i) => &p[i + 1..],
        None => p,
    }
}

/// lib([A-Za-z0-9_.-]+)_firstpass\.dylib$ against a whole basename.
pub fn firstpass_stem(base: &str) -> Option<&str> {
    let rest = base.strip_prefix("lib")?;
    let stem = rest.strip_suffix("_firstpass.dylib")?;
    if stem.is_empty() || !stem.bytes().all(is_name_char) {
        return None;
    }
    Some(stem)
}

/// (upward labels, unported names) from -Wl,-upward_library flags.
///
/// An UPWARD dependency is one dyld links but does NOT descend into when running initializers,
/// and it is what lets libSystem own initializer run first. Treating them as ordinary
/// dependencies sent the walk into libc++ ahead of libSystem and killed every boot.
pub fn upwards_of(
    vars: &HashMap<String, String>,
    reg: &HashMap<String, String>,
    final_reg: &HashMap<String, String>,
) -> (Vec<String>, Vec<String>) {
    let flags = format!(
        "{} {}",
        vars.get("LINK_FLAGS").map(|s| s.as_str()).unwrap_or(""),
        vars.get("LINK_LIBRARIES").map(|s| s.as_str()).unwrap_or("")
    );
    let mut labels: Vec<String> = Vec::new();
    let mut missing: Vec<String> = Vec::new();
    let b = flags.as_bytes();
    let needle = "-Wl,-upward_library";
    let mut i = 0;
    while let Some(at) = flags[i..].find(needle) {
        let mut j = i + at + needle.len();
        i = j;
        // [,\s]+ then an optional -Wl, then (\S+)
        let sep = j;
        while j < b.len() && (b[j] == b',' || (b[j] as char).is_whitespace()) {
            j += 1;
        }
        if j == sep {
            continue;
        }
        if flags[j..].starts_with("-Wl,") {
            j += 4;
        }
        let k = nonspace_run(b, j);
        if k == j {
            continue;
        }
        let path = &flags[j..k];
        i = k;
        let base = basename(path);
        let label = match firstpass_stem(base) {
            Some(stem) => reg.get(stem),
            None => final_reg.get(base),
        };
        match label {
            Some(l) => {
                if !labels.contains(l) {
                    labels.push(l.clone());
                }
            }
            None => {
                let bs = base.to_string();
                if !missing.contains(&bs) {
                    missing.push(bs);
                }
            }
        }
    }
    (labels, missing)
}
