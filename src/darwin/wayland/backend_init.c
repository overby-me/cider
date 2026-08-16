// The backend bundle's load-time entry point, in a file of its own.
//
// It is NOT in shim.c, and that is a link-time fact rather than tidiness: shim.c is shared with
// the probe binary, which has no backend in it, so a constructor calling
// cider_wayland_backend_register there would leave the probe with an undefined symbol.
// THE BACKEND ENTRY POINT. NSBundle loads this dylib and then asks for the principal class BY
// NAME, so CGSConnectionWayland has to exist before any message reaches it. A C constructor is
// the portable way to run code at load; Rust has no stable equivalent that survives being pulled
// into a dylib through a staticlib.
extern void cider_wayland_backend_register(void);

__attribute__((constructor)) static void cider_wayland_backend_init(void) {
	cider_wayland_backend_register();
}
