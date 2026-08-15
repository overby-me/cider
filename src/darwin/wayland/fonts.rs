// Font enumeration for the Wayland backend, through fontconfig.
//
// THIS IS NOT WINDOW SYSTEM CODE, and that is the point. The X11 backend implements
// -allFontFamilyNames and -fontTypefacesForFamilyName: with fontconfig and no X calls at all;
// they live in X11Display only because that is where Cocotron put them. 31 of its 49 methods are
// like this. The user chose to REIMPLEMENT rather than patch the pin, so they are written here.
//
// THE SHARED CONFIG IS NOT AVAILABLE. The X11 backend calls O2FontSharedFontConfig(), a Cocotron
// helper, and that symbol is not exported by the CoreGraphics this prefix links (checked with
// llvm-nm). fontconfig takes NULL to mean the current configuration, which is what the helper
// returns anyway, so NULL is used and FcInit is called once to make sure one exists.
use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_void};

// The macro is exported at the crate root by objc.rs, so a module reaches it through crate::,
// not through the module path. A macro_export macro is not a module item.
use crate::cstr;
use crate::objc;

pub enum FcPattern {}
pub enum FcObjectSet {}
pub enum FcConfig {}

/// fontconfig's result enum; 0 is FcResultMatch and nothing else is interesting here.
const FC_RESULT_MATCH: c_int = 0;

/// The layout fontconfig documents for a font set. Read only, and only these three fields.
#[repr(C)]
pub struct FcFontSet {
    pub nfont: c_int,
    pub sfont: c_int,
    pub fonts: *mut *mut FcPattern,
}

unsafe extern "C" {
    fn FcInit() -> c_int;
    fn FcPatternAddString(p: *mut FcPattern, object: *const c_char, s: *const c_char) -> c_int;
    fn FcPatternAddBool(p: *mut FcPattern, object: *const c_char, b: c_int) -> c_int;
    fn FcNameParse(name: *const c_char) -> *mut FcPattern;
    fn FcNameUnparse(p: *mut FcPattern) -> *mut c_char;
    fn FcStrFree(s: *mut c_char);
    fn FcConfigSubstitute(config: *mut FcConfig, p: *mut FcPattern, kind: c_int) -> c_int;
    fn FcDefaultSubstitute(p: *mut FcPattern);
    fn FcFontMatch(config: *mut FcConfig, p: *mut FcPattern, result: *mut c_int) -> *mut FcPattern;
    fn FcPatternCreate() -> *mut FcPattern;
    fn FcPatternDestroy(p: *mut FcPattern);
    fn FcPatternGetString(p: *mut FcPattern, object: *const c_char, n: c_int, s: *mut *mut c_char) -> c_int;
    fn FcPatternGetInteger(p: *mut FcPattern, object: *const c_char, n: c_int, i: *mut c_int) -> c_int;
    /// VARIADIC, terminated by a null pointer, which is why it is declared with the ellipsis
    /// rather than fixed arity.
    fn FcObjectSetBuild(first: *const c_char, ...) -> *mut FcObjectSet;
    fn FcObjectSetDestroy(os: *mut FcObjectSet);
    fn FcFontList(config: *mut FcConfig, p: *mut FcPattern, os: *mut FcObjectSet) -> *mut FcFontSet;
    fn FcFontSetDestroy(s: *mut FcFontSet);
}

/// Every family fontconfig knows about, as an NSSet of NSString.
///
/// AppKit asks for this early, before any window exists, which is why it was the wall right after
/// -screens.
pub fn all_family_names() -> objc::Object {
    unsafe {
        FcInit();
        let set_cls = objc::objc_getClass(cstr!("NSMutableSet"));
        let str_cls = objc::objc_getClass(cstr!("NSString"));
        if set_cls.is_null() || str_cls.is_null() {
            println!("cider-wayland-appkit fonts=FAILED reason=no-NSMutableSet-or-NSString");
            return std::ptr::null_mut();
        }
        let sel_set = objc::sel_registerName(cstr!("set"));
        let sel_add = objc::sel_registerName(cstr!("addObject:"));
        let sel_utf8 = objc::sel_registerName(cstr!("stringWithUTF8String:"));
        let out = objc::msg_send0(set_cls, sel_set);

        let pattern = FcPatternCreate();
        // SCALABLE ONLY. A bitmap X11 font has one size and no outline, and everything above this
        // draws by scaling an outline to a point size, so a face without one renders as nothing.
        // The list here becomes the typeface patterns applications hand back to us later, so a
        // bitmap font that enters here reaches FreeType with no match in between.
        FcPatternAddBool(pattern, cstr!("scalable"), 1);
        let props = FcObjectSetBuild(cstr!("family"), std::ptr::null::<c_char>());
        // NULL config: fontconfig reads that as the current configuration, which is what the
        // Cocotron helper would have handed back.
        let fonts = FcFontList(std::ptr::null_mut(), pattern, props);
        let mut count = 0;
        if !fonts.is_null() {
            let fonts_ref = &*fonts;
            for i in 0..fonts_ref.nfont {
                let pat = *fonts_ref.fonts.offset(i as isize);
                let mut family: *mut c_char = std::ptr::null_mut();
                if FcPatternGetString(pat, cstr!("family"), 0, &mut family) == FC_RESULT_MATCH
                    && !family.is_null()
                {
                    let s = objc::msg_send_cstr(str_cls, sel_utf8, family);
                    if !s.is_null() {
                        objc::msg_send_obj(out, sel_add, s);
                        count += 1;
                    }
                }
            }
            FcFontSetDestroy(fonts);
        }
        FcObjectSetDestroy(props);
        FcPatternDestroy(pattern);
        println!("cider-wayland-appkit fonts={count} families");
        out
    }
}

// fontconfig's own numbers, from fontconfig.h. Named rather than inlined because the comparisons
// below read as nonsense otherwise: 87 and 113 mean nothing, semicondensed and semiexpanded do.
const FC_MATCH_PATTERN: c_int = 0;
const FC_SLANT_ITALIC: c_int = 100;
const FC_SLANT_OBLIQUE: c_int = 110;
const FC_WIDTH_SEMICONDENSED: c_int = 87;
const FC_WIDTH_SEMIEXPANDED: c_int = 113;
const FC_WEIGHT_LIGHT: c_int = 50;
const FC_WEIGHT_SEMIBOLD: c_int = 180;

// NSFontManager.h, checked against the header rather than remembered.
const NS_ITALIC_FONT_MASK: u64 = 0x0000_0001;
const NS_BOLD_FONT_MASK: u64 = 0x0000_0002;
const NS_UNBOLD_FONT_MASK: u64 = 0x0000_0004;
const NS_NARROW_FONT_MASK: u64 = 0x0000_0010;
const NS_EXPANDED_FONT_MASK: u64 = 0x0000_0020;
const NS_UNITALIC_FONT_MASK: u64 = 0x0100_0000;

/// Ask fontconfig what it would actually use for a family name, which is how a request for a font
/// nobody has still produces a font. Returns None only if fontconfig has nothing at all.
///
/// # Safety
/// `name` is a NUL terminated family name.
unsafe fn substitute_family(name: *const c_char) -> Option<*mut FcPattern> {
    unsafe {
        let pat = FcNameParse(name);
        if pat.is_null() {
            return None;
        }
        FcConfigSubstitute(std::ptr::null_mut(), pat, FC_MATCH_PATTERN);
        FcDefaultSubstitute(pat);
        let mut result: c_int = 0;
        let matched = FcFontMatch(std::ptr::null_mut(), pat, &mut result);
        FcPatternDestroy(pat);
        if matched.is_null() { None } else { Some(matched) }
    }
}

/// THE FAMILY NAME THAT FONTCONFIG SUBSTITUTES FOR THIS ONE, remembered.
///
/// FcFontMatch walks the whole font set and compares every element of the pattern against every
/// candidate, and it was 29.69 percent of a whole text to PDF conversion -- more than the layout,
/// the rasteriser and the PDF filter together. Nothing above it cached, and an application that
/// enumerates its font list asks for the typefaces of EVERY family, so the same expensive answer
/// was computed once per family on every start.
///
/// Only the resulting family NAME is wanted here; the listing that follows is done with a fresh
/// pattern, exactly as the X11 version does. So the cache holds a string, not a pattern, and there
/// is no lifetime question about a pattern owned by fontconfig.
///
/// The configuration is not reloaded during a run, so the answer cannot change under the cache.
fn substituted_family_name(name: &CStr) -> Option<std::ffi::CString> {
    use std::collections::HashMap;
    use std::sync::Mutex;
    use std::sync::OnceLock;

    static CACHE: OnceLock<Mutex<HashMap<Vec<u8>, Option<std::ffi::CString>>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let key = name.to_bytes().to_vec();

    if let Ok(map) = cache.lock() {
        if let Some(hit) = map.get(&key) {
            if crate::env_flag!("CIDER_TRACE_FONTS") {
                println!("cider-wayland-font substitute=hit family={}", name.to_string_lossy());
            }
            return hit.clone();
        }
    }

    let answer = unsafe {
        match substitute_family(name.as_ptr()) {
            None => None,
            Some(substituted) => {
                let mut family_name: *mut c_char = std::ptr::null_mut();
                let have = FcPatternGetString(substituted, cstr!("family"), 0, &mut family_name)
                    == FC_RESULT_MATCH
                    && !family_name.is_null();
                let owned = if have { Some(CStr::from_ptr(family_name).to_owned()) } else { None };
                FcPatternDestroy(substituted);
                owned
            }
        }
    };

    if crate::env_flag!("CIDER_TRACE_FONTS") {
        println!(
            "cider-wayland-font substitute=miss family={} answer={}",
            name.to_string_lossy(),
            answer.as_ref().map(|a| a.to_string_lossy().into_owned()).unwrap_or_default()
        );
    }
    if let Ok(mut map) = cache.lock() {
        map.insert(key, answer.clone());
    }
    answer
}

/// The typefaces within one family, as NSFontTypeface objects.
///
/// This is the X11 implementation, which is pure fontconfig and touches no X call, WITH ONE BUG
/// FIXED. It passes FcPatternGetInteger a default VALUE where the parameter is an INDEX:
/// FcPatternGetInteger(p, FC_WIDTH, FC_WIDTH_NORMAL, &width) asks for element 100 of the width
/// list, which does not exist, so the call fails and width is read UNINITIALISED off the stack.
/// The same applies to weight. Only slant works there, and by accident: FC_SLANT_ROMAN is 0, which
/// happens to be the right index. Every element here is asked for at index 0, which is what was
/// meant, so bold and condensed faces are classified rather than left to whatever was on the stack.
pub fn typefaces_for_family(family: objc::Object) -> objc::Object {
    unsafe {
        FcInit();
        let array_cls = objc::objc_getClass(cstr!("NSMutableArray"));
        let str_cls = objc::objc_getClass(cstr!("NSString"));
        let face_cls = objc::objc_getClass(cstr!("NSFontTypeface"));
        if array_cls.is_null() || str_cls.is_null() || face_cls.is_null() {
            return std::ptr::null_mut();
        }
        let out = objc::msg_send0(array_cls, objc::sel_registerName(cstr!("array")));
        if family.is_null() {
            return out;
        }
        let sel_utf8 = objc::sel_registerName(cstr!("UTF8String"));
        let raw = objc::msg_send0(family, sel_utf8) as *const c_char;
        if raw.is_null() {
            return out;
        }
        /*
         * THE FILE IS IN THE OBJECT SET, and that one word is worth about a second of startup.
         *
         * The typeface name handed back is FcNameUnparse of this pattern, and Onyx2D parses it back
         * later to find the font FILE. Without file here the round trip is lossy: the file we
         * already have in our hands is dropped, and finding it again costs a full FcFontMatch, once
         * per typeface. Measured before this: 1573 distinct patterns in one startup, 1573 matches,
         * and FcFontMatch was 29.69 percent of the run.
         */
        let props = FcObjectSetBuild(
            cstr!("family"),
            cstr!("style"),
            cstr!("slant"),
            cstr!("width"),
            cstr!("weight"),
            cstr!("file"),
            std::ptr::null::<c_char>(),
        );

        /*
         * ASK FOR THE FAMILY THAT WAS NAMED FIRST, and only fall back to fontconfig's substitution
         * when there is no such family.
         *
         * The substitution is what resolves an ALIAS -- sans-serif, or a name this system does not
         * have -- and it costs an FcFontMatch, which walks the entire font set comparing every
         * element of the pattern against every candidate. That was 29.69 percent of a whole text to
         * PDF conversion, more than the layout, the rasteriser and the PDF filter together.
         *
         * And almost every call is for a name that needs no substitution at all: an application
         * enumerating its font list asks us for the families and then asks each one for its
         * typefaces, so the name it hands back came from fontconfig in the first place. Measured:
         * 281 substitutions in one startup, every one of them a name we had just supplied.
         *
         * A caching layer does not help here, which was the first thing tried and the reason this
         * comment exists: the 281 names are 281 DIFFERENT names, so a cache is 281 misses.
         */
        let mut pat = FcPatternCreate();
        FcPatternAddString(pat, cstr!("family"), raw);
        FcPatternAddBool(pat, cstr!("scalable"), 1);
        let mut set = FcFontList(std::ptr::null_mut(), pat, props);
        let listed = if set.is_null() { 0 } else { (*set).nfont };

        if listed == 0 {
            if !set.is_null() {
                FcFontSetDestroy(set);
            }
            FcPatternDestroy(pat);
            let Some(family_name) = substituted_family_name(CStr::from_ptr(raw)) else {
                FcObjectSetDestroy(props);
                return out;
            };
            pat = FcPatternCreate();
            FcPatternAddString(pat, cstr!("family"), family_name.as_ptr());
            FcPatternAddBool(pat, cstr!("scalable"), 1);
            set = FcFontList(std::ptr::null_mut(), pat, props);
        }

        let string_with = objc::sel_registerName(cstr!("stringWithUTF8String:"));
        let alloc = objc::sel_registerName(cstr!("alloc"));
        let init_face = objc::sel_registerName(cstr!("initWithName:traitName:traits:"));
        let add = objc::sel_registerName(cstr!("addObject:"));
        let release = objc::sel_registerName(cstr!("release"));
        let mut count = 0;
        if !set.is_null() {
            let set_ref = &*set;
            for i in 0..set_ref.nfont {
                let p = *set_ref.fonts.offset(i as isize);
                let mut style: *mut c_char = std::ptr::null_mut();
                if FcPatternGetString(p, cstr!("style"), 0, &mut style) != FC_RESULT_MATCH
                    || style.is_null()
                {
                    continue;
                }
                let trait_name = objc::msg_send_cstr(str_cls, string_with, style);
                // FcNameUnparse gives the full pattern text, which is what Onyx2D later parses
                // back to find the file. It is fontconfig's own round trip, not a display name.
                let unparsed = FcNameUnparse(p);
                if unparsed.is_null() {
                    continue;
                }
                let name = objc::msg_send_cstr(str_cls, string_with, unparsed);
                FcStrFree(unparsed);

                let slant = pattern_integer(p, cstr!("slant")).unwrap_or(0);
                let width = pattern_integer(p, cstr!("width")).unwrap_or(100);
                let weight = pattern_integer(p, cstr!("weight")).unwrap_or(80);
                let mut traits = if slant == FC_SLANT_ITALIC || slant == FC_SLANT_OBLIQUE {
                    NS_ITALIC_FONT_MASK
                } else {
                    NS_UNITALIC_FONT_MASK
                };
                if weight <= FC_WEIGHT_LIGHT {
                    traits |= NS_UNBOLD_FONT_MASK;
                } else if weight >= FC_WEIGHT_SEMIBOLD {
                    traits |= NS_BOLD_FONT_MASK;
                }
                if width <= FC_WIDTH_SEMICONDENSED {
                    traits |= NS_NARROW_FONT_MASK;
                } else if width >= FC_WIDTH_SEMIEXPANDED {
                    traits |= NS_EXPANDED_FONT_MASK;
                }

                let face = objc::msg_send_face_init(
                    objc::msg_send0(face_cls, alloc),
                    init_face,
                    name,
                    trait_name,
                    traits,
                );
                if !face.is_null() {
                    objc::msg_send_obj(out, add, face);
                    // The array retains it, so the reference from alloc is ours to drop. Without
                    // this every family listing leaks one object per face.
                    objc::msg_send0(face, release);
                    count += 1;
                }
            }
            FcFontSetDestroy(set);
        }
        FcObjectSetDestroy(props);
        FcPatternDestroy(pat);
        if count == 0 {
            println!("cider-wayland-appkit typefaces=none family=unmatched");
        }
        out
    }
}

/// One integer property at index 0, which is the index that was meant everywhere it is used.
pub unsafe fn pattern_integer(pat: *mut FcPattern, key: *const c_char) -> Option<c_int> {
    let mut v: c_int = 0;
    if unsafe { FcPatternGetInteger(pat, key, 0, &mut v) } == FC_RESULT_MATCH {
        Some(v)
    } else {
        None
    }
}

/// Silences the unused warning for the opaque config type while keeping it documented.
#[allow(dead_code)]
fn _config_type_is_used(_c: *mut FcConfig, _v: *mut c_void) {}
