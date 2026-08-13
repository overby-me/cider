//! The four LEXICAL path operations python's os.path has and Rust's std does not.
//!
//! A SECOND COPY. src/linux/buildtools/src-normalise/src/pypath.rs is the same module for the same
//! reason, and the two crates are independent (no workspace), so this is a copy rather than a
//! shared dependency. Both carry the same unit test, whose expectations were read out of
//! python3, so a divergence fails a build rather than producing a quietly different path. If
//! these crates ever become a cargo workspace, this is the first thing to merge.
//!
//! LEXICAL IS THE POINT, not an implementation shortcut. The normaliser walks symlink chains
//! ITSELF, one readlink at a time, because it has to reason about links that do not resolve:
//! a dangling target, a target that leaves the cell, a target naming a tree that was renamed.
//! std::fs::canonicalize answers none of those questions, it fails on them. So every path
//! decision here is made on the STRING, exactly as the python this replaces made it, and the
//! filesystem is consulted only through explicit lexists/exists calls.
//!
//! Strings rather than Path/PathBuf for the same reason. Path::parent is not os.path.dirname
//! (they disagree on a trailing slash), and PathBuf::push of an absolute path replacing the
//! whole buffer is a behaviour worth writing out rather than inheriting silently.

/// os.path.dirname.
///
///   "a/b" -> "a", "a" -> "", "/a" -> "/", "a/" -> "a"
pub fn dirname(p: &str) -> &str {
    match p.rfind('/') {
        None => "",
        Some(i) => {
            let head = &p[..i + 1];
            // A head that is ALL slashes keeps them: dirname("/a") is "/", not "".
            if head.chars().any(|c| c != '/') {
                head.trim_end_matches('/')
            } else {
                head
            }
        }
    }
}

/// os.path.join, two arguments. An absolute second argument REPLACES the first.
pub fn join2(a: &str, b: &str) -> String {
    if b.starts_with('/') {
        b.to_string()
    } else if a.is_empty() || a.ends_with('/') {
        format!("{a}{b}")
    } else {
        format!("{a}/{b}")
    }
}

/// os.path.normpath: collapse "//" and ".", resolve ".." TEXTUALLY.
///
/// Textually means it does not care what is on disk, so it is wrong across a symlink and right
/// for everything this tool does with it. A leading ".." is kept on a relative path, because
/// there is nothing above the start to fold it into.
pub fn normpath(p: &str) -> String {
    if p.is_empty() {
        return ".".to_string();
    }
    // POSIX keeps EXACTLY two leading slashes and collapses any other run to one. Nothing in
    // this tree uses that form, but the rule is cheap and its absence would be a silent
    // difference rather than an error.
    let lead = p.len() - p.trim_start_matches('/').len();
    let prefix = if lead == 2 { "//" } else if lead > 0 { "/" } else { "" };
    let absolute = lead > 0;

    let mut out: Vec<&str> = Vec::new();
    for comp in p.split('/') {
        if comp.is_empty() || comp == "." {
            continue;
        }
        if comp != ".."
            || (!absolute && out.is_empty())
            || out.last().map(|c| *c == "..").unwrap_or(false)
        {
            out.push(comp);
        } else if !out.is_empty() {
            out.pop();
        }
    }
    let joined = format!("{prefix}{}", out.join("/"));
    if joined.is_empty() {
        ".".to_string()
    } else {
        joined
    }
}

/// The process cwd, read ONCE, which is what python's os.path.abspath consults on every call.
/// Nothing here chdirs, so one read is the same answer.
pub fn cwd() -> &'static str {
    static CWD: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    CWD.get_or_init(|| {
        std::env::current_dir()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| "/".to_string())
    })
}

/// os.path.abspath.
pub fn abspath_in(p: &str, cwd: &str) -> String {
    if p.starts_with('/') {
        normpath(p)
    } else {
        normpath(&join2(cwd, p))
    }
}

/// os.path.relpath. Both sides are made absolute first, then the common prefix is dropped and
/// one ".." emitted per remaining component of `start`.
pub fn relpath(path: &str, start: &str) -> String {
    let path_abs = abspath_in(path, cwd());
    let start_abs = abspath_in(start, cwd());
    let path_list: Vec<&str> = path_abs.split('/').filter(|c| !c.is_empty()).collect();
    let start_list: Vec<&str> = start_abs.split('/').filter(|c| !c.is_empty()).collect();

    let mut i = 0;
    while i < path_list.len() && i < start_list.len() && path_list[i] == start_list[i] {
        i += 1;
    }
    let mut rel: Vec<&str> = vec![".."; start_list.len() - i];
    rel.extend_from_slice(&path_list[i..]);
    if rel.is_empty() {
        ".".to_string()
    } else {
        rel.join("/")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_python() {
        // Every expectation here was read out of python3 -c "import os.path; print(...)".
        assert_eq!(dirname("a/b"), "a");
        assert_eq!(dirname("a"), "");
        assert_eq!(dirname("/a"), "/");
        assert_eq!(dirname("a/"), "a");
        assert_eq!(join2("a", "b"), "a/b");
        assert_eq!(join2("", "b"), "b");
        assert_eq!(join2("a/", "b"), "a/b");
        assert_eq!(join2("a", "/b"), "/b");
        assert_eq!(normpath("a/./b"), "a/b");
        assert_eq!(normpath("a/b/../c"), "a/c");
        assert_eq!(normpath("../../a"), "../../a");
        assert_eq!(normpath("/a/../../b"), "/b");
        assert_eq!(normpath("//a/b"), "//a/b");
        assert_eq!(normpath("///a/b"), "/a/b");
        assert_eq!(normpath(""), ".");
        assert_eq!(relpath("/a/b/c", "/a/x"), "../b/c");
        assert_eq!(relpath("/a/b", "/a/b"), ".");
        // Relative on both sides: the cwd cancels, whatever it is.
        assert_eq!(relpath("b/c", "b"), "c");
    }
}
