//! Reduce the project to what the graph derivation actually reads.
//!
//! Why this exists. The graph derivation took the whole project, so editing one .c file reran
//! it, 30 to 47 minutes, before a single compile could start. Under content addressing that is
//! not a cascade, the lowered derivations do not all rebuild afterwards, but it is a fixed tax
//! on every edit and it is the reason iteration on this port is slow.
//!
//! It is unnecessary, because buck2 analysis CANNOT read source file contents. Analysis is a
//! pure function of the target graph and the configuration; source files are artifacts that
//! exist only at execution. Measured on the real dump to confirm it rather than assume it: the
//! data output is 6.9 MB of staged/ that is 166 rule generated scripts and value files
//! (rustc.sh, forward.py, configure.py, values.json), plus treelinks/ which is link names. Not
//! one byte of source content reaches either.
//!
//! Analysis alone would let EVERY file be emptied, since analysis cannot read a source at all.
//! It is not analysis alone: the derivation also materialises the in-process artifacts, and a
//! staged farm of GENERATED headers is only materialised by running its generator, which does
//! read real bytes. So the C family is emptied and everything else is copied whole.
//!
//! The output is content addressed by its consumer, so editing a .c or a .h leaves it byte
//! identical and the graph derivation does not rerun at all. Editing a BUCK file, a .defs, a
//! grammar or a generator script changes it, and the graph correctly rebuilds.
//!
//! Usage:
//!   cider-skeleton <src> <out> [--keep <file of paths to never empty>]
//!
//! ====================================================================================
//! PORTED FROM scripts/buck-skeleton.py (#99), and it is the FIRST build-path script to move
//! off Python. Verified byte-for-byte against it: same tree, same file contents, same symlink
//! TARGET STRINGS, same modes, same stderr summary, same exit codes.
//!
//! WHY THIS ONE FIRST. Every build-path script runs inside a derivation whose output is content
//! addressed, and this is the only one with a derivation of its OWN (skeletonSrc,
//! nix/lib/ciderBuck2Graph.nix:164) rather than sharing one. Its contract is a tree in and a
//! reduced tree out, so "build both and diff" is the complete test with no graph involved, and
//! because the output is CA a byte-identical result re-runs this derivation once and stops:
//! nothing downstream moves. That is the same argument as #67.
//!
//! RUST, NOT NUSHELL, and not by preference: this runs inside the nix build, so it is #99. It
//! is built by rustPlatform.buildRustPackage the way nix/launcher.nix and nix/loader.nix are,
//! NOT by buck2, which would be circular: this tool produces the tree buck2 is then run on.
//! std only, no dependencies, so the Cargo.lock stays empty of packages.
//!
//! ONE DEFECT FOUND IN THE PYTHON WHILE PORTING, preserved here rather than silently fixed,
//! because changing it would change behaviour: the --keep guard cannot fire. It computes
//! `fresh |= NEVER_EMPTY_FILES` and then `missing = NEVER_EMPTY_FILES - fresh`, which is
//! empty by construction, so a --keep list that drops a generator input is accepted with the
//! message that says it will not be. Removing the union would make the guard real. Left as a
//! decision rather than taken, since a live --keep list may rely on the union.

use std::collections::BTreeSet;
use std::fs;
use std::io::Write;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

/// Read by buck2 while loading and analysing, so their CONTENTS matter.
///
/// Names first, then the whole of buck/, which holds this port's rules, toolchains and prelude
/// glue. A rule file that arrived empty would not fail loudly, it would analyse to a DIFFERENT
/// graph, so this list errs towards copying.
const BUILD_NAMES: &[&str] = &[
    "BUCK", "BUCK.v2", "PACKAGE", "PACKAGE.v2",
    ".buckconfig", ".buckconfig.local", ".buckroot", ".buckignore",
];
const BUILD_SUFFIXES: &[&str] = &[".bzl", ".bxl"];
const BUILD_TREES: &[&str] = &["buck/"];

/// WHAT MAY BE EMPTIED, and it is a much smaller set than "everything that is not a build
/// file". Emptying the whole tree looked right, since analysis reads no source, but the graph
/// derivation also MATERIALISES the in-process artifacts, and a staged farm of GENERATED
/// headers can only be materialised by running the generator. Measured: with everything
/// emptied, buck2 fails on root//pins/ciderd:dserver_rpc, root//buck-src:mig_parser and
/// root//buck-src:shell_cmds_find_getdate, which are the rpc wrapper script, a mig .defs and a
/// yacc grammar.
///
/// So only the C family is emptied. That is the bulk of the tree and it is what people edit, it
/// is only ever COMPILED, and compiles no longer run here at all since buck/bxl/materialize.bxl
/// stopped ensuring default outputs.
const EMPTIABLE: &[&str] = &[
    ".c", ".cc", ".cpp", ".cxx", ".m", ".mm",
    ".h", ".hpp", ".hh", ".inc",
    ".s", ".S", ".asm",
];

/// NEVER emptied, whatever the suffix. In the graph derivation these do not come from here at
/// all: the pins are materialised from ciderSrc, the crates from the vendor derivation, and
/// pins is where the pins are planted. Emptying them in a hand run makes the run
/// unrepresentative of the build.
const NEVER_EMPTY: &[&str] = &["buck-src/", "buck-rust/", "pins/"];

/// THE FIVE FILES THE PREFIX LIST ABOVE DOES NOT COVER, and the reason the skeleton was
/// reverted rather than fixed the first time. These are C family and outside pins, so they were
/// emptied, and every one is compiled into a GENERATOR that this derivation then RUNS. An
/// emptied rtsig.c does not fail: it compiles, links, runs, and writes an EMPTY header, so the
/// graph comes out quietly wrong and the failure lands somewhere else entirely.
///
/// NOT A GUESS AND NOT A HAND LIST. scripts/buck-codegen-closure.py computes which files must
/// keep real contents and says 1,743 of 74,621. Intersecting that with may_empty leaves exactly
/// these five; the other 1,738 are already covered by NEVER_EMPTY.
const NEVER_EMPTY_FILES: &[&str] = &[
    "linux/libelfloader/wrapgen/wrapgen.cpp",
    "darwin/libsimple/include/libsimple/base.h",
    "darwin/libsimple/include/libsimple/lock.h",
    "darwin/libsimple/src/lock.c",
    "linux/startup/rtsig.c",
];

/// Never walked, at any depth below the root. The Nix filter feeding this already drops them,
/// but this tool is also run by hand against a working tree, where .git alone is bigger than
/// everything it would have to skeletonise.
const ROOT_PRUNE: &[&str] = &[".git", ".jj", ".direnv", "buck-out"];

struct Skeleton {
    keep: BTreeSet<String>,
    copied: u64,
    emptied: u64,
    links: u64,
    dirs: u64,
}

impl Skeleton {
    fn may_empty(&self, rel: &str) -> bool {
        EMPTIABLE.iter().any(|s| rel.ends_with(s))
            && !NEVER_EMPTY.iter().any(|p| rel.starts_with(p))
            && !self.keep.contains(rel)
    }

    fn is_build_file(rel: &str) -> bool {
        let base = Path::new(rel)
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        BUILD_NAMES.contains(&base.as_str())
            || BUILD_SUFFIXES.iter().any(|s| rel.ends_with(s))
            || BUILD_TREES.iter().any(|p| rel.starts_with(p))
            // .buckconfig.d/ and friends: a config fragment is read the same as .buckconfig.
            || rel.contains("/.buckconfig")
            || rel.starts_with(".buckconfig")
    }

    /// One directory, then its children. Mirrors os.walk top-down with followlinks=False: a
    /// symlinked DIRECTORY is recreated as a symlink and NOT descended into, so the skeleton
    /// keeps the same shape rather than expanding a farm into real directories.
    fn walk(&mut self, src: &Path, out: &Path, rel_root: &str) -> std::io::Result<()> {
        let here = if rel_root.is_empty() { src.to_path_buf() } else { src.join(rel_root) };
        let out_here = if rel_root.is_empty() { out.to_path_buf() } else { out.join(rel_root) };
        fs::create_dir_all(&out_here)?;
        self.dirs += 1;

        let mut subdirs: Vec<String> = Vec::new();
        for entry in fs::read_dir(&here)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            let p = entry.path();
            let rel = if rel_root.is_empty() { name.clone() } else { format!("{rel_root}/{name}") };

            // symlink_metadata does NOT follow, which is the whole point: this tree is full of
            // dangling links and os.stat on one is a FileNotFoundError, which is how the first
            // python run died on AppKit.framework/Headers.
            let md = fs::symlink_metadata(&p)?;

            if md.file_type().is_symlink() {
                // By its TARGET STRING, which is exactly how Nix hashes a symlink, so a
                // dangling one is preserved rather than resolved or dropped. No mode is set: a
                // symlink has none of its own that survives being recreated.
                let target = fs::read_link(&p)?;
                symlink(&target, out.join(&rel))?;
                self.links += 1;
                continue;
            }

            if md.is_dir() {
                if rel_root.is_empty() && ROOT_PRUNE.contains(&name.as_str()) {
                    continue;
                }
                subdirs.push(rel);
                continue;
            }

            let dst = out.join(&rel);
            if self.may_empty(&rel) && !Self::is_build_file(&rel) {
                // The NAME is the whole content that analysis needs, and nothing here reads a C
                // family file: compiles do not run in this derivation.
                fs::File::create(&dst)?;
                self.emptied += 1;
            } else {
                fs::copy(&p, &dst)?;
                self.copied += 1;
            }
            // THE MODE, which writing bytes does not carry. buck2 EXECUTES things out of this
            // tree, mig.sh and generate-rpc-wrappers.py and configure scripts, and an executable
            // that arrives without its +x bit fails at exec time a long way from here with
            // nothing pointing back at the skeleton. Applied to emptied files too, so the tree
            // differs from the original in CONTENT only.
            fs::set_permissions(&dst, fs::Permissions::from_mode(md.permissions().mode() & 0o7777))?;
        }

        for rel in subdirs {
            self.walk(src, out, &rel)?;
        }
        Ok(())
    }
}

fn usage() -> ExitCode {
    eprintln!("  cider-skeleton <src> <out> [--keep <file of paths to never empty>]");
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let mut args: Vec<String> = std::env::args().skip(1).collect();

    let mut keep_path = String::new();
    if let Some(i) = args.iter().position(|a| a == "--keep") {
        if i + 1 >= args.len() {
            eprintln!("--keep needs a file of project-relative paths");
            return ExitCode::from(2);
        }
        keep_path = args[i + 1].clone();
        args.drain(i..i + 2);
    }
    if args.len() != 2 {
        return usage();
    }
    let src = match fs::canonicalize(&args[0]) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("skeleton: cannot resolve {}: {e}", args[0]);
            return ExitCode::from(2);
        }
    };
    let out = PathBuf::from(&args[1]);
    let out = if out.is_absolute() {
        out
    } else {
        std::env::current_dir().unwrap_or_default().join(out)
    };

    let mut keep: BTreeSet<String> = NEVER_EMPTY_FILES.iter().map(|s| s.to_string()).collect();
    if !keep_path.is_empty() {
        let text = match fs::read_to_string(&keep_path) {
            Ok(t) => t,
            Err(e) => {
                eprintln!("skeleton: cannot read {keep_path}: {e}");
                return ExitCode::from(2);
            }
        };
        let mut fresh: BTreeSet<String> = text
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .collect();
        // The generated list is the DELTA against NEVER_EMPTY, so union rather than replace:
        // the five are inside the first-party trees and would otherwise have to be restated.
        //
        // The guard below is the python's, and it CANNOT FIRE because of this union. Kept
        // identical rather than repaired, so this port changes no behaviour; see the header.
        for f in NEVER_EMPTY_FILES {
            fresh.insert(f.to_string());
        }
        let missing: Vec<&&str> = NEVER_EMPTY_FILES
            .iter()
            .filter(|f| !fresh.contains(**f))
            .collect();
        if !missing.is_empty() {
            eprintln!("skeleton: the --keep list drops files known to feed a generator:");
            for m in &missing {
                eprintln!("    {m}");
            }
            eprintln!("  An emptied generator input does not fail, it produces an empty output.");
            return ExitCode::from(2);
        }
        keep = fresh;
        eprintln!("skeleton: keeping {} file(s) from {keep_path}", keep.len());
    }

    let mut sk = Skeleton { keep, copied: 0, emptied: 0, links: 0, dirs: 0 };
    if let Err(e) = sk.walk(&src, &out, "") {
        eprintln!("skeleton: {e}");
        return ExitCode::FAILURE;
    }

    let _ = std::io::stderr().flush();
    eprintln!(
        "skeleton: {} file(s) copied whole, {} emptied, {} symlinks, {} directories",
        sk.copied, sk.emptied, sk.links, sk.dirs
    );
    if sk.copied == 0 || sk.emptied == 0 {
        eprintln!("skeleton: nothing was copied or nothing was emptied, the filter is wrong");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}
