// The host window backend for a flat guest (kl_flatwin.h) — a plain SDL3
// window with a Metal view, on macOS, for the glibc door's SDL seam.
//
// Host-only, like kl_view.c next door and for the same reasons: it is SDL3, it
// is a desktop window, and only m_boot links it. On device the backend slot is
// empty (or, later, Compositor Services' through kl_openxr).
//
// AppKit wants windows made and events pumped on the main thread, and the
// guest calls SDL_CreateWindow from its own. So create/destroy/set_* post a
// request and wait; kl_hostwin_pump — the door's pump loop, on the main thread
// — serves the requests and turns SDL3 input into kl_fw_events, which the
// guest's thread then collects through poll().
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "kl_hostwin.h"

#if __has_include(<SDL3/SDL.h>)
#include <SDL3/SDL.h>

typedef enum { RQ_CREATE = 1, RQ_DESTROY, RQ_TITLE, RQ_SIZE, RQ_SHOW, RQ_RELMOUSE } rq_kind;
typedef struct {
    rq_kind kind;
    char title[256];
    int w, h, on;
    uint32_t flags;
    SDL_Window *win;
    // results
    void *layer;
    int pw, ph, done;
} request;

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_cv = PTHREAD_COND_INITIALIZER;
static request *g_rq;                         // one outstanding request at a time
static pthread_mutex_t g_rq_serial = PTHREAD_MUTEX_INITIALIZER;
static SDL_Window *g_win;                     // the one window this backend shows
static int g_sdl_up, g_rel;

#define EVQ 1024
static kl_fw_event g_evq[EVQ];
static unsigned g_head, g_tail;

static void post(request *r) {
    pthread_mutex_lock(&g_rq_serial);
    pthread_mutex_lock(&g_mu);
    r->done = 0;
    g_rq = r;
    while (!r->done) pthread_cond_wait(&g_cv, &g_mu);
    pthread_mutex_unlock(&g_mu);
    pthread_mutex_unlock(&g_rq_serial);
}

static void push_ev(const kl_fw_event *e) {
    pthread_mutex_lock(&g_mu);
    if (g_tail - g_head < EVQ) g_evq[g_tail++ % EVQ] = *e;
    pthread_mutex_unlock(&g_mu);
}

static void *hw_create(const char *title, int w, int h, uint32_t flags,
                       void **layer, int *pw, int *ph) {
    request r = { .kind = RQ_CREATE, .w = w, .h = h, .flags = flags };
    snprintf(r.title, sizeof r.title, "%s", title ? title : "Klepton");
    post(&r);
    if (layer) *layer = r.layer;
    if (pw) *pw = r.pw;
    if (ph) *ph = r.ph;
    return r.win;
}
static void hw_destroy(void *win) { request r = { .kind = RQ_DESTROY, .win = win }; post(&r); }
static void hw_set_title(void *win, const char *t) {
    request r = { .kind = RQ_TITLE, .win = win };
    snprintf(r.title, sizeof r.title, "%s", t ? t : "");
    post(&r);
}
static void hw_set_size(void *win, int w, int h) {
    request r = { .kind = RQ_SIZE, .win = win, .w = w, .h = h }; post(&r);
}
static void hw_show(void *win, int on) { request r = { .kind = RQ_SHOW, .win = win, .on = on }; post(&r); }
static void hw_relmouse(int on) { request r = { .kind = RQ_RELMOUSE, .on = on }; post(&r); }

// Grab, cursor and warp: latest-wins state for pump() to apply (kl_flatwin.h).
// -1 = nothing pending.
static int g_want_grab = -1, g_want_cursor = -1, g_want_warp, g_warp_x, g_warp_y;
static void hw_grab(int on)    { pthread_mutex_lock(&g_mu); g_want_grab = !!on; pthread_mutex_unlock(&g_mu); }
static void hw_cursor(int on)  { pthread_mutex_lock(&g_mu); g_want_cursor = !!on; pthread_mutex_unlock(&g_mu); }
static void hw_warp(int x, int y) {
    pthread_mutex_lock(&g_mu);
    g_want_warp = 1; g_warp_x = x; g_warp_y = y;
    pthread_mutex_unlock(&g_mu);
}

static void hw_display(int *w, int *h, int *hz) {
    // Read once on the main thread by pump(); before that, a sane desktop.
    static int cw, ch, chz;
    if (!cw && g_sdl_up) {
        const SDL_DisplayMode *m = SDL_GetDesktopDisplayMode(SDL_GetPrimaryDisplay());
        if (m) { cw = m->w; ch = m->h; chz = (int)(m->refresh_rate + 0.5f); }
    }
    *w = cw ? cw : 1920; *h = ch ? ch : 1080; *hz = chz ? chz : 60;
}

static int hw_poll(kl_fw_event *e) {
    int got = 0;
    pthread_mutex_lock(&g_mu);
    if (g_head != g_tail) { *e = g_evq[g_head++ % EVQ]; got = 1; }
    pthread_mutex_unlock(&g_mu);
    return got;
}

static void serve(request *r) {
    switch (r->kind) {
    case RQ_CREATE: {
        // No HIGH_PIXEL_DENSITY: one drawable pixel per point. With it the
        // CAMetalLayer was 2x on Retina, so MoltenVK's currentExtent (and the
        // swapchain) disagreed with the window size the engine sizes its
        // viewport from, and the frame filled only the top-left quarter.
        // Points everywhere keeps window, drawable, surface extent, display
        // mode and mouse coordinates in one space, and costs a quarter the fill.
        SDL_WindowFlags f = SDL_WINDOW_METAL | SDL_WINDOW_RESIZABLE;
        SDL_Window *w = SDL_CreateWindow(r->title, r->w, r->h, f);
        if (!w) { fprintf(stderr, "  [hostwin] SDL_CreateWindow: %s\n", SDL_GetError()); break; }
        SDL_MetalView v = SDL_Metal_CreateView(w);
        r->layer = v ? SDL_Metal_GetLayer(v) : NULL;
        SDL_GetWindowSizeInPixels(w, &r->pw, &r->ph);
        r->win = w;
        g_win = w;
        SDL_ShowWindow(w);
        SDL_RaiseWindow(w);
        fprintf(stderr, "  [hostwin] window \"%s\" %dx%d (%dx%d px), layer %p\n",
                r->title, r->w, r->h, r->pw, r->ph, r->layer);
        break;
    }
    case RQ_DESTROY:
        if (r->win) SDL_DestroyWindow(r->win);
        if (r->win == g_win) g_win = NULL;
        break;
    case RQ_TITLE: if (r->win) SDL_SetWindowTitle(r->win, r->title); break;
    case RQ_SIZE:  if (r->win) SDL_SetWindowSize(r->win, r->w, r->h); break;
    case RQ_SHOW:  if (r->win) { if (r->on) SDL_ShowWindow(r->win); else SDL_HideWindow(r->win); } break;
    case RQ_RELMOUSE:
        g_rel = r->on;
        if (g_win) SDL_SetWindowRelativeMouseMode(g_win, r->on ? true : false);
        break;
    }
}

static void translate(const SDL_Event *s) {
    kl_fw_event e;
    memset(&e, 0, sizeof e);
    switch (s->type) {
    case SDL_EVENT_QUIT: e.kind = KL_FW_QUIT; break;
    case SDL_EVENT_WINDOW_CLOSE_REQUESTED: e.kind = KL_FW_CLOSE; break;
    case SDL_EVENT_WINDOW_FOCUS_GAINED: e.kind = KL_FW_FOCUS; e.down = 1; break;
    case SDL_EVENT_WINDOW_FOCUS_LOST: e.kind = KL_FW_FOCUS; break;
    case SDL_EVENT_WINDOW_MOUSE_ENTER: e.kind = KL_FW_ENTER; e.down = 1; break;
    case SDL_EVENT_WINDOW_MOUSE_LEAVE: e.kind = KL_FW_ENTER; break;
    case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED: {
        SDL_Window *w = SDL_GetWindowFromID(s->window.windowID);
        if (!w) return;
        e.kind = KL_FW_RESIZED;
        SDL_GetWindowSize(w, &e.x, &e.y);
        SDL_GetWindowSizeInPixels(w, &e.dx, &e.dy);
        break;
    }
    case SDL_EVENT_KEY_DOWN: case SDL_EVENT_KEY_UP:
        e.kind = KL_FW_KEY;
        e.down = s->type == SDL_EVENT_KEY_DOWN;
        e.repeat = s->key.repeat;
        e.scancode = (int)s->key.scancode;
        e.keycode = (int)s->key.key;
        e.mod = (int)s->key.mod;
        break;
    case SDL_EVENT_TEXT_INPUT:
        e.kind = KL_FW_TEXT;
        snprintf(e.text, sizeof e.text, "%s", s->text.text ? s->text.text : "");
        break;
    case SDL_EVENT_MOUSE_MOTION:
        e.kind = KL_FW_MOTION;
        e.x = (int)s->motion.x; e.y = (int)s->motion.y;
        e.dx = (int)s->motion.xrel; e.dy = (int)s->motion.yrel;
        e.buttons = (int)s->motion.state;
        break;
    case SDL_EVENT_MOUSE_BUTTON_DOWN: case SDL_EVENT_MOUSE_BUTTON_UP:
        e.kind = KL_FW_BUTTON;
        e.down = s->type == SDL_EVENT_MOUSE_BUTTON_DOWN;
        e.button = s->button.button;
        e.clicks = s->button.clicks;
        e.x = (int)s->button.x; e.y = (int)s->button.y;
        break;
    case SDL_EVENT_MOUSE_WHEEL:
        e.kind = KL_FW_WHEEL; e.fx = s->wheel.x; e.fy = s->wheel.y;
        break;
    default:
        return;
    }
    push_ev(&e);
}

static void hw_pump(void) {
    if (!g_sdl_up) {
        if (!SDL_Init(SDL_INIT_VIDEO)) {
            static int said;
            if (!said++) fprintf(stderr, "  [hostwin] SDL_Init: %s\n", SDL_GetError());
            return;
        }
        g_sdl_up = 1;
    }
    pthread_mutex_lock(&g_mu);
    request *r = g_rq;
    pthread_mutex_unlock(&g_mu);
    if (r) {
        serve(r);
        pthread_mutex_lock(&g_mu);
        g_rq = NULL;
        r->done = 1;
        pthread_cond_broadcast(&g_cv);
        pthread_mutex_unlock(&g_mu);
    }
    pthread_mutex_lock(&g_mu);
    int grab = g_want_grab, cur = g_want_cursor, warp = g_want_warp, wx = g_warp_x, wy = g_warp_y;
    g_want_grab = g_want_cursor = -1; g_want_warp = 0;
    pthread_mutex_unlock(&g_mu);
    if (g_win && grab >= 0) SDL_SetWindowMouseGrab(g_win, grab ? true : false);
    if (cur >= 0) { if (cur) SDL_ShowCursor(); else SDL_HideCursor(); }
    // A warp in relative mode is the engine re-centring a pointer it is not
    // reading; SDL3 would turn it into a motion event that undoes the look.
    if (g_win && warp && !g_rel) SDL_WarpMouseInWindow(g_win, (float)wx, (float)wy);
    SDL_Event ev;
    while (SDL_PollEvent(&ev)) translate(&ev);
}

static const kl_flatwin_backend g_backend = {
    .name = "host window (SDL3 + CAMetalLayer)",
    .create = hw_create, .destroy = hw_destroy, .set_title = hw_set_title,
    .set_size = hw_set_size, .show = hw_show, .set_relative_mouse = hw_relmouse,
    .set_grab = hw_grab, .show_cursor = hw_cursor, .warp = hw_warp,
    .display = hw_display, .poll = hw_poll, .pump = hw_pump,
};
const kl_flatwin_backend *kl_hostwin_backend(void) { return &g_backend; }

#else
const kl_flatwin_backend *kl_hostwin_backend(void) { return NULL; }
#endif
