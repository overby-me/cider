//! EMIT mig_gen TARGETS FROM THE REFERENCE build.ninja BUILD-MIG EDGES.
//!
//! THE RUST REWRITE of the python gen-mig-from-ninja (#98). MIG configurations vary more than
//! they look: libsyscall runs mig over the SAME definition list three times with different suffix
//! sets, so rather than re-deriving that from the CMakeLists this reads the edges. Each one names
//! its defs and its five outputs, so the suffixes follow by subtracting the stem, and multiarch
//! needs no rule support at all because the arch infix rides in the suffix.
//!
//! A FROZEN GENERATOR. cmake is gone, so nothing can regenerate the reference build.ninja this
//! reads. It runs against the stale result-graph-ref symlink until a store GC collects it.
//!
//! AND IT DOES NOT RUN TO COMPLETION ON THIS TREE, which the python recorded and this reproduces
//! rather than repairs: sdk_env_flags looks for the literal `exported_flags = [` in darwin/BUCK,
//! and that target now says `exported_flags = _ENV_FLAGS`, a variable. The python dies there with
//! a ValueError after printing its five header lines. Guessing at which spelling replaced the
//! literal would be inventing a result nothing verifies, so this stops in the same place, after
//! the same five lines, with a message instead of a traceback.
//!
//! Usage:
//!   cider-mig-from-ninja <output-dir-substring> [--prefix NAME] [--deps DEP,...]

#[path = "pyshlex.rs"]
mod pyshlex;
use pyshlex::shlex_split;

use std::collections::BTreeSet;
use std::fs;
use std::process::ExitCode;

const BIN_DIR: &str = "/build/build";

/// Generated mig sources the reference libraries CONTAIN but whose compile edge does not appear
/// in the graph. Without them, anything binding the symbol fails to load a long way from here.
const EXTRA_COMPILE_SRCS: &[(&str, &[&str])] = &[
    ("emmig_signal_exc", &["signal/excServer.c"]),
    ("mig_MachExceptions", &["MachExceptionsServer.c", "MachExceptionsUser.c"]),
    ("iokitd_mig_iokitmig", &["iokitmigServer.c"]),
    ("iokitd_mig_powermanagement", &["powermanagementServer.c"]),
];

const USAGE: &str = "\
cider-mig-from-ninja: emit mig_gen targets from the reference build.ninja build-mig edges.

  cider-mig-from-ninja <output-dir-substring> [--prefix NAME] [--deps DEP,...]
";

/// BOTH NAMES. The reference build.ninja is a FROZEN cmake-era artifact, so the #84 rename could
/// not reach it: it says darling-cmake-src and never cider-cmake-src. With the cider spelling
/// alone this matched nothing and all 124 mig edges came back with a store prefix.
/// /nix/store/[a-z0-9]{32}-(?:cider|darling)-cmake-src
fn strip_src_store(s: &str) -> String {
    let mut out = String::new();
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if s[i..].starts_with("/nix/store/") {
            let h = i + "/nix/store/".len();
            if h + 32 <= b.len() && b[h..h + 32].iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()) {
                let rest = &s[h + 32..];
                for tail in ["-cider-cmake-src", "-darling-cmake-src"] {
                    if rest.starts_with(tail) {
                        i = h + 32 + tail.len();
                        break;
                    }
                }
                if i == h + 32 + "-cider-cmake-src".len()
                    || i == h + 32 + "-darling-cmake-src".len()
                {
                    continue;
                }
            }
        }
        let c = s[i..].chars().next().unwrap();
        out.push(c);
        i += c.len_utf8();
    }
    out
}

/// os.path.splitext(p)[0]: the last dot that is not the first character of the basename.
fn splitext_stem(p: &str) -> String {
    let base_at = p.rfind('/').map(|i| i + 1).unwrap_or(0);
    match p[base_at..].rfind('.') {
        Some(d) if d > 0 => p[..base_at + d].to_string(),
        _ => p.to_string(),
    }
}

fn basename(p: &str) -> &str {
    match p.rfind('/') {
        Some(i) => &p[i + 1..],
        None => p,
    }
}

fn dirname(p: &str) -> &str {
    match p.rfind('/') {
        Some(i) => &p[..i],
        None => "",
    }
}

/// re.sub(r"[^A-Za-z0-9]+", "_", s).strip("_")
fn ident(s: &str) -> String {
    let mut out = String::new();
    let mut run = false;
    for c in s.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c);
            run = false;
        } else if !run {
            out.push('_');
            run = true;
        }
    }
    out.trim_matches('_').to_string()
}

/// python str.rstrip(".h") strips any trailing '.' or 'h' CHARACTERS, not the suffix.
fn rstrip_dot_h(s: &str) -> &str {
    s.trim_end_matches(|c| c == '.' || c == 'h')
}

fn json_string(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| format!("\"{s}\""))
}

/// The flags //darwin:sdk_env already exports, read from darwin/BUCK rather than listed, because
/// the point is to emit the DIFFERENCE.
fn sdk_env_flags(repo: &str) -> Result<BTreeSet<String>, String> {
    let path = format!("{repo}/darwin/BUCK");
    let text = fs::read_to_string(&path).map_err(|e| format!("cannot read {path}: {e}"))?;
    let i = match text.find("name = \"sdk_env\"") {
        Some(i) => i,
        None => return Err("no sdk_env target in darwin/BUCK".to_string()),
    };
    let j = match text[i..].find("exported_flags = [") {
        Some(j) => i + j,
        None => {
            return Err(format!(
                "darwin/BUCK has no literal `exported_flags = [` after the sdk_env target: it \
                 says `exported_flags = _ENV_FLAGS`.\nThe python died here too, with a \
                 ValueError, and this is left unrepaired on purpose: guessing which spelling \
                 replaced the literal would invent a result nothing verifies."
            ))
        }
    };
    let end = text[j..].find(']').map(|k| j + k).unwrap_or(text.len());
    let mut out = BTreeSet::new();
    let seg = &text[j..end];
    let mut k = 0;
    while let Some(at) = seg[k..].find('"') {
        let start = k + at + 1;
        match seg[start..].find('"') {
            Some(e) => {
                if e > 0 {
                    out.insert(seg[start..start + e].to_string());
                }
                k = start + e + 1;
            }
            None => break,
        }
    }
    Ok(out)
}

/// (defs_repo_path, [output paths], command) for every build-mig edge.
fn mig_edges(graph: &str, m: &str) -> Result<Vec<(String, Vec<String>, String)>, String> {
    let text = fs::read_to_string(graph).map_err(|e| format!("cannot read {graph}: {e}"))?;
    let mut out = Vec::new();
    let mut cur_head: Option<Vec<String>> = None;
    for line in text.split('\n') {
        if let Some(rest) = line.strip_prefix("build ") {
            let head = rest.split(": ").next().unwrap_or("");
            let head = head.split(" | ").next().unwrap_or("");
            cur_head = Some(head.split_whitespace().map(|s| s.to_string()).collect());
        } else if cur_head.is_some() {
            let t = line.trim_start();
            if !t.starts_with("COMMAND = ") || !line.contains("build-mig") {
                continue;
            }
            let cmd = line.trim().strip_prefix("COMMAND = ").unwrap_or("").to_string();
            let head = cur_head.clone().unwrap();
            if !head.iter().any(|o| o.contains(m)) {
                continue;
            }
            // (\S+\.defs)\s*(?:;|$) : the defs argument, at the end or before a semicolon.
            let mut defs: Option<String> = None;
            for (i, _) in cmd.match_indices(".defs") {
                let end = i + ".defs".len();
                let start = cmd[..i].rfind(|c: char| c.is_whitespace()).map(|k| k + 1).unwrap_or(0);
                let mut k = end;
                let b = cmd.as_bytes();
                while k < b.len() && (b[k] as char).is_whitespace() {
                    k += 1;
                }
                if k == b.len() || b[k] == b';' {
                    defs = Some(cmd[start..end].to_string());
                    break;
                }
            }
            let defs = match defs {
                Some(d) => d,
                None => continue,
            };
            let defs = strip_src_store(&defs).trim_start_matches('/').to_string();
            out.push((defs, head, cmd));
            cur_head = None;
        } else if line.trim().is_empty() {
            cur_head = None;
        }
    }
    Ok(out)
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
    let graph = format!("{repo}/result-graph-ref/build.ninja");
    if !std::path::Path::new(&graph).exists() {
        eprintln!("no reference graph at {graph}");
        return ExitCode::FAILURE;
    }
    let args: Vec<&String> = argv.iter().filter(|a| !a.starts_with("--")).collect();
    if args.is_empty() {
        eprintln!("{USAGE}");
        return ExitCode::FAILURE;
    }
    let m = args[0].clone();
    let mut prefix = "mig".to_string();
    if let Some(i) = argv.iter().position(|a| a == "--prefix") {
        match argv.get(i + 1) {
            Some(v) => prefix = v.clone(),
            None => {
                eprintln!("--prefix wants a value");
                return ExitCode::FAILURE;
            }
        }
    }
    let mut deps: Vec<String> = vec!["//darwin:sdk_env".to_string()];
    if let Some(i) = argv.iter().position(|a| a == "--deps") {
        match argv.get(i + 1) {
            Some(v) => {
                let mut d: Vec<String> = v.split(',').map(|s| s.to_string()).collect();
                d.push("//darwin:sdk_env".to_string());
                deps = d;
            }
            None => {
                eprintln!("--deps wants a value");
                return ExitCode::FAILURE;
            }
        }
    }

    println!("# GENERATED by cider-mig-from-ninja -- review before committing.");
    println!("#");
    println!("# One mig_gen per (definition, pass): the same definitions are run through");
    println!("# mig several times with different suffix sets. Multiarch rides in the");
    println!("# suffix (-x86_64-User.c), so the rule needs no arch concept of its own.");
    println!();

    // THE STOP, in the same place the python stops.
    let shared = match sdk_env_flags(&repo) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };

    let edges = match mig_edges(&graph, &m) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };

    let mut seen: BTreeSet<String> = BTreeSet::new();
    let mut count = 0usize;
    for (defs, outs, cmd) in edges {
        // mig runs the C PREPROCESSOR over the .defs, so a -D the reference passes decides which
        // routines exist. shlex, not a whitespace split: the emulation directory passes
        // -DEMULATED_VERSION="Darwin Kernel Version 23.4.0".
        let words = shlex_split(&cmd).unwrap_or_else(|_| {
            cmd.split_whitespace().map(|s| s.to_string()).collect()
        });
        let migdefs: Vec<String> = {
            let s: BTreeSet<String> = words
                .iter()
                .filter(|f| f.starts_with("-D") && !shared.contains(*f))
                .cloned()
                .collect();
            s.into_iter().collect()
        };
        for d in &migdefs {
            if d.contains(' ') || d.contains('\t') || d.contains('"') {
                eprintln!(
                    "WARNING: {defs}: check {} against the reference quoting before committing",
                    py_repr(d)
                );
            }
        }
        let mut rel_outs: Vec<String> = Vec::new();
        for o in &outs {
            let o = o.replace(BIN_DIR, "");
            let o = o.trim_start_matches('/').to_string();
            if o.contains(&m) {
                let after = o.splitn(2, &m).nth(1).unwrap_or("").trim_start_matches('/').to_string();
                rel_outs.push(after);
            }
        }
        if rel_outs.is_empty() {
            continue;
        }
        let stem = if defs.contains(&m) {
            splitext_stem(defs.splitn(2, &m).nth(1).unwrap_or("").trim_start_matches('/'))
        } else {
            splitext_stem(basename(&defs))
        };
        // Suffix per output = whatever follows the stem.
        let mut sfx_header = String::new();
        let mut sfx_user = String::new();
        let mut sfx_server = String::new();
        let mut sfx_sheader = String::new();
        let mut sfx_xtrace = String::new();
        let mut nkeys = 0;
        {
            let mut set = |slot: &mut String, v: &str, n: &mut usize| {
                if slot.is_empty() {
                    *n += 1;
                }
                *slot = v.to_string();
            };
            for o in &rel_outs {
                if !o.starts_with(&stem) {
                    continue;
                }
                let suffix = &o[stem.len()..];
                if suffix.ends_with("Server.h") || suffix.ends_with("_server.h") {
                    set(&mut sfx_sheader, suffix, &mut nkeys);
                } else if suffix.ends_with("Server.c") || suffix.ends_with("_server.c") {
                    set(&mut sfx_server, suffix, &mut nkeys);
                } else if suffix.ends_with("User.c") || suffix.ends_with("_user.c") {
                    set(&mut sfx_user, suffix, &mut nkeys);
                } else if suffix.to_lowercase().contains("xtrace") {
                    set(&mut sfx_xtrace, suffix, &mut nkeys);
                } else if suffix.ends_with(".h") {
                    set(&mut sfx_header, suffix, &mut nkeys);
                }
            }
        }
        if nkeys < 3 {
            continue;
        }
        let name = format!("{prefix}_{}", ident(&stem));
        // Distinguish the passes by what the header suffix is.
        let mut tag = String::new();
        if !sfx_header.is_empty() && sfx_header != ".h" {
            tag = format!("_{}", ident(rstrip_dot_h(&sfx_header)));
        }
        let arch = ["i386", "x86_64"]
            .iter()
            .find(|a| sfx_user.contains(&format!("-{a}-")))
            .map(|a| a.to_string());
        if let Some(a) = &arch {
            tag = format!("_{a}");
        }
        let full = format!("{name}{tag}");
        if seen.contains(&full) {
            continue;
        }
        seen.insert(full.clone());
        count += 1;
        println!("mig_gen(");
        println!("    name = \"{full}\",");
        println!("    defs = \"{}\",", defs.strip_prefix("pins/").unwrap_or(&defs));
        // out_base is the directory the OUTPUTS are relative to, not the defs own directory.
        let base_src = defs.strip_prefix("pins/").unwrap_or(&defs).to_string();
        let base = match base_src.find(&m) {
            Some(i) => base_src[..i + m.len()].to_string(),
            None => dirname(&base_src).to_string(),
        };
        println!("    out_base = \"{base}\",");
        for (v, attr) in [
            (&sfx_user, "user_suffix"),
            (&sfx_header, "header_suffix"),
            (&sfx_server, "server_suffix"),
            (&sfx_sheader, "sheader_suffix"),
            (&sfx_xtrace, "xtrace_suffix"),
        ] {
            if !v.is_empty() {
                println!("    {attr} = \"{v}\",");
            }
        }
        let mut compile_srcs: Vec<String> = Vec::new();
        if let Some(a) = &arch {
            println!("    arch = \"{a}\",");
            compile_srcs.push(format!("{stem}{sfx_user}"));
        }
        // Collected into ONE list: Starlark takes the last of a repeated keyword argument, so a
        // block per entry silently exports only the last one.
        for (k, v) in EXTRA_COMPILE_SRCS {
            if *k == full {
                compile_srcs.extend(v.iter().map(|s| s.to_string()));
            }
        }
        if !compile_srcs.is_empty() {
            println!("    compile_srcs = [");
            for src in &compile_srcs {
                println!("        \"{src}\",");
            }
            println!("    ],");
        }
        if !migdefs.is_empty() {
            println!("    mig_flags = [");
            for d in &migdefs {
                println!("        {},", json_string(d));
            }
            println!("    ],");
        }
        println!("    mig_sh = \"//buck-src:mig.sh\",");
        println!("    migcom = \"//buck-src:migcom\",");
        println!("    deps = [");
        for d in &deps {
            println!("        \"{d}\",");
        }
        println!("    ],");
        println!("    visibility = [\"PUBLIC\"],");
        println!(")");
        println!();
    }
    eprintln!("# {count} mig targets");
    ExitCode::SUCCESS
}

/// python repr of a string, for the one warning that prints a flag.
fn py_repr(s: &str) -> String {
    let q = if s.contains('\'') && !s.contains('"') { '"' } else { '\'' };
    let mut out = String::new();
    out.push(q);
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            c if c == q => {
                out.push('\\');
                out.push(c);
            }
            c => out.push(c),
        }
    }
    out.push(q);
    out
}
