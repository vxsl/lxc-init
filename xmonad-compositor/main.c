/*
 * xmonad-wlr: minimal Wayland compositor for running xmonad via
 * rootless Xwayland on wlroots 0.19.
 *
 * Architecture:
 *   - wlroots handles GPU output, input devices, Xwayland bridge
 *   - xmonad is the X11 window manager (holds SubstructureRedirect)
 *   - no-redirect.so (LD_PRELOAD) prevents wlroots' built-in xwm from
 *     grabbing SubstructureRedirect, leaving that for xmonad
 *   - This compositor just renders surfaces at the positions the X11 WM sets
 *
 * Compile via meson (see meson.build).
 */

#define _POSIX_C_SOURCE 200809L
#define WLR_USE_UNSTABLE

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_pointer.h>
#include <wlr/types/wlr_primary_selection_v1.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/util/log.h>
#include <wlr/xwayland/xwayland.h>
#include <xkbcommon/xkbcommon.h>

/* ── forward declarations ────────────────────────────────────────────── */
struct server;
static void process_cursor_motion(struct server *s, uint32_t time_msec);

/* ── data structures ─────────────────────────────────────────────────── */

struct server {
    struct wl_display             *display;
    struct wlr_backend            *backend;
    struct wlr_renderer           *renderer;
    struct wlr_allocator          *allocator;
    struct wlr_compositor         *compositor;
    struct wlr_scene              *scene;
    struct wlr_scene_output_layout *scene_layout;
    struct wlr_output_layout      *output_layout;
    struct wlr_seat               *seat;
    struct wlr_cursor             *cursor;
    struct wlr_xcursor_manager    *cursor_mgr;
    struct wlr_xwayland           *xwayland;

    struct wl_list views;    /* xw_view.link   */
    struct wl_list outputs;  /* output.link    */
    struct wl_list keyboards;/* keyboard.link  */

    struct wl_listener new_output;
    struct wl_listener new_input;
    struct wl_listener cursor_motion;
    struct wl_listener cursor_motion_absolute;
    struct wl_listener cursor_button;
    struct wl_listener cursor_axis;
    struct wl_listener cursor_frame;
    struct wl_listener request_set_cursor;
    struct wl_listener xwayland_ready;
    struct wl_listener new_xwayland_surface;
};

struct output {
    struct wl_list     link;
    struct server     *server;
    struct wlr_output *wlr_output;
    struct wl_listener frame;
    struct wl_listener request_state;
    struct wl_listener destroy;
};

struct keyboard {
    struct wl_list        link;
    struct server        *server;
    struct wlr_keyboard  *wlr_keyboard;
    struct wl_listener    key;
    struct wl_listener    modifiers;
    struct wl_listener    destroy;
};

/*
 * One xw_view per wlr_xwayland_surface.
 * We create a scene_surface after 'associate' (when xsurface->surface becomes
 * valid) and destroy it on 'dissociate'. Position is kept in sync via
 * 'set_geometry'. The scene graph handles visibility automatically based on
 * whether the surface has committed content.
 */
struct xw_view {
    struct wl_list               link;
    struct server               *server;
    struct wlr_xwayland_surface *xsurface;
    struct wlr_scene_surface    *scene_surface; /* non-NULL when associated */

    struct wl_listener associate;
    struct wl_listener dissociate;
    struct wl_listener set_geometry;
    struct wl_listener destroy;
};

/* ── output handlers ─────────────────────────────────────────────────── */

static void output_frame(struct wl_listener *listener, void *data) {
    struct output *output = wl_container_of(listener, output, frame);
    struct wlr_scene_output *so =
        wlr_scene_get_scene_output(output->server->scene, output->wlr_output);
    if (!so) return;
    wlr_scene_output_commit(so, NULL);
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    wlr_scene_output_send_frame_done(so, &now);
}

static void output_request_state(struct wl_listener *listener, void *data) {
    struct output *output = wl_container_of(listener, output, request_state);
    const struct wlr_output_event_request_state *ev = data;
    wlr_output_commit_state(output->wlr_output, ev->state);
}

static void output_destroy(struct wl_listener *listener, void *data) {
    struct output *output = wl_container_of(listener, output, destroy);
    wl_list_remove(&output->frame.link);
    wl_list_remove(&output->request_state.link);
    wl_list_remove(&output->destroy.link);
    wl_list_remove(&output->link);
    free(output);
}

static void handle_new_output(struct wl_listener *listener, void *data) {
    struct server     *server = wl_container_of(listener, server, new_output);
    struct wlr_output *wlr_output = data;

    wlr_output_init_render(wlr_output, server->allocator, server->renderer);

    struct wlr_output_state state;
    wlr_output_state_init(&state);
    wlr_output_state_set_enabled(&state, true);
    struct wlr_output_mode *mode = wlr_output_preferred_mode(wlr_output);
    if (mode) wlr_output_state_set_mode(&state, mode);
    wlr_output_commit_state(wlr_output, &state);
    wlr_output_state_finish(&state);

    struct output *output = calloc(1, sizeof(*output));
    output->server     = server;
    output->wlr_output = wlr_output;

    output->frame.notify = output_frame;
    wl_signal_add(&wlr_output->events.frame, &output->frame);
    output->request_state.notify = output_request_state;
    wl_signal_add(&wlr_output->events.request_state, &output->request_state);
    output->destroy.notify = output_destroy;
    wl_signal_add(&wlr_output->events.destroy, &output->destroy);

    wl_list_insert(&server->outputs, &output->link);
    wlr_output_layout_add_auto(server->output_layout, wlr_output);
    wlr_scene_output_create(server->scene, wlr_output);
}

/* ── keyboard handlers ───────────────────────────────────────────────── */

static void keyboard_handle_modifiers(struct wl_listener *listener, void *data) {
    struct keyboard *kb = wl_container_of(listener, kb, modifiers);
    wlr_seat_set_keyboard(kb->server->seat, kb->wlr_keyboard);
    wlr_seat_keyboard_notify_modifiers(kb->server->seat,
        &kb->wlr_keyboard->modifiers);
}

static void keyboard_handle_key(struct wl_listener *listener, void *data) {
    struct keyboard *kb = wl_container_of(listener, kb, key);
    struct wlr_keyboard_key_event *ev = data;
    wlr_seat_set_keyboard(kb->server->seat, kb->wlr_keyboard);
    wlr_seat_keyboard_notify_key(kb->server->seat,
        ev->time_msec, ev->keycode, ev->state);
}

static void keyboard_destroy(struct wl_listener *listener, void *data) {
    struct keyboard *kb = wl_container_of(listener, kb, destroy);
    wl_list_remove(&kb->modifiers.link);
    wl_list_remove(&kb->key.link);
    wl_list_remove(&kb->destroy.link);
    wl_list_remove(&kb->link);
    free(kb);
}

static void handle_new_keyboard(struct server *server,
                                 struct wlr_input_device *device) {
    struct wlr_keyboard *wlr_kb = wlr_keyboard_from_input_device(device);
    struct xkb_context  *ctx    = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_keymap   *keymap = xkb_keymap_new_from_names(ctx, NULL,
        XKB_KEYMAP_COMPILE_NO_FLAGS);
    wlr_keyboard_set_keymap(wlr_kb, keymap);
    xkb_keymap_unref(keymap);
    xkb_context_unref(ctx);
    wlr_keyboard_set_repeat_info(wlr_kb, 25, 600);

    struct keyboard *kb = calloc(1, sizeof(*kb));
    kb->server       = server;
    kb->wlr_keyboard = wlr_kb;

    kb->modifiers.notify = keyboard_handle_modifiers;
    wl_signal_add(&wlr_kb->events.modifiers, &kb->modifiers);
    kb->key.notify = keyboard_handle_key;
    wl_signal_add(&wlr_kb->events.key, &kb->key);
    kb->destroy.notify = keyboard_destroy;
    wl_signal_add(&device->events.destroy, &kb->destroy);

    wl_list_insert(&server->keyboards, &kb->link);
    wlr_seat_set_keyboard(server->seat, wlr_kb);
}

/* ── pointer / cursor handlers ───────────────────────────────────────── */

static void process_cursor_motion(struct server *server, uint32_t time_msec) {
    double sx = 0, sy = 0;
    struct wlr_scene_node *node = wlr_scene_node_at(
        &server->scene->tree.node,
        server->cursor->x, server->cursor->y, &sx, &sy);

    struct wlr_surface *surface = NULL;
    if (node && node->type == WLR_SCENE_NODE_BUFFER) {
        struct wlr_scene_buffer  *sb = wlr_scene_buffer_from_node(node);
        struct wlr_scene_surface *ss = wlr_scene_surface_try_from_buffer(sb);
        if (ss) surface = ss->surface;
    }

    if (surface) {
        wlr_seat_pointer_notify_enter(server->seat, surface, sx, sy);
        wlr_seat_pointer_notify_motion(server->seat, time_msec, sx, sy);
    } else {
        wlr_seat_pointer_clear_focus(server->seat);
    }
    wlr_cursor_set_xcursor(server->cursor, server->cursor_mgr, "default");
}

static void cursor_motion(struct wl_listener *listener, void *data) {
    struct server *server = wl_container_of(listener, server, cursor_motion);
    struct wlr_pointer_motion_event *ev = data;
    wlr_cursor_move(server->cursor, &ev->pointer->base, ev->delta_x, ev->delta_y);
    process_cursor_motion(server, ev->time_msec);
}

static void cursor_motion_absolute(struct wl_listener *listener, void *data) {
    struct server *server =
        wl_container_of(listener, server, cursor_motion_absolute);
    struct wlr_pointer_motion_absolute_event *ev = data;
    wlr_cursor_warp_absolute(server->cursor, &ev->pointer->base, ev->x, ev->y);
    process_cursor_motion(server, ev->time_msec);
}

static void cursor_button(struct wl_listener *listener, void *data) {
    struct server *server = wl_container_of(listener, server, cursor_button);
    struct wlr_pointer_button_event *ev = data;
    wlr_seat_pointer_notify_button(server->seat,
        ev->time_msec, ev->button, ev->state);
}

static void cursor_axis(struct wl_listener *listener, void *data) {
    struct server *server = wl_container_of(listener, server, cursor_axis);
    struct wlr_pointer_axis_event *ev = data;
    wlr_seat_pointer_notify_axis(server->seat,
        ev->time_msec, ev->orientation,
        ev->delta, ev->delta_discrete, ev->source,
        ev->relative_direction);
}

static void cursor_frame(struct wl_listener *listener, void *data) {
    struct server *server = wl_container_of(listener, server, cursor_frame);
    wlr_seat_pointer_notify_frame(server->seat);
}

static void request_set_cursor(struct wl_listener *listener, void *data) {
    struct server *server = wl_container_of(listener, server, request_set_cursor);
    struct wlr_seat_pointer_request_set_cursor_event *ev = data;
    if (server->seat->pointer_state.focused_client == ev->seat_client)
        wlr_cursor_set_surface(server->cursor, ev->surface,
            ev->hotspot_x, ev->hotspot_y);
}

static void handle_new_pointer(struct server *server,
                                struct wlr_input_device *device) {
    wlr_cursor_attach_input_device(server->cursor, device);
}

static void handle_new_input(struct wl_listener *listener, void *data) {
    struct server          *server = wl_container_of(listener, server, new_input);
    struct wlr_input_device *device = data;
    switch (device->type) {
    case WLR_INPUT_DEVICE_KEYBOARD: handle_new_keyboard(server, device); break;
    case WLR_INPUT_DEVICE_POINTER:  handle_new_pointer(server, device);  break;
    default: break;
    }
    uint32_t caps = WL_SEAT_CAPABILITY_POINTER;
    if (!wl_list_empty(&server->keyboards)) caps |= WL_SEAT_CAPABILITY_KEYBOARD;
    wlr_seat_set_capabilities(server->seat, caps);
}

/* ── Xwayland surface (view) handlers ───────────────────────────────── */

static void xw_view_set_geometry(struct wl_listener *listener, void *data) {
    struct xw_view *view = wl_container_of(listener, view, set_geometry);
    if (view->scene_surface)
        wlr_scene_node_set_position(&view->scene_surface->buffer->node,
            view->xsurface->x, view->xsurface->y);
}

static void xw_view_associate(struct wl_listener *listener, void *data) {
    struct xw_view *view = wl_container_of(listener, view, associate);
    assert(!view->scene_surface);
    view->scene_surface = wlr_scene_surface_create(
        &view->server->scene->tree, view->xsurface->surface);
    if (!view->scene_surface) return;
    /* Position immediately; the scene will show content once committed. */
    wlr_scene_node_set_position(&view->scene_surface->buffer->node,
        view->xsurface->x, view->xsurface->y);
}

static void xw_view_dissociate(struct wl_listener *listener, void *data) {
    struct xw_view *view = wl_container_of(listener, view, dissociate);
    if (view->scene_surface) {
        wlr_scene_node_destroy(&view->scene_surface->buffer->node);
        view->scene_surface = NULL;
    }
}

static void xw_view_destroy(struct wl_listener *listener, void *data) {
    struct xw_view *view = wl_container_of(listener, view, destroy);
    wl_list_remove(&view->associate.link);
    wl_list_remove(&view->dissociate.link);
    wl_list_remove(&view->set_geometry.link);
    wl_list_remove(&view->destroy.link);
    wl_list_remove(&view->link);
    free(view);
}

static void handle_new_xwayland_surface(struct wl_listener *listener,
                                         void *data) {
    struct server               *server =
        wl_container_of(listener, server, new_xwayland_surface);
    struct wlr_xwayland_surface *xsurface = data;

    struct xw_view *view = calloc(1, sizeof(*view));
    view->server   = server;
    view->xsurface = xsurface;

    view->associate.notify = xw_view_associate;
    wl_signal_add(&xsurface->events.associate, &view->associate);

    view->dissociate.notify = xw_view_dissociate;
    wl_signal_add(&xsurface->events.dissociate, &view->dissociate);

    view->set_geometry.notify = xw_view_set_geometry;
    wl_signal_add(&xsurface->events.set_geometry, &view->set_geometry);

    view->destroy.notify = xw_view_destroy;
    wl_signal_add(&xsurface->events.destroy, &view->destroy);

    wl_list_insert(&server->views, &view->link);
}

/* ── Xwayland ready ──────────────────────────────────────────────────── */

static void xwayland_ready(struct wl_listener *listener, void *data) {
    struct server *server = wl_container_of(listener, server, xwayland_ready);
    wlr_xwayland_set_seat(server->xwayland, server->seat);
    setenv("DISPLAY", server->xwayland->display_name, 1);
    wlr_log(WLR_INFO, "Xwayland ready on %s; launching xmonad",
        server->xwayland->display_name);

    pid_t pid = fork();
    if (pid == 0) {
        setsid();
        /* Inherit DISPLAY set above */
        execl("/bin/sh", "sh", "-c", "xmonad", NULL);
        _exit(1);
    }
}

/* ── main ────────────────────────────────────────────────────────────── */

int main(void) {
    wlr_log_init(WLR_DEBUG, NULL);

    struct server server = {0};
    wl_list_init(&server.views);
    wl_list_init(&server.outputs);
    wl_list_init(&server.keyboards);

    server.display = wl_display_create();
    struct wl_event_loop *loop = wl_display_get_event_loop(server.display);

    server.backend = wlr_backend_autocreate(loop, NULL);
    if (!server.backend) {
        wlr_log(WLR_ERROR, "failed to create backend");
        return 1;
    }

    server.renderer = wlr_renderer_autocreate(server.backend);
    wlr_renderer_init_wl_display(server.renderer, server.display);

    server.allocator = wlr_allocator_autocreate(server.backend, server.renderer);

    /* Wayland globals */
    server.compositor = wlr_compositor_create(server.display, 5, server.renderer);
    wlr_subcompositor_create(server.display);
    wlr_data_device_manager_create(server.display);
    wlr_primary_selection_v1_device_manager_create(server.display);

    /* Output layout + scene graph */
    server.output_layout = wlr_output_layout_create(server.display);
    server.scene         = wlr_scene_create();
    server.scene_layout  = wlr_scene_attach_output_layout(server.scene,
        server.output_layout);

    /* Seat + cursor */
    server.seat       = wlr_seat_create(server.display, "seat0");
    server.cursor     = wlr_cursor_create();
    wlr_cursor_attach_output_layout(server.cursor, server.output_layout);
    server.cursor_mgr = wlr_xcursor_manager_create(NULL, 24);
    wlr_xcursor_manager_load(server.cursor_mgr, 1);

    /* Cursor events */
    server.cursor_motion.notify = cursor_motion;
    wl_signal_add(&server.cursor->events.motion, &server.cursor_motion);
    server.cursor_motion_absolute.notify = cursor_motion_absolute;
    wl_signal_add(&server.cursor->events.motion_absolute,
        &server.cursor_motion_absolute);
    server.cursor_button.notify = cursor_button;
    wl_signal_add(&server.cursor->events.button, &server.cursor_button);
    server.cursor_axis.notify = cursor_axis;
    wl_signal_add(&server.cursor->events.axis, &server.cursor_axis);
    server.cursor_frame.notify = cursor_frame;
    wl_signal_add(&server.cursor->events.frame, &server.cursor_frame);
    server.request_set_cursor.notify = request_set_cursor;
    wl_signal_add(&server.seat->events.request_set_cursor,
        &server.request_set_cursor);

    /* Backend events */
    server.new_output.notify = handle_new_output;
    wl_signal_add(&server.backend->events.new_output, &server.new_output);
    server.new_input.notify = handle_new_input;
    wl_signal_add(&server.backend->events.new_input, &server.new_input);

    /* Rootless Xwayland (lazy=false: start immediately, not on first connect) */
    server.xwayland = wlr_xwayland_create(server.display, server.compositor, false);
    if (!server.xwayland) {
        wlr_log(WLR_ERROR, "failed to create Xwayland");
        return 1;
    }
    server.xwayland_ready.notify = xwayland_ready;
    wl_signal_add(&server.xwayland->events.ready, &server.xwayland_ready);
    server.new_xwayland_surface.notify = handle_new_xwayland_surface;
    wl_signal_add(&server.xwayland->events.new_surface,
        &server.new_xwayland_surface);

    /* Wayland socket */
    const char *socket = wl_display_add_socket_auto(server.display);
    if (!socket) {
        wlr_log(WLR_ERROR, "failed to create Wayland socket");
        return 1;
    }
    setenv("WAYLAND_DISPLAY", socket, 1);
    wlr_log(WLR_INFO, "running on WAYLAND_DISPLAY=%s", socket);

    if (!wlr_backend_start(server.backend)) {
        wlr_log(WLR_ERROR, "failed to start backend");
        return 1;
    }

    wl_display_run(server.display);

    wlr_xwayland_destroy(server.xwayland);
    wlr_backend_destroy(server.backend);
    wl_display_destroy_clients(server.display);
    wl_display_destroy(server.display);
    return 0;
}
