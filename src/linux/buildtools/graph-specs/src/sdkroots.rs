//! DERIVE BUCK2 HEADER ROOTS FROM THE COMMITTED SDK SYMLINK FARM.
//!
//! THE RUST REWRITE of the python gen-sdk-header-roots (#98). Cider exposes Darwin headers
//! through src/darwin/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include, a
//! tree of about 1900 committed relative symlinks into the pinned upstream sources. Those
//! symlinks ARE the authority on how the SDK namespaces are assembled: i386/ merges xnu/bsd/i386
//! with xnu/osfmk/i386, libkern/ merges xnu with libplatform and libc, and no single prefix rule
//! reproduces that.
//!
//! Rather than hand-deriving it, this reads the farm and emits cc_header_root(header_map = {...})
//! declarations mapping each include path to the real source file. A compile then sees exactly
//! the SDK headers under exactly the SDK names, with no source tree on the include path.
//!
//! REALPATH IS THE WHOLE TRICK, and it is why this is not a hand-rolled link chase. The farm has
//! three kinds of link: straight into a pinned tree, INTRA-SDK (pthread.h to pthread/pthread.h,
//! itself a link), and links whose PARENT DIRECTORY is a link into a pinned tree. Testing
//! is_symlink on the last kind answers false, because the parent cannot be traversed in a working
//! copy where the pins are absent. os.path.realpath handles all three because it resolves every
//! component TEXTUALLY and does not require the result to exist. std::fs::canonicalize does
//! require it, so realpath() below is written out rather than borrowed.
//!
//! Usage:
//!   cider-sdk-header-roots <namespace> ...                 > vendor/src/sdk_headers.bzl
//!   cider-sdk-header-roots --list-pins <namespace> ...     # which pins are needed
//!   cider-sdk-header-roots --framework-roots <namespace> ...
//!   cider-sdk-header-roots --pin-roots [--apply] [--only a,b] <namespace> ...
//!   cider-sdk-header-roots --repo-roots [--apply] <namespace> ...

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::process::ExitCode;

const PIN_ROOT: &str = "vendor/pins";
const BUCK_SRC: &str = "vendor/src";

/// .c is included deliberately: the SDK exposes implementation .c files under the emulation
/// namespace and the emulation layer includes them by path.
const HEADER_EXTS: &[&str] = &[".h", ".hpp", ".modulemap", ".defs", ".c"];

/// Upstream exposes a handful of headers under two spellings and the farm carries only one.
const ALIASES: &[(&str, &str)] = &[
    ("System/pthread_machdep.h", "pthread_machdep.h"),
    ("Kernel/sys/decmpfs.h", "sys/decmpfs.h"),
    ("Kernel/IOKit/IOKitDebug.h", "IOKit/IOKitDebug.h"),
];

const USAGE: &str = "\
cider-sdk-header-roots: derive Buck2 header roots from the committed SDK symlink farm.

  cider-sdk-header-roots <namespace> [<namespace> ...]  > vendor/src/sdk_headers.bzl
  cider-sdk-header-roots --list-pins <namespace> ...     # which pins are needed
";

// ---------------------------------------------------------------- paths

fn normpath(p: &str) -> String {
    let absolute = p.starts_with('/');
    let mut out: Vec<&str> = Vec::new();
    for seg in p.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                if let Some(last) = out.last() {
                    if *last != ".." {
                        out.pop();
                        continue;
                    }
                }
                if absolute {
                    continue;
                }
                out.push("..");
            }
            s => out.push(s),
        }
    }
    let joined = out.join("/");
    if absolute {
        format!("/{joined}")
    } else if joined.is_empty() {
        ".".to_string()
    } else {
        joined
    }
}

fn pjoin(a: &str, b: &str) -> String {
    if b.starts_with('/') {
        b.to_string()
    } else if a.is_empty() || a.ends_with('/') {
        format!("{a}{b}")
    } else {
        format!("{a}/{b}")
    }
}

/// os.path.realpath: every component resolved, symlinks followed, and the result is NOT required
/// to exist.
fn realpath(path: &str) -> String {
    let mut stack: Vec<String> = Vec::new();
    let mut todo: Vec<String> = path.split('/').map(|s| s.to_string()).collect();
    todo.reverse();
    let mut links = 0;
    while let Some(comp) = todo.pop() {
        if comp.is_empty() || comp == "." {
            continue;
        }
        if comp == ".." {
            stack.pop();
            continue;
        }
        stack.push(comp);
        let cur = format!("/{}", stack.join("/"));
        let is_link = fs::symlink_metadata(&cur).map(|m| m.file_type().is_symlink()).unwrap_or(false);
        if !is_link {
            continue;
        }
        links += 1;
        if links > 40 {
            // python raises ELOOP; stopping here leaves a path that names the loop rather than
            // crashing, and no farm link is anywhere near this deep.
            continue;
        }
        if let Ok(t) = fs::read_link(&cur) {
            let t = t.to_string_lossy().into_owned();
            stack.pop();
            if t.starts_with('/') {
                stack.clear();
            }
            let mut parts: Vec<String> = t.split('/').map(|s| s.to_string()).collect();
            parts.reverse();
            for p in parts {
                todo.push(p);
            }
        }
    }
    format!("/{}", stack.join("/"))
}

/// os.path.relpath, lexical, both sides absolute and normalised.
fn relpath(target: &str, base: &str) -> String {
    let t = normpath(target);
    let b = normpath(base);
    let tp: Vec<&str> = t.split('/').filter(|s| !s.is_empty()).collect();
    let bp: Vec<&str> = b.split('/').filter(|s| !s.is_empty()).collect();
    let mut i = 0;
    while i < tp.len() && i < bp.len() && tp[i] == bp[i] {
        i += 1;
    }
    let mut parts: Vec<String> = vec!["..".to_string(); bp.len() - i];
    parts.extend(tp[i..].iter().map(|s| s.to_string()));
    if parts.is_empty() {
        ".".to_string()
    } else {
        parts.join("/")
    }
}

fn is_symlink(p: &str) -> bool {
    fs::symlink_metadata(p).map(|m| m.file_type().is_symlink()).unwrap_or(false)
}

fn is_dir(p: &str) -> bool {
    fs::metadata(p).map(|m| m.is_dir()).unwrap_or(false)
}

fn is_file(p: &str) -> bool {
    fs::metadata(p).map(|m| m.is_file()).unwrap_or(false)
}

fn exists(p: &str) -> bool {
    fs::metadata(p).is_ok()
}

fn ends_with_header_ext(name: &str) -> bool {
    HEADER_EXTS.iter().any(|e| name.ends_with(e))
}

fn sanitize(s: &str) -> String {
    // [^A-Za-z0-9_.+-]+ to one underscore.
    let mut out = String::new();
    let mut run = false;
    for c in s.chars() {
        if c.is_ascii_alphanumeric() || c == '_' || c == '.' || c == '+' || c == '-' {
            out.push(c);
            run = false;
        } else if !run {
            out.push('_');
            run = true;
        }
    }
    out
}

/// os.walk(root, followlinks=False), pre-order, scandir order.
fn walk(dir: &str, out: &mut Vec<(String, Vec<String>, Vec<String>)>) {
    let rd = match fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return,
    };
    let mut dirs = Vec::new();
    let mut files = Vec::new();
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let p = format!("{dir}/{name}");
        if is_dir(&p) {
            dirs.push(name);
        } else {
            files.push(name);
        }
    }
    out.push((dir.to_string(), dirs.clone(), files));
    for d in dirs {
        let p = format!("{dir}/{d}");
        if !is_symlink(&p) {
            walk(&p, out);
        }
    }
}

fn walk_files_only(dir: &str) -> Vec<(String, Vec<String>)> {
    let mut all = Vec::new();
    walk(dir, &mut all);
    all.into_iter().map(|(d, _dirs, files)| (d, files)).collect()
}

// ---------------------------------------------------------------- the farm

struct Ctx {
    repo: String,
    sdk_include: String,
    repo_side: Vec<String>,
}

impl Ctx {
    /// Repo-relative path a farm symlink ultimately points at, or None if it leaves the repo.
    fn link_target_repo_rel(&self, link_path: &str) -> Option<String> {
        let real = realpath(link_path);
        let rel = relpath(&real, &self.repo);
        if rel.starts_with("..") {
            None
        } else {
            Some(rel)
        }
    }

    /// vendor/pins/xnu/osfmk/mach/boolean.h becomes xnu/osfmk/mach/boolean.h, or None when the file is
    /// not ours to map: committed repo content outside pins, or one of the committed trees under
    /// pins that never appear in vendor/src.
    fn to_buck_src(&self, repo_rel: &str) -> Option<String> {
        let buck_rel = repo_rel.strip_prefix("vendor/pins/")?;
        if !exists(&format!("{}/{BUCK_SRC}/{buck_rel}", self.repo)) {
            return None;
        }
        Some(buck_rel.to_string())
    }

    /// (include_path, repo_relative_source) for every header under a namespace.
    fn walk_namespace(&mut self, ns: &str) -> Result<Vec<(String, String)>, String> {
        let root = if ns == "." {
            self.sdk_include.clone()
        } else {
            format!("{}/{ns}", self.sdk_include)
        };
        if !exists(&root) && !is_symlink(&root) {
            return Err(format!("no such SDK namespace: {ns}"));
        }
        let mut yielded: Vec<(String, String)> = Vec::new();
        let mut all = Vec::new();
        walk(&root, &mut all);
        for (dirpath, dirs, files) in all {
            let rel_dir = relpath(&dirpath, &self.sdk_include);
            let mut names: Vec<String> = files;
            names.extend(dirs);
            names.sort();
            for name in names {
                let path = format!("{dirpath}/{name}");
                if !is_symlink(&path) {
                    // A REAL file committed in the SDK tree belongs to the SDK directory own
                    // package, so it is reported separately rather than mapped into vendor/src.
                    if is_file(&path) && ends_with_header_ext(&name) {
                        self.repo_side.push(normpath(&pjoin(&rel_dir, &name)));
                    }
                    continue;
                }
                let repo_rel = match self.link_target_repo_rel(&path) {
                    Some(r) => r,
                    None => continue,
                };
                let include_base = normpath(&pjoin(&rel_dir, &name));
                if ends_with_header_ext(&name) {
                    yielded.push((include_base, repo_rel));
                    continue;
                }
                // A directory symlink: expand it from the materialized tree so its headers get
                // mapped too.
                let buck_rel = self.to_buck_src(&repo_rel);
                let src_dir = match &buck_rel {
                    Some(b) => format!("{}/{BUCK_SRC}/{b}", self.repo),
                    // Not a pin but a COMMITTED repo tree, so expand it from the repo.
                    None => format!("{}/{repo_rel}", self.repo),
                };
                if !is_dir(&src_dir) {
                    continue;
                }
                for (sub_dir, mut sub_files) in walk_files_only(&src_dir) {
                    sub_files.sort();
                    for f in sub_files {
                        if !ends_with_header_ext(&f) {
                            continue;
                        }
                        let sub_path = format!("{sub_dir}/{f}");
                        let sub_rel = relpath(&sub_path, &src_dir);
                        // Inside a committed tree the entries are often themselves links into the
                        // pins; follow them, or the map names a source that is not checked out.
                        let mut target = normpath(&pjoin(&repo_rel, &sub_rel));
                        if buck_rel.is_none() && is_symlink(&sub_path) {
                            if let Some(resolved) = self.link_target_repo_rel(&sub_path) {
                                target = resolved;
                            }
                        }
                        yielded.push((normpath(&pjoin(&include_base, &sub_rel)), target));
                    }
                }
            }
        }
        Ok(yielded)
    }
}

fn split_pins(repo: &str) -> BTreeSet<String> {
    fs::read_to_string(format!("{repo}/buck/generated/split-pins.txt"))
        .map(|t| {
            t.lines()
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty() && !l.starts_with('#'))
                .collect()
        })
        .unwrap_or_default()
}

/// How a map refers to a pinned header: a path, or a label once the pin has split.
fn pin_value(buck_rel: &str, moved: &BTreeSet<String>) -> String {
    let pin = buck_rel.split('/').next().unwrap_or("");
    if !moved.contains(pin) {
        return buck_rel.to_string();
    }
    let rel = &buck_rel[pin.len() + 1..];
    format!("//{BUCK_SRC}/{pin}:{}", sanitize(rel))
}

fn write_block(path: &str, text: &str, begin: &str, end: &str, name: &str, header_load: &str) {
    let existing = fs::read_to_string(path).unwrap_or_default();
    let new_text = if let Some(i) = existing.find(begin) {
        let rest = &existing[i + begin.len()..];
        match rest.find(end) {
            Some(j) => format!("{}{}{}", &existing[..i], text, &rest[j + end.len()..]),
            None => format!("{existing}{text}"),
        }
    } else if let Some(napos) = existing.find(&format!("name = \"{name}\"")) {
        // An older hand-placed copy of the same root: replace that block rather than adding a
        // second definition of the same target.
        match existing[..napos].rfind("cc_header_root(") {
            Some(i) => match existing[i..].find("\n)\n") {
                Some(k) => {
                    let j = i + k + "\n)\n".len();
                    format!("{}{}{}", &existing[..i], text, &existing[j..])
                }
                None => format!("{existing}{text}"),
            },
            None => format!("{existing}{text}"),
        }
    } else if !existing.trim().is_empty() {
        format!("{}\n\n{}", existing.trim_end(), text)
    } else {
        format!("{header_load}{text}")
    };
    if let Some(parent) = std::path::Path::new(path).parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::write(path, new_text);
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let repo = match std::env::var("CIDER_REPO") {
        Ok(v) if !v.is_empty() => v,
        _ => match std::env::current_dir() {
            Ok(d) => d.to_string_lossy().into_owned(),
            Err(e) => {
                eprintln!("cannot read the working directory: {e}");
                return ExitCode::FAILURE;
            }
        },
    };
    let repo = repo.trim_end_matches('/').to_string();
    if !std::path::Path::new(&format!("{repo}/flake.nix")).exists() {
        eprintln!(
            "{repo} does not look like the cider tree (no flake.nix).\n\
             Run this from the repo root, or set CIDER_REPO."
        );
        return ExitCode::FAILURE;
    }

    let list_pins = argv.iter().any(|a| a == "--list-pins");
    let mut argv_vals: BTreeSet<String> = BTreeSet::new();
    if let Some(i) = argv.iter().position(|a| a == "--only") {
        if i + 1 < argv.len() {
            argv_vals.insert(argv[i + 1].clone());
        }
    }
    let namespaces: Vec<String> = argv
        .iter()
        .filter(|a| !a.starts_with("--") && !argv_vals.contains(*a))
        .cloned()
        .collect();
    if namespaces.is_empty() {
        eprintln!("{USAGE}");
        return ExitCode::FAILURE;
    }

    let sdk_include =
        format!("{repo}/src/darwin/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include");
    let mut ctx = Ctx { repo: repo.clone(), sdk_include, repo_side: Vec::new() };
    let moved = split_pins(&repo);

    // pins keeps FIRST-SEEN order, which is what a stable sort by -count falls back on.
    let mut pin_order: Vec<String> = Vec::new();
    let mut pins: HashMap<String, usize> = HashMap::new();
    let mut roots: Vec<(String, Vec<(String, String)>)> = Vec::new();
    let mut skipped: BTreeMap<String, usize> = BTreeMap::new();

    for ns in &namespaces {
        let walked = match ctx.walk_namespace(ns) {
            Ok(w) => w,
            Err(e) => {
                eprintln!("{e}");
                return ExitCode::FAILURE;
            }
        };
        let mut entries: Vec<(String, String)> = Vec::new();
        for (include_path, repo_rel) in &walked {
            // INDEX DERIVED FROM THE PIN ROOT, not written as a number.
            let pin = if repo_rel.starts_with(&format!("{PIN_ROOT}/")) {
                repo_rel.split('/').nth(PIN_ROOT.split('/').count()).unwrap_or("(repo)").to_string()
            } else {
                "(repo)".to_string()
            };
            if !pins.contains_key(&pin) {
                pin_order.push(pin.clone());
            }
            *pins.entry(pin).or_insert(0) += 1;
            match ctx.to_buck_src(repo_rel) {
                None => {
                    let n = if repo_rel.starts_with(&format!("{PIN_ROOT}/")) {
                        PIN_ROOT.split('/').count() + 1
                    } else {
                        2
                    };
                    let key: Vec<&str> = repo_rel.split('/').take(n).collect();
                    *skipped.entry(key.join("/")).or_insert(0) += 1;
                }
                Some(buck_rel) => entries.push((include_path.clone(), pin_value(&buck_rel, &moved))),
            }
        }
        let mut by_path: HashMap<&str, &str> = HashMap::new();
        for (k, v) in &entries {
            by_path.insert(k.as_str(), v.as_str());
        }
        let mut extra: Vec<(String, String)> = Vec::new();
        for (alias, real) in ALIASES {
            if let Some(v) = by_path.get(real) {
                if !by_path.contains_key(alias) {
                    extra.push((alias.to_string(), v.to_string()));
                }
            }
        }
        entries.extend(extra);
        let uniq: BTreeSet<(String, String)> = entries.into_iter().collect();
        roots.push((ns.clone(), uniq.into_iter().collect()));
    }

    // ------------------------------------------------ --framework-roots
    if argv.iter().any(|a| a == "--framework-roots") {
        for (tree, label) in
            [("src/darwin/framework-include", "framework"), ("src/darwin/framework-private-include", "framework_private")]
        {
            let root = format!("{repo}/{tree}");
            if !is_dir(&root) {
                continue;
            }
            let mut by_pkg: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
            let mut names: Vec<String> = fs::read_dir(&root)
                .map(|rd| rd.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
                .unwrap_or_default();
            names.sort();
            for name in names {
                let entry = format!("{root}/{name}");
                let real = realpath(&entry);
                let rel = relpath(&real, &repo);
                if rel.starts_with("..") {
                    continue;
                }
                let buck_rel = ctx.to_buck_src(&rel);
                let src_dir = match &buck_rel {
                    Some(b) => format!("{repo}/{BUCK_SRC}/{b}"),
                    None => format!("{repo}/{rel}"),
                };
                if !is_dir(&src_dir) {
                    continue;
                }
                let pkg = match &buck_rel {
                    Some(_) => BUCK_SRC.to_string(),
                    None => rel.split('/').take(2).collect::<Vec<_>>().join("/"),
                };
                for (dirpath, mut files) in walk_files_only(&src_dir) {
                    files.sort();
                    for f in files {
                        if !ends_with_header_ext(&f) {
                            continue;
                        }
                        let fpath = format!("{dirpath}/{f}");
                        let sub = relpath(&fpath, &src_dir);
                        let include_path = normpath(&pjoin(&name, &sub));
                        // A committed framework tree can be a farm of its OWN: following the link
                        // decides the owning package, and skipping that step produced a map
                        // naming 52 files that do not exist.
                        let mut owner = pkg.clone();
                        let mut rel_in_owner = relpath(&fpath, &format!("{repo}/{pkg}"));
                        if is_symlink(&fpath) && !exists(&fpath) {
                            if let Some(resolved) = ctx.link_target_repo_rel(&fpath) {
                                if let Some(in_pin) = ctx.to_buck_src(&resolved) {
                                    owner = BUCK_SRC.to_string();
                                    rel_in_owner = in_pin;
                                }
                            }
                        }
                        let value = if owner == BUCK_SRC {
                            pin_value(&rel_in_owner, &split_pins(&repo))
                        } else {
                            rel_in_owner
                        };
                        by_pkg.entry(owner).or_default().push((include_path, value));
                    }
                }
            }
            // One dict per FRAMEWORK, not one giant map, and written per owning package so a
            // package only parses what it declares.
            for (pkg, entries) in &by_pkg {
                let uniq: BTreeSet<(String, String)> = entries.iter().cloned().collect();
                let mut per_fw: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
                for (include_path, value) in &uniq {
                    let fw = include_path.split('/').next().unwrap_or("").to_string();
                    per_fw.entry(fw).or_default().push((include_path.clone(), value.clone()));
                }
                let out = format!(
                    "{repo}/buck/generated/sdk_{label}_{}.bzl",
                    pkg.replace('/', "_").replace('-', "_")
                );
                let mut text = String::new();
                text.push_str("# GENERATED by cider-sdk-header-roots --framework-roots.\n");
                text.push_str("#\n");
                text.push_str(&format!("# The {tree} headers owned by {pkg}, one entry per framework:\n"));
                text.push_str("# {framework: {include path: source file}}. A target declares the\n");
                text.push_str("# frameworks it includes rather than getting the whole surface.\n");
                text.push_str("FRAMEWORKS = {\n");
                for (fw, items) in &per_fw {
                    text.push_str(&format!("    \"{fw}\": {{\n"));
                    for (include_path, value) in items {
                        text.push_str(&format!("        \"{include_path}\": \"{value}\",\n"));
                    }
                    text.push_str("    },\n");
                }
                text.push_str("}\n");
                let _ = fs::write(&out, text);
                eprintln!(
                    "wrote {}: {} frameworks, {} headers ({pkg})",
                    relpath(&out, &repo),
                    per_fw.len(),
                    uniq.len()
                );
            }
        }
        return ExitCode::SUCCESS;
    }

    // ------------------------------------------------ --pin-roots
    if argv.iter().any(|a| a == "--pin-roots") {
        let mut by_pin: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
        for ns in &namespaces {
            let walked = match ctx.walk_namespace(ns) {
                Ok(w) => w,
                Err(e) => {
                    eprintln!("{e}");
                    return ExitCode::FAILURE;
                }
            };
            for (include_path, repo_rel) in walked {
                let buck_rel = match ctx.to_buck_src(&repo_rel) {
                    Some(b) => b,
                    None => continue,
                };
                let pin = buck_rel.split('/').next().unwrap_or("").to_string();
                let rest = buck_rel[pin.len() + 1..].to_string();
                by_pin.entry(pin).or_default().push((include_path, rest));
            }
        }
        let apply = argv.iter().any(|a| a == "--apply");
        let only: Option<Vec<String>> = argv
            .iter()
            .position(|a| a == "--only")
            .and_then(|i| argv.get(i + 1))
            .map(|v| v.split(',').map(|s| s.to_string()).collect());
        let mut labels: Vec<String> = Vec::new();
        for (pin, entries) in &by_pin {
            if let Some(o) = &only {
                if !o.contains(pin) {
                    continue;
                }
            }
            let mut name = String::new();
            let mut run = false;
            for c in pin.chars() {
                if c.is_ascii_alphanumeric() || c == '_' {
                    name.push(c);
                    run = false;
                } else if !run {
                    name.push('_');
                    run = true;
                }
            }
            let name = format!("sdk_pin_{}_headers", name.trim_matches('_'));
            labels.push(format!("//{BUCK_SRC}/{pin}:{name}"));
            let uniq: BTreeSet<(String, String)> = entries.iter().cloned().collect();
            let mut block: Vec<String> = vec![
                "# BEGIN generated: sdk pin headers".to_string(),
                "# This pin's share of the Darwin SDK header surface. One root per pin, so"
                    .to_string(),
                "# vendor/src can be split into a package per pin: a subpackage owns its files,"
                    .to_string(),
                "# and a map in the parent package cannot name them.".to_string(),
                "# GENERATED by cider-sdk-header-roots --pin-roots.".to_string(),
                "cc_header_root(".to_string(),
                format!("    name = \"{name}\","),
                "    header_map = {".to_string(),
            ];
            for (include_path, rel) in &uniq {
                block.push(format!("        \"{include_path}\": \"{rel}\","));
            }
            block.push("    },".to_string());
            block.push("    visibility = [\"PUBLIC\"],".to_string());
            block.push(")".to_string());
            block.push("# END generated: sdk pin headers".to_string());
            let text = block.join("\n") + "\n";
            if !apply {
                println!("### {BUCK_SRC}/{pin}/BUCK  ({} headers)", uniq.len());
                continue;
            }
            let f = format!("{repo}/{BUCK_SRC}/{pin}/BUCK");
            write_block(
                &f,
                &text,
                "# BEGIN generated: sdk pin headers\n",
                "# END generated: sdk pin headers\n",
                &name,
                "load(\"//buck/rules:cc.bzl\", \"cc_header_root\")\n\n",
            );
            eprintln!("wrote {BUCK_SRC}/{pin}/BUCK: {name} ({} headers)", uniq.len());
        }
        if apply {
            println!("# sdk_env deps for src/darwin/BUCK:");
            for lb in &labels {
                println!("        \"{lb}\",");
            }
        } else {
            println!("# {} pins carry SDK headers", by_pin.len());
        }
        return ExitCode::SUCCESS;
    }

    // ------------------------------------------------ --repo-roots
    if argv.iter().any(|a| a == "--repo-roots") {
        let mut by_pkg: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
        for ns in &namespaces {
            let walked = match ctx.walk_namespace(ns) {
                Ok(w) => w,
                Err(e) => {
                    eprintln!("{e}");
                    return ExitCode::FAILURE;
                }
            };
            for (include_path, repo_rel) in walked {
                if ctx.to_buck_src(&repo_rel).is_some() {
                    continue;
                }
                let parts: Vec<&str> = repo_rel.split('/').collect();
                let n = if repo_rel.starts_with("vendor/pins/") { 3 } else { 2 };
                let pkg = parts.iter().take(n).cloned().collect::<Vec<_>>().join("/");
                if !is_dir(&format!("{repo}/{pkg}")) {
                    continue;
                }
                let rel_in_pkg = relpath(&format!("{repo}/{repo_rel}"), &format!("{repo}/{pkg}"));
                by_pkg.entry(pkg).or_default().push((include_path, rel_in_pkg));
            }
        }
        let apply = argv.iter().any(|a| a == "--apply");
        let mut labels: Vec<String> = Vec::new();
        for (pkg, entries) in &by_pkg {
            let name = format!("sdk_{}_headers", pkg.replace('/', "_").replace('-', "_"));
            labels.push(format!("//{pkg}:{name}"));
            let uniq: BTreeSet<(String, String)> = entries.iter().cloned().collect();
            if apply {
                let mut block: Vec<String> = vec![
                    "# BEGIN generated: sdk headers".to_string(),
                    "# SDK headers this package owns: the Darwin SDK tree reaches them by".to_string(),
                    "# symlink, and a header_map's values must be sources in the declaring".to_string(),
                    "# package. GENERATED by cider-sdk-header-roots --repo-roots.".to_string(),
                    "cc_header_root(".to_string(),
                    format!("    name = \"{name}\","),
                    "    header_map = {".to_string(),
                ];
                for (include_path, rel) in &uniq {
                    block.push(format!("        \"{include_path}\": \"{rel}\","));
                }
                block.push("    },".to_string());
                block.push("    visibility = [\"PUBLIC\"],".to_string());
                block.push(")".to_string());
                block.push("# END generated: sdk headers".to_string());
                let text = block.join("\n") + "\n";
                write_block(
                    &format!("{repo}/{pkg}/BUCK"),
                    &text,
                    "# BEGIN generated: sdk headers\n",
                    "# END generated: sdk headers\n",
                    &name,
                    "load(\"//buck/rules:cc.bzl\", \"cc_header_root\")\n\n",
                );
                eprintln!("wrote {pkg}/BUCK: {name} ({} headers)", uniq.len());
                continue;
            }
            println!("### {pkg}/BUCK");
            println!("load(\"//buck/rules:cc.bzl\", \"cc_header_root\")");
            println!();
            println!("# SDK headers this package owns: the Darwin SDK tree reaches them by");
            println!("# symlink, and a header_map's values must be sources in the declaring");
            println!("# package. GENERATED by cider-sdk-header-roots --repo-roots.");
            println!("cc_header_root(");
            println!("    name = \"{name}\",");
            println!("    header_map = {{");
            for (include_path, rel) in &uniq {
                println!("        \"{include_path}\": \"{rel}\",");
            }
            println!("    }},");
            println!("    visibility = [\"PUBLIC\"],");
            println!(")");
            println!();
        }
        if apply {
            println!("# sdk_env deps for src/darwin/BUCK:");
            for lb in &labels {
                println!("        \"{lb}\",");
            }
        }
        return ExitCode::SUCCESS;
    }

    // ------------------------------------------------ --list-pins
    if list_pins {
        let mut order: Vec<(&String, &usize)> = pin_order.iter().map(|p| (p, &pins[p])).collect();
        // sorted(key=-count) is STABLE, so equal counts keep first-seen order.
        order.sort_by_key(|(_, c)| std::cmp::Reverse(**c));
        for (pin, count) in order {
            if pin == "(repo)" {
                println!("{count:5}  (repo)");
            } else {
                println!("{count:5}  vendor/pins/{pin}");
            }
        }
        return ExitCode::SUCCESS;
    }

    // ------------------------------------------------ the default dump
    println!("# GENERATED by cider-sdk-header-roots -- do not edit.");
    println!("#");
    println!("# Derived from the repo's committed SDK symlink farm");
    println!("# (src/darwin/Developer/.../MacOSX.sdk/usr/include), which is the authority on how");
    println!("# Darwin's header namespaces are assembled from the pinned upstream trees.");
    println!("# Regenerate after materializing more pins:");
    println!("#   cider-sdk-header-roots {} > vendor/src/sdk_headers.bzl", namespaces.join(" "));
    println!();
    for (ns, entries) in &roots {
        let var = format!("SDK_{}", ns.replace('/', "_").replace('.', "ROOT").to_uppercase());
        println!("# {ns}/: {} headers", entries.len());
        println!("{var} = {{");
        for (include_path, buck_rel) in entries {
            println!("    \"{include_path}\": \"{buck_rel}\",");
        }
        println!("}}");
        println!();
    }
    if !ctx.repo_side.is_empty() {
        println!("# Real files committed inside the SDK tree (not links into a pinned tree).");
        println!("# Declared by the header root in the SDK directory's own package, where these");
        println!("# paths are both the file paths and the include paths.");
        println!("SDK_REPO_HEADERS = [");
        let uniq: BTreeSet<&String> = ctx.repo_side.iter().collect();
        for h in uniq {
            println!("    \"{h}\",");
        }
        println!("]");
        println!();
    }
    if !skipped.is_empty() {
        println!("# Headers skipped: they live in another buck2 package (committed repo");
        println!("# content, or one of the committed trees under pins), so they need a");
        println!("# header root declared in the package that owns them:");
        for (top, count) in &skipped {
            println!("#   {count:4} under {top}/");
        }
        eprintln!("# skipped:");
        for (top, count) in &skipped {
            eprintln!("#   {count:4} under {top}/");
        }
    }
    ExitCode::SUCCESS
}
