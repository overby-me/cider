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
    /// [NSColor colorWithCalibratedRed:g:b:alpha:a], for the colours whose ALPHA is the point.
    /// The five fill colours are defined as a tint of black at a few percent, so painting them
    /// opaque would not be a slightly wrong shade, it would be a black box.
    Rgba(f64, f64, f64, f64),
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
        // LIGHT BLUE, NOT GREY. This is the colour an application fills a selected row or a
        // selected run of text with, and LibreOffice asks for it by name for the tree in its
        // Options dialog: with lightGrayColor the selected category read as disabled.
        "selectedTextBackgroundColor" => Recipe::Rgb(0.70, 0.84, 1.0),
        "disabledControlTextColor" => Recipe::ClassMethod("grayColor"),
        "controlTextColor" => Recipe::ClassMethod("blackColor"),
        "menuBackgroundColor" => Recipe::Grey(0.96),
        "mainMenuBarColor" => Recipe::Grey(0.96),
        "controlShadowColor" => Recipe::ClassMethod("darkGrayColor"),
        "selectedControlColor" => ACCENT,
        "controlBackgroundColor" => Recipe::ClassMethod("whiteColor"),
        "controlLightHighlightColor" => Recipe::ClassMethod("lightGrayColor"),
        // NOT GREEN. Cocotron's X11 table answers greenColor here, which is a placeholder nobody
        // ever saw because an archived headerColor used to keep its stored value instead of asking
        // this table. Fifty of them across the three applications in the queue would have turned
        // every table header green the moment that lookup started working.
        "headerColor" => Recipe::Grey(0.96),
        "textBackgroundColor" => Recipe::ClassMethod("whiteColor"),
        "textColor" => Recipe::ClassMethod("blackColor"),
        // BLACK ON THE LIGHT BLUE ABOVE, not white. These two are a pair: selected text is drawn in
        // this colour on selectedTextBackgroundColor, and white on a pale blue is barely there. The
        // selected name in the save panel came out as a ghost of itself, which is exactly what the
        // reference screenshot from macOS does not show: there it is ordinary black text with a
        // blue band behind it.
        "selectedTextColor" => Recipe::ClassMethod("blackColor"),
        "headerTextColor" => Recipe::ClassMethod("blackColor"),
        "menuItemTextColor" => Recipe::ClassMethod("blackColor"),
        "selectedMenuItemTextColor" => Recipe::ClassMethod("whiteColor"),
        "selectedMenuItemColor" => ACCENT,
        "selectedControlTextColor" => Recipe::ClassMethod("blackColor"),
        "windowFrameColor" => Recipe::ClassMethod("lightGrayColor"),
        // The TEXT on the frame, black on the light frame above, which is what a light mode macOS
        // title bar looks like.
        "windowFrameTextColor" => Recipe::ClassMethod("blackColor"),
        "shadowColor" => Recipe::ClassMethod("blackColor"),
        "alternateSelectedControlTextColor" => Recipe::ClassMethod("whiteColor"),
        "labelColor" => Recipe::ClassMethod("blackColor"),
        "linkColor" => Recipe::ClassMethod("blueColor"),
        "unemphasizedSelectedTextColor" => Recipe::ClassMethod("blackColor"),
        "selectedContentBackgroundColor" => ACCENT,
        "unemphasizedSelectedContentBackgroundColor" => Recipe::Rgb(0.82, 0.89, 0.98),
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
        "quinaryLabelColor" => Recipe::Grey(0.82),
        // A NAME WITH A METHOD BUT NO RECIPE ANSWERED nil, which is the failure this table warns
        // about at the top: a table drew no grid and a focused control no ring, and neither is
        // distinguishable by looking from a control that was never asked to draw one.
        "gridColor" => Recipe::Grey(0.8),
        "keyboardFocusIndicatorColor" => Recipe::Rgba(0.0, 0.478, 1.0, 0.5),
        "unemphasizedSelectedTextBackgroundColor" => Recipe::Grey(0.86),
        "alternatingContentBackgroundColor" => Recipe::Grey(0.96),
        // The yellow behind the current match in a find bar.
        "findHighlightColor" => Recipe::Rgb(1.0, 1.0, 0.0),
        // THE FILL HIERARCHY, black at a few percent, lighter with each step down. An application
        // fills a control background with these and expects to see what is underneath through them.
        "systemFillColor" => Recipe::Rgba(0.0, 0.0, 0.0, 0.10),
        "secondarySystemFillColor" => Recipe::Rgba(0.0, 0.0, 0.0, 0.08),
        "tertiarySystemFillColor" => Recipe::Rgba(0.0, 0.0, 0.0, 0.05),
        "quaternarySystemFillColor" => Recipe::Rgba(0.0, 0.0, 0.0, 0.03),
        "quinarySystemFillColor" => Recipe::Rgba(0.0, 0.0, 0.0, 0.02),
        // THE MACOS SYSTEM PALETTE, light appearance. These are the published values, transcribed
        // rather than measured off a running macOS, and they are what an application means when it
        // asks for a colour BY ROLE instead of by value: a red that is the system red, not 1,0,0.
        // Until now every one of these was an unrecognised selector, which raises, and a raise
        // inside a drawing method is caught by most applications and turns the feature off with no
        // message at all.
        "systemRedColor" => Recipe::Rgb(1.0, 0.231, 0.188),
        "systemOrangeColor" => Recipe::Rgb(1.0, 0.584, 0.0),
        "systemYellowColor" => Recipe::Rgb(1.0, 0.8, 0.0),
        "systemGreenColor" => Recipe::Rgb(0.157, 0.804, 0.255),
        "systemMintColor" => Recipe::Rgb(0.0, 0.78, 0.745),
        "systemTealColor" => Recipe::Rgb(0.349, 0.678, 0.769),
        "systemCyanColor" => Recipe::Rgb(0.333, 0.745, 0.941),
        "systemBlueColor" => Recipe::Rgb(0.0, 0.478, 1.0),
        "systemIndigoColor" => Recipe::Rgb(0.345, 0.337, 0.839),
        "systemPurpleColor" => Recipe::Rgb(0.686, 0.322, 0.871),
        "systemPinkColor" => Recipe::Rgb(1.0, 0.176, 0.333),
        "systemBrownColor" => Recipe::Rgb(0.635, 0.518, 0.369),
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
        if crate::env_flag!("CIDER_WAYLAND_COLOR_PROBE") {
            if let Some((r, g, b)) = probe_recipe(text) {
                let sel = objc::sel_registerName(cstr!("colorWithDeviceRed:green:blue:alpha:"));
                let c = objc::msg_send_f64_4(color_cls, sel, r, g, b, 1.0);
                println!("cider-wayland-color name={text} probe={r},{g},{b}");
                return c;
            }
        }
        // EVERY NAME, NOT ONLY THE ONES THAT FAIL. A colour that is answered with the WRONG colour
        // is invisible to the nil trace below and is exactly what a foreign looking control is: the
        // Options tree drew its selected row grey, and the only way to learn which of a dozen
        // plausible names it had asked for was to watch the application ask.
        if crate::env_flag!("CIDER_WAYLAND_TRACE_COLORS") {
            println!("cider-wayland-color asked={text}");
        }
        match recipe_for(text) {
            None => {
                // A NAME THAT ANSWERS nil IS INVISIBLE FROM ABOVE. AppKit does not complain; it
                // draws with no colour, and the result is a control that renders as nothing at
                // all. That is not distinguishable from a layout bug by looking, so the names are
                // printed instead of guessed at.
                if crate::env_flag!("CIDER_WAYLAND_TRACE_COLORS") {
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
            Some(Recipe::Rgba(r, g, b, a)) => {
                let sel = objc::sel_registerName(cstr!(
                    "colorWithCalibratedRed:green:blue:alpha:"
                ));
                objc::msg_send_f64_4(color_cls, sel, r, g, b, a)
            }
        }
    }
}
