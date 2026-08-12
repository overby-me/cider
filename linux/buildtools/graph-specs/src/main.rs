//! The lowering and the spec generator, in Rust: what a group NEEDS, the script that builds it,
//! and the per-group spec files the bridge reads. Task #99.
//!
//! This is linux/buildtools/graph-specs and linux/buildtools/graph-specs in one binary. They were
//! two files because python needed an importable module shared between the generator and three
//! checks; a binary has no import, so the checks read the JSON it already writes instead, which
//! is the same data by a shorter route.
//!
//! BUILT BY NIX, NOT BY BUCK2, because it runs inside the graph derivation, which is the tree
//! buck2 was just run on. See linux/buildtools/skeleton for the same constraint.
//!
//! THE OUTPUT IS THE IDENTITY. specsDrv is content addressed, so every byte here is load
//! bearing: object key ORDER, the ", " and ": " separators python's json.dump emits, the exact
//! shell escaping nixpkgs lib.escapeShellArg does, and the two stray newlines in the builder
//! template that cost two bytes across 5,662 when they were missing. See src/pyjson.rs for the
//! serialiser and the harness comment below for why the shell block is a file rather than a
//! literal.
//!
//! VERIFIED against linux/buildtools/graph-specs over the REAL 147 MB graph, 1,474 groups and
//! 2,955 output files, byte for byte.

mod pyjson;

use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;
use std::process::ExitCode;

const BRIDGE_OUTPUT_NAME: &str = "result";

/// LIFTED VERBATIM, NOT RETYPED, and the python it comes from says why: it is about sixty lines
/// of shell and comment, and a typo in any of them is a byte the comparison would report without
/// saying which side is right. Extracted from buck_lowering._HARNESS into a file so that even
/// this port cannot introduce one. Exactly one %, which is the label slot.
const HARNESS: &str = include_str!("harness.sh");

// ---------------------------------------------------------------- labels and names

/// The buck2 label out of an action identity. REFUSES TO GUESS: splitting on the first " ("
/// returns a label that LOOKS right and silently groups the action wrongly. See #92, where the
/// real fix is reading the label from buck2's own types rather than its rendered output.
fn target_of(identity: &str) -> Result<&str, String> {
    // ^(?P<label>[^ ]+) \((?P<cfg>[^)]*)\) \((?P<action>.+)\)$
    let label_end = match identity.find(' ') {
        Some(i) => i,
        None => return Err(identity.to_string()),
    };
    let rest = &identity[label_end + 1..];
    if !rest.starts_with('(') {
        return Err(identity.to_string());
    }
    let cfg_end = match rest.find(')') {
        Some(i) => i,
        None => return Err(identity.to_string()),
    };
    let after = &rest[cfg_end + 1..];
    if !after.starts_with(" (") || !after.ends_with(')') || after.len() < 4 {
        return Err(identity.to_string());
    }
    Ok(&identity[..label_end])
}

/// A coarse pin folds its members into one synthetic label. WHICH pins may be folded is decided
/// in the DUMP: contracting a DAG can create cycles and this graph has them, so re-deriving the
/// choice here would be re-deriving the bug.
fn group_of(label: &str, coarse_pin_of: &Map<String, Value>, coarse_pins: bool) -> String {
    if !coarse_pins {
        return label.to_string();
    }
    match coarse_pin_of.get(label).and_then(|v| v.as_str()) {
        Some(pin) => format!("root//buck-src:pin-{pin}"),
        None => label.to_string(),
    }
}

/// A store-safe file name, INJECTIVELY: the name keys the consumer lookup, so a collision would
/// silently merge two derivations. Checked in group_specs.
fn safe_name(group: &str) -> String {
    group
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '.' || c == '-' { c } else { '_' })
        .collect()
}

/// Order preserving, which is what lib.unique is. NEVER sorted.
fn uniq<I: IntoIterator<Item = String>>(xs: I) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for x in xs {
        if seen.insert(x.clone()) {
            out.push(x);
        }
    }
    out
}

// ---------------------------------------------------------------- escaping

fn is_safe_arg(s: &str) -> bool {
    // ^[A-Za-z0-9,._+:@%/-]+$
    !s.is_empty()
        && s.chars().all(|c| {
            c.is_ascii_alphanumeric() || matches!(c, ',' | '.' | '_' | '+' | ':' | '@' | '%' | '/' | '-')
        })
}

/// @X@ where X is [A-Z_0-9]+. Returns (start, end, name) for each.
fn placeholders(s: &str) -> Vec<(usize, usize, String)> {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'@' {
            let mut j = i + 1;
            while j < b.len() && (b[j].is_ascii_uppercase() || b[j].is_ascii_digit() || b[j] == b'_') {
                j += 1;
            }
            if j > i + 1 && j < b.len() && b[j] == b'@' {
                out.push((i, j + 1, s[i + 1..j].to_string()));
                i = j + 1;
                continue;
            }
        }
        i += 1;
    }
    out
}

fn ph_var(name: &str) -> String {
    format!("CIDER_PH_{name}")
}

fn dq_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"").replace('$', "\\$").replace('`', "\\`")
}

/// Double quotes, not single, because a single-quoted string does not expand. Everything special
/// inside double quotes is escaped, so only the placeholder expands and an argv containing a
/// literal dollar or backtick cannot become a command substitution.
fn esc_with_placeholders(s: &str) -> String {
    let mut out = String::from("\"");
    let mut last = 0;
    for (start, end, name) in placeholders(s) {
        out.push_str(&dq_escape(&s[last..start]));
        out.push_str(&format!("${{{}}}", ph_var(&name)));
        last = end;
    }
    out.push_str(&dq_escape(&s[last..]));
    out.push('"');
    out
}

/// Byte for byte as nixpkgs lib.escapeShellArg does. IT DOES NOT ALWAYS QUOTE, which is the
/// whole reason this is a function: assuming it did produced a script that differed from the
/// lowering on EVERY line while being perfectly valid shell.
fn esc(s: &str) -> String {
    if !placeholders(s).is_empty() {
        return esc_with_placeholders(s);
    }
    if is_safe_arg(s) {
        return s.to_string();
    }
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// lib.escapeShellArg including its no-quotes-needed case, for paths rather than argv.
fn sh_quote(s: &str) -> String {
    if s.is_empty() {
        return "''".to_string();
    }
    if is_safe_arg(s) {
        return s.to_string();
    }
    format!("'{}'", s.replace('\'', "'\\''"))
}

// ---------------------------------------------------------------- the graph

struct Graph {
    actions: Vec<Value>,
    coarse_pin_of: Map<String, Value>,
    staged: Map<String, Value>,
    staged_trees: Map<String, Value>,
    staged_tree_deps: Map<String, Value>,
}

fn arr<'a>(a: &'a Value, k: &str) -> &'a [Value] {
    a.get(k).and_then(|v| v.as_array()).map(|v| v.as_slice()).unwrap_or(&[])
}

fn strs(a: &Value, k: &str) -> Vec<String> {
    arr(a, k).iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect()
}

/// The lowering's needsOf. Field for field, so it can be diffed by eye against the nix.
struct Needs<'g> {
    g: &'g Graph,
    order: Vec<String>,
    targets: HashMap<String, Vec<usize>>,
    producer: HashMap<String, String>,
    known: HashSet<String>,
    staged_by_target: HashMap<String, Vec<String>>,
    owner_cache: std::cell::RefCell<HashMap<String, Option<String>>>,
}

impl<'g> Needs<'g> {
    fn new(g: &'g Graph) -> Needs<'g> {
        let mut order = Vec::new();
        let mut targets: HashMap<String, Vec<usize>> = HashMap::new();
        let mut producer: HashMap<String, String> = HashMap::new();
        for (i, a) in g.actions.iter().enumerate() {
            let ident = a.get("identity").and_then(|v| v.as_str()).unwrap_or("");
            let label = target_of(ident).unwrap_or(ident);
            let grp = group_of(label, &g.coarse_pin_of, true);
            if !targets.contains_key(&grp) {
                order.push(grp.clone());
            }
            targets.entry(grp.clone()).or_default().push(i);
            for o in strs(a, "outputs") {
                producer.insert(o, grp.clone());
            }
        }

        let mut known: HashSet<String> = producer.keys().cloned().collect();
        known.extend(g.staged.keys().cloned());
        known.extend(g.staged_trees.keys().cloned());

        // ATTRIBUTE NAMES COME OUT OF NIX SORTED, so the two halves are sorted separately and
        // then concatenated, exactly as `attrNames a ++ attrNames b` does. Feeding hash order
        // here would give the right SET with the wrong ORDER, which is the failure this goes out
        // of its way to be able to see.
        let mut sa: Vec<String> = g.staged.keys().cloned().collect();
        sa.sort();
        let mut st: Vec<String> = g.staged_trees.keys().cloned().collect();
        st.sort();
        let mut staged_by_target: HashMap<String, Vec<String>> = HashMap::new();
        for o in sa.into_iter().chain(st.into_iter()) {
            let k = producer.get(&o).cloned().unwrap_or_default();
            staged_by_target.entry(k).or_default().push(o);
        }

        Needs {
            g,
            order,
            targets,
            producer,
            known,
            staged_by_target,
            owner_cache: std::cell::RefCell::new(HashMap::new()),
        }
    }

    fn acts(&self, label: &str) -> &[usize] {
        self.targets.get(label).map(|v| v.as_slice()).unwrap_or(&[])
    }

    /// Every artifact this group's actions write, deduped in order. These become the cp -aT
    /// lines that put the results under $out.
    fn outs_of(&self, label: &str) -> Vec<String> {
        uniq(self.acts(label).iter().flat_map(|&i| strs(&self.g.actions[i], "outputs")))
    }

    /// The LONGEST known prefix of a path, or None. An input can be a file INSIDE a directory
    /// output, so exact matching is not enough.
    fn owner_of(&self, path: &str, exact: bool) -> Option<String> {
        if exact {
            return if self.known.contains(path) { Some(path.to_string()) } else { None };
        }
        if let Some(hit) = self.owner_cache.borrow().get(path) {
            return hit.clone();
        }
        let segs: Vec<&str> = path.split('/').collect();
        let mut got = None;
        for n in (1..=segs.len()).rev() {
            let p = segs[..n].join("/");
            if self.known.contains(&p) {
                got = Some(p);
                break;
            }
        }
        self.owner_cache.borrow_mut().insert(path.to_string(), got.clone());
        got
    }

    /// `break_rule` disables exactly ONE rule, for the controls. Breaking a rule here rather than
    /// mangling the result afterwards is the difference between a control that proves the rule is
    /// exercised by this graph and one that only proves the comparison can subtract.
    fn of(&self, label: &str, break_rule: &str) -> (Vec<String>, Vec<String>) {
        let acts = self.acts(label);
        let ins = uniq(acts.iter().flat_map(|&i| strs(&self.g.actions[i], "inputs")));
        let ex = break_rule == "exact";
        let direct = uniq(ins.iter().filter_map(|i| self.owner_of(i, ex)));

        // A None from owner_of is dropped; dropping before or after the dedup gives the same
        // order, since removing a value cannot reorder the others.
        let via: Vec<String> = if break_rule == "vialinks" {
            Vec::new()
        } else {
            uniq(direct.iter().flat_map(|o| {
                self.g
                    .staged_tree_deps
                    .get(o)
                    .and_then(|v| v.as_array())
                    .map(|a| a.iter().filter_map(|t| t.as_str()).filter_map(|t| self.owner_of(t, ex)).collect::<Vec<_>>())
                    .unwrap_or_default()
            }))
        };
        let owners = uniq(direct.iter().cloned().chain(via.into_iter()));

        let declared: Vec<String> = if break_rule == "declared" {
            Vec::new()
        } else {
            uniq(acts.iter().flat_map(|&i| {
                strs(&self.g.actions[i], "input_targets")
                    .into_iter()
                    .map(|t| group_of(&t, &self.g.coarse_pin_of, true))
                    .collect::<Vec<_>>()
            }))
        };
        let declared_with_actions: Vec<String> =
            declared.iter().filter(|t| self.targets.contains_key(*t)).cloned().collect();
        let declared_staged: Vec<String> = declared
            .iter()
            .flat_map(|t| self.staged_by_target.get(t).cloned().unwrap_or_default())
            .collect();

        let from_targets = uniq(
            owners
                .iter()
                .filter_map(|o| self.producer.get(o).cloned())
                .chain(declared_with_actions.into_iter())
                .filter(|t| t != label),
        );
        let from_staged = uniq(
            owners
                .iter()
                .filter(|o| self.g.staged.contains_key(*o) || self.g.staged_trees.contains_key(*o))
                .cloned()
                .chain(declared_staged.into_iter()),
        );
        (from_targets, from_staged)
    }
}

// ---------------------------------------------------------------- the builder template

fn dep_var(name: &str) -> String {
    let s: String = name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect();
    format!("DYN_DEP_{s}")
}

/// The whole of builderScriptWith, as an ALTERNATING TEMPLATE: literal, variable, literal, ...
/// Always odd length, so index parity alone says which is which.
///
/// WHY A TEMPLATE AND NOT A FINISHED STRING, measured rather than argued: a consumer has to put
/// its own paths in, and with a finished string that means replaceStrings scanning 77 MB of text
/// against up to 130 patterns. A template turns the same job into concatenation.
fn builder_parts(n: &Needs, label: &str, group_script: &str) -> Vec<String> {
    let (nt, ns) = n.of(label, "");
    let mut parts: Vec<String> = vec![String::new()];
    macro_rules! lit {
        ($s:expr) => {{
            let last = parts.len() - 1;
            parts[last].push_str($s);
        }};
    }
    macro_rules! var {
        ($v:expr) => {{
            parts.push($v.to_string());
            parts.push(String::new());
        }};
    }

    lit!("mkdir -p work && cd work\n");
    var!("CIDER_STAGE");
    lit!("\n");
    lit!("\n");
    lit!("# What other targets built, at the paths this target's argv expects. Modes are\n");
    lit!("# PRESERVED: a dependency can be a TOOL -- migcom is, and the port's every codegen\n");
    lit!("# edge runs it -- and dropping the executable bit turns into \"Permission denied\"\n");
    lit!("# inside mig.sh, a long way from here. Writability is restored afterwards instead,\n");
    lit!("# because the store copy is read-only and later actions write next to it.\n");
    for dep in &nt {
        lit!("cp -a ");
        var!(dep_var(&safe_name(dep)));
        lit!("/. .\n");
        lit!("# After EACH one, not at the end: the copy reproduces the store's read-only\n");
        lit!("# directories, and two dependencies share parent directories under buck-out, so\n");
        lit!("# the second copy cannot write into what the first one just created.\n");
        lit!("find . -type d ! -perm -u+w -exec chmod u+w {} +\n");
    }
    lit!("\n");
    lit!("\n");
    lit!("# And the artifacts buck2 made in-process rather than by running a command. A staged\n");
    lit!("# include root is rebuilt from its link map; anything buck2 GENERATED rather than\n");
    lit!("# linked was copied out and is restored from there.\n");
    // NUMBERED BY SCRIPTS EMITTED, not by position in fromStaged. An entry with no links emits
    // no script, so indexing on the loop variable silently shifts every later number past the
    // first such entry: 730 of 1,474 labels matched anyway, because a group whose entries all
    // have links has the two numberings agree. The 744 that did not are what found this.
    let mut tree = 0;
    for o in &ns {
        let has_links = n
            .g
            .staged_trees
            .get(o)
            .and_then(|v| v.get("n"))
            .and_then(|v| v.as_i64())
            .unwrap_or(0)
            > 0;
        let data = n.g.staged.get(o).and_then(|v| v.as_str());
        if has_links {
            var!(format!("CIDER_TREE_{tree}"));
            lit!("\n");
            tree += 1;
        }
        if let Some(data) = data {
            if has_links {
                lit!("# MERGED, not replaced: a tree can hold both links into the project and files\n");
                lit!("# buck2 generated (rtsig.h is one), and copying over the farm with -T destroys\n");
                lit!("# the links that were just made.\n");
                lit!("cp -a ");
                var!("CIDER_DATA");
                lit!(&format!("/{}/. {}/\n", data, sh_quote(o)));
                lit!(&format!("chmod -R u+w {}\n", sh_quote(o)));
            } else {
                lit!(&format!("mkdir -p \"$(dirname {})\"\n", sh_quote(o)));
                lit!("cp -aT ");
                var!("CIDER_DATA");
                lit!(&format!("/{} {}\n", data, sh_quote(o)));
                lit!(&format!("chmod -R u+w {}\n", sh_quote(o)));
            }
        }
    }
    lit!("\n");
    lit!("\n");
    lit!(&HARNESS.replace("%(label)s", label));
    var!("EXPORTS");
    // THE TEMPLATE'S OWN NEWLINE, after the interpolation. Both this one and the final one below
    // were missing at first and cost exactly two bytes across 5,662, which is precisely the kind
    // of thing a comparison against the real script catches and a reading of the code does not.
    lit!(&format!("{group_script}\n"));
    lit!("_drain\n");
    lit!("\n");
    lit!("# Everything this target produced, at the SAME relative paths, so a consumer can\n");
    lit!("# stage it exactly where its own argv expects it.\n");
    for o in n.outs_of(label) {
        lit!(&format!("mkdir -p \"$out/$(dirname {})\"\n", sh_quote(&o)));
        lit!(&format!("cp -aT {} \"$out/{}\"\n", sh_quote(&o), o));
    }
    lit!("\n");
    parts
}

/// Even index literal, odd index variable name. The one place that rule is written down.
fn join_parts(parts: &[String], exports: &str) -> String {
    let mut out = String::new();
    for (i, p) in parts.iter().enumerate() {
        if i % 2 == 0 {
            out.push_str(p);
        } else if p == "EXPORTS" {
            out.push_str(exports);
        } else {
            out.push_str(&format!("\"${p}\""));
        }
    }
    out
}

// ---------------------------------------------------------------- the per-group action script

/// THE _drain BRANCH IS THE WHOLE SUBTLETY. Independent actions run concurrently through _spawn;
/// one that reads an output THIS group produces must wait for everything in flight, hence _drain
/// before it. Sound only because the action list is topological.
fn action_script(g: &Graph, idxs: &[usize]) -> String {
    let mut own: HashSet<String> = HashSet::new();
    for &i in idxs {
        own.extend(strs(&g.actions[i], "outputs"));
    }
    let mut out = String::new();
    for &i in idxs {
        let a = &g.actions[i];
        for o in strs(a, "outputs") {
            out.push_str(&format!("mkdir -p \"$(dirname {})\"\n", esc(&o)));
        }
        out.push_str(&format!(
            "echo \"  {}\"\n",
            a.get("identity").and_then(|v| v.as_str()).unwrap_or("")
        ));
        let cmd: Vec<String> = strs(a, "argv").iter().map(|x| esc(x)).collect();
        let cmd = cmd.join(" ");
        if strs(a, "inputs").iter().any(|i| own.contains(i)) {
            out.push_str(&format!("_drain\n{cmd}\n"));
        } else {
            out.push_str(&format!("_spawn {cmd}\n"));
        }
    }
    out
}

// ---------------------------------------------------------------- checks

/// Refuse to emit a script referencing a placeholder nobody exports. The failure it prevents is
/// the silent kind: an unset ${CIDER_PH_X} expands to the EMPTY STRING, and an argument quietly
/// losing a path fragment is about the worst way for this to go wrong.
fn check_placeholders(g: &Graph) -> Result<(), String> {
    const KNOWN: &[&str] = &["CLANG", "RESOURCE_DIR", "LD64"];
    let mut seen: Vec<(String, String, String)> = Vec::new();
    let mut have: HashSet<String> = HashSet::new();
    for a in &g.actions {
        for x in strs(a, "argv") {
            for (_, _, name) in placeholders(&x) {
                if have.insert(name.clone()) {
                    seen.push((
                        name,
                        a.get("identity").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                        x.clone(),
                    ));
                }
            }
        }
    }
    let mut unknown: Vec<&(String, String, String)> =
        seen.iter().filter(|(k, _, _)| !KNOWN.contains(&k.as_str())).collect();
    unknown.sort_by(|a, b| a.0.cmp(&b.0));
    if unknown.is_empty() {
        return Ok(());
    }
    let mut lines = vec![format!("FAIL: {} placeholder(s) no consumer exports:", unknown.len())];
    for (k, ident, arg) in &unknown {
        lines.push(format!("    @{k}@  first in {ident}\n        {arg}"));
    }
    lines.push(format!(
        "The emitted script would expand ${{{}}} to the empty string. Either add it to \
         KNOWN_PLACEHOLDERS here AND to `placeholders` in nix/lib/ciderBuck2Lower.nix, or stop \
         buck2-graph-dump.py from emitting it.",
        ph_var(&unknown[0].0)
    ));
    Err(lines.join("\n"))
}

/// The first cycle found, or empty. A cycle is FATAL rather than suboptimal: dyn-actions.nix
/// resolves a dependency to another action's OUTPUT, so a cycle is an infinite recursion in the
/// evaluator naming neither party.
fn acyclic(order: &[String], deps: &HashMap<String, Vec<String>>) -> Vec<String> {
    const WHITE: u8 = 0;
    const GREY: u8 = 1;
    const BLACK: u8 = 2;
    // ITERATIVE, not the python's recursion. This graph is 1,474 groups deep enough that a
    // recursive walk is a stack risk for no gain, and an explicit work stack is also what makes
    // the GREY test below obviously the same test.
    let mut colour: HashMap<&str, u8> = order.iter().map(|g| (g.as_str(), WHITE)).collect();
    for start in order {
        if colour.get(start.as_str()).copied().unwrap_or(WHITE) != WHITE {
            continue;
        }
        let mut stack: Vec<&str> = vec![start.as_str()];
        let mut work: Vec<(&str, usize)> = vec![(start.as_str(), 0)];
        colour.insert(start.as_str(), GREY);
        while let Some(&(n, ci)) = work.last() {
            let children: &[String] = deps.get(n).map(|v| v.as_slice()).unwrap_or(&[]);
            if ci < children.len() {
                let last = work.len() - 1;
                work[last].1 += 1;
                let m = children[ci].as_str();
                match colour.get(m).copied().unwrap_or(WHITE) {
                    GREY => {
                        let at = stack.iter().position(|x| *x == m).unwrap_or(0);
                        let mut out: Vec<String> =
                            stack[at..].iter().map(|s| s.to_string()).collect();
                        out.push(m.to_string());
                        return out;
                    }
                    WHITE => {
                        colour.insert(m, GREY);
                        stack.push(m);
                        work.push((m, 0));
                    }
                    _ => {}
                }
            } else {
                colour.insert(n, BLACK);
                stack.pop();
                work.pop();
            }
        }
    }
    Vec::new()
}

// ---------------------------------------------------------------- main

fn die(msg: String) -> ExitCode {
    eprintln!("{msg}");
    ExitCode::FAILURE
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 2 {
        eprintln!("  cider-graph-specs <graph.json> <outdir>");
        return ExitCode::FAILURE;
    }
    let raw = match fs::read_to_string(&args[0]) {
        Ok(t) => t,
        Err(e) => return die(format!("cannot read {}: {e}", args[0])),
    };
    let root: Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => return die(format!("cannot parse {}: {e}", args[0])),
    };
    let obj = |k: &str| -> Map<String, Value> {
        root.get(k).and_then(|v| v.as_object()).cloned().unwrap_or_default()
    };
    let g = Graph {
        actions: root.get("actions").and_then(|v| v.as_array()).cloned().unwrap_or_default(),
        coarse_pin_of: obj("coarsePinOf"),
        staged: obj("staged"),
        staged_trees: obj("stagedTrees"),
        staged_tree_deps: obj("stagedTreeDeps"),
    };

    if let Err(e) = check_placeholders(&g) {
        return die(e);
    }

    // {group: [action index]} in buck2 order, and safe_name must be injective over it.
    let mut order: Vec<String> = Vec::new();
    let mut groups: HashMap<String, Vec<usize>> = HashMap::new();
    for (i, a) in g.actions.iter().enumerate() {
        let ident = a.get("identity").and_then(|v| v.as_str()).unwrap_or("");
        let label = match target_of(ident) {
            Ok(l) => l,
            Err(bad) => {
                return die(format!(
                    "FAIL: cannot parse a buck2 action identity: {bad:?}\nExpected `LABEL \
                     (CONFIGURATION) (ACTION)`. Splitting on the first ' (' would return a label \
                     that LOOKS right and silently group this action wrongly, so this stops \
                     instead. See #92."
                ))
            }
        };
        let grp = group_of(label, &g.coarse_pin_of, true);
        if !groups.contains_key(&grp) {
            order.push(grp.clone());
        }
        groups.entry(grp).or_default().push(i);
    }
    let mut seen: HashMap<String, String> = HashMap::new();
    for grp in &order {
        let s = safe_name(grp);
        if let Some(prev) = seen.get(&s) {
            return die(format!(
                "FAIL: safe_name is not injective: {grp:?} and {prev:?} both give {s:?}. Two \
                 groups would silently share one derivation."
            ));
        }
        seen.insert(s, grp.clone());
    }
    let total_actions: usize = groups.values().map(|v| v.len()).sum();
    if total_actions != g.actions.len() {
        return die(format!(
            "FAIL: {total_actions} actions across groups but {} in the graph; the grouping \
             dropped some",
            g.actions.len()
        ));
    }

    let outdir = Path::new(&args[1]);
    if let Err(e) = fs::create_dir_all(outdir) {
        return die(format!("cannot create {}: {e}", outdir.display()));
    }

    let mut names: Vec<String> = Vec::new();
    let mut scripts: Map<String, Value> = Map::new();
    for grp in &order {
        let n = safe_name(grp);
        names.push(n.clone());
        let idxs = &groups[grp];
        let acts: Vec<Value> = idxs.iter().map(|&i| g.actions[i].clone()).collect();
        let mut m = Map::new();
        m.insert("group".into(), Value::String(grp.clone()));
        m.insert("actions".into(), Value::Array(acts));
        if let Err(e) = fs::write(outdir.join(format!("{n}.json")), pyjson::dumps(&Value::Object(m))) {
            return die(format!("write {n}.json: {e}"));
        }
        scripts.insert(n, Value::String(action_script(&g, idxs)));
    }
    if let Err(e) = fs::write(outdir.join("names"), format!("{}\n", names.join("\n"))) {
        return die(format!("write names: {e}"));
    }

    let needs = Needs::new(&g);
    // THE TWO GROUPINGS MUST BE THE SAME ONE. Needs regroups the graph itself, so a divergence
    // would hand every group somebody else's dependency list, quietly.
    let a: HashSet<&String> = needs.order.iter().collect();
    let b: HashSet<&String> = order.iter().collect();
    if a != b {
        return die(format!(
            "FAIL: the two groupings disagree, {} against {}",
            needs.order.len(),
            order.len()
        ));
    }

    let mut full: Map<String, Value> = Map::new();
    for grp in &order {
        let n = safe_name(grp);
        let script = scripts[&n].as_str().unwrap_or("");
        let parts = builder_parts(&needs, grp, script);
        full.insert(n, Value::Array(parts.into_iter().map(Value::String).collect()));
    }
    if let Err(e) = fs::write(outdir.join("full.json"), pyjson::dumps(&Value::Object(full))) {
        return die(format!("write full.json: {e}"));
    }

    let mut needs_out: Map<String, Value> = Map::new();
    for grp in &order {
        let (t, s) = needs.of(grp, "");
        let trees: Vec<String> = s
            .iter()
            .filter(|o| {
                g.staged_trees
                    .get(*o)
                    .and_then(|v| v.get("n"))
                    .and_then(|v| v.as_i64())
                    .unwrap_or(0)
                    > 0
            })
            .cloned()
            .collect();
        needs_out.insert(
            safe_name(grp),
            json!({"t": t, "s": s, "trees": trees}),
        );
    }
    if let Err(e) = fs::write(outdir.join("needs.json"), pyjson::dumps(&Value::Object(needs_out))) {
        return die(format!("write needs.json: {e}"));
    }

    // THE EDGE SET THE BRIDGE CANNOT INFER: in specDir mode the spec files are copied without
    // being parsed, so a dependency that is not here does not exist, and the failure is silent
    // because every action still builds and simply sees an empty dependency.
    let mut producer: HashMap<String, String> = HashMap::new();
    for grp in &order {
        for &i in &groups[grp] {
            for o in strs(&g.actions[i], "outputs") {
                producer.insert(o, grp.clone());
            }
        }
    }
    let mut deps: HashMap<String, Vec<String>> = HashMap::new();
    for grp in &order {
        let mut set: HashSet<String> = HashSet::new();
        for &i in &groups[grp] {
            let a = &g.actions[i];
            for i2 in strs(a, "inputs") {
                if let Some(p) = producer.get(&i2) {
                    if p != grp {
                        set.insert(p.clone());
                    }
                }
            }
            for t in strs(a, "input_targets") {
                let grp2 = group_of(&t, &g.coarse_pin_of, true);
                if &grp2 != grp && groups.contains_key(&grp2) {
                    set.insert(grp2);
                }
            }
        }
        let mut v: Vec<String> = set.into_iter().collect();
        v.sort();
        deps.insert(grp.clone(), v);
    }
    let cycle = acyclic(&order, &deps);
    if !cycle.is_empty() {
        return die(format!(
            "FAIL: the group dependency graph has a cycle, which nix/lib/dyn-actions.nix cannot \
             express:\n    {}",
            cycle.join("\n -> ")
        ));
    }
    let mut deps_json: Map<String, Value> = Map::new();
    for grp in &order {
        deps_json.insert(
            safe_name(grp),
            Value::Array(deps[grp].iter().map(|d| Value::String(safe_name(d))).collect()),
        );
    }
    let deps_text = pyjson::dumps(&Value::Object(deps_json));
    if let Err(e) = fs::write(outdir.join("deps.json"), &deps_text) {
        return die(format!("write deps.json: {e}"));
    }

    if let Err(e) = fs::write(outdir.join("scripts.json"), pyjson::dumps(&Value::Object(scripts.clone()))) {
        return die(format!("write scripts.json: {e}"));
    }

    // THE SAME GROUPS AS BRIDGE SPECS, in the layout dyn-actions.nix reads in specDir mode. A
    // SUBDIRECTORY because the <name>.json at the top level is the ACTION DATA, a different shape
    // entirely, and two files of different shape under one name is how a consumer ends up reading
    // the wrong one without an error.
    //
    // THE EXPORTS SLOT IS EMPTY HERE, not a marker: an emitted action gets CIDER_PH_* from the
    // consumer's extraEnv directly.
    let dyn_dir = outdir.join("dyn");
    if let Err(e) = fs::create_dir_all(&dyn_dir) {
        return die(format!("cannot create dyn: {e}"));
    }
    let preamble = format!("set -e\nexport PATH=\"$CIDER_PATH\"\nexport out=\"${BRIDGE_OUTPUT_NAME}\"\n");
    for grp in &order {
        let n = safe_name(grp);
        let script = scripts[&n].as_str().unwrap_or("");
        let body = join_parts(&builder_parts(&needs, grp, script), "");
        let mut spec = Map::new();
        spec.insert("name".into(), Value::String(n.clone()));
        spec.insert("builder".into(), Value::String("/bin/sh".into()));
        spec.insert(
            "args".into(),
            Value::Array(vec![Value::String("-c".into()), Value::String(format!("{preamble}{body}"))]),
        );
        // THE SYSTEM IS THE CONSUMER'S, and it is the one field a generator genuinely cannot
        // know. Left out, and the consumer fills it in.
        spec.insert("env".into(), Value::Object(Map::new()));
        let mut inputs = Map::new();
        inputs.insert("drvs".into(), Value::Object(Map::new()));
        inputs.insert("srcs".into(), Value::Array(vec![]));
        spec.insert("inputs".into(), Value::Object(inputs));
        let mut outs = Map::new();
        outs.insert(
            BRIDGE_OUTPUT_NAME.into(),
            json!({"hashAlgo": "sha256", "method": "nar"}),
        );
        spec.insert("outputs".into(), Value::Object(outs));
        spec.insert("version".into(), Value::Number(4.into()));
        if let Err(e) = fs::write(dyn_dir.join(format!("{n}.json")), pyjson::dumps(&Value::Object(spec))) {
            return die(format!("write dyn/{n}.json: {e}"));
        }
    }
    if let Err(e) = fs::write(dyn_dir.join("names"), format!("{}\n", names.join("\n"))) {
        return die(format!("write dyn/names: {e}"));
    }
    if let Err(e) = fs::write(dyn_dir.join("deps.json"), &deps_text) {
        return die(format!("write dyn/deps.json: {e}"));
    }

    println!(
        "wrote {} group spec(s) and script(s), {total_actions} action(s), to {}",
        names.len(),
        outdir.display()
    );
    ExitCode::SUCCESS
}
