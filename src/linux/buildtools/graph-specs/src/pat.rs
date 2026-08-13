//! The six patterns the dump matches, by hand rather than through a regex crate.
//!
//! WHY NOT THE regex CRATE. This crate is std plus serde_json, and every dependency it takes
//! has to be vendored into the graph derivation, which sits at the front of every build. Six
//! fixed patterns over character classes is less code than the vendoring would be, and each one
//! is checked against python's re in the tests below on real strings out of the graph.
//!
//! THE ONE SUBTLETY IS GREED. `\(target: `(.+)`, id: ...` uses a greedy `.+`, so python matches
//! the LAST viable split, not the first. A target label can itself contain a backtick sequence,
//! so scanning left to right would capture too little. `node_target_id` searches from the right
//! for exactly that reason.

/// re.findall(r"buck-out/[A-Za-z0-9_.-]+/[^\s\"']*")
pub fn buck_out_paths(s: &str) -> Vec<String> {
    const NEEDLE: &str = "buck-out/";
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while let Some(rel) = s[i..].find(NEEDLE) {
        let start = i + rel;
        let mut j = start + NEEDLE.len();
        let seg = j;
        while j < b.len() && is_seg(b[j]) {
            j += 1;
        }
        // The class does not contain "/", so the run above is maximal and a slash has to
        // follow it. Nothing to backtrack: shortening the run only lands on another class
        // character.
        if j == seg || j >= b.len() || b[j] != b'/' {
            i = start + 1;
            continue;
        }
        j += 1;
        while j < b.len() && !matches!(b[j], b' ' | b'\t' | b'\n' | b'\r' | 0x0b | 0x0c | b'"' | b'\'') {
            j += 1;
        }
        out.push(s[start..j].to_string());
        i = j;
    }
    out
}

fn is_seg(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'.' || c == b'-'
}

/// re.sub(r"[^A-Za-z0-9_.-]+", "_", s). Runs collapse to ONE underscore.
pub fn sanitise(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_run = false;
    for c in s.chars() {
        if c.is_ascii_alphanumeric() || c == '_' || c == '.' || c == '-' {
            out.push(c);
            in_run = false;
        } else if !in_run {
            out.push('_');
            in_run = true;
        }
    }
    out
}

/// re.search(r"\((?:c|cxx|objc)_compile ([^/]+)/"), the first match's group 1.
pub fn compile_root(identity: &str) -> Option<String> {
    let b = identity.as_bytes();
    for (i, _) in identity.match_indices('(') {
        for kind in ["c_compile ", "cxx_compile ", "objc_compile "] {
            if identity[i + 1..].starts_with(kind) {
                let start = i + 1 + kind.len();
                let mut j = start;
                while j < b.len() && b[j] != b'/' {
                    j += 1;
                }
                if j > start && j < b.len() {
                    return Some(identity[start..j].to_string());
                }
            }
        }
    }
    None
}

/// re.match(r"\(target: `(.+)`, id: `?(\d+)`?\)"), returning group 1. GREEDY, so the rightmost
/// viable split wins.
pub fn node_target(node: &str) -> Option<String> {
    const HEAD: &str = "(target: `";
    const MID: &str = "`, id: ";
    if !node.starts_with(HEAD) || !node.ends_with(')') {
        return None;
    }
    let mut search_end = node.len();
    while let Some(pos) = node[..search_end].rfind(MID) {
        if pos >= HEAD.len() {
            let tail = &node[pos + MID.len()..node.len() - 1];
            if is_optionally_quoted_number(tail) {
                return Some(node[HEAD.len()..pos].to_string());
            }
        }
        if pos == 0 {
            break;
        }
        search_end = pos + MID.len() - 1;
    }
    None
}

fn is_optionally_quoted_number(s: &str) -> bool {
    let s = s.strip_prefix('`').unwrap_or(s);
    let s = s.strip_suffix('`').unwrap_or(s);
    !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit())
}

/// re.findall(r"action: \(target: `([^`]+)`, id: `?\d+`?\)"), group 1 of every match.
pub fn declared_input_targets(decl: &str) -> Vec<String> {
    const HEAD: &str = "action: (target: `";
    let mut out = Vec::new();
    let mut i = 0;
    while let Some(rel) = decl[i..].find(HEAD) {
        let start = i + rel + HEAD.len();
        let Some(close) = decl[start..].find('`') else { break };
        let label = &decl[start..start + close];
        let rest = &decl[start + close + 1..];
        // `[^`]+` is one or more, and the tail is fixed, so there is no greed to worry about.
        if !label.is_empty() {
            if let Some(after) = rest.strip_prefix(", id: ") {
                if let Some(end) = after.find(')') {
                    if is_optionally_quoted_number(&after[..end]) {
                        out.push(label.to_string());
                        i = start + close + 1 + ", id: ".len() + end + 1;
                        continue;
                    }
                }
            }
        }
        i = start;
    }
    out
}

/// re.findall(r"/nix/store/[a-z0-9]{32}-[^/\s\"',]+")
pub fn store_paths(s: &str) -> Vec<String> {
    const NEEDLE: &str = "/nix/store/";
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while let Some(rel) = s[i..].find(NEEDLE) {
        let start = i + rel;
        let hash = start + NEEDLE.len();
        // EXACTLY 32, so this cannot backtrack into a shorter hash: the 33rd byte has to be
        // the dash.
        if hash + 33 > b.len()
            || !b[hash..hash + 32].iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
            || b[hash + 32] != b'-'
        {
            i = start + 1;
            continue;
        }
        let mut j = hash + 33;
        while j < b.len()
            && !matches!(b[j], b'/' | b' ' | b'\t' | b'\n' | b'\r' | 0x0b | 0x0c | b'"' | b'\'' | b',')
        {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_python_re() {
        // Every expectation below was printed by python3 -c "import re; ..." on these inputs.
        assert_eq!(
            buck_out_paths("clang -c buck-out/v2/gen/root/abc/x.o -o buck-out/v2/gen/root/y.o"),
            vec!["buck-out/v2/gen/root/abc/x.o", "buck-out/v2/gen/root/y.o"]
        );
        // no slash after the first segment, and a quote ends the path
        assert_eq!(buck_out_paths("buck-out/v2"), Vec::<String>::new());
        assert_eq!(buck_out_paths("\"buck-out/v2/a b\""), vec!["buck-out/v2/a"]);

        assert_eq!(sanitise("root//pkg:name (cfg) (c_compile src/a.c)"), "root_pkg_name_cfg_c_compile_src_a.c_");
        assert_eq!(
            compile_root("root//vendor/src/python:x (cfg) (c_compile Python-2.7.16/foo.c)"),
            Some("Python-2.7.16".to_string())
        );
        assert_eq!(compile_root("root//x:y (cfg) (cxx_compile a/b.cpp)"), Some("a".to_string()));
        assert_eq!(compile_root("root//x:y (cfg) (link)"), None);

        assert_eq!(
            node_target("(target: `root//a:b (cfg#hash)`, id: `3`)"),
            Some("root//a:b (cfg#hash)".to_string())
        );
        assert_eq!(node_target("(target: `root//a:b`, id: 12)"), Some("root//a:b".to_string()));
        assert_eq!(node_target("(analysis: root//a:b)"), None);

        assert_eq!(
            declared_input_targets(
                "x action: (target: `root//a:b (c)`, id: `0`) y action: (target: `root//d:e`, id: 2)"
            ),
            vec!["root//a:b (c)".to_string(), "root//d:e".to_string()]
        );

        assert_eq!(
            store_paths("-B/nix/store/00000000000000000000000000000000-clang-21/bin,x"),
            vec!["/nix/store/00000000000000000000000000000000-clang-21"]
        );
        assert_eq!(store_paths("/nix/store/short-x"), Vec::<String>::new());
    }
}
