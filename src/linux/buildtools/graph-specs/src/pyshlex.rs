//! shlex.split, POSIX, ported state by state from shlex.read_token.
//!
//! SPLIT OUT of cider-specs-check, which compares shell WORDS and stands or falls on this. It
//! had a second user, mig-from-ninja (deleted), until that tool went with the frozen generators it
//! belonged to; the split stays because the tokeniser is the part of the check that is worth
//! being able to point at on its own.
//!
//! ADJACENCY AND THE ESCAPE RULE ARE THE POINT. a"b"c is ONE word, and a backslash inside double
//! quotes is LITERAL unless it escapes a quote or a backslash. Both are where a rewrite goes
//! silently wrong, which is why this is a port of the state machine rather than a regex.

#![allow(dead_code)]

/// shlex.split(s), posix, whitespace_split, commenters disabled, which is what shlex.split does.
/// Ported state by state from shlex.read_token rather than approximated: adjacency and the rule
/// that a backslash inside double quotes is LITERAL unless it escapes a quote or a backslash are
/// exactly where a rewrite goes wrong.
pub fn shlex_split(s: &str) -> Result<Vec<String>, String> {
    #[derive(Clone, Copy, PartialEq)]
    enum St {
        Space,
        Word,
        Quote(char),
        Escape(char), // the state to return to: ' ' for space, 'a' for word, or a quote char
    }
    let ws = |c: char| c == ' ' || c == '\t' || c == '\r' || c == '\n';
    let mut out: Vec<String> = Vec::new();
    let mut token = String::new();
    let mut quoted = false;
    let mut st = St::Space;
    for c in s.chars() {
        match st {
            St::Space => {
                if ws(c) {
                    continue;
                } else if c == '\\' {
                    st = St::Escape('a');
                } else if c == '\'' || c == '"' {
                    st = St::Quote(c);
                } else {
                    token.push(c);
                    st = St::Word;
                }
            }
            St::Quote(q) => {
                quoted = true;
                if c == q {
                    st = St::Word;
                } else if c == '\\' && q == '"' {
                    st = St::Escape(q);
                } else {
                    token.push(c);
                }
            }
            St::Escape(back) => {
                // In posix shells only the quote itself or the escape char may be escaped inside
                // quotes, so any other backslash inside a double quoted string stays.
                if (back == '"' || back == '\'') && c != '\\' && c != back {
                    token.push('\\');
                }
                token.push(c);
                st = if back == '"' || back == '\'' { St::Quote(back) } else { St::Word };
            }
            St::Word => {
                if ws(c) {
                    if !token.is_empty() || quoted {
                        out.push(std::mem::take(&mut token));
                        quoted = false;
                    }
                    st = St::Space;
                } else if c == '\'' || c == '"' {
                    st = St::Quote(c);
                } else if c == '\\' {
                    st = St::Escape('a');
                } else {
                    token.push(c);
                }
            }
        }
    }
    match st {
        St::Quote(_) => return Err("No closing quotation".to_string()),
        St::Escape(_) => return Err("No escaped character".to_string()),
        _ => {}
    }
    if !token.is_empty() || quoted {
        out.push(token);
    }
    Ok(out)
}
