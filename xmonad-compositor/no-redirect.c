/*
 * no-redirect.c — LD_PRELOAD shim
 *
 * Strips XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT from every
 * xcb_change_window_attributes call so that wlroots' built-in xwm
 * (which always grabs that mask on the root window) leaves the slot
 * free for an external X11 window manager (xmonad).
 *
 * The xwm still has XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY, so it can
 * track window lifecycle (create/map/configure/destroy) via Notify
 * events. Only the Redirect (intercept-before-execute) half is removed.
 *
 * Build:
 *   gcc -shared -fPIC -o no-redirect.so no-redirect.c -ldl
 * Use:
 *   LD_PRELOAD=/path/to/no-redirect.so xmonad-wlr
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <xcb/xcb.h>

/* XCB constants (avoid pulling in full xcb headers in the shim) */
#define XCB_CW_EVENT_MASK              0x00000800u
#define XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT 0x00100000u

typedef xcb_void_cookie_t (*fn_t)(xcb_connection_t *, xcb_window_t,
                                  uint32_t, const void *);

xcb_void_cookie_t
xcb_change_window_attributes(xcb_connection_t *c, xcb_window_t window,
                              uint32_t value_mask, const void *value_list)
{
    static fn_t real = NULL;
    if (!real)
        real = (fn_t)dlsym(RTLD_NEXT, "xcb_change_window_attributes");

    if ((value_mask & XCB_CW_EVENT_MASK) && value_list) {
        /*
         * value_list is a packed array of uint32_t, one entry per set bit
         * in value_mask (LSB first). Count bits below XCB_CW_EVENT_MASK
         * to find the index of the event-mask entry.
         */
        uint32_t bits_below = value_mask & (XCB_CW_EVENT_MASK - 1u);
        int idx = __builtin_popcount(bits_below);

        const uint32_t *vals = (const uint32_t *)value_list;
        if (vals[idx] & XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT) {
            /* Copy, strip the redirect bit, call real function */
            int total = __builtin_popcount(value_mask);
            uint32_t patched[32];
            memcpy(patched, value_list, (size_t)total * sizeof(uint32_t));
            patched[idx] &= ~XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT;
            return real(c, window, value_mask, patched);
        }
    }

    return real(c, window, value_mask, value_list);
}
