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
    globals.note(&name.to_string_lossy(), _name, _version);
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

    // ACTUALLY OPEN ONE. Binding, a surface, an xdg_toplevel and a round trip is the exact
    // machinery CGSWindow and CGSSurface will need, so proving it here means the backend is
    // wiring known-good pieces rather than debugging two things at once.
    if ok {
        let configured = open_a_window(display, registry, &globals);
        println!("cider-wayland-probe window={}", if configured { "configured" } else { "FAILED" });
        if !configured {
            unsafe { wl::wl_display_disconnect(display) };
            return 1;
        }
    }
    unsafe { wl::wl_display_disconnect(display) };
    if ok { 0 } else { 1 }
}

/// The compositor acknowledges a surface by CONFIGURING it, and a client that does not ack the
/// serial is never mapped. That handshake is the whole test: it means the protocol objects were
/// created, the ids were valid and the round trip completed.
static mut CONFIGURED: bool = false;

extern "C" fn on_xdg_configure(_data: *mut c_void, surface: *mut wl::XdgSurface, serial: u32) {
    unsafe {
        wl::cider_xdg_surface_ack_configure(surface, serial);
        CONFIGURED = true;
    }
}

extern "C" fn on_ping(_data: *mut c_void, base: *mut wl::XdgWmBase, serial: u32) {
    // A client that never pongs is treated as hung, and the symptom is a window that never
    // appears rather than an error.
    unsafe { wl::cider_xdg_wm_base_pong(base, serial) };
}

fn open_a_window(
    display: *mut wl::WlDisplay,
    registry: *mut wl::WlRegistry,
    globals: &wl::Globals,
) -> bool {
    unsafe {
        let compositor = wl::cider_wl_registry_bind_compositor(
            registry,
            globals.bound.compositor_name,
            globals.bound.compositor_version,
        );
        let base = wl::cider_wl_registry_bind_xdg_wm_base(
            registry,
            globals.bound.xdg_name,
            globals.bound.xdg_version,
        );
        if compositor.is_null() || base.is_null() {
            println!("cider-wayland-probe bind=FAILED");
            return false;
        }
        let ping = wl::XdgWmBaseListener { ping: on_ping };
        wl::cider_xdg_wm_base_add_listener(base, &ping, std::ptr::null_mut());

        let surface = wl::cider_wl_compositor_create_surface(compositor);
        if surface.is_null() {
            println!("cider-wayland-probe surface=FAILED");
            return false;
        }
        let xdg = wl::cider_xdg_wm_base_get_xdg_surface(base, surface);
        let toplevel = wl::cider_xdg_surface_get_toplevel(xdg);
        if xdg.is_null() || toplevel.is_null() {
            println!("cider-wayland-probe toplevel=FAILED");
            return false;
        }
        let title = std::ffi::CString::new("cider wayland probe").unwrap_or_default();
        wl::cider_xdg_toplevel_set_title(toplevel, title.as_ptr());

        let listener = wl::XdgSurfaceListener { configure: on_xdg_configure };
        wl::cider_xdg_surface_add_listener(xdg, &listener, std::ptr::null_mut());

        // COMMIT FIRST, WITHOUT A BUFFER. That is the protocol: an empty commit asks the
        // compositor for a configure, and only then may pixels be attached.
        wl::cider_wl_surface_commit(surface);
        for _ in 0..5 {
            wl::wl_display_roundtrip(display);
            if CONFIGURED {
                break;
            }
        }
        if !CONFIGURED {
            return false;
        }

        // NOW THE PIXELS, which is the part a CGSSurface exists to do.
        let shm = wl::cider_wl_registry_bind_shm(registry, globals.bound.shm_name, globals.bound.shm_version);
        if shm.is_null() {
            println!("cider-wayland-probe shm-bind=FAILED");
            return false;
        }
        match present_a_buffer(display, shm, surface) {
            Ok(()) => true,
            Err(why) => {
                println!("cider-wayland-probe pixels=FAILED {why}");
                false
            }
        }
    }
}

static mut RELEASED: bool = false;
static mut PRESENTED: bool = false;

extern "C" fn on_buffer_release(_data: *mut c_void, _buffer: *mut wl::WlBuffer) {
    unsafe { RELEASED = true };
}

extern "C" fn on_frame_done(_data: *mut c_void, _cb: *mut wl::WlCallback, _time: u32) {
    unsafe { PRESENTED = true };
}

/// Fill a buffer, attach it, and wait for the compositor to RELEASE it.
///
/// The release is the assertion. Attaching proves nothing on its own: the client can hand over a
/// buffer the compositor never reads. A release event means it finished with those pages, so the
/// pixels crossed the socket, the fd survived the trip and the mapping was valid on both sides.
///
/// # Safety
/// Called with a configured surface and a bound wl_shm.
unsafe fn present_a_buffer(
    display: *mut wl::WlDisplay,
    shm: *mut wl::WlShm,
    surface: *mut wl::WlSurface,
) -> Result<(), String> {
    use std::io::{Seek, SeekFrom, Write};
    use std::os::unix::io::AsRawFd;

    const W: i32 = 64;
    const H: i32 = 64;
    let stride = W * 4;
    let size = (stride * H) as usize;

    // A PLAIN FILE, not shm_open. The compositor receives the DESCRIPTOR over the socket and mmaps
    // that, so the file only has to be mmap-able and the right size; where it lives does not
    // travel with it. This also sidesteps the question of whether the guest has a working
    // /dev/shm, which it does not need to have.
    let mut file = tempfile_in_guest()?;
    let pixel = 0xffu32 << 24 | 0x30u32 << 16 | 0x60u32 << 8 | 0x90u32; // opaque, a flat colour
    let row: Vec<u8> = std::iter::repeat(pixel.to_ne_bytes()).take(W as usize).flatten().collect();
    for _ in 0..H {
        file.write_all(&row).map_err(|e| format!("write {e}"))?;
    }
    file.flush().map_err(|e| format!("flush {e}"))?;
    file.seek(SeekFrom::Start(0)).map_err(|e| format!("seek {e}"))?;

    let pool = unsafe { wl::cider_wl_shm_create_pool(shm, file.as_raw_fd(), size as i32) };
    if pool.is_null() {
        return Err("create_pool returned null".into());
    }
    let format = unsafe { wl::cider_wl_shm_format_xrgb8888() };
    let buffer = unsafe { wl::cider_wl_shm_pool_create_buffer(pool, 0, W, H, stride, format) };
    if buffer.is_null() {
        return Err("create_buffer returned null".into());
    }
    let listener = wl::WlBufferListener { release: on_buffer_release };
    unsafe {
        wl::cider_wl_buffer_add_listener(buffer, &listener, std::ptr::null_mut());
        // ASK FOR A FRAME TOO, before the commit that carries the buffer: the callback is
        // delivered when the compositor has PRESENTED, which separates "never drawn" from
        // "drawn, buffer still held".
        let frame = wl::cider_wl_surface_frame(surface);
        let frame_listener = wl::WlCallbackListener { done: on_frame_done };
        if !frame.is_null() {
            wl::cider_wl_callback_add_listener(frame, &frame_listener, std::ptr::null_mut());
        }
        wl::cider_wl_surface_attach(surface, buffer, 0, 0);
        wl::cider_wl_surface_damage(surface, 0, 0, W, H);
        wl::cider_wl_surface_commit(surface);
        wl::wl_display_flush(display);
        // A ROUNDTRIP IS NOT A FRAME, and a headless compositor is SLOW to start repainting.
        // Measured on weston 15 with the pixman renderer: the first frame callback after a
        // surface is mapped took well over two seconds, so a 2 second budget reported "never
        // presented" for a surface that was in the scene graph the whole time. Ten seconds.
        for _ in 0..200 {
            wl::wl_display_roundtrip(display);
            if RELEASED && PRESENTED {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        wl::cider_wl_shm_pool_destroy(pool);
        // ASK THE CONNECTION WHETHER IT IS STILL ALIVE. A protocol error is invisible from
        // here otherwise: events simply stop arriving, which looks exactly like a compositor
        // that has not got round to compositing yet.
        println!("cider-wayland-probe display_error={}", wl::wl_display_get_error(display));
        // HOLD THE SURFACE OPEN when asked, so a scene-graph dump has something to look at.
        // Without it the probe exits in about two seconds and every inspection races it.
        if let Ok(secs) = std::env::var("CIDER_WAYLAND_HOLD") {
            if let Ok(n) = secs.parse::<u64>() {
                println!("cider-wayland-probe holding={n}s");
                for _ in 0..(n * 10) {
                    wl::wl_display_roundtrip(display);
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
            }
        }
        println!("cider-wayland-probe presented={PRESENTED} released={RELEASED}");
        // PRESENTED IS THE ASSERTION, not the release. A compositor may legitimately hold a
        // buffer after drawing with it, so demanding a release asks for more than the protocol
        // promises; a frame callback is the compositor stating it drew.
        if PRESENTED {
            println!("cider-wayland-probe pixels=presented size={W}x{H}");
            Ok(())
        } else {
            Err("no frame callback arrived, so the surface was never presented".into())
        }
    }
}

/// A file the guest can create and mmap. /tmp inside the container is a tmpfs, which is exactly
/// what this wants.
fn tempfile_in_guest() -> Result<std::fs::File, String> {
    let path = format!("/tmp/cider-wayland-probe-{}.shm", std::process::id());
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(true)
        .open(&path)
        .map_err(|e| format!("open {path}: {e}"))?;
    // Unlinked immediately: the descriptor keeps it alive and nothing is left behind.
    let _ = std::fs::remove_file(&path);
    Ok(file)
}
