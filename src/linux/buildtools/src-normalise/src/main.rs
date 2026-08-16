//! Make the materialized pins crawlable by buck2. The Rust rewrite of the python normaliser
//! (buck-src-normalise.py, deleted by #99).
//!
//! buck2 rejects two kinds of symlink outright, and both occur in the upstream trees:
//!
//!   * a target with a "." component ("path contains platform-specific path separator"),
//!     e.g. corefoundation's CFArray.h -> include/CoreFoundation/./CFArray.h;
//!   * a target that leaves the cell ("expected a normalized path"), e.g. libnotify's
//!     cider/src/notify.defs -> ../../../../../darwin/.../usr/include/mach/notify.defs,
//!     which reaches back into the repo's SDK symlink farm.
//!
//! Both are rewritten to point at the same file INSIDE vendor/src: the SDK farm's own links end
//! in vendor/pins/<pin>/..., which is exactly vendor/src/<pin>/....
//!
//! A third case has nothing to do with targets: buck2's globs do not descend into a symlinked
//! DIRECTORY, so a header behind one is invisible to the package that needs it. Those are
//! expanded into a real directory of per-file links.
//!
//! Run after scripts/buck-src.nu (it invokes this itself) and from assembleProject in
//! nix/lib/ciderBuck2Graph.nix; safe to re-run, and re-running it is the normal case.
//!
//! Usage: cider-src-normalise [--repo <root>] [<tree> ...]
//!
//! BUILT BY NIX, NOT BY BUCK2, like the other #99 tools: this one prepares the very tree buck2
//! then crawls, so building it with buck2 would be circular.

use std::env;
use std::fs;
use std::io;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::Path;
use std::sync::OnceLock;

mod pypath;
use pypath::{abspath, dirname, join2, normpath, relpath};

/// Where upstream pins live in this repo. Named once so the join below cannot drift from the
/// rename table, which is the drift that broke #87 stage 2's first rung.
const PIN_ROOT: &str = "vendor/pins";

/// WE RENAMED FIRST-PARTY DIRECTORIES; UPSTREAM DID NOT, and a pin links into the layout
/// upstream has. 2,078 links under vendor/src/security/darling/submodules/xnu name
/// vendor/pins/darlingserver/duct-tape/xnu, which is where that tree lives in Darling and has not
/// existed here since the Cider rename and the duct-tape to xnu-sys move.
///
/// THIS CLASS IS INVISIBLE TO EVERY CONTENT SWEEP, and that is the whole lesson: a symlink
/// TARGET is not file content, so grep does not read it and no rename script that rewrites
/// files can reach it. It surfaced only as a buck2 package load failure four minutes into the
/// endpoint, naming a path that appears nowhere in the tree:
///     File not found: root//vendor/src/darlingserver/duct-tape/xnu
/// Longest prefix first, so the duct-tape entry wins over the plain one.
///
/// THE ROOT MOVED TOO, AND THAT IS A SEPARATE ENTRY. #87 stage 2 emptied src/ into src/darwin/,
/// src/linux/ and vendor/pins/, so a link written before it names src/external/<pin> for what is now
/// vendor/pins/<pin>. All 2,077 of those had an existing vendor/pins/ counterpart when it was measured, 0
/// missing, so that entry is a re-rooting rather than a guess about where the tree went.
const FIRST_PARTY_RENAMES: &[(&str, &str)] = &[
    ("vendor/pins/darlingserver/duct-tape", "vendor/pins/ciderd/xnu-sys"),
    ("vendor/pins/darlingserver", "vendor/pins/ciderd"),
    ("src/external", PIN_ROOT),
];

/// Translate an upstream-era first-party path to where it lives now.
fn rename_first_party(rel: &str) -> String {
    for (old, new) in FIRST_PARTY_RENAMES {
        if rel == *old || rel.starts_with(&format!("{old}/")) {
            return format!("{}{}", new, &rel[old.len()..]);
        }
    }
    rel.to_string()
}

/// The process cwd, read ONCE. python's os.path.abspath reads it on every call; nothing here
/// chdirs, so one read is the same answer, and it keeps a getcwd syscall out of the per-file
/// mirror loop.
fn cwd() -> &'static str {
    static CWD: OnceLock<String> = OnceLock::new();
    CWD.get_or_init(|| {
        std::env::current_dir()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| "/".to_string())
    })
}

fn lexists(p: &str) -> bool {
    fs::symlink_metadata(p).is_ok()
}

fn exists(p: &str) -> bool {
    Path::new(p).exists()
}

fn is_link(p: &str) -> bool {
    fs::symlink_metadata(p)
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
}

/// True when the path resolves to a directory, symlinks FOLLOWED, which is how python's
/// os.walk decides whether an entry is a directory. A dangling link is therefore a file here,
/// and that is deliberate: main() has to see one to fix it.
fn is_dir_follow(p: &str) -> bool {
    fs::metadata(p).map(|m| m.is_dir()).unwrap_or(false)
}

/// readlink, or None for a target that is not UTF-8. Nothing in these trees has one; the
/// alternative to reporting it would be a lossy conversion, which turns a path this tool
/// cannot handle into a path it handles WRONGLY.
fn read_link(p: &str) -> Option<String> {
    let t = fs::read_link(p).ok()?;
    match t.to_str() {
        Some(s) => Some(s.to_string()),
        None => {
            eprintln!("vendor/src: non-UTF-8 symlink target, left alone: {p}");
            None
        }
    }
}

struct Ctx {
    repo: String,
    buck_src: String,
    cwd: String,
}

impl Ctx {
    fn new(repo: &str, cwd: &str) -> Ctx {
        // ABSOLUTE, because the comparisons in in_tree_target are: with a relative tree
        // argument they silently never matched, and the in-tree cases fell through to the
        // escape handling.
        let repo = abspath(repo, cwd);
        let buck_src = join2(&repo, "vendor/src");
        Ctx { repo, buck_src, cwd: cwd.to_string() }
    }

    /// Where a link should point instead, or None to leave it alone.
    fn in_tree_target(&self, link: &str, target: &str) -> Option<String> {
        let parts: Vec<&str> = target.split('/').filter(|c| *c != ".").collect();
        if parts.len() != target.split('/').count() {
            return Some(parts.join("/"));
        }

        if target.starts_with('/') {
            return None;
        }
        let mut resolved = abspath(&join2(dirname(link), target), &self.cwd);
        let buck_src_slash = format!("{}/", self.buck_src);
        if resolved.starts_with(&buck_src_slash) {
            if lexists(&resolved) {
                return None; // already inside the tree and resolving
            }
            // Inside vendor/src but DANGLING: the link names a sibling pin that is not
            // materialized here because it lives in the repo proper. security's
            // darling/submodules/xnu points at ciderd/xnu-sys/xnu that way, and ciderd is at
            // vendor/pins/ciderd, not a pin. A dangling link is not merely unused -- a glob that
            // picks it up fails the whole package load. And the name it uses is UPSTREAM's,
            // so the candidate goes through the rename table too. In the Nix graph derivation
            // these links resolve INSIDE vendor/src rather than to pins, which is why fixing
            // only the other branch left the endpoint failing with the re-pointed count still
            // at 103.
            let rel = &resolved[self.buck_src.len() + 1..];
            // PIN_ROOT, not the two literals this used to join. It said join("src", "external",
            // rel), and #87 stage 2 moved the pin root to vendor/pins/. Because the path was ASSEMBLED
            // FROM SEPARATE ARGUMENTS rather than written out, no textual sweep could see it:
            // the rename table moved to vendor/pins/ and this went on building src/external/..., so
            // the security link stayed dangling and the graph died with "File not found:
            // root//vendor/src/darlingserver/duct-tape/xnu".
            let cand = join2(&self.repo, &rename_first_party(&join2(PIN_ROOT, rel)));
            if lexists(&cand) {
                return Some(relpath(&cand, dirname(link), &self.cwd));
            }
            return None;
        }
        if !resolved.starts_with(&format!("{}/", self.repo)) {
            // The link escapes the repo entirely: it was written for a tree of a different
            // depth (libnotify's cider/src/notify.defs climbs five levels to reach what is
            // src/darwin/... from the repo root). Recover the intent by resolving what follows the
            // leading ../ run against the repo root.
            let mut tail = target.trim_start_matches(['.', '/']).to_string();
            while let Some(rest) = tail.strip_prefix("../") {
                tail = rest.to_string();
            }
            let mut cand = normpath(&join2(&self.repo, &tail));
            if !lexists(&cand) {
                // Task #68 moved the guest trees under src/darwin/, and a pin written before that
                // still says Developer/... from the repo root.
                cand = normpath(&join2(&join2(&self.repo, "src/darwin"), &tail));
            }
            if !lexists(&cand) {
                return None;
            }
            resolved = cand;
        }

        // Follow the chain TEXTUALLY: the repo's SDK farm is itself symlinks into
        // vendor/pins/<pin>, which is what vendor/src holds a copy of.
        let mut seen: Vec<String> = Vec::new();
        let mut cur = resolved;
        while is_link(&cur) && !seen.contains(&cur) {
            seen.push(cur.clone());
            let t = read_link(&cur)?;
            cur = normpath(&join2(dirname(&cur), &t));
        }
        let rel = relpath(&cur, &self.repo, &self.cwd);
        // A renamed first-party tree is in the REPO, not in vendor/src, so it resolves here
        // rather than through the pin copy below.
        let renamed = rename_first_party(&rel);
        if renamed != rel {
            let cand = join2(&self.repo, &renamed);
            if lexists(&cand) {
                return Some(relpath(&cand, dirname(link), &self.cwd));
            }
            return None;
        }
        let rest = rel.strip_prefix("vendor/pins/")?;
        let inside = join2(&self.buck_src, rest);
        // exists, NOT lexists: a pin copy whose own link dangles is no use as a destination.
        if !exists(&inside) {
            return None;
        }
        Some(relpath(&inside, dirname(link), &self.cwd))
    }
}

/// The directory entries of `dir`, split the way python's os.walk splits them: directories
/// first (symlinks followed to decide), then everything else. Order within each half is
/// readdir order, which is what os.scandir gives python.
fn split_entries(dir: &str) -> (Vec<String>, Vec<String>) {
    let mut dirs = Vec::new();
    let mut files = Vec::new();
    let rd = match fs::read_dir(dir) {
        Ok(rd) => rd,
        // os.walk's default onerror is None, which means an unreadable directory is skipped
        // silently. Matched here rather than improved on: this tool runs inside a derivation
        // whose failure mode should stay the one the python had.
        Err(_) => return (dirs, files),
    };
    for ent in rd.flatten() {
        let name = match ent.file_name().to_str() {
            Some(n) => n.to_string(),
            None => {
                eprintln!("vendor/src: non-UTF-8 name, left alone: {dir}");
                continue;
            }
        };
        if is_dir_follow(&join2(dir, &name)) {
            dirs.push(name);
        } else {
            files.push(name);
        }
    }
    (dirs, files)
}

fn make_writable(dir: &str) -> io::Result<()> {
    let mut perm = fs::metadata(dir)?.permissions();
    perm.set_mode(perm.mode() | 0o200);
    fs::set_permissions(dir, perm)
}

fn repoint_links(ctx: &Ctx, root: &str, fixed: &mut usize, skipped: &mut usize) {
    let (dirs, files) = split_entries(root);
    for name in dirs.iter().chain(files.iter()) {
        let path = join2(root, name);
        if !is_link(&path) {
            continue;
        }
        let target = match read_link(&path) {
            Some(t) => t,
            None => continue,
        };
        let new = match ctx.in_tree_target(&path, &target) {
            Some(n) if n != target => n,
            _ => continue,
        };
        let d = dirname(&path).to_string();
        let write = || -> io::Result<()> {
            make_writable(&d)?;
            fs::remove_file(&path)?;
            symlink(&new, &path)
        };
        match write() {
            Ok(()) => *fixed += 1,
            Err(_) => *skipped += 1,
        }
    }
    // Pre-order, and NOT into a symlinked directory: os.walk(followlinks=False) does not, and
    // descending would walk a pin's copy of another pin.
    for name in dirs {
        let sub = join2(root, &name);
        if !is_link(&sub) {
            repoint_links(ctx, &sub, fixed, skipped);
        }
    }
}

/// Every (dir, files) pair under `target`, symlinked subdirectories NOT descended into and NOT
/// listed as files. That omission is python's os.walk behaviour and is load bearing: a
/// symlinked subdir inside an expanded tree stays out of the mirror rather than becoming a
/// broken file link.
fn walk_real(target: &str, out: &mut Vec<(String, Vec<String>)>) {
    let (dirs, files) = split_entries(target);
    out.push((target.to_string(), files));
    for name in dirs {
        let sub = join2(target, &name);
        if !is_link(&sub) {
            walk_real(&sub, out);
        }
    }
}

/// Replace a symlinked DIRECTORY with a real one holding a link per file.
///
/// buck2's globs do not descend into a symlinked directory, so a header behind one is
/// invisible: security ships cider/include/macOS/security_libDER/libDER as a link to
/// ../libDER, and `macOS/**/*.h` staged everything EXCEPT what lived behind it. The compile
/// then failed on security_libDER/libDER/libDER.h while the file was plainly there on disk.
///
/// A directory of per-file links is the shape the repo's own SDK farm uses -- roughly 1,900 of
/// them -- and buck2 globs and stages those without trouble.
fn expand_dir_links(root_of_walk: &str, root: &str, changed: &mut usize) {
    let (dirs, _files) = split_entries(root_of_walk);
    let mut descend: Vec<String> = Vec::new();
    for name in dirs {
        let link = join2(root_of_walk, &name);
        if !is_link(&link) {
            descend.push(name);
            continue;
        }
        // realpath, and it fails on a dangling link, which is the same "not a directory that
        // exists" answer python's isdir/exists pair gives.
        let target = match fs::canonicalize(&link).ok().and_then(|t| t.to_str().map(String::from)) {
            Some(t) if Path::new(&t).is_dir() => t,
            _ => continue,
        };
        // A link pointing at its OWN ancestor is a cycle, and expanding one walks into the tree
        // it is itself creating. JavaScriptCore has exactly one --
        // DerivedSources/JavaScriptCore/JavaScriptCore -> ../.. -- and running this over it
        // turned 13 directories at 5 levels into 1147 at 266 before ENAMETOOLONG stopped it.
        // The swallowed error below then reported expanding nothing while having wrecked the
        // tree; buck2 crawls what is left and `aquery` dies with "File name too long". That is
        // what broke the Nix endpoint while the host, whose vendor/src still held the plain
        // symlink, kept building.
        let here = match fs::canonicalize(root_of_walk).ok().and_then(|t| t.to_str().map(String::from)) {
            Some(d) => join2(&d, &name),
            None => continue,
        };
        if here == target || here.starts_with(&format!("{target}/")) {
            let shown = read_link(&link).unwrap_or_default();
            println!(
                "vendor/src: left cyclic dir link alone: {} -> {}",
                relpath(&link, root, cwd()),
                shown
            );
            continue;
        }
        let expand = || -> io::Result<()> {
            make_writable(root_of_walk)?;
            fs::remove_file(&link)?;
            let mut tree: Vec<(String, Vec<String>)> = Vec::new();
            walk_real(&target, &mut tree);
            for (sub, files) in tree {
                let rel = relpath(&sub, &target, cwd());
                let dest = if rel == "." { link.clone() } else { join2(&link, &rel) };
                fs::create_dir_all(&dest)?;
                for f in files {
                    // NEVER MIRROR A BUCK FILE. buck2 reads one as a PACKAGE definition, so a
                    // mirror that carries it defines the whole target set a SECOND time under
                    // the nested path, and both copies then get built. Measured 2026-08-10: the
                    // two mirrors here contributed 91 duplicate ruby dylib targets and 4
                    // duplicate xnu ones, which is the entire growth in the dylib count since
                    // 08-09. .buckconfig sets [buildfile] name = BUCK, so that one name is the
                    // whole rule.
                    if f == "BUCK" {
                        continue;
                    }
                    let d = join2(&dest, &f);
                    if !lexists(&d) {
                        symlink(relpath(&join2(&sub, &f), &dest, cwd()), &d)?;
                    }
                }
            }
            Ok(())
        };
        if expand().is_ok() {
            *changed += 1;
        }
        // Not descended into either way: an expanded tree is per-file links, and a failed
        // expansion is not made better by walking what is left of it.
    }
    for name in descend {
        expand_dir_links(&join2(root_of_walk, &name), root, changed);
    }
}

fn main() {
    let mut argv: Vec<String> = env::args().skip(1).collect();
    let cwd = cwd();
    // The project root. Overridable with --repo because the Nix endpoint runs this FROM THE
    // STORE: there the executable's parent has no project under it, and the rewrite that needs
    // the project (an escaping link, resolved through the SDK farm) would silently find
    // nothing to point at while the "." case kept working.
    let mut repo = env::current_exe()
        .ok()
        .and_then(|p| p.parent().and_then(|p| p.parent()).map(|p| p.to_string_lossy().into_owned()))
        .unwrap_or_else(|| cwd.to_string());
    if let Some(i) = argv.iter().position(|a| a == "--repo") {
        if i + 1 >= argv.len() {
            eprintln!("cider-src-normalise: --repo needs a path");
            std::process::exit(2);
        }
        repo = argv[i + 1].clone();
        argv.drain(i..i + 2);
    }
    let ctx = Ctx::new(&repo, cwd);

    let roots: Vec<String> = if argv.is_empty() { vec![ctx.buck_src.clone()] } else { argv };

    let (mut fixed, mut skipped) = (0usize, 0usize);
    for root in &roots {
        repoint_links(&ctx, root, &mut fixed, &mut skipped);
    }
    let mut expanded = 0usize;
    for root in &roots {
        expand_dir_links(root, root, &mut expanded);
    }
    if expanded > 0 {
        println!("vendor/src: expanded {expanded} symlinked director(ies) into per-file links");
    }
    if fixed > 0 || skipped > 0 {
        let tail = if skipped > 0 {
            format!(", {skipped} could not be written")
        } else {
            String::new()
        };
        println!("vendor/src: re-pointed {fixed} symlink(s) into the tree{tail}");
    }
}
