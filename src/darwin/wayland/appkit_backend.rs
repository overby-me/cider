// THE APPKIT WAYLAND BACKEND (#112), and it is the one that is actually reached.
//
// CoreGraphics has a backend mechanism too, and in this prefix it is dead: its Backends live
// under Versions/C while Versions/Current points at A, so _CGSLoadBackend finds nothing and even
// the X11 CoreGraphics backend has never loaded. A DYLD_PRINT_LIBRARIES trace shows exactly one
// backend bundle in a whole AppKit run, and it is AppKit's. See docs/wayland-port.md.
//
// HOW APPKIT CHOOSES, which differs from CoreGraphics in the one way that shapes this file:
// NSDisplay sorts the bundles by NSPriority and then does [[principalClass alloc] init] on each,
// taking the first that returns non-nil. There is no +isAvailable. AVAILABILITY IS EXPRESSED BY
// RETURNING NIL, so an -init that cannot reach a compositor must return nil and let X11 win.
//
// OPT-IN FOR NOW. This backend declines unless CIDER_WAYLAND_BACKEND is set, because it does not
// yet implement the abstract methods NSDisplay requires and being chosen would break every GUI
// program rather than only the new path. The variable comes out when the methods go in.
use std::os::raw::c_void;

mod objc;
mod wl;

use objc::{Class, ObjcSuper, Object, Sel};

/// -init, the whole of the backend's current behaviour.
///
/// Returns nil unless CIDER_WAYLAND_BACKEND is set AND a compositor answers, which is how a
/// backend says "not me" on this side of AppKit.
extern "C" fn display_init(this: Object, _cmd: Sel) -> Object {
    if std::env::var_os("CIDER_WAYLAND_BACKEND").is_none() {
        println!("cider-wayland-appkit init=declined reason=CIDER_WAYLAND_BACKEND-unset");
        return std::ptr::null_mut();
    }

    // Chain to NSDisplay first: skipping the superclass leaves whatever it sets up unset, and
    // that surfaces much later as a nil ivar rather than here.
    let super_class = unsafe { objc::class_getSuperclass(objc::object_getClass(this)) };
    let mut sup = ObjcSuper { receiver: this, super_class };
    let sel_init = unsafe { objc::sel_registerName(cstr!("init")) };
    let this = unsafe { objc::objc_msgSendSuper(&mut sup, sel_init) };
    if this.is_null() {
        println!("cider-wayland-appkit init=declined reason=super-returned-nil");
        return std::ptr::null_mut();
    }

    // A COMPOSITOR HAS TO ANSWER, and this is the honest place to find out: returning self and
    // failing later would make every window operation fail instead of letting X11 take over.
    let display = unsafe { wl::wl_display_connect(std::ptr::null()) };
    if display.is_null() {
        println!("cider-wayland-appkit init=declined reason=no-compositor");
        return std::ptr::null_mut();
    }
    println!("cider-wayland-appkit init=ok display=connected");
    // Kept open deliberately: the connection IS the backend's state, and there is nowhere else to
    // put it until the class grows an ivar.
    this
}

/// Registered from a C constructor, because NSBundle asks for the principal class BY NAME as soon
/// as the bundle loads.
#[unsafe(no_mangle)]
pub extern "C" fn cider_wayland_appkit_register() {
    let cls: Class = unsafe {
        objc::register_subclass(cstr!("NSDisplayWayland"), cstr!("NSDisplay"), &[objc::MethodDef {
            sel: cstr!("init"),
            // "@@:" is: returns id, takes self and _cmd.
            types: cstr!("@@:"),
            imp: display_init as *const c_void,
        }])
    };
    if cls.is_null() {
        println!("cider-wayland-appkit register=FAILED reason=no-NSDisplay-superclass");
        return;
    }
    println!("cider-wayland-appkit register=ok class=NSDisplayWayland");
}
