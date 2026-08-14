// Pointer and keyboard, which is what makes a window an application rather than a picture.
//
// THE SEAT IS NOT A GLOBAL YOU JUST BIND AND USE. wl_seat announces its CAPABILITIES in an event
// after the bind, and asking for a pointer the compositor has not advertised is a protocol error
// that disconnects the client. weston headless advertises a seat with NO capabilities at all,
// which is why this is driven entirely by the capabilities event and why a backend that requests
// a pointer up front works everywhere except the one compositor the checks run against.
//
// THE KEYMAP COMES FROM THE COMPOSITOR, as a file descriptor holding an xkb keymap. That is not a
// formality: it is what makes a Danish keyboard produce Danish characters. Guessing a layout gives
// an application that is correct on the author's machine and wrong on the user's, which is the
// worst possible split. libxkbcommon reaches this process as a Mach-O forwarding stub, the same
// way libwayland-client does.
use std::os::raw::{c_char, c_int, c_void};

use crate::cstr;
use crate::objc::Object;
use crate::window;
use crate::wl;

/// AppKit event types, from AppKit/NSEvent.h. Spelled out rather than computed: they are a wire
/// format between this file and WaylandEvents.m and a clever mapping would hide a mistake.
const NS_LEFT_MOUSE_DOWN: c_int = 1;
const NS_LEFT_MOUSE_UP: c_int = 2;
const NS_RIGHT_MOUSE_DOWN: c_int = 3;
const NS_RIGHT_MOUSE_UP: c_int = 4;
const NS_MOUSE_MOVED: c_int = 5;
const NS_LEFT_MOUSE_DRAGGED: c_int = 6;
const NS_RIGHT_MOUSE_DRAGGED: c_int = 7;
const NS_SCROLL_WHEEL: c_int = 22;
const NS_OTHER_MOUSE_DOWN: c_int = 25;
const NS_OTHER_MOUSE_UP: c_int = 26;

/// NSEvent modifier masks.
const NS_ALPHA_SHIFT: u64 = 1 << 16;
const NS_SHIFT: u64 = 1 << 17;
const NS_CONTROL: u64 = 1 << 18;
const NS_ALTERNATE: u64 = 1 << 19;
const NS_COMMAND: u64 = 1 << 20;

/// Linux input button codes, from linux/input-event-codes.h. Wayland reports these verbatim.
const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;
const BTN_MIDDLE: u32 = 0x112;

/// A Wayland keycode is an EVDEV code, and xkb numbers the same key eight higher. This offset is
/// the single most commonly forgotten line in a Wayland input implementation: without it every key
/// produces the character of a key a few positions away, which looks like a broken keymap.
const XKB_KEYCODE_OFFSET: u32 = 8;

unsafe extern "C" {
    fn cider_wayland_post_mouse(
        event_type: c_int,
        x: f64,
        y: f64,
        window_height: f64,
        modifiers: u64,
        delegate: Object,
        click_count: c_int,
        button_number: c_int,
        delta_x: f64,
        delta_y: f64,
    );
    fn cider_wayland_post_key(
        is_down: c_int,
        modifiers: u64,
        window_number: i64,
        characters: *const c_char,
        characters_ignoring_modifiers: *const c_char,
        is_repeat: c_int,
        key_code: c_int,
    );
    fn cider_wayland_post_flags_changed(modifiers: u64, window_number: i64);
    fn cider_wayland_set_keyboard_focus(delegate: Object, platform_window: Object);
    fn cider_wayland_carbon_keycode(evdev_keycode: u32) -> c_int;
    fn cider_wayland_carbon_for_keysym(keysym: u32) -> c_int;
    fn cider_wayland_watch_focus_notifications();
}

/// libxkbcommon, which is a host library reached through a forwarding stub.
#[allow(non_camel_case_types)]
enum XkbContext {}
#[allow(non_camel_case_types)]
enum XkbKeymap {}
#[allow(non_camel_case_types)]
enum XkbState {}

unsafe extern "C" {
    fn xkb_context_new(flags: u32) -> *mut XkbContext;
    fn xkb_keymap_new_from_string(
        context: *mut XkbContext,
        string: *const c_char,
        format: u32,
        flags: u32,
    ) -> *mut XkbKeymap;
    fn xkb_keymap_unref(keymap: *mut XkbKeymap);
    fn xkb_state_new(keymap: *mut XkbKeymap) -> *mut XkbState;
    fn xkb_state_unref(state: *mut XkbState);
    fn xkb_state_update_mask(
        state: *mut XkbState,
        depressed_mods: u32,
        latched_mods: u32,
        locked_mods: u32,
        depressed_layout: u32,
        latched_layout: u32,
        locked_layout: u32,
    ) -> u32;
    /// The text a KEYSYM stands for, with no modifier transformation applied.
    ///
    /// This is what -charactersIgnoringModifiers has to answer, and it is not the same string as
    /// the one the state produces: xkbcommon applies the control transformation to the state text,
    /// so Control and A give U+0001 there and the letter a here. AppKit key bindings are written
    /// against the SECOND one, which is why control shortcuts did nothing.
    fn xkb_keysym_to_utf8(keysym: u32, buffer: *mut c_char, size: usize) -> i32;

    fn xkb_state_key_get_utf8(
        state: *mut XkbState,
        key: u32,
        buffer: *mut c_char,
        size: usize,
    ) -> c_int;
    /// The keysym the LAYOUT resolves this key to, which is the only thing that knows what the key
    /// means. The physical keycode does not.
    fn xkb_state_key_get_one_sym(state: *mut XkbState, key: u32) -> u32;
    /// WHICH BIT IS CONTROL is a question for the keymap, not a constant. The conventional order
    /// holds for ordinary layouts and not for synthetic ones, and guessing it wrongly means a
    /// modifier that is never reported.
    fn xkb_keymap_mod_get_index(keymap: *mut XkbKeymap, name: *const c_char) -> u32;
    fn xkb_state_mod_index_is_active(state: *mut XkbState, idx: u32, components: u32) -> c_int;
}

/// xkb_keymap_format: the only text format there is.
const XKB_KEYMAP_FORMAT_TEXT_V1: u32 = 1;

/// Everything input needs to remember between events.
///
/// It is a single global because there is one seat and the Wayland queue is dispatched on the main
/// thread from inside the event pump. A Mutex rather than a static mut so the compiler agrees it
/// is sound, not because there is contention.
struct InputState {
    pointer: *mut wl::WlPointer,
    keyboard: *mut wl::WlKeyboard,
    /// The surface the pointer is over, and where it is on that surface. A button event carries
    /// NEITHER, so both have to be remembered from the enter and motion events that preceded it.
    pointer_focus: *mut wl::WlSurface,
    pointer_x: f64,
    pointer_y: f64,
    /// Which buttons are down, so motion can be reported as a DRAG rather than a move. AppKit
    /// treats those as different events and a text selection needs the drag.
    buttons_down: u32,
    /// Double click state: when the last press was, where it was, and how many in a row.
    last_press_time: u32,
    last_press_x: f64,
    last_press_y: f64,
    click_count: i32,
    keyboard_focus: *mut wl::WlSurface,
    modifiers: u64,
    xkb_context: *mut XkbContext,
    xkb_keymap: *mut XkbKeymap,
    xkb_state: *mut XkbState,
    /// The last key pressed, to recognise auto repeat the way the X11 backend does.
    last_key: u32,
}

unsafe impl Send for InputState {}

static INPUT: std::sync::Mutex<InputState> = std::sync::Mutex::new(InputState {
    pointer: std::ptr::null_mut(),
    keyboard: std::ptr::null_mut(),
    pointer_focus: std::ptr::null_mut(),
    pointer_x: 0.0,
    pointer_y: 0.0,
    buttons_down: 0,
    last_press_time: 0,
    last_press_x: 0.0,
    last_press_y: 0.0,
    click_count: 0,
    keyboard_focus: std::ptr::null_mut(),
    modifiers: 0,
    xkb_context: std::ptr::null_mut(),
    xkb_keymap: std::ptr::null_mut(),
    xkb_state: std::ptr::null_mut(),
    last_key: 0,
});

fn tracing() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("CIDER_WAYLAND_TRACE_INPUT").is_some())
}

/// Attach to a seat. Called once, from the registry sweep.
pub fn attach_seat(seat: *mut wl::WlSeat) {
    if seat.is_null() {
        return;
    }
    unsafe {
        wl::cider_wl_seat_add_listener(seat, &SEAT_LISTENER, std::ptr::null_mut());
    }
}

extern "C" fn on_seat_capabilities(_data: *mut c_void, seat: *mut wl::WlSeat, capabilities: u32) {
    let want_pointer = capabilities & unsafe { wl::cider_wl_seat_capability_pointer() } != 0;
    let want_keyboard = capabilities & unsafe { wl::cider_wl_seat_capability_keyboard() } != 0;
    println!(
        "cider-wayland-input seat=capabilities pointer={} keyboard={}",
        want_pointer, want_keyboard
    );
    let Ok(mut st) = INPUT.lock() else { return };
    unsafe {
        // A WITHDRAWN CAPABILITY MEANS RELEASE, and it is not merely tidy: the next capabilities
        // event that brings the device back has to find us without one, or the guard below keeps
        // the dead proxy and no event is ever delivered again. This is exactly what a virtual
        // pointer does, since it exists only for as long as the tool that created it.
        if !want_pointer && !st.pointer.is_null() {
            wl::cider_wl_pointer_release(st.pointer);
            st.pointer = std::ptr::null_mut();
            st.pointer_focus = std::ptr::null_mut();
            st.buttons_down = 0;
            println!("cider-wayland-input pointer=released");
        }
        if !want_keyboard && !st.keyboard.is_null() {
            wl::cider_wl_keyboard_release(st.keyboard);
            st.keyboard = std::ptr::null_mut();
            st.keyboard_focus = std::ptr::null_mut();
            println!("cider-wayland-input keyboard=released");
        }
        if want_pointer && st.pointer.is_null() {
            st.pointer = wl::cider_wl_seat_get_pointer(seat);
            if !st.pointer.is_null() {
                wl::cider_wl_pointer_add_listener(st.pointer, &POINTER_LISTENER, std::ptr::null_mut());
                println!("cider-wayland-input pointer=attached");
            }
        }
        if want_keyboard && st.keyboard.is_null() {
            st.keyboard = wl::cider_wl_seat_get_keyboard(seat);
            if !st.keyboard.is_null() {
                wl::cider_wl_keyboard_add_listener(st.keyboard, &KEYBOARD_LISTENER, std::ptr::null_mut());
                println!("cider-wayland-input keyboard=attached");
            }
        }
    }
}

extern "C" fn on_seat_name(_data: *mut c_void, _seat: *mut wl::WlSeat, _name: *const c_char) {}

static SEAT_LISTENER: wl::WlSeatListener = wl::WlSeatListener {
    capabilities: on_seat_capabilities,
    name: on_seat_name,
};

// -------------------------------------------------------------------------------------------
// Pointer.

extern "C" fn on_pointer_enter(
    _data: *mut c_void,
    _pointer: *mut wl::WlPointer,
    _serial: u32,
    surface: *mut wl::WlSurface,
    x: i32,
    y: i32,
) {
    let Ok(mut st) = INPUT.lock() else { return };
    st.pointer_focus = surface;
    st.pointer_x = unsafe { wl::cider_wl_fixed_to_double(x) };
    st.pointer_y = unsafe { wl::cider_wl_fixed_to_double(y) };
    if tracing() {
        println!("cider-wayland-input pointer=enter x={} y={}", st.pointer_x, st.pointer_y);
    }
}

extern "C" fn on_pointer_leave(
    _data: *mut c_void,
    _pointer: *mut wl::WlPointer,
    _serial: u32,
    _surface: *mut wl::WlSurface,
) {
    let Ok(mut st) = INPUT.lock() else { return };
    st.pointer_focus = std::ptr::null_mut();
    // The buttons go with the focus. A button released outside the surface is never reported to
    // us, so keeping the state would leave every later move looking like a drag.
    st.buttons_down = 0;
}

extern "C" fn on_pointer_motion(
    _data: *mut c_void,
    _pointer: *mut wl::WlPointer,
    _time: u32,
    x: i32,
    y: i32,
) {
    let (surface, px, py, buttons, modifiers) = {
        let Ok(mut st) = INPUT.lock() else { return };
        st.pointer_x = unsafe { wl::cider_wl_fixed_to_double(x) };
        st.pointer_y = unsafe { wl::cider_wl_fixed_to_double(y) };
        (st.pointer_focus, st.pointer_x, st.pointer_y, st.buttons_down, st.modifiers)
    };
    let Some((_owner, delegate, height, _number)) = window::window_for_surface(surface) else {
        return;
    };
    // A move with a button held is a DRAG, and AppKit routes the two differently: a drag goes to
    // the view that took the mouse down, a move goes to whatever is under the pointer.
    let event_type = if buttons & (1 << 0) != 0 {
        NS_LEFT_MOUSE_DRAGGED
    } else if buttons & (1 << 1) != 0 {
        NS_RIGHT_MOUSE_DRAGGED
    } else {
        NS_MOUSE_MOVED
    };
    // MOTION IS THE ONLY POINTER EVENT WITH NO TRACE, which made a drag that selected nothing
    // impossible to tell from a drag whose motion never arrived. Rate limited because a real
    // pointer produces hundreds of these a second.
    if tracing() {
        use std::sync::atomic::{AtomicU64, Ordering};
        static SEEN: AtomicU64 = AtomicU64::new(0);
        let n = SEEN.fetch_add(1, Ordering::Relaxed) + 1;
        if n <= 4 || n % 50 == 0 {
            println!(
                "cider-wayland-input motion={n} x={px:.0} y={py:.0} buttons={buttons:#x} type={event_type}"
            );
        }
    }
    unsafe {
        // A DRAG CARRIES THE CLICK COUNT OF THE CLICK THAT STARTED IT. AppKit does that, and an
        // application reads it: a drag reported as zero clicks is not a drag that began with a
        // press, so the code that extends a selection never runs. Measured: mouseDown, six
        // mouseDragged and mouseUp all reached LibreOffice, every one of the drags said
        // clickCount=0, and nothing was selected.
        let clicks = if buttons != 0 { 1 } else { 0 };
        cider_wayland_post_mouse(event_type, px, py, height, modifiers, delegate, clicks, 0, 0.0, 0.0);
    }
}

/// How close together in time two presses have to be to count as a double click, in milliseconds.
/// The macOS default is 500 and the Wayland clock is in the same units, so no conversion.
const DOUBLE_CLICK_MS: u32 = 500;
/// And how close in space. A double click is two clicks at the same PLACE; a pointer that moved a
/// long way between them is two separate clicks however fast they were.
const DOUBLE_CLICK_SLOP: f64 = 5.0;

extern "C" fn on_pointer_button(
    _data: *mut c_void,
    _pointer: *mut wl::WlPointer,
    _serial: u32,
    time: u32,
    button: u32,
    state: u32,
) {
    let pressed = state == unsafe { wl::cider_wl_pointer_button_state_pressed() };
    let (surface, px, py, modifiers, clicks) = {
        let Ok(mut st) = INPUT.lock() else { return };
        let bit = match button {
            BTN_LEFT => 1u32 << 0,
            BTN_RIGHT => 1u32 << 1,
            _ => 1u32 << 2,
        };
        if pressed {
            st.buttons_down |= bit;
        } else {
            st.buttons_down &= !bit;
        }
        /*
         * COUNT THE CLICKS. AppKit reports the second press of a double click as clickCount 2, and
         * applications read it: that is how a double click selects a word and how a third click
         * selects a line. This backend reported 1 for every press, so a double click was two single
         * clicks and nothing that needs one could ever happen.
         */
        if pressed {
            let near = (st.pointer_x - st.last_press_x).abs() <= DOUBLE_CLICK_SLOP
                && (st.pointer_y - st.last_press_y).abs() <= DOUBLE_CLICK_SLOP;
            let soon = time.wrapping_sub(st.last_press_time) <= DOUBLE_CLICK_MS;
            st.click_count = if near && soon && st.click_count > 0 {
                st.click_count + 1
            } else {
                1
            };
            st.last_press_time = time;
            st.last_press_x = st.pointer_x;
            st.last_press_y = st.pointer_y;
        }
        (st.pointer_focus, st.pointer_x, st.pointer_y, st.modifiers, st.click_count)
    };
    let Some((_owner, delegate, height, _number)) = window::window_for_surface(surface) else {
        if tracing() {
            println!("cider-wayland-input button=dropped reason=no-window-for-surface");
        }
        return;
    };
    let (event_type, number) = match (button, pressed) {
        (BTN_LEFT, true) => (NS_LEFT_MOUSE_DOWN, 0),
        (BTN_LEFT, false) => (NS_LEFT_MOUSE_UP, 0),
        (BTN_RIGHT, true) => (NS_RIGHT_MOUSE_DOWN, 1),
        (BTN_RIGHT, false) => (NS_RIGHT_MOUSE_UP, 1),
        (BTN_MIDDLE, true) => (NS_OTHER_MOUSE_DOWN, 2),
        (BTN_MIDDLE, false) => (NS_OTHER_MOUSE_UP, 2),
        (_, true) => (NS_OTHER_MOUSE_DOWN, 3),
        (_, false) => (NS_OTHER_MOUSE_UP, 3),
    };
    if tracing() {
        println!(
            "cider-wayland-input button={button:#x} pressed={pressed} x={px} y={py} type={event_type} clicks={clicks}"
        );
    }
    unsafe {
        // A click count of 1 rather than 0: a zero count reads as "not a click" and controls that
        // act on a click never fire.
        cider_wayland_post_mouse(event_type, px, py, height, modifiers, delegate, clicks, number, 0.0, 0.0);
    }
}

extern "C" fn on_pointer_axis(
    _data: *mut c_void,
    _pointer: *mut wl::WlPointer,
    _time: u32,
    axis: u32,
    value: i32,
) {
    let (surface, px, py, modifiers) = {
        let Ok(st) = INPUT.lock() else { return };
        (st.pointer_focus, st.pointer_x, st.pointer_y, st.modifiers)
    };
    let Some((_owner, delegate, height, _number)) = window::window_for_surface(surface) else {
        return;
    };
    // Wayland measures scroll in surface units pointing the way the CONTENT moves; AppKit measures
    // it in lines pointing the way the FINGERS move. Hence the negation and the divisor, which is
    // the conventional ten units per line.
    let amount = -unsafe { wl::cider_wl_fixed_to_double(value) } / 10.0;
    let (dx, dy) = if axis == 0 { (0.0, amount) } else { (amount, 0.0) };
    // THE SCROLL HAD NO TRACE EITHER, so a wheel that does nothing could not be told from a wheel
    // whose events never arrived. Both were live possibilities: this harness could not produce an
    // axis event at all until a virtual pointer device was used.
    if tracing() {
        println!(
            "cider-wayland-input axis={axis} value={value} dx={dx:.2} dy={dy:.2} x={px:.0} y={py:.0}"
        );
    }
    unsafe {
        cider_wayland_post_mouse(NS_SCROLL_WHEEL, px, py, height, modifiers, delegate, 0, 0, dx, dy);
    }
}

extern "C" fn on_pointer_frame(_data: *mut c_void, _pointer: *mut wl::WlPointer) {}
extern "C" fn on_pointer_axis_source(_data: *mut c_void, _pointer: *mut wl::WlPointer, _source: u32) {}
extern "C" fn on_pointer_axis_stop(_data: *mut c_void, _pointer: *mut wl::WlPointer, _time: u32, _axis: u32) {}
extern "C" fn on_pointer_axis_discrete(_data: *mut c_void, _pointer: *mut wl::WlPointer, _axis: u32, _discrete: i32) {}
extern "C" fn on_pointer_axis_value120(_data: *mut c_void, _pointer: *mut wl::WlPointer, _axis: u32, _value: i32) {}
extern "C" fn on_pointer_axis_relative_direction(_data: *mut c_void, _pointer: *mut wl::WlPointer, _axis: u32, _dir: u32) {}

static POINTER_LISTENER: wl::WlPointerListener = wl::WlPointerListener {
    enter: on_pointer_enter,
    leave: on_pointer_leave,
    motion: on_pointer_motion,
    button: on_pointer_button,
    axis: on_pointer_axis,
    frame: on_pointer_frame,
    axis_source: on_pointer_axis_source,
    axis_stop: on_pointer_axis_stop,
    axis_discrete: on_pointer_axis_discrete,
    axis_value120: on_pointer_axis_value120,
    axis_relative_direction: on_pointer_axis_relative_direction,
};

// -------------------------------------------------------------------------------------------
// Keyboard.

extern "C" fn on_keyboard_keymap(
    _data: *mut c_void,
    _keyboard: *mut wl::WlKeyboard,
    format: u32,
    fd: i32,
    size: u32,
) {
    // THE DESCRIPTOR IS OURS TO CLOSE. The compositor sends it once per keymap change and leaks it
    // into this process otherwise, which is a slow failure that looks like nothing at all.
    let mapped = map_keymap(fd, size as usize);
    unsafe {
        close(fd);
    }
    if format != unsafe { wl::cider_wl_keyboard_keymap_format_xkb_v1() } {
        println!("cider-wayland-input keymap=unsupported format={format}");
        return;
    }
    let Some(text) = mapped else {
        println!("cider-wayland-input keymap=FAILED reason=mmap");
        return;
    };
    let Ok(mut st) = INPUT.lock() else { return };
    unsafe {
        if st.xkb_context.is_null() {
            st.xkb_context = xkb_context_new(0);
        }
        if st.xkb_context.is_null() {
            println!("cider-wayland-input keymap=FAILED reason=no-xkb-context");
            return;
        }
        let keymap = xkb_keymap_new_from_string(
            st.xkb_context,
            text.as_ptr() as *const c_char,
            XKB_KEYMAP_FORMAT_TEXT_V1,
            0,
        );
        if keymap.is_null() {
            println!("cider-wayland-input keymap=FAILED reason=parse");
            return;
        }
        let state = xkb_state_new(keymap);
        if state.is_null() {
            xkb_keymap_unref(keymap);
            println!("cider-wayland-input keymap=FAILED reason=no-state");
            return;
        }
        if !st.xkb_state.is_null() {
            xkb_state_unref(st.xkb_state);
        }
        if !st.xkb_keymap.is_null() {
            xkb_keymap_unref(st.xkb_keymap);
        }
        st.xkb_keymap = keymap;
        st.xkb_state = state;
    }
    println!("cider-wayland-input keymap=ok bytes={size}");
}

/// The keymap text, read through a mapping and copied into a NUL terminated buffer.
///
/// xkb_keymap_new_from_string wants a C string. The mapping is not guaranteed to be NUL terminated
/// on every compositor, so it is copied rather than pointed at.
fn map_keymap(fd: i32, size: usize) -> Option<Vec<u8>> {
    if fd < 0 || size == 0 {
        return None;
    }
    const PROT_READ: c_int = 1;
    const MAP_PRIVATE: c_int = 2;
    let map = unsafe { mmap(std::ptr::null_mut(), size, PROT_READ, MAP_PRIVATE, fd, 0) };
    if map.is_null() || map as isize == -1 {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(map as *const u8, size) };
    let mut out = Vec::with_capacity(size + 1);
    // Up to the first NUL if there is one, so a terminated mapping does not produce a string with
    // a NUL in the middle.
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(size);
    out.extend_from_slice(&bytes[..end]);
    out.push(0);
    unsafe {
        munmap(map, size);
    }
    Some(out)
}

unsafe extern "C" {
    fn mmap(addr: *mut c_void, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) -> *mut c_void;
    fn munmap(addr: *mut c_void, len: usize) -> c_int;
    fn close(fd: c_int) -> c_int;
}

extern "C" fn on_keyboard_enter(
    _data: *mut c_void,
    _keyboard: *mut wl::WlKeyboard,
    _serial: u32,
    surface: *mut wl::WlSurface,
    _keys: *mut c_void,
) {
    {
        let Ok(mut st) = INPUT.lock() else { return };
        st.keyboard_focus = surface;
    }
    // ACTIVATION, not just focus bookkeeping. AppKit sends text to the first responder of the KEY
    // window, and nothing here made a window key, so keystrokes were delivered and discarded.
    //
    // WHICH window is activated is printed because it is not the same question as which window the
    // keys are addressed to: the compositor decides focus, and a key event that names one window
    // while another is key goes to a first responder that is not there.
    unsafe { cider_wayland_watch_focus_notifications() };
    match window::window_for_surface(surface) {
        Some((owner, delegate, _height, number)) => {
            if tracing() {
                println!("cider-wayland-input keyboard=enter activating=window{number}");
            }
            unsafe { cider_wayland_set_keyboard_focus(delegate, owner) };
        }
        None => {
            if tracing() {
                println!("cider-wayland-input keyboard=enter activating=NONE-no-window-for-surface");
            }
        }
    }
}

extern "C" fn on_keyboard_leave(
    _data: *mut c_void,
    _keyboard: *mut wl::WlKeyboard,
    _serial: u32,
    _surface: *mut wl::WlSurface,
) {
    {
        let Ok(mut st) = INPUT.lock() else { return };
        st.keyboard_focus = std::ptr::null_mut();
    }
    unsafe { cider_wayland_set_keyboard_focus(std::ptr::null_mut(), std::ptr::null_mut()) };
}


/// The Unicode code point AppKit puts in -characters for a key that has no printable character.
///
/// THIS IS NOT DECORATION. AppKit does not deliver an arrow key or Page Down as an empty string: it
/// delivers a character in the private use block, 0xF700 upwards, and every key binding table in
/// the framework and in applications is written against those values. xkbcommon produces nothing at
/// all for these keys, so the event arrived with an empty -characters, no binding could match it,
/// and the application saw a keystroke with no content.
///
/// Measured before fixing: Page Down and Home reached this backend with the right keysyms and the
/// right Carbon codes, and NOTHING reached -[SalFrameView keyDown:]. Arrows, Home, End, Page Up and
/// Page Down, the function keys and forward delete were all in that state, which is most of moving
/// around a document.
fn appkit_function_key(keysym: u32) -> Option<(u32, bool)> {
    // (code point, is an arrow). AppKit marks arrows with the numeric pad flag as well, which is
    // what the framework key binding table matches on.
    let mapped = match keysym {
        0xff52 => (0xF700, true),  // Up
        0xff54 => (0xF701, true),  // Down
        0xff51 => (0xF702, true),  // Left
        0xff53 => (0xF703, true),  // Right
        0xffbe => (0xF704, false), // F1
        0xffbf => (0xF705, false),
        0xffc0 => (0xF706, false),
        0xffc1 => (0xF707, false),
        0xffc2 => (0xF708, false),
        0xffc3 => (0xF709, false),
        0xffc4 => (0xF70A, false),
        0xffc5 => (0xF70B, false),
        0xffc6 => (0xF70C, false),
        0xffc7 => (0xF70D, false),
        0xffc8 => (0xF70E, false),
        0xffc9 => (0xF70F, false), // F12
        0xff63 => (0xF727, false), // Insert
        0xffff => (0xF728, false), // Forward delete
        0xff50 => (0xF729, false), // Home
        0xff57 => (0xF72B, false), // End
        0xff55 => (0xF72C, false), // Page Up
        0xff56 => (0xF72D, false), // Page Down
        0xff61 => (0xF72E, false), // Print Screen
        0xff14 => (0xF72F, false), // Scroll Lock
        0xff13 => (0xF730, false), // Pause
        _ => return None,
    };
    Some(mapped)
}

/// AppKit sets this for every key in the function block.
const NS_FUNCTION_KEY_MASK: u64 = 1 << 23;
/// And this as well for the arrows.
const NS_NUMERIC_PAD_MASK: u64 = 1 << 21;

extern "C" fn on_keyboard_key(
    _data: *mut c_void,
    _keyboard: *mut wl::WlKeyboard,
    _serial: u32,
    _time: u32,
    key: u32,
    state: u32,
) {
    let pressed = state == unsafe { wl::cider_wl_keyboard_key_state_pressed() };
    let keycode = key + XKB_KEYCODE_OFFSET;

    let (surface, modifiers, text, repeat, keysym) = {
        let Ok(mut st) = INPUT.lock() else { return };
        let mut buffer = [0u8; 64];
        let text = if st.xkb_state.is_null() {
            None
        } else {
            let n = unsafe {
                xkb_state_key_get_utf8(
                    st.xkb_state,
                    keycode,
                    buffer.as_mut_ptr() as *mut c_char,
                    buffer.len(),
                )
            };
            if n > 0 && (n as usize) < buffer.len() {
                Some(buffer[..n as usize].to_vec())
            } else {
                None
            }
        };
        let repeat = pressed && st.last_key == key;
        st.last_key = if pressed { key } else { 0 };
        // THE KEYSYM, which is what the layout resolved this key to. The physical code alone
        // cannot say what the key means on anything but a US keyboard.
        let keysym = if st.xkb_state.is_null() {
            0
        } else {
            unsafe { xkb_state_key_get_one_sym(st.xkb_state, keycode) }
        };
        (st.keyboard_focus, st.modifiers, text, repeat, keysym)
    };

    /*
     * PREFER THE KEYSYM, fall back to the physical table.
     *
     * Translating the raw evdev number through a fixed US layout table is right on a US keyboard
     * and wrong everywhere else, and it fails SILENTLY: the character is correct while the key code
     * names an unrelated key. LibreOffice reads the key code to decide what a keystroke means, so
     * it was being told Escape and handed the letter h at the same time, and it believed the code.
     *
     * The fallback remains for keys the keysym table does not name, where the physical guess is
     * better than nothing.
     */
    let carbon = {
        let from_sym = unsafe { cider_wayland_carbon_for_keysym(keysym) };
        if from_sym >= 0 {
            from_sym
        } else {
            unsafe { cider_wayland_carbon_keycode(keycode) }
        }
    };

    // A key with no window is not an error: the compositor can deliver one between a focus change
    // and the surface being registered. Dropping it is right; crashing on it is not.
    let number = window::window_for_surface(surface).map(|(_, _, _, n)| n).unwrap_or(0);
    if tracing() {
        println!(
            "cider-wayland-input key={key} keysym={keysym:#x} carbon={carbon} pressed={pressed} window={number} text={:?}",
            text.as_ref().map(|t| String::from_utf8_lossy(t).to_string())
        );
    }

    /*
     * A KEY WITH NO PRINTABLE CHARACTER STILL HAS A CHARACTER, in AppKit terms. Substituting the
     * function block code point is what makes arrows, Home, End, Page Up and Page Down and the
     * function keys exist at all above this layer.
     */
    let (mut chars, modifiers) = match appkit_function_key(keysym) {
        Some((code, is_arrow)) => {
            let mut extra = NS_FUNCTION_KEY_MASK;
            if is_arrow {
                extra |= NS_NUMERIC_PAD_MASK;
            }
            let mut encoded = [0u8; 4];
            let text = char::from_u32(code)
                .map(|c| c.encode_utf8(&mut encoded).as_bytes().to_vec())
                .unwrap_or_default();
            (text, modifiers | extra)
        }
        None => (text.unwrap_or_default(), modifiers),
    };
    chars.push(0);
    /*
     * THE TWO STRINGS ARE NOT THE SAME STRING.
     *
     * -characters is what the key produced WITH the modifiers applied, and -charactersIgnoringModifiers
     * is what it would have produced without them. AppKit key equivalents and key bindings are
     * matched against the second, so sending the first for both means every control and command
     * shortcut is looked up under a character nobody wrote a binding for.
     *
     * Measured: Control and A arrived as U+0001 in both, the binding for control plus a was never
     * found, and the application inserted the control character into the document instead of
     * selecting anything.
     */
    let mut bare = if appkit_function_key(keysym).is_some() {
        // A function key has no unmodified spelling that differs; both strings are the code point.
        chars.clone()
    } else {
        let mut buffer = [0u8; 64];
        let n = unsafe {
            xkb_keysym_to_utf8(keysym, buffer.as_mut_ptr() as *mut c_char, buffer.len())
        };
        if n > 1 {
            buffer[..(n as usize - 1)].to_vec()
        } else {
            chars.clone()
        }
    };
    if bare.last() != Some(&0) {
        bare.push(0);
    }
    unsafe {
        cider_wayland_post_key(
            if pressed { 1 } else { 0 },
            modifiers,
            number,
            chars.as_ptr() as *const c_char,
            bare.as_ptr() as *const c_char,
            if repeat { 1 } else { 0 },
            // THE CARBON VIRTUAL KEY CODE, not the evdev one. An application reads the key code
            // and applies its own layout; handing it the raw number means it looks up an unrelated
            // key, which is why every keystroke arrived and nothing appeared.
            carbon,
        );
    }
}

extern "C" fn on_keyboard_modifiers(
    _data: *mut c_void,
    _keyboard: *mut wl::WlKeyboard,
    _serial: u32,
    mods_depressed: u32,
    mods_latched: u32,
    mods_locked: u32,
    group: u32,
) {
    let (modifiers, surface) = {
        let Ok(mut st) = INPUT.lock() else { return };
        if !st.xkb_state.is_null() {
            unsafe {
                xkb_state_update_mask(
                    st.xkb_state,
                    mods_depressed,
                    mods_latched,
                    mods_locked,
                    0,
                    0,
                    group,
                );
            }
        }
        /*
         * ASK THE KEYMAP WHICH BIT IS WHICH. The bit positions used before were the conventional
         * xkb order, which holds for ordinary layouts and not for synthetic ones, and a wrong
         * guess means a modifier that is simply never reported: every shortcut misses and nothing
         * says why. This is the same mistake the key codes had, one layer along.
         *
         * XKB_STATE_MODS_EFFECTIVE, so a latched or locked modifier counts as held, which is what
         * an application means by asking whether shift is down.
         */
        const EFFECTIVE: u32 = 1 << 3;
        let mut flags = 0u64;
        if !st.xkb_state.is_null() && !st.xkb_keymap.is_null() {
            let active = |name: &std::ffi::CStr| -> bool {
                unsafe {
                    let idx = xkb_keymap_mod_get_index(st.xkb_keymap, name.as_ptr());
                    idx != u32::MAX
                        && xkb_state_mod_index_is_active(st.xkb_state, idx, EFFECTIVE) > 0
                }
            };
            if active(c"Shift") {
                flags |= NS_SHIFT;
            }
            if active(c"Lock") {
                flags |= NS_ALPHA_SHIFT;
            }
            if active(c"Control") {
                flags |= NS_CONTROL;
            }
            if active(c"Mod1") {
                flags |= NS_ALTERNATE;
            }
            if active(c"Mod4") {
                flags |= NS_COMMAND;
            }
        } else {
            // No keymap yet: the conventional order is the only thing left, and it is better than
            // reporting nothing at all.
            if mods_depressed & (1 << 0) != 0 {
                flags |= NS_SHIFT;
            }
            if mods_locked & (1 << 1) != 0 {
                flags |= NS_ALPHA_SHIFT;
            }
            if mods_depressed & (1 << 2) != 0 {
                flags |= NS_CONTROL;
            }
        }
        st.modifiers = flags;
        if tracing() {
            println!(
                "cider-wayland-input modifiers={flags:#x} depressed={mods_depressed:#x} latched={mods_latched:#x} locked={mods_locked:#x}"
            );
        }
        (flags, st.keyboard_focus)
    };
    let number = window::window_for_surface(surface).map(|(_, _, _, n)| n).unwrap_or(0);
    unsafe {
        cider_wayland_post_flags_changed(modifiers, number);
    }
}

extern "C" fn on_keyboard_repeat_info(
    _data: *mut c_void,
    _keyboard: *mut wl::WlKeyboard,
    _rate: i32,
    _delay: i32,
) {
}

static KEYBOARD_LISTENER: wl::WlKeyboardListener = wl::WlKeyboardListener {
    keymap: on_keyboard_keymap,
    enter: on_keyboard_enter,
    leave: on_keyboard_leave,
    key: on_keyboard_key,
    modifiers: on_keyboard_modifiers,
    repeat_info: on_keyboard_repeat_info,
};

/// The pointer position, for -mouseLocation. AppKit asks the display where the pointer is, and
/// Wayland has no request that answers it: the position is only ever known from the events that
/// reported it, which is exactly what this returns.
pub fn pointer_location() -> (f64, f64) {
    match INPUT.lock() {
        Ok(st) => (st.pointer_x, st.pointer_y),
        Err(_) => (0.0, 0.0),
    }
}

/// The pointer position in SCREEN coordinates, which is what -[NSEvent mouseLocation] answers.
///
/// Wayland reports motion in surface coordinates with y increasing downwards, and AppKit wants the
/// screen with y increasing upwards, so this is the window origin plus the flipped local position.
/// Applications ask this before deciding which widget an event belongs to: LibreOffice does it for
/// every scroll wheel event, and with the origin as the answer the wheel was applied to a point
/// outside the window, so eight scroll events reached its own scrollWheel: and moved nothing.
pub fn pointer_screen_location() -> (f64, f64) {
    let (surface, x, y) = match INPUT.lock() {
        Ok(st) => (st.pointer_focus, st.pointer_x, st.pointer_y),
        Err(_) => return (0.0, 0.0),
    };
    match window::frame_for_surface(surface) {
        Some((origin_x, origin_y, height)) => (origin_x + x, origin_y + (height - y)),
        None => (x, y),
    }
}

/// The current modifier flags, for -currentModifierFlags.
pub fn modifier_flags() -> u64 {
    match INPUT.lock() {
        Ok(st) => st.modifiers,
        Err(_) => 0,
    }
}

/// Referenced so the constant is not dead code while the keymap path is the only user of cstr.
#[allow(dead_code)]
fn _keep_cstr_used() -> *const c_char {
    cstr!("cider")
}
