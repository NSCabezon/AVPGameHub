// The glibc door's SDL video seam — see kl_flatwin.h for the backend half.
//
// Source 2 drives its window, its Vulkan surface and its input through SDL2,
// taking almost all of SDL by dlsym (and Panorama by plain imports). The guest's
// own libSDL2 is linked against X11/Wayland, neither of which is loaded here,
// so its video subsystem cannot come up: SDL_Vulkan_GetInstanceExtensions
// fails, the render system reports #Vulkan_InitializationFailure and quits.
//
// So the VIDEO half of SDL is answered here and everything else stays the
// guest's: SDL_Init loses SDL_INIT_VIDEO on its way to the real one (and gains
// EVENTS, so the event queue exists), windows are ours, the Vulkan surface is
// MoltenVK's on the backend's CAMetalLayer (or kl_vulkan's synthetic one when
// there is no window), and host input is pushed into the guest's own event
// queue with its own SDL_PushEvent — on the guest's thread, inside the
// SDL_PumpEvents/SDL_PollEvent family it was already calling. AUDIO OUTPUT is
// answered here too (see "audio" below): the guest SDL's drivers are ALSA,
// PulseAudio and PipeWire, none of which exist. Joysticks, timers, threads,
// hints, audio-stream conversion and the keyboard tables remain the real SDL.
//
// Reached two ways, both from kl_glibc.c: the glibc ABI tier (imports bound at
// relocation — Panorama's) and the dlsym override (the engine's SDL table).
// The SDL2 ABI this writes against: SDL_Event is a 56-byte union, SDL_Window
// is opaque, SDL_DisplayMode is { format, w, h, refresh_rate, driverdata }.
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "klepton.h"
#include "kl_env.h"
#include "kl_flatwin.h"
#include "kl_vulkan.h"
#include "kl_glibc_sdl.h"
#include "kl_audio.h"
#include <math.h>
#include <time.h>
#include <unistd.h>

static const kl_flatwin_backend *g_be;
void kl_flatwin_set_backend(const kl_flatwin_backend *b) { g_be = b; }
const kl_flatwin_backend *kl_flatwin_backend_now(void) { return g_be; }

// ---- the real SDL, for what stays the guest's -----------------------------------
static void *real(const char *name) {
    // The guest images only: kl_guest_sym_global never consults the shim tier,
    // so this cannot find our own override of the same name.
    void *p = kl_guest_sym_global(name);
    if (!p) fprintf(stderr, "  [sdl] guest SDL has no %s\n", name);
    return p;
}
#define REAL(type, name) ((type)real(name))

// ---- windows ----------------------------------------------------------------------
#define SDL_WINDOW_FULLSCREEN    0x1u
#define SDL_WINDOW_SHOWN         0x4u
#define SDL_WINDOW_HIDDEN        0x8u
#define SDL_WINDOW_INPUT_FOCUS   0x200u
#define SDL_WINDOW_MOUSE_FOCUS   0x400u
#define SDL_WINDOW_VULKAN        0x10000000u
#define SDL_INIT_VIDEO           0x20u
#define SDL_INIT_EVENTS          0x4000u

typedef struct {
    uint32_t magic, id, flags;
    int w, h, pw, ph, x, y;
    char title[256];
    void *be_win, *layer;
} sdlwin;
#define SDLWIN_MAGIC 0x6b6c7377u     // "klsw"
static sdlwin *g_wins[16];
static uint32_t g_next_id = 1;
static int g_video_inited, g_relative, g_text_input;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

static sdlwin *W(void *p) {
    sdlwin *w = p;
    return (w && w->magic == SDLWIN_MAGIC) ? w : NULL;
}
static sdlwin *focus_win(void) {
    for (int i = 0; i < 16; i++) if (g_wins[i]) return g_wins[i];
    return NULL;
}

static void *sdl_CreateWindow(const char *title, int x, int y, int w, int h, uint32_t flags) {
    sdlwin *win = calloc(1, sizeof *win);
    if (!win) return NULL;
    win->magic = SDLWIN_MAGIC;
    win->flags = (flags & ~SDL_WINDOW_HIDDEN) | SDL_WINDOW_SHOWN | SDL_WINDOW_INPUT_FOCUS |
                 SDL_WINDOW_MOUSE_FOCUS;
    // A fullscreen request at the desktop size becomes a window: this is a
    // debugging frontend, and the engine asks for the display's own size.
    int dw = 1280, dh = 720, hz = 60;
    if (g_be && g_be->display) g_be->display(&dw, &dh, &hz);
    if (w <= 0 || h <= 0 || w > dw || h > dh) { w = dw * 3 / 4; h = dh * 3 / 4; }
    win->w = win->pw = w;
    win->h = win->ph = h;
    win->x = x; win->y = y;
    snprintf(win->title, sizeof win->title, "%s", title ? title : "");
    if (g_be && g_be->create)
        win->be_win = g_be->create(win->title, w, h, flags, &win->layer, &win->pw, &win->ph);
    pthread_mutex_lock(&g_mu);
    win->id = g_next_id++;
    for (int i = 0; i < 16; i++) if (!g_wins[i]) { g_wins[i] = win; break; }
    pthread_mutex_unlock(&g_mu);
    fprintf(stderr, "  [sdl] SDL_CreateWindow(\"%s\", %dx%d, flags %#x) -> window %u "
                    "(%s, drawable %dx%d)\n", win->title, w, h, flags, win->id,
            win->layer ? "host window, CAMetalLayer" : "no window: synthetic surface",
            win->pw, win->ph);
    return win;
}
static void sdl_DestroyWindow(void *p) {
    sdlwin *w = W(p);
    if (!w) return;
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < 16; i++) if (g_wins[i] == w) g_wins[i] = NULL;
    pthread_mutex_unlock(&g_mu);
    if (g_be && g_be->destroy && w->be_win) g_be->destroy(w->be_win);
    w->magic = 0;
    free(w);
}
static void sdl_GetWindowSize(void *p, int *w, int *h) {
    sdlwin *s = W(p);
    if (w) *w = s ? s->w : 0;
    if (h) *h = s ? s->h : 0;
}
static void sdl_GetDrawableSize(void *p, int *w, int *h) {
    sdlwin *s = W(p);
    if (w) *w = s ? s->pw : 0;
    if (h) *h = s ? s->ph : 0;
}
static void sdl_SetWindowSize(void *p, int w, int h) {
    sdlwin *s = W(p);
    if (!s || w <= 0 || h <= 0) return;
    if (g_be && g_be->set_size && s->be_win) g_be->set_size(s->be_win, w, h);
}
static void sdl_GetWindowPosition(void *p, int *x, int *y) {
    sdlwin *s = W(p);
    if (x) *x = s ? s->x : 0;
    if (y) *y = s ? s->y : 0;
}
static void sdl_SetWindowPosition(void *p, int x, int y) {
    sdlwin *s = W(p);
    if (s) { s->x = x; s->y = y; }
}
static uint32_t sdl_GetWindowFlags(void *p) { sdlwin *s = W(p); return s ? s->flags : 0; }
static uint32_t sdl_GetWindowID(void *p) { sdlwin *s = W(p); return s ? s->id : 0; }
static void *sdl_GetWindowFromID(uint32_t id) {
    for (int i = 0; i < 16; i++) if (g_wins[i] && g_wins[i]->id == id) return g_wins[i];
    return NULL;
}
static const char *sdl_GetWindowTitle(void *p) { sdlwin *s = W(p); return s ? s->title : ""; }
static void sdl_SetWindowTitle(void *p, const char *t) {
    sdlwin *s = W(p);
    if (!s) return;
    snprintf(s->title, sizeof s->title, "%s", t ? t : "");
    if (g_be && g_be->set_title && s->be_win) g_be->set_title(s->be_win, s->title);
}
static void sdl_ShowWindow(void *p) {
    sdlwin *s = W(p);
    if (s && g_be && g_be->show && s->be_win) g_be->show(s->be_win, 1);
}
static void sdl_HideWindow(void *p) {
    sdlwin *s = W(p);
    if (s && g_be && g_be->show && s->be_win) g_be->show(s->be_win, 0);
}
static void sdl_noop_win(void *p) { (void)p; }
static void sdl_noop_win_i(void *p, int v) { (void)p; (void)v; }
static int  sdl_ret0_win_i(void *p, uint32_t v) { (void)p; (void)v; return 0; }
static int  sdl_ret0_win_p(void *p, const void *v) { (void)p; (void)v; return 0; }
static int  sdl_GetWindowDisplayIndex(void *p) { (void)p; return 0; }
static void *sdl_GetKeyboardFocus(void) { return focus_win(); }
static void *sdl_GetMouseFocus(void) { return focus_win(); }
// SDL_GetWindowWMInfo: no X11 Window or Wayland surface to give. SDL_FALSE is
// the documented answer for "this driver has none", and the Vulkan path does
// not need one — the surface comes from SDL_Vulkan_CreateSurface.
static int sdl_GetWindowWMInfo(void *p, void *info) { (void)p; (void)info; return 0; }

// ---- displays ------------------------------------------------------------------------
typedef struct { uint32_t format; int w, h, refresh_rate; void *driverdata; } sdl_mode;
typedef struct { int x, y, w, h; } sdl_rect;
#define SDL_PIXELFORMAT_ARGB8888 0x16362004u

static void display(int *w, int *h, int *hz) {
    *w = 1920; *h = 1080; *hz = 60;
    if (g_be && g_be->display) g_be->display(w, h, hz);
}
static int sdl_GetNumVideoDisplays(void) { return 1; }
static int sdl_GetNumDisplayModes(int i) { (void)i; return 1; }
static int sdl_mode_fill(sdl_mode *m) {
    int w, h, hz;
    display(&w, &h, &hz);
    if (m) *m = (sdl_mode){ SDL_PIXELFORMAT_ARGB8888, w, h, hz, NULL };
    return 0;
}
static int sdl_GetDisplayMode(int d, int i, sdl_mode *m) { (void)d; (void)i; return sdl_mode_fill(m); }
static int sdl_GetDesktopDisplayMode(int d, sdl_mode *m) { (void)d; return sdl_mode_fill(m); }
static int sdl_GetCurrentDisplayMode(int d, sdl_mode *m) { (void)d; return sdl_mode_fill(m); }
static int sdl_GetWindowDisplayMode(void *p, sdl_mode *m) { (void)p; return sdl_mode_fill(m); }
static int sdl_GetDisplayBounds(int d, sdl_rect *r) {
    (void)d;
    int w, h, hz;
    display(&w, &h, &hz);
    if (r) *r = (sdl_rect){ 0, 0, w, h };
    return 0;
}
static int sdl_GetDisplayDPI(int d, float *dd, float *hd, float *vd) {
    (void)d;
    if (dd) *dd = 110; if (hd) *hd = 110; if (vd) *vd = 110;
    return 0;
}
static const char *sdl_GetDisplayName(int d) { (void)d; return "Klepton host display"; }

// ---- mouse, cursor, keyboard odds and ends ------------------------------------------
// The pointer as the guest's own SDL would know it. Its libSDL2 never sees the
// host's mouse (events are pushed past its video layer, which is what updates
// its mouse state), so the state queries are answered here from the same
// events: SDL_GetMouseState is Panorama's cursor, and the grab, cursor and
// focus answers are what tier0 consults before it re-captures the pointer.
// KL_TRACE_SDL=1 prints every capture-related call.
static int g_grab, g_cursor_shown = 1, g_mx, g_my, g_mbuttons, g_rdx, g_rdy;
#define TRACE_MOUSE(...) do { if (kl_env_on("KL_TRACE_SDL", 0)) fprintf(stderr, "  [sdl] " __VA_ARGS__); } while (0)

static int  sdl_SetRelativeMouseMode(int on) {
    TRACE_MOUSE("SDL_SetRelativeMouseMode(%d) (was %d)\n", on, g_relative);
    g_relative = on;
    g_rdx = g_rdy = 0;
    if (g_be && g_be->set_relative_mouse) g_be->set_relative_mouse(on);
    return 0;
}
static int  sdl_GetRelativeMouseMode(void) { return g_relative; }
static void sdl_SetWindowGrab(void *p, int on) {
    TRACE_MOUSE("SDL_SetWindowGrab(%p, %d)\n", p, on);
    g_grab = on;
    if (g_be && g_be->set_grab) g_be->set_grab(on);
}
static int  sdl_GetWindowGrab(void *p) { (void)p; return g_grab; }
static void sdl_SetWindowKeyboardGrab(void *p, int on) { (void)p; (void)on; }
static void *sdl_GetGrabbedWindow(void) { return (g_grab || g_relative) ? focus_win() : NULL; }
static void sdl_WarpMouseInWindow(void *p, int x, int y) {
    static int said;
    if (!said++) TRACE_MOUSE("SDL_WarpMouseInWindow(%p, %d, %d) (first; not traced again)\n", p, x, y);
    g_mx = x; g_my = y;
    if (g_be && g_be->warp) g_be->warp(x, y);
}
static int  sdl_WarpMouseGlobal(int x, int y) { sdl_WarpMouseInWindow(focus_win(), x, y); return 0; }
static int  sdl_ShowCursor(int t) {
    if (t >= 0 && t != g_cursor_shown) {
        TRACE_MOUSE("SDL_ShowCursor(%d)\n", t);
        g_cursor_shown = !!t;
        if (g_be && g_be->show_cursor) g_be->show_cursor(g_cursor_shown);
    }
    return g_cursor_shown;
}
static int  sdl_CaptureMouse(int on) { TRACE_MOUSE("SDL_CaptureMouse(%d)\n", on); return 0; }
static uint32_t sdl_GetMouseState(int *x, int *y) {
    if (x) *x = g_mx;
    if (y) *y = g_my;
    return (uint32_t)g_mbuttons;
}
static uint32_t sdl_GetRelativeMouseState(int *x, int *y) {
    if (x) *x = g_rdx;
    if (y) *y = g_rdy;
    g_rdx = g_rdy = 0;
    return (uint32_t)g_mbuttons;
}
static int  g_cursor_tok;
static void *sdl_CreateCursor_any(void) { return &g_cursor_tok; }
static void *sdl_CreateCursor(const void *a, const void *b, int w, int h, int x, int y) {
    (void)a; (void)b; (void)w; (void)h; (void)x; (void)y; return &g_cursor_tok;
}
static void *sdl_CreateColorCursor(void *s, int x, int y) { (void)s; (void)x; (void)y; return &g_cursor_tok; }
static void *sdl_CreateSystemCursor(int id) { (void)id; return &g_cursor_tok; }
static void sdl_SetCursor(void *c) { (void)c; }
static void sdl_FreeCursor(void *c) { (void)c; }
static char *sdl_GetClipboardText(void) { return strdup(""); }
static int  sdl_HasClipboardText(void) { return 0; }
static int  sdl_SetClipboardText(const char *t) { (void)t; return 0; }
static void sdl_StartTextInput(void) { g_text_input = 1; }
static void sdl_StopTextInput(void) { g_text_input = 0; }
static int  sdl_IsTextInputActive(void) { return g_text_input; }
static void sdl_SetTextInputRect(const void *r) { (void)r; }
static int  sdl_ret0(void) { return 0; }
static void sdl_void(void) {}
static int  sdl_IsScreenSaverEnabled(void) { return 0; }
static int  sdl_GL_SetAttribute(int a, int v) { (void)a; (void)v; return 0; }

// ---- init: VIDEO is ours ----------------------------------------------------------------
#define SDL_INIT_AUDIO           0x10u
static int g_audio_inited;
static int sdl_InitSubSystem(uint32_t flags) {
    if (flags & SDL_INIT_VIDEO) g_video_inited = 1;
    if (flags & SDL_INIT_AUDIO) {
        fprintf(stderr, "  [sdl-au] SDL_InitSubSystem(AUDIO) (was %s)\n", g_audio_inited ? "up" : "down");
        g_audio_inited = 1;
    }
    uint32_t rest = flags & ~(SDL_INIT_VIDEO | SDL_INIT_AUDIO);
    if (flags & SDL_INIT_VIDEO) rest |= SDL_INIT_EVENTS;
    if (!rest) return 0;
    int (*r)(uint32_t) = REAL(int (*)(uint32_t), "SDL_InitSubSystem");
    return r ? r(rest) : 0;
}
static int sdl_Init(uint32_t flags) { return sdl_InitSubSystem(flags); }
static void sdl_audio_quit(const char *who);
static void sdl_QuitSubSystem(uint32_t flags) {
    if (flags & SDL_INIT_VIDEO) g_video_inited = 0;
    if (flags & SDL_INIT_AUDIO) sdl_audio_quit("SDL_QuitSubSystem(AUDIO)");
    uint32_t rest = flags & ~(SDL_INIT_VIDEO | SDL_INIT_AUDIO);
    void (*r)(uint32_t) = REAL(void (*)(uint32_t), "SDL_QuitSubSystem");
    if (r && rest) r(rest);
}
static uint32_t sdl_WasInit(uint32_t flags) {
    uint32_t (*r)(uint32_t) = REAL(uint32_t (*)(uint32_t), "SDL_WasInit");
    uint32_t v = r ? r(flags) : 0;
    if (g_video_inited) v |= SDL_INIT_VIDEO & (flags ? flags : ~0u);
    if (g_audio_inited) v |= SDL_INIT_AUDIO & (flags ? flags : ~0u);
    return v;
}

// ---- audio -------------------------------------------------------------------------------
// One playback device, fed into kl_audio (CoreAudio; the same sink the OpenSL
// and AAudio guests use). Source 2's tier0 opens it in QUEUE mode — no callback,
// SDL_QueueAudio from its mixer, SDL_GetQueuedAudioSize to pace itself — but the
// callback mode is served too. A feeder thread drains one period at a time into
// kl_audio_write, which blocks for the period's duration: that is the device
// clock, exactly as for the other guests. An empty queue plays silence, which is
// what SDL does. Whatever the guest's format (s16, s32 or float; 1-8 channels),
// it is converted to s16 stereo here, surround folded down; kl_audio resamples
// 44.1 kHz to the hardware rate.
//
// SDL2's SDL_AudioSpec: freq int @0, format u16 @4, channels u8 @6, silence u8
// @7, samples u16 @8, size u32 @12, callback @16, userdata @24.
typedef struct {
    int freq; uint16_t format; uint8_t channels, silence; uint16_t samples, padding;
    uint32_t size; void (*callback)(void *, uint8_t *, int); void *userdata;
} sdl_audiospec;
_Static_assert(sizeof(sdl_audiospec) == 32, "SDL2 SDL_AudioSpec");
#define AUDIO_S16LSB 0x8010u
#define AUDIO_S32LSB 0x8020u
#define AUDIO_F32LSB 0x8120u
// Device ids: every successful open gets a NEW id (2, 3, ...), as SDL does,
// and only the current one is honoured. A stale id (a device the engine closed,
// or one we replaced) is a no-op rather than an alias of whatever is open now.
#define AUDIO_DEV_FIRST 2u

static struct {
    int open, paused, quit;
    uint32_t id;                      // the open device's id
    sdl_audiospec spec;
    pthread_t th;
    pthread_mutex_t mu;               // the queue, and SDL_LockAudioDevice
    uint8_t *q; size_t qcap, qhead, qlen;
    unsigned long long periods, starved;
    // The 5-second window the feeder reports (KL_SDL_AUDIO_STATS, default on):
    // bytes the guest queued (under mu), and what the feeder played.
    unsigned long long w_in, w_periods, w_starved, w_queues, w_clears;
    unsigned long long w_frames, w_nonfinite;   // frames converted / with a NaN or Inf in them
    int w_peak;
} g_au = { .mu = PTHREAD_MUTEX_INITIALIZER };
static uint32_t g_au_next_id = AUDIO_DEV_FIRST;
static int au_dev(uint32_t dev) { return g_au.open && dev == g_au.id; }

static int au_frame_bytes(void) { return (g_au.spec.format & 0xff) / 8 * g_au.spec.channels; }
static float au_sample(const uint8_t *p, int i) {
    switch (g_au.spec.format) {
    case AUDIO_F32LSB: { float f; memcpy(&f, p + 4 * i, 4); return f; }
    case AUDIO_S32LSB: { int32_t v; memcpy(&v, p + 4 * i, 4); return (float)v / 2147483648.0f; }
    default:           { int16_t v; memcpy(&v, p + 2 * i, 2); return (float)v / 32768.0f; }
    }
}
// n frames of guest audio -> n s16 stereo frames. Surround folds to stereo with
// the usual -3 dB centre and surrounds (SDL's channel orders: 4 = FL FR BL BR,
// 6 = FL FR C LFE SL SR, 8 = FL FR C LFE BL BR SL SR); LFE is dropped.
static void au_convert(const uint8_t *in, int n, int16_t *out) {
    int ch = g_au.spec.channels;
    const float k = 0.7071f;
    for (int f = 0; f < n; f++) {
        const uint8_t *fr = in + (size_t)f * au_frame_bytes();
        float l, r;
        switch (ch) {
        case 1:  l = r = au_sample(fr, 0); break;
        case 2:  l = au_sample(fr, 0); r = au_sample(fr, 1); break;
        case 4:  l = au_sample(fr, 0) + k * au_sample(fr, 2); r = au_sample(fr, 1) + k * au_sample(fr, 3); break;
        case 6:  l = au_sample(fr, 0) + k * (au_sample(fr, 2) + au_sample(fr, 4));
                 r = au_sample(fr, 1) + k * (au_sample(fr, 2) + au_sample(fr, 5)); break;
        case 8:  l = au_sample(fr, 0) + k * (au_sample(fr, 2) + au_sample(fr, 4) + au_sample(fr, 6));
                 r = au_sample(fr, 1) + k * (au_sample(fr, 2) + au_sample(fr, 5) + au_sample(fr, 7)); break;
        default: l = au_sample(fr, 0); r = ch > 1 ? au_sample(fr, 1) : l; break;
        }
        // A NaN converts to 0 below (lrintf of NaN is 0 here), so a mix poisoned
        // by one bad source reads as exact SILENCE in the peak — counted apart,
        // because "the guest mixed nothing" and "the guest mixed NaN" are
        // different bugs (the second: a DSP stage, e.g. Steam Audio, emitting it).
        if (!isfinite(l) || !isfinite(r)) g_au.w_nonfinite++;
        if (ch > 2) { l *= 0.6f; r *= 0.6f; }           // headroom for the fold-down
        l = l > 1.0f ? 1.0f : l < -1.0f ? -1.0f : l;
        r = r > 1.0f ? 1.0f : r < -1.0f ? -1.0f : r;
        out[2 * f] = (int16_t)lrintf(l * 32767.0f);
        out[2 * f + 1] = (int16_t)lrintf(r * 32767.0f);
    }
}
static double au_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec * 1e-9;
}
// One line per 5 s while a device is open: is the guest still feeding us, and
// is what it feeds silent? The sink's own "guest PCM so far" peak is cumulative
// over the process, so a menu that played audio hides a game that went silent;
// this one is per window.
static void au_stats_maybe(double *t0) {
    double t = au_now();
    if (t - *t0 < 5.0) return;
    *t0 = t;
    pthread_mutex_lock(&g_au.mu);
    unsigned long long in = g_au.w_in, nq = g_au.w_queues, ncl = g_au.w_clears;
    size_t qlen = g_au.qlen;
    g_au.w_in = g_au.w_queues = g_au.w_clears = 0;
    pthread_mutex_unlock(&g_au.mu);
    char nf[96] = "";
    if (g_au.w_nonfinite)
        snprintf(nf, sizeof nf, ", NON-FINITE %llu of %llu frames (NaN/Inf in the guest's mix)",
                 g_au.w_nonfinite, g_au.w_frames);
    fprintf(stderr, "  [sdl-au] dev %u 5s: %s, %llu periods (%llu short), %s %llu KB in %llu calls, "
                    "queue now %zu B, %llu clears, PCM peak %d/32767%s%s\n",
            g_au.id, g_au.paused ? "PAUSED" : "playing", g_au.w_periods, g_au.w_starved,
            g_au.spec.callback ? "callback" : "queued", in >> 10, nq, qlen, ncl, g_au.w_peak, nf,
            g_au.paused ? "" : g_au.w_peak ? "" : " — SILENT");
    g_au.w_periods = g_au.w_starved = 0;
    g_au.w_frames = g_au.w_nonfinite = 0;
    g_au.w_peak = 0;
}
static void *au_feeder(void *arg) {
    (void)arg;
    if (g_au.spec.callback) kl_thread_init();         // the guest's callback runs here
    size_t period = (size_t)g_au.spec.samples * au_frame_bytes();
    uint8_t *buf = malloc(period);
    int16_t *out = malloc((size_t)g_au.spec.samples * 4);
    int stats = kl_env_on("KL_SDL_AUDIO_STATS", 1);
    double t0 = au_now();
    while (!g_au.quit) {
        if (stats) au_stats_maybe(&t0);
        if (g_au.paused) { usleep(5000); continue; }
        if (g_au.spec.callback) {
            memset(buf, g_au.spec.silence, period);
            pthread_mutex_lock(&g_au.mu);
            g_au.spec.callback(g_au.spec.userdata, buf, (int)period);
            pthread_mutex_unlock(&g_au.mu);
        } else {
            pthread_mutex_lock(&g_au.mu);
            size_t take = g_au.qlen < period ? g_au.qlen : period;
            for (size_t i = 0; i < take; i++) buf[i] = g_au.q[(g_au.qhead + i) % g_au.qcap];
            g_au.qhead = g_au.qcap ? (g_au.qhead + take) % g_au.qcap : 0;
            g_au.qlen -= take;
            pthread_mutex_unlock(&g_au.mu);
            if (take < period) {
                memset(buf + take, g_au.spec.silence, period - take);
                g_au.starved++; g_au.w_starved++;
            }
        }
        au_convert(buf, g_au.spec.samples, out);
        g_au.w_frames += g_au.spec.samples;
        for (int i = 0; i < g_au.spec.samples * 2; i++) {
            int v = out[i] < 0 ? -out[i] : out[i];
            if (v > g_au.w_peak) g_au.w_peak = v;
        }
        g_au.periods++; g_au.w_periods++;
        if (kl_audio_write(out, (size_t)g_au.spec.samples * 4) == 0) usleep(5000);
    }
    free(buf); free(out);
    return NULL;
}
static void au_close(const char *who) {
    if (!g_au.open) return;
    g_au.quit = 1;
    pthread_join(g_au.th, NULL);
    kl_audio_close();
    g_au.open = 0;
    pthread_mutex_lock(&g_au.mu);
    g_au.qhead = g_au.qlen = 0;
    pthread_mutex_unlock(&g_au.mu);
    fprintf(stderr, "  [sdl-au] %s: device %u closed, %llu periods played, %llu of them short\n",
            who, g_au.id, g_au.periods, g_au.starved);
}
static void sdl_audio_quit(const char *who) {
    // SDL_QuitSubSystem(AUDIO) / SDL_AudioQuit close every open device in real
    // SDL. Leaving ours open made the NEXT open (after SDL_InitSubSystem(AUDIO))
    // refuse with "one device", and the engine would have run mute from there.
    fprintf(stderr, "  [sdl-au] %s (device %s)\n", who, g_au.open ? "open: closing it" : "none open");
    au_close(who);
    g_audio_inited = 0;
}
static uint32_t sdl_OpenAudioDevice(const char *name, int capture, const sdl_audiospec *want,
                                    sdl_audiospec *have, int allowed) {
    if (capture || !want) {
        fprintf(stderr, "  [sdl] SDL_OpenAudioDevice(capture %d): no capture device\n", capture);
        return 0;
    }
    fprintf(stderr, "  [sdl-au] SDL_OpenAudioDevice(\"%s\", want %d Hz, format %#x, %u ch, %u frames, "
                    "%s, allowed %#x)%s\n",
            name ? name : "default", want->freq, want->format, want->channels, want->samples,
            want->callback ? "callback" : "queue", allowed,
            g_au.open ? " — a device is ALREADY open" : "");
    // One sink, so one device. A second open with the first still open used to
    // be refused (0) — silently, and for the rest of the run if the engine
    // reopens on a map change without closing. The newest open wins instead:
    // the old one is closed (its id goes stale) and this one plays.
    if (g_au.open) au_close("replaced by a new SDL_OpenAudioDevice");
    sdl_audiospec s = *want;
    if (s.format != AUDIO_S16LSB && s.format != AUDIO_S32LSB && s.format != AUDIO_F32LSB)
        s.format = AUDIO_F32LSB;
    if (s.channels < 1 || s.channels > 8) s.channels = 2;
    if (s.freq <= 0) s.freq = 48000;
    if (!s.samples) s.samples = 1024;
    s.silence = 0;
    s.size = (uint32_t)s.samples * ((s.format & 0xff) / 8) * s.channels;
    if (have) *have = s;
    if (kl_audio_open((unsigned)s.freq, 2, 16) != 0) {
        fprintf(stderr, "  [sdl] SDL_OpenAudioDevice: the host audio device did not open\n");
        return 0;
    }
    g_au.spec = s;
    g_au.id = g_au_next_id++;
    g_au.paused = 1; g_au.quit = 0;
    pthread_mutex_lock(&g_au.mu);
    g_au.qhead = g_au.qlen = 0;
    g_au.w_in = g_au.w_queues = g_au.w_clears = 0;
    pthread_mutex_unlock(&g_au.mu);
    g_au.periods = g_au.starved = g_au.w_periods = g_au.w_starved = 0;
    g_au.w_peak = 0;
    g_au.open = 1;
    pthread_create(&g_au.th, NULL, au_feeder, NULL);
    fprintf(stderr, "  [sdl] SDL_OpenAudioDevice(\"%s\") -> %u: %d Hz, format %#x, %u channel(s), "
                    "%u-frame periods, %s mode -> s16 stereo into the host sink\n",
            name ? name : "default", g_au.id, s.freq, s.format, s.channels, s.samples,
            s.callback ? "callback" : "queue");
    return g_au.id;
}
static void sdl_PauseAudioDevice(uint32_t dev, int pause) {
    if (!au_dev(dev)) {
        fprintf(stderr, "  [sdl-au] SDL_PauseAudioDevice(%u, %d) on a device that is not open "
                        "(open: %u) — ignored\n", dev, pause, g_au.open ? g_au.id : 0);
        return;
    }
    if ((pause != 0) != g_au.paused)
        fprintf(stderr, "  [sdl-au] device %u %s\n", dev, pause ? "PAUSED" : "playing");
    g_au.paused = pause != 0;
    if (pause) kl_audio_pause(); else kl_audio_play();
}
static int sdl_QueueAudio(uint32_t dev, const void *data, uint32_t len) {
    if (!au_dev(dev) || g_au.spec.callback) {
        static int said;
        if (said++ < 5)
            fprintf(stderr, "  [sdl-au] SDL_QueueAudio(%u, %u B) refused: %s\n", dev, len,
                    !g_au.open ? "no device open" : dev != g_au.id ? "stale device id"
                                                                    : "device is in callback mode");
        return -1;
    }
    pthread_mutex_lock(&g_au.mu);
    if (g_au.qlen + len > g_au.qcap) {                // grow, unrolling the ring
        size_t ncap = (g_au.qlen + len) * 2;
        uint8_t *nq = malloc(ncap);
        for (size_t i = 0; i < g_au.qlen; i++) nq[i] = g_au.q[(g_au.qhead + i) % g_au.qcap];
        free(g_au.q);
        g_au.q = nq; g_au.qcap = ncap; g_au.qhead = 0;
    }
    for (uint32_t i = 0; i < len; i++)
        g_au.q[(g_au.qhead + g_au.qlen + i) % g_au.qcap] = ((const uint8_t *)data)[i];
    g_au.qlen += len;
    g_au.w_in += len; g_au.w_queues++;
    pthread_mutex_unlock(&g_au.mu);
    return 0;
}
static uint32_t sdl_GetQueuedAudioSize(uint32_t dev) {
    if (!au_dev(dev)) return 0;
    pthread_mutex_lock(&g_au.mu);
    uint32_t n = (uint32_t)g_au.qlen;
    pthread_mutex_unlock(&g_au.mu);
    return n;
}
static void sdl_ClearQueuedAudio(uint32_t dev) {
    if (!au_dev(dev)) return;
    pthread_mutex_lock(&g_au.mu);
    g_au.qhead = g_au.qlen = 0;
    g_au.w_clears++;
    pthread_mutex_unlock(&g_au.mu);
}
static void sdl_CloseAudioDevice(uint32_t dev) {
    if (!au_dev(dev)) {
        fprintf(stderr, "  [sdl-au] SDL_CloseAudioDevice(%u): not the open device (%u) — ignored\n",
                dev, g_au.open ? g_au.id : 0);
        return;
    }
    au_close("SDL_CloseAudioDevice");
}
static void sdl_LockAudioDevice(uint32_t dev)   { if (au_dev(dev)) pthread_mutex_lock(&g_au.mu); }
static void sdl_UnlockAudioDevice(uint32_t dev) { if (au_dev(dev)) pthread_mutex_unlock(&g_au.mu); }
static int  sdl_GetAudioDeviceStatus(uint32_t dev) {   // 0 stopped, 1 playing, 2 paused
    return au_dev(dev) ? (g_au.paused ? 2 : 1) : 0;
}
// The legacy (SDL 1.2-style) entry points address "the" device: whichever is open.
static int  sdl_OpenAudio(const sdl_audiospec *want, sdl_audiospec *have) {
    sdl_audiospec tmp;
    return sdl_OpenAudioDevice(NULL, 0, want, have ? have : &tmp, 0) ? 0 : -1;
}
static void sdl_PauseAudio(int pause) { if (g_au.open) sdl_PauseAudioDevice(g_au.id, pause); }
static void sdl_CloseAudio(void)      { if (g_au.open) sdl_CloseAudioDevice(g_au.id); }
static void sdl_LockAudio(void)       { if (g_au.open) sdl_LockAudioDevice(g_au.id); }
static void sdl_UnlockAudio(void)     { if (g_au.open) sdl_UnlockAudioDevice(g_au.id); }
static int  sdl_GetNumAudioDevices(int capture) { return capture ? 0 : 1; }
static const char *sdl_GetAudioDeviceName(int i, int capture) {
    return !capture && i == 0 ? "Klepton audio" : NULL;
}
static int  sdl_GetNumAudioDrivers(void) { return 1; }
static const char *sdl_GetAudioDriver(int i) { return i == 0 ? "klepton" : NULL; }
static const char *sdl_GetCurrentAudioDriver(void) { return g_audio_inited ? "klepton" : NULL; }
static int  sdl_AudioInit(const char *d) {
    fprintf(stderr, "  [sdl-au] SDL_AudioInit(%s)\n", d ? d : "NULL");
    g_audio_inited = 1;
    return 0;
}
static void sdl_AudioQuit(void) { sdl_audio_quit("SDL_AudioQuit"); }

// ---- Vulkan ------------------------------------------------------------------------------
typedef struct { uint32_t sType; const void *pNext; uint32_t flags; const void *pLayer; } metal_surface_ci;
typedef struct { uint32_t sType; const void *pNext; uint32_t flags; void *window; } android_surface_ci;
#define VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT   1000217000u
#define VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR 1000008000u
typedef void *(*gipa_fn)(void *inst, const char *name);
typedef int (*create_surface_fn)(void *inst, const void *ci, const void *alloc, uint64_t *out);

static int sdl_Vulkan_LoadLibrary(const char *path) {
    if (kl_env_on("KL_TRACE_SDL", 0))
        fprintf(stderr, "  [sdl] SDL_Vulkan_LoadLibrary(%s) -> 0\n", path ? path : "NULL");
    return 0;
}
static void sdl_Vulkan_UnloadLibrary(void) {}
static void *sdl_Vulkan_GetVkGetInstanceProcAddr(void) { return kl_vulkan_sym("vkGetInstanceProcAddr"); }

static int window_has_layer(void *p) {
    sdlwin *s = W(p);
    if (s) return s->layer != NULL;
    return g_be && g_be->create;          // no window yet: what one would have
}
static int sdl_Vulkan_GetInstanceExtensions(void *p, unsigned *count, const char **names) {
    const char *ext[2] = { "VK_KHR_surface",
                           window_has_layer(p) ? "VK_EXT_metal_surface" : "VK_KHR_android_surface" };
    if (kl_env_on("KL_TRACE_SDL", 0))
        fprintf(stderr, "  [sdl] SDL_Vulkan_GetInstanceExtensions(%p, %u, %p) -> %s, %s\n",
                p, count ? *count : 0, (void *)names, ext[0], ext[1]);
    if (!count) return 0;
    if (!names) { *count = 2; return 1; }
    if (*count < 2) return 0;
    names[0] = ext[0]; names[1] = ext[1];
    *count = 2;
    return 1;
}
static int sdl_Vulkan_CreateSurface(void *p, void *instance, uint64_t *surface) {
    sdlwin *s = W(p);
    gipa_fn gipa = (gipa_fn)kl_vulkan_sym("vkGetInstanceProcAddr");
    if (!gipa || !surface) return 0;
    int r;
    if (s && s->layer) {
        create_surface_fn f = (create_surface_fn)gipa(instance, "vkCreateMetalSurfaceEXT");
        metal_surface_ci ci = { VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT, NULL, 0, s->layer };
        r = f ? f(instance, &ci, NULL, surface) : -1;
        fprintf(stderr, "  [sdl] SDL_Vulkan_CreateSurface: vkCreateMetalSurfaceEXT -> %d\n", r);
    } else {
        create_surface_fn f = (create_surface_fn)gipa(instance, "vkCreateAndroidSurfaceKHR");
        android_surface_ci ci = { VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR, NULL, 0, NULL };
        r = f ? f(instance, &ci, NULL, surface) : -1;
        fprintf(stderr, "  [sdl] SDL_Vulkan_CreateSurface: synthetic surface -> %d\n", r);
    }
    return r == 0;
}

// ---- events: host input into the guest's own queue ------------------------------------------
// SDL2's SDL_Event, the members used here (offsets per SDL_events.h, 2.x).
#define SDL_QUIT_           0x100u
#define SDL_WINDOWEVENT_    0x200u
#define SDL_KEYDOWN_        0x300u
#define SDL_KEYUP_          0x301u
#define SDL_TEXTINPUT_      0x303u
#define SDL_MOUSEMOTION_    0x400u
#define SDL_MOUSEBUTTONDOWN_ 0x401u
#define SDL_MOUSEBUTTONUP_  0x402u
#define SDL_MOUSEWHEEL_     0x403u
typedef union { uint8_t b[56]; uint32_t u[14]; } sdl_event;

static void put_u32(sdl_event *e, int off, uint32_t v) { memcpy(e->b + off, &v, 4); }
static void put_i32(sdl_event *e, int off, int32_t v)  { memcpy(e->b + off, &v, 4); }
static void put_f32(sdl_event *e, int off, float v)    { memcpy(e->b + off, &v, 4); }

static int translate(const kl_fw_event *f, sdl_event *e) {
    memset(e, 0, sizeof *e);
    sdlwin *w = focus_win();
    uint32_t wid = w ? w->id : 1;
    switch (f->kind) {
    case KL_FW_QUIT:
        put_u32(e, 0, SDL_QUIT_); return 1;
    case KL_FW_CLOSE:
        put_u32(e, 0, SDL_WINDOWEVENT_); put_u32(e, 8, wid); e->b[12] = 14; return 1;
    case KL_FW_FOCUS:
        TRACE_MOUSE("focus %s\n", f->down ? "gained" : "lost");
        if (w) w->flags = f->down ? (w->flags | SDL_WINDOW_INPUT_FOCUS)
                                  : (w->flags & ~SDL_WINDOW_INPUT_FOCUS);
        put_u32(e, 0, SDL_WINDOWEVENT_); put_u32(e, 8, wid); e->b[12] = f->down ? 12 : 13;
        return 1;
    case KL_FW_ENTER:
        if (w) w->flags = f->down ? (w->flags | SDL_WINDOW_MOUSE_FOCUS)
                                  : (w->flags & ~SDL_WINDOW_MOUSE_FOCUS);
        put_u32(e, 0, SDL_WINDOWEVENT_); put_u32(e, 8, wid); e->b[12] = f->down ? 10 : 11;
        return 1;
    case KL_FW_RESIZED:
        if (w) { w->w = f->x; w->h = f->y; w->pw = f->dx; w->ph = f->dy; }
        put_u32(e, 0, SDL_WINDOWEVENT_); put_u32(e, 8, wid); e->b[12] = 6;   // SIZE_CHANGED
        put_i32(e, 16, f->x); put_i32(e, 20, f->y);
        return 1;
    case KL_FW_KEY:
        put_u32(e, 0, f->down ? SDL_KEYDOWN_ : SDL_KEYUP_); put_u32(e, 8, wid);
        e->b[12] = f->down ? 1 : 0; e->b[13] = (uint8_t)f->repeat;
        put_i32(e, 16, f->scancode); put_i32(e, 20, f->keycode);
        { uint16_t m = (uint16_t)f->mod; memcpy(e->b + 24, &m, 2); }
        return 1;
    case KL_FW_TEXT:
        put_u32(e, 0, SDL_TEXTINPUT_); put_u32(e, 8, wid);
        memcpy(e->b + 12, f->text, 31);
        return 1;
    case KL_FW_MOTION:
        g_mx = f->x; g_my = f->y; g_mbuttons = f->buttons;
        g_rdx += f->dx; g_rdy += f->dy;
        put_u32(e, 0, SDL_MOUSEMOTION_); put_u32(e, 8, wid);
        put_u32(e, 16, (uint32_t)f->buttons);
        put_i32(e, 20, f->x); put_i32(e, 24, f->y);
        put_i32(e, 28, f->dx); put_i32(e, 32, f->dy);
        return 1;
    case KL_FW_BUTTON:
        if (f->down) TRACE_MOUSE("button %d down at %d,%d (relative %d, grab %d)\n",
                                 f->button, f->x, f->y, g_relative, g_grab);
        if (f->button > 0 && f->button <= 32) {
            uint32_t bit = 1u << (f->button - 1);
            g_mbuttons = f->down ? (int)((uint32_t)g_mbuttons | bit) : (int)((uint32_t)g_mbuttons & ~bit);
        }
        g_mx = f->x; g_my = f->y;
        put_u32(e, 0, f->down ? SDL_MOUSEBUTTONDOWN_ : SDL_MOUSEBUTTONUP_); put_u32(e, 8, wid);
        e->b[16] = (uint8_t)f->button; e->b[17] = f->down ? 1 : 0;
        e->b[18] = (uint8_t)(f->clicks ? f->clicks : 1);
        put_i32(e, 20, f->x); put_i32(e, 24, f->y);
        return 1;
    case KL_FW_WHEEL:
        put_u32(e, 0, SDL_MOUSEWHEEL_); put_u32(e, 8, wid);
        put_i32(e, 16, (int32_t)f->fx); put_i32(e, 20, (int32_t)f->fy);
        put_f32(e, 28, f->fx); put_f32(e, 32, f->fy);
        return 1;
    }
    return 0;
}

// Move whatever the backend collected into the guest's queue. Guest thread.
static void drain_host_events(void) {
    if (!g_be || !g_be->poll) return;
    static int (*push)(sdl_event *);
    if (!push) push = REAL(int (*)(sdl_event *), "SDL_PushEvent");
    if (!push) return;
    kl_fw_event f;
    sdl_event e;
    while (g_be->poll(&f))
        if (translate(&f, &e)) push(&e);
}
static void sdl_PumpEvents(void) {
    drain_host_events();
    void (*r)(void) = REAL(void (*)(void), "SDL_PumpEvents");
    if (r) r();
}
static int sdl_PollEvent(sdl_event *e) {
    drain_host_events();
    int (*r)(sdl_event *) = REAL(int (*)(sdl_event *), "SDL_PollEvent");
    return r ? r(e) : 0;
}
static int sdl_WaitEventTimeout(sdl_event *e, int ms) {
    // In slices, so host input that arrives during the wait is delivered.
    int (*r)(sdl_event *, int) = REAL(int (*)(sdl_event *, int), "SDL_WaitEventTimeout");
    if (!r) return 0;
    for (int left = ms; ; ) {
        drain_host_events();
        int slice = (ms < 0 || left > 10) ? 10 : left;
        int got = r(e, slice);
        if (got) return got;
        if (ms >= 0 && (left -= slice) <= 0) return 0;
    }
}
static int sdl_WaitEvent(sdl_event *e) { return sdl_WaitEventTimeout(e, -1); }
static int sdl_PeepEvents(sdl_event *e, int n, int action, uint32_t lo, uint32_t hi) {
    drain_host_events();
    int (*r)(sdl_event *, int, int, uint32_t, uint32_t) =
        REAL(int (*)(sdl_event *, int, int, uint32_t, uint32_t), "SDL_PeepEvents");
    return r ? r(e, n, action, lo, hi) : 0;
}

// ---- the table ----------------------------------------------------------------------------
typedef struct { const char *name; void *fn; } entry;
#define F(n, f) { n, (void *)(f) }
static const entry g_sdl[] = {
    F("SDL_Init", sdl_Init), F("SDL_InitSubSystem", sdl_InitSubSystem),
    F("SDL_OpenAudioDevice", sdl_OpenAudioDevice), F("SDL_PauseAudioDevice", sdl_PauseAudioDevice),
    F("SDL_QueueAudio", sdl_QueueAudio), F("SDL_GetQueuedAudioSize", sdl_GetQueuedAudioSize),
    F("SDL_ClearQueuedAudio", sdl_ClearQueuedAudio), F("SDL_CloseAudioDevice", sdl_CloseAudioDevice),
    F("SDL_LockAudioDevice", sdl_LockAudioDevice), F("SDL_UnlockAudioDevice", sdl_UnlockAudioDevice),
    F("SDL_GetAudioDeviceStatus", sdl_GetAudioDeviceStatus),
    F("SDL_OpenAudio", sdl_OpenAudio), F("SDL_PauseAudio", sdl_PauseAudio), F("SDL_CloseAudio", sdl_CloseAudio),
    F("SDL_LockAudio", sdl_LockAudio), F("SDL_UnlockAudio", sdl_UnlockAudio),
    F("SDL_GetNumAudioDevices", sdl_GetNumAudioDevices), F("SDL_GetAudioDeviceName", sdl_GetAudioDeviceName),
    F("SDL_GetNumAudioDrivers", sdl_GetNumAudioDrivers), F("SDL_GetAudioDriver", sdl_GetAudioDriver),
    F("SDL_GetCurrentAudioDriver", sdl_GetCurrentAudioDriver),
    F("SDL_AudioInit", sdl_AudioInit), F("SDL_AudioQuit", sdl_AudioQuit),
    F("SDL_QuitSubSystem", sdl_QuitSubSystem), F("SDL_WasInit", sdl_WasInit),
    F("SDL_CreateWindow", sdl_CreateWindow), F("SDL_DestroyWindow", sdl_DestroyWindow),
    F("SDL_GetWindowSize", sdl_GetWindowSize), F("SDL_SetWindowSize", sdl_SetWindowSize),
    F("SDL_GetWindowSizeInPixels", sdl_GetDrawableSize),
    F("SDL_Vulkan_GetDrawableSize", sdl_GetDrawableSize),
    F("SDL_GL_GetDrawableSize", sdl_GetDrawableSize),
    F("SDL_GetWindowPosition", sdl_GetWindowPosition), F("SDL_SetWindowPosition", sdl_SetWindowPosition),
    F("SDL_GetWindowFlags", sdl_GetWindowFlags), F("SDL_GetWindowID", sdl_GetWindowID),
    F("SDL_GetWindowFromID", sdl_GetWindowFromID),
    F("SDL_GetWindowTitle", sdl_GetWindowTitle), F("SDL_SetWindowTitle", sdl_SetWindowTitle),
    F("SDL_ShowWindow", sdl_ShowWindow), F("SDL_HideWindow", sdl_HideWindow),
    F("SDL_RaiseWindow", sdl_noop_win), F("SDL_MinimizeWindow", sdl_noop_win),
    F("SDL_MaximizeWindow", sdl_noop_win), F("SDL_RestoreWindow", sdl_noop_win),
    F("SDL_SetWindowFullscreen", sdl_ret0_win_i), F("SDL_SetWindowBordered", sdl_noop_win_i),
    F("SDL_SetWindowResizable", sdl_noop_win_i),
    F("SDL_SetWindowGrab", sdl_SetWindowGrab), F("SDL_GetWindowGrab", sdl_GetWindowGrab),
    F("SDL_SetWindowMouseGrab", sdl_SetWindowGrab), F("SDL_GetWindowMouseGrab", sdl_GetWindowGrab),
    F("SDL_SetWindowKeyboardGrab", sdl_SetWindowKeyboardGrab),
    F("SDL_CaptureMouse", sdl_CaptureMouse), F("SDL_GetMouseState", sdl_GetMouseState),
    F("SDL_GetGlobalMouseState", sdl_GetMouseState),
    F("SDL_GetRelativeMouseState", sdl_GetRelativeMouseState),
    F("SDL_SetWindowIcon", sdl_ret0_win_p), F("SDL_SetWindowGammaRamp", sdl_ret0),
    F("SDL_GetWindowDisplayIndex", sdl_GetWindowDisplayIndex),
    F("SDL_GetWindowDisplayMode", sdl_GetWindowDisplayMode),
    F("SDL_SetWindowDisplayMode", sdl_ret0_win_p),
    F("SDL_GetWindowWMInfo", sdl_GetWindowWMInfo),
    F("SDL_GetKeyboardFocus", sdl_GetKeyboardFocus), F("SDL_GetMouseFocus", sdl_GetMouseFocus),
    F("SDL_GetGrabbedWindow", sdl_GetGrabbedWindow),
    F("SDL_GetNumVideoDisplays", sdl_GetNumVideoDisplays),
    F("SDL_GetNumDisplayModes", sdl_GetNumDisplayModes), F("SDL_GetDisplayMode", sdl_GetDisplayMode),
    F("SDL_GetDesktopDisplayMode", sdl_GetDesktopDisplayMode),
    F("SDL_GetCurrentDisplayMode", sdl_GetCurrentDisplayMode),
    F("SDL_GetDisplayBounds", sdl_GetDisplayBounds), F("SDL_GetDisplayUsableBounds", sdl_GetDisplayBounds),
    F("SDL_GetDisplayDPI", sdl_GetDisplayDPI), F("SDL_GetDisplayName", sdl_GetDisplayName),
    F("SDL_SetRelativeMouseMode", sdl_SetRelativeMouseMode),
    F("SDL_GetRelativeMouseMode", sdl_GetRelativeMouseMode),
    F("SDL_WarpMouseInWindow", sdl_WarpMouseInWindow), F("SDL_WarpMouseGlobal", sdl_WarpMouseGlobal),
    F("SDL_ShowCursor", sdl_ShowCursor), F("SDL_CreateCursor", sdl_CreateCursor),
    F("SDL_CreateColorCursor", sdl_CreateColorCursor), F("SDL_CreateSystemCursor", sdl_CreateSystemCursor),
    F("SDL_SetCursor", sdl_SetCursor), F("SDL_FreeCursor", sdl_FreeCursor),
    F("SDL_GetCursor", sdl_CreateCursor_any), F("SDL_GetDefaultCursor", sdl_CreateCursor_any),
    F("SDL_GetClipboardText", sdl_GetClipboardText), F("SDL_HasClipboardText", sdl_HasClipboardText),
    F("SDL_SetClipboardText", sdl_SetClipboardText),
    F("SDL_StartTextInput", sdl_StartTextInput), F("SDL_StopTextInput", sdl_StopTextInput),
    F("SDL_IsTextInputActive", sdl_IsTextInputActive), F("SDL_SetTextInputRect", sdl_SetTextInputRect),
    F("SDL_HasScreenKeyboardSupport", sdl_ret0), F("SDL_IsScreenKeyboardShown", sdl_ret0),
    F("SDL_DisableScreenSaver", sdl_void), F("SDL_EnableScreenSaver", sdl_void),
    F("SDL_IsScreenSaverEnabled", sdl_IsScreenSaverEnabled),
    F("SDL_GL_SetAttribute", sdl_GL_SetAttribute),
    F("SDL_Vulkan_LoadLibrary", sdl_Vulkan_LoadLibrary),
    F("SDL_Vulkan_UnloadLibrary", sdl_Vulkan_UnloadLibrary),
    F("SDL_Vulkan_GetVkGetInstanceProcAddr", sdl_Vulkan_GetVkGetInstanceProcAddr),
    F("SDL_Vulkan_GetInstanceExtensions", sdl_Vulkan_GetInstanceExtensions),
    F("SDL_Vulkan_CreateSurface", sdl_Vulkan_CreateSurface),
    F("SDL_PumpEvents", sdl_PumpEvents), F("SDL_PollEvent", sdl_PollEvent),
    F("SDL_WaitEvent", sdl_WaitEvent), F("SDL_WaitEventTimeout", sdl_WaitEventTimeout),
    F("SDL_PeepEvents", sdl_PeepEvents),
};

void *kl_glibc_sdl_lookup(const char *name) {
    if (!name || name[0] != 'S' || strncmp(name, "SDL_", 4)) return NULL;
    if (!kl_env_on("KL_GLIBC_SDL_SEAM", 1)) return NULL;
    for (size_t i = 0; i < sizeof g_sdl / sizeof *g_sdl; i++)
        if (!strcmp(g_sdl[i].name, name)) return g_sdl[i].fn;
    return NULL;
}
