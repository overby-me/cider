// CGWindowWayland: the class -newWindowWithDelegate: hands back.
//
// AppKit's NSWindow keeps a _platformWindow and sends it 16 distinct selectors (counted across
// AppKit/*.m). CGWindow declares 40, of which the rest are reached from elsewhere or not at all in
// the paths this rung exercises. Every one of the 40 is defined here rather than only the 16,
// BECAUSE A MISSING ONE IS A TERMINATED PROCESS: CGWindow's defaults raise, so an override that
// does nothing is strictly better than no override, and it is visible in the log rather than fatal.
//
// The window IS an xdg_toplevel with a wl_shm buffer, which the wayland probe already proved end
// to end: configure handshake, then pixels the compositor reports presenting. Nothing new is being
// tried here; the same sequence is being driven by AppKit instead of by a main().
//
// PIXELS ARE A FLAT COLOUR FOR NOW, written through the file rather than a mapping. Real drawing
// needs the surface handed to an O2Context, which is the next rung; a window that shows the wrong
// contents is visible and debuggable, a window that never maps is not.
use std::os::raw::{c_char, c_int, c_void};
use std::sync::atomic::{AtomicI64, AtomicIsize, AtomicUsize, Ordering};

use crate::cstr;
use crate::objc::{self, NsPoint, NsRect, Object, ObjcBool, Sel, NO, YES};
use crate::session;
use crate::wl;

unsafe extern "C" {
    /// The write watchpoint, in C because the Darwin signal structures are correct there.
    fn cider_wayland_watch_begin(base: *mut c_void, len: usize);
}

/// Byte offset of the state pointer inside an instance, learned at registration. -1 until then,
/// which is the only value that can mean "not registered" for an offset.
static STATE_OFFSET: AtomicIsize = AtomicIsize::new(-1);

/// Window numbers must be unique and nonzero: AppKit uses them as identity, and 0 reads as "no
/// window" in several of its own comparisons.
static NEXT_WINDOW_NUMBER: AtomicI64 = AtomicI64::new(1);

/// The most recently created TITLED toplevel, used as the parent for borderless ones. A pointer
/// held as an integer because a raw pointer is not Sync and this is only ever read back as one.
static LAST_TITLED_TOPLEVEL: AtomicUsize = AtomicUsize::new(0);

/// The xdg_surface of that same window, which is what a POPUP has to be parented to, plus the
/// frame it occupies so an anchor rectangle can be expressed in its coordinates.
static PARENT_XDG_SURFACE: AtomicUsize = AtomicUsize::new(0);
static PARENT_TOP: AtomicI64 = AtomicI64::new(0);
static PARENT_LEFT: AtomicI64 = AtomicI64::new(0);

/// Everything one window owns. Boxed and pointed to by the instance's single ivar, so the ObjC
/// object stays one word wider than CGWindow and all the real state has a Rust type.
pub struct WindowState {
    pub surface: *mut wl::WlSurface,
    pub xdg: *mut wl::XdgSurface,
    pub toplevel: *mut wl::XdgToplevel,
    pub delegate: Object,
    /// The ObjC instance this state belongs to. A listener is handed the Rust state and the
    /// delegate expects the CGWindow, so one of the two has to point at the other.
    pub owner: Object,
    pub frame: NsRect,
    pub configured: bool,
    pub mapped: bool,
    pub style_mask: usize,
    pub level: c_int,
    pub miniaturized: bool,
    /// Nesting count, not a flag: AppKit disables and enables around nested drawing, and treating
    /// it as a boolean re-enables one level too early.
    pub flush_disabled: i32,
    pub number: i64,
    pub backing: Option<std::fs::File>,
    pub buffer: *mut wl::WlBuffer,
    pub buffer_w: i32,
    pub buffer_h: i32,
    /// The size of the BITMAP, which is not always the size of the buffer.
    ///
    /// A window with a minimum size cannot obey a compositor that configures it smaller, and
    /// LibreOffice has several: tiled to 700x600, the Start Center kept a 700x733 frame. Drawing a
    /// 733 tall window into a 600 tall bitmap loses the top 133 rows, because the context is
    /// unflipped and anchors at the bottom, and the top of a window is its title bar and its menu
    /// bar. So the bitmap is as large as the application insists on and the wl_buffer stays the
    /// size the compositor asked for, taken from the START of the same pages, which is the top of
    /// the window. What overflows is the bottom, which is a scroll area rather than the controls.
    pub draw_w: i32,
    pub draw_h: i32,
    /// How much empty surface surrounds the window, for the shadow. Zero for a window that has
    /// none, which is every popup and every undecorated one.
    pub margin: i32,
    /// The frame the application refuses to shrink below, 0 when it has never refused one.
    pub insist_w: i32,
    pub insist_h: i32,
    /// The shm pages, mapped. AppKit DRAWS DIRECTLY INTO THESE: the O2Surface is built over this
    /// pointer, so there is no copy between what was drawn and what the compositor reads.
    pub pixels: *mut u8,
    pub map_len: usize,
    /// The O2Context, retained. AppKit asks for it repeatedly and expects the same one back.
    pub context: Object,
    /// Whether the drawn-pixel count has been printed. Once is enough: it answers a question about
    /// whether drawing works at all, not one about every frame.
    pub reported_drawn: bool,
    /// When this window last wrote a dump, so the rate limit has something to compare against.
    pub last_dump: Option<std::time::Instant>,
    /// How many times this window has been committed to the compositor.
    pub presents: u64,
    /// How many times AppKit has asked this window to flush, presented or not.
    pub flushes: u64,
    /// A size the compositor asked for, not yet given to AppKit. Applied by the main loop.
    pub pending_size: Option<(i32, i32)>,
    /// THE SIZE THE COMPOSITOR HAS ALREADY DECIDED, once it has decided one. A compositor with no
    /// opinion sends 0x0 and never sets this, and then the application sizes its own windows as it
    /// likes. A tiling one sets it for every toplevel, and then it is binding.
    pub configured_size: Option<(i32, i32)>,
    /// Whether the one-row NUDGE has been spent on this window. See the repeat block: an
    /// application that ignores a resize to the size it already has needs to be told a DIFFERENT
    /// one before it will lay out again.
    pub nudged: bool,
    /// How many more frame changes to deliver to make the application believe a resize happened:
    /// two means one row short and then the true size, which is what a drag of a window edge looks
    /// like and is the only thing this application acts on.
    pub nudge_pending: u8,
    /// The popup role, when this window is a menu or a tooltip rather than a document window.
    pub popup: *mut wl::XdgPopup,
    /// The title AppKit gave this window, which it may have given before the toplevel existed.
    pub title: Option<std::ffi::CString>,
    /// Whether AppKit still has to be told to draw the whole of this window.
    pub needs_full_display: bool,
    /// KEEP REDRAWING FOR A MOMENT AFTER A RESIZE. One forced display is not enough: the
    /// application relays out its own widgets on ITS main queue, so a display issued the instant
    /// the size changes paints the OLD layout and the new area is never covered. Measured: a
    /// freshly opened document window painted its original 656 rows into an 1388 tall surface and
    /// left the rest black, while the run before it painted the same window in full. Until this
    /// instant passes, every pump marks the window dirty and displays it again.
    pub redraw_until: Option<std::time::Instant>,
    pub last_forced_display: Option<std::time::Instant>,
    /// Whether AppKit has actually SHOWN this window. A Mach-O application creates windows long
    /// before it shows them, and one that was never ordered front must not appear.
    pub visible: bool,
    /// Whether THIS backend hid the window because the application was deactivated, which is the
    /// only thing application activation is allowed to undo.
    pub hidden_by_deactivation: bool,
    /// Whether the window is maximised, so the zoom button can toggle rather than only set.
    pub maximized: bool,
    /// A counter, not a handle: xdg_popup.reposition takes a token the compositor echoes back so a
    /// client can tell which request a configure belongs to. Nothing here waits on one yet, but the
    /// protocol wants it to change per request.
    pub reposition_token: u32,
}

impl WindowState {
    fn new() -> Self {
        WindowState {
            surface: std::ptr::null_mut(),
            xdg: std::ptr::null_mut(),
            toplevel: std::ptr::null_mut(),
            delegate: std::ptr::null_mut(),
            owner: std::ptr::null_mut(),
            frame: NsRect::new(0.0, 0.0, 512.0, 384.0),
            configured: false,
            mapped: false,
            style_mask: 0,
            level: 0,
            miniaturized: false,
            flush_disabled: 0,
            number: NEXT_WINDOW_NUMBER.fetch_add(1, Ordering::Relaxed),
            backing: None,
            buffer: std::ptr::null_mut(),
            buffer_w: 0,
            buffer_h: 0,
            draw_w: 0,
            draw_h: 0,
            margin: 0,
            insist_w: 0,
            insist_h: 0,
            pixels: std::ptr::null_mut(),
            map_len: 0,
            context: std::ptr::null_mut(),
            reported_drawn: false,
            last_dump: None,
            presents: 0,
            flushes: 0,
            pending_size: None,
            configured_size: None,
            nudged: false,
            nudge_pending: 0,
            popup: std::ptr::null_mut(),
            title: None,
            needs_full_display: true,
            redraw_until: None,
            last_forced_display: None,
            visible: false,
            hidden_by_deactivation: false,
            maximized: false,
            reposition_token: 0,
        }
    }
}

/// The state pointer for an instance, or None before -initWithDelegate: has run.
///
/// # Safety
/// `this` must be an instance of the registered class.
unsafe fn state<'a>(this: Object) -> Option<&'a mut WindowState> {
    let off = STATE_OFFSET.load(Ordering::Acquire);
    if this.is_null() || off < 0 {
        return None;
    }
    unsafe {
        let slot = (this as *mut u8).offset(off) as *mut *mut WindowState;
        (*slot).as_mut()
    }
}

/// The compositor has offered a configuration. Acknowledging is not optional: until the serial is
/// acked the surface is not considered configured, and any buffer attached before that is a
/// protocol error rather than a picture.
extern "C" fn on_configure(data: *mut c_void, surface: *mut wl::XdgSurface, serial: u32) {
    unsafe {
        wl::cider_xdg_surface_ack_configure(surface, serial);
        if let Some(st) = (data as *mut WindowState).as_mut() {
            st.configured = true;
        }
    }
}

/// Fn pointers are Sync, so the listener can be a static and outlive every call, which is what
/// libwayland requires: it keeps the pointer, it does not copy the struct.
static XDG_LISTENER: wl::XdgSurfaceListener = wl::XdgSurfaceListener { configure: on_configure };

/// The compositor's opinion about the window's size and state.
///
/// ZERO MEANS THE CLIENT DECIDES, which is the protocol and not a missing value: a compositor that
/// has no opinion sends 0x0, and treating that as a resize to nothing would collapse the window.
extern "C" fn on_toplevel_configure(
    data: *mut c_void,
    _toplevel: *mut wl::XdgToplevel,
    width: i32,
    height: i32,
    _states: *mut c_void,
) {
    if width <= 0 || height <= 0 {
        return;
    }
    let Some(st) = (unsafe { (data as *mut WindowState).as_mut() }) else { return };
    if st.frame.size.width as i32 == width && st.frame.size.height as i32 == height {
        return;
    }
    /*
     * RECORD, DO NOT APPLY. This runs inside a libwayland callback, which is reached from the
     * middle of the event pump, and both of the obvious things to do here are wrong.
     *
     * Freeing the backing frees the O2Context AppKit is holding, so the next draw goes through a
     * surface that was unmapped underneath it. Delivering the frame change re-enters AppKit from a
     * compositor callback, which killed the process on a real compositor while a headless one that
     * never resizes looked perfectly healthy.
     *
     * NOT APPLYING IT AT ALL IS ALSO WRONG, and that is the version this replaces: the buffer
     * followed the compositor while NSWindow kept its original frame, so AppKit drew a large
     * window into a small surface. weston headless never resizes, so it never showed; a tiling
     * compositor resizes every window and LibreOffice died there after a dozen windows.
     *
     * So the size is remembered and applied by the main loop, where nothing is mid-draw and
     * re-entering AppKit is exactly what is supposed to happen.
     */
    st.pending_size = Some((width, height));
    if crate::env_flag!("CIDER_WAYLAND_TRACE_RESIZE") {
        println!("cider-wayland-window configured number={} size={width}x{height}", st.number);
    }
}

/// Apply the sizes compositors asked for, from the MAIN LOOP rather than from a callback.
///
/// Called once per turn of the event pump. Everything here is what -on_toplevel_configure
/// deliberately does not do: change the frame AppKit sees, and tell AppKit it changed.
pub fn deliver_pending_configures() {
    /*
     * THE FAST PATH IS THE COMMON ONE, and it used to allocate.
     *
     * This runs on EVERY fetch of EVERY event, which under a modal loop is sixty times a second
     * forever, and almost every one of those passes has nothing to do: no compositor resize
     * waiting, no forced redraw due. It still cloned the window list, which is a heap allocation
     * per pass, and read the clock once per WINDOW, and LibreOffice has forty of them. Both showed
     * in the profile of an idle file picker: malloc and clock_gettime near the top, under
     * deliver_pending_configures.
     *
     * So the list is scanned under the lock first, allocating nothing, and the work only starts if
     * some window actually has some.
     */
    let anything = match WINDOWS.lock() {
        Ok(list) => list.iter().any(|&p| {
            unsafe { (p as *mut WindowState).as_ref() }.is_some_and(|st| {
                st.pending_size.is_some() || st.needs_full_display || st.redraw_until.is_some()
            })
        }),
        Err(_) => return,
    };
    if !anything {
        return;
    }
    let pending: Vec<usize> = match WINDOWS.lock() {
        Ok(list) => list.clone(),
        Err(_) => return,
    };
    for p in pending.iter().copied() {
        let st = match unsafe { (p as *mut WindowState).as_mut() } {
            Some(st) => st,
            None => continue,
        };
        /*
         * ASK APPKIT TO DRAW, because nothing else is going to.
         *
         * THIS IS THE DIFFERENCE BETWEEN X11 AND WAYLAND, and it is not a small one. X sends an
         * Expose event whenever a window needs its contents, and the X11 backend turns that into
         * drawing. WAYLAND HAS NO EXPOSE: a client owns its buffer and is expected to know when to
         * paint. A backend ported from the X11 one therefore maps windows that AppKit never draws
         * into, and they stay exactly as the backend cleared them.
         *
         * Measured before fixing: three of LibreOffice child windows contained ONE unique colour
         * across every pixel, which was the clear value, and they appeared as flat rectangles over
         * the document, over the sidebar and through the middle of the page.
         *
         * Done from the main loop rather than at map time, for the same reason the configure is:
         * -display draws immediately, and calling it from inside a compositor callback re-enters
         * AppKit at a moment of its choosing rather than ours.
         */
        let now = std::time::Instant::now();
        // REPEAT UNTIL IT IS ACTUALLY PAINTED, not for a fixed number of tries. The application
        // may be inside its own modal loop when the compositor resizes it -- which is exactly what
        // happens to a document window opened from a file dialog -- and a notification delivered
        // then changes nothing. So the condition to stop is the bottom of the window being painted,
        // with a deadline so a window that is legitimately dark at the bottom cannot spin forever.
        /*
         * A NUDGE IS OWED WHENEVER THE APPLICATION ARGUED, and that is a different signal from the
         * bottom of the window being unpainted.
         *
         * bottom_row_is_clear only sees a window the application never painted at all. LibreOffice
         * paints: it lays its content out for the size IT wanted, fills the rest with its own grey
         * and stops. A document opened from the file picker into a tiled slot came up with its find
         * bar across the middle of the window and grey below it, and every check said the window
         * was fine -- the frame was 845x1388, the content view was 845x1338, the pixels were drawn.
         *
         * What is known at the moment of the argument is that the application asked for a size the
         * compositor will not give it. That is the signal, and set_frame records it.
         */
        let nudge_owed = st.nudge_pending > 0
            && st
                .last_forced_display
                .is_none_or(|prev| now.duration_since(prev).as_millis() >= 150);
        let repeat_due = nudge_owed
            || match (st.redraw_until, st.last_forced_display) {
                (Some(until), last) if now < until => {
                    last.is_none_or(|prev| now.duration_since(prev).as_millis() >= 150)
                        && bottom_row_is_clear(st)
                }
                _ => false,
            };
        if (st.needs_full_display || repeat_due) && !st.delegate.is_null() && st.mapped {
            st.needs_full_display = false;
            st.last_forced_display = Some(now);
            /*
             * AND SAY THE SIZE AGAIN, because the first time nobody may have been listening.
             *
             * NSWindow turns this into NSWindowDidResizeNotification, and an application learns its
             * new size from that: LibreOffice recomputes its frame geometry there and lays its
             * widgets out again. A window that is resized THE INSTANT IT MAPS -- which is what a
             * tiling compositor does to every new window -- can be handed that notification before
             * the application has finished wiring the window up, and then nothing ever tells it
             * again.
             *
             * Measured: a freshly opened document laid its widgets out for the 656 rows it was
             * created with and left the rest of an 1388 tall surface black, with its status bar
             * stranded in the middle of the window, while the FIRST document window in the same run
             * relaid out correctly because its resize came seconds after it was set up.
             *
             * Repeating a configure is ordinary on Wayland and the size is unchanged, so an
             * application that already knows does nothing with it.
             */
            if repeat_due {
                /*
                 * AND THE FIRST ONE IS A ROW SHORT, deliberately.
                 *
                 * Measured: repeating the SAME size changes nothing, a hundred times over six
                 * seconds, but a real compositor resize to a DIFFERENT size makes the window lay
                 * out correctly at once -- docs/wayland-open-two-documents.png is the before and
                 * the after. So the application ignores a resize to the size it believes it
                 * already has, and the only thing that reaches it is a change.
                 *
                 * One row, once, then the true size on the next pass a sixth of a second later.
                 * This is what dragging a window edge by one pixel would send, and it is the whole
                 * difference between a document window laid out for the size it was CREATED with
                 * and one laid out for the size it actually has.
                 */
                let mut frame = st.frame;
                if st.nudge_pending > 1 {
                    frame.size.height = (frame.size.height - 1.0).max(1.0);
                } else if !st.nudged && st.nudge_pending == 0 {
                    st.nudged = true;
                    frame.size.height = (frame.size.height - 1.0).max(1.0);
                }
                st.nudge_pending = st.nudge_pending.saturating_sub(1);
                unsafe {
                    let sel = objc::sel_registerName(cstr!("platformWindow:frameChanged:didSize:"));
                    objc::msg_send_frame_changed(st.delegate, sel, st.owner, frame, objc::YES);
                }
            }
            let delegate = st.delegate;
            let number = st.number;
            unsafe {
                // MARK IT DIRTY FIRST. -display draws what needs displaying, and a window that
                // nobody has invalidated needs nothing: the call returns having drawn not one
                // pixel. The content view is what owns the area, so that is what is marked.
                let content =
                    objc::msg_send0(delegate, objc::sel_registerName(cstr!("contentView")));
                if !content.is_null() {
                    objc::msg_send_bool(
                        content,
                        objc::sel_registerName(cstr!("setNeedsDisplay:")),
                        objc::YES,
                    );
                }
                objc::msg_send0(delegate, objc::sel_registerName(cstr!("display")));
                /*
                 * AND PRESENT IT. -display draws into the pages the compositor maps, but a
                 * compositor does not re-read a surface it was not told about: without an attach,
                 * a damage and a commit, the drawing is invisible. AppKit flushes after its own
                 * display cycle and this one is ours, so the flush is ours to do.
                 *
                 * Measured before adding it: the application drawRect ran twenty times against a
                 * forced display and the frame on screen never changed once.
                 */
                present(st);
                if crate::env_flag!("CIDER_WAYLAND_TRACE_DISPLAY") {
                    println!(
                        "cider-wayland-window display-forced number={number} content={}",
                        if content.is_null() { "nil" } else { "yes" }
                    );
                }
            }
        }
    }
    for p in pending {
        let st = match unsafe { (p as *mut WindowState).as_mut() } {
            Some(st) => st,
            None => continue,
        };
        let Some((width, height)) = st.pending_size.take() else { continue };
        if st.frame.size.width as i32 == width && st.frame.size.height as i32 == height {
            continue;
        }
        st.frame.size.width = width as f64;
        st.frame.size.height = height as f64;
        /*
         * AND MOVE IT TO WHERE THE COMPOSITOR PUT IT, which is the top left corner.
         *
         * A RESIZE THAT KEEPS THE OLD ORIGIN CORRUPTS EVERY POPUP. Wayland never tells a client
         * where its window is, so the origin here is whatever the application guessed at creation;
         * growing the size while keeping that guess moves the window TOP by the difference, and the
         * top is what fill_positioner subtracts to turn a screen coordinate into a parent local
         * one. Measured on a tiling compositor that sized the document to the whole output: the
         * frame stayed at 128,668 while the size became 1690x1388, so the parent top read 2056 on a
         * 1388 tall screen and the File menu, asked for at screen y 935, was placed 668 pixels too
         * low, at the bottom left corner instead of under its title.
         *
         * Treating a resized toplevel as sitting at the screen origin is exact when the compositor
         * gave it the whole output, and for a window placed anywhere else it still leaves the
         * offsets right RELATIVE TO THE WINDOW, which is the space an xdg_positioner anchor rect is
         * measured in anyway.
         */
        if st.popup.is_null() && !st.toplevel.is_null() {
            if let Some((_, screen_h)) = session::output_size() {
                st.frame.origin.x = 0.0;
                st.frame.origin.y = screen_h - height as f64;
            }
        }
        st.configured_size = Some((width, height));
        // The drawn report is reset so the new size is measured rather than reported from the
        // previous buffer.
        st.reported_drawn = false;
        // REBUILD BEFORE NOTIFYING. AppKit draws in response to a frame change, and it asks for a
        // graphics context when it does; if the surface is still the old size at that moment it
        // draws a large window into a small one and the result is clipped rather than laid out.
        ensure_backing(st);
        println!(
            "cider-wayland-window resized number={} size={width}x{height}",
            st.number
        );
        let has_delegate = !st.delegate.is_null();
        if has_delegate {
            unsafe {
                let sel = objc::sel_registerName(cstr!("platformWindow:frameChanged:didSize:"));
                objc::msg_send_frame_changed(st.delegate, sel, st.owner, st.frame, objc::YES);
                /*
                 * AND THEN ASK WHAT IT DID WITH IT, because a window with a minimum size does not
                 * come back to say no. NSWindow clamps inside -setFrame: and never calls the
                 * platform window again, so the only way to learn that 700x600 became 700x733 is to
                 * read the frame afterwards. When it is larger, the bitmap grows to hold the whole
                 * window and the buffer stays the size the compositor asked for; see draw_w.
                 */
                let actual =
                    objc::msg_send_rect_ret(st.delegate, objc::sel_registerName(cstr!("frame")));
                let aw = actual.size.width as i32;
                let ah = actual.size.height as i32;
                if aw > width || ah > height {
                    st.insist_w = aw.max(width);
                    st.insist_h = ah.max(height);
                    ensure_backing(st);
                    st.needs_full_display = true;
                }
            }
        }
        /*
         * WHAT THE APPLICATION MADE OF THE SIZE WE JUST GAVE IT. A window whose content view ends up
         * taller than the surface draws its bottom row of controls off the end of the buffer, which
         * looks like a clipped dialog and not like a geometry bug, so the two rects are worth having
         * side by side rather than inferred from a screenshot.
         */
        if has_delegate && crate::env_flag!("CIDER_WAYLAND_TRACE_GEOMETRY") {
            // THE DELEGATE IS THE NSWindow. st.owner is our own platform window, which answers the
            // sixteen selectors AppKit sends a backend window and NOT -contentView; asking it
            // raises inside our own code and the application reports Unspecified Application Error.
            unsafe {
                let f = objc::msg_send_rect_ret(st.delegate, objc::sel_registerName(cstr!("frame")));
                let cv = objc::msg_send0(st.delegate, objc::sel_registerName(cstr!("contentView")));
                let cf = if cv.is_null() {
                    objc::NsRect::new(0.0, 0.0, 0.0, 0.0)
                } else {
                    objc::msg_send_rect_ret(cv, objc::sel_registerName(cstr!("frame")))
                };
                println!(
                    "cider-wayland-geometry number={} delegate={} surface={}x{} frame={}x{} content={}x{}+{}+{}",
                    st.number, has_delegate, width, height, f.size.width, f.size.height,
                    cf.size.width, cf.size.height, cf.origin.x, cf.origin.y
                );
                /*
                 * AND WHERE THE WINDOW PUT ITS SUBVIEWS. A content view of the right size can still
                 * hold a button laid out below its own bottom edge, and that is invisible in every
                 * number above: the dialog just comes out cut off. One level is enough to see it,
                 * and the class name says which view is which without guessing from the rect.
                 */
                /*
                 * WHO IS LISTENING. NSWindow turns a frame change into
                 * NSWindowDidResizeNotification, and an application that lays itself out from that
                 * notification hears nothing if the window has no delegate YET -- which is the
                 * suspect for a window resized the instant it maps.
                 */
                let wd = objc::msg_send0(st.delegate, objc::sel_registerName(cstr!("delegate")));
                let responds = if wd.is_null() {
                    objc::NO
                } else {
                    objc::msg_send_sel_bool(
                        wd,
                        objc::sel_registerName(cstr!("respondsToSelector:")),
                        objc::sel_registerName(cstr!("windowDidResize:")),
                    )
                };
                println!(
                    "cider-wayland-listener number={} delegate={} windowDidResize={}",
                    st.number,
                    if wd.is_null() { "nil" } else { "set" },
                    responds != objc::NO
                );
                if !cv.is_null() {
                    let subviews = objc::msg_send0(cv, objc::sel_registerName(cstr!("subviews")));
                    if !subviews.is_null() {
                        let count = objc::msg_send_usize_ret(
                            subviews, objc::sel_registerName(cstr!("count")));
                        let at_index = objc::sel_registerName(cstr!("objectAtIndex:"));
                        let frame_sel = objc::sel_registerName(cstr!("frame"));
                        for i in 0..count.min(12) {
                            let v = objc::msg_send_usize(subviews, at_index, i);
                            if v.is_null() {
                                continue;
                            }
                            let vf = objc::msg_send_rect_ret(v, frame_sel);
                            let cls = objc::object_getClass(v);
                            let name = objc::class_getName(cls);
                            let name = std::ffi::CStr::from_ptr(name).to_string_lossy();
                            println!(
                                "cider-wayland-subview number={} {} frame={}x{}+{}+{} bottom={}",
                                st.number, name, vf.size.width, vf.size.height,
                                vf.origin.x, vf.origin.y, vf.origin.y + vf.size.height
                            );
                        }
                    }
                }
            }
        }
        /*
         * AND REDRAW THE WHOLE THING. A frame change makes the application lay out again, and it
         * repaints what it believes changed; anything it lays out but does not consider dirty keeps
         * whatever the buffer held at the OLD size.
         *
         * Visible symptom, and it survived every other fix in this file: LibreOffice menu bar showed
         * Application and File and nothing else, at rest, for the whole session, because the window
         * is resized once during startup and the rest of the bar was laid out into a strip nobody
         * repainted. One click on the bar brought all of it back.
         */
        if has_delegate {
            st.needs_full_display = true;
            st.redraw_until =
                Some(std::time::Instant::now() + std::time::Duration::from_secs(6));
            st.last_forced_display = None;
        }
    }
}

/// The compositor is asking the window to close, which is a REQUEST and not an order: AppKit
/// decides, exactly as it does for a close button, and may refuse.
extern "C" fn on_toplevel_close(data: *mut c_void, _toplevel: *mut wl::XdgToplevel) {
    let Some(st) = (unsafe { (data as *mut WindowState).as_mut() }) else { return };
    println!("cider-wayland-window close-requested number={}", st.number);
    if !st.delegate.is_null() {
        unsafe {
            let sel = objc::sel_registerName(cstr!("platformWindowWillClose:"));
            objc::msg_send_obj(st.delegate, sel, st.owner);
        }
    }
}

extern "C" fn on_popup_configure(
    _data: *mut c_void,
    _popup: *mut wl::XdgPopup,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) {
    if crate::env_flag!("CIDER_WAYLAND_TRACE_RESIZE") {
        println!("cider-wayland-window popup-configure x={x} y={y} size={width}x{height}");
    }
}

/// THE COMPOSITOR DISMISSED THE MENU, which is how a menu closes on Wayland: a click elsewhere or
/// a focus change, decided by the compositor rather than by the client. Ignoring it leaves a menu
/// on screen that nothing can remove.
extern "C" fn on_popup_done(data: *mut c_void, _popup: *mut wl::XdgPopup) {
    let Some(st) = (unsafe { (data as *mut WindowState).as_mut() }) else { return };
    println!("cider-wayland-window popup=dismissed number={}", st.number);
    /*
     * A DISMISSED POPUP IS HIDDEN, NOT CLOSING, and telling AppKit otherwise took the whole
     * application apart.
     *
     * This used to send -platformWindowWillClose:, which cocotron turns into -performClose:, the
     * full the-user-closed-this-window protocol. The compositor dismisses popups whenever focus
     * moves, so opening the file picker dismissed nine of LibreOffice own parked menus, and each
     * one ran the close path. Named by the backtrace, reading upwards:
     *
     *     on_popup_done
     *     -[NSWindow performClose:]
     *     -[SalFrameWindow windowShouldClose:]
     *     ImplNSAppPostEvents
     *     -[NSApplication nextEventMatchingMask:...]
     *     -[NSArray makeObjectsPerformSelector:...]
     *     -[NSWindow _hideForDeactivation]
     *     hide_window_for_app_deactivation
     *
     * The application pumped events inside windowShouldClose, decided it was being deactivated, and
     * hid every window it had -- including the file picker that had just opened.
     *
     * popup_done means the popup is gone. Tear our side down so a later show rebuilds it, and say
     * nothing to AppKit: the close protocol belongs to xdg_toplevel.close, which is a different
     * event with a different meaning.
     */
    st.visible = false;
    st.mapped = false;
    st.configured = false;
    unsafe {
        if !st.popup.is_null() {
            wl::cider_xdg_popup_destroy(st.popup);
            st.popup = std::ptr::null_mut();
        }
        if !st.xdg.is_null() {
            wl::cider_xdg_surface_destroy(st.xdg);
            st.xdg = std::ptr::null_mut();
        }
        if !st.surface.is_null() {
            wl::cider_wl_surface_destroy(st.surface);
            st.surface = std::ptr::null_mut();
        }
    }
    release_backing(st);
    session::flush();
}

extern "C" fn on_popup_repositioned(_d: *mut c_void, _p: *mut wl::XdgPopup, _token: u32) {}

static POPUP_LISTENER: wl::XdgPopupListener = wl::XdgPopupListener {
    configure: on_popup_configure,
    popup_done: on_popup_done,
    repositioned: on_popup_repositioned,
};

extern "C" fn on_configure_bounds(_d: *mut c_void, _t: *mut wl::XdgToplevel, _w: i32, _h: i32) {}

extern "C" fn on_wm_capabilities(_d: *mut c_void, _t: *mut wl::XdgToplevel, _c: *mut c_void) {}

static TOPLEVEL_LISTENER: wl::XdgToplevelListener = wl::XdgToplevelListener {
    configure: on_toplevel_configure,
    close: on_toplevel_close,
    configure_bounds: on_configure_bounds,
    wm_capabilities: on_wm_capabilities,
};

/// Create the surface, the xdg_surface and the toplevel, then complete the configure handshake.
///
/// AN EMPTY COMMIT COMES FIRST. That is the protocol: committing with no buffer asks the
/// compositor for a configure, and only after acking it may pixels be attached.
fn create_surface(st: &mut WindowState) -> bool {
    let compositor = session::compositor();
    let base = session::wm_base();
    if compositor.is_null() || base.is_null() {
        println!("cider-wayland-window create=FAILED reason=no-session");
        return false;
    }
    unsafe {
        st.surface = wl::cider_wl_compositor_create_surface(compositor);
        if st.surface.is_null() {
            println!("cider-wayland-window create=FAILED reason=no-surface");
            return false;
        }
        st.xdg = wl::cider_xdg_wm_base_get_xdg_surface(base, st.surface);
        if st.xdg.is_null() {
            println!("cider-wayland-window create=FAILED reason=no-xdg-surface");
            return false;
        }
        wl::cider_xdg_surface_add_listener(st.xdg, &XDG_LISTENER, st as *mut WindowState as *mut c_void);

        /*
         * A MENU IS NOT A WINDOW, and this is where the two roles part.
         *
         * xdg_shell has two: a toplevel is an entry in the compositor idea of open windows, and a
         * POPUP belongs to another surface, is placed relative to it, and is dismissed rather than
         * closed. Creating a menu as a toplevel is what made LibreOffice menus open correctly and
         * appear nowhere near the pointer: measured, a click on the File menu created a 247x381
         * window at level 2 which a tiling compositor then placed as a tile of its own.
         *
         * THE LEVEL IS THE SIGNAL. AppKit gives menus and tooltips a window level above
         * NSNormalWindowLevel, and document windows level 0. An earlier attempt used the style mask
         * and could not tell a menu from a scrollbar helper; the level separates them exactly.
         */
        /*
         * THE PARENT MUST BE A MAPPED TOPLEVEL. A popup is positioned against a surface that is on
         * screen, and a compositor simply never configures one whose parent is not: measured, three
         * popups in a row reported create=FAILED reason=never-configured with no complaint in the
         * compositor log at all.
         *
         * Tracking the last TITLED window is not enough, because most of those are never shown:
         * this application creates a dozen and one is mapped. So the parent is looked up among the
         * windows that are actually mapped, which is information this backend already keeps.
         */
        /*
         * AND A BORDERLESS WINDOW IS NOT ONE EITHER, which the level alone does not catch.
         *
         * A TOOLTIP is level 0 and style mask 0, so the rule above made it a toplevel, and on a
         * tiling compositor every one of them took a share of the screen. Measured in one run:
         * twenty windows 18 points tall mapped as the pointer crossed the toolbar, one every
         * 0.3 seconds, and the last one survived as a 419x684 TILE painted 59x18, which is the
         * black third of the screen in docs/wayland-open-two-documents.png. It also moved every
         * other window while a test was driving it, which is what made this harness look flaky:
         * the document window was 1690 wide in one run and 419 in the next for no reason the test
         * could see.
         *
         * The comment above is still right that the style mask alone cannot separate a menu from a
         * scrollbar helper. It does not have to: those helpers are never mapped, so the two signals
         * together are exact. Borderless AND parented is a tooltip; borderless with no mapped
         * parent stays a toplevel, which is what a splash screen wants.
         */
        let (parent_xdg, parent_left, parent_top) = match mapped_toplevel_anchor() {
            Some((xdg, left, top)) => (xdg, left, top),
            None => (
                std::ptr::null_mut(),
                PARENT_LEFT.load(Ordering::Acquire),
                PARENT_TOP.load(Ordering::Acquire),
            ),
        };
        let transient = st.level > 0 || st.style_mask == 0;
        let wants_popup = transient && !parent_xdg.is_null() && parent_xdg != st.xdg;
        if wants_popup {
            let base = session::wm_base();
            let positioner = if base.is_null() {
                std::ptr::null_mut()
            } else {
                wl::cider_xdg_wm_base_create_positioner(base)
            };
            if !positioner.is_null() {
                fill_positioner(positioner, st, parent_left, parent_top, "create");
                st.popup = wl::cider_xdg_surface_get_popup(st.xdg, parent_xdg, positioner);
                wl::cider_xdg_positioner_destroy(positioner);
            }
            if st.popup.is_null() {
                println!("cider-wayland-window popup=FAILED number={} falling back", st.number);
            } else {
                wl::cider_xdg_popup_add_listener(
                    st.popup,
                    &POPUP_LISTENER,
                    st as *mut WindowState as *mut c_void,
                );
                println!(
                    "cider-wayland-window popup=ok number={} size={}x{} level={}",
                    st.number, st.frame.size.width as i32, st.frame.size.height as i32, st.level
                );
            }
        }

        if st.popup.is_null() {
            st.toplevel = wl::cider_xdg_surface_get_toplevel(st.xdg);
            if st.toplevel.is_null() {
                println!("cider-wayland-window create=FAILED reason=no-toplevel");
                return false;
            }
            wl::cider_xdg_toplevel_add_listener(
                st.toplevel,
                &TOPLEVEL_LISTENER,
                st as *mut WindowState as *mut c_void,
            );
            /*
             * SAY WHICH APPLICATION THIS IS. A toplevel with no app_id is anonymous to the
             * compositor: no window rule can match it, it has no identity in a task list, and it
             * gets no icon. It is also how a person drives it from outside, which is how this was
             * noticed: a resize aimed at the window did nothing, because there was nothing to aim
             * at.
             *
             * The bundle identifier is the right answer where there is one, since that is what the
             * application calls itself; the executable name is the honest fallback.
             */
            let app_id = app_identifier();
            if let Ok(text) = std::ffi::CString::new(app_id) {
                wl::cider_xdg_toplevel_set_app_id(st.toplevel, text.as_ptr());
            }
            apply_pending_title(st);
        }
        /*
         * A BORDERLESS WINDOW IS NOT A DOCUMENT, and saying so is the difference between an
         * application and a pile of tiles. AppKit opens tooltips, palettes, scrollbar helpers and
         * menu shadows as ordinary NSWindows with a borderless style mask; without a parent, a
         * compositor has no way to tell them from the document and a tiling one gives each an
         * equal share of the screen. Measured: LibreOffice opened twenty four windows and the
         * document window was resized from 1256 wide to 628 and then to 314 as its own tooltips
         * were tiled beside it.
         *
         * The parent is the most recent TITLED window, which is what these belong to in practice.
         * Compositors float a toplevel that has a parent, which is the behaviour wanted here.
         */
        /*
         * A PANEL IS A DIALOG, not a second document, and a compositor cannot tell from the style
         * mask alone: a save panel is TITLED, so the rule below made it a parent and a tiling
         * compositor gave it half the screen beside the document. On Apple systems that panel is
         * modal and centred over the window it belongs to.
         *
         * xdg_toplevel.set_parent is exactly that relationship, and compositors float a toplevel
         * that has a parent instead of tiling it. NSPanel is the class every one of these is:
         * NSSavePanel, NSOpenPanel and the window NSAlert builds all inherit from it, and asking
         * the delegate is precise where guessing from the style mask is not.
         */
        let is_panel = if st.delegate.is_null() {
            false
        } else {
            let cls = objc::objc_getClass(cstr!("NSPanel"));
            !cls.is_null()
                && objc::msg_send_class_bool(
                    st.delegate,
                    objc::sel_registerName(cstr!("isKindOfClass:")),
                    cls,
                ) != objc::NO
        };
        /*
         * AND A TITLED WINDOW WITH NO MINIMISE BUTTON IS A DIALOG, which catches the ones an
         * application builds itself rather than through NSPanel.
         *
         * The rule used to be "cannot be resized", and that was too narrow. It caught the save
         * prompt, style 0x3, titled and closable and nothing else. It did NOT catch the Options
         * window, style 0xb, which is titled, closable and RESIZABLE but has no minimise button:
         * a tiling compositor gave that one half the screen, LibreOffice would not lay its 967 wide
         * content out into a 628 wide tile, and the right third of the dialog was simply off the
         * edge with its buttons on it.
         *
         * MINIATURIZABLE IS THE SIGNAL because it is the one macOS itself uses. A document window
         * is 0xf and has all four bits; a dialog never has a minimise button, whatever else it has.
         * Being unresizable is a special case of that, so the save prompt is still caught.
         */
        let miniaturizable = st.style_mask & 0x4 != 0;
        let dialog = st.style_mask & 0x1 != 0 && !miniaturizable;
        let titled = st.style_mask & 0x1 != 0 && st.popup.is_null() && !is_panel && !dialog;
        /* WHICH APPKIT CLASS THIS SURFACE IS. A window that appears in the wrong place, or appears
         * and should not have, is identified by its class faster than by its size and level: a
         * 164x304 panel at level 6 is a popup window, a combo box list or a tooltip, and only the
         * class says which. Chasing a context menu through three wrong guesses is what put this
         * here. */
        let class_name = if st.delegate.is_null() {
            "(none)".to_string()
        } else {
            let cls = objc::object_getClass(st.delegate);
            let name = if cls.is_null() { std::ptr::null() } else { objc::class_getName(cls) };
            if name.is_null() {
                "(unknown)".to_string()
            } else {
                std::ffi::CStr::from_ptr(name).to_string_lossy().into_owned()
            }
        };
        println!(
            "cider-wayland-window role number={} style={:#x} panel={} dialog={} titled={} class={}",
            st.number, st.style_mask, is_panel, dialog, titled, class_name
        );
        /* WHO MADE THIS WINDOW. The class alone was not enough once: an NSPopUpWindow appeared for
         * every right click while the only code in the framework that can create one was proved
         * not to run. CIDER_WAYLAND_TRACE_CREATOR names the frames. */
        if crate::env_flag!("CIDER_WAYLAND_TRACE_CREATOR") {
            crate::print_backtrace(&format!("window-{}-{}", st.number, class_name));
        }
        if titled {
            LAST_TITLED_TOPLEVEL.store(st.toplevel as usize, Ordering::Release);
            PARENT_XDG_SURFACE.store(st.xdg as usize, Ordering::Release);
            PARENT_LEFT.store(st.frame.origin.x as i64, Ordering::Release);
            PARENT_TOP.store((st.frame.origin.y + st.frame.size.height) as i64, Ordering::Release);
        } else if !st.toplevel.is_null() {
            // A MAPPED window first, and the remembered one only as a fallback: a parent that is
            // not on screen is not a parent as far as the compositor is concerned.
            let parent = mapped_toplevel().unwrap_or(
                LAST_TITLED_TOPLEVEL.load(Ordering::Acquire) as *mut wl::XdgToplevel,
            );
            if !parent.is_null() && parent != st.toplevel {
                wl::cider_xdg_toplevel_set_parent(st.toplevel, parent);
            }
        }
        /*
         * WHICH PART OF THE SURFACE IS THE WINDOW, before the first commit.
         *
         * A window with a shadow has a surface bigger than itself, and without this the compositor
         * treats the whole thing as the window: a tiled window would be inset by the shadow, a
         * maximised one would overhang the screen, and a popup would be anchored to the shadow
         * rather than to the menu bar. The geometry is set once here and again after every resize,
         * because the size is part of it.
         */
        let margin = shadow_margin(st);
        if margin > 0 && !st.xdg.is_null() {
            wl::cider_xdg_surface_set_window_geometry(
                st.xdg,
                margin,
                margin,
                (st.frame.size.width as i32).max(1),
                (st.frame.size.height as i32).max(1),
            );
        }
        wl::cider_wl_surface_commit(st.surface);
        for _ in 0..20 {
            session::roundtrip();
            if st.configured {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
        if !st.configured {
            println!("cider-wayland-window create=FAILED reason=never-configured");
            return false;
        }
    }
    println!(
        "cider-wayland-window create=ok number={} size={}x{} at={},{} level={} style={:#x}",
        st.number, st.frame.size.width as i32, st.frame.size.height as i32,
        st.frame.origin.x as i32, st.frame.origin.y as i32, st.level, st.style_mask
    );
    true
}

/// mmap and friends, declared rather than pulled in: the guest libSystem has them and the whole
/// need is one mapping per window. Darwin's own values, since this is Darwin ABI code.
unsafe extern "C" {
    fn mmap(addr: *mut c_void, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) -> *mut c_void;
    fn munmap(addr: *mut c_void, len: usize) -> c_int;
    fn ftruncate(fd: c_int, len: i64) -> c_int;
}

const PROT_READ: c_int = 0x01;
const PROT_WRITE: c_int = 0x02;
const MAP_SHARED: c_int = 0x0001;

/// Onyx2D, which is where CoreGraphics actually lives: the CoreGraphics dylib in the prefix is a
/// re-export shim whose symbols are all undefined, and O2Surface and O2Context_builtin_FT are
/// classes in Onyx2D.framework. Only the colour space constructor is a plain function.
unsafe extern "C" {
    fn O2ColorSpaceCreateDeviceRGB() -> *mut c_void;
    fn O2ColorSpaceRelease(cs: *mut c_void);
}

/// kO2ImageAlphaPremultipliedFirst is the third member of its enum, so 2, and
/// kO2BitmapByteOrder32Little is 0x2000. Together they describe little-endian ARGB, which is
/// BYTE FOR BYTE the same layout as Wayland's XRGB8888: B, G, R, then a byte Wayland ignores and
/// Onyx2D treats as alpha. That equality is what makes the mapping shareable with no conversion.
const BITMAP_INFO: u32 = 2 | 0x2000;

/// What a fresh window is cleared to: opaque light grey, so an undrawn window is visibly a window
/// rather than whatever the pages happened to contain. It is also the value the drawn-pixel count
/// measures against, which is why it is a constant rather than a literal in one place.
const CLEAR_PIXEL: u32 = 0xffee_eeee;

/// What a TRANSPARENT window is cleared to. A menu is rounded and translucent on macOS, which means
/// the pixels outside its rounded shape have to be nothing at all rather than a light grey, and
/// nothing at all is premultiplied zero.
const CLEAR_ALPHA: u32 = 0x0000_0000;

/// Whether this window is drawn with an alpha channel: the transient ones, which are the menus, the
/// dropdown lists and the tooltips. A document window is opaque and stays on the format the
/// protocol guarantees.
fn wants_alpha(st: &WindowState) -> bool {
    // AND THE WINDOWS WE DRAW A FRAME FOR, which get rounded corners punched out of the same
    // channel. A window with a title bar is one this backend decorates, and macOS rounds all four
    // of its corners.
    st.level > 0 || st.style_mask & 0x1 != 0
}

/// HOW WIDE THE SHADOW IS, in surface pixels around the window.
///
/// macOS floats every window and every dialog on a soft shadow, and a flat rectangle against the
/// desktop is one of the last things that says this is not a Mac. A Wayland client draws its own:
/// the surface is made bigger than the window, the extra ring is painted with a falling alpha, and
/// xdg_surface.set_window_geometry tells the compositor which part is the WINDOW so that tiling,
/// snapping and popup anchoring still use the right rectangle.
const SHADOW_MARGIN: i32 = 24;

/// Whether this window gets one. A decorated toplevel does; a popup does not, because a menu is
/// already drawn with its own rounded panel and a compositor places it against its parent.
fn shadow_margin(st: &WindowState) -> i32 {
    if crate::env_flag!("CIDER_WAYLAND_NO_SHADOW") {
        return 0;
    }
    if st.popup.is_null() && st.style_mask & 0x1 != 0 && wants_alpha(st) {
        SHADOW_MARGIN
    } else {
        0
    }
}

/// Paint the ring around the window, once per backing.
///
/// The application never touches these pixels, so this runs when the pages are allocated rather
/// than per frame. Premultiplied, like everything else in the buffer, and offset DOWNWARD: an Apple
/// shadow sits below its window rather than around it evenly.
fn paint_shadow(st: &mut WindowState) {
    let margin = st.margin;
    if margin <= 0 || st.pixels.is_null() {
        return;
    }
    let alloc_w = st.draw_w + margin * 2;
    let alloc_h = st.draw_h + margin * 2;
    let total = st.map_len / 4;
    if total < (alloc_w as usize) * (alloc_h as usize) {
        return;
    }
    let words = unsafe { std::slice::from_raw_parts_mut(st.pixels as *mut u32, total) };
    let inner_x0 = margin as f64;
    let inner_y0 = margin as f64;
    let inner_x1 = (margin + st.draw_w) as f64;
    let inner_y1 = (margin + st.draw_h) as f64;
    let reach = margin as f64;
    // The shadow is cast from a rectangle sitting slightly ABOVE the window, so more of it falls
    // below than above, which is what a light source over the screen does.
    let drop = 6.0;

    for y in 0..alloc_h {
        for x in 0..alloc_w {
            let inside_x = (x as f64) >= inner_x0 && (x as f64) < inner_x1;
            let inside_y = (y as f64) >= inner_y0 && (y as f64) < inner_y1;
            if inside_x && inside_y {
                continue;
            }
            let dx = if (x as f64) < inner_x0 {
                inner_x0 - x as f64
            } else if (x as f64) >= inner_x1 {
                x as f64 - inner_x1 + 1.0
            } else {
                0.0
            };
            let dy = if (y as f64) < inner_y0 + drop {
                inner_y0 + drop - y as f64
            } else if (y as f64) >= inner_y1 + drop {
                y as f64 - (inner_y1 + drop) + 1.0
            } else {
                0.0
            };
            let distance = (dx * dx + dy * dy).sqrt();
            if distance >= reach {
                continue;
            }
            let fall = 1.0 - distance / reach;
            let alpha = (0.30 * fall * fall * 255.0).round() as u32;
            if alpha == 0 {
                continue;
            }
            // Premultiplied black: the colour channels are zero, so only the alpha carries it.
            words[(y as usize) * (alloc_w as usize) + (x as usize)] = alpha << 24;
        }
    }
}

/// The radius macOS rounds a window and a menu with.
const CORNER_RADIUS: i32 = 10;

/// Punch the four corners out of the buffer, so a window is a rounded rectangle.
///
/// DONE HERE RATHER THAN IN APPKIT because the corners of a window are not all drawn by the same
/// thing: the frame paints the top ones and the application content paints over the bottom ones,
/// and a content view that fills its own rect square would undo any rounding the frame did. The
/// pixels are the one place where every drawing has already happened.
///
/// The coverage is sampled four by four so the edge is smooth rather than a staircase, and it
/// SCALES the pixel rather than clearing it: the buffer is premultiplied, so multiplying all four
/// channels by the coverage is exactly a partial alpha.
fn round_corners(st: &mut WindowState) {
    if st.pixels.is_null() || !wants_alpha(st) {
        return;
    }
    let w = st.draw_w;
    let h = st.draw_h;
    let r = CORNER_RADIUS;
    if w < r * 2 || h < r * 2 {
        return;
    }
    // THE CORNERS OF THE WINDOW, NOT OF THE SURFACE. With a shadow the surface is bigger, and
    // rounding its corners would round the shadow while leaving the window square.
    let margin = st.margin as usize;
    let stride = (w + st.margin * 2) as usize;
    let total = st.map_len / 4;
    if total < stride * (h as usize) {
        return;
    }
    let words = unsafe { std::slice::from_raw_parts_mut(st.pixels as *mut u32, total) };
    let rf = r as f64;
    for corner in 0..4 {
        let right = corner & 1 == 1;
        let bottom = corner & 2 == 2;
        for cy in 0..r {
            for cx in 0..r {
                // Distance from the corner circle centre, measured from the pixel CENTRE.
                let mut covered = 0u32;
                for sy in 0..4 {
                    for sx in 0..4 {
                        let px = cx as f64 + (sx as f64 + 0.5) / 4.0;
                        let py = cy as f64 + (sy as f64 + 0.5) / 4.0;
                        let dx = rf - px;
                        let dy = rf - py;
                        if dx * dx + dy * dy <= rf * rf {
                            covered += 1;
                        }
                    }
                }
                if covered == 16 {
                    continue;
                }
                let x = if right { w - 1 - cx } else { cx };
                let y = if bottom { h - 1 - cy } else { cy };
                let idx = ((y as usize) + margin) * stride + (x as usize) + margin;
                let pixel = words[idx];
                if covered == 0 {
                    words[idx] = 0;
                    continue;
                }
                /*
                 * ONLY A PIXEL THAT IS STILL FULLY OPAQUE, which is what makes this safe to run on
                 * every present. Scaling by coverage a second time would scale an already scaled
                 * pixel, and a window that presents thirty times a second would watch its own
                 * corners fade to nothing. A pixel AppKit has just drawn is opaque; one this
                 * function has already touched is not.
                 */
                if (pixel >> 24) != 0xff {
                    continue;
                }
                let scale = |c: u32| ((c * covered) / 16) & 0xff;
                words[idx] = (scale((pixel >> 24) & 0xff) << 24)
                    | (scale((pixel >> 16) & 0xff) << 16)
                    | (scale((pixel >> 8) & 0xff) << 8)
                    | scale(pixel & 0xff);
            }
        }
    }
}

/// The value this window clears to, which is not the same for the two formats.
fn clear_value(st: &WindowState) -> u32 {
    if wants_alpha(st) { CLEAR_ALPHA } else { CLEAR_PIXEL }
}

/// Make sure the window has shm pages of the right size, mapped, with a wl_buffer over them.
///
/// Returns false if anything failed, with a reason in the log. Every caller treats false as "there
/// is nothing to draw on", which is survivable, rather than raising.
fn ensure_backing(st: &mut WindowState) -> bool {
    use std::os::unix::io::AsRawFd;

    let w = (st.frame.size.width as i32).max(1);
    let h = (st.frame.size.height as i32).max(1);
    // The bitmap is the larger of the two sizes in each direction, so a window the application
    // refuses to shrink still has somewhere to draw all of itself.
    let dw = w.max(st.insist_w);
    let dh = h.max(st.insist_h);
    if !st.pixels.is_null() && st.buffer_w == w && st.buffer_h == h && st.draw_w == dw
        && st.draw_h == dh && st.margin == shadow_margin(st)
    {
        return true;
    }
    let had_backing = !st.pixels.is_null();
    release_backing(st);
    /*
     * TELL APPKIT ITS CACHED CONTEXT IS GONE. NSWindow keeps the graphics context per thread in
     * _threadToContext and hands the SAME one out until something invalidates it, and the only
     * thing that does is -platformWindowDidInvalidateCGContext:. Without this call AppKit goes on
     * drawing through an O2Context whose surface wraps pixels this function has just unmapped.
     *
     * It is a use after free on every rebuild, and a rebuild only happens on RESIZE, which is why
     * weston headless never showed it: that compositor never resizes anything. A tiling compositor
     * resizes the first window it maps.
     */
    st.needs_full_display = true;
    if had_backing && !st.delegate.is_null() {
        unsafe {
            let sel = objc::sel_registerName(cstr!("platformWindowDidInvalidateCGContext:"));
            objc::msg_send_obj(st.delegate, sel, st.owner);
        }
    }

    let shm = session::shm();
    if shm.is_null() {
        return false;
    }
    // THE SURFACE IS BIGGER THAN THE WINDOW WHEN THERE IS A SHADOW, and everything below counts in
    // the padded space: the stride, the mapping, and the wl_buffer. Only the O2 surface handed to
    // AppKit is the inner rectangle, which it reaches through a pointer into the middle of the
    // mapping.
    let margin = shadow_margin(st);
    let alloc_w = dw + margin * 2;
    let alloc_h = dh + margin * 2;
    let stride = alloc_w * 4;
    let size = (stride as usize) * (alloc_h as usize);

    // A PLAIN FILE, not shm_open: the compositor receives the DESCRIPTOR and mmaps that, so where
    // the file lives never travels with it and the guest needs no working /dev/shm.
    let path = format!("/tmp/cider-window-{}-{}.shm", std::process::id(), st.number);
    let Ok(file) = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(true)
        .open(&path)
    else {
        println!("cider-wayland-window backing=FAILED reason=no-file");
        return false;
    };
    // Unlinked immediately: the descriptor keeps it alive and nothing is left behind.
    let _ = std::fs::remove_file(&path);
    let fd = file.as_raw_fd();
    if unsafe { ftruncate(fd, size as i64) } != 0 {
        println!("cider-wayland-window backing=FAILED reason=ftruncate");
        return false;
    }
    let map = unsafe {
        mmap(std::ptr::null_mut(), size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
    };
    if map.is_null() || map as isize == -1 {
        println!("cider-wayland-window backing=FAILED reason=mmap");
        return false;
    }
    unsafe {
        let words = std::slice::from_raw_parts_mut(map as *mut u32, size / 4);
        words.fill(clear_value(st));
        // ARMED AFTER THE CLEAR, so the fill itself is not what faults. Diagnostic only, and it
        // does nothing unless CIDER_WAYLAND_WATCH is set. See watch.c for why a watchpoint rather
        // than another trace: every trace so far had to guess which layer to instrument.
        cider_wayland_watch_begin(map, size);
    }

    unsafe {
        let pool = wl::cider_wl_shm_create_pool(shm, fd, size as i32);
        if pool.is_null() {
            println!("cider-wayland-window backing=FAILED reason=no-pool");
            munmap(map, size);
            return false;
        }
        let format = if wants_alpha(st) {
            wl::cider_wl_shm_format_argb8888()
        } else {
            wl::cider_wl_shm_format_xrgb8888()
        };
        // OFFSET ZERO AND THE DRAWING STRIDE. Zero is the first row of the bitmap, which an
        // unflipped context makes the TOP of the window, and a stride wider than the buffer takes
        // the left of each row: between them the compositor is shown the top left corner of a
        // window that is larger than its surface, rather than the bottom right.
        st.buffer =
            wl::cider_wl_shm_pool_create_buffer(pool, 0, w + margin * 2, h + margin * 2, stride,
                                                format);
        // The pool may go as soon as the buffer exists: the buffer holds its own reference to the
        // mapping, which is what makes a resize a new pool rather than a torn down surface.
        wl::cider_wl_shm_pool_destroy(pool);
        if st.buffer.is_null() {
            println!("cider-wayland-window backing=FAILED reason=no-buffer");
            munmap(map, size);
            return false;
        }
    }
    st.backing = Some(file);
    st.pixels = map as *mut u8;
    st.map_len = size;
    st.buffer_w = w;
    st.buffer_h = h;
    st.draw_w = dw;
    st.draw_h = dh;
    st.margin = margin;
    paint_shadow(st);
    if dw != w || dh != h {
        println!(
            "cider-wayland-window backing=oversize number={} buffer={w}x{h} bitmap={dw}x{dh}",
            st.number
        );
    }
    true
}

/// Drop the mapping, the buffer and the context together, because all three describe one size.
fn release_backing(st: &mut WindowState) {
    if !st.context.is_null() {
        unsafe {
            objc::msg_send0(st.context, objc::sel_registerName(cstr!("release")));
        }
        st.context = std::ptr::null_mut();
    }
    if !st.pixels.is_null() {
        unsafe { munmap(st.pixels as *mut c_void, st.map_len) };
        st.pixels = std::ptr::null_mut();
        st.map_len = 0;
    }
    st.buffer = std::ptr::null_mut();
    st.backing = None;
    st.buffer_w = 0;
    st.buffer_h = 0;
    st.draw_w = 0;
    st.draw_h = 0;
}

/// Hand the mapped pages to the compositor.
///
/// Whatever AppKit has drawn is already in those pages, so this is attach, damage and commit and
/// nothing else. That is the point of mapping rather than copying.
fn present(st: &mut WindowState) {
    /*
     * A WINDOW APPKIT HAS NOT SHOWN MUST NOT BE MAPPED, and this is the whole of that rule.
     *
     * present() is reached from flushBuffer, from -makeKey, from -setTitle and from half a dozen
     * other places, so before this check ANY of them mapped the surface. An application creates
     * windows long before it shows them, and LibreOffice creates plenty it never shows at all:
     * those appeared as flat rectangles of the clear colour, over the document, over the sidebar
     * and as a band through the middle of the page. Their buffers contained ONE unique colour,
     * which is how they were finally identified.
     *
     * Visibility arrives through -showWindowWithoutActivation and -showWindowForAppActivation:,
     * which is what -[NSWindow setIsVisible:] calls.
     */
    if !st.visible {
        return;
    }
    /* A HIDDEN WINDOW HAS NO SURFACE AT ALL NOW, so showing it again means building the role from
     * scratch, exactly as it was built the first time. */
    if st.surface.is_null() && st.visible && !create_surface(st) {
        return;
    }
    if st.surface.is_null() || !st.configured || !ensure_backing(st) {
        return;
    }
    /*
     * AND A SURFACE WITH NOTHING IN IT IS NOT MAPPED, which is Wayland own rule and happens to be
     * the answer to a window the user should never see.
     *
     * LibreOffice keeps a borderless 648x200 window it calls VCL ImplGetDefaultWindow and never
     * draws into. On Apple systems it is out of the way; here it was ordered front like any other
     * window, so the FIRST thing to appear on the user desktop was a blank grey rectangle, and on a
     * tiling compositor it took a share of the screen for the whole session.
     *
     * A client is not obliged to attach a buffer, and a surface without one is unmapped by
     * definition. So the first attach waits for the application to draw SOMETHING. Once a window has
     * been mapped this check is skipped, because a window that later clears itself completely is
     * still a window.
     */
    if !st.mapped && !st.pixels.is_null() && st.map_len >= 4 {
        let total = st.map_len / 4;
        let words = unsafe { std::slice::from_raw_parts(st.pixels as *const u32, total) };
        let clear = clear_value(st);
        if words.iter().all(|&w| w == clear) {
            /*
             * AND SAY SO WHEN ASKED, because this rule is indistinguishable from the application
             * never showing the window at all: both end with no map line and nothing on screen.
             * A dropdown list that is presented and still blank is OUR bug; one that is never
             * presented is the application not opening it, and those want opposite work.
             */
            if crate::env_flag!("CIDER_WAYLAND_TRACE_DISPLAY") {
                println!(
                    "cider-wayland-window skip=allclear number={} size={}x{} t={:.2}",
                    st.number, st.buffer_w, st.buffer_h, elapsed()
                );
            }
            return;
        }
    }
    round_corners(st);
    unsafe {
        if st.margin > 0 && !st.xdg.is_null() {
            // The size is part of the geometry, so a resized window has to say so again.
            wl::cider_xdg_surface_set_window_geometry(
                st.xdg,
                st.margin,
                st.margin,
                st.buffer_w.max(1),
                st.buffer_h.max(1),
            );
        }
        wl::cider_wl_surface_attach(st.surface, st.buffer, 0, 0);
        wl::cider_wl_surface_damage(st.surface, 0, 0, st.buffer_w + st.margin * 2,
                                    st.buffer_h + st.margin * 2);
        wl::cider_wl_surface_commit(st.surface);
    }
    session::flush();
    if !st.mapped {
        st.mapped = true;
        println!(
            "cider-wayland-window mapped=yes number={} size={}x{} t={:.2}",
            st.number, st.buffer_w, st.buffer_h, elapsed()
        );
    }
    report_pixels(st);
    // HOW MANY TIMES A WINDOW IS PRESENTED separates two failures that look identical on screen:
    // an application that draws nonsense, and one that draws correctly but never commits again, so
    // the compositor keeps showing an early frame forever. The dump below is taken at present time
    // and therefore cannot tell them apart on its own.
    st.presents += 1;
    if st.presents <= 3 || st.presents % 50 == 0 {
        println!(
            "cider-wayland-window present number={} count={} size={}x{} t={:.2}",
            st.number, st.presents, st.buffer_w, st.buffer_h, elapsed()
        );
    }
    dump_buffer(st);
}

/// Write the window's pixels to a BMP under $CIDER_WAYLAND_DUMP, so the contents can be LOOKED AT.
///
/// Every measurement above this one is a summary: a changed count, a distinct-colour count, one
/// centre pixel. All three are satisfied by a window that draws confident nonsense, and that is
/// exactly the failure they cannot distinguish. This writes the pixels themselves.
///
/// BMP because it needs no encoder: a 32bpp BI_RGB image IS the shm buffer with a 54 byte header in
/// front of it, and the byte order the header implies is the byte order wl_shm already uses. A
/// NEGATIVE HEIGHT means top-down, which is the direction the buffer is already in; without it
/// every dump comes out mirrored and the mistake looks like a rendering bug.
fn dump_buffer(st: &mut WindowState) {
    let Some(dir) = crate::env_value!("CIDER_WAYLAND_DUMP") else {
        return;
    };
    if st.pixels.is_null() || st.map_len == 0 {
        return;
    }
    // Rate limited because a 2752x1152 window is 12 MB per write, and a redraw storm would
    // otherwise measure the disk rather than the application.
    let now = std::time::Instant::now();
    if let Some(prev) = st.last_dump {
        if now.duration_since(prev).as_millis() < 400 {
            return;
        }
    }
    st.last_dump = Some(now);

    // THE BITMAP, not the buffer: the pages are the drawing, and on a window the compositor sized
    // smaller than its minimum the two differ.
    let (w, h) = (st.draw_w, st.draw_h);
    let stride = (w as usize) * 4;
    let image_len = stride * (h as usize);
    if image_len == 0 || image_len > st.map_len {
        return;
    }
    // THE HEADER AND THE PIXELS ARE WRITTEN SEPARATELY, not concatenated into a buffer first. The
    // pixels are already in memory and copying twelve megabytes to prepend fifty four bytes showed
    // up as five percent of the whole profile, which is a diagnostic charging more than the thing
    // it diagnoses.
    let mut header = [0u8; 54];
    let file_len = (54 + image_len) as u32;
    header[0..2].copy_from_slice(b"BM");
    header[2..6].copy_from_slice(&file_len.to_le_bytes());
    header[10..14].copy_from_slice(&54u32.to_le_bytes());
    header[14..18].copy_from_slice(&40u32.to_le_bytes());
    header[18..22].copy_from_slice(&w.to_le_bytes());
    header[22..26].copy_from_slice(&(-h).to_le_bytes());
    header[26..28].copy_from_slice(&1u16.to_le_bytes());
    header[28..30].copy_from_slice(&32u16.to_le_bytes());
    header[34..38].copy_from_slice(&(image_len as u32).to_le_bytes());

    let path = format!("{}/window-{}.bmp", dir.to_string_lossy(), st.number);
    // Written whole then renamed, because a reader that opens a half written 12 MB file sees a
    // torn image and blames the renderer.
    let tmp = format!("{path}.tmp");
    let pixels = unsafe { std::slice::from_raw_parts(st.pixels, image_len) };
    if let Ok(mut file) = std::fs::File::create(&tmp) {
        use std::io::Write;
        if file.write_all(&header).is_ok() && file.write_all(pixels).is_ok() {
            drop(file);
            let _ = std::fs::rename(&tmp, &path);
        }
    }
}

/// Say whether anything was actually DRAWN into the pages, once.
///
/// A context that constructs is not a context that renders, and the two failures look identical
/// from outside: both produce a window. Counting the pixels that differ from the fill this backend
/// wrote is the cheapest honest distinction, and it reads the same memory the compositor maps, so
/// there is nothing between the measurement and the truth.
/// Whether the LAST ROW of the buffer is still the clear value, which means the application has not
/// painted the bottom of its own window.
///
/// This is the acknowledgement a resize otherwise has none of. Telling an application its new size
/// is not the same as the application acting on it, and the gap between the two is exactly the bug
/// this answers: a window whose widgets are still laid out for the size it was created with paints
/// the top of the surface and leaves the rest cleared.
fn bottom_row_is_clear(st: &WindowState) -> bool {
    if st.pixels.is_null() || st.draw_w <= 0 || st.draw_h <= 0 {
        return false;
    }
    let width = st.draw_w as usize;
    let total = st.map_len / 4;
    if total < width {
        return false;
    }
    let words = unsafe { std::slice::from_raw_parts(st.pixels as *const u32, total) };
    let clear = clear_value(st);
    words[total - width..].iter().all(|&w| w == clear)
}

fn report_pixels(st: &mut WindowState) {
    if st.pixels.is_null() || st.reported_drawn {
        return;
    }
    let total = st.map_len / 4;
    if total == 0 {
        return;
    }
    let words = unsafe { std::slice::from_raw_parts(st.pixels as *const u32, total) };
    let clear = clear_value(st);
    let drawn = words.iter().filter(|&&w| w != clear).count();
    if drawn == 0 {
        return;
    }
    st.reported_drawn = true;
    let centre = words[total / 2 + (st.draw_w as usize) / 2];
    // DISTINCT COLOURS, not just a changed count, because the changed count cannot see text: black
    // glyphs on a coloured fill differ from the clear value either way, so the count is identical
    // whether the string rasterised or not. A flat fill has two values in it and antialiased
    // glyphs have dozens, which is a measure that needs to know nothing about the application.
    let mut seen = [0u32; DISTINCT_CAP];
    let mut distinct = 0usize;
    for &w in words {
        if seen[..distinct].contains(&w) {
            continue;
        }
        seen[distinct] = w;
        distinct += 1;
        if distinct == DISTINCT_CAP {
            break;
        }
    }
    let capped = if distinct == DISTINCT_CAP { "+" } else { "" };
    println!(
        "cider-wayland-window pixels=drawn number={} changed={drawn}/{total} colours={distinct}{capped} centre={centre:08x}",
        st.number
    );
}

/// Ask every mapped window to redraw, if CIDER_WAYLAND_FORCE_REDRAW is set to a millisecond period.
///
/// A DIAGNOSTIC BEFORE IT IS ANYTHING ELSE. The application paints its window three times and then
/// never again, and there are two very different reasons that could be: it never invalidates
/// anything, or it invalidates and the display cycle never reaches drawRect. Forcing the display
/// separates them in one run, and if the picture CHANGES when forced, everything that is wrong on
/// screen right now is a stale frame rather than a drawing bug.
pub fn force_redraw_if_due() {
    let Some(period) = crate::env_value!("CIDER_WAYLAND_FORCE_REDRAW") else {
        return;
    };
    let Some(ms) = period.to_string_lossy().parse::<u64>().ok() else {
        return;
    };
    use std::sync::atomic::{AtomicU64, Ordering};
    static LAST: AtomicU64 = AtomicU64::new(0);
    let now = (elapsed() * 1000.0) as u64;
    let last = LAST.load(Ordering::Relaxed);
    if now.saturating_sub(last) < ms {
        return;
    }
    LAST.store(now, Ordering::Relaxed);
    let Ok(list) = WINDOWS.lock() else {
        return;
    };
    for &p in list.iter() {
        let st = unsafe { &mut *(p as *mut WindowState) };
        if st.mapped && !st.delegate.is_null() {
            st.needs_full_display = true;
        }
    }
}

/// What this application calls itself, for xdg_toplevel.set_app_id.
///
/// The bundle identifier first, because that is the name the application chose and the one a
/// compositor rule would be written against. Falling back to the executable name keeps every
/// window identifiable even for a binary with no bundle at all.
fn app_identifier() -> String {
    unsafe {
        let bundle_cls = objc::objc_getClass(cstr!("NSBundle"));
        if !bundle_cls.is_null() {
            let main = objc::msg_send0(bundle_cls, objc::sel_registerName(cstr!("mainBundle")));
            if !main.is_null() {
                let ident =
                    objc::msg_send0(main, objc::sel_registerName(cstr!("bundleIdentifier")));
                if !ident.is_null() {
                    let raw = objc::msg_send0(ident, objc::sel_registerName(cstr!("UTF8String")))
                        as *const std::os::raw::c_char;
                    if !raw.is_null() {
                        if let Ok(text) = std::ffi::CStr::from_ptr(raw).to_str() {
                            if !text.is_empty() {
                                return text.to_string();
                            }
                        }
                    }
                }
            }
        }
    }
    std::env::current_exe()
        .ok()
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
        .unwrap_or_else(|| "cider".to_string())
}

/// The frame origin and height of the window that owns a surface, for turning a pointer position
/// into the screen coordinates AppKit asks for.
pub fn frame_for_surface(surface: *mut wl::WlSurface) -> Option<(f64, f64, f64)> {
    let list = WINDOWS.lock().ok()?;
    for &p in list.iter() {
        let st = unsafe { (p as *mut WindowState).as_ref() }?;
        if st.surface == surface {
            return Some((st.frame.origin.x, st.frame.origin.y, st.frame.size.height));
        }
    }
    None
}

/// Seconds since the backend was loaded.
///
/// EVERY PERFORMANCE QUESTION NEEDS A CLOCK. Without one the log says what happened in what order
/// and nothing about how long any of it took, so "startup is slow" cannot be turned into a number,
/// and a change cannot be shown to have helped. The first call fixes the origin, and register()
/// makes that call at load time so the origin is the process rather than the first window.
pub fn elapsed() -> f64 {
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    START.get_or_init(std::time::Instant::now).elapsed().as_secs_f64()
}

/// Enough distinct values to tell flat fills from rasterised glyphs, and small enough that the
/// linear scan over it stays cheap. Stopping at the cap is reported rather than hidden.
const DISTINCT_CAP: usize = 64;

/// The drawing context, built over the shm pages.
///
/// THIS IS THE X11 PATH WITH ONE CHANGE. X11Window passes NULL for the bytes and lets O2Surface
/// allocate, then copies the result to the server with XPutImage. Here the bytes are the mapping
/// the compositor already reads, so the copy does not exist: AppKit draws and the pixels are
/// already where they need to be.
fn cg_context_for(st: &mut WindowState) -> Object {
    if !st.context.is_null() {
        return st.context;
    }
    if !ensure_backing(st) {
        return std::ptr::null_mut();
    }
    unsafe {
        let surface_cls = objc::objc_getClass(cstr!("O2Surface"));
        let context_cls = objc::objc_getClass(cstr!("O2Context_builtin_FT"));
        if surface_cls.is_null() || context_cls.is_null() {
            println!("cider-wayland-window context=FAILED reason=no-Onyx2D-classes");
            return std::ptr::null_mut();
        }
        let color_space = O2ColorSpaceCreateDeviceRGB();
        let alloc = objc::sel_registerName(cstr!("alloc"));
        let init_surface = objc::sel_registerName(cstr!(
            "initWithBytes:width:height:bitsPerComponent:bytesPerRow:colorSpace:bitmapInfo:"
        ));
        let surface = objc::msg_send_surface_init(
            objc::msg_send0(surface_cls, alloc),
            init_surface,
            // INTO THE MIDDLE OF THE MAPPING when there is a shadow: the surface AppKit draws on
            // is the window, and the ring around it belongs to this backend. A wider stride than
            // the width is exactly how a subrectangle of a bitmap is described.
            (st.pixels as usize
                + (st.margin as usize) * ((st.draw_w + st.margin * 2) as usize) * 4
                + (st.margin as usize) * 4) as *mut c_void,
            st.draw_w as usize,
            st.draw_h as usize,
            8,
            ((st.draw_w + st.margin * 2) * 4) as usize,
            color_space,
            BITMAP_INFO,
        );
        O2ColorSpaceRelease(color_space);
        if surface.is_null() {
            println!("cider-wayland-window context=FAILED reason=no-surface-object");
            return std::ptr::null_mut();
        }
        let init_context = objc::sel_registerName(cstr!("initWithSurface:flipped:"));
        st.context = objc::msg_send_obj_bool(
            objc::msg_send0(context_cls, alloc),
            init_context,
            surface,
            objc::NO,
        );
        if st.context.is_null() {
            println!("cider-wayland-window context=FAILED reason=no-context-object");
        } else {
            println!(
                "cider-wayland-window context=ok number={} size={}x{}",
                st.number, st.draw_w, st.draw_h
            );
        }
        st.context
    }
}

// ---------------------------------------------------------------------------------------------
// The methods. Encodings are spelled out next to each one and checked against CGWindow.h; an
// encoding that disagrees with the signature does not fail at registration, it corrupts arguments
// at the first call.
// ---------------------------------------------------------------------------------------------

// CGRect and CGPoint as the runtime spells them; NSRect is CGRect on this platform. Written as
// LITERALS rather than built with format!, so the pointer handed to class_addMethod points at
// static memory. Whether the runtime copies a type string is a detail of the runtime, and a
// dangling one would corrupt arguments rather than fail.

extern "C" {
    /// Installs the application side traces, which have to be in place before the settings are
    /// read. A window is created long before any input arrives, and headless compositors advertise
    /// no seat at all, so keying the install off the first event misses startup entirely.
    fn cider_wayland_trace_vcl();
}

extern "C" fn init_with_delegate(this: Object, _cmd: Sel, delegate: Object) -> Object {
    unsafe { cider_wayland_trace_vcl() };
    let super_class = unsafe { objc::class_getSuperclass(objc::object_getClass(this)) };
    let mut sup = objc::ObjcSuper { receiver: this, super_class };
    let sel_init = unsafe { objc::sel_registerName(cstr!("init")) };
    let this = unsafe { objc::objc_msgSendSuper(&mut sup, sel_init) };
    if this.is_null() {
        return std::ptr::null_mut();
    }
    let off = STATE_OFFSET.load(Ordering::Acquire);
    if off < 0 {
        return std::ptr::null_mut();
    }
    let mut st = Box::new(WindowState::new());
    st.delegate = delegate;
    st.owner = this;
    // THE DELEGATE ALREADY KNOWS ITS GEOMETRY. NSWindow sets its frame in
    // -initWithContentRect:... which runs BEFORE the platform window exists, so the initial
    // -setFrame: never arrives here and a window that does not ask keeps whatever default this
    // file invented. The widget probe showed exactly that: a 480x360 application drawing into a
    // 512x384 buffer. X11Window reads the same three properties in its own initWithDelegate:.
    if !delegate.is_null() {
        unsafe {
            let frame = objc::msg_send_rect_ret(delegate, objc::sel_registerName(cstr!("frame")));
            if frame.size.width >= 1.0 && frame.size.height >= 1.0 {
                st.frame = frame;
            }
            st.level = objc::msg_send_i64_ret(delegate, objc::sel_registerName(cstr!("level"))) as c_int;
            st.style_mask =
                objc::msg_send_usize_ret(delegate, objc::sel_registerName(cstr!("styleMask")));
        }
    }
    let raw = Box::into_raw(st);
    unsafe {
        let slot = (this as *mut u8).offset(off) as *mut *mut WindowState;
        *slot = raw;
        if !create_surface(&mut *raw) {
            // The surface is what the window IS. Without it every later call would fail one at a
            // time, so failing here lets AppKit see a nil window instead.
            drop(Box::from_raw(raw));
            *slot = std::ptr::null_mut();
            return std::ptr::null_mut();
        }
        register_window(raw);
    }
    this
}

/// Every live window, so a wl_surface arriving on an input event can be turned back into the
/// AppKit objects that own it.
///
/// AN INPUT EVENT NAMES A SURFACE AND NOTHING ELSE. The protocol identifies the destination of a
/// click by wl_surface pointer, and AppKit needs the window delegate and the window number, so
/// something has to hold the correspondence. A list rather than a map because the count is the
/// number of windows an application has open, which is tens, and a linear scan of tens of pointers
/// per event is not worth a hash.
static WINDOWS: std::sync::Mutex<Vec<usize>> = std::sync::Mutex::new(Vec::new());

/// The xdg_surface of a window that is mapped and is a toplevel, which is the only thing a popup
/// may be parented to.
/// THE ANCHOR IS IN THE PARENT COORDINATE SPACE, and the two spaces disagree about which way is
/// up: AppKit puts the origin at the bottom left with y increasing upwards, Wayland at the top left
/// with y increasing downwards. Converting through the parent TOP edge is what makes a menu appear
/// under its title rather than mirrored to the other end of the window.
///
/// One function for both the creation and the reposition, because two copies of this arithmetic
/// would drift and the drift would be invisible: a popup in the wrong place still draws.
unsafe fn fill_positioner(
    positioner: *mut wl::XdgPositioner,
    st: &WindowState,
    parent_left: i64,
    parent_top: i64,
    why: &str,
) {
    let w = (st.frame.size.width as i32).max(1);
    let h = (st.frame.size.height as i32).max(1);
    let local_x = st.frame.origin.x as i64 - parent_left;
    let popup_top = (st.frame.origin.y + st.frame.size.height) as i64;
    let local_y = parent_top - popup_top;

    unsafe {
        wl::cider_xdg_positioner_set_size(positioner, w, h);
        wl::cider_xdg_positioner_set_anchor_rect(
            positioner,
            local_x.max(0) as i32,
            local_y.max(0) as i32,
            1,
            1,
        );
        wl::cider_xdg_positioner_set_anchor(
            positioner,
            wl::cider_xdg_positioner_anchor_bottom_left(),
        );
        wl::cider_xdg_positioner_set_gravity(
            positioner,
            wl::cider_xdg_positioner_gravity_bottom_right(),
        );
        wl::cider_xdg_positioner_set_constraint_adjustment(
            positioner,
            wl::cider_xdg_positioner_constraint_slide_flip(),
        );
    }
    /* THE WHOLE CONVERSION ON ONE LINE. A popup that lands under the pointer instead of below it
     * eats the next click, and the arithmetic has four inputs that are easy to mix up: where the
     * application asked, how big it is, and where the parent thinks its left and top edges are.
     * Printing the result next to the request is the only way to see which of them is wrong. */
    if crate::env_flag!("CIDER_WAYLAND_TRACE_DISPLAY") {
        println!(
            "cider-wayland-window popup={why} number={} asked={},{} size={w}x{h} parent-left={parent_left} parent-top={parent_top} local={local_x},{local_y}",
            st.number,
            st.frame.origin.x as i64,
            st.frame.origin.y as i64,
        );
    }
}

/// MOVE A POPUP THAT IS ALREADY UP, which the protocol only allows through reposition.
///
/// An xdg_popup position is decided by the positioner it was CREATED with and never changes on its
/// own. LibreOffice builds its dropdown list windows during startup, parks them at whatever origin
/// it happens to have, and moves each one into place just before showing it, so every list appeared
/// where its window had been at creation: hard against the left edge of the screen instead of
/// hanging under its own toolbar field.
fn reposition_popup(st: &mut WindowState) {
    if st.popup.is_null() {
        return;
    }
    if unsafe { wl::cider_xdg_popup_can_reposition(st.popup) } == 0 {
        return;
    }
    let Some((_, parent_left, parent_top)) = mapped_toplevel_anchor() else { return };
    let base = session::wm_base();
    if base.is_null() {
        return;
    }
    unsafe {
        let positioner = wl::cider_xdg_wm_base_create_positioner(base);
        if positioner.is_null() {
            return;
        }
        fill_positioner(positioner, st, parent_left, parent_top, "move");
        st.reposition_token = st.reposition_token.wrapping_add(1);
        wl::cider_xdg_popup_reposition(st.popup, positioner, st.reposition_token);
        wl::cider_xdg_positioner_destroy(positioner);
    }
    session::flush();
}

fn mapped_toplevel_xdg() -> Option<*mut wl::XdgSurface> {
    mapped_toplevel_anchor().map(|(xdg, _, _)| xdg)
}

/// The mapped parent AND the edges its coordinate space starts from, which have to come from the
/// same window or a popup lands somewhere nobody asked for.
///
/// PARENT_LEFT and PARENT_TOP used to be stored by whichever titled window was created last, and
/// this application creates titled windows it never shows. One of them, 1004x591 at 125,69, put the
/// top edge at 660 while the window actually on screen had its top at 685, so every popup came out
/// TWENTY FIVE POINTS HIGH. For a menu that is invisible. For a tooltip it is the difference
/// between sitting below the pointer and sitting UNDER it, and a tooltip under the pointer takes
/// the click that was meant for the button beneath: measured, the first click on a toolbar dropdown
/// did nothing at all and the third one opened it.
fn mapped_toplevel_anchor() -> Option<(*mut wl::XdgSurface, i64, i64)> {
    let list = WINDOWS.lock().ok()?;
    for &p in list.iter().rev() {
        let st = unsafe { (p as *mut WindowState).as_ref() }?;
        if st.mapped && st.popup.is_null() && !st.xdg.is_null() {
            let left = st.frame.origin.x as i64;
            let top = (st.frame.origin.y + st.frame.size.height) as i64;
            return Some((st.xdg, left, top));
        }
    }
    None
}

/// The toplevel of a window that is actually MAPPED, which is the only parent a compositor will
/// honour.
///
/// LAST_TITLED_TOPLEVEL is not that. It records the most recent window with a title bar, and this
/// application creates a dozen of those that are never shown: the save panel was being parented to
/// xdg_toplevel#29 while the document on screen was #19, and a parent that is not a real view is
/// ignored, so the panel was tiled beside the document instead of floating over it. Seen on the
/// wire with WAYLAND_DEBUG, which is the only place the two numbers appear side by side.
fn mapped_toplevel() -> Option<*mut wl::XdgToplevel> {
    let list = WINDOWS.lock().ok()?;
    for &p in list.iter().rev() {
        let st = unsafe { (p as *mut WindowState).as_ref() }?;
        if st.mapped && st.popup.is_null() && !st.toplevel.is_null() {
            return Some(st.toplevel);
        }
    }
    None
}

fn register_window(st: *mut WindowState) {
    if let Ok(mut list) = WINDOWS.lock() {
        list.push(st as usize);
    }
}

fn unregister_window(st: *mut WindowState) {
    if let Ok(mut list) = WINDOWS.lock() {
        list.retain(|&p| p != st as usize);
    }
}

/// The window a surface belongs to: its delegate, its owner and its height.
///
/// The HEIGHT comes back because Wayland puts the origin at the TOP left and AppKit puts it at the
/// bottom left, so every coordinate has to be flipped and the flip needs the window height. Doing
/// it at the call site would mean each caller reaching into the state for it.
/// How far the WINDOW is inset inside its surface, for a surface that carries a shadow.
///
/// Pointer coordinates arrive in SURFACE space. With a shadow the surface is bigger than the window
/// and its origin is up and to the left of it, so every pointer position is that much too large:
/// without this a click lands twenty four points down and right of where it was aimed, which reads
/// as an off-by-a-widget bug everywhere at once.
pub fn margin_for_surface(surface: *mut wl::WlSurface) -> f64 {
    let Ok(list) = WINDOWS.lock() else { return 0.0 };
    for &p in list.iter() {
        let Some(st) = (unsafe { (p as *mut WindowState).as_ref() }) else { continue };
        if st.surface == surface {
            return st.margin as f64;
        }
    }
    0.0
}

pub fn window_for_surface(surface: *mut wl::WlSurface) -> Option<(Object, Object, f64, i64)> {
    let list = WINDOWS.lock().ok()?;
    for &p in list.iter() {
        let st = unsafe { (p as *mut WindowState).as_ref() }?;
        if st.surface == surface {
            return Some((st.owner, st.delegate, st.frame.size.height, st.number));
        }
    }
    None
}

extern "C" fn set_delegate(this: Object, _cmd: Sel, delegate: Object) {
    if let Some(st) = unsafe { state(this) } {
        st.delegate = delegate;
    }
}

/// Tear the surface down. AppKit sends this on close and then releases, so anything left here is
/// leaked for the life of the process.
extern "C" fn invalidate(this: Object, _cmd: Sel) {
    if let Some(st) = unsafe { state(this) } {
        // OUT OF THE INPUT REGISTRY FIRST. A surface that is about to lose its buffer can still be
        // named by an event already in the compositor queue, and answering that with a window
        // whose delegate has just been cleared is worse than not answering at all.
        println!("cider-wayland-window invalidate number={}", st.number);
        unregister_window(st as *mut WindowState);
        st.delegate = std::ptr::null_mut();
        st.mapped = false;
        release_backing(st);
        unsafe {
            if !st.surface.is_null() {
                wl::cider_wl_surface_attach(st.surface, std::ptr::null_mut(), 0, 0);
                wl::cider_wl_surface_commit(st.surface);
            }
        }
        session::flush();
    }
}

/// AppKit pushing the delegate's properties down after a batch of changes. Everything it would set
/// is already applied by the individual setters, so this is where the pixels go out.
extern "C" fn sync_delegate_properties(this: Object, _cmd: Sel) {
    if let Some(st) = unsafe { state(this) } {
        present(st);
    }
}

extern "C" fn cgl_context(_this: Object, _cmd: Sel) -> *mut c_void {
    std::ptr::null_mut()
}

extern "C" fn cg_context(this: Object, _cmd: Sel) -> Object {
    match unsafe { state(this) } {
        Some(st) => cg_context_for(st),
        None => std::ptr::null_mut(),
    }
}

extern "C" fn style_mask(this: Object, _cmd: Sel) -> usize {
    unsafe { state(this) }.map(|st| st.style_mask).unwrap_or(0)
}

extern "C" fn set_style_mask(this: Object, _cmd: Sel, mask: usize) {
    if let Some(st) = unsafe { state(this) } {
        st.style_mask = mask;
    }
}

/// Stored, not applied. xdg_shell has no notion of a stacking level: a compositor decides ordering
/// and a client that wants to be on top asks through a protocol this surface does not use. Keeping
/// the value means -level answers honestly if anything asks.
extern "C" fn set_level(this: Object, _cmd: Sel, level: c_int) {
    if let Some(st) = unsafe { state(this) } {
        st.level = level;
    }
}

/*
 * REMEMBERED, THEN APPLIED, because AppKit titles a window before there is anything to title.
 *
 * A panel is given its title while it is being built and the toplevel is created later, when it is
 * first shown; this dropped anything set before that moment, and the compositor listed the window
 * with an EMPTY name -- a blank entry in every window list and switcher on the desktop. The save
 * panel was exactly that case.
 */
extern "C" fn set_title(this: Object, _cmd: Sel, title: Object) {
    let Some(st) = (unsafe { state(this) }) else { return };
    if title.is_null() {
        return;
    }
    unsafe {
        let sel_utf8 = objc::sel_registerName(cstr!("UTF8String"));
        let raw = objc::msg_send0(title, sel_utf8) as *const c_char;
        if raw.is_null() {
            return;
        }
        let owned = std::ffi::CStr::from_ptr(raw).to_owned();
        if !st.toplevel.is_null() {
            wl::cider_xdg_toplevel_set_title(st.toplevel, owned.as_ptr());
            session::flush();
        }
        st.title = Some(owned);
    }
}

/// Put a title on a toplevel that has just been created.
///
/// ASKING THE WINDOW IS MORE RELIABLE THAN REMEMBERING. A title set before this backend had any
/// state for the window is not in st.title, and a window with no title is a blank entry in every
/// window list on the desktop -- the save panel was exactly that, reported by the compositor as the
/// empty string while it plainly says Save inside.
fn apply_pending_title(st: &mut WindowState) {
    if st.toplevel.is_null() {
        return;
    }
    if st.title.is_none() && !st.delegate.is_null() {
        unsafe {
            let title = objc::msg_send0(st.delegate, objc::sel_registerName(cstr!("title")));
            if !title.is_null() {
                let raw = objc::msg_send0(title, objc::sel_registerName(cstr!("UTF8String")))
                    as *const c_char;
                if !raw.is_null() {
                    let owned = std::ffi::CStr::from_ptr(raw).to_owned();
                    if !owned.as_bytes().is_empty() {
                        st.title = Some(owned);
                    }
                }
            }
        }
    }
    if let Some(title) = &st.title {
        unsafe {
            wl::cider_xdg_toplevel_set_title(st.toplevel, title.as_ptr());
        }
    }
}

/// THE COMPOSITOR PLACES THE WINDOW, so only the size is acted on. Wayland gives a client no way
/// to position its own toplevel, by design; the origin is remembered because AppKit reads it back
/// and comparing against a value it never wrote would look like the window moved on its own.
extern "C" fn set_frame(this: Object, _cmd: Sel, frame: NsRect) {
    let Some(st) = (unsafe { state(this) }) else { return };
    let resized = frame.size.width != st.frame.size.width || frame.size.height != st.frame.size.height;
    if resized && crate::env_flag!("CIDER_WAYLAND_TRACE_GEOMETRY") {
        // A SIZE THE COMPOSITOR DID NOT ASK FOR is worth seeing: on a tiling compositor a buffer
        // larger than the configured size is CROPPED, and the part that goes missing is the bottom
        // of the window, which is where a dialog keeps its buttons.
        println!(
            "cider-wayland-setframe number={} asked={}x{} current={}x{}",
            st.number, frame.size.width, frame.size.height,
            st.frame.size.width, st.frame.size.height
        );
    }
    /*
     * THE COMPOSITOR SIZE WINS, when there is one.
     *
     * An application sizes its windows to what it wants; a Wayland client has to use the size it
     * was configured with, and a tiling compositor configures every toplevel. LibreOffice opens a
     * document window at its preferred 1024x656 AFTER the compositor has tiled it to 628x684, and
     * obeying that meant committing a 1024x656 buffer into a 628x684 surface: the compositor shows
     * the part it has and BLACK for the rest, which is the black bottom half of a freshly opened
     * document in docs/wayland-open-two-documents.png.
     *
     * Measured, one line, which is why the trace above exists:
     *     cider-wayland-setframe number=46 asked=1024x656 current=628x684
     *
     * The application is told the real size again rather than silently overruled, so its own layout
     * follows the window instead of drifting from it. A popup sizes itself and keeps that right,
     * and a compositor that never configures anything -- weston headless -- leaves this untouched.
     */
    if st.popup.is_null() {
        if let Some((cw, ch)) = st.configured_size {
            if frame.size.width as i32 != cw || frame.size.height as i32 != ch {
                /*
                 * A SIZE IT WILL NOT GIVE UP IS NOT A SIZE TO ARGUE WITH.
                 *
                 * Told 700x600 by a tiling compositor, the Start Center answers 700x733 and keeps
                 * answering it: the window has a minimum and no amount of telling changes that.
                 * The buffer stays the size the compositor asked for, because that is not ours to
                 * choose, and the BITMAP grows to what the application insists on so that the part
                 * shown is the top of the window rather than a view scrolled 133 rows down with no
                 * title bar and no menu bar. Measured with CIDER_WAYLAND_TRACE_GEOMETRY:
                 *     surface=700x600 frame=700x733 content=700x689+0+0
                 */
                let want_w = frame.size.width as i32;
                let want_h = frame.size.height as i32;
                if want_w > cw || want_h > ch {
                    st.insist_w = want_w.max(cw);
                    st.insist_h = want_h.max(ch);
                }
                st.frame.origin = frame.origin;
                st.frame.size.width = cw as f64;
                st.frame.size.height = ch as f64;
                st.needs_full_display = true;
                st.redraw_until =
                    Some(std::time::Instant::now() + std::time::Duration::from_secs(6));
                st.last_forced_display = None;
                st.nudged = false;
                // TWO FRAME CHANGES ARE OWED: one row short, then the true size. See the comment on
                // nudge_owed in deliver_pending_configures for why the painted-pixel test cannot
                // stand in for this.
                st.nudge_pending = 2;
                // REBUILD BEFORE NOTIFYING, the same order deliver_pending_configures uses: the
                // application draws in answer to a frame change and asks for a context while it
                // does, and the context has to be the one over the new bitmap.
                ensure_backing(st);
                if !st.delegate.is_null() {
                    unsafe {
                        let sel =
                            objc::sel_registerName(cstr!("platformWindow:frameChanged:didSize:"));
                        objc::msg_send_frame_changed(st.delegate, sel, st.owner, st.frame, objc::YES);
                    }
                }
                return;
            }
        }
    }
    let moved = frame.origin.x != st.frame.origin.x || frame.origin.y != st.frame.origin.y;
    st.frame = frame;
    /* A POPUP THAT MOVED HAS TO BE TOLD TO MOVE. Its position was decided by the positioner it was
     * created with, and this application creates its dropdown windows long before it shows one. */
    if !st.popup.is_null() {
        /* EVERY setFrame ON A POPUP, moved or not. Whether the application repositions a dropdown
         * before showing it is the whole question here, and a trace that fires only on a move
         * cannot tell "it never moved" from "the move never reached us". */
        if crate::env_flag!("CIDER_WAYLAND_TRACE_DISPLAY") {
            println!(
                "cider-wayland-window popup=setframe number={} origin={},{} size={}x{} moved={moved} resized={resized}",
                st.number,
                st.frame.origin.x as i64,
                st.frame.origin.y as i64,
                st.frame.size.width as i64,
                st.frame.size.height as i64
            );
        }
        if moved || resized {
            reposition_popup(st);
        }
    }
    if resized {
        // THE CONTEXT DESCRIBES A SIZE, so it cannot outlive one. AppKit is told rather than left
        // holding a context over a mapping that no longer exists, which is the same contract
        // X11Window has through -invalidateContextWithNewSize:.
        release_backing(st);
        st.reported_drawn = false;
        let delegate = st.delegate;
        present(st);
        if !delegate.is_null() {
            unsafe {
                let sel = objc::sel_registerName(cstr!("platformWindowDidInvalidateCGContext:"));
                objc::msg_send_obj(delegate, sel, this);
            }
        }
    }
}

/*
 * THE THREE THINGS A TITLE BAR ASKS THE COMPOSITOR FOR.
 *
 * A Wayland client cannot move, minimise or maximise itself: it asks, and the ask carries the
 * SERIAL of the input event that caused it, which is how a compositor knows the user did it and not
 * a background process. input.rs records the serial of every key and button press for exactly this.
 *
 * They are methods on the platform window because that is what NSThemeFrame can reach: it has the
 * NSWindow, and -[NSWindow platformWindow] is this object.
 */
extern "C" fn cider_begin_interactive_move(this: Object, _cmd: Sel) {
    let Some(st) = (unsafe { state(this) }) else { return };
    let seat = crate::input::seat();
    let serial = crate::input::last_serial();
    if st.toplevel.is_null() || seat.is_null() || serial == 0 {
        return;
    }
    unsafe { wl::cider_xdg_toplevel_move(st.toplevel, seat, serial) };
    session::flush();
}

extern "C" fn cider_set_minimized(this: Object, _cmd: Sel) {
    let Some(st) = (unsafe { state(this) }) else { return };
    if st.toplevel.is_null() {
        return;
    }
    unsafe { wl::cider_xdg_toplevel_set_minimized(st.toplevel) };
    session::flush();
}

extern "C" fn cider_toggle_maximized(this: Object, _cmd: Sel) {
    let Some(st) = (unsafe { state(this) }) else { return };
    if st.toplevel.is_null() {
        return;
    }
    unsafe {
        if st.maximized {
            wl::cider_xdg_toplevel_unset_maximized(st.toplevel);
        } else {
            wl::cider_xdg_toplevel_set_maximized(st.toplevel);
        }
    }
    st.maximized = !st.maximized;
    session::flush();
}

extern "C" fn set_opaque(_this: Object, _cmd: Sel, _value: ObjcBool) {}

/// Per-window alpha needs a subsurface or a compositor extension; XRGB8888 has no alpha channel by
/// definition, so this is recorded as unsupported rather than silently ignored.
extern "C" fn set_alpha_value(_this: Object, _cmd: Sel, _value: f64) {}

/// SHADOWS ARE THE COMPOSITOR'S BUSINESS in Wayland, not the client's. There is nothing to do and
/// nothing missing.
extern "C" fn set_has_shadow(_this: Object, _cmd: Sel, _value: ObjcBool) {}

extern "C" fn rect_noop(_this: Object, _cmd: Sel, _frame: NsRect) {}

extern "C" fn show_window_without_activation(this: Object, _cmd: Sel) {
    if let Some(st) = unsafe { state(this) } {
        st.visible = true;
        st.needs_full_display = true;
        present(st);
    }
}

/*
 * THE OTHER HALF OF SHOWING, which AppKit uses when the whole application comes forward -- and it
 * may only undo what deactivation did.
 *
 * It used to show EVERY window it was sent to, and an application has windows that were never
 * ordered front: LibreOffice keeps one called VCL ImplGetDefaultWindow, 648x200 and empty, which on
 * Apple systems is parked where nobody sees it. Wayland has no offscreen -- the compositor places
 * windows -- so showing it put a blank window on the user desktop, and on a tiling compositor it
 * took a share of the screen. It only appeared when the application was ACTIVATED, which is why a
 * headless run never showed it and a real session always did.
 */
extern "C" fn show_window_for_app_activation(this: Object, _cmd: Sel, _frame: NsRect) {
    if let Some(st) = unsafe { state(this) } {
        if !st.hidden_by_deactivation {
            return;
        }
        st.hidden_by_deactivation = false;
        st.visible = true;
        st.needs_full_display = true;
        present(st);
    }
}

extern "C" fn hide_window_for_app_deactivation(this: Object, _cmd: Sel, _frame: NsRect) {
    let was_visible = unsafe { state(this) }.map(|st| st.visible).unwrap_or(false);
    hide_window(this, _cmd);
    if was_visible {
        if let Some(st) = unsafe { state(this) } {
            st.hidden_by_deactivation = true;
        }
    }
}

/// Unmap by attaching a null buffer, which is how a Wayland client hides a surface: there is no
/// hide request, an unmapped surface is one with no content.
extern "C" fn hide_window(this: Object, _cmd: Sel) {
    if let Some(st) = unsafe { state(this) } {
        /* WHO DISAPPEARED AND WHEN. A window that unmaps is indistinguishable from a compositor
         * that stopped drawing, and both look like a black screen; only the client knows which it
         * did. */
        /*
         * HIDING A HIDDEN WINDOW IS NOT FREE, it is a protocol event.
         *
         * Every call here attaches a null buffer and commits, which UNMAPS the surface. AppKit asks
         * repeatedly -- the file picker was hidden eighteen times in one modal session, seventeen
         * of them while it was already hidden -- and each one resets the surface state the
         * compositor keeps, including the configure it is waiting to have acknowledged. The wire
         * log shows those eighteen unmaps landing BETWEEN a configure and the ack that follows it,
         * and the connection dies on the next ack with
         *     xdg_wm_base error 4 wrong configure serial
         *
         * An unmap that changes nothing is skipped now. That does not fix the modal spin above it,
         * and it is not claimed to.
         */
        if !st.visible && !st.mapped {
            return;
        }
        println!("cider-wayland-window hide number={} visible={}", st.number, st.visible);
        /* AND WHO ASKED. A window that hides itself two seconds after it appears is being ordered
         * out by somebody, and the name and the number cannot say who. The same recipe that named
         * the print crash: the frames, resolved with dladdr, no debugger involved. */
        if crate::env_flag!("CIDER_TRACE_HIDE") {
            unsafe {
                unsafe extern "C" {
                    fn backtrace(buffer: *mut *mut c_void, size: c_int) -> c_int;
                    fn dladdr(addr: *const c_void, info: *mut DlInfo) -> c_int;
                }
                #[repr(C)]
                struct DlInfo {
                    fname: *const std::os::raw::c_char,
                    fbase: *mut c_void,
                    sname: *const std::os::raw::c_char,
                    saddr: *mut c_void,
                }
                let mut frames: [*mut c_void; 20] = [std::ptr::null_mut(); 20];
                let count = backtrace(frames.as_mut_ptr(), 20);
                for i in 1..count as usize {
                    let mut info = DlInfo {
                        fname: std::ptr::null(),
                        fbase: std::ptr::null_mut(),
                        sname: std::ptr::null(),
                        saddr: std::ptr::null_mut(),
                    };
                    if dladdr(frames[i], &mut info) != 0 && !info.sname.is_null() {
                        let name = std::ffi::CStr::from_ptr(info.sname).to_string_lossy();
                        println!("cider-wayland-window   hide-from {name}");
                    }
                }
            }
        }
        /*
         * DESTROY THE ROLE, DO NOT JUST DROP THE BUFFER.
         *
         * Hiding used to attach a null buffer, which unmaps the surface and leaves the objects in
         * place. The compositor treats an unmapped surface as RESET: the configure it sends when
         * the surface comes back belongs to a new generation, our acknowledgement of it is refused,
         * and the connection dies with
         *     xdg_wm_base error 4, wrong configure serial
         * taking every surface with it. That is the black screen behind Insert then Image, and the
         * wire log in the plan has the whole nine line sequence.
         *
         * Real clients hide a toplevel by destroying its role objects and building new ones when it
         * returns, which is what create_surface does from scratch. Order matters and is the
         * protocol: role first, then the xdg_surface, then the wl_surface.
         */
        unsafe {
            if !st.popup.is_null() {
                wl::cider_xdg_popup_destroy(st.popup);
                st.popup = std::ptr::null_mut();
            }
            if !st.toplevel.is_null() {
                wl::cider_xdg_toplevel_destroy(st.toplevel);
                st.toplevel = std::ptr::null_mut();
            }
            if !st.xdg.is_null() {
                wl::cider_xdg_surface_destroy(st.xdg);
                st.xdg = std::ptr::null_mut();
            }
            if !st.surface.is_null() {
                wl::cider_wl_surface_destroy(st.surface);
                st.surface = std::ptr::null_mut();
            }
        }
        release_backing(st);
        st.mapped = false;
        st.visible = false;
        /*
         * AND IT IS NO LONGER CONFIGURED. An unmapped surface starts again: the compositor sends a
         * fresh configure when it comes back, and attaching before that serial is acknowledged is a
         * protocol error, not a picture. This flag was set once at creation and never cleared, so a
         * window that was hidden and shown again attached on the strength of an acknowledgement
         * from minutes earlier.
         *
         * Seen on the wire, and it kills the connection outright:
         *     wl_display#1.error(xdg_wm_base#5, 4, "wrong configure serial: 67")
         * after which the compositor drops every surface, the workspace is empty, the screen is
         * black, and the application carries on drawing into buffers nobody will ever read.
         */
        st.configured = false;
        session::flush();
    }
}

extern "C" fn window_number(this: Object, _cmd: Sel) -> i64 {
    unsafe { state(this) }.map(|st| st.number).unwrap_or(0)
}

/// Stacking is the compositor's, as with -setLevel:.
/*
 * -placeAboveWindow: and -placeBelowWindow:, which are how AppKit ORDERS A WINDOW FRONT.
 *
 * This was a no-op, and that is why nothing appeared once mapping was gated on visibility:
 * -[NSWindow orderWindow:relativeTo:] does not call -showWindowWithoutActivation at all. It sets
 * its own _isVisible directly and tells the platform window to place itself, so THIS is the signal
 * that a window is meant to be on screen. -setIsVisible: is the other route and is used less.
 *
 * Stacking order is not implemented: xdg_shell has no request to place one toplevel above another,
 * because that is the compositor decision. What matters here is the visibility half.
 */
extern "C" fn place_window(this: Object, _cmd: Sel, _other: i64) {
    if let Some(st) = unsafe { state(this) } {
        if !st.visible {
            st.visible = true;
            st.needs_full_display = true;
        }
        present(st);
    }
}

/// A CLIENT CANNOT FOCUS ITSELF in Wayland. The compositor grants focus; xdg_activation exists for
/// the request but needs a token from an existing focused surface, which an app being launched has
/// not got. Presenting is the honest approximation: a mapped surface is one the compositor can
/// choose to focus.
extern "C" fn make_key(this: Object, _cmd: Sel) {
    if let Some(st) = unsafe { state(this) } {
        present(st);
    }
}

extern "C" fn noop(_this: Object, _cmd: Sel) {}

extern "C" fn miniaturize(this: Object, _cmd: Sel) {
    if let Some(st) = unsafe { state(this) } {
        st.miniaturized = true;
    }
}

extern "C" fn deminiaturize(this: Object, _cmd: Sel) {
    if let Some(st) = unsafe { state(this) } {
        st.miniaturized = false;
        present(st);
    }
}

extern "C" fn is_miniaturized(this: Object, _cmd: Sel) -> ObjcBool {
    match unsafe { state(this) } {
        Some(st) if st.miniaturized => YES,
        _ => NO,
    }
}

extern "C" fn disable_flush_window(this: Object, _cmd: Sel) {
    if let Some(st) = unsafe { state(this) } {
        st.flush_disabled += 1;
    }
}

extern "C" fn enable_flush_window(this: Object, _cmd: Sel) {
    if let Some(st) = unsafe { state(this) } {
        st.flush_disabled = (st.flush_disabled - 1).max(0);
    }
}

extern "C" fn flush_buffer(this: Object, _cmd: Sel) {
    if let Some(st) = unsafe { state(this) } {
        // A SUPPRESSED FLUSH AND AN ABSENT ONE LOOK THE SAME FROM OUTSIDE: both leave the
        // compositor showing an old frame forever. Counting them separately is the difference
        // between a stuck disable count and a window nothing ever asks to flush.
        st.flushes += 1;
        if st.flushes <= 3 || st.flushes % 100 == 0 {
            println!(
                "cider-wayland-window flush number={} count={} disabled={}",
                st.number, st.flushes, st.flush_disabled
            );
        }
        if st.flush_disabled == 0 {
            present(st);
        }
    }
}

/// NO POINTER WITHOUT A SEAT. weston headless advertises none, and asking a compositor where the
/// pointer is has no equivalent request in any case: position arrives through motion events. The
/// origin is the value AppKit reads as "nothing to report".
extern "C" fn mouse_location(_this: Object, _cmd: Sel) -> NsPoint {
    NsPoint { x: 0.0, y: 0.0 }
}

extern "C" fn send_event(_this: Object, _cmd: Sel, _event: *mut c_void) {}

extern "C" fn object_noop(_this: Object, _cmd: Sel, _obj: Object) {}

extern "C" fn cgl_noop(_this: Object, _cmd: Sel, _ctx: *mut c_void) {}

/// Subwindows are a real xdg_shell concept (wl_subsurface), and this returns nil until one is
/// needed. AppKit uses subwindows for sheets and drawers, neither of which is on the path to a
/// document window, and a nil here is a missing sheet rather than a dead process.
extern "C" fn create_sub_window(_this: Object, _cmd: Sel, _frame: NsRect) -> Object {
    std::ptr::null_mut()
}

/// Build the class. Returns null if CGWindow is missing, which means CoreGraphics is not loaded.
///
/// # Safety
/// Called once, from the bundle's initialiser.
pub unsafe fn register() -> objc::Class {
    // THE CLOCK STARTS AT LOAD, not at the first window. Otherwise the first thing that asks the
    // time is also what defines zero, and every stamp reads as if it happened immediately.
    println!("cider-wayland-window clock=started t={:.2}", elapsed());
    let methods = [
        objc::MethodDef { sel: cstr!("initWithDelegate:"), types: cstr!("@@:@"), imp: init_with_delegate as *const c_void },
        objc::MethodDef { sel: cstr!("setDelegate:"), types: cstr!("v@:@"), imp: set_delegate as *const c_void },
        objc::MethodDef { sel: cstr!("invalidate"), types: cstr!("v@:"), imp: invalidate as *const c_void },
        objc::MethodDef { sel: cstr!("syncDelegateProperties"), types: cstr!("v@:"), imp: sync_delegate_properties as *const c_void },
        objc::MethodDef { sel: cstr!("cglContext"), types: cstr!("^v@:"), imp: cgl_context as *const c_void },
        objc::MethodDef { sel: cstr!("cgContext"), types: cstr!("@@:"), imp: cg_context as *const c_void },
        objc::MethodDef { sel: cstr!("styleMask"), types: cstr!("Q@:"), imp: style_mask as *const c_void },
        objc::MethodDef { sel: cstr!("setStyleMask:"), types: cstr!("v@:Q"), imp: set_style_mask as *const c_void },
        objc::MethodDef { sel: cstr!("setLevel:"), types: cstr!("v@:i"), imp: set_level as *const c_void },
        objc::MethodDef { sel: cstr!("setTitle:"), types: cstr!("v@:@"), imp: set_title as *const c_void },
        objc::MethodDef { sel: cstr!("setFrame:"), types: cstr!("v@:{CGRect={CGPoint=dd}{CGSize=dd}}"), imp: set_frame as *const c_void },
        objc::MethodDef { sel: cstr!("ciderBeginInteractiveMove"), types: cstr!("v@:"), imp: cider_begin_interactive_move as *const c_void },
        objc::MethodDef { sel: cstr!("ciderSetMinimized"), types: cstr!("v@:"), imp: cider_set_minimized as *const c_void },
        objc::MethodDef { sel: cstr!("ciderToggleMaximized"), types: cstr!("v@:"), imp: cider_toggle_maximized as *const c_void },
        objc::MethodDef { sel: cstr!("setOpaque:"), types: cstr!("v@:c"), imp: set_opaque as *const c_void },
        objc::MethodDef { sel: cstr!("setAlphaValue:"), types: cstr!("v@:d"), imp: set_alpha_value as *const c_void },
        objc::MethodDef { sel: cstr!("setHasShadow:"), types: cstr!("v@:c"), imp: set_has_shadow as *const c_void },
        objc::MethodDef { sel: cstr!("sheetOrderFrontFromFrame:"), types: cstr!("v@:{CGRect={CGPoint=dd}{CGSize=dd}}"), imp: rect_noop as *const c_void },
        objc::MethodDef { sel: cstr!("sheetOrderOutToFrame:"), types: cstr!("v@:{CGRect={CGPoint=dd}{CGSize=dd}}"), imp: rect_noop as *const c_void },
        objc::MethodDef { sel: cstr!("showWindowForAppActivation:"), types: cstr!("v@:{CGRect={CGPoint=dd}{CGSize=dd}}"), imp: show_window_for_app_activation as *const c_void },
        objc::MethodDef { sel: cstr!("hideWindowForAppDeactivation:"), types: cstr!("v@:{CGRect={CGPoint=dd}{CGSize=dd}}"), imp: hide_window_for_app_deactivation as *const c_void },
        objc::MethodDef { sel: cstr!("hideWindow"), types: cstr!("v@:"), imp: hide_window as *const c_void },
        objc::MethodDef { sel: cstr!("showWindowWithoutActivation"), types: cstr!("v@:"), imp: show_window_without_activation as *const c_void },
        objc::MethodDef { sel: cstr!("windowNumber"), types: cstr!("q@:"), imp: window_number as *const c_void },
        objc::MethodDef { sel: cstr!("placeAboveWindow:"), types: cstr!("v@:q"), imp: place_window as *const c_void },
        objc::MethodDef { sel: cstr!("placeBelowWindow:"), types: cstr!("v@:q"), imp: place_window as *const c_void },
        objc::MethodDef { sel: cstr!("makeKey"), types: cstr!("v@:"), imp: make_key as *const c_void },
        objc::MethodDef { sel: cstr!("makeMain"), types: cstr!("v@:"), imp: noop as *const c_void },
        objc::MethodDef { sel: cstr!("captureEvents"), types: cstr!("v@:"), imp: noop as *const c_void },
        objc::MethodDef { sel: cstr!("miniaturize"), types: cstr!("v@:"), imp: miniaturize as *const c_void },
        objc::MethodDef { sel: cstr!("deminiaturize"), types: cstr!("v@:"), imp: deminiaturize as *const c_void },
        objc::MethodDef { sel: cstr!("isMiniaturized"), types: cstr!("c@:"), imp: is_miniaturized as *const c_void },
        objc::MethodDef { sel: cstr!("disableFlushWindow"), types: cstr!("v@:"), imp: disable_flush_window as *const c_void },
        objc::MethodDef { sel: cstr!("enableFlushWindow"), types: cstr!("v@:"), imp: enable_flush_window as *const c_void },
        objc::MethodDef { sel: cstr!("flushBuffer"), types: cstr!("v@:"), imp: flush_buffer as *const c_void },
        objc::MethodDef { sel: cstr!("mouseLocationOutsideOfEventStream"), types: cstr!("{CGPoint=dd}@:"), imp: mouse_location as *const c_void },
        objc::MethodDef { sel: cstr!("sendEvent:"), types: cstr!("v@:^v"), imp: send_event as *const c_void },
        objc::MethodDef { sel: cstr!("addEntriesToDeviceDictionary:"), types: cstr!("v@:@"), imp: object_noop as *const c_void },
        objc::MethodDef { sel: cstr!("flashWindow"), types: cstr!("v@:"), imp: noop as *const c_void },
        objc::MethodDef { sel: cstr!("addCGLContext:"), types: cstr!("v@:^v"), imp: cgl_noop as *const c_void },
        objc::MethodDef { sel: cstr!("removeCGLContext:"), types: cstr!("v@:^v"), imp: cgl_noop as *const c_void },
        objc::MethodDef { sel: cstr!("flushCGLContext:"), types: cstr!("v@:^v"), imp: cgl_noop as *const c_void },
        objc::MethodDef { sel: cstr!("createSubWindowWithFrame:"), types: cstr!("@@:{CGRect={CGPoint=dd}{CGSize=dd}}"), imp: create_sub_window as *const c_void },
    ];
    let (cls, offset) = unsafe {
        objc::register_subclass_with_state(
            cstr!("CGWindowWayland"),
            cstr!("CGWindow"),
            &methods,
            cstr!("_ciderWindowState"),
        )
    };
    if !cls.is_null() {
        STATE_OFFSET.store(offset, Ordering::Release);
    }
    cls
}

/// -newWindowWithDelegate: in one place, so the display and the panel variant share it.
pub fn new_window(delegate: Object) -> Object {
    unsafe {
        let cls = objc::objc_getClass(cstr!("CGWindowWayland"));
        if cls.is_null() {
            println!("cider-wayland-window new=FAILED reason=class-not-registered");
            return std::ptr::null_mut();
        }
        let alloc = objc::sel_registerName(cstr!("alloc"));
        let init = objc::sel_registerName(cstr!("initWithDelegate:"));
        let obj = objc::msg_send0(cls, alloc);
        objc::msg_send_obj(obj, init, delegate)
    }
}
