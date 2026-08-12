//! GIVE EVERY FILE ANOTHER PACKAGE NAMES BY LABEL AN export_file IN ITS OWNER.
//!
//! THE RUST REWRITE of the python buck-exports (#98). A file attribute has to be a source of the
//! package that DECLARES it, so once a pin is its own package, everything outside it, a header
//! map in buck-src/BUCK or a force-included header in another pin compile, has to reach its files
//! through a label backed by an export_file. This is the one place that keeps those in sync: it
//! scans every BUCK file and every generated .bzl for //buck-src/<pin>:<name> labels, resolves
//! each name back to the file it flattens from, and writes the pin export list.
//!
//! The list is a DICT in buck/generated/exports_<pin>.bzl, one line per file, with the pin BUCK
//! declaring them in a comprehension. One export_file block per file would be five lines each,
//! 30k lines across the tree, and the biggest pins would land back over the Nix evaluator budget
//! that splitting buck-src was meant to get under.
//!
//! IT IS RUST because the answer is a JOIN: a flattened-name index over a materialized pin, which
//! can be tens of thousands of files, against every label anything in the tree names. The
//! measured rule in this port sends that to Rust rather than to a nushell record.
//!
//! FOLLOWING SYMLINKED DIRECTORIES MATTERS, and the guard is BRANCH-LOCAL rather than global: a
//! pin reaches part of its own tree through symlinked directories, and under two different names
//! (libsyscall/mach/mach and cider/include/mach are the same files). Both spellings have to be
//! indexed, because a label minted from either one has to resolve. Skipping a directory because
//! another name for it was already seen dropped every entry under the second spelling.
//!
//! Usage:
//!   cider-exports            # write the lists
//!   cider-exports --check    # fail if anything is missing or stale

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::process::ExitCode;

const SKIP_DIRS: &[&str] = &["buck-out", ".git", ".jj", ".direnv", "build"];

/// What can be a FILE label rather than a rule target, for the ONE package that cannot be walked.
/// Not a filter anywhere else, and deliberately so: which names are FILES is decided by whether
/// the name resolves to one in the pin.
const FILE_EXTS: &[&str] = &[
    ".h", ".hpp", ".hh", ".hxx", ".inc", ".defs", ".c", ".cc", ".cpp", ".cxx", ".m", ".mm", ".S",
    ".s", ".y", ".l", ".tcc", ".mdh", ".mdhi", ".mdhs", ".pro", ".epro", ".sh", ".plist", ".txt",
    ".in", ".sym", ".exp", ".def", ".conf", ".asl", ".alias", ".lua", ".mgc", ".cnf", ".lib",
    ".pl", ".1", ".2", ".3", ".4", ".5", ".6", ".7", ".8", ".9",
];

/// The same, for files that carry no extension at all: vim vimrc and libedit inputrc are
/// installed by name, and without them the label goes unresolved and the package it names is
/// never even created.
const FILE_NAMES: &[&str] = &["vimrc", "inputrc"];

const BEGIN: &str = "# BEGIN generated: pin exports\n";
const END: &str = "# END generated: pin exports\n";

/// Same flattening as the generator: separators become underscores.
fn export_target_name(rel_in_pkg: &str) -> String {
    // [^A-Za-z0-9_.+-]+ replaced by ONE underscore, which is what re.sub does with a + quantifier.
    let mut out = String::new();
    let mut in_run = false;
    for c in rel_in_pkg.chars() {
        let ok = c.is_ascii_alphanumeric() || c == '_' || c == '.' || c == '+' || c == '-';
        if ok {
            out.push(c);
            in_run = false;
        } else if !in_run {
            out.push('_');
            in_run = true;
        }
    }
    out
}

fn is_label_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'.' || c == b'+' || c == b'-'
}

/// //(buck-src(?:/[A-Za-z0-9_.+-]+)?):([A-Za-z0-9_.+-]+)
fn labels_in(text: &str, out: &mut Vec<(String, String)>) {
    let b = text.as_bytes();
    let mut i = 0;
    while let Some(at) = text[i..].find("//buck-src") {
        let start = i + at;
        let after = start + "//buck-src".len();
        i = start + 1;
        // The optional segment is greedy, so it is tried first and only then dropped.
        let mut cand: Vec<usize> = Vec::new();
        if after < b.len() && b[after] == b'/' {
            let mut j = after + 1;
            while j < b.len() && is_label_char(b[j]) {
                j += 1;
            }
            if j > after + 1 {
                cand.push(j);
            }
        }
        cand.push(after);
        for end_pkg in cand {
            if end_pkg < b.len() && b[end_pkg] == b':' {
                let mut k = end_pkg + 1;
                while k < b.len() && is_label_char(b[k]) {
                    k += 1;
                }
                if k > end_pkg + 1 {
                    out.push((text[start + 2..end_pkg].to_string(), text[end_pkg + 1..k].to_string()));
                    i = k;
                }
                break;
            }
        }
    }
}

fn walk_files(root: &str, dir: &str, out: &mut Vec<String>) {
    let rd = match fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return,
    };
    let mut dirs = Vec::new();
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let p = format!("{dir}/{name}");
        if fs::metadata(&p).map(|m| m.is_dir()).unwrap_or(false) {
            if !SKIP_DIRS.contains(&name.as_str())
                && !fs::symlink_metadata(&p).map(|m| m.file_type().is_symlink()).unwrap_or(false)
            {
                dirs.push(p);
            }
        } else {
            out.push(p);
        }
    }
    for d in dirs {
        walk_files(root, &d, out);
    }
}

/// {package: {label name}} over every file that can name one.
fn scan_labels(root: &str) -> BTreeMap<String, BTreeSet<String>> {
    let mut wanted: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut files = Vec::new();
    walk_files(root, root, &mut files);
    let mut found = Vec::new();
    for path in files {
        let name = path.rsplit('/').next().unwrap_or("");
        if name != "BUCK" && !name.ends_with(".bzl") && !name.ends_with(".json") {
            continue;
        }
        // The python skips a file it cannot decode, which is what read_to_string does here.
        let text = match fs::read_to_string(&path) {
            Ok(t) => t,
            Err(_) => continue,
        };
        found.clear();
        labels_in(&text, &mut found);
        for (pkg, n) in &found {
            wanted.entry(pkg.clone()).or_default().insert(n.clone());
        }
    }
    wanted
}

/// {flattened name: pin-relative path} for every file in the pin.
fn pin_index(root: &str, pin: &str) -> (HashMap<String, String>, usize) {
    let pin_root = format!("{root}/buck-src/{pin}");
    let mut index: HashMap<String, String> = HashMap::new();
    let mut clash: HashSet<String> = HashSet::new();
    let real_root = fs::canonicalize(&pin_root)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| pin_root.clone());
    walk_pin(&pin_root, &pin_root, &[real_root], &mut index, &mut clash);
    (index, clash.len())
}

fn walk_pin(
    pin_root: &str,
    dir: &str,
    chain: &[String],
    index: &mut HashMap<String, String>,
    clash: &mut HashSet<String>,
) {
    let rd = match fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return,
    };
    let mut entries: Vec<(String, String)> = rd
        .flatten()
        .map(|e| {
            let n = e.file_name().to_string_lossy().into_owned();
            let p = format!("{dir}/{n}");
            (n, p)
        })
        .collect();
    // sorted(os.scandir(d), key=name)
    entries.sort();
    for (name, path) in entries {
        // is_dir() FOLLOWS the link here, which is the whole point.
        if fs::metadata(&path).map(|m| m.is_dir()).unwrap_or(false) {
            if SKIP_DIRS.contains(&name.as_str()) {
                continue;
            }
            let real = fs::canonicalize(&path)
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_else(|_| path.clone());
            if chain.contains(&real) || chain.len() > 24 {
                continue;
            }
            let mut next: Vec<String> = chain.to_vec();
            next.push(real);
            walk_pin(pin_root, &path, &next, index, clash);
        } else {
            let rel = path[pin_root.len() + 1..].to_string();
            let key = export_target_name(&rel);
            match index.get(&key) {
                Some(have) if *have != rel => {
                    clash.insert(key.clone());
                    // Prefer the shallowest path, deterministically, so a regeneration does not
                    // flip between two files that flatten to the same name.
                    let a = (rel.matches('/').count(), rel.clone());
                    let b = (have.matches('/').count(), have.clone());
                    if a < b {
                        index.insert(key, rel);
                    }
                }
                Some(_) => {}
                None => {
                    index.insert(key, rel);
                }
            }
        }
    }
}

fn target_names(buck_path: &str) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    let text = match fs::read_to_string(buck_path) {
        Ok(t) => t,
        Err(_) => return out,
    };
    let text = match text.find(BEGIN) {
        Some(i) => {
            let rest = &text[i + BEGIN.len()..];
            match rest.find(END) {
                Some(j) => format!("{}{}", &text[..i], &rest[j + END.len()..]),
                // The python raises IndexError here; there is no such file in the tree and
                // inventing a recovery would be inventing a result.
                None => text.clone(),
            }
        }
        None => text,
    };
    let mut i = 0;
    while let Some(at) = text[i..].find("name = \"") {
        let start = i + at + "name = \"".len();
        match text[start..].find('"') {
            Some(k) => {
                if k > 0 {
                    out.insert(text[start..start + k].to_string());
                }
                i = start + k + 1;
            }
            None => break,
        }
    }
    out
}

/// buck-src/xnu becomes exports_xnu; buck-src itself becomes exports_buck_src.
fn bzl_name(pkg: &str) -> String {
    match pkg.strip_prefix("buck-src/") {
        Some(tail) => format!("exports_{tail}"),
        None => "exports_buck_src".to_string(),
    }
}

fn render(pkg: &str, exports: &BTreeMap<String, String>) -> String {
    let mut out: Vec<String> = vec![
        "# GENERATED by cider-exports.".to_string(),
        "#".to_string(),
        format!("# Files in {pkg} that other packages name by label:"),
        "# {export target name: package-relative path}. The package's BUCK turns each".to_string(),
        "# into an export_file, because a file attribute has to be a source of the".to_string(),
        "# package that declares it.".to_string(),
        "EXPORTS = {".to_string(),
    ];
    for (name, rel) in exports {
        out.push(format!("    \"{name}\": \"{rel}\","));
    }
    out.push("}".to_string());
    out.push(String::new());
    out.join("\n")
}

fn block(pkg: &str) -> String {
    format!(
        "{BEGIN}load(\"//buck/generated:{}.bzl\", \"EXPORTS\")\n\n\
         # One export_file per file another package names by label, from the list\n\
         # cider-exports keeps.\n\
         [\n    export_file(name = _n, src = _s, visibility = [\"PUBLIC\"])\n    \
         for _n, _s in EXPORTS.items()\n]\n{END}",
        bzl_name(pkg)
    )
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let check = argv.iter().any(|a| a == "--check");
    let root = match std::env::var("CIDER_REPO") {
        Ok(v) if !v.is_empty() => v,
        _ => match std::env::current_dir() {
            Ok(d) => d.to_string_lossy().into_owned(),
            Err(e) => {
                eprintln!("cannot read the working directory: {e}");
                return ExitCode::FAILURE;
            }
        },
    };
    let root = root.trim_end_matches('/').to_string();
    if !std::path::Path::new(&format!("{root}/flake.nix")).exists() {
        eprintln!(
            "{root} does not look like the cider tree (no flake.nix).\n\
             Run this from the repo root, or set CIDER_REPO."
        );
        return ExitCode::FAILURE;
    }

    // Pins already migrated to their own package.
    let pins: BTreeSet<String> = fs::read_to_string(format!("{root}/buck/generated/split-pins.txt"))
        .map(|t| {
            t.lines()
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty() && !l.starts_with('#'))
                .collect()
        })
        .unwrap_or_default();

    // {package: {label name: path in package}} recorded by whoever created the label: buck-src
    // itself cannot be indexed by walking it.
    let hints_text = fs::read_to_string(format!("{root}/buck/generated/export-hints.json"));
    let hints: HashMap<String, HashMap<String, String>> = match hints_text {
        Ok(t) => serde_json_lite(&t),
        Err(_) => HashMap::new(),
    };

    let wanted = scan_labels(&root);
    let mut missing: Vec<String> = Vec::new();
    let mut stale: Vec<String> = Vec::new();
    let mut wrote = 0usize;

    let mut packages: BTreeSet<String> = wanted.keys().cloned().collect();
    for p in &pins {
        packages.insert(format!("buck-src/{p}"));
    }

    for pkg in &packages {
        let pin = pkg.strip_prefix("buck-src/").map(|s| s.to_string());
        let mut names: BTreeSet<String> = wanted.get(pkg).cloned().unwrap_or_default();
        let buck = format!("{root}/{pkg}/BUCK");
        if let Some(p) = &pin {
            if !pins.contains(p) && !std::path::Path::new(&buck).exists() {
                if !names.is_empty() {
                    missing.push(format!(
                        "{pkg}: {} label(s) into a pin that is not a package",
                        names.len()
                    ));
                }
                continue;
            }
        }
        let mut index: HashMap<String, String> = hints.get(pkg).cloned().unwrap_or_default();
        if pin.is_some() && !names.is_empty() {
            let (idx, nclash) = pin_index(&root, pin.as_ref().unwrap());
            if nclash > 0 {
                eprintln!(
                    "  NOTE: {}: {nclash} name(s) are shared by several files; using the \
                     shallowest of each",
                    pin.as_ref().unwrap()
                );
            }
            let hint_over = index.clone();
            index = idx;
            index.extend(hint_over);
        } else {
            // buck-src itself cannot be walked, so its index is the hints and "does not resolve"
            // says nothing. For that one package the name has to LOOK like a file to be treated
            // as one, and a name the install generator recorded a HINT for is known to be one.
            names = names
                .into_iter()
                .filter(|n| {
                    index.contains_key(n)
                        || FILE_EXTS.iter().any(|e| n.ends_with(e))
                        || FILE_NAMES.iter().any(|e| n.ends_with(e))
                })
                .collect();
        }
        let already = target_names(&buck);
        let mut exports: BTreeMap<String, String> = BTreeMap::new();
        let mut unresolved: Vec<String> = Vec::new();
        for name in &names {
            if already.contains(name) {
                continue; // a real target of that name already provides it
            }
            match index.get(name) {
                Some(rel) => {
                    exports.insert(name.clone(), rel.clone());
                }
                None => unresolved.push(name.clone()),
            }
        }
        for name in unresolved {
            missing.push(format!("{pkg}:{name} does not resolve to a file in the package"));
        }

        let out = format!("{root}/buck/generated/{}.bzl", bzl_name(pkg));
        let text = render(pkg, &exports);
        let have = fs::read_to_string(&out).unwrap_or_default();
        if exports.is_empty() {
            // Nothing to export: drop the list and the block rather than leaving an empty
            // comprehension behind.
            if std::path::Path::new(&out).exists() && !check {
                let _ = fs::remove_file(&out);
            }
            if let Ok(btext) = fs::read_to_string(&buck) {
                if btext.contains(BEGIN) && !check {
                    let i = btext.find(BEGIN).unwrap();
                    let rest = &btext[i + BEGIN.len()..];
                    if let Some(j) = rest.find(END) {
                        let new = format!("{}{}", &btext[..i], &rest[j + END.len()..]);
                        let _ = fs::write(&buck, new);
                    }
                }
            }
            continue;
        }
        if have != text {
            if check {
                stale.push(format!("buck/generated/{}.bzl", bzl_name(pkg)));
            } else {
                let _ = fs::write(&out, &text);
                wrote += 1;
            }
        }
        let btext = fs::read_to_string(&buck).unwrap_or_default();
        let mut new = if let Some(i) = btext.find(BEGIN) {
            let rest = &btext[i + BEGIN.len()..];
            match rest.find(END) {
                Some(j) => format!("{}{}{}", &btext[..i], block(pkg), &rest[j + END.len()..]),
                None => format!("{}{}", btext, block(pkg)),
            }
        } else if !btext.trim().is_empty() {
            format!("{}\n\n{}", btext.trim_end_matches('\n'), block(pkg))
        } else {
            block(pkg)
        };
        // The comprehension calls export_file, which a pin that exported nothing before has no
        // reason to have loaded. Adding the block without the load leaves the package unparseable.
        let load = "load(\"//buck/rules:files.bzl\", \"export_file\")";
        if !new.contains(load) {
            new = format!("{load}\n{new}");
        }
        if new != btext {
            if check {
                stale.push(format!("{pkg}/BUCK"));
            } else {
                let _ = fs::write(&buck, new);
            }
        }
        if !check {
            println!("{pkg}: {} export(s)", exports.len());
        }
    }

    for m in &missing {
        eprintln!("  MISSING {m}");
    }
    if check && (!stale.is_empty() || !missing.is_empty()) {
        for s in &stale {
            eprintln!("  STALE {s}");
        }
        return ExitCode::FAILURE;
    }
    if !check {
        println!("wrote {wrote} export list(s)");
    }
    if missing.is_empty() {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

/// The hints file is {package: {name: path}} and nothing else, so it is read into exactly that
/// rather than carried around as a Value.
fn serde_json_lite(text: &str) -> HashMap<String, HashMap<String, String>> {
    let v: serde_json::Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(_) => return HashMap::new(),
    };
    let mut out = HashMap::new();
    if let Some(o) = v.as_object() {
        for (k, inner) in o {
            let mut m = HashMap::new();
            if let Some(io) = inner.as_object() {
                for (n, p) in io {
                    if let Some(s) = p.as_str() {
                        m.insert(n.clone(), s.to_string());
                    }
                }
            }
            out.insert(k.clone(), m);
        }
    }
    out
}
