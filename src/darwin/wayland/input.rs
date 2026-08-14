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
    fn xkb_state_key_get_utf8(
        state: *mut XkbState,
        key: u32,
        buffer: *mut c_char,
        size: usize,
    ) -> c_int;
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
    unsafe {
        cider_wayland_post_mouse(event_type, px, py, height, modifiers, delegate, 0, 0, 0.0, 0.0);
    }
}

extern "C" fn on_pointer_button(
    _data: *mut c_void,
    _pointer: *mut wl::WlPointer,
    _serial: u32,
    _time: u32,
    button: u32,
    state: u32,
) {
    let pressed = state == unsafe { wl::cider_wl_pointer_button_state_pressed() };
    let (surface, px, py, modifiers) = {
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
        (st.pointer_focus, st.pointer_x, st.pointer_y, st.modifiers)
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
            "cider-wayland-input button={button:#x} pressed={pressed} x={px} y={py} type={event_type}"
        );
    }
    unsafe {
        // A click count of 1 rather than 0: a zero count reads as "not a click" and controls that
        // act on a click never fire.
        cider_wayland_post_mouse(event_type, px, py, height, modifiers, delegate, 1, number, 0.0, 0.0);
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

    let (surface, modifiers, text, repeat) = {
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
        (st.keyboard_focus, st.modifiers, text, repeat)
    };

    // A key with no window is not an error: the compositor can deliver one between a focus change
    // and the surface being registered. Dropping it is right; crashing on it is not.
    let number = window::window_for_surface(surface).map(|(_, _, _, n)| n).unwrap_or(0);
    if tracing() {
        println!(
            "cider-wayland-input key={key} pressed={pressed} window={number} text={:?}",
            text.as_ref().map(|t| String::from_utf8_lossy(t).to_string())
        );
    }

    let mut chars = text.unwrap_or_default();
    chars.push(0);
    unsafe {
        cider_wayland_post_key(
            if pressed { 1 } else { 0 },
            modifiers,
            number,
            chars.as_ptr() as *const c_char,
            chars.as_ptr() as *const c_char,
            if repeat { 1 } else { 0 },
            // THE CARBON VIRTUAL KEY CODE, not the evdev one. An application reads the key code
            // and applies its own layout; handing it the raw number means it looks up an unrelated
            // key, which is why every keystroke arrived and nothing appeared.
            cider_wayland_carbon_keycode(keycode),
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
        // The bit positions are the xkb defaults for the standard modifiers. Reading them by name
        // through xkb_keymap_mod_get_index would be better and is the obvious next step; this is
        // correct for every keymap that keeps the usual order, which is all of them in practice.
        let mut flags = 0u64;
        if mods_depressed & (1 << 0) != 0 {
            flags |= NS_SHIFT;
        }
        if mods_locked & (1 << 1) != 0 {
            flags |= NS_ALPHA_SHIFT;
        }
        if mods_depressed & (1 << 2) != 0 {
            flags |= NS_CONTROL;
        }
        if mods_depressed & (1 << 3) != 0 {
            flags |= NS_ALTERNATE;
        }
        if mods_depressed & (1 << 6) != 0 {
            flags |= NS_COMMAND;
        }
        st.modifiers = flags;
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
