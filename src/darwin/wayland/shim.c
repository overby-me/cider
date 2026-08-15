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
#include "wlr-layer-shell-unstable-v1-client-protocol.h"

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

// WHERE THE WINDOW ACTUALLY IS INSIDE THE SURFACE. A client that draws a shadow makes its surface
// bigger than its window, and this is how the compositor is told which part is the window: tiling,
// snapping and popup anchoring all use this rectangle rather than the buffer.
void cider_xdg_surface_set_window_geometry(struct xdg_surface *surface, int32_t x, int32_t y,
                                           int32_t width, int32_t height) {
	xdg_surface_set_window_geometry(surface, x, y, width, height);
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

// AND THE ONE WITH AN ALPHA CHANNEL, which is also guaranteed. A menu on macOS is translucent with
// rounded corners, and both need the compositor to blend rather than ignore the fourth byte.
uint32_t cider_wl_shm_format_argb8888(void) { return WL_SHM_FORMAT_ARGB8888; }

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

// ---------------------------------------------------------------------------------------------
// POPUPS. A menu is not a window in the sense a compositor means: it belongs to another surface,
// it is positioned RELATIVE to it, and it is dismissed rather than closed. Creating one as an
// xdg_toplevel gives a tiling compositor a tile of its own to place, which is why LibreOffice menus
// opened and appeared nowhere near the pointer.
struct xdg_positioner *cider_xdg_wm_base_create_positioner(struct xdg_wm_base *base) {
	return xdg_wm_base_create_positioner(base);
}

void cider_xdg_positioner_set_size(struct xdg_positioner *p, int32_t w, int32_t h) {
	xdg_positioner_set_size(p, w, h);
}

void cider_xdg_positioner_set_anchor_rect(struct xdg_positioner *p, int32_t x, int32_t y,
                                          int32_t w, int32_t h) {
	xdg_positioner_set_anchor_rect(p, x, y, w, h);
}

void cider_xdg_positioner_set_anchor(struct xdg_positioner *p, uint32_t anchor) {
	xdg_positioner_set_anchor(p, anchor);
}

void cider_xdg_positioner_set_gravity(struct xdg_positioner *p, uint32_t gravity) {
	xdg_positioner_set_gravity(p, gravity);
}

// SLIDE AND FLIP RATHER THAN CLIP. A menu near the edge of the screen has to move to stay whole,
// and without this the compositor is entitled to cut it off instead.
void cider_xdg_positioner_set_constraint_adjustment(struct xdg_positioner *p, uint32_t adjust) {
	xdg_positioner_set_constraint_adjustment(p, adjust);
}

void cider_xdg_positioner_destroy(struct xdg_positioner *p) { xdg_positioner_destroy(p); }

struct xdg_popup *cider_xdg_surface_get_popup(struct xdg_surface *surface,
                                              struct xdg_surface *parent,
                                              struct xdg_positioner *positioner) {
	return xdg_surface_get_popup(surface, parent, positioner);
}

int cider_xdg_popup_add_listener(struct xdg_popup *popup, const struct xdg_popup_listener *listener,
                                 void *data) {
	return xdg_popup_add_listener(popup, listener, data);
}

void cider_xdg_popup_destroy(struct xdg_popup *popup) { xdg_popup_destroy(popup); }

// TEARING A WINDOW DOWN, IN THE ORDER THE PROTOCOL REQUIRES: the role object first, then the
// xdg_surface, then the wl_surface. Destroying an xdg_surface while its toplevel still exists is a
// protocol error in its own right.
//
// This exists because hiding a toplevel by attaching a null buffer does NOT work: the surface is
// reset by the compositor and the configure that follows belongs to a new generation, so the next
// acknowledgement is refused and the connection dies. See the plan, wrong configure serial.
void cider_xdg_toplevel_destroy(struct xdg_toplevel *toplevel) { xdg_toplevel_destroy(toplevel); }

void cider_xdg_surface_destroy(struct xdg_surface *surface) { xdg_surface_destroy(surface); }

void cider_wl_surface_destroy(struct wl_surface *surface) { wl_surface_destroy(surface); }

// A POPUP POSITION IS FIXED WHEN THE POPUP IS MADE, and applications do not work that way.
// LibreOffice builds its dropdown list windows at startup, parks them wherever, and MOVES them just
// before showing one, so a list made once and never repositioned appears where its window happened
// to be at creation: hard against the left edge of the screen rather than under its own field.
// Reposition is the protocol answer to exactly that. It arrived in xdg_shell version 3, so a
// compositor that only speaks 1 or 2 has to be left alone: asking is a protocol error and kills the
// connection.
int cider_xdg_popup_can_reposition(struct xdg_popup *popup) {
	return popup != NULL &&
	       wl_proxy_get_version((struct wl_proxy *) popup) >= XDG_POPUP_REPOSITION_SINCE_VERSION;
}

void cider_xdg_popup_reposition(struct xdg_popup *popup, struct xdg_positioner *positioner,
                                uint32_t token) {
	xdg_popup_reposition(popup, positioner, token);
}

uint32_t cider_xdg_positioner_anchor_bottom_left(void) {
	return XDG_POSITIONER_ANCHOR_BOTTOM_LEFT;
}
uint32_t cider_xdg_positioner_gravity_bottom_right(void) {
	return XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT;
}
uint32_t cider_xdg_positioner_constraint_slide_flip(void) {
	return XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_X |
	       XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_Y |
	       XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X |
	       XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y;
}

// The connection file descriptor, so something other than the main thread can WATCH it. Reading it
// stays with the main thread; this is only for poll.
int cider_wl_display_get_fd(struct wl_display *display) {
	return wl_display_get_fd(display);
}

// THE APPLICATION IDENTITY, which a compositor uses for everything it does per application: window
// rules, task lists, icons, and matching a window at all. A toplevel without one is anonymous, and
// a rule written against it cannot fire.
void cider_xdg_toplevel_set_app_id(struct xdg_toplevel *toplevel, const char *app_id) {
	xdg_toplevel_set_app_id(toplevel, app_id);
}

// THE CLIPBOARD BETWEEN APPLICATIONS, which is wl_data_device and nothing to do with the seat
// beyond needing one. A selection is OWNED by a client: the owner advertises MIME types and writes
// the bytes down a pipe when someone asks, so there is no clipboard daemon and no data at rest.
struct wl_data_device_manager *cider_wl_registry_bind_data_device_manager(struct wl_registry *registry,
                                                                         uint32_t name,
                                                                         uint32_t version) {
	return wl_registry_bind(registry, name, &wl_data_device_manager_interface, version);
}

struct wl_data_device *cider_wl_data_device_manager_get_data_device(
        struct wl_data_device_manager *manager, struct wl_seat *seat) {
	return wl_data_device_manager_get_data_device(manager, seat);
}

struct wl_data_source *cider_wl_data_device_manager_create_data_source(
        struct wl_data_device_manager *manager) {
	return wl_data_device_manager_create_data_source(manager);
}

int cider_wl_data_device_add_listener(struct wl_data_device *device,
                                      const struct wl_data_device_listener *listener, void *data) {
	return wl_data_device_add_listener(device, listener, data);
}

int cider_wl_data_source_add_listener(struct wl_data_source *source,
                                      const struct wl_data_source_listener *listener, void *data) {
	return wl_data_source_add_listener(source, listener, data);
}

void cider_wl_data_source_offer(struct wl_data_source *source, const char *mime_type) {
	wl_data_source_offer(source, mime_type);
}

void cider_wl_data_source_destroy(struct wl_data_source *source) {
	wl_data_source_destroy(source);
}

// THE SERIAL IS NOT DECORATION: a compositor refuses a selection whose serial it does not recognise
// as a recent input event, which is how it stops a background client from stealing the clipboard.
void cider_wl_data_device_set_selection(struct wl_data_device *device, struct wl_data_source *source,
                                        uint32_t serial) {
	wl_data_device_set_selection(device, source, serial);
}

void cider_wl_data_offer_receive(struct wl_data_offer *offer, const char *mime_type, int32_t fd) {
	wl_data_offer_receive(offer, mime_type, fd);
}

void cider_wl_data_offer_destroy(struct wl_data_offer *offer) {
	wl_data_offer_destroy(offer);
}

int cider_wl_data_offer_add_listener(struct wl_data_offer *offer,
                                     const struct wl_data_offer_listener *listener, void *data) {
	return wl_data_offer_add_listener(offer, listener, data);
}

// THE WINDOW MANAGEMENT REQUESTS A TITLE BAR NEEDS. A client cannot move or minimise itself on
// Wayland: it ASKS the compositor, and the ask carries the serial of the input event that caused it
// so a background client cannot grab the pointer.
void cider_xdg_toplevel_move(struct xdg_toplevel *toplevel, struct wl_seat *seat, uint32_t serial) {
	xdg_toplevel_move(toplevel, seat, serial);
}

void cider_xdg_toplevel_set_minimized(struct xdg_toplevel *toplevel) {
	xdg_toplevel_set_minimized(toplevel);
}

void cider_xdg_toplevel_set_maximized(struct xdg_toplevel *toplevel) {
	xdg_toplevel_set_maximized(toplevel);
}

void cider_xdg_toplevel_unset_maximized(struct xdg_toplevel *toplevel) {
	xdg_toplevel_unset_maximized(toplevel);
}

// ---------------------------------------------------------------------------------------------
// LAYER SHELL, which is the only way to put a menu bar where macOS puts it.
//
// A Wayland client cannot place a toplevel: position is the compositor's business, and nothing in
// the standard protocol set asks for "the top edge of the screen, full width, always visible, and
// keep other windows out of it". Layer shell does exactly that, and every compositor built on
// wlroots or smithay has it because their own panels and docks are written to it. A compositor is
// free not to: the strip is asked for and the in-window menu bar stays when the answer is no.
struct zwlr_layer_shell_v1 *cider_wl_registry_bind_layer_shell(struct wl_registry *registry,
                                                               uint32_t name, uint32_t version) {
	return wl_registry_bind(registry, name, &zwlr_layer_shell_v1_interface, version);
}

const struct wl_interface *cider_zwlr_layer_shell_v1_interface(void) {
	return &zwlr_layer_shell_v1_interface;
}

// The output may be NULL, which means the compositor picks one. A menu bar wants the output the
// application is on, and until there is a reason to choose, the compositor knows better than we do.
struct zwlr_layer_surface_v1 *cider_zwlr_layer_shell_get_layer_surface(
        struct zwlr_layer_shell_v1 *shell, struct wl_surface *surface, struct wl_output *output,
        uint32_t layer, const char *name_space) {
	return zwlr_layer_shell_v1_get_layer_surface(shell, surface, output, layer, name_space);
}

void cider_zwlr_layer_surface_set_size(struct zwlr_layer_surface_v1 *surface, uint32_t width,
                                       uint32_t height) {
	zwlr_layer_surface_v1_set_size(surface, width, height);
}

// WHICH EDGES IT IS STUCK TO. Anchoring to left, right and top at once is what makes a strip: the
// width comes from the screen rather than from the client, and only the height is ours.
void cider_zwlr_layer_surface_set_anchor(struct zwlr_layer_surface_v1 *surface, uint32_t anchor) {
	zwlr_layer_surface_v1_set_anchor(surface, anchor);
}

// THE ROOM NO OTHER WINDOW MAY USE. Without this a maximised window sits UNDER the menu bar, which
// is how a panel with no exclusive zone behaves and is not what a menu bar is.
void cider_zwlr_layer_surface_set_exclusive_zone(struct zwlr_layer_surface_v1 *surface,
                                                 int32_t zone) {
	zwlr_layer_surface_v1_set_exclusive_zone(surface, zone);
}

void cider_zwlr_layer_surface_set_keyboard_interactivity(struct zwlr_layer_surface_v1 *surface,
                                                         uint32_t interactivity) {
	zwlr_layer_surface_v1_set_keyboard_interactivity(surface, interactivity);
}

void cider_zwlr_layer_surface_ack_configure(struct zwlr_layer_surface_v1 *surface, uint32_t serial) {
	zwlr_layer_surface_v1_ack_configure(surface, serial);
}

void cider_zwlr_layer_surface_destroy(struct zwlr_layer_surface_v1 *surface) {
	zwlr_layer_surface_v1_destroy(surface);
}

int cider_zwlr_layer_surface_add_listener(struct zwlr_layer_surface_v1 *surface,
                                          const struct zwlr_layer_surface_v1_listener *listener,
                                          void *data) {
	return zwlr_layer_surface_v1_add_listener(surface, listener, data);
}

// A POPUP OVER A STRIP. An xdg_popup needs an xdg_surface parent, and a layer surface is not one,
// so the popup is made with a NULL parent and handed to the layer surface afterwards. This is the
// only way a menu can open under a menu bar that is not a window.
void cider_zwlr_layer_surface_get_popup(struct zwlr_layer_surface_v1 *surface,
                                        struct xdg_popup *popup) {
	zwlr_layer_surface_v1_get_popup(surface, popup);
}
