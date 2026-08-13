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
    // WHAT THE GUEST ACTUALLY SEES, printed before anything is attempted. The first run failed
    // with connect=FAILED and no way to tell whether the variables were missing, the path was
    // wrong, or the socket was unreachable, which is three guesses too many.
    for key in ["WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "CIDER_WAYLAND_SOCKET"] {
        match std::env::var(key) {
            Ok(v) => println!("cider-wayland-probe env {key}={v}"),
            Err(_) => println!("cider-wayland-probe env {key}=<unset>"),
        }
    }

    // DOES THE BRIDGE WORK AT ALL? Asked before connect, because a failed connect has many
    // causes and "the stub never reached libwayland" is the one that makes every other answer
    // meaningless. wl_list_init writes two pointers into a struct owned here.
    let mut list = wl::WlList { prev: std::ptr::null_mut(), next: std::ptr::null_mut() };
    unsafe { wl::wl_list_init(&mut list) };
    let self_ptr = &mut list as *mut wl::WlList;
    println!(
        "cider-wayland-probe bridge={}",
        if list.prev == self_ptr && list.next == self_ptr { "ok" } else { "FAILED" }
    );

    let mut display = unsafe { wl::wl_display_connect(std::ptr::null()) };
    if display.is_null() {
        println!("cider-wayland-probe connect(default)=FAILED");
        // AN ABSOLUTE PATH BYPASSES THE ENVIRONMENT ENTIRELY. libwayland treats a display name
        // beginning with / as the socket path itself, so this says whether the failure is the
        // variables not arriving or the socket not being reachable, which are different bugs.
        if let Ok(sock) = std::env::var("CIDER_WAYLAND_SOCKET") {
            let c = std::ffi::CString::new(sock.clone()).unwrap_or_default();
            display = unsafe { wl::wl_display_connect(c.as_ptr()) };
            if display.is_null() {
                // ERRNO IS THE WHOLE ANSWER HERE. ENOENT means the path is wrong from inside the
                // container, EACCES means it is there and we may not open it, ECONNREFUSED means
                // nothing is listening, and ENOSYS or EPERM would mean the emulation layer did
                // not let the call through at all. Guessing between those cost several runs.
                let e = std::io::Error::last_os_error();
                println!(
                    "cider-wayland-probe connect(absolute)=FAILED path={sock} errno={} msg={}",
                    e.raw_os_error().unwrap_or(-1),
                    e
                );
                // FALL THROUGH to the guest-socket attempt: the three attempts test three
                // different claims, and the later ones are the informative ones.
            }
            if !display.is_null() {
                println!("cider-wayland-probe connect(absolute)=ok path={sock}");
            }
        }
        // THIRD ATTEMPT, and it tests a different claim: let the GUEST open the socket with its
        // own syscalls and hand the descriptor over. libwayland then never touches a path or the
        // environment. If this works and the others do not, the failure is in the host side of
        // the process seeing a different filesystem or environment than the guest, which is
        // exactly the split this container has.
        if display.is_null() {
            if let Ok(guest_path) = std::env::var("CIDER_WAYLAND_SOCKET_GUEST") {
                match std::os::unix::net::UnixStream::connect(&guest_path) {
                    Ok(stream) => {
                        use std::os::unix::io::IntoRawFd;
                        let fd = stream.into_raw_fd();
                        println!("cider-wayland-probe guest-socket=ok fd={fd} path={guest_path}");
                        display = unsafe { wl::wl_display_connect_to_fd(fd) };
                        if display.is_null() {
                            println!("cider-wayland-probe connect(fd)=FAILED");
                            return 1;
                        }
                        println!("cider-wayland-probe connect(fd)=ok");
                    }
                    Err(e) => {
                        println!("cider-wayland-probe guest-socket=FAILED path={guest_path} err={e}");
                        return 1;
                    }
                }
            } else {
                return 1;
            }
        }
    } else {
        println!("cider-wayland-probe connect=ok");
    }

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
