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

use objc::{Class, NsRect, ObjcSuper, Object, Sel};

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

/// -screens, the first abstract method AppKit demands.
///
/// PROVISIONAL GEOMETRY, and it is marked as such rather than quietly wrong: the compositor knows
/// the real size and wl_output reports it, but that needs a listener and this rung is about
/// getting past the abstract method. A wrong size here shows up as a window of the wrong size,
/// which is visible; a missing method shows up as a terminated process, which is not progress.
extern "C" fn display_screens(_this: Object, _cmd: Sel) -> Object {
    unsafe {
        let screen_cls = objc::objc_getClass(cstr!("NSScreen"));
        let array_cls = objc::objc_getClass(cstr!("NSArray"));
        if screen_cls.is_null() || array_cls.is_null() {
            println!("cider-wayland-appkit screens=FAILED reason=no-NSScreen-or-NSArray");
            return std::ptr::null_mut();
        }
        let frame = NsRect::new(0.0, 0.0, 1024.0, 768.0);
        let alloc = objc::sel_registerName(cstr!("alloc"));
        let init2 = objc::sel_registerName(cstr!("initWithFrame:visibleFrame:"));
        let screen = objc::msg_send0(screen_cls, alloc);
        let screen = objc::msg_send_rect2(screen, init2, frame, frame);
        if screen.is_null() {
            println!("cider-wayland-appkit screens=FAILED reason=NSScreen-init-returned-nil");
            return std::ptr::null_mut();
        }
        let with_objs = objc::sel_registerName(cstr!("arrayWithObjects:count:"));
        let one = [screen];
        let array = objc::msg_send_ptr_len(array_cls, with_objs, one.as_ptr(), 1);
        println!("cider-wayland-appkit screens=1 frame=1024x768 provisional=yes");
        array
    }
}

/// The window border geometry pair.
///
/// A WAYLAND CLIENT HAS NO SERVER SIDE BORDER: xdg-shell gives the client a surface and the
/// decorations are the client's own business unless the compositor offers the decoration
/// protocol. So the content rect and the frame rect are the same rect, and both of these are the
/// identity. Under X11 they differ because the window manager adds a frame.
///
/// RETURNING A STRUCT BY VALUE across the runtime is the reason these are spelled out rather than
/// left abstract: a 32 byte return goes through the hidden pointer path, and Rust's extern "C"
/// does that correctly, which is what makes a Rust IMP usable here at all.
extern "C" fn display_inset_rect(_this: Object, _cmd: Sel, frame: NsRect, _style: usize) -> NsRect {
    frame
}

extern "C" fn display_outset_rect(_this: Object, _cmd: Sel, frame: NsRect, _style: usize) -> NsRect {
    frame
}

/// Registered from a C constructor, because NSBundle asks for the principal class BY NAME as soon
/// as the bundle loads.
#[unsafe(no_mangle)]
pub extern "C" fn cider_wayland_appkit_register() {
    let cls: Class = unsafe {
        objc::register_subclass(cstr!("NSDisplayWayland"), cstr!("NSDisplay"), &[
            objc::MethodDef {
                sel: cstr!("init"),
                // "@@:" is: returns id, takes self and _cmd.
                types: cstr!("@@:"),
                imp: display_init as *const c_void,
            },
            objc::MethodDef {
                sel: cstr!("screens"),
                types: cstr!("@@:"),
                imp: display_screens as *const c_void,
            },
            // The encodings below describe a CGRect return and a CGRect plus NSUInteger argument.
            // They matter for introspection and forwarding; the CALL itself goes through the IMP,
            // whose Rust signature is what has to match the ABI.
            objc::MethodDef {
                sel: cstr!("insetRect:forNativeWindowBorderWithStyle:"),
                types: cstr!("{CGRect={CGPoint=dd}{CGSize=dd}}@:{CGRect={CGPoint=dd}{CGSize=dd}}L"),
                imp: display_inset_rect as *const c_void,
            },
            objc::MethodDef {
                sel: cstr!("outsetRect:forNativeWindowBorderWithStyle:"),
                types: cstr!("{CGRect={CGPoint=dd}{CGSize=dd}}@:{CGRect={CGPoint=dd}{CGSize=dd}}L"),
                imp: display_outset_rect as *const c_void,
            },
        ])
    };
    if cls.is_null() {
        println!("cider-wayland-appkit register=FAILED reason=no-NSDisplay-superclass");
        return;
    }
    println!("cider-wayland-appkit register=ok class=NSDisplayWayland");
}
