// The rest of NSDisplay's abstract surface, in one place.
//
// NSDisplay declares 25 methods that raise unless a backend defines them, and AppKit reaches them
// on ordinary paths: -draggingManager is sent from -[NSWindow initWithContentRect:...] itself, so
// every window hits it. They are implemented together rather than one per round trip, because
// discovering them one at a time costs a build and a container run each to learn a single name
// that the header already lists.
//
// WHERE X11 DOES NOTHING, THIS DOES NOTHING, and says so. Four of these raise NSUnimplementedMethod
// in the X11 backend and one returns nil outright; matching that is not laziness, it is the
// difference between a backend that behaves like the one this replaces and one that behaves
// differently for no stated reason. The comments say which is which so a later reader can tell an
// intentional gap from an oversight.
use std::os::raw::c_void;

use crate::cstr;
use crate::objc::{self, NsPoint, Object, Sel};

/// DRAG AND DROP IS NOT IMPLEMENTED, and nil is how the X11 backend says so. NSDraggingManager's
/// own methods are all abstract, so any object that is not a real manager would raise on first
/// use; nil absorbs the messages instead, which is why -[NSWindow init] sending
/// -registerWindow:dragTypes: to it is harmless.
extern "C" fn dragging_manager(_this: Object, _cmd: Sel) -> Object {
    std::ptr::null_mut()
}

/// THE PASTEBOARD IS A REAL GAP, called out rather than quietly nil. X11Pasteboard is a genuine
/// implementation over X selections, and the Wayland equivalent is wl_data_device, which needs a
/// seat. weston headless advertises no seat, so there is nothing to build against yet; a document
/// application will want this and the log will say it was asked for.
extern "C" fn pasteboard_with_name(_this: Object, _cmd: Sel, _name: Object) -> Object {
    static ANNOUNCED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    if !ANNOUNCED.swap(true, std::sync::atomic::Ordering::Relaxed) {
        println!("cider-wayland-appkit pasteboard=unimplemented reason=needs-wl_data_device");
    }
    std::ptr::null_mut()
}

/// Display-agnostic constants. Both are plain numbers in the X11 backend with no X call anywhere
/// near them, which is the same reason the font and colour methods moved here.
extern "C" fn text_caret_blink_interval(_this: Object, _cmd: Sel) -> f64 {
    0.5
}

extern "C" fn scroller_width(_this: Object, _cmd: Sel) -> f64 {
    15.0
}

/// CURSORS NEED A SEAT. A Wayland client sets the cursor by attaching a surface to a wl_pointer,
/// so with no pointer there is no cursor to set and nothing to hide. These are no-ops rather than
/// stubs that raise, because AppKit sets a cursor on ordinary mouse-move paths and an exception
/// there would kill an application over an invisible detail.
extern "C" fn hide_cursor(_this: Object, _cmd: Sel) {}

extern "C" fn unhide_cursor(_this: Object, _cmd: Sel) {}

extern "C" fn set_cursor(_this: Object, _cmd: Sel, _cursor: Object) {}

extern "C" fn cursor_with_name(_this: Object, _cmd: Sel, _name: Object) -> Object {
    std::ptr::null_mut()
}

extern "C" fn cursor_with_image(_this: Object, _cmd: Sel, _image: Object, _hot_spot: NsPoint) -> Object {
    std::ptr::null_mut()
}

/// X11 rings the X server's bell. There is no Wayland equivalent at all: the protocol has no bell
/// request, and a compositor that wants one uses a desktop service. The terminal bell is the
/// nearest honest thing and costs nothing.
extern "C" fn beep(_this: Object, _cmd: Sel) {
    print!("\x07");
}

/// PRINTING IS UNIMPLEMENTED IN THE X11 BACKEND TOO, where all four raise NSUnimplementedMethod
/// and return a zero. Returning the zero without the complaint is the same behaviour with less
/// noise; NSPrintOperation reads 0 as "the user cancelled".
extern "C" fn run_modal_zero(_this: Object, _cmd: Sel, _a: Object) -> i32 {
    0
}

extern "C" fn save_panel_run_modal(_this: Object, _cmd: Sel, _p: Object, _d: Object, _f: Object) -> i32 {
    0
}

extern "C" fn open_panel_run_modal(
    _this: Object,
    _cmd: Sel,
    _p: Object,
    _d: Object,
    _f: Object,
    _t: Object,
) -> i32 {
    0
}

extern "C" fn graphics_port_for_print(
    _this: Object,
    _cmd: Sel,
    _view: Object,
    _info: Object,
    _range: *mut c_void,
) -> *mut c_void {
    std::ptr::null_mut()
}

/// NO POINTER WITHOUT A SEAT, and no query for its position even with one: Wayland delivers motion
/// as events to a focused surface and offers no way to ask. The origin is what AppKit reads as
/// nothing to report.
extern "C" fn mouse_location(_this: Object, _cmd: Sel) -> NsPoint {
    NsPoint { x: 0.0, y: 0.0 }
}

/// Modifier state arrives with key events in Wayland (wl_keyboard.modifiers) rather than being
/// queryable, so there is nothing to report until there is a keyboard. Zero means no modifiers
/// held, which is true whenever nothing has been pressed.
extern "C" fn current_modifier_flags(_this: Object, _cmd: Sel) -> usize {
    0
}

/// The window numbers, front to back.
///
/// DISPLAY-AGNOSTIC: the X11 version walks [NSApp windows] and collects -windowNumber, touching no
/// X call, so this is the same walk written in Rust. Ordering is the application's own list, which
/// is the best available answer under a protocol where the compositor decides stacking and never
/// reports it.
extern "C" fn ordered_window_numbers(_this: Object, _cmd: Sel) -> Object {
    unsafe {
        let app_cls = objc::objc_getClass(cstr!("NSApplication"));
        let array_cls = objc::objc_getClass(cstr!("NSMutableArray"));
        let number_cls = objc::objc_getClass(cstr!("NSNumber"));
        if app_cls.is_null() || array_cls.is_null() || number_cls.is_null() {
            return std::ptr::null_mut();
        }
        let out = objc::msg_send0(array_cls, objc::sel_registerName(cstr!("array")));
        let app = objc::msg_send0(app_cls, objc::sel_registerName(cstr!("sharedApplication")));
        if app.is_null() {
            return out;
        }
        let windows = objc::msg_send0(app, objc::sel_registerName(cstr!("windows")));
        if windows.is_null() {
            return out;
        }
        let count = objc::msg_send_usize_ret(windows, objc::sel_registerName(cstr!("count")));
        let at_index = objc::sel_registerName(cstr!("objectAtIndex:"));
        let window_number = objc::sel_registerName(cstr!("windowNumber"));
        let with_integer = objc::sel_registerName(cstr!("numberWithInteger:"));
        let add = objc::sel_registerName(cstr!("addObject:"));
        for i in 0..count {
            let win = objc::msg_send_usize(windows, at_index, i);
            if win.is_null() {
                continue;
            }
            let n = objc::msg_send_i64_ret(win, window_number);
            let boxed = objc::msg_send_i64(number_cls, with_integer, n);
            if !boxed.is_null() {
                objc::msg_send_obj(out, add, boxed);
            }
        }
        out
    }
}

/// Every method above, ready to hand to the class registration alongside the ones that needed a
/// file of their own.
pub fn methods() -> Vec<objc::MethodDef> {
    vec![
        objc::MethodDef { sel: cstr!("draggingManager"), types: cstr!("@@:"), imp: dragging_manager as *const c_void },
        objc::MethodDef { sel: cstr!("pasteboardWithName:"), types: cstr!("@@:@"), imp: pasteboard_with_name as *const c_void },
        objc::MethodDef { sel: cstr!("textCaretBlinkInterval"), types: cstr!("d@:"), imp: text_caret_blink_interval as *const c_void },
        objc::MethodDef { sel: cstr!("scrollerWidth"), types: cstr!("d@:"), imp: scroller_width as *const c_void },
        objc::MethodDef { sel: cstr!("hideCursor"), types: cstr!("v@:"), imp: hide_cursor as *const c_void },
        objc::MethodDef { sel: cstr!("unhideCursor"), types: cstr!("v@:"), imp: unhide_cursor as *const c_void },
        objc::MethodDef { sel: cstr!("setCursor:"), types: cstr!("v@:@"), imp: set_cursor as *const c_void },
        objc::MethodDef { sel: cstr!("cursorWithName:"), types: cstr!("@@:@"), imp: cursor_with_name as *const c_void },
        objc::MethodDef { sel: cstr!("cursorWithImage:hotSpot:"), types: cstr!("@@:@{CGPoint=dd}"), imp: cursor_with_image as *const c_void },
        objc::MethodDef { sel: cstr!("beep"), types: cstr!("v@:"), imp: beep as *const c_void },
        objc::MethodDef { sel: cstr!("runModalPageLayoutWithPrintInfo:"), types: cstr!("i@:@"), imp: run_modal_zero as *const c_void },
        objc::MethodDef { sel: cstr!("runModalPrintPanelWithPrintInfoDictionary:"), types: cstr!("i@:@"), imp: run_modal_zero as *const c_void },
        objc::MethodDef { sel: cstr!("graphicsPortForPrintOperationWithView:printInfo:pageRange:"), types: cstr!("^v@:@@^v"), imp: graphics_port_for_print as *const c_void },
        objc::MethodDef { sel: cstr!("savePanel:runModalForDirectory:file:"), types: cstr!("i@:@@@"), imp: save_panel_run_modal as *const c_void },
        objc::MethodDef { sel: cstr!("openPanel:runModalForDirectory:file:types:"), types: cstr!("i@:@@@@"), imp: open_panel_run_modal as *const c_void },
        objc::MethodDef { sel: cstr!("mouseLocation"), types: cstr!("{CGPoint=dd}@:"), imp: mouse_location as *const c_void },
        objc::MethodDef { sel: cstr!("currentModifierFlags"), types: cstr!("Q@:"), imp: current_modifier_flags as *const c_void },
        objc::MethodDef { sel: cstr!("orderedWindowNumbers"), types: cstr!("@@:"), imp: ordered_window_numbers as *const c_void },
    ]
}
