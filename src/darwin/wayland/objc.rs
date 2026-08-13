// The Objective-C runtime, by hand, because a Cocotron backend IS a class hierarchy.
//
// CoreGraphics loads a *.backend bundle and asks its Info.plist NSPrincipalClass for
// +isAvailable, then sends it -newWindow: and the rest. So the backend has to EXPOSE OBJC
// CLASSES that subclass CGSConnection, CGSWindow and CGSSurface. The user chose Rust for this
// port, and Rust has no ObjC class syntax, so the classes are built at load time through the
// runtime's own C API. That is what this module wraps, and it wraps nothing else.
//
// NO objc2 CRATE. vendor/rust carries 53 crates and neither objc2 nor its family is among them;
// adding one would be a vendoring exercise to get what six extern declarations give. See
// docs/wayland-port.md for the same reasoning applied to wayland-client.
//
// THE ENCODINGS ARE THE PART TO GET RIGHT. class_addMethod takes a type encoding string that
// describes the return and every argument, INCLUDING the implicit self and _cmd. An encoding
// that disagrees with the function signature does not fail at registration; it corrupts
// arguments at the first call, which is a debugging session nobody wants. They are spelled out
// next to each method rather than built by a macro, so a reader can check them against the
// header.
use std::os::raw::{c_char, c_int, c_void};

pub type Class = *mut c_void;
pub type Object = *mut c_void;
pub type Sel = *mut c_void;
pub type Imp = *const c_void;

unsafe extern "C" {
    pub fn objc_getClass(name: *const c_char) -> Class;
    pub fn objc_allocateClassPair(superclass: Class, name: *const c_char, extra: usize) -> Class;
    pub fn objc_registerClassPair(cls: Class);
    pub fn class_addMethod(cls: Class, name: Sel, imp: Imp, types: *const c_char) -> bool;
    pub fn class_addIvar(
        cls: Class,
        name: *const c_char,
        size: usize,
        alignment: u8,
        types: *const c_char,
    ) -> bool;
    pub fn object_getIndexedIvars(obj: Object) -> *mut c_void;
    pub fn sel_registerName(name: *const c_char) -> Sel;
    pub fn object_getClass(obj: Object) -> Class;
    pub fn class_getSuperclass(cls: Class) -> Class;

    /// CALLING super. An override that does not chain to its superclass skips whatever the base
    /// set up, and for an -init that is usually fatal later rather than here. Declared with the
    /// exact signature of a zero-argument message rather than as a variadic, which is the
    /// ordinary way to reach objc_msgSendSuper from Rust: the ABI for the no-extra-argument case
    /// is the same and a variadic declaration would be harder to call correctly.
    pub fn objc_msgSendSuper(sup: *mut ObjcSuper, sel: Sel) -> Object;

    /// objc_msgSend IS DECLARED ONCE PER SIGNATURE, deliberately. It is a variadic symbol whose
    /// real ABI is that of the method being called, so the only safe way to reach it from Rust is
    /// a declaration that spells out the exact argument types of each call site. Aliasing them
    /// with #[link_name] gives distinct Rust signatures over the same symbol.
    #[link_name = "objc_msgSend"]
    pub fn msg_send0(receiver: Object, sel: Sel) -> Object;
    #[link_name = "objc_msgSend"]
    pub fn msg_send_rect2(receiver: Object, sel: Sel, a: NsRect, b: NsRect) -> Object;
    #[link_name = "objc_msgSend"]
    pub fn msg_send_ptr_len(receiver: Object, sel: Sel, objs: *const Object, count: usize) -> Object;
    #[link_name = "objc_msgSend"]
    pub fn msg_send_cstr(receiver: Object, sel: Sel, s: *const c_char) -> Object;
    #[link_name = "objc_msgSend"]
    pub fn msg_send_obj(receiver: Object, sel: Sel, obj: Object) -> Object;
}

/// AppKit geometry: two doubles of origin, two of size. repr(C) so the struct is passed the way
/// the method expects rather than the way Rust would prefer.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct NsPoint {
    pub x: f64,
    pub y: f64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct NsSize {
    pub width: f64,
    pub height: f64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct NsRect {
    pub origin: NsPoint,
    pub size: NsSize,
}

impl NsRect {
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        NsRect {
            origin: NsPoint { x, y },
            size: NsSize { width, height },
        }
    }
}

/// The receiver plus the class to start the lookup from, which is what makes a super call a super
/// call. Layout is fixed by the runtime.
#[repr(C)]
pub struct ObjcSuper {
    pub receiver: Object,
    pub super_class: Class,
}

/// A NUL terminated literal, since every runtime call takes a C string and Rust literals are not.
#[macro_export]
macro_rules! cstr {
    ($s:literal) => {
        concat!($s, "\0").as_ptr() as *const ::std::os::raw::c_char
    };
}

/// What a class needs before it can be registered: its name, its superclass, and the methods it
/// overrides. Kept as data so the registration reads like the header it mirrors.
pub struct MethodDef {
    pub sel: *const c_char,
    pub types: *const c_char,
    pub imp: Imp,
}

/// Register one subclass. Returns null if the superclass is missing, which is the interesting
/// failure: it means CoreGraphics is not loaded, or its class names have moved.
///
/// # Safety
/// `imp` in every MethodDef must be a function whose signature matches `types` exactly.
pub unsafe fn register_subclass(
    name: *const c_char,
    superclass_name: *const c_char,
    methods: &[MethodDef],
) -> Class {
    let superclass = unsafe { objc_getClass(superclass_name) };
    if superclass.is_null() {
        return std::ptr::null_mut();
    }
    let cls = unsafe { objc_allocateClassPair(superclass, name, 0) };
    if cls.is_null() {
        // Already registered: a second load of the same bundle, which is not an error.
        return unsafe { objc_getClass(name) };
    }
    for m in methods {
        let sel = unsafe { sel_registerName(m.sel) };
        unsafe { class_addMethod(cls, sel, m.imp, m.types) };
    }
    unsafe { objc_registerClassPair(cls) };
    cls
}

/// Objective-C BOOL is a signed char on this platform, not Rust bool, and returning the wrong
/// width is the kind of mistake that reads as "isAvailable said no" with no other symptom.
pub type ObjcBool = c_char;
pub const YES: ObjcBool = 1;
pub const NO: ObjcBool = 0;

/// CoreGraphics returns these; 0 is success. Named rather than inlined so the intent survives.
pub type CgError = c_int;
pub const K_CG_ERROR_SUCCESS: CgError = 0;
pub const K_CG_ERROR_FAILURE: CgError = 1000;
