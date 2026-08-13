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

// ---------------------------------------------------------------------------------------------
// SURFACE AND WINDOW, the inline layer again. Everything below expands to wl_proxy_marshal_flags
// at the call site upstream, so none of it is a symbol the forwarding stub could carry.

struct wl_compositor *cider_wl_registry_bind_compositor(struct wl_registry *registry, uint32_t name,
                                                        uint32_t version) {
	return wl_registry_bind(registry, name, &wl_compositor_interface, version);
}

struct wl_shm *cider_wl_registry_bind_shm(struct wl_registry *registry, uint32_t name,
                                          uint32_t version) {
	return wl_registry_bind(registry, name, &wl_shm_interface, version);
}

struct xdg_wm_base *cider_wl_registry_bind_xdg_wm_base(struct wl_registry *registry, uint32_t name,
                                                       uint32_t version) {
	return wl_registry_bind(registry, name, &xdg_wm_base_interface, version);
}

struct wl_surface *cider_wl_compositor_create_surface(struct wl_compositor *compositor) {
	return wl_compositor_create_surface(compositor);
}

struct xdg_surface *cider_xdg_wm_base_get_xdg_surface(struct xdg_wm_base *base,
                                                      struct wl_surface *surface) {
	return xdg_wm_base_get_xdg_surface(base, surface);
}

struct xdg_toplevel *cider_xdg_surface_get_toplevel(struct xdg_surface *surface) {
	return xdg_surface_get_toplevel(surface);
}

void cider_xdg_toplevel_set_title(struct xdg_toplevel *toplevel, const char *title) {
	xdg_toplevel_set_title(toplevel, title);
}

void cider_xdg_surface_ack_configure(struct xdg_surface *surface, uint32_t serial) {
	xdg_surface_ack_configure(surface, serial);
}

void cider_wl_surface_commit(struct wl_surface *surface) { wl_surface_commit(surface); }

int cider_xdg_surface_add_listener(struct xdg_surface *surface,
                                   const struct xdg_surface_listener *listener, void *data) {
	return xdg_surface_add_listener(surface, listener, data);
}

// THE COMPOSITOR PINGS AND EXPECTS A PONG. Ignoring it makes weston consider the client
// unresponsive, which shows up as a window that never appears rather than as an error.
void cider_xdg_wm_base_pong(struct xdg_wm_base *base, uint32_t serial) {
	xdg_wm_base_pong(base, serial);
}

int cider_xdg_wm_base_add_listener(struct xdg_wm_base *base,
                                   const struct xdg_wm_base_listener *listener, void *data) {
	return xdg_wm_base_add_listener(base, listener, data);
}
