// The system colour table, which is display-agnostic and reimplemented here by the user's
// decision rather than patched into the cocotron pin.
//
// AppKit asks the display for named system colours (controlColor, textColor and so on) and the
// X11 backend answers with a plain table of NSColor class methods. There is nothing about X in
// it; it is a palette. The same table is reproduced here so the two backends look identical to
// anything above them, which matters because a missing colour is not a crash but a wrong looking
// application, and that is far harder to notice.
//
// UNKNOWN NAMES RETURN nil ON PURPOSE, exactly as the X11 one does. AppKit treats nil as "no
// system colour by that name" and falls back, so inventing a colour here would hide a name we do
// not know about instead of letting AppKit deal with it.
use std::ffi::CStr;
use std::os::raw::c_char;

use crate::cstr;
use crate::objc;

/// How a named colour is produced: either a class method with no arguments, or a grey level.
enum Recipe {
    /// [NSColor <sel>]
    ClassMethod(&'static str),
    /// [NSColor colorWithCalibratedWhite:<v> alpha:1.0]
    Grey(f64),
    /// [NSColor colorWithCalibratedRed:g:b:alpha:1.0], for the colours Cocoa has no constructor
    /// for. THE ACCENT IS ONE OF THEM: blueColor is 0,0,1, a saturated primary that Apple has not
    /// used for a selection since Aqua, and every selected menu item, every default button and
    /// every highlighted row was drawn in it.
    Rgb(f64, f64, f64),
}

/// The macOS accent blue, which is what a selection is filled with.
const ACCENT: Recipe = Recipe::Rgb(0.0, 0.478, 1.0);

/// The table, in the order the X11 backend tests the names. Order does not matter to correctness
/// here because the lookup is exact, but keeping it makes the two readable side by side.
fn recipe_for(name: &str) -> Option<Recipe> {
    Some(match name {
        "controlColor" => Recipe::Grey(0.93),
        // NAMES THE X11 TABLE DOES NOT HAVE, added because the application asks for them and a nil
        // answer is not neutral: AppKit hands the caller no colour at all and whatever it was going
        // to paint gets whatever was already there.
        "windowBackgroundColor" => Recipe::Grey(0.93),
        "selectedTextBackgroundColor" => Recipe::ClassMethod("lightGrayColor"),
        "disabledControlTextColor" => Recipe::ClassMethod("grayColor"),
        "controlTextColor" => Recipe::ClassMethod("blackColor"),
        "menuBackgroundColor" => Recipe::Grey(0.96),
        "mainMenuBarColor" => Recipe::Grey(0.96),
        "controlShadowColor" => Recipe::ClassMethod("darkGrayColor"),
        "selectedControlColor" => ACCENT,
        "controlBackgroundColor" => Recipe::ClassMethod("whiteColor"),
        "controlLightHighlightColor" => Recipe::ClassMethod("lightGrayColor"),
        "headerColor" => Recipe::ClassMethod("greenColor"),
        "textBackgroundColor" => Recipe::ClassMethod("whiteColor"),
        "textColor" => Recipe::ClassMethod("blackColor"),
        "selectedTextColor" => Recipe::ClassMethod("whiteColor"),
        "headerTextColor" => Recipe::ClassMethod("blackColor"),
        "menuItemTextColor" => Recipe::ClassMethod("blackColor"),
        "selectedMenuItemTextColor" => Recipe::ClassMethod("whiteColor"),
        "selectedMenuItemColor" => ACCENT,
        "selectedControlTextColor" => Recipe::ClassMethod("blackColor"),
        "windowFrameColor" => Recipe::ClassMethod("lightGrayColor"),
        "shadowColor" => Recipe::ClassMethod("blackColor"),
        "alternateSelectedControlTextColor" => Recipe::ClassMethod("whiteColor"),
        "labelColor" => Recipe::ClassMethod("blackColor"),
        "linkColor" => Recipe::ClassMethod("blueColor"),
        "unemphasizedSelectedTextColor" => Recipe::ClassMethod("blackColor"),
        "selectedContentBackgroundColor" => ACCENT,
        "unemphasizedSelectedContentBackgroundColor" => Recipe::ClassMethod("lightGrayColor"),
        // The modern semantic names, added with the AppKit class methods that ask for them.
        // Greys rather than named class methods where Cocoa has no equivalent constructor: the
        // point of these is a LEGIBLE HIERARCHY, primary text darker than secondary and so on,
        // and grey levels express that directly.
        "underPageBackgroundColor" => Recipe::Grey(0.85),
        "controlAccentColor" => ACCENT,
        "separatorColor" => Recipe::Grey(0.87),
        "secondaryLabelColor" => Recipe::Grey(0.4),
        "tertiaryLabelColor" => Recipe::Grey(0.55),
        "quaternaryLabelColor" => Recipe::Grey(0.7),
        "placeholderTextColor" => Recipe::Grey(0.6),
        "systemGrayColor" => Recipe::Grey(0.5),
        _ => return None,
    })
}

/// A DELIBERATELY LOUD PALETTE, used only when CIDER_WAYLAND_COLOR_PROBE is set.
///
/// It exists to answer a question that reading code cannot: WHICH system colour is a given region
/// of the screen actually painted with. LibreOffice draws its chrome in values that match nothing
/// in the table below, and the two candidate explanations (the application never asks us, or it
/// asks and something later corrupts the answer) predict different things when the answers are
/// changed. Giving each name a unique unmistakable colour and looking at the result distinguishes
/// them in one run: regions that change are ours, regions that do not never came from here.
fn probe_recipe(name: &str) -> Option<(f64, f64, f64)> {
    // EVERY NAME, not eight of them. The first version of this palette covered the names that were
    // suspected, which can only ever confirm a suspicion: a region painted from a name that is not
    // in the list looks exactly like a region painted from nowhere. The colours are generated from
    // the name so that adding a name to the table cannot forget to add one here.
    let mut hash: u64 = 1469598103934665603;
    for byte in name.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(1099511628211);
    }
    // Bright and separated: the darkest channel is lifted so that no two names collide visually
    // with a plausible real colour like black or white.
    let r = 0.15 + 0.85 * (((hash >> 16) & 0xff) as f64 / 255.0);
    let g = 0.15 + 0.85 * (((hash >> 32) & 0xff) as f64 / 255.0);
    let b = 0.15 + 0.85 * (((hash >> 48) & 0xff) as f64 / 255.0);
    Some((r, g, b))
}

/// Answer -colorWithName:.
///
/// The name arrives as an NSString, so it is read back through -UTF8String rather than compared
/// with -isEqual:, which would mean building a temporary NSString per candidate.
pub fn color_with_name(name: objc::Object) -> objc::Object {
    if name.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        let color_cls = objc::objc_getClass(cstr!("NSColor"));
        if color_cls.is_null() {
            return std::ptr::null_mut();
        }
        let sel_utf8 = objc::sel_registerName(cstr!("UTF8String"));
        let raw = objc::msg_send0(name, sel_utf8) as *const c_char;
        if raw.is_null() {
            return std::ptr::null_mut();
        }
        let Ok(text) = CStr::from_ptr(raw).to_str() else {
            return std::ptr::null_mut();
        };
        if std::env::var_os("CIDER_WAYLAND_COLOR_PROBE").is_some() {
            if let Some((r, g, b)) = probe_recipe(text) {
                let sel = objc::sel_registerName(cstr!("colorWithDeviceRed:green:blue:alpha:"));
                let c = objc::msg_send_f64_4(color_cls, sel, r, g, b, 1.0);
                println!("cider-wayland-color name={text} probe={r},{g},{b}");
                return c;
            }
        }
        match recipe_for(text) {
            None => {
                // A NAME THAT ANSWERS nil IS INVISIBLE FROM ABOVE. AppKit does not complain; it
                // draws with no colour, and the result is a control that renders as nothing at
                // all. That is not distinguishable from a layout bug by looking, so the names are
                // printed instead of guessed at.
                if std::env::var_os("CIDER_WAYLAND_TRACE_COLORS").is_some() {
                    println!("cider-wayland-color name={text} result=nil");
                }
                std::ptr::null_mut()
            }
            Some(Recipe::ClassMethod(sel_name)) => {
                // sel_registerName needs a NUL terminated string and these are Rust literals, so
                // one small allocation per lookup. AppKit caches system colours, so this is not a
                // hot path.
                let Ok(c) = std::ffi::CString::new(sel_name) else {
                    return std::ptr::null_mut();
                };
                let sel = objc::sel_registerName(c.as_ptr());
                objc::msg_send0(color_cls, sel)
            }
            Some(Recipe::Grey(level)) => {
                let sel = objc::sel_registerName(cstr!("colorWithCalibratedWhite:alpha:"));
                objc::msg_send_f64_2(color_cls, sel, level, 1.0)
            }
            Some(Recipe::Rgb(r, g, b)) => {
                let sel = objc::sel_registerName(cstr!(
                    "colorWithCalibratedRed:green:blue:alpha:"
                ));
                objc::msg_send_f64_4(color_cls, sel, r, g, b, 1.0)
            }
        }
    }
}
