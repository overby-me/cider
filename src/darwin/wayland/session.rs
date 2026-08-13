// The one Wayland connection, shared by the display and every window it makes.
//
// -init connected and then DROPPED THE POINTER ON THE FLOOR, which was fine while the only
// question was whether a compositor answers. A window needs the same connection: a surface belongs
// to the wl_display it was created from, and a second connection would be a second client with its
// own registry, its own globals and no relationship to the first.
//
// THE GLOBALS ARE BOUND ONCE, here, for the same reason. Binding is not idempotent: each bind
// creates a new proxy, and a compositor is entitled to object to a client that binds wl_compositor
// once per window.
//
// AtomicPtr RATHER THAN static mut. AppKit is single threaded by convention, so a plain static mut
// would work today, but it is exactly the assumption that stops being true the first time
// something calls into a window from a dispatch queue. The atomics cost nothing measurable here
// and the declaration says what is shared.
use std::os::raw::{c_char, c_void};
use std::sync::atomic::{AtomicPtr, Ordering};

use crate::wl;

static DISPLAY: AtomicPtr<wl::WlDisplay> = AtomicPtr::new(std::ptr::null_mut());
static REGISTRY: AtomicPtr<wl::WlRegistry> = AtomicPtr::new(std::ptr::null_mut());
static COMPOSITOR: AtomicPtr<wl::WlCompositor> = AtomicPtr::new(std::ptr::null_mut());
static SHM: AtomicPtr<wl::WlShm> = AtomicPtr::new(std::ptr::null_mut());
static WM_BASE: AtomicPtr<wl::XdgWmBase> = AtomicPtr::new(std::ptr::null_mut());

/// Where the registry sweep accumulates. Only touched between the add_listener and the roundtrip
/// that drives it, both inside connect(), so it never escapes that call.
static mut SWEEP: Option<wl::Globals> = None;

extern "C" fn on_global(
    _data: *mut c_void,
    _registry: *mut wl::WlRegistry,
    name: u32,
    interface: *const c_char,
    version: u32,
) {
    if interface.is_null() {
        return;
    }
    let Ok(text) = (unsafe { std::ffi::CStr::from_ptr(interface) }).to_str() else {
        return;
    };
    unsafe {
        if let Some(g) = (&raw mut SWEEP).as_mut().and_then(|s| s.as_mut()) {
            g.note(text, name, version);
        }
    }
}

extern "C" fn on_global_remove(_data: *mut c_void, _registry: *mut wl::WlRegistry, _name: u32) {}

/// THE PING MATTERS: a client that never pongs is treated as hung, and the symptom is a window
/// that never appears rather than any error. The listener is registered once, on the shared base.
extern "C" fn on_ping(_data: *mut c_void, base: *mut wl::XdgWmBase, serial: u32) {
    unsafe { wl::cider_xdg_wm_base_pong(base, serial) };
}

/// Connect, sweep the registry and bind what a window needs.
///
/// Returns false with a reason printed if anything is missing, and the caller declines rather than
/// carrying on: a display that answers -screens but cannot make a surface is worse than one that
/// never loaded, because the failure lands somewhere unrelated.
pub fn connect() -> bool {
    if !display().is_null() {
        return true;
    }
    unsafe {
        let display = wl::wl_display_connect(std::ptr::null());
        if display.is_null() {
            println!("cider-wayland-appkit init=declined reason=no-compositor");
            return false;
        }
        let registry = wl::cider_wl_display_get_registry(display);
        if registry.is_null() {
            println!("cider-wayland-appkit init=declined reason=no-registry");
            wl::wl_display_disconnect(display);
            return false;
        }
        SWEEP = Some(wl::Globals::default());
        let listener = wl::RegistryListener {
            global: on_global,
            global_remove: on_global_remove,
        };
        wl::cider_wl_registry_add_listener(registry, &listener, std::ptr::null_mut());
        // One roundtrip delivers the whole advertisement: the compositor sends every global it has
        // as soon as the registry is created, so this is a complete list rather than a sample.
        wl::wl_display_roundtrip(display);
        let globals = (&raw mut SWEEP).as_mut().and_then(|s| s.take()).unwrap_or_default();

        if !globals.can_open_a_window() {
            println!(
                "cider-wayland-appkit init=declined reason=missing-globals compositor={} shm={} xdg_wm_base={}",
                globals.compositor, globals.shm, globals.xdg_wm_base
            );
            wl::wl_display_disconnect(display);
            return false;
        }

        let compositor = wl::cider_wl_registry_bind_compositor(
            registry,
            globals.bound.compositor_name,
            globals.bound.compositor_version,
        );
        let shm = wl::cider_wl_registry_bind_shm(
            registry,
            globals.bound.shm_name,
            globals.bound.shm_version,
        );
        let base = wl::cider_wl_registry_bind_xdg_wm_base(
            registry,
            globals.bound.xdg_name,
            globals.bound.xdg_version,
        );
        if compositor.is_null() || shm.is_null() || base.is_null() {
            println!("cider-wayland-appkit init=declined reason=bind-failed");
            wl::wl_display_disconnect(display);
            return false;
        }
        let ping = wl::XdgWmBaseListener { ping: on_ping };
        wl::cider_xdg_wm_base_add_listener(base, &ping, std::ptr::null_mut());

        DISPLAY.store(display, Ordering::Release);
        REGISTRY.store(registry, Ordering::Release);
        COMPOSITOR.store(compositor, Ordering::Release);
        SHM.store(shm, Ordering::Release);
        WM_BASE.store(base, Ordering::Release);
        println!(
            "cider-wayland-appkit init=ok display=connected globals={} seat={} output={}",
            globals.total, globals.seat, globals.output
        );
        true
    }
}

pub fn display() -> *mut wl::WlDisplay {
    DISPLAY.load(Ordering::Acquire)
}

pub fn compositor() -> *mut wl::WlCompositor {
    COMPOSITOR.load(Ordering::Acquire)
}

pub fn shm() -> *mut wl::WlShm {
    SHM.load(Ordering::Acquire)
}

pub fn wm_base() -> *mut wl::XdgWmBase {
    WM_BASE.load(Ordering::Acquire)
}

/// Push queued requests without waiting for anything. A commit that is never flushed is a window
/// that never appears, and the client sees no error at all.
pub fn flush() {
    let d = display();
    if !d.is_null() {
        unsafe { wl::wl_display_flush(d) };
    }
}

/// Service the connection WITHOUT WAITING, which is what an event loop needs.
///
/// roundtrip is the wrong shape here: it waits for the server to answer a sync, so an application
/// that pumps once per loop iteration would block on every idle pass. This is the sequence
/// libwayland documents for a client with its own loop: drain what is already decoded, flush what
/// is queued, then read whatever has arrived.
///
/// THE SOCKET IS NON-BLOCKING, which is what makes the read safe to do without polling first. That
/// matters more here than in an ordinary client: the descriptor belongs to the HOST libwayland,
/// reached through the forwarding stub, so a guest poll on it would be asking the emulated kernel
/// about a descriptor it has never seen.
pub fn pump() {
    let d = display();
    if d.is_null() {
        return;
    }
    unsafe {
        // prepare_read fails while anything is already decoded, so drain first. The loop is
        // libwayland's own idiom, not a retry.
        while wl::wl_display_prepare_read(d) != 0 {
            if wl::wl_display_dispatch_pending(d) < 0 {
                return;
            }
        }
        wl::wl_display_flush(d);
        if wl::wl_display_read_events(d) < 0 {
            wl::wl_display_cancel_read(d);
            return;
        }
        wl::wl_display_dispatch_pending(d);
    }
}

/// Flush and wait for the server to catch up. Used where the next step depends on an event that
/// has already been asked for, which is the only honest way to wait in this protocol.
pub fn roundtrip() {
    let d = display();
    if !d.is_null() {
        unsafe { wl::wl_display_roundtrip(d) };
    }
}
