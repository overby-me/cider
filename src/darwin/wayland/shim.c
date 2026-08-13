// The parts of libwayland that CANNOT be called from Rust directly, and nothing else.
//
// libwayland's per-object entry points are `static inline` in the generated protocol header:
// wl_display_get_registry, wl_registry_add_listener and wl_registry_bind are not symbols in
// libwayland-client.so at all, they expand to wl_proxy_marshal_flags and wl_proxy_add_listener at
// the call site. A Mach-O forwarding stub can only carry real symbols, so the inline layer has to
// exist on this side of the bridge. That is what this file is: one wrapper per inline call, and
// accessors for the wl_interface objects, which are DATA and therefore also absent from the stub.
//
// The generated headers come from wayland-scanner over the same XML upstream uses; see
// nix/wayland-core-protocol.nix for why the core XML has to be extracted from the source tarball.
//
// NOT wayland-client.h: that header pulls in the HOST's copy of the protocol declarations, which
// would collide with the ones generated here. Core plus our own protocol headers is the same
// split upstream makes.
#include <wayland-client-core.h>

#include "wayland-client-protocol.h"
#include "xdg-shell-client-protocol.h"

struct wl_registry *cider_wl_display_get_registry(struct wl_display *display) {
	return wl_display_get_registry(display);
}

int cider_wl_registry_add_listener(struct wl_registry *registry,
                                   const struct wl_registry_listener *listener, void *data) {
	return wl_registry_add_listener(registry, listener, data);
}

void *cider_wl_registry_bind(struct wl_registry *registry, uint32_t name,
                             const struct wl_interface *interface, uint32_t version) {
	return wl_registry_bind(registry, name, interface, version);
}

// The interface objects, reached through a function because a stub forwards code, not data.
const struct wl_interface *cider_wl_compositor_interface(void) { return &wl_compositor_interface; }
const struct wl_interface *cider_wl_shm_interface(void) { return &wl_shm_interface; }
const struct wl_interface *cider_wl_seat_interface(void) { return &wl_seat_interface; }
const struct wl_interface *cider_wl_output_interface(void) { return &wl_output_interface; }
const struct wl_interface *cider_xdg_wm_base_interface(void) { return &xdg_wm_base_interface; }
