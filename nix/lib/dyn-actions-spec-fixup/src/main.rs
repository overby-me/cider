//! Fix up one emitted derivation spec, at PRODUCER BUILD TIME, just before `nix derivation add`.
//! The Rust rewrite of nix/lib/dyn-actions-spec-fixup.py, task #99.
//!
//! Two things can only be done here rather than in the evaluator, and both were learned the hard
//! way. See nix/lib/dyn-actions-dep-probe.nix for the measurements.
//!
//! 1. inputs.srcs MUST BE STORE-DIR-RELATIVE. The version 4 format wants `<hash>-<name>`, and
//!    given a full path `nix derivation add` fails with
//!        store path '/nix/store/xxx-foo' contains illegal base-32 character '/'
//!    The bridge cannot pre-strip them, because an entry may be another action's output, which
//!    at eval time is a builtins.outputOf PLACEHOLDER. The outer Nix substitutes the real path
//!    only when this producer runs, and it matches the placeholder TEXT exactly, so taking a
//!    basename or discarding the context mangles it and the emitted drv names a path that "is
//!    not valid".
//!
//! 2. DEPENDENCIES ON OTHER ACTIONS, for the same reason and one more. In specDir mode the spec
//!    is a FILE the bridge copies without parsing, so nothing in the evaluator can inject a
//!    dependency into it. The bridge instead hands this tool the dependency paths through the
//!    environment, where Nix has already substituted them, and it writes them into the spec: as
//!    a source, so the sandbox has the file, AND as an env entry, so the action can find it
//!    without anyone interpolating a path into its args.
//!
//! BOTH MODES GO THROUGH HERE, deliberately. Doing deps in specOf for `actions` mode and here
//! for `specDir` mode would be two implementations of one rule, and they would drift.
//!
//! WHY THIS ONE DOES NOT NEED A PYTHON COMPATIBLE JSON WRITER, unlike the graph tools. Its
//! output is read by `nix derivation add`, a PARSER, and the artifact that has to stay identical
//! is the emitted derivation, which Nix canonicalises. graph.json is different: it is read at
//! evaluation and its bytes are the identity of every derivation lowered from it. So this writes
//! serde_json's compact form and the proof is the producer's own content addressed output.
//!
//! Usage: cider-spec-fixup <spec.json>
//!   DYN_DEP_NAMES  space separated action names this action depends on
//!   <depVar>       one per name, holding the dependency's already-substituted output path

use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;

use serde_json::{Map, Value};

const USAGE: &str = "Usage: cider-spec-fixup <spec.json>\n  \
DYN_DEP_NAMES  space separated action names this action depends on\n  \
<depVar>       one per name, holding the dependency's already-substituted output path";

// MAX_ARG_STRLEN. Kept a little under 32 pages because the kernel counts the terminating NUL and
// the pointer, and being exactly at the edge is not worth the argument.
const MAX_ARG: usize = 120 * 1024;

/// MUST MATCH depVar IN dyn-actions.nix. A shell variable name is [A-Za-z_][A-Za-z0-9_]*, and
/// action names are free-form, so EVERY OTHER CHARACTER becomes an underscore -- one per
/// character, not one per run, which is what python's re.sub of a single-character class does.
/// Getting this wrong does not fail: the variable is simply unset and expands to EMPTY, which is
/// how the first version of this shipped a clean build that produced nothing.
fn dep_var(name: &str) -> String {
    let mut out = String::from("DYN_DEP_");
    for c in name.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c);
        } else {
            out.push('_');
        }
    }
    out
}

/// Every store path a string names: the store directory, a 32 character base-32 hash, a dash,
/// then the name. Anchored on the hash length so a path-shaped string in ordinary text cannot
/// match. Trailing path components are deliberately NOT captured: srcs names a store OBJECT, and
/// /nix/store/xxx-foo/bar is the object xxx-foo.
///
/// re.finditer(r"/nix/store/[a-z0-9]{32}-[A-Za-z0-9+._?=-]+")
fn store_paths(s: &str) -> Vec<String> {
    const NEEDLE: &str = "/nix/store/";
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while let Some(rel) = s[i..].find(NEEDLE) {
        let start = i + rel;
        let hash = start + NEEDLE.len();
        if hash + 33 > b.len()
            || !b[hash..hash + 32].iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
            || b[hash + 32] != b'-'
        {
            i = start + 1;
            continue;
        }
        let mut j = hash + 33;
        while j < b.len() && is_name_char(b[j]) {
            j += 1;
        }
        if j == hash + 33 {
            i = start + 1;
            continue;
        }
        out.push(s[start..j].to_string());
        i = j;
    }
    out
}

fn is_name_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, b'+' | b'.' | b'_' | b'?' | b'=' | b'-')
}

/// Put an over-long argument in the store and return its path, or None on failure.
fn spill(text: &str, name: &str) -> Option<String> {
    let dir = env::temp_dir().join(format!("cider-spec-fixup-{}", std::process::id()));
    if fs::create_dir_all(&dir).is_err() {
        return None;
    }
    let f = dir.join(format!("{name}.sh"));
    if fs::write(&f, text).is_err() {
        return None;
    }
    // add-path rather than add-file: it is the spelling available on the nix this runs against,
    // and a regular file goes in as a regular file either way.
    let r = Command::new("nix")
        .args(["--extra-experimental-features", "nix-command", "store", "add-path"])
        .arg(&f)
        .output()
        .ok()?;
    if !r.status.success() {
        eprintln!(
            "dyn-actions: could not spill a {} byte argument of {name:?} to the store: {}",
            text.len(),
            String::from_utf8_lossy(&r.stderr).trim()
        );
        return None;
    }
    let _ = fs::remove_dir_all(&dir);
    Some(String::from_utf8_lossy(&r.stdout).trim().to_string())
}

fn obj_mut<'a>(v: &'a mut Value, key: &str) -> &'a mut Map<String, Value> {
    let m = v.as_object_mut().expect("spec is not a JSON object");
    m.entry(key).or_insert_with(|| Value::Object(Map::new()));
    m.get_mut(key)
        .and_then(|x| x.as_object_mut())
        .unwrap_or_else(|| fail(&format!("spec field {key:?} is not an object")))
}

fn fail(msg: &str) -> ! {
    eprintln!("{msg}");
    std::process::exit(1);
}

fn main() {
    let argv: Vec<String> = env::args().skip(1).collect();
    if argv.len() != 1 {
        fail(USAGE);
    }
    let path = &argv[0];
    let text = fs::read_to_string(path).unwrap_or_else(|e| fail(&format!("cannot read {path}: {e}")));
    let mut spec: Value =
        serde_json::from_str(&text).unwrap_or_else(|e| fail(&format!("{path} is not JSON: {e}")));

    {
        let inputs = obj_mut(&mut spec, "inputs");
        inputs.entry("srcs").or_insert_with(|| Value::Array(Vec::new()));
        inputs.entry("drvs").or_insert_with(|| Value::Object(Map::new()));
    }
    obj_mut(&mut spec, "env");

    // WHAT ONLY THE BRIDGE KNOWS, filled in here so a spec dir can be written by a GENERATOR that
    // has never heard of Nix placeholders. Before this, specDir mode required a fully formed
    // version 4 derivation, which in practice meant it could only read what mkSpecDir wrote: the
    // bridge reading its own files back, which is not what the mode is for.
    //
    // ANYTHING ALREADY PRESENT IS LEFT ALONE. mkSpecDir writes complete specs and they must keep
    // working byte for byte.
    //
    // THE PLACEHOLDER IS NOT DERIVABLE OUTSIDE NIX. builtins.placeholder is a hash of a fixed
    // string with the output NAME in it, and reimplementing that in a generator would be a
    // second copy of an internal encoding. It arrives in the environment instead.
    let out_name = env::var("DYN_OUTPUT_NAME").unwrap_or_default();
    let placeholder = env::var("DYN_OUTPUT_PLACEHOLDER").unwrap_or_default();
    let system = env::var("DYN_SYSTEM").unwrap_or_default();
    if !out_name.is_empty() && !placeholder.is_empty() && !system.is_empty() {
        let name = spec.get("name").cloned().unwrap_or_else(|| Value::String(String::new()));
        let builder = spec.get("builder").cloned().unwrap_or_else(|| Value::String(String::new()));
        {
            let m = spec.as_object_mut().unwrap();
            m.entry("system").or_insert_with(|| Value::String(system.clone()));
            m.entry("version").or_insert_with(|| Value::from(4));
            m.entry("outputs").or_insert_with(|| Value::Object(Map::new()));
        }
        {
            let outputs = obj_mut(&mut spec, "outputs");
            outputs.entry(out_name.clone()).or_insert_with(|| {
                let mut o = Map::new();
                o.insert("hashAlgo".into(), Value::String("sha256".into()));
                o.insert("method".into(), Value::String("nar".into()));
                Value::Object(o)
            });
        }
        let env_map = obj_mut(&mut spec, "env");
        env_map.entry("name").or_insert(name);
        env_map.entry("builder").or_insert(builder);
        env_map.entry(out_name).or_insert_with(|| Value::String(placeholder));
        env_map.entry("outputHashAlgo").or_insert_with(|| Value::String("sha256".into()));
        env_map.entry("outputHashMode").or_insert_with(|| Value::String("recursive".into()));
        env_map.entry("system").or_insert_with(|| Value::String(system));
    }

    let mut new_srcs: Vec<String> = Vec::new();

    for name in env::var("DYN_DEP_NAMES").unwrap_or_default().split_whitespace() {
        let var = dep_var(name);
        let value = env::var(&var).unwrap_or_default();
        if value.is_empty() {
            // LOUD, because the silent version of this is an action that runs happily against an
            // empty path and produces a plausible, wrong, empty result.
            fail(&format!(
                "dyn-actions: dependency {name:?} has no {var} in the environment"
            ));
        }
        new_srcs.push(value.clone());
        obj_mut(&mut spec, "env").insert(var, Value::String(value));
    }

    // CONSUMER SUPPLIED PATHS, the same route as a dependency and for the same reason: a spec
    // read from a file cannot have a store path interpolated into it, because the generator that
    // wrote it ran before any consumer path existed. Each becomes an env entry so the script can
    // name it, and a source so the sandbox actually has it.
    //
    // SEPARATE FROM DYN_DEP_NAMES because a dependency is also an EDGE and this is not: the value
    // is already a realised path rather than another action's output.
    for name in env::var("DYN_EXTRA_NAMES").unwrap_or_default().split_whitespace() {
        let value = env::var(name).unwrap_or_default();
        if value.is_empty() {
            fail(&format!("dyn-actions: extraEnv {name:?} is not in the environment"));
        }
        obj_mut(&mut spec, "env").insert(name.to_string(), Value::String(value.clone()));
        // EVERY STORE PATH THE VALUE NAMES, not the value itself, and the difference is not
        // theoretical: a PATH is a colon-joined list of <store path>/bin entries, and appending
        // the whole string made `nix derivation add` fail with "bin is too short to be a valid
        // store path" once the basename step below took its last component.
        //
        // A caller may legitimately pass a plain string with no path in it. That is carried in
        // the env and simply declares nothing.
        new_srcs.extend(store_paths(&value));
    }

    // INFERRED SOURCES: every store path the command itself names.
    //
    // WHY THIS CAN ONLY HAPPEN HERE, and why it is worth having. A caller assembling an action
    // from an existing build script has the paths in the SCRIPT rather than in a list: the string
    // carries Nix string context, the outer Nix substitutes real paths into it when this producer
    // runs, and there is no point before that at which the caller could enumerate them. Reading
    // them back out of the finished args is the only place the information is both present and
    // concrete.
    //
    // OVER-DECLARING IS SAFE AND UNDER-DECLARING IS NOT, which is what makes this a reasonable
    // default to offer: a path named in a comment merely puts something extra in the sandbox,
    // whereas a missing one is a command running against a file that is not there. It is still
    // opt-in, because a caller that knows its inputs exactly should say so and get an error when
    // it is wrong.
    if !env::var("DYN_INFER_SRCS").unwrap_or_default().is_empty() {
        let args = spec.get("args").cloned().unwrap_or_else(|| Value::Array(Vec::new()));
        let builder = spec.get("builder").cloned().unwrap_or_else(|| Value::String(String::new()));
        // The RENDERING of both, as the python scanned, because that is what puts every argument
        // into one string. Which JSON writer renders it does not matter: a store path contains
        // no character either writer escapes.
        let text = format!("{}{}", args, builder);
        new_srcs.extend(store_paths(&text));
    }

    // AN ARGUMENT CAN BE TOO LONG TO PASS AT ALL, and this is not a tuning knob: Linux caps a
    // SINGLE argv or env string at MAX_ARG_STRLEN, 32 pages, 131,072 bytes. It is not ARG_MAX,
    // which is the 2 MB total and would not have been reached. execve fails with E2BIG and the
    // builder reports "executing /bin/sh: Argument list too long".
    //
    // FOUND BY A REAL CONSUMER, and it could not have been found by a toy: the largest fixture
    // script here is a few kilobytes, while 89 of one consumer's 1,474 actions are over the limit
    // and the largest is 5.1 MB. Three exceed even the 2 MB total.
    //
    // ONLY A SHELL COMMAND STRING IS REWRITTEN, and that is the whole reason this is safe: an
    // argument after -c IS a shell script, and sourcing a file containing it is exactly
    // equivalent. For any other over-long argument there is no rewrite that preserves meaning, so
    // that is a named error rather than a guess.
    let spec_name = spec.get("name").and_then(|v| v.as_str()).unwrap_or("action").to_string();
    let args_len = spec.get("args").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0);
    for i in 0..args_len {
        let arg = match spec["args"][i].as_str() {
            Some(s) if s.len() > MAX_ARG => s.to_string(),
            _ => continue,
        };
        let prev_is_c = i > 0 && spec["args"][i - 1].as_str() == Some("-c");
        if !prev_is_c {
            fail(&format!(
                "dyn-actions: argument {i} of {spec_name:?} is {} bytes, over the {MAX_ARG} byte \
                 limit on a single argument, and is not a -c command string, so there is no \
                 equivalent rewrite",
                arg.len()
            ));
        }
        let spilled = match spill(&arg, &spec_name) {
            Some(p) => p,
            None => std::process::exit(1),
        };
        spec["args"][i] = Value::String(format!(". {spilled}"));
        new_srcs.push(spilled);
    }

    // LAST, so it also catches the dependency and inferred paths just added. Everything in srcs
    // is a store path by now: the outer Nix has substituted every placeholder.
    let mut all: Vec<String> = spec["inputs"]["srcs"]
        .as_array()
        .map(|a| a.iter().map(|s| s.as_str().unwrap_or_default().to_string()).collect())
        .unwrap_or_default();
    all.extend(new_srcs);
    let mut seen: Vec<String> = Vec::new();
    let mut srcs: Vec<Value> = Vec::new();
    for s in all {
        let base = match s.rsplit_once('/') {
            Some((_, b)) => b.to_string(),
            None => s.clone(),
        };
        if !seen.contains(&base) {
            seen.push(base.clone());
            srcs.push(Value::String(base));
        }
    }
    spec["inputs"]["srcs"] = Value::Array(srcs);

    let out = serde_json::to_string(&spec).unwrap_or_else(|e| fail(&format!("cannot serialise: {e}")));
    if fs::write(Path::new(path), out).is_err() {
        fail(&format!("cannot write {path}"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_python() {
        // python3 -c "import re; print(re.sub(r'[^A-Za-z0-9]', '_', 'root//a:b (c)'))"
        assert_eq!(dep_var("root//a:b (c)"), "DYN_DEP_root__a_b__c_");
        // ONE UNDERSCORE PER CHARACTER, not per run: the class has no +.
        assert_eq!(dep_var("a//b"), "DYN_DEP_a__b");

        let p = "/nix/store/00000000000000000000000000000000-foo-1.0/bin:/x";
        assert_eq!(store_paths(p), vec!["/nix/store/00000000000000000000000000000000-foo-1.0"]);
        // too short a hash matches nothing
        assert_eq!(store_paths("/nix/store/abc-foo"), Vec::<String>::new());
        // two in one string, and the second name stops at the slash
        let two = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a:/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-b/bin";
        assert_eq!(
            store_paths(two),
            vec![
                "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a",
                "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-b"
            ]
        );
    }
}
