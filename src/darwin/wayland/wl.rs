// The Wayland client FFI, in its own file BECAUSE IT CAN BE.
//
// A guest Rust crate had to be a single file until 2026-08-13: the Nix endpoint stages what an
// action's argv names, and a `mod` in its own file appears in no argv and in no buck2 aquery
// attribute, so it simply was not there when the endpoint replayed the compile. srcset.rs stages
// the whole crate DIRECTORY now, for the guest rule as well as the host one. This file and
// src/darwin/rustprobe are the two places that would fail loudly if that regressed.
//
// Everything here is declared against the FORWARDING STUB (//src/linux/native:wayland-client_dylib),
// which carries libwayland's real functions, plus shim.c for the inline layer and the interface
// data. Nothing is reimplemented.
use std::os::raw::{c_char, c_int, c_void};

pub enum WlDisplay {}
pub enum WlRegistry {}
pub enum WlInterface {}
pub enum WlCompositor {}
pub enum WlShm {}
pub enum WlSurface {}
pub enum XdgWmBase {}
pub enum XdgSurface {}
pub enum XdgToplevel {}
pub enum WlShmPool {}
pub enum WlBuffer {}
pub enum WlCallback {}
pub enum WlOutput {}

/// libwayland's intrusive list head: two pointers, and wl_list_init makes both point at it.
#[repr(C)]
pub struct WlList {
    pub prev: *mut WlList,
    pub next: *mut WlList,
}

unsafe extern "C" {
    // Real symbols in libwayland-client, verified present in the generated stub with llvm-nm.
    pub fn wl_display_connect(name: *const c_char) -> *mut WlDisplay;
    pub fn wl_display_disconnect(display: *mut WlDisplay);
    /// TAKES AN ALREADY CONNECTED FD, which is the interesting alternative: the GUEST can create
    /// and connect a unix socket with its own emulated syscalls, and this hands the result to
    /// libwayland. It is also the answer to whether a guest fd is a real host fd, which the
    /// backend needs to know regardless.
    pub fn wl_display_connect_to_fd(fd: c_int) -> *mut WlDisplay;
    pub fn wl_display_roundtrip(display: *mut WlDisplay) -> c_int;
    /// THE BRIDGE TEST. It writes prev and next to point at the list itself, which is an effect
    /// this side can verify without a compositor, a socket or an environment. If this does not
    /// happen, the forwarding stub never reached libwayland and everything else is noise.
    pub fn wl_list_init(list: *mut WlList);

    // shim.c, because these are static inline upstream and cannot cross the bridge.
    pub fn cider_wl_display_get_registry(display: *mut WlDisplay) -> *mut WlRegistry;
    pub fn cider_wl_registry_add_listener(
        registry: *mut WlRegistry,
        listener: *const RegistryListener,
        data: *mut c_void,
    ) -> c_int;
    pub fn cider_wl_compositor_interface() -> *const WlInterface;
    pub fn cider_xdg_wm_base_interface() -> *const WlInterface;

    // Surface and window, all of it inline upstream and therefore living in shim.c here.
    pub fn cider_wl_registry_bind_compositor(r: *mut WlRegistry, name: u32, version: u32) -> *mut WlCompositor;
    pub fn cider_wl_registry_bind_shm(r: *mut WlRegistry, name: u32, version: u32) -> *mut WlShm;
    pub fn cider_wl_registry_bind_xdg_wm_base(r: *mut WlRegistry, name: u32, version: u32) -> *mut XdgWmBase;
    pub fn cider_wl_compositor_create_surface(c: *mut WlCompositor) -> *mut WlSurface;
    pub fn cider_xdg_wm_base_get_xdg_surface(b: *mut XdgWmBase, s: *mut WlSurface) -> *mut XdgSurface;
    pub fn cider_xdg_surface_get_toplevel(s: *mut XdgSurface) -> *mut XdgToplevel;
    pub fn cider_xdg_toplevel_set_title(t: *mut XdgToplevel, title: *const c_char);
    pub fn cider_xdg_toplevel_add_listener(t: *mut XdgToplevel, l: *const XdgToplevelListener, data: *mut c_void) -> c_int;
    pub fn cider_wl_registry_bind_output(r: *mut WlRegistry, name: u32, version: u32) -> *mut WlOutput;
    pub fn cider_wl_output_add_listener(o: *mut WlOutput, l: *const WlOutputListener, data: *mut c_void) -> c_int;

    /// THE NON-BLOCKING PUMP. roundtrip is the wrong shape for an event loop: it waits for the
    /// server to answer a sync, so an application that pumps per iteration would block on every
    /// idle pass. prepare_read, read_events and dispatch_pending are the sequence libwayland
    /// documents for a client that has its own loop.
    pub fn wl_display_dispatch_pending(display: *mut WlDisplay) -> c_int;
    pub fn wl_display_prepare_read(display: *mut WlDisplay) -> c_int;
    pub fn wl_display_read_events(display: *mut WlDisplay) -> c_int;
    pub fn wl_display_cancel_read(display: *mut WlDisplay);
    pub fn cider_xdg_surface_ack_configure(s: *mut XdgSurface, serial: u32);
    pub fn cider_wl_surface_commit(s: *mut WlSurface);
    pub fn cider_xdg_surface_add_listener(s: *mut XdgSurface, l: *const XdgSurfaceListener, data: *mut c_void) -> c_int;
    pub fn cider_xdg_wm_base_pong(b: *mut XdgWmBase, serial: u32);
    pub fn cider_xdg_wm_base_add_listener(b: *mut XdgWmBase, l: *const XdgWmBaseListener, data: *mut c_void) -> c_int;

    // Pixels.
    pub fn cider_wl_shm_create_pool(shm: *mut WlShm, fd: c_int, size: i32) -> *mut WlShmPool;
    pub fn cider_wl_shm_pool_create_buffer(pool: *mut WlShmPool, offset: i32, width: i32, height: i32, stride: i32, format: u32) -> *mut WlBuffer;
    pub fn cider_wl_shm_pool_destroy(pool: *mut WlShmPool);
    pub fn cider_wl_surface_attach(s: *mut WlSurface, b: *mut WlBuffer, x: i32, y: i32);
    pub fn cider_wl_surface_damage(s: *mut WlSurface, x: i32, y: i32, w: i32, h: i32);
    pub fn cider_wl_buffer_add_listener(b: *mut WlBuffer, l: *const WlBufferListener, data: *mut c_void) -> c_int;
    pub fn cider_wl_shm_format_xrgb8888() -> u32;

    /// Nonzero once the connection has failed. A protocol error kills the connection silently
    /// from the client's point of view, so without asking, a missing event and a dead socket look
    /// the same.
    pub fn wl_display_get_error(display: *mut WlDisplay) -> c_int;
    pub fn wl_display_flush(display: *mut WlDisplay) -> c_int;
    pub fn cider_wl_surface_frame(s: *mut WlSurface) -> *mut WlCallback;
    pub fn cider_wl_callback_add_listener(c: *mut WlCallback, l: *const WlCallbackListener, data: *mut c_void) -> c_int;
}

/// The layout libwayland expects: two function pointers, in this order. It is passed by pointer
/// and read by the C side, so the order is ABI and not style.
#[repr(C)]
pub struct RegistryListener {
    pub global: extern "C" fn(
        data: *mut c_void,
        registry: *mut WlRegistry,
        name: u32,
        interface: *const c_char,
        version: u32,
    ),
    pub global_remove: extern "C" fn(data: *mut c_void, registry: *mut WlRegistry, name: u32),
}

/// What one registry sweep found. Counting is not the point; NAMING the globals is, because a
/// backend that cannot find wl_compositor, wl_shm and xdg_wm_base cannot open a window, and the
/// failure should say which one is missing rather than "it did not work".
#[derive(Default)]
pub struct Globals {
    pub bound: Bound,
    pub total: u32,
    pub compositor: bool,
    pub shm: bool,
    pub xdg_wm_base: bool,
    pub seat: bool,
    pub output: bool,
}

impl Globals {
    /// The registry hands out a NAME and a VERSION per global, and both are needed later: binding
    /// takes the name, and asking for a version the compositor does not have is a protocol error
    /// that kills the connection rather than returning null.
    pub fn note(&mut self, interface: &str, name: u32, version: u32) {
        self.total += 1;
        match interface {
            "wl_compositor" => {
                self.compositor = true;
                self.bound.compositor_name = name;
                self.bound.compositor_version = version.min(4);
            }
            "wl_shm" => {
                self.shm = true;
                self.bound.shm_name = name;
                self.bound.shm_version = version.min(1);
            }
            "xdg_wm_base" => {
                self.xdg_wm_base = true;
                self.bound.xdg_name = name;
                self.bound.xdg_version = version.min(1);
            }
            "wl_seat" => self.seat = true,
            "wl_output" => {
                self.output = true;
                self.bound.output_name = name;
                // Version 2 is where wl_output.done arrives, which is what says a burst of
                // properties is complete. Below that the values are used as they come.
                self.bound.output_version = version.min(2);
            }
            _ => {}
        }
    }

    /// Everything a window needs. wl_seat is deliberately NOT required: weston's headless backend
    /// advertises no seat at all, which is a fact about the test compositor and not about us.
    pub fn can_open_a_window(&self) -> bool {
        self.compositor && self.shm && self.xdg_wm_base
    }
}

/// One callback: the compositor says "this configuration is yours now", and the client must
/// acknowledge the serial before its surface is considered ready.
#[repr(C)]
pub struct XdgSurfaceListener {
    pub configure: extern "C" fn(data: *mut c_void, surface: *mut XdgSurface, serial: u32),
}

/// THE PING MATTERS. A client that never pongs is treated as hung, and the symptom is a window
/// that simply never appears rather than an error anyone can see.
#[repr(C)]
pub struct XdgWmBaseListener {
    pub ping: extern "C" fn(data: *mut c_void, base: *mut XdgWmBase, serial: u32),
}

/// What the registry sweep kept, so a second pass can bind without re-reading the names.
#[derive(Default)]
pub struct Bound {
    pub compositor_name: u32,
    pub compositor_version: u32,
    pub shm_name: u32,
    pub shm_version: u32,
    pub xdg_name: u32,
    pub xdg_version: u32,
    pub output_name: u32,
    pub output_version: u32,
}

/// One callback: the compositor has finished with the buffer. That event is the only honest
/// evidence from the client side that the pixels were CONSUMED and not merely handed over.
#[repr(C)]
pub struct WlBufferListener {
    pub release: extern "C" fn(data: *mut c_void, buffer: *mut WlBuffer),
}

/// The compositor calls this once it has PRESENTED the surface. Independent of buffer lifetime,
/// so it distinguishes "never drawn" from "drawn but the buffer is still held".
#[repr(C)]
pub struct WlCallbackListener {
    pub done: extern "C" fn(data: *mut c_void, callback: *mut WlCallback, time: u32),
}

/// FOUR MEMBERS, NOT TWO, and the last two are why. libwayland dispatches an event by INDEXING
/// this struct with the opcode, so a struct shorter than the interface's event list calls whatever
/// follows it in memory. configure_bounds and wm_capabilities only arrive at versions 4 and 5 and
/// this binds version 1, so they cannot fire today; declaring them costs two pointers and removes
/// the question entirely.
#[repr(C)]
pub struct XdgToplevelListener {
    pub configure: extern "C" fn(
        data: *mut c_void,
        toplevel: *mut XdgToplevel,
        width: i32,
        height: i32,
        states: *mut c_void,
    ),
    pub close: extern "C" fn(data: *mut c_void, toplevel: *mut XdgToplevel),
    pub configure_bounds:
        extern "C" fn(data: *mut c_void, toplevel: *mut XdgToplevel, width: i32, height: i32),
    pub wm_capabilities:
        extern "C" fn(data: *mut c_void, toplevel: *mut XdgToplevel, capabilities: *mut c_void),
}

/// SIX MEMBERS, for the same reason the toplevel listener has four: libwayland indexes this with
/// the event opcode. name and description are version 4 and this binds version 2, so they cannot
/// fire, and declaring them settles it rather than leaving a shorter struct to be read past.
#[repr(C)]
pub struct WlOutputListener {
    pub geometry: extern "C" fn(
        data: *mut c_void,
        output: *mut WlOutput,
        x: i32,
        y: i32,
        physical_width: i32,
        physical_height: i32,
        subpixel: i32,
        make: *const c_char,
        model: *const c_char,
        transform: i32,
    ),
    pub mode: extern "C" fn(
        data: *mut c_void,
        output: *mut WlOutput,
        flags: u32,
        width: i32,
        height: i32,
        refresh: i32,
    ),
    pub done: extern "C" fn(data: *mut c_void, output: *mut WlOutput),
    pub scale: extern "C" fn(data: *mut c_void, output: *mut WlOutput, factor: i32),
    pub name: extern "C" fn(data: *mut c_void, output: *mut WlOutput, name: *const c_char),
    pub description: extern "C" fn(data: *mut c_void, output: *mut WlOutput, description: *const c_char),
}

/// wl_output.mode flags. Only "current" matters: a compositor lists every mode it supports and
/// exactly one of them is the one in use, so taking the last mode seen would pick an arbitrary
/// resolution the screen is not actually running at.
pub const WL_OUTPUT_MODE_CURRENT: u32 = 0x1;
