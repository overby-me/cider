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
// IT IS THE DEFAULT NOW, and the opt-in variable is an opt-OUT. It was opt-in while the abstract
// methods NSDisplay requires were missing, because being chosen then would have broken every GUI
// program rather than only the new path. They are in: LibreOffice renders, takes keyboard and
// mouse, and resizes on this backend, which is what the variable was waiting for.
//
// CIDER_WAYLAND_BACKEND=0 declines on purpose, for comparing against X11 without rebuilding.
use std::os::raw::c_void;

mod clipboard;
mod colors;
mod display;
mod fonts;
mod input;
mod objc;
mod session;
mod wl;
mod window;

use objc::{Class, NsRect, ObjcSuper, Object, Sel};

/// -init, the whole of the backend's current behaviour.
///
/// Returns nil unless a compositor answers, which is how a backend says "not me" on this side of
/// AppKit, or unless CIDER_WAYLAND_BACKEND is set to 0 to decline deliberately.
///
/// NOTHING ELSE IS NEEDED TO KEEP X11 WORKING WHERE THERE IS NO WAYLAND: connect() fails without a
/// compositor, this returns nil, and NSDisplay moves on to the next bundle by priority.
extern "C" fn display_init(this: Object, _cmd: Sel) -> Object {
    if std::env::var_os("CIDER_WAYLAND_BACKEND").as_deref() == Some(std::ffi::OsStr::new("0")) {
        println!("cider-wayland-appkit init=declined reason=CIDER_WAYLAND_BACKEND-0");
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
    // failing later would make every window operation fail instead of declining the backend.
    // connect() also binds the globals a window needs, so a compositor that answers but offers no
    // xdg_wm_base is refused here rather than at the first window.
    if !session::connect() {
        return std::ptr::null_mut();
    }
    // The window class needs CGWindow, which is loaded by now: this bundle is an AppKit backend,
    // so CoreGraphics came in before it.
    if unsafe { window::register() }.is_null() {
        println!("cider-wayland-appkit init=declined reason=no-CGWindow");
        return std::ptr::null_mut();
    }
    this
}

/// -nextEventMatchingMask:untilDate:inMode:dequeue:, which is where an application spends its
/// life.
///
/// THE OVERRIDE EXISTS TO SERVICE THE CONNECTION, not to produce events. NSDisplay's own
/// implementation manages the queue perfectly well and is chained to; what it cannot do is read
/// the Wayland socket, and a client that never reads it never learns it was resized, never sees a
/// close request, and never answers a ping. A compositor treats an unanswered ping as a hung
/// application, so the symptom of skipping this is a window that stops responding rather than an
/// error anyone can see. This is the same shape as the X11 backend, which calls
/// -processPendingEvents here for the same reason.
unsafe extern "C" {
    fn cider_wayland_drain_main_queue();
    /// An autorelease pool around the work this backend does per pass. See the comment on the C
    /// side: the returned event must NOT be inside it.
    fn cider_wayland_pool_push() -> *mut c_void;
    fn cider_wayland_pool_pop(pool: *mut c_void);
}

extern "C" fn display_next_event(
    this: Object,
    _cmd: Sel,
    mask: u64,
    until: Object,
    mode: Object,
    dequeue: objc::ObjcBool,
) -> Object {
    /*
     * A POOL AROUND THIS BACKEND OWN WORK, and only that.
     *
     * Everything here calls into AppKit and produces autoreleased objects, and it runs on every
     * pass, so without a pool it accumulates for the life of the process.
     *
     * IT CANNOT BE STRETCHED TO COVER THE EVENT FETCH BELOW. The event that comes back is
     * autoreleased and the caller has not seen it yet, so a pool closing here would free it. I
     * tried the run loop pattern instead -- one pool per pass, released at the top of the NEXT pass,
     * which is what Apple does -- and the application dies on its first window with Unspecified
     * Application Error: it is holding something from the previous pass that this would free. So
     * the fetch stays outside, and the autoreleased events it returns are the residual leak
     * measured in the plan.
     */
    let pool = unsafe { cider_wayland_pool_push() };
    session::pump();
    // THE APPLICATION OWN DEFERRED WORK, which nothing else here runs. See the comment on the C
    // side: LibreOffice queues its wakeups on the main queue and the main queue is drained by the
    // main thread, which is this one, at the point the run loop would do it on macOS.
    // A SWITCH FOR ATTRIBUTION, not a feature: with the drain off the application stops running its
    // own deferred work, which breaks it, but it answers WHOSE allocations the idle leak is in one
    // run instead of an afternoon of guessing.
    if std::env::var_os("CIDER_WAYLAND_NO_DRAIN").is_none() {
        unsafe { cider_wayland_drain_main_queue() };
    }
    // AFTER the pump, because that is what turns compositor events into the pending state this
    // applies. Doing it here rather than in the callback is the whole point: the main loop is
    // where re-entering AppKit is safe.
    window::force_redraw_if_due();
    window::deliver_pending_configures();
    unsafe { cider_wayland_pool_pop(pool) };
    // WHETHER THE APPLICATION ASKS THIS BACKEND FOR EVENTS AT ALL is the question underneath a
    // window that never redraws, and it is not answerable from the outside: an application with
    // its own main loop and one that is wedged in this call look identical from a log of window
    // operations.
    {
        use std::sync::atomic::{AtomicU64, Ordering};
        static CALLS: AtomicU64 = AtomicU64::new(0);
        let n = CALLS.fetch_add(1, Ordering::Relaxed) + 1;
        // HOW OFTEN, not just whether. NSApplication redisplays between events, so the rate of this
        // call IS the frame rate available to the application, and a rate of a few per second looks
        // exactly like a window that does not repaint.
        if n <= 3 || n % 200 == 0 {
            // THE MASK IS THE INTERESTING PART. NSDisplay does not merely skip a queued event that
            // does not match it, it DISCARDS it, so an application asking with a narrow mask
            // silently destroys every event of any other type that arrived in the meantime.
            println!(
                "cider-wayland-appkit nextevent calls={n} mask={mask:#x} t={:.2}",
                window::elapsed()
            );
        }
    }
    let super_class = unsafe { objc::class_getSuperclass(objc::object_getClass(this)) };
    let mut sup = ObjcSuper { receiver: this, super_class };
    let sel = unsafe { objc::sel_registerName(cstr!("nextEventMatchingMask:untilDate:inMode:dequeue:")) };
    let ev = unsafe { objc::msg_send_super_event(&mut sup, sel, mask, capped_until(until), mode, dequeue) };
    // RETURNING IS THE INTERESTING PART, not being called. The call count alone cannot tell a
    // backend that is wedged inside this wait from one that returned and let the application block
    // somewhere else entirely, and those two have nothing in common as bugs.
    if std::env::var_os("CIDER_WAYLAND_TRACE_EVENTS").is_some() {
        use std::sync::atomic::{AtomicU64, Ordering};
        static RETURNS: AtomicU64 = AtomicU64::new(0);
        let n = RETURNS.fetch_add(1, Ordering::Relaxed) + 1;
        if n <= 3 || n % 500 == 0 {
            println!("cider-wayland-appkit nextevent returned={n}");
        }
    }
    // WHAT IS HANDED BACK TO THE APPLICATION, which is the last point this backend can observe.
    // Anything after this belongs to the application: LibreOffice SUBCLASSES NSApplication and
    // overrides -sendEvent:, so a trace inside Cocotron proves nothing about whether the event was
    // received. Type 100 is the idle event NSDisplay manufactures and is not worth printing.
    if !ev.is_null() && std::env::var_os("CIDER_TRACE_KEYS").is_some() {
        let t = unsafe { objc::msg_send_i64_ret(ev, objc::sel_registerName(cstr!("type"))) };
        if t != 100 {
            println!("cider-wayland-appkit delivered-event type={t}");
        }
    }
    ev
}

/// The longest this backend will let the application sleep inside one event wait, in seconds.
///
/// It has to be an upper bound rather than the wait itself: NSApplication REDISPLAYS BETWEEN
/// EVENTS, so how often the loop comes back around is how often the screen can change.
const MAX_EVENT_WAIT: f64 = 0.016;

/// Bound the date NSDisplay will wait until.
///
/// AN IDLE APPLICATION ASKS TO WAIT FOREVER. NSApplication passes distantFuture when it has
/// nothing to do, NSDisplay hands that straight to -[NSRunLoop runMode:beforeDate:], and with no
/// run loop source attached to the Wayland socket that call never returns. Nothing after it runs:
/// not the next -_displayAllWindowsIfNeeded, not the pump above. The observed shape of this was an
/// application that drew its window exactly once, flushed exactly once, and then showed that first
/// frame for the rest of its life while continuing to run.
///
/// Capping the wait turns that into a polling loop. It is not the eventual design, which is to make
/// the Wayland fd a run loop source and sleep properly; it is the smallest change that makes the
/// display cycle turn, and it is honest about costing a wakeup per frame.
fn capped_until(until: Object) -> Object {
    unsafe {
        let date_cls = objc::objc_getClass(cstr!("NSDate"));
        if date_cls.is_null() {
            return until;
        }
        // A caller that wants a SHORTER wait than the cap keeps it: taking the cap unconditionally
        // would turn every poll with a near date into a 16 ms sleep and slow down modal loops.
        if !until.is_null() {
            let remaining =
                objc::msg_send_f64_ret(until, objc::sel_registerName(cstr!("timeIntervalSinceNow")));
            if std::env::var_os("CIDER_WAYLAND_TRACE_EVENTS").is_some() {
                println!("cider-wayland-appkit until remaining={remaining}");
            }
            if remaining <= MAX_EVENT_WAIT {
                return until;
            }
        } else if std::env::var_os("CIDER_WAYLAND_TRACE_EVENTS").is_some() {
            println!("cider-wayland-appkit until=nil");
        }
        let sel = objc::sel_registerName(cstr!("dateWithTimeIntervalSinceNow:"));
        let capped = objc::msg_send_f64(date_cls, sel, MAX_EVENT_WAIT);
        if capped.is_null() { until } else { capped }
    }
}

/// -newWindowWithDelegate:, the method that makes this a window system at all.
///
/// AppKit owns the returned window: the name begins with new, so the caller has the reference and
/// releases it. Returning nil is survivable and says so in the log; AppKit reports a window it
/// could not create rather than dying inside one.
extern "C" fn display_new_window(_this: Object, _cmd: Sel, delegate: Object) -> Object {
    window::new_window(delegate)
}

/// -screens, the first abstract method AppKit demands.
///
/// THE SIZE COMES FROM wl_output NOW, and the log line says which source it used. The constant
/// remains as a fallback because wl_output is optional: a compositor can advertise none and still
/// open windows, and in that case the answer really is a guess and says so.
extern "C" fn display_screens(_this: Object, _cmd: Sel) -> Object {
    unsafe {
        let screen_cls = objc::objc_getClass(cstr!("NSScreen"));
        let array_cls = objc::objc_getClass(cstr!("NSArray"));
        if screen_cls.is_null() || array_cls.is_null() {
            println!("cider-wayland-appkit screens=FAILED reason=no-NSScreen-or-NSArray");
            return std::ptr::null_mut();
        }
        // The compositor's own answer where there is one. The fallback stays because wl_output is
        // optional and a window can be opened without it.
        let (width, height, source) = match session::output_size() {
            Some((w, h)) => (w, h, "wl_output"),
            None => (1024.0, 768.0, "provisional"),
        };
        let frame = NsRect::new(0.0, 0.0, width, height);
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
        println!(
            "cider-wayland-appkit screens=1 frame={}x{} source={source}",
            width as i32, height as i32
        );
        array
    }
}

/// -allFontFamilyNames, which AppKit asks for before any window exists.
extern "C" fn display_all_font_family_names(_this: Object, _cmd: Sel) -> Object {
    fonts::all_family_names()
}

extern "C" fn display_typefaces(_this: Object, _cmd: Sel, family: Object) -> Object {
    fonts::typefaces_for_family(family)
}

extern "C" fn display_color_with_name(_this: Object, _cmd: Sel, name: Object) -> Object {
    colors::color_with_name(name)
}

/// AppKit hands the display a colour to remember under a name. Nothing needs remembering yet: the
/// table is static, so this accepts and ignores rather than raising, which is what an override
/// with no state should do.
extern "C" fn display_add_system_color(_this: Object, _cmd: Sel, _color: Object, _name: Object) {}

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
    // The methods that needed a file of their own, plus display.rs, which holds the 18 whose
    // answer is a constant, a nil or a walk of AppKit's own state.
    let mut methods = vec![
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
            objc::MethodDef {
                sel: cstr!("allFontFamilyNames"),
                types: cstr!("@@:"),
                imp: display_all_font_family_names as *const c_void,
            },
            objc::MethodDef {
                sel: cstr!("fontTypefacesForFamilyName:"),
                types: cstr!("@@:@"),
                imp: display_typefaces as *const c_void,
            },
            objc::MethodDef {
                sel: cstr!("nextEventMatchingMask:untilDate:inMode:dequeue:"),
                types: cstr!("@@:Q@@c"),
                imp: display_next_event as *const c_void,
            },
            objc::MethodDef {
                sel: cstr!("newWindowWithDelegate:"),
                types: cstr!("@@:@"),
                imp: display_new_window as *const c_void,
            },
            objc::MethodDef {
                sel: cstr!("newPanelWithDelegate:"),
                types: cstr!("@@:@"),
                imp: display_new_window as *const c_void,
            },
            objc::MethodDef {
                sel: cstr!("colorWithName:"),
                types: cstr!("@@:@"),
                imp: display_color_with_name as *const c_void,
            },
            objc::MethodDef {
                sel: cstr!("_addSystemColor:forName:"),
                types: cstr!("v@:@@"),
                imp: display_add_system_color as *const c_void,
            },
    ];
    methods.extend(display::methods());
    let cls: Class = unsafe {
        objc::register_subclass(cstr!("NSDisplayWayland"), cstr!("NSDisplay"), &methods)
    };
    if cls.is_null() {
        println!("cider-wayland-appkit register=FAILED reason=no-NSDisplay-superclass");
        return;
    }
    println!("cider-wayland-appkit register=ok class=NSDisplayWayland");
}
