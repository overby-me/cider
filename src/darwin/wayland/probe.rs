// THE WAYLAND PROBE (#112): the smallest guest program that proves the bridge end to end.
//
// It is deliberately NOT the backend. Before 7,000 lines of CoreGraphics backend get written,
// one program should establish that a Mach-O binary running under Cider can reach the host's
// Wayland library AT RUNTIME, which is a different claim from linking against a stub. It
// connects, sweeps the registry and names what it found.
//
// Shape is the same as src/darwin/rustprobe: a staticlib with a C `main` for crt1, because
// Rust's lang_start never runs in this port.
//
// WHAT A FAILURE MEANS, in order, so a first run says how far it got:
//   connect fails            WAYLAND_DISPLAY is unset or the socket is not reachable from inside
//                            the container, which is a prefix or environment problem
//   connect works, 0 globals the roundtrip did not deliver events, so the stub forwards calls but
//                            something in the dispatch path is wrong
//   globals but no compositor the compositor is too old or refused the interfaces
use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_void};

mod wl;

use wl::{Globals, RegistryListener, WlRegistry};

extern "C" fn on_global(
    data: *mut c_void,
    _registry: *mut WlRegistry,
    _name: u32,
    interface: *const c_char,
    _version: u32,
) {
    if data.is_null() || interface.is_null() {
        return;
    }
    // SAFETY: `data` is the Globals we passed to add_listener, and libwayland hands back the
    // same pointer; `interface` is a NUL terminated string owned by the connection.
    let globals = unsafe { &mut *(data as *mut Globals) };
    let name = unsafe { CStr::from_ptr(interface) };
    globals.note(&name.to_string_lossy());
}

extern "C" fn on_global_remove(_data: *mut c_void, _registry: *mut WlRegistry, _name: u32) {}

#[unsafe(no_mangle)]
pub extern "C" fn main(_argc: c_int, _argv: *const *const c_char) -> c_int {
    let display = unsafe { wl::wl_display_connect(std::ptr::null()) };
    if display.is_null() {
        println!("cider-wayland-probe connect=FAILED");
        return 1;
    }
    println!("cider-wayland-probe connect=ok");

    let mut globals = Globals::default();
    let listener = RegistryListener {
        global: on_global,
        global_remove: on_global_remove,
    };

    let registry = unsafe { wl::cider_wl_display_get_registry(display) };
    if registry.is_null() {
        println!("cider-wayland-probe registry=FAILED");
        unsafe { wl::wl_display_disconnect(display) };
        return 1;
    }

    unsafe {
        wl::cider_wl_registry_add_listener(
            registry,
            &listener,
            &mut globals as *mut Globals as *mut c_void,
        );
        // ONE ROUNDTRIP IS ENOUGH for the initial burst: the compositor sends every global it has
        // as soon as the registry is created, and roundtrip waits for that to be processed.
        wl::wl_display_roundtrip(display);
    }

    println!(
        "cider-wayland-probe globals={} compositor={} shm={} xdg_wm_base={} seat={} output={}",
        globals.total,
        globals.compositor,
        globals.shm,
        globals.xdg_wm_base,
        globals.seat,
        globals.output
    );

    let ok = globals.can_open_a_window();
    println!("cider-wayland-probe can_open_a_window={ok}");
    unsafe { wl::wl_display_disconnect(display) };
    if ok { 0 } else { 1 }
}
