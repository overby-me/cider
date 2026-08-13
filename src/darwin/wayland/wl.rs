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

unsafe extern "C" {
    // Real symbols in libwayland-client, verified present in the generated stub with llvm-nm.
    pub fn wl_display_connect(name: *const c_char) -> *mut WlDisplay;
    pub fn wl_display_disconnect(display: *mut WlDisplay);
    pub fn wl_display_roundtrip(display: *mut WlDisplay) -> c_int;

    // shim.c, because these are static inline upstream and cannot cross the bridge.
    pub fn cider_wl_display_get_registry(display: *mut WlDisplay) -> *mut WlRegistry;
    pub fn cider_wl_registry_add_listener(
        registry: *mut WlRegistry,
        listener: *const RegistryListener,
        data: *mut c_void,
    ) -> c_int;
    pub fn cider_wl_compositor_interface() -> *const WlInterface;
    pub fn cider_xdg_wm_base_interface() -> *const WlInterface;
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
    pub total: u32,
    pub compositor: bool,
    pub shm: bool,
    pub xdg_wm_base: bool,
    pub seat: bool,
    pub output: bool,
}

impl Globals {
    pub fn note(&mut self, interface: &str) {
        self.total += 1;
        match interface {
            "wl_compositor" => self.compositor = true,
            "wl_shm" => self.shm = true,
            "xdg_wm_base" => self.xdg_wm_base = true,
            "wl_seat" => self.seat = true,
            "wl_output" => self.output = true,
            _ => {}
        }
    }

    /// Everything a window needs. wl_seat is deliberately NOT required: weston's headless backend
    /// advertises no seat at all, which is a fact about the test compositor and not about us.
    pub fn can_open_a_window(&self) -> bool {
        self.compositor && self.shm && self.xdg_wm_base
    }
}
