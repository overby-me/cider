//! THE PREFIX, DERIVED FROM THE REFERENCE BUILD INSTALL MANIFESTS.
//!
//! THE RUST REWRITE of the python gen-install-from-manifests (#98), and the LAST python the check
//! suite ran: buck-test.nu invokes it for the UNMAPPED gate, which is why this one is ported
//! rather than deleted like the frozen generators around it.
//!
//! It reads every cmake_install.cmake in the reference build, maps each install entry to the
//! buck2 target or source file that provides it, and writes buck/prefix/BUCK. UNMAPPED is the
//! number that must stay at zero: an entry the reference installs that nothing here provides.
//!
//! THE TWO REGISTRY LOOKUPS COME FROM src/ninjaref.rs, which is the live surface of the 2,508
//! line generator this file used to import. Everything else is here.
//!
//! THREE RULES THAT LOOK LIKE DETAILS AND ARE NOT:
//!   BY PATH FIRST when resolving an artifact. perl builds the same 53 module names twice, once
//!     for 5.18 and once for 5.28, so a basename does not identify anything; the generated blocks
//!     carry `# buck-registry: <reference path> = <target>` for exactly this.
//!   THE REAL IMPLEMENTATION WINS a destination collision. The reference installs both cocotron
//!     AppKit and its dev STUB to one path, and shipping the stub takes NSApplication down.
//!   THE FROZEN REFERENCE PREDATES TWO RENAMES. It says src/external/<pin> where the tree says
//!     vendor/pins/<pin>, and libexec/darling where the tree says libexec/cider. Both are mapped at the
//!     parse, by SEGMENT rather than by substring, or 2,425 entries read as unmapped.
//!
//! Usage:
//!   cider-install-from-manifests [--manifests <graph dir>] [--write]

#[path = "ninjaref.rs"]
mod ninjaref;
use ninjaref::{archive_registry, final_registry, repo_root, walk_buck_files};

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::process::ExitCode;

const ARCH: &str = "x86_64";
/// The prefix the reference configures with. cmake writes it into DESTINATION paths two ways,
/// as ${CMAKE_INSTALL_PREFIX} and, for a few targets, literally.
const INSTALL_PREFIX: &str = "/usr/local";

/// Artifacts the reference GENERATES with a custom command rather than linking, so no registry
/// knows them.
const GENERATED: &[(&str, &str)] = &[
    ("icudt66l.dat", "//vendor/src/icu:icudt66l_dat"),
    ("python-config", "//vendor/src/python:python_config"),
    ("xattr-0.6.4-2.7", "//vendor/src/python_modules:easyinstall_xattr_2.7"),
];

/// What the reference does NOT install, but a runnable prefix needs.
const EXTRA: &[(&str, &str)] = &[
    ("bin/cider", "//linux/launcher:cider"),
    ("bin/ciderd", "//linux/server:ciderd"),
    ("libexec/cider/usr/libexec/cider/mldr", "//darwin/loader:mldr"),
    (
        "libexec/cider/System/Library/Frameworks/Python.framework/Versions/2.7/lib/python2.7/lib-dynload/_sqlite3.so",
        "//vendor/src/python:py27__sqlite_dylib",
    ),
    (
        "libexec/cider/System/Library/Frameworks/Python.framework/Versions/2.7/lib/python2.7/lib-dynload/_curses.so",
        "//vendor/src/python:py27__curses_dylib",
    ),
];

/// install(DIRECTORY) entries whose source is a BUILD output, with the hand-written target.
const EXTRA_DIRS: &[(&str, &str)] = &[(
    "libexec/cider/System/Library/Security/Certificates.bundle",
    "//vendor/src:certificates_bundle",
)];

/// Destinations deliberately left out, counted apart from UNMAPPED so that number can reach zero.
const OUT_OF_SCOPE: &[&str] = &[
    "libexec/cider/usr/lib/libstdc++.6.dylib",
    "libexec/cider/usr/bin/zcmp",
    "libexec/cider/usr/bin/zmore",
];

/// THE SAME THREE THE COVERAGE CHECK CARRIES: the reference predates the Cider rename.
const ARTIFACT_RENAMES: &[(&str, &str)] = &[
    ("darling-coredump", "cider-coredump"),
    ("liblibsimple_darling.a", "liblibsimple_cider.a"),
    ("liblibsimple_darlingserver.a", "liblibsimple_ciderd.a"),
];

/// TWO INSTALLED FILES CHANGED NAME, not just directory, and a destination DIRECTORY is all
/// renamed_dest ever sees, so these are applied where the basename is joined on.
const FILE_DEST_RENAMES: &[(&str, &str)] = &[
    (
        "libexec/cider/System/Library/LaunchDaemons/org.darlinghq.shellspawn.plist",
        "libexec/cider/System/Library/LaunchDaemons/me.overby.cider.shellspawn.plist",
    ),
    ("bin/darling-coredump", "bin/cider-coredump"),
];

/// A first-party source the Cider rename RENAMED as well as moved.
const SOURCE_RENAMES: &[(&str, &str)] = &[
    (
        "src/shellspawn/org.darlinghq.shellspawn.plist",
        "darwin/shellspawn/me.overby.cider.shellspawn.plist",
    ),
    // etc/ WAS A TOP LEVEL DIRECTORY HOLDING ONE FILE. It became darwin/etc during the release
    // prep, because it is guest content and darwin/ is the guest side. Without this entry the
    // generator resolves the reference path to no package and drops the install entry, which is
    // the failure srcset.rs describes: the prefix dies on `cp: cannot stat etc/resolv.conf` at
    // the very last derivation of a 2,333 builder run.
    ("etc/resolv.conf", "darwin/etc/resolv.conf"),
];

// ---------------------------------------------------------------- paths

fn basename(p: &str) -> &str {
    match p.rfind('/') {
        Some(i) => &p[i + 1..],
        None => p,
    }
}

fn dirname(p: &str) -> &str {
    match p.rfind('/') {
        Some(i) if i > 0 => &p[..i],
        Some(_) => "/",
        None => "",
    }
}

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

/// os.path.relpath, lexical.
fn relpath(target: &str, base: &str) -> String {
    let t = normpath(target);
    let b = normpath(base);
    let tp: Vec<&str> = t.split('/').filter(|s| !s.is_empty() && *s != ".").collect();
    let bp: Vec<&str> = b.split('/').filter(|s| !s.is_empty() && *s != ".").collect();
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

fn lexists(p: &str) -> bool {
    fs::symlink_metadata(p).is_ok()
}

fn is_file(p: &str) -> bool {
    fs::metadata(p).map(|m| m.is_file()).unwrap_or(false)
}

fn is_dir(p: &str) -> bool {
    fs::metadata(p).map(|m| m.is_dir()).unwrap_or(false)
}

/// re.sub(r"[^A-Za-z0-9_.+-]+", "_", rel)
fn flatten(rel: &str) -> String {
    let mut out = String::new();
    let mut run = false;
    for c in rel.chars() {
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

/// A reference destination in the spelling the port installs under. BY PATH SEGMENT: a component
/// equal to darling becomes cider, and a component merely containing it does not.
fn renamed_dest(dest: &str) -> String {
    dest.split('/').map(|c| if c == "darling" { "cider" } else { c }).collect::<Vec<_>>().join("/")
}

/// A source path relative to the repo, or None. NORMALISED here, once.
fn source_rel(repo: &str, path: &str) -> Option<String> {
    // /nix/store/<32>-<name>/<rest>
    if let Some(rest) = path.strip_prefix("/nix/store/") {
        let b = rest.as_bytes();
        if b.len() > 33 && b[..32].iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()) && b[32] == b'-'
        {
            if let Some(slash) = rest[33..].find('/') {
                return Some(normpath(&rest[33 + slash + 1..]));
            }
        }
    }
    let pre = format!("{repo}/");
    if let Some(rest) = path.strip_prefix(&pre) {
        return Some(normpath(rest));
    }
    None
}

/// A build-tree path relative to the build directory, or None.
fn build_rel(path: &str) -> Option<&str> {
    path.strip_prefix("/build/build/")
}

/// A reference source path, moved to where #87 put it. DERIVED FROM THE TREE: if src/<rest> is
/// gone and one of darwin/<rest> or linux/<rest> is there, that is where it went. An
/// UNMATERIALIZED PIN is absent from disk too, so a src/external path whose vendor/pins/ candidate is
/// not there returns UNCHANGED: absence means not materialized, not moved.
fn moved_path(repo: &str, rel: &str) -> String {
    for (k, v) in SOURCE_RENAMES {
        if rel == *k {
            return v.to_string();
        }
    }
    if !rel.starts_with("src/") {
        return rel.to_string();
    }
    if lexists(&format!("{repo}/{rel}")) {
        return rel.to_string();
    }
    let rest = &rel["src/".len()..];
    if let Some(after) = rest.strip_prefix("external/") {
        let cand = format!("vendor/pins/{after}");
        return if lexists(&format!("{repo}/{cand}")) { cand } else { rel.to_string() };
    }
    for dest in ["darwin", "linux"] {
        if lexists(&format!("{repo}/{dest}/{rest}")) {
            return format!("{dest}/{rest}");
        }
    }
    rel.to_string()
}

/// (pin, path within the pin) for a vendor/pins/<pin>/... source path, in BOTH spellings.
fn pin_of(rel: &str) -> (Option<String>, Option<String>) {
    let p = normpath(rel);
    for prefix in ["vendor/pins/", "src/external/"] {
        if let Some(rest) = p.strip_prefix(prefix) {
            if let Some(slash) = rest.find('/') {
                if slash > 0 && slash + 1 < rest.len() {
                    return (Some(rest[..slash].to_string()), Some(rest[slash + 1..].to_string()));
                }
            }
        }
    }
    (None, None)
}

/// The nearest ancestor package that can declare this file, or None.
fn owning_package(repo: &str, rel: &str) -> Option<String> {
    let mut d = dirname(rel).to_string();
    while !d.is_empty() {
        if is_file(&format!("{repo}/{d}/BUCK")) {
            return Some(d);
        }
        d = dirname(&d).to_string();
    }
    None
}

// ---------------------------------------------------------------- the manifests

/// `"((?:[^"\\]|\\.)*)"` findall: the RAW inner text of every quoted string.
fn quoted_strings(text: &str) -> Vec<String> {
    let b = text.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] != b'"' {
            i += 1;
            continue;
        }
        let start = i + 1;
        let mut j = start;
        loop {
            if j >= b.len() {
                return out;
            }
            if b[j] == b'\\' && j + 1 < b.len() {
                j += 2;
                continue;
            }
            if b[j] == b'"' {
                break;
            }
            j += 1;
        }
        out.push(text[start..j].to_string());
        i = j + 1;
    }
    out
}

/// `REGEX "((?:[^"\\]|\\.)*)" EXCLUDE` findall.
fn exclude_regexes(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0;
    while let Some(at) = text[i..].find("REGEX \"") {
        let start = i + at + "REGEX \"".len();
        let b = text.as_bytes();
        let mut j = start;
        let mut ok = false;
        while j < b.len() {
            if b[j] == b'\\' && j + 1 < b.len() {
                j += 2;
                continue;
            }
            if b[j] == b'"' {
                ok = true;
                break;
            }
            j += 1;
        }
        if !ok {
            break;
        }
        if text[j + 1..].starts_with(" EXCLUDE") {
            out.push(text[start..j].to_string());
        }
        i = j + 1;
    }
    out
}

struct Entry {
    dest: String,
    kind: String,
    srcs: Vec<String>,
    excludes: Vec<String>,
}

struct Manifests {
    entries: Vec<Entry>,
    exec_sources: HashSet<String>,
    rename_of: HashMap<(String, String), String>,
    seen: usize,
}

/// os.walk, pre-order, readdir order. The ORDER decides which of two entries wins a destination
/// collision when neither side is a dev stub, so it is reproduced rather than tidied.
fn walk_manifests(dir: &str, out: &mut Vec<String>) {
    let rd = match fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return,
    };
    let mut dirs = Vec::new();
    let mut has = false;
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let p = format!("{dir}/{name}");
        if is_dir(&p) {
            dirs.push(p);
        } else if name == "cmake_install.cmake" {
            has = true;
        }
    }
    if has {
        out.push(format!("{dir}/cmake_install.cmake"));
    }
    for d in dirs {
        if !fs::symlink_metadata(&d).map(|m| m.file_type().is_symlink()).unwrap_or(false) {
            walk_manifests(&d, out);
        }
    }
}

/// `file\(INSTALL DESTINATION "([^"]+)"\s+TYPE (\w+)((?:\s+\w+)*?)(?:\s+RENAME "([^"]+)")?\s+FILES?\s+(.*?)\)\n`
///
/// The perms group is NON-GREEDY, so the scan stops at the first RENAME or FILE(S) token rather
/// than swallowing it as a permission word. That is the whole reason the older pattern dropped
/// 167 entries: it demanded FILES right after the type modifiers.
fn parse_entries(text: &str) -> Vec<(String, String, bool, Option<String>, String)> {
    let b = text.as_bytes();
    let mut out = Vec::new();
    let needle = "file(INSTALL DESTINATION \"";
    let mut i = 0;
    while let Some(at) = text[i..].find(needle) {
        let ds = i + at + needle.len();
        i = ds;
        let de = match text[ds..].find('"') {
            Some(k) => ds + k,
            None => break,
        };
        let dest = text[ds..de].to_string();
        let mut j = de + 1;
        let skip_ws = |b: &[u8], mut k: usize| {
            while k < b.len() && (b[k] as char).is_ascii_whitespace() {
                k += 1;
            }
            k
        };
        let word_end = |b: &[u8], mut k: usize| {
            while k < b.len() && (b[k].is_ascii_alphanumeric() || b[k] == b'_') {
                k += 1;
            }
            k
        };
        let k = skip_ws(b, j);
        if k == j || !text[k..].starts_with("TYPE") {
            continue;
        }
        j = skip_ws(b, k + "TYPE".len());
        let ke = word_end(b, j);
        if ke == j {
            continue;
        }
        let kind = text[j..ke].to_string();
        j = ke;
        let mut exec_perm = false;
        let mut rename: Option<String> = None;
        let mut ok = false;
        loop {
            let ws = skip_ws(b, j);
            if ws == j {
                break;
            }
            if text[ws..].starts_with("RENAME \"") {
                let rs = ws + "RENAME \"".len();
                let re = match text[rs..].find('"') {
                    Some(k) => rs + k,
                    None => break,
                };
                rename = Some(text[rs..re].to_string());
                j = re + 1;
                continue;
            }
            let we = word_end(b, ws);
            if we == ws {
                break;
            }
            let word = &text[ws..we];
            if word == "FILES" || word == "FILE" {
                j = we;
                ok = true;
                break;
            }
            if word.contains("EXECUTE") {
                exec_perm = true;
            }
            j = we;
        }
        if !ok {
            continue;
        }
        let bs = skip_ws(b, j);
        if bs == j {
            continue;
        }
        let be = match text[bs..].find(")\n") {
            Some(k) => bs + k,
            None => break,
        };
        out.push((dest, kind, exec_perm, rename, text[bs..be].to_string()));
        i = be;
    }
    out
}

fn read_entries(root: &str) -> Result<Manifests, String> {
    let mut files = Vec::new();
    walk_manifests(root, &mut files);
    let mut m = Manifests {
        entries: Vec::new(),
        exec_sources: HashSet::new(),
        rename_of: HashMap::new(),
        seen: files.len(),
    };
    for path in &files {
        let text = match fs::read_to_string(path) {
            Ok(t) => t,
            Err(_) => continue,
        };
        for (dest_raw, kind, exec_perm, rename, blob) in parse_entries(&text) {
            let dest = dest_raw.replace("${CMAKE_INSTALL_PREFIX}/", "");
            let dest = dest.trim_end_matches('/');
            let dest = dest.strip_prefix(&format!("{INSTALL_PREFIX}/")).unwrap_or(dest);
            let dest = renamed_dest(dest.trim_end_matches('/'));
            // The excludes are quoted strings too, so the file list is what comes BEFORE the
            // first REGEX.
            let head = blob.split(" REGEX ").next().unwrap_or("");
            let srcs = quoted_strings(head);
            if exec_perm || kind == "PROGRAM" {
                m.exec_sources.extend(srcs.iter().cloned());
            }
            if let Some(r) = &rename {
                for s in &srcs {
                    m.rename_of.insert((dest.clone(), s.clone()), r.clone());
                }
            }
            m.entries.push(Entry { dest, kind, srcs, excludes: exclude_regexes(&blob) });
        }
    }
    // Loudly, because an empty walk is indistinguishable from a prefix with nothing in it.
    if m.seen == 0 {
        return Err(format!("no cmake_install.cmake under {root} -- is the graph output still present?"));
    }
    Ok(m)
}

/// ([empty directories], {destination: link value}) over every manifest.
fn read_layout(root: &str, prefix: &str) -> (Vec<String>, BTreeMap<String, String>) {
    let mut dirs: Vec<String> = Vec::new();
    let mut links: BTreeMap<String, String> = BTreeMap::new();
    let mut files = Vec::new();
    walk_manifests(root, &mut files);
    for path in &files {
        let text = match fs::read_to_string(path) {
            Ok(t) => t,
            Err(_) => continue,
        };
        // file\(INSTALL DESTINATION "([^"]+)" TYPE DIRECTORY FILES ""\)
        let needle = "file(INSTALL DESTINATION \"";
        let mut i = 0;
        while let Some(at) = text[i..].find(needle) {
            let s = i + at + needle.len();
            i = s;
            let e = match text[s..].find('"') {
                Some(k) => s + k,
                None => break,
            };
            if text[e + 1..].starts_with(" TYPE DIRECTORY FILES \"\")") {
                let d = renamed_dest(
                    text[s..e].replace("${CMAKE_INSTALL_PREFIX}/", "").trim_end_matches('/'),
                );
                if !d.is_empty() && !dirs.contains(&d) {
                    dirs.push(d);
                }
            }
        }
        // create_symlink\s+(\S+)\s+(\S+)\)
        let mut i = 0;
        while let Some(at) = text[i..].find("create_symlink") {
            let mut j = i + at + "create_symlink".len();
            i = j;
            let b = text.as_bytes();
            let ws = |b: &[u8], mut k: usize| {
                while k < b.len() && (b[k] as char).is_ascii_whitespace() {
                    k += 1;
                }
                k
            };
            let nonws = |b: &[u8], mut k: usize| {
                while k < b.len() && !(b[k] as char).is_ascii_whitespace() {
                    k += 1;
                }
                k
            };
            let a1 = ws(b, j);
            if a1 == j {
                continue;
            }
            let a2 = nonws(b, a1);
            let b1 = ws(b, a2);
            if b1 == a2 {
                continue;
            }
            let b2 = nonws(b, b1);
            if b2 == b1 {
                continue;
            }
            let target = &text[a1..a2];
            // (\S+)\) : the second token must END at a close paren, which the regex takes as part
            // of the token only when nothing else follows.
            let dest_tok = &text[b1..b2];
            let dest_tok = match dest_tok.strip_suffix(')') {
                Some(d) => d,
                None => {
                    j = b2;
                    i = j;
                    continue;
                }
            };
            // Each block has two branches, one under $ENV{DESTDIR}; they say the same thing.
            if dest_tok.contains("DESTDIR") {
                i = b2;
                continue;
            }
            let rel = renamed_dest(dest_tok.strip_prefix(prefix).unwrap_or(dest_tok).trim_start_matches('/'));
            if !rel.is_empty() {
                links.insert(rel, target.to_string());
            }
            i = b2;
        }
    }
    (dirs, links)
}

/// {build-relative path: link value} for every symlink configure left in the build tree.
fn read_symlinks(graph: &str) -> HashMap<String, String> {
    let mut links = HashMap::new();
    let path = format!("{graph}/install-symlinks.tsv");
    if !is_file(&path) {
        return links;
    }
    if let Ok(text) = fs::read_to_string(&path) {
        for line in text.split('\n') {
            let line = line.trim_end_matches('\n');
            if line.is_empty() {
                continue;
            }
            let (p, target) = match line.find('\t') {
                Some(i) => (&line[..i], line[i + 1..].to_string()),
                None => (line, String::new()),
            };
            links.insert(p.strip_prefix("./").unwrap_or(p).to_string(), target);
        }
    }
    links
}

// ---------------------------------------------------------------- the tree side

struct Binaries {
    exe: HashMap<String, String>,
    lib: HashMap<String, String>,
}

/// {kind: {output name: label}} for every executable and framework binary the port builds.
///
/// Split by KIND rather than merged, because the two collide silently: `login` is both a program
/// and a private framework, and in one namespace whichever walk order reached first won.
fn binary_index(repo: &str) -> Binaries {
    let mut out = Binaries { exe: HashMap::new(), lib: HashMap::new() };
    for (pkg, path) in walk_buck_files(repo) {
        let text = match fs::read_to_string(&path) {
            Ok(t) => t,
            Err(_) => continue,
        };
        // The python pattern is one alternation over the three rule names, so the blocks come
        // in TEXT ORDER. darwin_binary and cc_binary share the exe map and the insert is a
        // setdefault, so scanning one rule to exhaustion before the next would change the winner.
        let mut i = 0;
        loop {
            let next = ["darwin_binary(\n", "cc_binary(\n", "darwin_dylib(\n"]
                .iter()
                .filter_map(|o| text[i..].find(*o).map(|at| (i + at, *o)))
                .min_by_key(|(at, _)| *at);
            let (start, open) = match next {
                Some(v) => v,
                None => break,
            };
            let rule = open.trim_end_matches("(\n");
            {
                let mut j = start + open.len();
                let mut end = None;
                while j <= text.len() {
                    let line_end = match text[j..].find('\n') {
                        Some(k) => j + k,
                        None => break,
                    };
                    if &text[j..line_end] == ")" {
                        end = Some(line_end + 1);
                        break;
                    }
                    j = line_end + 1;
                }
                let e = match end {
                    Some(e) => e,
                    None => break,
                };
                let block = &text[start..e];
                i = e;
                let name = match quoted_after(block, "name = ") {
                    Some(n) => n,
                    None => continue,
                };
                // A dev STUB never answers a lookup by NAME: it is reachable by its reference
                // PATH and by nothing else, or the prefix ships an empty framework.
                let back = &text[start.saturating_sub(800)..start];
                if stub_pragma(back, &name) {
                    continue;
                }
                let into = if rule == "darwin_dylib" { &mut out.lib } else { &mut out.exe };
                let label = format!("//{pkg}:{name}");
                into.entry(name.clone()).or_insert_with(|| label.clone());
                if let Some(o) = quoted_after(block, "dylib_name = ") {
                    into.entry(o.clone()).or_insert_with(|| label.clone());
                    into.entry(o.strip_suffix(".dylib").unwrap_or(&o).to_string())
                        .or_insert_with(|| label.clone());
                }
                if let Some(x) = quoted_after(block, "exe_name = ") {
                    into.entry(x).or_insert_with(|| label.clone());
                }
            }
        }
    }
    out
}

/// `#\s*buck-registry:\s*(\S+)\s*=\s*<name>\s*$` in the 800 characters before a block, with the
/// left side naming a dev stub.
fn stub_pragma(back: &str, name: &str) -> bool {
    for line in back.lines() {
        let t = line.trim_start();
        let t = match t.strip_prefix('#') {
            Some(r) => r.trim_start(),
            None => continue,
        };
        let t = match t.strip_prefix("buck-registry:") {
            Some(r) => r.trim_start(),
            None => continue,
        };
        let mut parts = t.splitn(2, '=');
        let left = parts.next().unwrap_or("").trim();
        let right = parts.next().unwrap_or("").trim();
        if right == name && left.contains("/dev-stubs/") {
            return true;
        }
    }
    false
}

fn quoted_after(block: &str, key: &str) -> Option<String> {
    let at = block.find(key)?;
    let rest = &block[at + key.len()..];
    if !rest.starts_with('"') {
        return None;
    }
    let end = rest[1..].find('"')? + 1;
    if end == 1 {
        return None;
    }
    Some(rest[1..end].to_string())
}

/// {cc_objects target name: label}, for install entries that name a single object file.
fn object_groups(repo: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    for (pkg, path) in walk_buck_files(repo) {
        let text = match fs::read_to_string(&path) {
            Ok(t) => t,
            Err(_) => continue,
        };
        let needle = "cc_objects(\n    name = \"";
        let mut i = 0;
        while let Some(at) = text[i..].find(needle) {
            let s = i + at + needle.len();
            i = s;
            if let Some(k) = text[s..].find('"') {
                if k > 0 {
                    out.entry(text[s..s + k].to_string())
                        .or_insert_with(|| format!("//{pkg}:{}", &text[s..s + k]));
                }
            }
        }
    }
    out
}

struct Tables {
    ordered: Vec<HashMap<String, String>>,
    lib: HashMap<String, String>,
    exe: HashMap<String, String>,
    objects: HashMap<String, String>,
}

/// The buck2 target that builds this artifact, by output basename.
fn target_for(path: &str, t: &Tables, kind: &str) -> Option<String> {
    let raw = basename(path);
    let base = ARTIFACT_RENAMES
        .iter()
        .find(|(k, _)| *k == raw)
        .map(|(_, v)| v.to_string())
        .unwrap_or_else(|| raw.to_string());
    let mut tables: Vec<&HashMap<String, String>> = Vec::new();
    if kind == "EXECUTABLE" {
        tables.push(&t.exe);
    }
    tables.extend(t.ordered.iter());
    // BY PATH FIRST. A basename does not identify an artifact: perl builds the same 53 module
    // names twice, and resolving by name wired 54 of the 5.18 destinations to the 5.28 binary.
    if let Some(rel) = build_rel(path) {
        for table in &tables {
            if let Some(v) = table.get(rel) {
                return Some(v.clone());
            }
        }
    }
    for table in &tables {
        if let Some(v) = table.get(&base) {
            return Some(v.clone());
        }
    }
    // cmake POST_BUILD lipo renames the linker output, and the port builds the linker one.
    for table in [&t.lib, &t.exe] {
        if let Some(v) = table.get(&format!("{base}_{ARCH}")) {
            return Some(v.clone());
        }
    }
    // $<TARGET_OBJECTS:X> expands to CMakeFiles/X.dir/<source>.o, and python installs one such
    // object; the OBJECT GROUP is the answer because no library or executable exists to find.
    if path.ends_with(".o") {
        if let Some(at) = path.find("/CMakeFiles/") {
            let rest = &path[at + "/CMakeFiles/".len()..];
            if let Some(dot) = rest.find(".dir/") {
                if let Some(v) = t.objects.get(&rest[..dot]) {
                    return Some(v.clone());
                }
            }
        }
    }
    None
}

/// (label, package needing an export_file or None) for a source file the prefix installs.
fn file_label(repo: &str, rel: &str) -> (Option<String>, Option<String>) {
    let (pin, within) = pin_of(rel);
    if let (Some(pin), Some(within)) = (&pin, &within) {
        if is_dir(&format!("{repo}/vendor/src/{pin}")) {
            if is_file(&format!("{repo}/vendor/src/{pin}/BUCK")) {
                return (Some(format!("//vendor/src/{pin}:{}", flatten(within))), None);
            }
            // An unsplit pin lives in the vendor/src mega-package, and since vendor/src cannot be
            // walked to resolve a name the path is recorded as a HINT instead.
            return (
                Some(format!("//vendor/src:{}", flatten(&format!("{pin}/{within}")))),
                Some("vendor/src".to_string()),
            );
        }
    }
    // Both the package lookup and the label need the CURRENT path, not the reference one.
    let rel = moved_path(repo, rel);
    match owning_package(repo, &rel) {
        None => (None, None),
        Some(pkg) => (
            Some(format!("//{pkg}:{}", flatten(&relpath(&rel, &pkg)))),
            Some(pkg),
        ),
    }
}

/// cmake REGEX ... EXCLUDE as a buck2 glob exclusion. Only the shapes the tree uses, and a hard
/// failure otherwise: a silently dropped exclusion puts Makefiles into the prefix.
fn regex_to_glob(rx: &str) -> Result<String, String> {
    if !rx.starts_with('/') || !rx.ends_with('$') {
        return Err(format!("exclude regex is not anchored the way this understands: {rx}"));
    }
    let body = rx[1..rx.len() - 1]
        .replace("\\\\", "\\")
        .replace("[^/]*", "*")
        .replace("\\.", ".");
    if body.contains(|c| "[]()|+?^$\\".contains(c)) {
        return Err(format!("exclude regex too rich to convert to a glob: {rx}"));
    }
    Ok(format!("**/{body}"))
}

/// The prefix_dir target for an install(DIRECTORY) source: (label, package, block).
fn dir_target(repo: &str, rel: &str, excludes: &[String]) -> Result<Option<(String, String, String)>, String> {
    let (pin, within) = pin_of(rel);
    let (pin, within) = match (pin, within) {
        (Some(p), Some(w)) => (p, w),
        _ => return Ok(None),
    };
    if !is_dir(&format!("{repo}/vendor/src/{pin}")) {
        return Ok(None);
    }
    // cmake reaches out of a source directory with .. (libc installs its sibling assets).
    let within = normpath(&within);
    if within.starts_with("..") {
        return Ok(None);
    }
    // An UNSPLIT pin directories go in the vendor/src mega-package. Writing a BUCK into the pin
    // would make it a package, and every generated block naming one of its files stops seeing it.
    let (pkg, within) = if is_file(&format!("{repo}/vendor/src/{pin}/BUCK")) {
        (format!("vendor/src/{pin}"), within)
    } else {
        ("vendor/src".to_string(), format!("{pin}/{within}"))
    };
    let mut name = String::from("prefix_");
    for c in within.chars() {
        name.push(if c.is_ascii_alphanumeric() || c == '_' { c } else { '_' });
    }
    let mut ex = String::new();
    for r in excludes {
        ex.push_str(&format!("\n            \"{}\",", regex_to_glob(r)?));
    }
    let tail = if ex.is_empty() { String::new() } else { "\n        ".to_string() };
    let block = format!(
        "prefix_dir(\n    name = \"{name}\",\n    srcs = glob(\n        [\"{within}/**\"],\n\
         \x20       exclude = [{ex}{tail}],\n    ),\n    strip = \"{within}\",\n    \
         visibility = [\"PUBLIC\"],\n)\n"
    );
    Ok(Some((format!("//{pkg}:{name}"), pkg, block)))
}

/// Make sure `load` is satisfied, without duplicating an existing load of that module.
fn ensure_load(text: &str, load: &str) -> String {
    let module = match quoted_after(load, "load(") {
        Some(m) => m,
        None => return text.to_string(),
    };
    let symbols: Vec<String> = quoted_strings(load).into_iter().skip(1).collect();
    let want = format!("load(\"{module}\"");
    // ^load\("<module>"([^)]*)\)$ with re.M: one line, no close paren before the last one.
    let mut have: Option<(usize, usize)> = None;
    let mut pos = 0;
    for line in text.split('\n') {
        let start = pos;
        let end = pos + line.len();
        pos = end + 1;
        if line.starts_with(&want)
            && line.ends_with(')')
            && !line[want.len()..line.len() - 1].contains(')')
        {
            have = Some((start, end));
            break;
        }
    }
    let (hs, he) = match have {
        None => return format!("{load}\n{text}"),
        Some(v) => v,
    };
    let existing = &text[hs..he];
    let missing: Vec<&String> =
        symbols.iter().filter(|s| !existing.contains(&format!("\"{s}\""))).collect();
    if missing.is_empty() {
        return text.to_string();
    }
    let add: String = missing.iter().map(|s| format!(", \"{s}\"")).collect();
    format!("{}{}{}", &text[..he - 1], add, &text[he - 1..])
}

/// Replace a generated block in a package BUCK file, creating the file if absent.
fn write_block(repo: &str, pkg: &str, blocks: &[String], kind: &str, load: &str) -> Result<(), String> {
    let path = format!("{repo}/{pkg}/BUCK");
    let begin = format!("# BEGIN generated: {kind}");
    let end = format!("# END generated: {kind}");
    let body = format!(
        "{begin}\n# GENERATED from the reference build's install entries by\n\
         # cider-install-from-manifests -- review before committing.\n\n{}{end}\n",
        blocks.join("\n")
    );
    let text = fs::read_to_string(&path).unwrap_or_default();
    let mut text = if let Some(i) = text.find(&begin) {
        match text[i..].find(&end) {
            Some(j) => {
                let stop = i + j + end.len();
                let stop = if text[stop..].starts_with('\n') { stop + 1 } else { stop };
                format!("{}{}{}", &text[..i], body, &text[stop..])
            }
            None => format!("{}{}", text.trim_end_matches('\n'), body),
        }
    } else if !text.trim().is_empty() {
        format!("{}\n\n{}", text.trim_end_matches('\n'), body)
    } else {
        body
    };
    text = ensure_load(&text, load);
    if let Some(parent) = std::path::Path::new(&path).parent() {
        let _ = fs::create_dir_all(parent);
    }
    fs::write(&path, text).map_err(|e| format!("cannot write {path}: {e}"))
}

fn die(msg: String) -> ExitCode {
    eprintln!("{msg}");
    ExitCode::FAILURE
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let repo = match repo_root() {
        Ok(r) => r,
        Err(e) => return die(e),
    };
    let graph = match argv.iter().position(|a| a == "--manifests") {
        Some(i) => match argv.get(i + 1) {
            Some(v) => v.clone(),
            None => return die("--manifests wants a directory".to_string()),
        },
        None => fs::canonicalize(format!("{repo}/result-graph-ref"))
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| format!("{repo}/result-graph-ref")),
    };
    let root = format!("{graph}/install-manifests");
    if !is_dir(&root) {
        return die(format!("no install manifests at {root} -- build .#cider-graph-stock first"));
    }

    let binaries = binary_index(&repo);
    let links = read_symlinks(&graph);
    let man = match read_entries(&root) {
        Ok(m) => m,
        Err(e) => return die(e),
    };
    let (empty_dirs, abs_links) = read_layout(&root, INSTALL_PREFIX);

    let generated: HashMap<String, String> =
        GENERATED.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    let tables = Tables {
        ordered: vec![
            final_registry(&repo),
            archive_registry(&repo),
            binaries.lib.clone(),
            binaries.exe.clone(),
            generated,
        ],
        lib: binaries.lib.clone(),
        exe: binaries.exe.clone(),
        objects: object_groups(&repo),
    };

    let installed_base = |dest: &str, src: &str| -> String {
        man.rename_of
            .get(&(dest.to_string(), src.to_string()))
            .cloned()
            .unwrap_or_else(|| basename(src).to_string())
    };
    let file_dest_rename = |full: &str| -> String {
        FILE_DEST_RENAMES
            .iter()
            .find(|(k, _)| *k == full)
            .map(|(_, v)| v.to_string())
            .unwrap_or_else(|| full.to_string())
    };

    // Where each installed source ends up, so a symlink can be expressed against the DESTINATION
    // of the thing it points at rather than against a build path.
    let mut dest_of: HashMap<String, String> = HashMap::new();
    for e in &man.entries {
        for src in &e.srcs {
            if src.is_empty() {
                continue;
            }
            let base = installed_base(&e.dest, src);
            let full = if e.dest.is_empty() { base } else { format!("{}/{}", e.dest, base) };
            dest_of.insert(src.clone(), file_dest_rename(&full));
        }
    }
    let all_dests: HashSet<&String> = dest_of.values().collect();

    let mut built: BTreeMap<String, String> = BTreeMap::new();
    let mut sources: BTreeMap<String, String> = BTreeMap::new();
    let mut exec_files: BTreeMap<String, String> = BTreeMap::new();
    let mut symlinks: BTreeMap<String, String> = BTreeMap::new();
    let mut dirs: BTreeMap<String, String> = BTreeMap::new();
    let mut unmapped: Vec<(String, String)> = Vec::new();
    let mut skipped: Vec<String> = Vec::new();
    let mut collisions: Vec<(String, String, String)> = Vec::new();
    let mut blocks: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut exports: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    let mut hints: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();

    for e in &man.entries {
        for src in &e.srcs {
            if src.is_empty() {
                continue;
            }
            let full = dest_of[src].clone();
            if OUT_OF_SCOPE.contains(&full.as_str()) {
                skipped.push(full);
                continue;
            }
            if e.kind == "SHARED_LIBRARY" || e.kind == "EXECUTABLE" || e.kind == "STATIC_LIBRARY" {
                match target_for(src, &tables, &e.kind) {
                    Some(t) => resolve(&mut built, &mut collisions, &full, &t, src),
                    None => unmapped.push((full, "no target builds it".to_string())),
                }
            } else if e.kind == "FILE" || e.kind == "PROGRAM" {
                if let Some(brel) = build_rel(src) {
                    if let Some(value) = links.get(brel) {
                        // A symlink InstallSymlink left in the build tree. Its value is relative
                        // to the link itself, so resolve it there and ask where THAT lands.
                        let target = normpath(&pjoin(dirname(src), value));
                        if let Some(d) = dest_of.get(&target) {
                            symlinks.insert(full, d.clone());
                        } else {
                            // Resolving the value against the DESTINATION instead is what a
                            // relative symlink actually means: openssl_certificates 159 hash
                            // links are made at configure time, so no edge builds them.
                            let cand = if e.dest.is_empty() {
                                value.clone()
                            } else {
                                normpath(&format!("{}/{}", e.dest, value))
                            };
                            if all_dests.contains(&cand) {
                                symlinks.insert(full, cand);
                            } else {
                                unmapped.push((
                                    full,
                                    format!("links to {value}, which is not installed"),
                                ));
                            }
                        }
                        continue;
                    }
                }
                if let Some(rel) = source_rel(&repo, src) {
                    let (label, needs_export) = file_label(&repo, &rel);
                    let label = match label {
                        Some(l) => l,
                        None => {
                            unmapped.push((full, format!("{rel} is in no package")));
                            continue;
                        }
                    };
                    let name = label.splitn(2, ':').nth(1).unwrap_or("").to_string();
                    if man.exec_sources.contains(src) {
                        exec_files.insert(full, label.clone());
                    } else {
                        sources.insert(full, label.clone());
                    }
                    match needs_export.as_deref() {
                        Some("vendor/src") => {
                            // EITHER SPELLING, and NOT through moved_path: vendor/src mirrors each
                            // upstream tree under its bare name, and moved_path answers from DISK
                            // where an unmaterialised pin is absent.
                            let hint = rel
                                .strip_prefix("src/external/")
                                .map(|s| s.to_string())
                                .unwrap_or_else(|| {
                                    rel.strip_prefix("vendor/pins/").unwrap_or(&rel).to_string()
                                });
                            hints.entry("vendor/src".to_string()).or_default().insert(name, hint);
                        }
                        Some(pkg) => {
                            // THE MOVED PATH: relpath against the NEW package with the OLD path
                            // spells a src full of ../.
                            let sp = relpath(&moved_path(&repo, &rel), pkg);
                            exports.entry(pkg.to_string()).or_default().insert(name, sp);
                        }
                        None => {}
                    }
                    continue;
                }
                match target_for(src, &tables, "") {
                    Some(t) => resolve(&mut built, &mut collisions, &full, &t, src),
                    None => unmapped.push((full, "build output with no target".to_string())),
                }
            } else if e.kind == "DIRECTORY" {
                // A trailing slash means the CONTENTS go to the destination; without one the
                // directory itself does, under its own name.
                let where_ = if src.ends_with('/') {
                    e.dest.clone()
                } else {
                    format!("{}/{}", e.dest, installed_base(&e.dest, src))
                };
                if let Some((_, t)) = EXTRA_DIRS.iter().find(|(k, _)| *k == where_) {
                    dirs.insert(where_, t.to_string());
                    continue;
                }
                let info = match source_rel(&repo, src) {
                    Some(rel) => match dir_target(&repo, &rel, &e.excludes) {
                        Ok(v) => v,
                        Err(err) => return die(err),
                    },
                    None => None,
                };
                let (label, pkg, block) = match info {
                    Some(v) => v,
                    None => {
                        let tail: String = if src.chars().count() > 50 {
                            src.chars().skip(src.chars().count() - 50).collect()
                        } else {
                            src.clone()
                        };
                        unmapped.push((
                            e.dest.clone(),
                            format!("install(DIRECTORY) of {tail}, not a pin path"),
                        ));
                        continue;
                    }
                };
                dirs.insert(where_, label);
                let v = blocks.entry(pkg).or_default();
                if !v.contains(&block) {
                    v.push(block);
                }
            } else {
                unmapped.push((full, format!("unhandled install type {}", e.kind)));
            }
        }
    }

    for (k, v) in EXTRA {
        built.insert(k.to_string(), v.to_string());
    }

    // A symlink whose destination did not SURVIVE: the check inside the loop asks whether the
    // target is an install entry at all, which it can be while still being dropped for having no
    // target that builds it. Left in, the prefix rule fails on a link into nothing.
    loop {
        let present: HashSet<&String> = built
            .keys()
            .chain(sources.keys())
            .chain(exec_files.keys())
            .chain(dirs.keys())
            .chain(empty_dirs.iter())
            .collect();
        let dangling: Vec<(String, String)> = symlinks
            .iter()
            .filter(|(_, t)| !present.contains(t) && !symlinks.contains_key(*t))
            .map(|(d, t)| (d.clone(), t.clone()))
            .collect();
        if dangling.is_empty() {
            break;
        }
        for (d, t) in dangling {
            unmapped.push((d.clone(), format!("links to {t}, which is not in the prefix")));
            symlinks.remove(&d);
        }
    }

    println!("install entries: {}", man.entries.len());
    println!("  built artifacts mapped to targets: {}", built.len());
    println!("  source files:                      {}", sources.len());
    println!("  source files (executable):         {}", exec_files.len());
    println!("  symlinks:                          {}", symlinks.len());
    println!("  directories:                       {}", dirs.len());
    println!("  empty directories:                 {}", empty_dirs.len());
    println!("  symlinks outside the tree:         {}", abs_links.len());
    println!("  out of scope:                      {}", skipped.len());
    println!("  UNMAPPED:                          {}", unmapped.len());
    for (full, why) in &unmapped {
        println!("      {full}  ({why})");
    }
    if !collisions.is_empty() {
        println!("  destination collisions (real wins): {}", collisions.len());
        for (full, keep, drop) in &collisions {
            println!("      {full}\n          kept {keep}\n          over {drop}");
        }
    }

    if !argv.iter().any(|a| a == "--write") {
        return ExitCode::SUCCESS;
    }

    for (pkg, bs) in &blocks {
        if let Err(e) = write_block(
            &repo,
            pkg,
            bs,
            "prefix dirs",
            "load(\"//buck/rules:install.bzl\", \"prefix_dir\")",
        ) {
            return die(e);
        }
        println!("wrote {pkg}/BUCK: {} prefix_dir target(s)", bs.len());
    }

    if !hints.is_empty() {
        let f = format!("{repo}/buck/generated/export-hints.json");
        let mut have: BTreeMap<String, BTreeMap<String, String>> = fs::read_to_string(&f)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        let mut n = 0;
        for (pkg, entries) in &hints {
            let into = have.entry(pkg.clone()).or_default();
            for (k, v) in entries {
                into.insert(k.clone(), v.clone());
                n += 1;
            }
        }
        let rendered = serde_json::to_string_pretty(&have).unwrap_or_default() + "\n";
        if let Err(e) = fs::write(&f, rendered) {
            return die(format!("cannot write {f}: {e}"));
        }
        println!("wrote buck/generated/export-hints.json: {n} hint(s)");
    }

    for (pkg, files) in &exports {
        let mut block = String::new();
        for (n, sp) in files {
            block.push_str(&format!(
                "export_file(\n    name = \"{n}\",\n    src = \"{sp}\",\n    visibility = [\"PUBLIC\"],\n)\n\n"
            ));
        }
        if let Err(e) = write_block(
            &repo,
            pkg,
            &[block],
            "prefix exports",
            "load(\"//buck/rules:files.bzl\", \"export_file\")",
        ) {
            return die(e);
        }
        println!("wrote {pkg}/BUCK: {} export_file target(s)", files.len());
    }

    let mut lines: Vec<String> = vec![
        "load(\"//buck/rules:install.bzl\", \"prefix_tree\")".to_string(),
        String::new(),
        "# GENERATED from the reference build's cmake_install.cmake manifests by".to_string(),
        "# cider-install-from-manifests -- review before committing.".to_string(),
        "prefix_tree(".to_string(),
        "    name = \"cider_prefix\",".to_string(),
        "    entries = {".to_string(),
    ];
    for (dest, t) in &built {
        lines.push(format!("        \"{dest}\": \"{t}\","));
    }
    lines.push("    },".to_string());
    lines.push("    trees = {".to_string());
    for (dest, t) in &dirs {
        lines.push(format!("        \"{dest}\": \"{t}\","));
    }
    lines.push("    },".to_string());
    lines.push("    files = {".to_string());
    for (dest, t) in &sources {
        lines.push(format!("        \"{dest}\": \"{t}\","));
    }
    lines.push("    },".to_string());
    lines.push("    exec_files = {".to_string());
    for (dest, t) in &exec_files {
        lines.push(format!("        \"{dest}\": \"{t}\","));
    }
    lines.push("    },".to_string());
    lines.push("    symlinks = {".to_string());
    for (dest, t) in &symlinks {
        lines.push(format!("        \"{dest}\": \"{t}\","));
    }
    lines.push("    },".to_string());
    lines.push("    links = {".to_string());
    for (dest, t) in &abs_links {
        lines.push(format!("        \"{dest}\": \"{t}\","));
    }
    lines.push("    },".to_string());
    lines.push("    dirs = [".to_string());
    let sorted_dirs: BTreeSet<&String> = empty_dirs.iter().collect();
    for d in sorted_dirs {
        lines.push(format!("        \"{d}\","));
    }
    lines.push("    ],".to_string());
    lines.push("    visibility = [\"PUBLIC\"],".to_string());
    lines.push(")".to_string());
    lines.push(String::new());

    let out = format!("{repo}/buck/prefix/BUCK");
    if let Some(parent) = std::path::Path::new(&out).parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Err(e) = fs::write(&out, lines.join("\n")) {
        return die(format!("cannot write {out}: {e}"));
    }
    println!(
        "wrote buck/prefix/BUCK: {} target(s), {} file(s), {} symlink(s)",
        built.len() + dirs.len(),
        sources.len(),
        symlinks.len()
    );
    ExitCode::SUCCESS
}

/// TWO ENTRIES, ONE DESTINATION. The reference installs both the real framework and its dev STUB
/// to the same path, so whichever entry is read last would win. The real implementation wins,
/// always: a stub exists so a program can LINK against a framework that is not built, and
/// shipping it in place of the real one takes NSApplication down with it.
fn resolve(
    built: &mut BTreeMap<String, String>,
    collisions: &mut Vec<(String, String, String)>,
    full: &str,
    t: &str,
    src: &str,
) {
    match built.get(full) {
        Some(have) if have != t => {
            let keep = if src.contains("/dev-stubs/") { have.clone() } else { t.to_string() };
            let drop = if keep == *have { t.to_string() } else { have.clone() };
            collisions.push((full.to_string(), keep.clone(), drop));
            built.insert(full.to_string(), keep);
        }
        _ => {
            built.insert(full.to_string(), t.to_string());
        }
    }
}
