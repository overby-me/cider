/*
 * cider-vptr.c - a pointer that can HOLD A BUTTON across real time.
 *
 * WHY THIS EXISTS. Every other way of injecting a pointer into a wlroots compositor drops the
 * button. sway IPC makes a virtual device for the command list it is running and destroys it when
 * the list ends, so a press and a release arrive at the client with the SAME timestamp and before
 * any motion: measured on the wire, wl_pointer.button(103, ..., 272, 1) and
 * wl_pointer.button(104, ..., 272, 0) back to back. wlrctl offers click, move and scroll, and has
 * no press or release at all. Neither can express a drag, which is a press, motion spread over
 * real time, and a release, all from one device.
 *
 * wlr-virtual-pointer-unstable-v1 creates a pointer that lives exactly as long as this process, so
 * the whole gesture comes from one device and looks to the application like a hand on a mouse.
 * That is what proved drag selection works in LibreOffice under this port.
 *
 * BUILD. The protocol glue is generated rather than committed, so this needs wayland-scanner and
 * the wlr-protocols XML, both of which Nix has:
 *
 *   XML=$(nix build --print-out-paths nixpkgs#wlr-protocols)/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml
 *   WS=$(nix build --print-out-paths nixpkgs#wayland-scanner)/bin/wayland-scanner
 *   $WS client-header "$XML" wlr-virtual-pointer-unstable-v1-client-protocol.h
 *   $WS private-code   "$XML" wlr-virtual-pointer-unstable-v1-protocol.c
 *   clang -O2 -o cider-vptr scripts/cider-vptr.c wlr-virtual-pointer-unstable-v1-protocol.c \
 *       -I. $(pkg-config --cflags --libs wayland-client)
 *
 * USE. Commands on stdin, one per line, against the compositor in WAYLAND_DISPLAY. The output size
 * is argv, because absolute motion is meaningless without the extent it is measured in and a
 * nested compositor can be asked for a size before it has settled on one.
 *
 *   abs X Y        absolute motion, pixels in the output
 *   rel DX DY      relative motion, pixels
 *   press NAME     left, right, middle, or a numeric evdev code
 *   release NAME
 *   scroll N       vertical wheel, N steps, negative is up
 *   sleep MS
 *   #...           comment
 *
 * A drag then reads as what it is:
 *
 *   printf 'abs 290 250\nsleep 400\npress left\nsleep 250\nabs 340 250\nsleep 60\nabs 500 250\nsleep 250\nrelease left\n' \
 *     | cider-vptr 1690 1388
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>

#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

#define BTN_LEFT 0x110
#define BTN_RIGHT 0x111
#define BTN_MIDDLE 0x112

static struct wl_seat *seat;
static struct wl_output *output;
static struct zwlr_virtual_pointer_manager_v1 *manager;
static uint32_t manager_version;
static int32_t out_w, out_h;

static void output_geometry(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t pw,
                            int32_t ph, int32_t sub, const char *make, const char *model,
                            int32_t tr) {}
static void output_mode(void *d, struct wl_output *o, uint32_t flags, int32_t w, int32_t h,
                        int32_t refresh) {
    if (flags & WL_OUTPUT_MODE_CURRENT) {
        out_w = w;
        out_h = h;
    }
}
static void output_done(void *d, struct wl_output *o) {}
static void output_scale(void *d, struct wl_output *o, int32_t f) {}
static const struct wl_output_listener output_listener = {
    output_geometry, output_mode, output_done, output_scale,
};

static void registry_global(void *data, struct wl_registry *reg, uint32_t name, const char *iface,
                            uint32_t version) {
    if (strcmp(iface, wl_seat_interface.name) == 0 && seat == NULL) {
        seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
    } else if (strcmp(iface, wl_output_interface.name) == 0 && output == NULL) {
        output = wl_registry_bind(reg, name, &wl_output_interface, 2);
        wl_output_add_listener(output, &output_listener, NULL);
    } else if (strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name) == 0) {
        manager_version = version > 2 ? 2 : version;
        manager = wl_registry_bind(reg, name, &zwlr_virtual_pointer_manager_v1_interface,
                                   manager_version);
    }
}
static void registry_remove(void *data, struct wl_registry *reg, uint32_t name) {}
static const struct wl_registry_listener registry_listener = {registry_global, registry_remove};

static uint32_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t) (ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static void nap(long ms) {
    struct timespec ts = {ms / 1000, (ms % 1000) * 1000000L};
    nanosleep(&ts, NULL);
}

static uint32_t button_code(const char *name) {
    if (strcmp(name, "left") == 0) return BTN_LEFT;
    if (strcmp(name, "right") == 0) return BTN_RIGHT;
    if (strcmp(name, "middle") == 0) return BTN_MIDDLE;
    return (uint32_t) strtoul(name, NULL, 0);
}

int main(int argc, char **argv) {
    struct wl_display *display = wl_display_connect(NULL);
    if (display == NULL) {
        const char *d = getenv("WAYLAND_DISPLAY");
        fprintf(stderr, "vptr: no compositor on WAYLAND_DISPLAY=%s\n", d ? d : "(unset)");
        return 1;
    }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    wl_display_roundtrip(display); /* the second one collects the output mode */

    if (manager == NULL) {
        fprintf(stderr, "vptr: compositor does not offer zwlr_virtual_pointer_manager_v1\n");
        return 1;
    }
    if (argc >= 3) {
        out_w = atoi(argv[1]);
        out_h = atoi(argv[2]);
    }
    if (out_w <= 0 || out_h <= 0) {
        fprintf(stderr, "vptr: no output size; pass WIDTH HEIGHT on argv\n");
        return 1;
    }

    struct zwlr_virtual_pointer_v1 *pointer;
    if (manager_version >= 2 && output != NULL)
        pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer_with_output(manager, seat,
                                                                                    output);
    else
        pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, seat);
    wl_display_roundtrip(display);
    fprintf(stderr, "vptr: pointer on %dx%d, manager v%u\n", out_w, out_h, manager_version);

    /* A DEVICE THAT HAS JUST APPEARED IS NOT YET A SEAT CAPABILITY. The application has to see the
     * pointer capability, ask the seat for a wl_pointer and be handed one before anything sent
     * here can reach it, and that is a round trip through its main loop. */
    nap(400);

    char line[512];
    while (fgets(line, sizeof line, stdin) != NULL) {
        char cmd[32];
        long a, b;
        if (line[0] == '#' || line[0] == '\n') continue;
        if (sscanf(line, "%31s", cmd) != 1) continue;

        if (strcmp(cmd, "abs") == 0 && sscanf(line, "%*s %ld %ld", &a, &b) == 2) {
            zwlr_virtual_pointer_v1_motion_absolute(pointer, now_ms(), (uint32_t) a, (uint32_t) b,
                                                    (uint32_t) out_w, (uint32_t) out_h);
            zwlr_virtual_pointer_v1_frame(pointer);
        } else if (strcmp(cmd, "rel") == 0 && sscanf(line, "%*s %ld %ld", &a, &b) == 2) {
            zwlr_virtual_pointer_v1_motion(pointer, now_ms(), wl_fixed_from_int((int) a),
                                           wl_fixed_from_int((int) b));
            zwlr_virtual_pointer_v1_frame(pointer);
        } else if (strcmp(cmd, "press") == 0 || strcmp(cmd, "release") == 0) {
            char name[32] = "left";
            sscanf(line, "%*s %31s", name);
            zwlr_virtual_pointer_v1_button(pointer, now_ms(), button_code(name),
                                           strcmp(cmd, "press") == 0
                                                   ? WL_POINTER_BUTTON_STATE_PRESSED
                                                   : WL_POINTER_BUTTON_STATE_RELEASED);
            zwlr_virtual_pointer_v1_frame(pointer);
        } else if (strcmp(cmd, "scroll") == 0 && sscanf(line, "%*s %ld", &a) == 1) {
            zwlr_virtual_pointer_v1_axis_source(pointer, WL_POINTER_AXIS_SOURCE_WHEEL);
            zwlr_virtual_pointer_v1_axis_discrete(pointer, now_ms(),
                                                  WL_POINTER_AXIS_VERTICAL_SCROLL,
                                                  wl_fixed_from_int((int) a * 15), (int32_t) a);
            zwlr_virtual_pointer_v1_frame(pointer);
        } else if (strcmp(cmd, "sleep") == 0 && sscanf(line, "%*s %ld", &a) == 1) {
            wl_display_flush(display);
            nap(a);
            continue;
        } else {
            fprintf(stderr, "vptr: ignored %s", line);
            continue;
        }
        wl_display_flush(display);
        /* EVERY COMMAND IS ITS OWN MOMENT. Without this the script is written into the socket in
         * one go and the compositor sees a gesture with no time in it, which is the failure this
         * tool exists to avoid. */
        nap(20);
    }

    wl_display_flush(display);
    nap(200);
    zwlr_virtual_pointer_v1_destroy(pointer);
    wl_display_roundtrip(display);
    fprintf(stderr, "vptr: done\n");
    return 0;
}
