// Where a flat (desktop) guest's window goes — the backend half of the glibc
// door's SDL seam (kl_glibc_sdl.c).
//
// The guest asks its own libSDL2 for a window and a Vulkan surface. Its SDL has
// no video driver it could use here (X11 and Wayland are deliberately not
// loaded), so the seam answers those calls itself and asks a BACKEND for the
// one thing it cannot make: somewhere to put the picture.
//
//   host    a real window (kl_hostwin.c, SDL3, macOS only, host-only like
//           kl_view.c): create() returns its CAMetalLayer, the guest's
//           VkSurfaceKHR is vkCreateMetalSurfaceEXT on it, and MoltenVK
//           presents natively. Keyboard and mouse come back as events.
//   none    no backend registered — headless, and the shape the VR backend
//           takes on visionOS: create() is never called, the surface is
//           kl_vulkan's synthetic one, and whoever owns presentation
//           (Compositor Services via kl_openxr) takes the frames from there.
//
// A backend's create/destroy/set_* are called from the GUEST's thread; it owns
// getting them onto whichever thread its window system wants (AppKit: main),
// and pump() is how it gets that thread: the door's pump loop calls it there.
#ifndef KL_FLATWIN_H
#define KL_FLATWIN_H
#include <stdint.h>

// One input event, in SDL's own numbering (SDL2 and SDL3 share USB-HID
// scancodes and their printable keycodes), so the seam's translation to an
// SDL2 SDL_Event is field-for-field.
typedef enum {
    KL_FW_QUIT = 1,
    KL_FW_KEY,          // down, scancode, keycode, mod, repeat
    KL_FW_TEXT,         // text (UTF-8, <= 31 bytes)
    KL_FW_MOTION,       // x, y, dx, dy, buttons
    KL_FW_BUTTON,       // down, button (1 L, 2 M, 3 R), x, y, clicks
    KL_FW_WHEEL,        // fx, fy
    KL_FW_RESIZED,      // x = w, y = h (window points); dx/dy = drawable pixels
    KL_FW_FOCUS,        // down = gained
    KL_FW_CLOSE,
    KL_FW_ENTER,        // down = the pointer entered the window, 0 = left it
} kl_fw_kind;

typedef struct {
    kl_fw_kind kind;
    int  down, repeat, clicks;
    int  scancode, keycode, mod, button, buttons;
    int  x, y, dx, dy;
    float fx, fy;
    char text[32];
} kl_fw_event;

typedef struct {
    const char *name;
    // A window of w x h points. Returns an opaque handle (NULL on failure) and
    // writes its CAMetalLayer (or NULL when the backend has none) and its
    // drawable size in pixels.
    void *(*create)(const char *title, int w, int h, uint32_t sdl_flags,
                    void **metal_layer, int *pw, int *ph);
    void  (*destroy)(void *win);
    void  (*set_title)(void *win, const char *title);
    void  (*set_size)(void *win, int w, int h);
    void  (*show)(void *win, int shown);
    void  (*set_relative_mouse)(int on);
    // Pointer state the guest asks for many times a frame (a warp per frame
    // in some engines), so these only record what is wanted: pump() applies
    // the latest on the window system's thread and the caller never waits.
    void  (*set_grab)(int on);
    void  (*show_cursor)(int shown);
    void  (*warp)(int x, int y);           // window points
    // The display: size in points, refresh in Hz.
    void  (*display)(int *w, int *h, int *hz);
    // Next pending event, 1 if one was written. Any thread.
    int   (*poll)(kl_fw_event *ev);
    // The window system's own thread (the door's pump loop): service create/
    // destroy requests and collect input. Must be cheap when idle.
    void  (*pump)(void);
} kl_flatwin_backend;

// Register (or clear, with NULL) the backend. The host driver does this for a
// glibc target before the guest starts; nothing registers one on device yet.
void kl_flatwin_set_backend(const kl_flatwin_backend *b);
const kl_flatwin_backend *kl_flatwin_backend_now(void);

#endif
