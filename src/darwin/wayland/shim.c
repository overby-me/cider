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

struct wl_output *cider_wl_registry_bind_output(struct wl_registry *registry, uint32_t name,
                                                uint32_t version)
{
	return wl_registry_bind(registry, name, &wl_output_interface, version);
}

int cider_wl_output_add_listener(struct wl_output *output,
                                 const struct wl_output_listener *listener, void *data)
{
	return wl_output_add_listener(output, listener, data);
}

int cider_xdg_toplevel_add_listener(struct xdg_toplevel *toplevel,
                                    const struct xdg_toplevel_listener *listener, void *data)
{
	return xdg_toplevel_add_listener(toplevel, listener, data);
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

// ---------------------------------------------------------------------------------------------
// PIXELS. wl_shm hands the compositor a file descriptor and it mmaps the same pages the client
// wrote, which is how a CGSSurface will present a bitmap. All of this is inline upstream too.

struct wl_shm_pool *cider_wl_shm_create_pool(struct wl_shm *shm, int32_t fd, int32_t size) {
	return wl_shm_create_pool(shm, fd, size);
}

struct wl_buffer *cider_wl_shm_pool_create_buffer(struct wl_shm_pool *pool, int32_t offset,
                                                  int32_t width, int32_t height, int32_t stride,
                                                  uint32_t format) {
	return wl_shm_pool_create_buffer(pool, offset, width, height, stride, format);
}

void cider_wl_shm_pool_destroy(struct wl_shm_pool *pool) { wl_shm_pool_destroy(pool); }

void cider_wl_surface_attach(struct wl_surface *surface, struct wl_buffer *buffer, int32_t x,
                             int32_t y) {
	wl_surface_attach(surface, buffer, x, y);
}

void cider_wl_surface_damage(struct wl_surface *surface, int32_t x, int32_t y, int32_t width,
                             int32_t height) {
	wl_surface_damage(surface, x, y, width, height);
}

// THE RELEASE EVENT IS THE PROOF. A compositor releases a buffer once it has finished reading it,
// so a release means our pixels were actually consumed rather than merely offered.
int cider_wl_buffer_add_listener(struct wl_buffer *buffer, const struct wl_buffer_listener *listener,
                                 void *data) {
	return wl_buffer_add_listener(buffer, listener, data);
}

// WL_SHM_FORMAT_XRGB8888 is guaranteed by the protocol, unlike most formats, so the probe uses it
// rather than asking which are supported.
uint32_t cider_wl_shm_format_xrgb8888(void) { return WL_SHM_FORMAT_XRGB8888; }

// A FRAME CALLBACK FIRES WHEN THE COMPOSITOR HAS PRESENTED, which is a different claim from a
// buffer release: release is about buffer LIFETIME and can be deferred, while a frame callback is
// the compositor saying it drew. Asking for both means a failure says which half is missing.
struct wl_callback *cider_wl_surface_frame(struct wl_surface *surface) {
	return wl_surface_frame(surface);
}

int cider_wl_callback_add_listener(struct wl_callback *callback,
                                   const struct wl_callback_listener *listener, void *data) {
	return wl_callback_add_listener(callback, listener, data);
}

// ---------------------------------------------------------------------------------------------
// INPUT. A seat carries the pointer and the keyboard, and neither is a global of its own: they are
// obtained from the seat AFTER it reports its capabilities, because a compositor that has no mouse
// attached will refuse wl_seat.get_pointer. weston headless is exactly that compositor, which is
// why this has to be driven by the capabilities event rather than requested up front.
struct wl_seat *cider_wl_registry_bind_seat(struct wl_registry *registry, uint32_t name,
                                            uint32_t version) {
	return wl_registry_bind(registry, name, &wl_seat_interface, version);
}

int cider_wl_seat_add_listener(struct wl_seat *seat, const struct wl_seat_listener *listener,
                               void *data) {
	return wl_seat_add_listener(seat, listener, data);
}

struct wl_pointer *cider_wl_seat_get_pointer(struct wl_seat *seat) {
	return wl_seat_get_pointer(seat);
}

struct wl_keyboard *cider_wl_seat_get_keyboard(struct wl_seat *seat) {
	return wl_seat_get_keyboard(seat);
}

int cider_wl_pointer_add_listener(struct wl_pointer *pointer,
                                  const struct wl_pointer_listener *listener, void *data) {
	return wl_pointer_add_listener(pointer, listener, data);
}

int cider_wl_keyboard_add_listener(struct wl_keyboard *keyboard,
                                   const struct wl_keyboard_listener *listener, void *data) {
	return wl_keyboard_add_listener(keyboard, listener, data);
}

// The seat capability bits, exposed as functions for the same reason the shm format is: they are
// enum constants in a header the Rust side does not read.
uint32_t cider_wl_seat_capability_pointer(void) { return WL_SEAT_CAPABILITY_POINTER; }
uint32_t cider_wl_seat_capability_keyboard(void) { return WL_SEAT_CAPABILITY_KEYBOARD; }
uint32_t cider_wl_pointer_button_state_pressed(void) { return WL_POINTER_BUTTON_STATE_PRESSED; }
uint32_t cider_wl_keyboard_key_state_pressed(void) { return WL_KEYBOARD_KEY_STATE_PRESSED; }
uint32_t cider_wl_keyboard_keymap_format_xkb_v1(void) {
	return WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1;
}

// wl_fixed_t is 24.8 FIXED POINT, not a float and not an integer of pixels. Converting it by cast
// loses the fraction and, worse, looks like it works: a pointer lands within a pixel of where it
// should and only fine positioning is wrong.
double cider_wl_fixed_to_double(int32_t f) { return wl_fixed_to_double(f); }

// RELEASING IS PART OF THE PROTOCOL, not cleanup. wl_seat.capabilities is sent again whenever a
// device appears or disappears, and a client that keeps its wl_pointer after the capability is
// withdrawn holds a proxy the compositor will never send to again. The visible symptom is an
// application that stops responding to the mouse after a device is unplugged and never recovers,
// because the client never asks for a new pointer.
void cider_wl_pointer_release(struct wl_pointer *pointer) { wl_pointer_release(pointer); }
void cider_wl_keyboard_release(struct wl_keyboard *keyboard) { wl_keyboard_release(keyboard); }

// A PARENT IS HOW A COMPOSITOR KNOWS A WINDOW IS NOT A DOCUMENT. xdg_toplevel.set_parent marks a
// surface as belonging to another, and compositors float those rather than placing them in the
// tiling layout. Without it every tooltip, palette and scrollbar helper an application opens is
// treated as a peer of the document window: a tiling compositor splits the screen with each one,
// and the document ends up a few hundred pixels wide with a dozen slivers beside it.
void cider_xdg_toplevel_set_parent(struct xdg_toplevel *toplevel, struct xdg_toplevel *parent) {
	xdg_toplevel_set_parent(toplevel, parent);
}
