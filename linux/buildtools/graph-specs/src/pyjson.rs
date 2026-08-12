//! A JSON writer byte-compatible with python's `json.dump(obj, f)` DEFAULTS.
//!
//! WHY THIS EXISTS RATHER THAN serde_json::to_writer. The output of this generator is consumed
//! through a CONTENT ADDRESSED derivation, so its bytes are its identity: a serialiser that
//! differs by one space produces a correct-looking tree with a different hash, every lowered
//! derivation moves, and the whole argument for landing this port without an hour-class gate is
//! gone. serde_json's compact form omits the spaces python emits.
//!
//! THE FOUR DEFAULTS THAT MATTER, all of them python's and none of them serde_json's:
//!
//!   separators are ", " and ": ", NOT "," and ":". This is the big one.
//!   ensure_ascii is TRUE, so every non-ASCII character becomes \uXXXX, and anything outside
//!     the basic multilingual plane becomes a SURROGATE PAIR.
//!   the short escapes are \b \f \n \r \t \" \\ and every other control character is \u00XX.
//!   the forward slash is NOT escaped, which some writers do.
//!
//! Object key order is the insertion order serde_json's preserve_order feature keeps, which is
//! python dict order. Nothing here sorts.

use serde_json::Value;

pub fn dumps(v: &Value) -> String {
    let mut s = String::new();
    write_value(v, &mut s);
    s
}

fn write_value(v: &Value, out: &mut String) {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => out.push_str(&n.to_string()),
        Value::String(s) => write_string(s, out),
        Value::Array(a) => {
            out.push('[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.push_str(", ");
                }
                write_value(x, out);
            }
            out.push(']');
        }
        Value::Object(m) => {
            out.push('{');
            for (i, (k, x)) in m.iter().enumerate() {
                if i > 0 {
                    out.push_str(", ");
                }
                write_string(k, out);
                out.push_str(": ");
                write_value(x, out);
            }
            out.push('}');
        }
    }
}

fn write_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c if (c as u32) < 0x7f => out.push(c),
            c => {
                // ensure_ascii: everything from DEL upwards is escaped, and anything above the
                // BMP becomes a surrogate pair, which is what python emits and what a naive
                // {:04x} of the scalar value would get wrong.
                let n = c as u32;
                if n > 0xFFFF {
                    let n = n - 0x10000;
                    let hi = 0xD800 + (n >> 10);
                    let lo = 0xDC00 + (n & 0x3FF);
                    out.push_str(&format!("\\u{hi:04x}\\u{lo:04x}"));
                } else {
                    out.push_str(&format!("\\u{n:04x}"));
                }
            }
        }
    }
    out.push('"');
}
