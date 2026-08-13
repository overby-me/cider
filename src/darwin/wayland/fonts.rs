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

/// The typefaces within one family.
///
/// EMPTY IS A LEGITIMATE ANSWER for now, and it is announced rather than faked: AppKit uses this
/// to populate a family with its styles, and returning an empty array means a family with no
/// styles rather than a crash. Filling it needs NSFontTypeface, which is the next font-side piece.
pub fn typefaces_for_family(_family: objc::Object) -> objc::Object {
    unsafe {
        let array_cls = objc::objc_getClass(cstr!("NSArray"));
        if array_cls.is_null() {
            return std::ptr::null_mut();
        }
        let sel_array = objc::sel_registerName(cstr!("array"));
        objc::msg_send0(array_cls, sel_array)
    }
}

/// Unused today, kept because FcPatternGetInteger is exactly what the typeface work needs next
/// (slant and weight) and removing the declaration would only mean writing it again.
#[allow(dead_code)]
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
