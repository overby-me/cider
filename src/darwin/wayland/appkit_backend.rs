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

/// When the last full pass of pump, drain and redraw ran, so a poll can be told there is nothing
/// new without repeating it.
static LAST_PASS: std::sync::Mutex<Option<std::time::Instant>> = std::sync::Mutex::new(None);

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
    /*
     * A POLL IS NOT A WAIT, and doing a full pass of work for one is most of what a spinning
     * application costs.
     *
     * Named with a backtrace at the point of the poll: LibreOffice runs
     *     Application::Execute -> Yield -> AquaSalInstance::DoYield -> AquaSalTimer::callTimerCallback
     *     -> Scheduler::CallbackTaskScheduling -> AquaSalInstance::AnyInput
     * and AnyInput asks for an event with a date that has ALREADY PASSED. Measured while a file
     * picker was open: nineteen thousand of those a second. The application is entitled to ask;
     * what it is not entitled to is a compositor round trip, a main queue drain and a sweep of
     * every window each time.
     *
     * So a poll that arrives within two milliseconds of the last real pass gets the queue as it
     * already is. Anything that arrives in the meantime is picked up by the next pass, which is at
     * most two milliseconds later, and a caller that actually WAITS is never rate limited.
     */
    let now = std::time::Instant::now();
    let polling = if until.is_null() {
        false
    } else {
        let remaining = unsafe {
            objc::msg_send_f64_ret(until, objc::sel_registerName(cstr!("timeIntervalSinceNow")))
        };
        remaining <= 0.0
    };
    let skip_work = polling
        && LAST_PASS
            .lock()
            .ok()
            .and_then(|last| *last)
            .is_some_and(|last| now.duration_since(last).as_micros() < 2000);
    if skip_work {
        let super_class = unsafe { objc::class_getSuperclass(objc::object_getClass(this)) };
        let mut sup = ObjcSuper { receiver: this, super_class };
        let sel = unsafe {
            objc::sel_registerName(cstr!("nextEventMatchingMask:untilDate:inMode:dequeue:"))
        };
        return unsafe { objc::msg_send_super_event(&mut sup, sel, mask, until, mode, dequeue) };
    }
    if let Ok(mut last) = LAST_PASS.lock() {
        *last = Some(now);
    }
    let pool = unsafe { cider_wayland_pool_push() };
    session::pump();
    // THE APPLICATION OWN DEFERRED WORK, which nothing else here runs. See the comment on the C
    // side: LibreOffice queues its wakeups on the main queue and the main queue is drained by the
    // main thread, which is this one, at the point the run loop would do it on macOS.
    // A SWITCH FOR ATTRIBUTION, not a feature: with the drain off the application stops running its
    // own deferred work, which breaks it, but it answers WHOSE allocations the idle leak is in one
    // run instead of an afternoon of guessing.
    if !crate::env_flag!("CIDER_WAYLAND_NO_DRAIN") {
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
    if crate::env_flag!("CIDER_WAYLAND_TRACE_EVENTS") {
        use std::sync::atomic::{AtomicU64, Ordering};
        static RETURNS: AtomicU64 = AtomicU64::new(0);
        let n = RETURNS.fetch_add(1, Ordering::Relaxed) + 1;
        if n <= 3 || n % 500 == 0 {
            println!("cider-wayland-appkit nextevent returned={n}");
        }
    }
    /*
     * AND IF THERE WAS NOTHING, SLEEP UNTIL THERE MIGHT BE, which is the difference between an
     * application waiting and an application spinning.
     *
     * MEASURED, with the counter above: nineteen thousand one hundred and eighty nine calls a
     * second while a file picker sat on screen doing nothing, and the guest burning 58 percent of a
     * core. Raising the wait cap from 16 ms to 50 changed that by three percent, which is the proof
     * that nothing here was ever waiting: -[NSApplication nextEventMatchingMask:] loops while the
     * result is nil and the date is in the future, and cocotron NSRunLoop -runMode:beforeDate:
     * returns at once when there is no input source to wait on. So the wait has to be here, on the
     * one descriptor that can actually deliver something.
     *
     * Type 100 is the idle event NSDisplay manufactures when its queue is empty, which
     * NSApplication turns straight back into nil, so it counts as nothing.
     */
    let empty = if ev.is_null() {
        true
    } else {
        unsafe { objc::msg_send_i64_ret(ev, objc::sel_registerName(cstr!("type"))) == 100 }
    };
    if empty {
        wait_for_something(until);
    }
    /* WHICH OF THE TWO THIS IS, counted rather than argued: a loop that spins because there is
     * always an event to hand back is a different bug from one that spins because the wait does not
     * wait, and the counts separate them in one run. */
    if crate::env_flag!("CIDER_WAYLAND_TRACE_SPIN") {
        use std::sync::atomic::{AtomicU64, Ordering};
        static EMPTY: AtomicU64 = AtomicU64::new(0);
        static FULL: AtomicU64 = AtomicU64::new(0);
        static LAST_TYPE: AtomicU64 = AtomicU64::new(999);
        if empty {
            EMPTY.fetch_add(1, Ordering::Relaxed);
        } else {
            let t = unsafe { objc::msg_send_i64_ret(ev, objc::sel_registerName(cstr!("type"))) };
            LAST_TYPE.store(t as u64, Ordering::Relaxed);
            let n = FULL.fetch_add(1, Ordering::Relaxed) + 1;
            if n % 2000 == 0 {
                println!(
                    "cider-wayland-appkit spin empty={} full={n} lasttype={t}",
                    EMPTY.load(Ordering::Relaxed)
                );
            }
        }
    }
    // WHAT IS HANDED BACK TO THE APPLICATION, which is the last point this backend can observe.
    // Anything after this belongs to the application: LibreOffice SUBCLASSES NSApplication and
    // overrides -sendEvent:, so a trace inside Cocotron proves nothing about whether the event was
    // received. Type 100 is the idle event NSDisplay manufactures and is not worth printing.
    if !ev.is_null() && crate::env_flag!("CIDER_TRACE_KEYS") {
        let t = unsafe { objc::msg_send_i64_ret(ev, objc::sel_registerName(cstr!("type"))) };
        if t != 100 {
            println!("cider-wayland-appkit delivered-event type={t}");
        }
    }
    ev
}

/// The frames above here, resolved with dladdr, because a spin is always about the caller.
pub fn print_backtrace(why: &str) {
    use std::os::raw::{c_char, c_int};
    unsafe extern "C" {
        fn backtrace(buffer: *mut c_void, size: c_int) -> c_int;
        fn dladdr(addr: *const c_void, info: *mut DlInfo) -> c_int;
    }
    #[repr(C)]
    struct DlInfo {
        fname: *const c_char,
        fbase: *mut c_void,
        sname: *const c_char,
        saddr: *mut c_void,
    }
    let mut frames: [*mut c_void; 24] = [std::ptr::null_mut(); 24];
    let count = unsafe { backtrace(frames.as_mut_ptr() as *mut c_void, 24) };
    println!("cider-wayland-appkit backtrace why={why} frames={count}");
    for (i, frame) in frames.iter().enumerate().take(count.max(0) as usize) {
        let mut info = DlInfo {
            fname: std::ptr::null(),
            fbase: std::ptr::null_mut(),
            sname: std::ptr::null(),
            saddr: std::ptr::null_mut(),
        };
        let ok = unsafe { dladdr(*frame as *const c_void, &mut info) };
        let name = if ok != 0 && !info.sname.is_null() {
            unsafe { std::ffi::CStr::from_ptr(info.sname) }.to_string_lossy().into_owned()
        } else {
            format!("{:p}", *frame)
        };
        println!("cider-wayland-appkit   #{i} {name}");
    }
}

/// Sleep on the compositor socket until it has something, the deadline passes, or the cap expires.
///
/// The waker thread watches the same descriptor and pokes the main run loop; this is the main
/// thread doing the same watch for itself, which is what it must do when the caller has asked for
/// an event and there is none. Nothing is READ here -- reading is the pump's job, under the
/// prepare_read protocol -- so a level triggered poll that returns immediately next pass is
/// correct rather than a busy loop: the pump at the top of the next call consumes what arrived.
fn wait_for_something(until: Object) {
    use std::os::raw::c_int;
    unsafe extern "C" {
        fn poll(fds: *mut PollFd, nfds: u64, timeout: c_int) -> c_int;
    }
    #[repr(C)]
    struct PollFd {
        fd: c_int,
        events: i16,
        revents: i16,
    }
    const POLLIN: i16 = 0x0001;

    let mut budget = max_event_wait();
    if !until.is_null() {
        let remaining = unsafe {
            objc::msg_send_f64_ret(until, objc::sel_registerName(cstr!("timeIntervalSinceNow")))
        };
        if remaining <= 0.0 {
            if crate::env_flag!("CIDER_WAYLAND_TRACE_SPIN") {
                use std::sync::atomic::{AtomicU64, Ordering};
                static PAST: AtomicU64 = AtomicU64::new(0);
                let n = PAST.fetch_add(1, Ordering::Relaxed) + 1;
                if n % 2000 == 0 {
                    println!("cider-wayland-appkit wait=none n={n} remaining={remaining}");
                }
                /* AND WHO IS ASKING. A caller that passes a date already in the past is not waiting
                 * for anything, it is polling, and the only thing that can explain a poll nineteen
                 * thousand times a second is the loop above it. Named once, with dladdr, the same
                 * recipe that named the hide chain. */
                if n == 1 {
                    print_backtrace("poll-with-no-wait");
                }
            }
            return;
        }
        budget = budget.min(remaining);
    }
    let ms = (budget * 1000.0).round() as c_int;
    if crate::env_flag!("CIDER_WAYLAND_TRACE_SPIN") {
        use std::sync::atomic::{AtomicU64, Ordering};
        static N: AtomicU64 = AtomicU64::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed) + 1;
        if n % 2000 == 0 {
            println!("cider-wayland-appkit wait n={n} ms={ms} budget={budget}");
        }
    }
    if ms <= 0 {
        return;
    }
    // FLUSH BEFORE SLEEPING. Anything this pass queued is still in the outgoing buffer, and going
    // to sleep on the answer to a request that was never sent is how a client hangs.
    session::flush();
    let fd = unsafe { wl::cider_wl_display_get_fd(session::display()) };
    if fd < 0 {
        return;
    }
    let mut fds = PollFd { fd, events: POLLIN, revents: 0 };
    unsafe { poll(&mut fds as *mut PollFd, 1, ms) };
}

/// The longest this backend will let the application sleep inside one event wait, in seconds.
///
/// It has to be an upper bound rather than the wait itself: NSApplication REDISPLAYS BETWEEN
/// EVENTS, so how often the loop comes back around is how often the screen can change.
const MAX_EVENT_WAIT_DEFAULT: f64 = 0.016;

/// The same, overridable for a MEASUREMENT rather than for a user to tune.
///
/// How often the loop comes back around is how often the screen can change AND how much CPU an
/// application burns while it waits, and those pull in opposite directions. The number that settles
/// it is measured with CIDER_WAYLAND_EVENT_WAIT set to each candidate, not argued about.
fn max_event_wait() -> f64 {
    static WAIT: std::sync::OnceLock<f64> = std::sync::OnceLock::new();
    *WAIT.get_or_init(|| {
        std::env::var("CIDER_WAYLAND_EVENT_WAIT")
            .ok()
            .and_then(|v| v.parse::<f64>().ok())
            .filter(|v| *v > 0.0 && *v < 1.0)
            .unwrap_or(MAX_EVENT_WAIT_DEFAULT)
    })
}

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
            if crate::env_flag!("CIDER_WAYLAND_TRACE_EVENTS") {
                println!("cider-wayland-appkit until remaining={remaining}");
            }
            if remaining <= max_event_wait() {
                return until;
            }
        } else if crate::env_flag!("CIDER_WAYLAND_TRACE_EVENTS") {
            println!("cider-wayland-appkit until=nil");
        }
        let sel = objc::sel_registerName(cstr!("dateWithTimeIntervalSinceNow:"));
        let capped = objc::msg_send_f64(date_cls, sel, max_event_wait());
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
/// THE ANSWER IS CACHED, and that is a performance fix rather than a tidy up.
///
/// -[NSWindow _makeSureIsOnAScreen] asks for the screens ONCE PER VISIBLE WINDOW, and cocotron runs
/// that sweep over every window on every fetch of every event. LibreOffice has forty odd windows,
/// so this was allocating an NSScreen and an NSArray, and PRINTING A LINE, a couple of thousand
/// times a second. Measured with a file picker open: the guest burned 58 percent of a core doing
/// nothing, and the log filled with identical screens=1 lines.
///
/// The screen only changes when the compositor says so, so the array is built once per size and
/// handed back retained. The line is printed when the value CHANGES, which is the only time it
/// carries information.
static SCREENS: std::sync::Mutex<Option<(f64, f64, usize)>> = std::sync::Mutex::new(None);

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
        if let Ok(cache) = SCREENS.lock() {
            if let Some((cw, ch, array)) = *cache {
                if cw == width && ch == height && array != 0 {
                    return array as Object;
                }
            }
        }
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
        // RETAINED, because it outlives the autorelease pool of whichever event fetch happened to
        // build it and is handed to every later caller.
        let array = objc::msg_send0(array, objc::sel_registerName(cstr!("retain")));
        if let Ok(mut cache) = SCREENS.lock() {
            *cache = Some((width, height, array as usize));
        }
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
    // CIDER_TRACE_FONTS says which family was asked for and how many faces went back, printed
    // BEFORE and AFTER the work so a fault inside it is visible as a line with no answer.
    if crate::env_flag!("CIDER_TRACE_FONTS") {
        let name = unsafe {
            let raw = crate::objc::msg_send0(
                family,
                crate::objc::sel_registerName(cstr!("UTF8String")),
            ) as *const std::os::raw::c_char;
            if raw.is_null() {
                "<nil>".to_string()
            } else {
                std::ffi::CStr::from_ptr(raw).to_string_lossy().into_owned()
            }
        };
        println!("cider-wayland-fonts typefaces family={name} asking");
        let out = fonts::typefaces_for_family(family);
        let n = if out.is_null() {
            -1
        } else {
            unsafe {
                crate::objc::msg_send0(out, crate::objc::sel_registerName(cstr!("count"))) as isize
            }
        };
        println!("cider-wayland-fonts typefaces family={name} faces={n}");
        return out;
    }
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
/// The height of the title bar this backend draws, in points. Apple uses 22 at 1x for a document
/// window, and the traffic lights are sized and spaced from it.
pub const TITLE_BAR_HEIGHT: f64 = 22.0;

/// NSTitledWindowMask.
const NS_TITLED_WINDOW_MASK: usize = 1;

extern "C" fn display_inset_rect(_this: Object, _cmd: Sel, frame: NsRect, style: usize) -> NsRect {
    /*
     * A TITLED WINDOW HAS A TITLE BAR, and on this backend it is ours to draw.
     *
     * Wayland gives a client a surface and nothing else; a compositor decorates only if the client
     * asks through the decoration protocol, and what it draws is the DESKTOP style rather than the
     * application. For an application whose whole point is to look like macOS, the honest answer is
     * to draw the macOS one, which is what NSThemeFrame now does -- see the patch that goes with
     * this. So the content rect is the frame minus that bar, exactly as it is on Apple systems, and
     * the bar sits above the content.
     */
    if style & NS_TITLED_WINDOW_MASK == 0 {
        return frame;
    }
    NsRect {
        origin: frame.origin,
        size: objc::NsSize {
            width: frame.size.width,
            height: (frame.size.height - TITLE_BAR_HEIGHT).max(0.0),
        },
    }
}

extern "C" fn display_outset_rect(_this: Object, _cmd: Sel, frame: NsRect, style: usize) -> NsRect {
    if style & NS_TITLED_WINDOW_MASK == 0 {
        return frame;
    }
    NsRect {
        origin: frame.origin,
        size: objc::NsSize {
            width: frame.size.width,
            height: frame.size.height + TITLE_BAR_HEIGHT,
        },
    }
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
