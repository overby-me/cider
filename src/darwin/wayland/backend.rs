// THE WAYLAND BACKEND for CoreGraphics (#112), in Rust, by the user's choice.
//
// HOW A BACKEND IS CHOSEN, because the whole design follows from it. CoreGraphics does not link a
// window system: _CGSLoadBackend in CGS.m loads every *.backend bundle under its Resources,
// sorts them by the NSPriority integer in their Info.plist, and takes the first whose principal
// class answers +isAvailable. X11 is priority 200 with a getenv("DISPLAY") probe. This bundle is
// priority 300 with a getenv("WAYLAND_DISPLAY") probe, so on a Wayland session it wins and on
// anything else it declines and X11 still runs. Nothing in CoreGraphics changes.
//
// WHAT THIS FILE IS TODAY: registration and selection, and no windows yet. That is deliberate.
// The rung it completes is "CoreGraphics loads a Rust backend and picks it", which is checkable
// on its own and worth having green before CGSWindow and CGSSurface arrive. The method tables
// for those are in the header comments of objc.rs and in docs/wayland-port.md.
//
// THE ENTRY POINT IS A CONSTRUCTOR. NSBundle loads this dylib and then asks for the principal
// class BY NAME, so the class has to exist before anything sends it a message. shim.c carries the
// __attribute__((constructor)) that calls the function below, because Rust has no stable
// equivalent that survives a staticlib being pulled into a dylib.
use std::os::raw::c_char;

mod objc;
mod wl;

use objc::{register_subclass, MethodDef, ObjcBool, Object, Sel, NO, YES};

/// The probe CoreGraphics runs before choosing a backend.
///
/// Deliberately CHEAP: it does not connect. _CGSLoadBackend calls this on every backend it loaded,
/// on a path that runs before anything is on screen, and a probe that opened a socket would make
/// backend selection depend on the compositor being reachable at that instant. The X11 one is a
/// single getenv for the same reason.
extern "C" fn is_available(_cls: Object, _cmd: Sel) -> ObjcBool {
    match std::env::var_os("WAYLAND_DISPLAY") {
        Some(display) => {
            // A marker, because the interesting failure is "the backend was never asked", and
            // that is invisible without one.
            println!(
                "cider-wayland-backend isAvailable=YES WAYLAND_DISPLAY={}",
                display.to_string_lossy()
            );
            YES
        }
        None => {
            println!("cider-wayland-backend isAvailable=NO reason=no-WAYLAND_DISPLAY");
            NO
        }
    }
}

/// Register the backend's classes. Called from a C constructor in shim.c.
///
/// Registering is not the same as being chosen: CoreGraphics decides that, from NSPriority and
/// +isAvailable. A print here answers the first question a failing run asks, which is whether the
/// bundle was loaded at all.
#[unsafe(no_mangle)]
pub extern "C" fn cider_wayland_backend_register() {
    let methods = [MethodDef {
        sel: cstr!("isAvailable"),
        // "c@:" is: returns char (ObjC BOOL), takes self and _cmd. BOOL is a signed char here,
        // not a Rust bool, and the width is why this is spelled out.
        types: cstr!("c@:"),
        imp: is_available as *const std::os::raw::c_void,
    }];

    // +isAvailable is a CLASS method, so it goes on the metaclass. object_getClass of a class
    // object is that metaclass, which is how the runtime spells it.
    let cls = unsafe {
        register_subclass(
            cstr!("CGSConnectionWayland"),
            cstr!("CGSConnection"),
            &[],
        )
    };
    if cls.is_null() {
        println!("cider-wayland-backend register=FAILED reason=no-CGSConnection-superclass");
        return;
    }
    let meta = unsafe { objc::object_getClass(cls) };
    for m in &methods {
        let sel = unsafe { objc::sel_registerName(m.sel) };
        unsafe { objc::class_addMethod(meta, sel, m.imp, m.types) };
    }
    println!("cider-wayland-backend register=ok class=CGSConnectionWayland");
}

/// Kept so the FFI module is exercised even before windows exist: without a use, the wayland
/// declarations would be dead code and a broken one would not be noticed until much later.
#[unsafe(no_mangle)]
pub extern "C" fn cider_wayland_backend_can_connect() -> ObjcBool {
    let display = unsafe { wl::wl_display_connect(std::ptr::null::<c_char>()) };
    if display.is_null() {
        return NO;
    }
    unsafe { wl::wl_display_disconnect(display) };
    YES
}
