//! DO THE RENDERED PER-GROUP ACTION SCRIPTS STILL SAY WHAT THE LOWERING MEANS? (#66)
//!
//! THE RUST REWRITE of the python buck-specs-check (#98), and the one whose own header argued it
//! could not move. That argument was about NUSHELL and it still holds: the verdict rests entirely
//! on tokenising 59 MB of script text, a character loop in nushell runs at about 25 KB/s and gets
//! roughly eight times worse per byte at 4.9 MB than at 6.5 KB, so the whole dump would take over
//! an hour. None of that is an argument against Rust, where the same character loop is the
//! natural way to write it. The rejected alternative is still rejected: a regex tokeniser goes
//! silently wrong exactly on adjacency (a"b"c is ONE word) and on mixed quoting inside a word,
//! which is what this check exists to compare.
//!
//! WHY THE CHECK EXISTS. #66 moved the lowering action rendering out of the evaluator and into
//! cider-graph-specs. That leaves the SAME rule written in two places, how an action identity
//! becomes a group, how an argv element is escaped, when an action must _drain first, and a
//! disagreement between them is silent in the worst way: the endpoint would build a perfectly
//! valid script that runs the wrong commands, and nothing would say so.
//!
//! SO IT RE-DERIVES THE ANSWER INDEPENDENTLY. It does not call the generator, because a check
//! that asks the thing under test what the answer is cannot fail. It reads graph.json, works out
//! what each group script MUST contain, and compares that against scripts.json, which is what
//! the generator wrote and what the lowering reads. THE SAME RULE APPLIES TO THIS FILE: it does
//! NOT use src/srcset.rs or the generator own group_of, it spells the rules out again, which is
//! why they are duplicated here on purpose.
//!
//! COMPARISON IS ON WORDS, NOT TEXT. The two renderings quote differently on purpose: the old
//! evaluator path used nixpkgs escapeShellArg, which leaves a string bare when it matches
//! [[:alnum:],._+:@%/-]+, while a string holding a placeholder must be double quoted so the
//! variable expands. "/nix/store/x" and /nix/store/x are different text and the same word.
//! Comparing text reports 1,215 of 1,474 scripts as differing when none of them do.
//!
//! AND IT PROVES IT CAN FAIL. --controls mutates a real script four ways and reports whether each
//! was caught, by the sub-check meant to catch it. Two earlier versions of these controls did not
//! fire: one mutation did not apply to the group it was tried on, and one deleted a _drain, which
//! the sequence comparison cannot see by construction.
//!
//! --dump-canon prints one line per group with the sha256 of its canonical form. It was written
//! as the gate for whoever ported the tokeniser, and it is what gated THIS port: 1,474 lines,
//! byte identical against the python.
//!
//! Usage:
//!   cider-specs-check <graph.json> <specsdir>              # check
//!   cider-specs-check <graph.json> <specsdir> --controls   # and prove it can fail
//!   cider-specs-check <graph.json> <specsdir> --dump-canon # the port gate

#[path = "sha256.rs"]
mod sha256;
use sha256::sha256;
#[path = "pyshlex.rs"]
mod pyshlex;
use pyshlex::shlex_split;

use serde_json::{Map, Value};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs;
use std::process::ExitCode;

/// Placeholders resolve to these only for the comparison. The VALUES do not matter and must not:
/// what is being checked is that the same word comes out, not which store path it names. Fake
/// paths keep a real one from accidentally matching something. ORDER IS THE PYTHON DICT ORDER,
/// which expand() walks.
const PH_VALUES: &[(&str, &str)] = &[
    ("CLANG", "/PH/clang"),
    ("RESOURCE_DIR", "/PH/resource-root"),
    ("LD64", "/PH/ld64"),
];

// ---------------------------------------------------------------- python-shaped rendering
//
// A LOCAL COPY, and worth saying why: equiv.rs renders python reprs too, but for arbitrary JSON
// values, and srcdeps.rs has a list-of-strings one. Sharing them would mean re-gating two
// binaries this port has already frozen, in the same turn as porting a third. The shape here is
// fixed and small: a str, a list of str, and the 2-tuple this check compares.

fn py_quote(s: &str) -> String {
    let q = if s.contains('\'') && !s.contains('"') { '"' } else { '\'' };
    let mut out = String::new();
    out.push(q);
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c == q => {
                out.push('\\');
                out.push(c);
            }
            c if (c as u32) < 0x20 || (c as u32) == 0x7f => {
                out.push_str(&format!("\\x{:02x}", c as u32))
            }
            c => out.push(c),
        }
    }
    out.push(q);
    out
}

fn py_list(items: &[String]) -> String {
    let inner: Vec<String> = items.iter().map(|s| py_quote(s)).collect();
    format!("[{}]", inner.join(", "))
}

/// repr of ("tag", ("word", ...)), including the one-element trailing comma.
fn py_entry(e: &Entry) -> String {
    let inner = if e.1.len() == 1 {
        format!("({},)", py_quote(&e.1[0]))
    } else {
        let ws: Vec<String> = e.1.iter().map(|s| py_quote(s)).collect();
        format!("({})", ws.join(", "))
    };
    if e.1.is_empty() {
        // ("drain",) is a ONE element tuple, which reprs with the trailing comma.
        format!("({},)", py_quote(e.0))
    } else {
        format!("({}, {})", py_quote(e.0), inner)
    }
}

fn truncate_chars(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// python OSError formatting, so a message about a missing file reads the same on both sides.
fn oserror(e: &std::io::Error, path: &str) -> String {
    match e.raw_os_error() {
        Some(code) => {
            let msg = match code {
                2 => "No such file or directory",
                13 => "Permission denied",
                20 => "Not a directory",
                21 => "Is a directory",
                _ => return format!("[Errno {code}] {e}: {}", py_quote(path)),
            };
            format!("[Errno {code}] {msg}: {}", py_quote(path))
        }
        None => format!("{e}: {}", py_quote(path)),
    }
}

// ---------------------------------------------------------------- the independent re-derivations

type Entry = (&'static str, Vec<String>);

/// IDENTITY = ^(?P<label>[^ ]+) \((?P<cfg>[^)]*)\) \((?P<action>.+)\)$
fn parse_identity(identity: &str) -> Option<&str> {
    let sp = identity.find(' ')?;
    let label = &identity[..sp];
    if label.is_empty() {
        return None;
    }
    let rest = &identity[sp..];
    let after = rest.strip_prefix(" (")?;
    let close = after.find(')')?;
    let rest2 = &after[close..];
    let action = rest2.strip_prefix(") (")?;
    let action = action.strip_suffix(')')?;
    // (.+) without DOTALL: at least one character, and no newline in it.
    if action.is_empty() || action.contains('\n') {
        return None;
    }
    Some(label)
}

fn group_of(identity: &str, coarse: &Map<String, Value>) -> Result<String, String> {
    let label = match parse_identity(identity) {
        Some(l) => l,
        None => return Err(format!("FAIL: unparseable action identity: {}", py_quote(identity))),
    };
    match coarse.get(label).and_then(|v| v.as_str()) {
        Some(pin) => Ok(format!("root//vendor/src:pin-{pin}")),
        None => Ok(label.to_string()),
    }
}

/// NAME_UNSAFE = [^A-Za-z0-9_.-], replaced with _.
fn safe_name(group: &str) -> String {
    group
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '.' || c == '-' { c } else { '_' })
        .collect()
}

/// PLACEHOLDER = @([A-Z_0-9]+)@, substituted where known and left alone where not.
fn fill(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = String::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'@' {
            let mut j = i + 1;
            while j < b.len() && (b[j].is_ascii_uppercase() || b[j] == b'_' || b[j].is_ascii_digit())
            {
                j += 1;
            }
            if j > i + 1 && j < b.len() && b[j] == b'@' {
                let name = &s[i + 1..j];
                match PH_VALUES.iter().find(|(k, _)| *k == name) {
                    Some((_, v)) => out.push_str(v),
                    None => out.push_str(&s[i..=j]),
                }
                i = j + 1;
                continue;
            }
        }
        let c = s[i..].chars().next().unwrap();
        out.push(c);
        i += c.len_utf8();
    }
    out
}

fn expand(text: &str) -> String {
    let mut t = text.to_string();
    for (k, v) in PH_VALUES {
        t = t.replace(&format!("${{CIDER_PH_{k}}}"), v);
    }
    t
}

/// Split on UNQUOTED newlines only. One argv in the real graph holds a literal newline (a mig
/// argument listing two file pairs); splitting on every newline tears that line in half and the
/// tokeniser then fails with No closing quotation, which is the harness breaking rather than the
/// script.
fn logical_lines(text: &str) -> Vec<String> {
    let cs: Vec<char> = text.chars().collect();
    let mut out: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut quote: Option<char> = None;
    let mut i = 0;
    while i < cs.len() {
        let mut c = cs[i];
        match quote {
            None => {
                if c == '\n' {
                    out.push(std::mem::take(&mut cur));
                    i += 1;
                    continue;
                }
                if c == '\'' || c == '"' {
                    quote = Some(c);
                } else if c == '\\' && i + 1 < cs.len() {
                    cur.push(c);
                    i += 1;
                    c = cs[i];
                }
            }
            Some(q) if c == q => quote = None,
            Some('"') if c == '\\' && i + 1 < cs.len() => {
                cur.push(c);
                i += 1;
                c = cs[i];
            }
            _ => {}
        }
        cur.push(c);
        i += 1;
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out.into_iter().filter(|x| !x.is_empty()).collect()
}

/// MKDIR = ^mkdir -p "\$\(dirname (.*)\)"$ with DOTALL, so the dollar allows one trailing newline.
fn mkdir_inner(line: &str) -> Option<&str> {
    let body = line.strip_prefix("mkdir -p \"$(dirname ")?;
    let body = body.strip_suffix('\n').unwrap_or(body);
    body.strip_suffix(")\"")
}

/// One rendered line as the WORDS a shell would see. Quoting style disappears.
fn canon(line: &str) -> Result<Entry, String> {
    if let Some(inner) = mkdir_inner(line) {
        return Ok(("mkdir", shlex_split(inner)?));
    }
    if line.starts_with("echo ") {
        return Ok(("echo", shlex_split(line)?));
    }
    if line == "_drain" {
        return Ok(("drain", Vec::new()));
    }
    if let Some(rest) = line.strip_prefix("_spawn ") {
        return Ok(("run", shlex_split(rest)?));
    }
    Ok(("run", shlex_split(line)?))
}

fn canon_script(text: &str) -> Result<Vec<Entry>, String> {
    logical_lines(&expand(text)).iter().map(|l| canon(l)).collect()
}

fn strs(v: &Value, k: &str) -> Vec<String> {
    v.get(k)
        .and_then(|x| x.as_array())
        .map(|a| a.iter().filter_map(|x| x.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default()
}

/// What the script MUST contain, derived from the graph rather than from a re-rendering.
fn expected_sequence(actions: &[&Value]) -> Vec<Entry> {
    let mut seq = Vec::new();
    for a in actions {
        for o in strs(a, "outputs") {
            seq.push(("mkdir", vec![fill(&o)]));
        }
        let ident = a.get("identity").and_then(|v| v.as_str()).unwrap_or("");
        seq.push(("echo", vec!["echo".to_string(), format!("  {ident}")]));
        seq.push(("run", strs(a, "argv").iter().map(|x| fill(x)).collect()));
    }
    seq
}

/// Which actions must be preceded by a _drain: those reading a sibling output.
fn expected_drains(actions: &[&Value]) -> Vec<bool> {
    let mut own: HashSet<String> = HashSet::new();
    for a in actions {
        own.extend(strs(a, "outputs"));
    }
    actions.iter().map(|a| strs(a, "inputs").iter().any(|i| own.contains(i))).collect()
}

fn actual_drains(seq: &[Entry]) -> Vec<bool> {
    let mut out = Vec::new();
    let mut pending = false;
    for e in seq {
        match e.0 {
            "drain" => pending = true,
            "run" => {
                out.push(pending);
                pending = false;
            }
            _ => pending = false,
        }
    }
    out
}

fn strip_drains(seq: &[Entry]) -> Vec<&Entry> {
    seq.iter().filter(|e| e.0 != "drain").collect()
}

// ---------------------------------------------------------------- the spec directory

struct Specs {
    dir: String,
    scripts: Option<Map<String, Value>>,
}

impl Specs {
    fn new(dir: &str) -> Specs {
        Specs { dir: dir.to_string(), scripts: None }
    }
    /// scripts.json, read once. It is one file rather than one .sh per group because the
    /// evaluator reads it, and 1,474 separate reads out of a deferred derivation output cost
    /// 19.6 s against 1.5 s for this.
    fn all_scripts(&mut self) -> Result<&Map<String, Value>, String> {
        if self.scripts.is_none() {
            let p = format!("{}/scripts.json", self.dir);
            let text = fs::read_to_string(&p).map_err(|e| oserror(&e, &p))?;
            let v: Value = serde_json::from_str(&text).map_err(|e| format!("{e}"))?;
            match v {
                Value::Object(m) => self.scripts = Some(m),
                _ => return Err(format!("{p} is not an object")),
            }
        }
        Ok(self.scripts.as_ref().unwrap())
    }
    fn forget(&mut self) {
        self.scripts = None;
    }
    /// KeyError in the python, whose str() is the repr of its argument, hence the quotes.
    fn read_script(&mut self, group: &str) -> Result<String, String> {
        let n = safe_name(group);
        let scripts = self.all_scripts()?;
        match scripts.get(&n).and_then(|v| v.as_str()) {
            Some(s) => Ok(s.to_string()),
            None => Err(py_quote(&format!("scripts.json has no entry for {n}"))),
        }
    }
}

// ---------------------------------------------------------------- grouping

struct Grouped<'a> {
    order: Vec<String>,
    map: HashMap<String, Vec<&'a Value>>,
    /// action index in buck2 order, per group, parallel to map
    idx: HashMap<String, Vec<usize>>,
}

fn group_actions<'a>(
    actions: &'a [Value],
    coarse: &Map<String, Value>,
) -> Result<Grouped<'a>, String> {
    let mut g = Grouped { order: Vec::new(), map: HashMap::new(), idx: HashMap::new() };
    for (i, a) in actions.iter().enumerate() {
        let ident = a.get("identity").and_then(|v| v.as_str()).unwrap_or("");
        let grp = group_of(ident, coarse)?;
        if !g.map.contains_key(&grp) {
            g.order.push(grp.clone());
            g.map.insert(grp.clone(), Vec::new());
            g.idx.insert(grp.clone(), Vec::new());
        }
        g.map.get_mut(&grp).unwrap().push(a);
        g.idx.get_mut(&grp).unwrap().push(i);
    }
    Ok(g)
}

// ---------------------------------------------------------------- deps.json

fn buckout_class(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'.' || c == b'/' || c == b'+' || c == b'-'
}

/// BUCKOUT = (buck-out/[A-Za-z0-9_./+-]+), non-overlapping, leftmost. Scanned as BYTES, because
/// an argv may hold any UTF-8 and a byte index into a str is a panic waiting for the one word
/// that is not ASCII; every byte a match can cover is ASCII by construction.
fn buckout_paths(s: &str) -> Vec<&str> {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i + 9 <= b.len() {
        if b[i..].starts_with(b"buck-out/") {
            let mut j = i + 9;
            while j < b.len() && buckout_class(b[j]) {
                j += 1;
            }
            if j > i + 9 {
                out.push(std::str::from_utf8(&b[i..j]).unwrap_or(""));
                i = j;
                continue;
            }
        }
        i += 1;
    }
    out
}

/// How many artifacts a group COMMANDS name that its sandbox would not contain.
///
/// THE ACTION OWN inputs ARE DELIBERATELY NOT CONSULTED. The first version allowed them, and
/// every argv path is already in inputs, so the test short-circuited before ever looking at deps:
/// it returned 0 with the real map AND 0 with every edge deleted. With the short-circuit gone:
/// 0 real, 2 with one edge dropped, 61,362 with all dropped.
fn uncovered_artifacts(g: &Grouped, deps: &HashMap<String, HashSet<String>>) -> usize {
    let mut outs_of: HashMap<&str, HashSet<String>> = HashMap::new();
    for grp in &g.order {
        let mut s = HashSet::new();
        for a in &g.map[grp] {
            s.extend(strs(a, "outputs"));
        }
        outs_of.insert(grp.as_str(), s);
    }
    let mut producer: HashMap<&str, &str> = HashMap::new();
    for (grp, os_) in &outs_of {
        for o in os_ {
            producer.insert(o.as_str(), *grp);
        }
    }
    let mut n = 0;
    for grp in &g.order {
        let mut allowed: HashSet<&str> =
            outs_of[grp.as_str()].iter().map(|s| s.as_str()).collect();
        if let Some(ds) = deps.get(grp) {
            for d in ds {
                if let Some(os_) = outs_of.get(d.as_str()) {
                    allowed.extend(os_.iter().map(|s| s.as_str()));
                }
            }
        }
        for a in &g.map[grp] {
            for x in strs(a, "argv") {
                for p in buckout_paths(&x) {
                    if allowed.contains(p) || !producer.contains_key(p) {
                        continue;
                    }
                    n += 1;
                }
            }
        }
    }
    n
}

/// deps.json must match the graph, and must respect buck2 own action ORDER.
///
/// THE ORDER CHECK IS THE INDEPENDENT ONE. Re-deriving the edges from inputs and comparing to a
/// file derived from inputs only proves the generator ran; it cannot catch a rule that is wrong
/// in the same way twice. g.actions is globally topological, a separate property, so for every
/// edge G to D the action in D that WRITES the artifact must come before the action in G that
/// reads it.
fn check_deps(
    actions: &[Value],
    coarse: &Map<String, Value>,
    g: &Grouped,
    specdir: &str,
) -> Vec<String> {
    let mut problems = Vec::new();
    let path = format!("{specdir}/deps.json");
    let listed: Map<String, Value> = match fs::read_to_string(&path) {
        Ok(t) => match serde_json::from_str::<Value>(&t) {
            Ok(Value::Object(m)) => m,
            _ => {
                return vec![format!(
                    "cannot read {path}: not an object; a spec dir without it is a SET, not a DAG"
                )]
            }
        },
        Err(e) => {
            return vec![format!(
                "cannot read {path}: {}; a spec dir without it is a SET, not a DAG",
                oserror(&e, &path)
            )]
        }
    };

    // Position of every action in buck2 order, and who writes what.
    let mut producer: HashMap<&str, usize> = HashMap::new();
    for (i, a) in actions.iter().enumerate() {
        for o in a.get("outputs").and_then(|v| v.as_array()).map(|x| x.as_slice()).unwrap_or(&[]) {
            if let Some(s) = o.as_str() {
                producer.insert(s, i);
            }
        }
    }
    let group_of_action: Vec<String> = {
        let mut v = Vec::with_capacity(actions.len());
        for a in actions {
            let ident = a.get("identity").and_then(|x| x.as_str()).unwrap_or("");
            v.push(group_of(ident, coarse).unwrap_or_default());
        }
        v
    };

    // TWO EDGE SOURCES, matching needsOf in the lowering. The artifact rule alone is not the
    // rule: an action that reads its inputs from a FILE names none of them in argv, so its
    // dependencies only appear in input_targets.
    let mut want: HashMap<String, HashSet<String>> = HashMap::new();
    for grp in &g.order {
        let mut seen: HashSet<String> = HashSet::new();
        for a in &g.map[grp] {
            for i in strs(a, "inputs") {
                if let Some(p) = producer.get(i.as_str()) {
                    let pg = &group_of_action[*p];
                    if pg != grp {
                        seen.insert(pg.clone());
                    }
                }
            }
            for t in strs(a, "input_targets") {
                let tg = match coarse.get(&t).and_then(|v| v.as_str()) {
                    Some(pin) => format!("root//vendor/src:pin-{pin}"),
                    None => t.clone(),
                };
                // A declared target with no actions has no derivation to depend on; what it owns
                // travels as staged data instead.
                if &tg != grp && g.map.contains_key(&tg) {
                    seen.insert(tg);
                }
            }
        }
        want.insert(safe_name(grp), seen.iter().map(|d| safe_name(d)).collect());
    }

    let listed_keys: HashSet<&str> = listed.keys().map(|k| k.as_str()).collect();
    let want_keys: HashSet<&str> = want.keys().map(|k| k.as_str()).collect();
    if listed_keys != want_keys {
        problems.push(format!(
            "deps.json covers {} groups, the graph has {}",
            listed.len(),
            want.len()
        ));
    }
    let both: BTreeSet<&str> = listed_keys.intersection(&want_keys).copied().collect();
    for k in both {
        let got: HashSet<String> = listed
            .get(k)
            .and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(|x| x.as_str().map(|s| s.to_string())).collect())
            .unwrap_or_default();
        let w = &want[k];
        if &got != w {
            // THE DIFFERENCE, not the first few sorted entries. Printing sorted heads made two
            // sets differing in their tails look identical, which is a report nobody can act on.
            let only_dep: Vec<String> =
                got.difference(w).cloned().collect::<BTreeSet<String>>().into_iter().take(3).collect();
            let only_graph: Vec<String> =
                w.difference(&got).cloned().collect::<BTreeSet<String>>().into_iter().take(3).collect();
            problems.push(format!(
                "{k}: only in deps.json {}, only in the graph {}",
                py_list(&only_dep),
                py_list(&only_graph)
            ));
        }
    }

    // SUFFICIENCY: could each group commands actually find what they name? Uses the label-keyed
    // edges rather than deps.json, because this asks whether the EDGE SET is complete, not
    // whether the file was written correctly, which is the check above.
    let mut label_deps: HashMap<String, HashSet<String>> = HashMap::new();
    for grp in &g.order {
        let mut seen = HashSet::new();
        for a in &g.map[grp] {
            for i in strs(a, "inputs") {
                if let Some(p) = producer.get(i.as_str()) {
                    let pg = &group_of_action[*p];
                    if pg != grp {
                        seen.insert(pg.clone());
                    }
                }
            }
        }
        label_deps.insert(grp.clone(), seen);
    }
    let missing = uncovered_artifacts(g, &label_deps);
    if missing > 0 {
        problems.push(format!(
            "{missing} artifact(s) named in an argv would not be present: not the group's own \
             output and not a declared dependency's"
        ));
    }

    // THE ORDER PROPERTY. Every consumed artifact is written before it is read, so every edge
    // points backwards in the action list.
    let mut violations = 0;
    for grp in &g.order {
        for (a, ai) in g.map[grp].iter().zip(g.idx[grp].iter()) {
            for i in strs(a, "inputs") {
                if let Some(p) = producer.get(i.as_str()) {
                    if p > ai {
                        violations += 1;
                    }
                }
            }
        }
    }
    if violations > 0 {
        problems.push(format!(
            "{violations} input(s) are read before they are written, so the action order is not \
             topological and the edge set cannot be trusted"
        ));
    }
    problems
}

/// The lowering has to sanitise a group name the same way this does. Compares the CHARACTER SET
/// the two spell out rather than a sample of names: a sample can agree on every real label and
/// still differ on the one that shows up next.
fn check_name_mapping(lowering: &str) -> Vec<String> {
    let text = match fs::read_to_string(lowering) {
        Ok(t) => t,
        Err(e) => return vec![format!("cannot read {lowering}: {}", oserror(&e, lowering))],
    };
    // specSafeChars\s*=\s*(?:\n\s*)?lib\.stringToCharacters\s*\n?\s*"([^"]*)"
    let mut chars: Option<String> = None;
    let mut from = 0;
    while let Some(at) = text[from..].find("specSafeChars") {
        let mut i = from + at + "specSafeChars".len();
        let b = text.as_bytes();
        // ASCII whitespace only: casting a UTF-8 continuation byte to char can land on NBSP,
        // which char::is_whitespace accepts and the file does not contain.
        let skip_ws = |b: &[u8], mut i: usize| {
            while i < b.len() && b[i].is_ascii_whitespace() {
                i += 1;
            }
            i
        };
        i = skip_ws(b, i);
        if i < b.len() && b[i] == b'=' {
            i = skip_ws(b, i + 1);
            if text[i..].starts_with("lib.stringToCharacters") {
                i = skip_ws(b, i + "lib.stringToCharacters".len());
                if i < b.len() && b[i] == b'"' {
                    if let Some(end) = text[i + 1..].find('"') {
                        chars = Some(text[i + 1..i + 1 + end].to_string());
                        break;
                    }
                }
            }
        }
        from = from + at + 1;
    }
    let nix_chars: BTreeSet<char> = match chars {
        Some(c) => c.chars().collect(),
        None => {
            return vec![
                "ciderBuck2Lower.nix has no specSafeChars: the lowering no longer states the \
                 mapping this checks, so the two cannot be compared"
                    .to_string(),
            ]
        }
    };
    let mut problems = Vec::new();
    let py_chars: BTreeSet<char> = (32u8..127)
        .map(|c| c as char)
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '.' || *c == '-')
        .collect();
    if nix_chars != py_chars {
        let only_nix: Vec<String> =
            nix_chars.difference(&py_chars).map(|c| c.to_string()).collect();
        let only_py: Vec<String> = py_chars.difference(&nix_chars).map(|c| c.to_string()).collect();
        problems.push(format!(
            "safe-character sets differ: only in nix {}, only in python {}",
            py_list(&only_nix),
            py_list(&only_py)
        ));
    }
    if !text.contains("CIDER_PH_") {
        problems.push(
            "ciderBuck2Lower.nix never mentions CIDER_PH_, so nothing exports the placeholders \
             the emitted scripts reference"
                .to_string(),
        );
    }
    problems
}

// ---------------------------------------------------------------- the check itself

fn check(
    actions: &[Value],
    coarse: &Map<String, Value>,
    g: &Grouped,
    specs: &mut Specs,
    lowering: &str,
) -> (Vec<String>, usize, usize) {
    let mut problems: Vec<String> = Vec::new();

    let names_path = format!("{}/names", specs.dir);
    let listed: HashSet<String> = match fs::read_to_string(&names_path) {
        Ok(t) => t.split('\n').filter(|l| !l.is_empty()).map(|s| s.to_string()).collect(),
        Err(e) => {
            return (
                vec![format!("cannot read {names_path}: {}", oserror(&e, &names_path))],
                0,
                0,
            )
        }
    };
    let ours: HashSet<String> = g.order.iter().map(|s| safe_name(s)).collect();
    if listed != ours {
        problems.push(format!(
            "the names index disagrees: {} listed with no group, {} groups not listed",
            listed.difference(&ours).count(),
            ours.difference(&listed).count()
        ));
    }

    let mut entries = 0;
    for grp in &g.order {
        let text = match specs.read_script(grp) {
            Ok(t) => t,
            Err(e) => {
                problems.push(format!("{grp}: {e}"));
                continue;
            }
        };
        let seq = match canon_script(&text) {
            Ok(s) => s,
            Err(e) => {
                problems.push(format!("{grp}: cannot tokenise the script: {e}"));
                continue;
            }
        };
        let want = expected_sequence(&g.map[grp]);
        entries += want.len();
        let got = strip_drains(&seq);
        if got.len() != want.len() || got.iter().zip(want.iter()).any(|(a, b)| *a != b) {
            let where_ = got.iter().zip(want.iter()).position(|(a, b)| *a != b);
            match where_ {
                None => problems
                    .push(format!("{grp}: {} entries, expected {}", got.len(), want.len())),
                Some(i) => problems.push(format!(
                    "{grp}: entry {i}\n      got  {}\n      want {}",
                    truncate_chars(&py_entry(got[i]), 180),
                    truncate_chars(&py_entry(&want[i]), 180)
                )),
            }
        }
        if actual_drains(&seq) != expected_drains(&g.map[grp]) {
            problems.push(format!("{grp}: _drain placement differs from the sibling-read rule"));
        }
    }

    problems.extend(check_deps(actions, coarse, g, &specs.dir));
    problems.extend(check_name_mapping(lowering));
    (problems, g.order.len(), entries)
}

// ---------------------------------------------------------------- the controls

/// Mutate a real script and confirm each mutation is caught. A control that does not apply is
/// reported as such: a no-op mutation passing looks exactly like a caught one.
fn controls(
    actions: &[Value],
    coarse: &Map<String, Value>,
    g: &Grouped,
    specs: &mut Specs,
) -> Vec<String> {
    // A group that exercises BOTH sub-checks: more than a couple of actions, and at least one
    // that has to drain. Picking the first group alphabetically gave one with neither.
    let mut sorted: Vec<&String> = g.order.iter().collect();
    sorted.sort();
    let victim = sorted
        .iter()
        .find(|grp| {
            let acts = &g.map[**grp];
            acts.len() > 3 && expected_drains(acts).iter().any(|b| *b)
        })
        .map(|s| (*s).clone());
    let victim = match victim {
        Some(v) => v,
        None => return vec!["no group exercises both sub-checks, so the controls cannot be run".to_string()],
    };

    let path = format!("{}/scripts.json", specs.dir);
    let mut blob: Map<String, Value> = match fs::read_to_string(&path)
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
    {
        Some(Value::Object(m)) => m,
        _ => return vec![format!("  [BAD] cannot read {path}")],
    };
    let key = safe_name(&victim);
    let original = blob.get(&key).and_then(|v| v.as_str()).unwrap_or("").to_string();

    let muts: &[(&str, &str, &str)] = &[
        ("drop an argument", " -c ", " "),
        ("corrupt a path", "buck-out", "buck-0ut"),
        ("blank an echo", "echo \"  ", "echo \"  X"),
        ("delete a _drain", "_drain\n", ""),
    ];
    let mut out: Vec<String> = Vec::new();

    // THE deps.json CONTROLS, separate because they mutate a different file and are caught by a
    // different sub-check. Without these, check_deps is a sub-check nobody has shown can fail.
    let dpath = format!("{}/deps.json", specs.dir);
    match fs::read_to_string(&dpath) {
        Err(e) => out.push(format!("  [BAD] deps controls could not run: {}", oserror(&e, &dpath))),
        Ok(dorig) => {
            let dblob: Map<String, Value> = match serde_json::from_str::<Value>(&dorig) {
                Ok(Value::Object(m)) => m,
                _ => Map::new(),
            };
            let mut names: Vec<&String> = dblob.keys().collect();
            names.sort();
            let victim_dep = names
                .iter()
                .find(|k| {
                    dblob.get(**k).and_then(|v| v.as_array()).map(|a| !a.is_empty()).unwrap_or(false)
                })
                .map(|s| (*s).clone());
            for label in ["drop an edge", "invent an edge", "delete deps.json"] {
                let vd = match &victim_dep {
                    Some(v) => v.clone(),
                    None => {
                        out.push(format!("  [BAD] {label}: no group has dependencies, cannot test"));
                        continue;
                    }
                };
                if label == "delete deps.json" {
                    let _ = fs::remove_file(&dpath);
                } else {
                    let mut b = dblob.clone();
                    let cur = b.get(&vd).and_then(|v| v.as_array()).cloned().unwrap_or_default();
                    let newv: Vec<Value> = if label == "drop an edge" {
                        cur[1..].to_vec()
                    } else {
                        let mut v = cur.clone();
                        v.push(Value::String("not_a_group".to_string()));
                        v
                    };
                    b.insert(vd.clone(), Value::Array(newv));
                    let _ = fs::write(&dpath, serde_json::to_string(&Value::Object(b)).unwrap());
                }
                let caught = !check_deps(actions, coarse, g, &specs.dir).is_empty();
                out.push(format!(
                    "  [{}] {label}: caught={}",
                    if caught { "ok " } else { "BAD" },
                    if caught { "True" } else { "False" }
                ));
                let _ = fs::write(&dpath, &dorig);
            }
        }
    }

    // THE SUFFICIENCY CONTROL, separate because it does not go through deps.json at all: it works
    // on the label-keyed edge set, so it has to be exercised directly.
    let mut outs_of: HashMap<&str, HashSet<String>> = HashMap::new();
    for grp in &g.order {
        let mut s = HashSet::new();
        for a in &g.map[grp] {
            s.extend(strs(a, "outputs"));
        }
        outs_of.insert(grp.as_str(), s);
    }
    let mut prod: HashMap<String, String> = HashMap::new();
    for (grp, os_) in &outs_of {
        for o in os_ {
            prod.insert(o.clone(), grp.to_string());
        }
    }
    let mut full: HashMap<String, HashSet<String>> = HashMap::new();
    for grp in &g.order {
        let mut s = HashSet::new();
        for a in &g.map[grp] {
            for i in strs(a, "inputs") {
                if let Some(p) = prod.get(&i) {
                    if p != grp {
                        s.insert(p.clone());
                    }
                }
            }
        }
        full.insert(grp.clone(), s);
    }
    let base = uncovered_artifacts(g, &full);
    let empty: HashMap<String, HashSet<String>> =
        g.order.iter().map(|grp| (grp.clone(), HashSet::new())).collect();
    let none_ = uncovered_artifacts(g, &empty);
    out.push(format!(
        "  [{}] argv coverage: real={base} (want 0), all edges dropped={none_} (want > 0)",
        if base == 0 && none_ > 0 { "ok " } else { "BAD" }
    ));

    for (label, find, repl) in muts {
        let applied = original.contains(find);
        let mutated = match original.find(find) {
            Some(i) => format!("{}{}{}", &original[..i], repl, &original[i + find.len()..]),
            None => original.clone(),
        };
        blob.insert(key.clone(), Value::String(mutated));
        let _ =
            fs::write(&path, serde_json::to_string(&Value::Object(blob.clone())).unwrap());
        specs.forget();
        let (by_seq, by_drain) = match specs.read_script(&victim).and_then(|t| canon_script(&t)) {
            Ok(seq) => {
                let want = expected_sequence(&g.map[&victim]);
                let got = strip_drains(&seq);
                let s = got.len() != want.len() || got.iter().zip(want.iter()).any(|(a, b)| *a != b);
                (s, actual_drains(&seq) != expected_drains(&g.map[&victim]))
            }
            // The python lets a tokeniser failure escape here; a mutation that produced one would
            // be a harness bug either way, and it is reported rather than swallowed.
            Err(e) => {
                out.push(format!("  [BAD] {label}: the mutated script does not tokenise: {e}"));
                continue;
            }
        };
        let ok = applied && (by_seq || by_drain);
        out.push(format!(
            "  [{}] {label}: applied={} caught_by_sequence={} caught_by_drain={}",
            if ok { "ok " } else { "BAD" },
            if applied { "True" } else { "False" },
            if by_seq { "True" } else { "False" },
            if by_drain { "True" } else { "False" }
        ));
    }
    blob.insert(key.clone(), Value::String(original));
    let _ = fs::write(&path, serde_json::to_string(&Value::Object(blob)).unwrap());
    specs.forget();
    out
}

// ---------------------------------------------------------------- the port gate

/// One line per group: its name and the sha256 of its CANONICAL form. This check compares WORDS
/// rather than text, so its verdict rests entirely on the tokeniser, and a reimplementation that
/// is subtly different would agree on the summary while comparing something else.
fn dump_canon(g: &Grouped, specs: &mut Specs) -> ExitCode {
    let mut sorted: Vec<&String> = g.order.iter().collect();
    sorted.sort();
    for group in sorted {
        let text = match specs.read_script(group) {
            Ok(t) => t,
            Err(_) => {
                println!("{}\tNOSCRIPT", safe_name(group));
                continue;
            }
        };
        let seq = match canon_script(&text) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("{e}");
                return ExitCode::FAILURE;
            }
        };
        let mut blob = String::new();
        for e in &seq {
            blob.push_str(e.0);
            blob.push('\t');
            blob.push_str(&e.1.join("\u{1f}"));
            blob.push('\n');
        }
        let d = sha256(blob.as_bytes());
        let hex: String = d.iter().map(|b| format!("{b:02x}")).collect();
        println!("{}\t{hex}", safe_name(group));
    }
    ExitCode::SUCCESS
}

// ---------------------------------------------------------------- main

const USAGE: &str = "\
cider-specs-check: check the rendered per-group action scripts against the graph they came from.

  cider-specs-check <graph.json> <specsdir>              # check
  cider-specs-check <graph.json> <specsdir> --controls   # and prove it can fail
  cider-specs-check <graph.json> <specsdir> --dump-canon # the tokeniser gate
";

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();

    // THE FOURTH SPEC-NAME IMPLEMENTATION, ASKED DIRECTLY. buck-names-check.nu compares every
    // spelling of the group-name mapping on the real labels, and it used to reach this one by
    // IMPORTING the python module. A binary cannot be imported, so the question it asked is a
    // mode: a JSON list of labels in, the same list through safe_name out. It is the only thing
    // here that the python did not have, and it exists so that comparison keeps running rather
    // than quietly dropping to three implementations.
    if argv.len() >= 2 && argv[0] == "--safe-names" {
        let text = match fs::read_to_string(&argv[1]) {
            Ok(t) => t,
            Err(e) => {
                eprintln!("cannot read {}: {}", argv[1], oserror(&e, &argv[1]));
                return ExitCode::FAILURE;
            }
        };
        let labels: Vec<String> = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("{} is not a JSON list of strings: {e}", argv[1]);
                return ExitCode::FAILURE;
            }
        };
        let names: Vec<String> = labels.iter().map(|l| safe_name(l)).collect();
        println!("{}", serde_json::to_string(&names).unwrap());
        return ExitCode::SUCCESS;
    }

    if argv.len() < 2 {
        // sys.exit(__doc__) in the python, which prints to stderr and exits 1. The text is this
        // tool's own header either way, so it is the one thing here that is not byte comparable.
        eprintln!("{USAGE}");
        return ExitCode::FAILURE;
    }
    let graph_path = &argv[0];
    let specdir = &argv[1];
    let rest = &argv[2..];

    let root = match std::env::var("CIDER_REPO") {
        Ok(v) if !v.is_empty() => v,
        _ => std::env::current_dir()
            .map(|d| d.to_string_lossy().into_owned())
            .unwrap_or_else(|_| ".".to_string()),
    };
    let lowering = format!("{}/nix/lib/ciderBuck2Lower.nix", root.trim_end_matches('/'));

    let text = match fs::read_to_string(graph_path) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("cannot read {graph_path}: {}", oserror(&e, graph_path));
            return ExitCode::FAILURE;
        }
    };
    let graph: Value = match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("cannot parse {graph_path}: {e}");
            return ExitCode::FAILURE;
        }
    };
    drop(text);
    let empty_map = Map::new();
    let coarse = graph.get("coarsePinOf").and_then(|v| v.as_object()).unwrap_or(&empty_map);
    let empty_actions: Vec<Value> = Vec::new();
    let actions = graph.get("actions").and_then(|v| v.as_array()).unwrap_or(&empty_actions);
    let g = match group_actions(actions, coarse) {
        Ok(g) => g,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let mut specs = Specs::new(specdir);

    if rest.iter().any(|a| a == "--dump-canon") {
        return dump_canon(&g, &mut specs);
    }

    if rest.iter().any(|a| a == "--controls") {
        // WRITES TO THE SPEC DIR, so it refuses to touch a store path. The specs normally live in
        // /nix/store, which is read-only; failing there with a permission error would be
        // confusing, and succeeding would be worse.
        let real = fs::canonicalize(specdir)
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| specdir.clone());
        if real.starts_with("/nix/store/") {
            println!("controls need a WRITABLE spec dir; copy it out of the store first");
            return ExitCode::from(2);
        }
        println!("negative controls:");
        let mut bad = 0;
        for line in controls(actions, coarse, &g, &mut specs) {
            println!("{line}");
            if line.contains("[BAD]") || line.starts_with("no group") {
                bad += 1;
            }
        }
        if bad > 0 {
            println!("FAIL: {bad} control(s) did not fire, so this check proves nothing");
            return ExitCode::FAILURE;
        }
    }

    let (problems, ngroups, entries) = check(actions, coarse, &g, &mut specs, &lowering);
    println!("groups: {ngroups}   entries checked: {entries}   problems: {}", problems.len());
    for p in problems.iter().take(20) {
        println!("    {p}");
    }
    if problems.len() > 20 {
        println!("    ... and {} more", problems.len() - 20);
    }
    if problems.is_empty() {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
