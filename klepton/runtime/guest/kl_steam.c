// A Steam client that is not there — see kl_steam.h.
//
// WHICH LAYER
//
// The engine never talks to steamclient.so itself. Every library imports the
// same handful of libsteam_api entry points — SteamInternal_SteamAPI_Init,
// SteamInternal_ContextInit, SteamInternal_FindOrCreateUserInterface /
// ...GameServerInterface, SteamInternal_CreateInterface, the callback
// (un)registration pair and the RunCallbacks pumps — and gets C++ interface
// objects back, which it then calls virtually. So this answers at THAT layer:
// those imports bind here (through the glibc ABI tier, ahead of the guest's own
// libsteam_api), and the objects handed back are ours, with vtables laid out
// slot for slot after the Steamworks SDK headers (kl_steam_vtables.h, generated
// by tools/gen_steam_vtables.py; Itanium ABI, `this` in x0).
//
// Every slot of every interface exists. The ones below are implemented; every
// other one is a named stub that logs "<version>::<method> (#slot)" the first
// few times and returns 0 — which the SDK's own conventions mostly read as
// "no", "none" or k_uAPICallInvalid. An interface version the SDK does not
// describe (SteamAudio001, Valve-private) gets 128 such slots.
//
// WHO WE ARE: the user's REAL Steam account when the Steam bridge answers
// (kl_steam_bridge.h: SteamDepot's SteamBridgeService, through the app on
// visionOS or `steamdepot serve`'s Unix socket on the Mac). SteamAPI_Init asks
// it `hello` for the target's app (546560 Half-Life: Alyx, 2669410 Metro
// Awakening, 617830 SUPERHOT VR; see steam_app_id): the real SteamID and
// persona name are reported everywhere, an app the account does not own fails
// init, stats and achievements are loaded from Steam and StoreStats sends what
// changed, and Steam shows the game as being played until shutdown. With no
// bridge, the old stub: user 76561197960287930 (KL_STEAM_ID), owning the
// target's app and nothing else. Either way: universe public, no overlay.
//
// NETWORKING: Source 2 runs even single player as a client connected to a
// listen server in the same process, over ISteamNetworkingSockets. So that
// interface is real, for the one topology that exists here — loopback: listen
// sockets (IP or P2P virtual port), connects to them, CreateSocketPair, poll
// groups, reliable ordered message delivery (loopback cannot lose anything),
// and connection-status callbacks, delivered both through the
// FnSteamNetConnectionStatusChanged config callbacks (global, per listen
// socket, per connection) and through SteamAPI_RegisterCallback(1221). Both
// the user and the game-server accessors return the SAME sockets object, which
// is what lets the client find the server's listen socket at all.
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>
#include <TargetConditionals.h>
#include <stdatomic.h>

#include "klepton.h"
#include "kl_env.h"
#include "kl_driver.h"
#include "kl_jni.h"
#include "kl_steam.h"
#include "kl_steam_bridge.h"
#include "kl_json.h"

// WHICH APP, WHICH USER. Both used to be constants, because Alyx was the only
// guest; the Steam Frame's Android builds (Metro Awakening, UE5; SUPERHOT VR,
// Unity + Steamworks.NET) link libsteam_api.so too, and the same stand-in serves
// them — the flat entry points
// and the C++ interface ABI are AAPCS64 + Itanium on both doors, so nothing
// here is glibc-specific except where the lookup is installed (kl_shim.c's
// Steamworks tier is the Android half). The app is the TARGET's: a stub that
// says "you own 546560" to Metro answers BIsSubscribedApp(2669410) with no.
//
//   KL_STEAM_APPID  override the app id (default: the target's, below)
//   KL_STEAM_ID     OVERRIDE the 64-bit SteamID reported (default: the real
//                   account's from the bridge; with no bridge, a fixed fake one)
//   KL_STEAM_NAME   OVERRIDE the persona name (default: the real one; with no
//                   bridge, "Gordon")
//
// The stub's SteamID is deliberately fake rather than read from anywhere: with
// no bridge there is no account to read it from.
static const struct { const char *target; uint32_t app; } g_apps[] = {
    { "alyx",  546560u  },     // Half-Life: Alyx (Linux arm64 depot 546564)
    { "metro", 2669410u },     // Metro Awakening (Android depot 2669412)
    { "superhot", 617830u },   // SUPERHOT VR (Steam Frame Android depot 617833)
};
static uint32_t steam_app_id(void) {
    static uint32_t app;
    if (app) return app;
    const char *e = getenv("KL_STEAM_APPID");
    if (e && *e) return app = (uint32_t)strtoul(e, NULL, 10);
    const char *t = kl_driver_target_name();
    for (size_t i = 0; i < sizeof g_apps / sizeof *g_apps; i++)
        if (t && !strcmp(t, g_apps[i].target)) return app = g_apps[i].app;
    return app = 546560u;
}
// The account the bridge answered `hello` for. `real` is set once, inside
// SteamAPI_Init, before the guest can ask who it is.
static struct {
    int real;                 // the bridge answered: everything below is the account's
    int owned, offline;       // offline: the service answered from its cache
    uint64_t steamid;
    char name[128];
} g_acct;

static uint64_t steam_user_id(void) {
    static uint64_t env_id;
    static int env_read;
    if (!env_read) {
        const char *e = getenv("KL_STEAM_ID");
        env_id = (e && *e) ? strtoull(e, NULL, 10) : 0;
        env_read = 1;
    }
    if (env_id) return env_id;
    if (g_acct.real && g_acct.steamid) return g_acct.steamid;
    return 76561197960287930ull;
}
static const char *steam_persona(void) {
    const char *e = getenv("KL_STEAM_NAME");
    if (e && *e) return e;
    if (g_acct.real && g_acct.name[0]) return g_acct.name;
    return "Gordon";
}
#define APP_ID      steam_app_id()
#define USER_ID     steam_user_id()
#define SERVER_ID   90071992547409921ull

// ---- interface objects ---------------------------------------------------------------
typedef struct { const char *ver, *cls; const char *const *slots; } iface_desc;
#define KL_STEAM_IFACE(ver, cls, ...) { ver, cls, (const char *const[]){ __VA_ARGS__, NULL } },
static const iface_desc g_desc[] = {
#include "kl_steam_vtables.h"
};
#undef KL_STEAM_IFACE

// vt first: it is a C++ object. `desc` is the row it was built from (NULL for a
// version no SDK here describes), which the FLAT API needs: a flat call names
// a class and a method, and only the object knows which version's slot order
// it was laid out in.
typedef struct { void **vt; const char *ver; const iface_desc *desc; } sobj;
static sobj *g_objs[64];
static int g_nobjs;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

typedef struct { const char *ver, *method; int nth; void *fn; } impl;
static sobj *iface(const char *ver);

// ---- the flat entry points -------------------------------------------------------------
static void stats_received(void);
static int  account_init(char *err, size_t n);
// SteamAPI_Init's verdict, reached once: 0 = not yet, 1 = OK, -rc = failed with
// that ESteamAPIInitResult (1 FailedGeneric: not owned; 2 NoSteamClient: the
// bridge is required and did not answer).
/* A SteamID for the log: its first two digits + "•••" (logs end up in bug reports). One
 * static buffer per call site is enough: each log line formats at most one. */
static const char *kl_mask_sid(uint64_t sid) {
    static __thread char buf[24];
    char full[24]; snprintf(full, sizeof full, "%llu", (unsigned long long)sid);
    snprintf(buf, sizeof buf, "%.2s\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2", full);
    return buf;
}
static int g_init_state;
static char g_init_err[256];
static pthread_mutex_t g_initmu = PTHREAD_MUTEX_INITIALIZER;
static int  st_init(const char *versions, void *err) {
    (void)versions;
    if (err) memset(err, 0, 1024);                // SteamErrMsg
    pthread_mutex_lock(&g_initmu);
    if (!g_init_state) {
        int rc = account_init(g_init_err, sizeof g_init_err);
        g_init_state = rc ? -rc : 1;
    }
    int state = g_init_state;
    pthread_mutex_unlock(&g_initmu);
    if (state < 0) {
        if (err) snprintf(err, 1024, "%s", g_init_err);
        fprintf(stderr, "  [steam] SteamAPI_Init -> FAILED (result %d): %s\n", -state, g_init_err);
        return -state;
    }
    fprintf(stderr, "  [steam] SteamAPI_Init -> OK (%s: user %s \"%s\", app %u)\n",
            g_acct.real ? (g_acct.offline ? "real Steam account, offline (cached answers)"
                                          : "real Steam account")
                        : "stub client",
            kl_mask_sid(USER_ID), steam_persona(), APP_ID);
    // SDK 1.61 dropped RequestCurrentStats: the client loads the user's stats
    // itself at init and announces them with UserStatsReceived_t, and a game
    // that waits for that before touching achievements (Steamworks.NET's
    // samples do) waits forever without it. Queued once (account_init has
    // already loaded the real ones); the first pump delivers it, whichever
    // dispatch style the game uses.
    static int stats_once;
    if (!stats_once) { stats_once = 1; stats_received(); }
    return 0;                                     // k_ESteamAPIInitResult_OK
}
static int  st_init_bool(void) { return st_init(NULL, NULL) == 0; }
static int  st_gs_init(uint32_t ip, uint16_t gport, uint16_t qport, int mode,
                       const char *ver, const char *versions, void *err) {
    (void)ip; (void)qport; (void)versions;
    if (err) memset(err, 0, 1024);
    fprintf(stderr, "  [steam] SteamGameServer_Init(port %u, mode %d, \"%s\") -> OK\n",
            gport, mode, ver ? ver : "");
    return 0;
}
static int  st_hsteamuser(void) { return 1; }
static int  st_hsteampipe(void) { return 1; }
static int  st_gs_hsteamuser(void) { return 2; }
static int  st_false(void) { return 0; }
// "Is Steam running": not after an init that found no Steam to talk to.
static int  st_is_running(void) { return g_init_state != -2; }
static void st_shutdown(void) {
    fprintf(stderr, "  [steam] SteamAPI_Shutdown\n");
    kl_steam_shutdown();
}
static void st_void(void) {}
static const char *st_install_path(void) { return "/steam"; }
static void *st_find_user(int hUser, const char *ver) { (void)hUser; return iface(ver); }
static void *st_create_iface(const char *ver) { return iface(ver); }

// CSteamAPIContext and friends: { void (*init)(void *ctx); uintp counter; ctx }.
static uintptr_t g_ctx_counter = 1;
static void *st_context_init(void *data) {
    struct { void (*fn)(void *); uintptr_t counter; char ctx[]; } *d = data;
    if (d->counter != g_ctx_counter) { d->fn(d->ctx); d->counter = g_ctx_counter; }
    return d->ctx;
}

// ---- callbacks ---------------------------------------------------------------------------
// CCallbackBase: vtable; uint8 m_nCallbackFlags @8; int m_iCallback @12.
// vtable: Run(void *), Run(void *, bool, SteamAPICall_t), GetCallbackSizeBytes().
typedef struct { void **vt; uint8_t flags; uint8_t pad[3]; int id; } ccb;
static ccb *g_cbs[512];
static int g_ncbs;
typedef struct { ccb *cb; uint64_t call; } cres;
static cres g_cres[256];
static int g_ncres;
// `announced`: a call result whose SteamAPICallCompleted_t the MANUAL dispatch
// loop has already handed out; it stays queued until GetAPICallResult takes it.
typedef struct { int id; uint64_t call; size_t n; void *data; int announced; } posted;
static posted g_posted[256];
static int g_nposted;
static uint64_t g_next_call = 1;
static pthread_mutex_t g_cbmu = PTHREAD_MUTEX_INITIALIZER;

static void st_register_cb(ccb *cb, int id) {
    pthread_mutex_lock(&g_cbmu);
    cb->flags |= 1;
    cb->id = id;
    if (g_ncbs < 512) g_cbs[g_ncbs++] = cb;
    pthread_mutex_unlock(&g_cbmu);
    if (kl_env_on("KL_TRACE_STEAM", 0))
        fprintf(stderr, "  [steam] RegisterCallback(%p, %d)\n", (void *)cb, id);
}
static void st_unregister_cb(ccb *cb) {
    pthread_mutex_lock(&g_cbmu);
    for (int i = 0; i < g_ncbs; i++) if (g_cbs[i] == cb) g_cbs[i--] = g_cbs[--g_ncbs];
    cb->flags &= (uint8_t)~1;
    pthread_mutex_unlock(&g_cbmu);
}
static void st_register_result(ccb *cb, uint64_t call) {
    pthread_mutex_lock(&g_cbmu);
    if (g_ncres < 256) g_cres[g_ncres++] = (cres){ cb, call };
    pthread_mutex_unlock(&g_cbmu);
}
static void st_unregister_result(ccb *cb, uint64_t call) {
    pthread_mutex_lock(&g_cbmu);
    for (int i = 0; i < g_ncres; i++)
        if (g_cres[i].cb == cb && g_cres[i].call == call) g_cres[i--] = g_cres[--g_ncres];
    pthread_mutex_unlock(&g_cbmu);
}
// Queue a callback (call == 0) or a call result, delivered by the next pump.
static uint64_t post(int id, const void *data, size_t n, int as_call_result) {
    pthread_mutex_lock(&g_cbmu);
    uint64_t call = as_call_result ? g_next_call++ : 0;
    if (g_nposted < 256) {
        void *c = malloc(n);
        memcpy(c, data, n);
        g_posted[g_nposted++] = (posted){ id, call, n, c, 0 };
    }
    pthread_mutex_unlock(&g_cbmu);
    return call;
}

static void net_dispatch(void);
static void st_run_callbacks(void) {
    net_dispatch();
    for (;;) {
        pthread_mutex_lock(&g_cbmu);
        if (!g_nposted) { pthread_mutex_unlock(&g_cbmu); break; }
        posted p = g_posted[0];
        memmove(g_posted, g_posted + 1, (size_t)--g_nposted * sizeof *g_posted);
        ccb *targets[64];
        int nt = 0;
        if (!p.call) {
            for (int i = 0; i < g_ncbs && nt < 64; i++)
                if (g_cbs[i]->id == p.id) targets[nt++] = g_cbs[i];
        } else {
            for (int i = 0; i < g_ncres && nt < 64; i++)
                if (g_cres[i].call == p.call) { targets[nt++] = g_cres[i].cb; g_cres[i--] = g_cres[--g_ncres]; }
        }
        pthread_mutex_unlock(&g_cbmu);
        for (int i = 0; i < nt; i++) {
            if (!p.call) ((void (*)(ccb *, void *))targets[i]->vt[0])(targets[i], p.data);
            else ((void (*)(ccb *, void *, int, uint64_t))targets[i]->vt[1])(targets[i], p.data, 0, p.call);
        }
        free(p.data);
    }
}

// ---- ISteamClient ------------------------------------------------------------------------
static int   cl_pipe(void *s) { (void)s; return 1; }
static int   cl_true(void *s) { (void)s; return 1; }
static int   cl_user(void *s, int pipe) { (void)s; (void)pipe; return 1; }
static void *cl_get3(void *s, int u, int p, const char *ver) { (void)s; (void)u; (void)p; return iface(ver); }
static void *cl_get2(void *s, int p, const char *ver) { (void)s; (void)p; return iface(ver); }

// ---- ISteamUser / ISteamGameServer ------------------------------------------------------------
static int      us_hsteamuser(void *s) { (void)s; return 1; }
static int      us_true(void *s) { (void)s; return 1; }
static int      us_false(void *s) { (void)s; return 0; }
static uint64_t us_steamid(void *s) { (void)s; return USER_ID; }
static uint64_t gs_steamid(void *s) { (void)s; return SERVER_ID; }
static int us_userdata_folder(void *s, char *buf, int n) {
    (void)s;
    // The TARGET's userdata, not Alyx's: this used to be a literal
    // ".../userdata/alyx/steam", which on a second Steam guest would have put
    // its Steam-side files in Alyx's directory.
    const char *t = kl_driver_target_name();
    snprintf(buf, (size_t)n, "%s/steam", kl_userdata_dir(t && *t ? t : "alyx"));
    return 1;
}
static int us_level(void *s) { (void)s; return 1; }
static int us_license(void *s, uint64_t id, uint32_t app) { (void)s; (void)id; return app == APP_ID ? 0 : 2; }
static uint32_t us_ticket(void *s, void *buf, int cb, uint32_t *out, const void *ident) {
    (void)s; (void)ident;
    if (buf && cb >= 8) { memset(buf, 0x4b, 8); if (out) *out = 8; }
    return 1;                                    // HAuthTicket
}
static int us_begin_auth(void *s, const void *t, int cb, uint64_t id) { (void)s; (void)t; (void)cb; (void)id; return 0; }

// ---- ISteamUtils -----------------------------------------------------------------------------------
static uint32_t ut_appid(void *s) { (void)s; return APP_ID; }
static uint32_t ut_time(void *s) { (void)s; return (uint32_t)time(NULL); }
static const char *ut_country(void *s) { (void)s; return "US"; }
// The game language: KL_STEAM_LANG (a Steam language API name: english,
// spanish, latam, french, german, ...), else KL_LOCALE (the per-game language
// the visionOS hub sets, the same knob the Android Locale answers from) mapped
// to Steam's name, else the system's first preferred language. Alyx ships
// English voices only; this picks UI text and subtitles.
static const char *steam_lang(void) {
    static char lang[32];
    if (lang[0]) return lang;
    const char *e = getenv("KL_STEAM_LANG");
    if (e && *e) { snprintf(lang, sizeof lang, "%s", e); return lang; }
    char code[64] = "en";
    const char *loc = getenv("KL_LOCALE");
    if (loc && *loc) {
        snprintf(code, sizeof code, "%s", loc);
        for (char *p = code; *p; p++) {
            if (*p == '_') *p = '-';
            if (*p == '.' || *p == '@') { *p = 0; break; }
        }
    } else {
        CFArrayRef pref = CFLocaleCopyPreferredLanguages();
        if (pref) {
            if (CFArrayGetCount(pref) > 0)
                CFStringGetCString(CFArrayGetValueAtIndex(pref, 0), code, sizeof code, kCFStringEncodingUTF8);
            CFRelease(pref);
        }
    }
    static const struct { const char *pfx, *name; } map[] = {
        {"es-ES", "spanish"}, {"es-", "latam"}, {"es", "spanish"},
        {"pt-BR", "brazilian"}, {"pt", "portuguese"}, {"zh-Hant", "tchinese"},
        {"zh-TW", "tchinese"}, {"zh-HK", "tchinese"}, {"zh", "schinese"},
        {"fr", "french"}, {"de", "german"}, {"it", "italian"}, {"ja", "japanese"}, {"ko", "koreana"},
        {"ru", "russian"}, {"pl", "polish"}, {"nl", "dutch"}, {"sv", "swedish"}, {"da", "danish"},
        {"fi", "finnish"}, {"nb", "norwegian"}, {"no", "norwegian"}, {"cs", "czech"}, {"hu", "hungarian"},
        {"tr", "turkish"}, {"uk", "ukrainian"}, {"th", "thai"}, {"el", "greek"}, {"bg", "bulgarian"},
        {"ro", "romanian"}, {"vi", "vietnamese"},
    };
    const char *name = "english";
    for (size_t i = 0; i < sizeof map / sizeof map[0]; i++)
        if (strncmp(code, map[i].pfx, strlen(map[i].pfx)) == 0) { name = map[i].name; break; }
    snprintf(lang, sizeof lang, "%s", name);
    fprintf(stderr, "  [steam] game language: %s (%s %s)\n", lang,
            loc && *loc ? "KL_LOCALE" : "system", code);
    return lang;
}
static const char *ut_lang(void *s) { (void)s; return steam_lang(); }
const char *kl_steam_game_language(void) { return steam_lang(); }
static int ut_universe(void *s) { (void)s; return 1; }
static uint8_t ut_battery(void *s) { (void)s; return 255; }
static int ut_call_done(void *s, uint64_t call, int *failed) {
    (void)s;
    pthread_mutex_lock(&g_cbmu);
    int done = 0;
    for (int i = 0; i < g_nposted; i++) if (g_posted[i].call == call) done = 1;
    pthread_mutex_unlock(&g_cbmu);
    if (failed) *failed = 0;
    return done;
}
static int ut_call_result(void *s, uint64_t call, void *out, int cb, int expected, int *failed) {
    (void)s; (void)expected;
    int got = 0;
    pthread_mutex_lock(&g_cbmu);
    for (int i = 0; i < g_nposted; i++)
        if (g_posted[i].call == call) {
            memcpy(out, g_posted[i].data, (size_t)cb < g_posted[i].n ? (size_t)cb : g_posted[i].n);
            free(g_posted[i].data);
            g_posted[i] = g_posted[--g_nposted];
            got = 1;
            break;
        }
    pthread_mutex_unlock(&g_cbmu);
    if (failed) *failed = !got;
    return got;
}

// ---- ISteamApps ---------------------------------------------------------------------------------------
static int ap_true(void *s) { (void)s; return 1; }
static int ap_false(void *s) { (void)s; return 0; }
static int ap_subscribed_app(void *s, uint32_t app) { (void)s; return app == APP_ID; }
static int ap_installed(void *s, uint32_t app) { (void)s; return app == APP_ID; }
static const char *ap_lang(void *s) { (void)s; return steam_lang(); }
static uint32_t ap_purchase(void *s, uint32_t app) { (void)s; (void)app; return 1600000000u; }
static int ap_beta(void *s, char *buf, int n) { (void)s; if (buf && n) buf[0] = 0; return 0; }
static uint32_t ap_install_dir(void *s, uint32_t app, char *buf, uint32_t n) {
    (void)s; (void)app;
    char cwd[1024];
    if (!getcwd(cwd, sizeof cwd)) cwd[0] = 0;   // the door chdir'd into the game root
    snprintf(buf, n, "%s", cwd);
    return (uint32_t)strlen(buf);
}
static uint64_t ap_owner(void *s) { (void)s; return USER_ID; }
static const char *ap_empty(void *s, const char *k) { (void)s; (void)k; return ""; }
static int ap_build(void *s) { (void)s; return 1; }
static int ap_cmdline(void *s, char *buf, int n) { (void)s; if (buf && n) buf[0] = 0; return 0; }

// ---- ISteamFriends ------------------------------------------------------------------------------------
static const char *fr_name(void *s) { (void)s; return steam_persona(); }
static int fr_state(void *s) { (void)s; return 1; }                       // online
static const char *fr_friend_name(void *s, uint64_t id) { (void)s; (void)id; return steam_persona(); }
static int fr_zero(void *s) { (void)s; return 0; }

// ---- ISteamNetworking (the old P2P API): only its packet size is asked ----
static uint32_t nw_max_packet(void *s, uint32_t sock) { (void)s; (void)sock; return 1200; }

// ---- ISteamNetworkingSockets: loopback ---------------------------------------------------------------
#define NS_MAXCONN 256
#define NS_MAXLISTEN 32
#define CS_NONE 0
#define CS_CONNECTING 1
#define CS_CONNECTED 3
#define CS_CLOSEDBYPEER 4
#define CS_PROBLEM 5
#define EK_OK 1
#define EK_NOCONN 3
#define EK_INVALIDPARAM 8

typedef void (*status_fn)(void *cb);
typedef struct msg {
    // SteamNetworkingMessage_t, 216 bytes; offsets per steamnetworkingtypes.h
    // (aarch64 Linux): data 0, size 8, conn 12, identity 16 (136), connuserdata
    // 152, time 160, number 168, freedata 176, release 184, channel 192,
    // flags 196, userdata 200, lane 208.
    uint8_t raw[216];
    struct msg *next;
} msg;
typedef struct {
    int used, state, peer, listen, poll;
    int64_t userdata;
    char name[128];
    status_fn cb;
    uint16_t port;
    int64_t nextnum;
    msg *head, *tail;
} nconn;
typedef struct { int used; uint16_t port; int p2p; status_fn cb; } nlisten;
static nconn g_conn[NS_MAXCONN];
static nlisten g_listen[NS_MAXLISTEN];
static int g_npoll;
static status_fn g_global_status_cb;
static pthread_mutex_t g_nmu = PTHREAD_MUTEX_INITIALIZER;
// Pending status changes: (conn, old state), turned into callbacks by net_dispatch.
static struct { int conn, old; } g_ns_q[512];
static int g_ns_nq;

#define H_CONN(i)   ((uint32_t)(0x10000 + (i)))
#define H_LISTEN(i) ((uint32_t)(0x20000 + (i)))
#define H_POLL(i)   ((uint32_t)(0x30000 + (i)))
static nconn *conn_of(uint32_t h) {
    uint32_t i = h - 0x10000;
    return (h >= 0x10000 && i < NS_MAXCONN && g_conn[i].used) ? &g_conn[i] : NULL;
}

static int64_t now_us(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000 + t.tv_nsec / 1000;
}

static void set_state(int ci, int st) {          // caller holds g_nmu
    int old = g_conn[ci].state;
    if (old == st) return;
    g_conn[ci].state = st;
    if (g_ns_nq < 512) { g_ns_q[g_ns_nq].conn = ci; g_ns_q[g_ns_nq].old = old; g_ns_nq++; }
}

static status_fn opts_status_cb(int n, const uint8_t *opts) {
    // SteamNetworkingConfigValue_t: { int m_eValue; int m_eDataType; union m_val @8 } = 16 bytes
    for (int i = 0; opts && i < n; i++) {
        int v; memcpy(&v, opts + i * 16, 4);
        if (v == 201) { void *p; memcpy(&p, opts + i * 16 + 8, 8); return (status_fn)p; }
    }
    return NULL;
}

static void put_identity(uint8_t *dst, uint64_t sid) {   // SteamNetworkingIdentity, 136 bytes
    memset(dst, 0, 136);
    int type = 16, size = 8;                              // k_ESteamNetworkingIdentityType_SteamID
    memcpy(dst, &type, 4); memcpy(dst + 4, &size, 4); memcpy(dst + 8, &sid, 8);
}
static void fill_info(uint8_t *info, int ci) {           // SteamNetConnectionInfo_t, 696 bytes
    nconn *c = &g_conn[ci];
    memset(info, 0, 696);
    put_identity(info, c->listen >= 0 ? USER_ID : SERVER_ID);
    memcpy(info + 136, &c->userdata, 8);
    uint32_t ls = c->listen >= 0 ? H_LISTEN(c->listen) : 0;
    memcpy(info + 144, &ls, 4);
    uint8_t addr[18] = { 0,0,0,0,0,0,0,0,0,0,0xff,0xff,127,0,0,1 };
    memcpy(addr + 16, &c->port, 2);
    memcpy(info + 148, addr, 18);
    int st = c->state;
    memcpy(info + 176, &st, 4);
    snprintf((char *)info + 312, 128, "loopback #%d%s%s", ci, c->name[0] ? " " : "", c->name);
}

static int new_conn(void) {                              // caller holds g_nmu
    for (int i = 0; i < NS_MAXCONN; i++)
        if (!g_conn[i].used) {
            memset(&g_conn[i], 0, sizeof g_conn[i]);
            g_conn[i].used = 1; g_conn[i].peer = -1; g_conn[i].listen = -1;
            g_conn[i].poll = -1; g_conn[i].userdata = -1; g_conn[i].nextnum = 1;
            return i;
        }
    return -1;
}

static void net_dispatch(void) {
    for (;;) {
        pthread_mutex_lock(&g_nmu);
        if (!g_ns_nq) { pthread_mutex_unlock(&g_nmu); return; }
        int ci = g_ns_q[0].conn, old = g_ns_q[0].old;
        memmove(g_ns_q, g_ns_q + 1, (size_t)--g_ns_nq * sizeof *g_ns_q);
        uint8_t cbdata[704];
        memset(cbdata, 0, sizeof cbdata);
        uint32_t h = H_CONN(ci);
        memcpy(cbdata, &h, 4);
        fill_info(cbdata + 4, ci);
        memcpy(cbdata + 700, &old, 4);
        status_fn fn = g_conn[ci].cb;
        if (!fn && g_conn[ci].listen >= 0) fn = g_listen[g_conn[ci].listen].cb;
        if (!fn) fn = g_global_status_cb;
        int st = g_conn[ci].state;
        pthread_mutex_unlock(&g_nmu);
        if (kl_env_on("KL_TRACE_STEAM", 0))
            fprintf(stderr, "  [steam] connection %#x: state %d -> %d (%s)\n", h, old, st,
                    fn ? "config callback" : "SteamAPI callback");
        if (fn) fn(cbdata);
        else post(1221, cbdata, sizeof cbdata, 0);
    }
}

static uint32_t ns_listen_ip(void *s, const uint8_t *addr, int n, const uint8_t *opts) {
    (void)s;
    pthread_mutex_lock(&g_nmu);
    for (int i = 0; i < NS_MAXLISTEN; i++)
        if (!g_listen[i].used) {
            g_listen[i].used = 1;
            memcpy(&g_listen[i].port, addr + 16, 2);
            g_listen[i].p2p = 0;
            g_listen[i].cb = opts_status_cb(n, opts);
            pthread_mutex_unlock(&g_nmu);
            fprintf(stderr, "  [steam] sockets: listen (IP port %u) -> %#x\n", g_listen[i].port, H_LISTEN(i));
            return H_LISTEN(i);
        }
    pthread_mutex_unlock(&g_nmu);
    return 0;
}
static uint32_t ns_listen_p2p(void *s, int vport, int n, const uint8_t *opts) {
    (void)s;
    pthread_mutex_lock(&g_nmu);
    for (int i = 0; i < NS_MAXLISTEN; i++)
        if (!g_listen[i].used) {
            g_listen[i].used = 1; g_listen[i].port = (uint16_t)vport; g_listen[i].p2p = 1;
            g_listen[i].cb = opts_status_cb(n, opts);
            pthread_mutex_unlock(&g_nmu);
            fprintf(stderr, "  [steam] sockets: listen (P2P vport %d) -> %#x\n", vport, H_LISTEN(i));
            return H_LISTEN(i);
        }
    pthread_mutex_unlock(&g_nmu);
    return 0;
}
static uint32_t connect_to(uint16_t port, int p2p, int n, const uint8_t *opts) {
    pthread_mutex_lock(&g_nmu);
    int li = -1;
    for (int i = 0; i < NS_MAXLISTEN; i++)
        if (g_listen[i].used && g_listen[i].p2p == p2p && (g_listen[i].port == port || !port)) { li = i; break; }
    if (li < 0)                                          // any listener: the loopback has one server
        for (int i = 0; i < NS_MAXLISTEN; i++) if (g_listen[i].used) { li = i; break; }
    int c = new_conn();
    if (c < 0) { pthread_mutex_unlock(&g_nmu); return 0; }
    g_conn[c].cb = opts_status_cb(n, opts);
    g_conn[c].port = port;
    set_state(c, CS_CONNECTING);
    if (li >= 0) {
        int sv = new_conn();
        g_conn[sv].listen = li;
        g_conn[sv].port = port;
        g_conn[sv].peer = c;
        g_conn[c].peer = sv;
        set_state(sv, CS_CONNECTING);                    // the server app must Accept it
    } else {
        set_state(c, CS_PROBLEM);
    }
    pthread_mutex_unlock(&g_nmu);
    fprintf(stderr, "  [steam] sockets: connect (%s %u) -> %#x%s\n", p2p ? "P2P vport" : "port",
            port, H_CONN(c), li < 0 ? " — nothing listening" : "");
    return H_CONN(c);
}
static uint32_t ns_connect_ip(void *s, const uint8_t *addr, int n, const uint8_t *opts) {
    (void)s; uint16_t port; memcpy(&port, addr + 16, 2);
    return connect_to(port, 0, n, opts);
}
static uint32_t ns_connect_p2p(void *s, const void *ident, int vport, int n, const uint8_t *opts) {
    (void)s; (void)ident;
    return connect_to((uint16_t)vport, 1, n, opts);
}
static int ns_accept(void *s, uint32_t h) {
    (void)s;
    pthread_mutex_lock(&g_nmu);
    nconn *c = conn_of(h);
    int r = EK_INVALIDPARAM;
    if (c && c->state == CS_CONNECTING) {
        int ci = (int)(c - g_conn);
        set_state(ci, CS_CONNECTED);
        if (c->peer >= 0 && g_conn[c->peer].used) set_state(c->peer, CS_CONNECTED);
        r = EK_OK;
    }
    pthread_mutex_unlock(&g_nmu);
    return r;
}
static void free_msgs(nconn *c) {
    for (msg *m = c->head; m; ) { msg *n = m->next; void *d; memcpy(&d, m->raw, 8); free(d); free(m); m = n; }
    c->head = c->tail = NULL;
}
static int ns_close(void *s, uint32_t h, int reason, const char *dbg, int linger) {
    (void)s; (void)reason; (void)linger;
    pthread_mutex_lock(&g_nmu);
    nconn *c = conn_of(h);
    if (!c) { pthread_mutex_unlock(&g_nmu); return 0; }
    if (c->peer >= 0 && g_conn[c->peer].used) {
        g_conn[c->peer].peer = -1;
        if (g_conn[c->peer].state == CS_CONNECTED || g_conn[c->peer].state == CS_CONNECTING)
            set_state(c->peer, CS_CLOSEDBYPEER);
    }
    free_msgs(c);
    // A closed handle never reports again; drop any queued change for it.
    int ci = (int)(c - g_conn);
    for (int i = 0; i < g_ns_nq; i++) if (g_ns_q[i].conn == ci) g_ns_q[i--] = g_ns_q[--g_ns_nq];
    c->used = 0;
    pthread_mutex_unlock(&g_nmu);
    if (kl_env_on("KL_TRACE_STEAM", 0))
        fprintf(stderr, "  [steam] sockets: close %#x (%s)\n", h, dbg ? dbg : "");
    return 1;
}
static int ns_close_listen(void *s, uint32_t h) {
    (void)s; uint32_t i = h - 0x20000;
    if (i >= NS_MAXLISTEN) return 0;
    pthread_mutex_lock(&g_nmu); g_listen[i].used = 0; pthread_mutex_unlock(&g_nmu);
    return 1;
}
static int ns_set_ud(void *s, uint32_t h, int64_t ud) {
    (void)s; pthread_mutex_lock(&g_nmu); nconn *c = conn_of(h); if (c) c->userdata = ud;
    pthread_mutex_unlock(&g_nmu); return c != NULL;
}
static int64_t ns_get_ud(void *s, uint32_t h) {
    (void)s; pthread_mutex_lock(&g_nmu); nconn *c = conn_of(h); int64_t v = c ? c->userdata : -1;
    pthread_mutex_unlock(&g_nmu); return v;
}
static void ns_set_name(void *s, uint32_t h, const char *n) {
    (void)s; pthread_mutex_lock(&g_nmu); nconn *c = conn_of(h);
    if (c) snprintf(c->name, sizeof c->name, "%s", n ? n : ""); pthread_mutex_unlock(&g_nmu);
}
static int ns_get_name(void *s, uint32_t h, char *buf, int n) {
    (void)s; pthread_mutex_lock(&g_nmu); nconn *c = conn_of(h);
    if (c && buf && n) snprintf(buf, (size_t)n, "%s", c->name); pthread_mutex_unlock(&g_nmu);
    return c != NULL;
}

static void msg_release(void *m) {
    void *d; memcpy(&d, (uint8_t *)m, 8);
    void (*fd)(void *); memcpy(&fd, (uint8_t *)m + 176, 8);
    if (fd) fd(m); else free(d);
    free(m);
}
static void msg_free_data(void *m) { void *d; memcpy(&d, (uint8_t *)m, 8); free(d); }

// Copy `data` into a message on `to`'s receive queue. Caller holds g_nmu.
static int deliver(int from, const void *data, uint32_t n, int flags, int64_t *num) {
    nconn *src = &g_conn[from];
    if (src->state != CS_CONNECTED || src->peer < 0 || !g_conn[src->peer].used) return EK_NOCONN;
    nconn *dst = &g_conn[src->peer];
    msg *m = calloc(1, sizeof *m);
    void *copy = malloc(n ? n : 1);
    memcpy(copy, data, n);
    uint8_t *r = m->raw;
    int sz = (int)n;
    uint32_t h = H_CONN(src->peer);
    int64_t t = now_us(), nn = src->nextnum++;
    void *rel = (void *)msg_release, *fd = (void *)msg_free_data;
    memcpy(r, &copy, 8); memcpy(r + 8, &sz, 4); memcpy(r + 12, &h, 4);
    put_identity(r + 16, src->listen >= 0 ? USER_ID : SERVER_ID);   // who sent it
    memcpy(r + 152, &dst->userdata, 8); memcpy(r + 160, &t, 8); memcpy(r + 168, &nn, 8);
    memcpy(r + 176, &fd, 8); memcpy(r + 184, &rel, 8); memcpy(r + 196, &flags, 4);
    if (dst->tail) dst->tail->next = m; else dst->head = m;
    dst->tail = m;
    if (num) *num = nn;
    return EK_OK;
}
static int ns_send(void *s, uint32_t h, const void *data, uint32_t n, int flags, int64_t *num) {
    (void)s;
    pthread_mutex_lock(&g_nmu);
    nconn *c = conn_of(h);
    int r = c ? deliver((int)(c - g_conn), data, n, flags, num) : EK_INVALIDPARAM;
    pthread_mutex_unlock(&g_nmu);
    return r;
}
static void ns_send_many(void *s, int n, void *const *msgs, int64_t *out) {
    (void)s;
    for (int i = 0; i < n; i++) {
        uint8_t *m = msgs[i];
        void *data; int sz, flags; uint32_t h;
        memcpy(&data, m, 8); memcpy(&sz, m + 8, 4); memcpy(&h, m + 12, 4); memcpy(&flags, m + 196, 4);
        int64_t num = 0;
        pthread_mutex_lock(&g_nmu);
        nconn *c = conn_of(h);
        int r = c ? deliver((int)(c - g_conn), data, (uint32_t)sz, flags, &num) : EK_INVALIDPARAM;
        pthread_mutex_unlock(&g_nmu);
        if (out) out[i] = r == EK_OK ? num : -r;
        void (*rel)(void *); memcpy(&rel, m + 184, 8);
        if (rel) rel(m);
    }
}
static int ns_flush(void *s, uint32_t h) { (void)s; (void)h; return EK_OK; }
static int take(nconn *c, void **out, int max) {          // caller holds g_nmu
    int k = 0;
    while (c->head && k < max) {
        msg *m = c->head;
        c->head = m->next;
        if (!c->head) c->tail = NULL;
        // Hand the guest the 216-byte struct itself; msg_release frees it, and
        // `raw` is the first member so the two pointers are the same.
        out[k++] = m;
    }
    return k;
}
static int ns_recv(void *s, uint32_t h, void **out, int max) {
    (void)s;
    pthread_mutex_lock(&g_nmu);
    nconn *c = conn_of(h);
    int k = c ? take(c, out, max) : -1;
    pthread_mutex_unlock(&g_nmu);
    return k;
}
static int ns_info(void *s, uint32_t h, uint8_t *info) {
    (void)s;
    pthread_mutex_lock(&g_nmu);
    nconn *c = conn_of(h);
    if (c && info) fill_info(info, (int)(c - g_conn));
    pthread_mutex_unlock(&g_nmu);
    return c != NULL;
}
static int ns_status(void *s, uint32_t h, uint8_t *st, int nl, void *lanes) {
    (void)s; (void)nl; (void)lanes;
    pthread_mutex_lock(&g_nmu);
    nconn *c = conn_of(h);
    if (c && st) {
        memset(st, 0, 120);
        int state = c->state; float q = 1.0f; int rate = 1 << 30;
        memcpy(st, &state, 4); memcpy(st + 8, &q, 4); memcpy(st + 12, &q, 4); memcpy(st + 32, &rate, 4);
    }
    pthread_mutex_unlock(&g_nmu);
    return c ? EK_OK : EK_NOCONN;
}
static int ns_detailed(void *s, uint32_t h, char *buf, int n) {
    (void)s; (void)h; if (buf && n) snprintf(buf, (size_t)n, "loopback"); return 0;
}
static int ns_listen_addr(void *s, uint32_t h, uint8_t *addr) {
    (void)s; uint32_t i = h - 0x20000;
    if (i >= NS_MAXLISTEN || !g_listen[i].used || !addr) return 0;
    uint8_t a[18] = { 0,0,0,0,0,0,0,0,0,0,0xff,0xff,127,0,0,1 };
    memcpy(a + 16, &g_listen[i].port, 2);
    memcpy(addr, a, 18);
    return 1;
}
static int ns_pair(void *s, uint32_t *a, uint32_t *b, int loop, const void *i1, const void *i2) {
    (void)s; (void)loop; (void)i1; (void)i2;
    pthread_mutex_lock(&g_nmu);
    int x = new_conn(), y = new_conn();
    g_conn[x].peer = y; g_conn[y].peer = x;
    g_conn[x].state = g_conn[y].state = CS_CONNECTED;     // born connected: no callbacks
    pthread_mutex_unlock(&g_nmu);
    if (a) *a = H_CONN(x);
    if (b) *b = H_CONN(y);
    return 1;
}
static int ns_lanes(void *s, uint32_t h, int n, const int *p, const uint16_t *w) {
    (void)s; (void)h; (void)n; (void)p; (void)w; return EK_OK;
}
static int ns_identity(void *s, uint8_t *id) { (void)s; if (id) put_identity(id, USER_ID); return 1; }
static int ns_avail(void *s) { (void)s; return 100; }   // k_ESteamNetworkingAvailability_Current
static int ns_auth_status(void *s, uint8_t *st) {
    (void)s; if (st) { memset(st, 0, 260); int a = 100; memcpy(st, &a, 4); } return 100;
}
static uint32_t ns_poll_create(void *s) { (void)s; return H_POLL(++g_npoll); }
static int ns_poll_destroy(void *s, uint32_t h) {
    (void)s;
    pthread_mutex_lock(&g_nmu);
    for (int i = 0; i < NS_MAXCONN; i++) if (g_conn[i].used && g_conn[i].poll == (int)h) g_conn[i].poll = -1;
    pthread_mutex_unlock(&g_nmu);
    return 1;
}
static int ns_set_poll(void *s, uint32_t hc, uint32_t hp) {
    (void)s; pthread_mutex_lock(&g_nmu); nconn *c = conn_of(hc); if (c) c->poll = hp ? (int)hp : -1;
    pthread_mutex_unlock(&g_nmu); return c != NULL;
}
static int ns_recv_poll(void *s, uint32_t hp, void **out, int max) {
    (void)s;
    int k = 0;
    pthread_mutex_lock(&g_nmu);
    for (int i = 0; i < NS_MAXCONN && k < max; i++)
        if (g_conn[i].used && g_conn[i].poll == (int)hp) k += take(&g_conn[i], out + k, max - k);
    pthread_mutex_unlock(&g_nmu);
    return k;
}
static void ns_run_callbacks(void *s) { (void)s; net_dispatch(); }

// ---- ISteamNetworkingUtils -------------------------------------------------------------------------
static void *nu_alloc(void *s, int cb) {
    (void)s;
    msg *m = calloc(1, sizeof *m);
    void *d = cb > 0 ? malloc((size_t)cb) : NULL;
    void *rel = (void *)msg_release, *fd = (void *)msg_free_data;
    memcpy(m->raw, &d, 8); memcpy(m->raw + 8, &cb, 4);
    memcpy(m->raw + 176, &fd, 8); memcpy(m->raw + 184, &rel, 8);
    return m;
}
static int nu_relay(void *s, uint8_t *st) {
    (void)s; if (st) { memset(st, 0, 272); int a = 100; memcpy(st, &a, 4); memcpy(st + 8, &a, 4); memcpy(st + 12, &a, 4); }
    return 100;
}
static int nu_true(void *s) { (void)s; return 1; }
static int64_t nu_time(void *s) { (void)s; return now_us(); }
static void nu_debug(void *s, int lvl, void *fn) { (void)s; (void)lvl; (void)fn; }
static int nu_set_config(void *s, int value, int scope, intptr_t obj, int type, const void *arg) {
    (void)s; (void)type;
    if (value == 201 && arg) {                       // Callback_ConnectionStatusChanged
        status_fn fn; memcpy(&fn, arg, 8);
        pthread_mutex_lock(&g_nmu);
        if (scope == 1 || scope == 2) g_global_status_cb = fn;
        else if (scope == 3 && (uint32_t)obj - 0x20000 < NS_MAXLISTEN) g_listen[(uint32_t)obj - 0x20000].cb = fn;
        else if (scope == 4) { nconn *c = conn_of((uint32_t)obj); if (c) c->cb = fn; }
        pthread_mutex_unlock(&g_nmu);
    }
    return 1;
}
static int nu_get_config(void *s, int value, int scope, intptr_t obj, int *type, void *out, size_t *cb) {
    (void)s; (void)value; (void)scope; (void)obj; (void)type; (void)out; (void)cb;
    return -1;                                        // k_ESteamNetworkingGetConfigValue_BadValue
}
static const char *nu_config_info(void *s, int value, int *type, int *scope) {
    (void)s; (void)value; (void)type; (void)scope; return NULL;
}
static int nu_iterate(void *s, int cur, int dev) { (void)s; (void)cur; (void)dev; return 0; }
static void nu_addr_tostr(void *s, const uint8_t *a, char *buf, size_t n, int port) {
    (void)s;
    uint16_t p; memcpy(&p, a + 16, 2);
    if (port) snprintf(buf, n, "%u.%u.%u.%u:%u", a[12], a[13], a[14], a[15], p);
    else snprintf(buf, n, "%u.%u.%u.%u", a[12], a[13], a[14], a[15]);
}
static int nu_addr_parse(void *s, uint8_t *a, const char *str) {
    (void)s;
    unsigned x[4] = {0}, p = 0;
    if (!str || sscanf(str, "%u.%u.%u.%u:%u", &x[0], &x[1], &x[2], &x[3], &p) < 4) return 0;
    memset(a, 0, 18); a[10] = a[11] = 0xff;
    for (int i = 0; i < 4; i++) a[12 + i] = (uint8_t)x[i];
    uint16_t pp = (uint16_t)p; memcpy(a + 16, &pp, 2);
    return 1;
}
static int nu_zero(void *s) { (void)s; return 0; }
static void nu_id_tostr(void *s, const uint8_t *id, char *buf, size_t n) {
    (void)s; uint64_t sid; memcpy(&sid, id + 8, 8); snprintf(buf, n, "steamid:%llu", (unsigned long long)sid);
}
static int nu_id_parse(void *s, uint8_t *id, const char *str) {
    (void)s; unsigned long long sid = 0;
    if (str && sscanf(str, "steamid:%llu", &sid) == 1) { put_identity(id, sid); return 1; }
    return 0;
}

// ---- the real account: SteamAPI_Init through the bridge ---------------------------------
//
// account_init runs once, inside SteamAPI_Init (and the flat / SteamInternal_
// spellings of it): `hello` for the target's app, then — owned — `stats`, then
// `playing` on. What happens when the bridge does not answer is
// KL_STEAM_REQUIRE_REAL's call:
//   1  init fails (k_ESteamAPIInitResult_NoSteamClient) and the game shows its
//      own "Steam is not running" behaviour;
//   0  today's stub, with one loud warning.
// Default: 0 on the Mac (a run with no `steamdepot serve` is a normal
// development run); on device 1 when the app registered a backend, i.e. this
// build carries the Steam service and ownership must come from it. A device
// build with NO backend (no SteamDepot linked) cannot ask, and keeps the stub.
//
// SAFETY KNOB: KL_STEAM_STATS_DRYRUN=1 marks every `store` "dry_run":true — the
// service then changes nothing on the account. Use it for any test run.
#define BRIDGE_RESP_CAP (256 * 1024)

static int bridge_timeout(void) { return kl_env_int("KL_STEAM_BRIDGE_TIMEOUT", 30000); }
static int require_real(void) {
#if TARGET_OS_OSX
    int dflt = 0;
#else
    int dflt = kl_steam_has_backend();
#endif
    return kl_env_on("KL_STEAM_REQUIRE_REAL", dflt);
}
static int stats_dry_run(void) { return kl_env_on("KL_STEAM_STATS_DRYRUN", 0); }
static const char *bridge_where(void) {
#if TARGET_OS_OSX
    extern const char *kl_steam_bridge_socket_path(void);
    if (!kl_steam_has_backend()) return kl_steam_bridge_socket_path();
#endif
    return kl_steam_has_backend() ? "the app's Steam service" : "no Steam service in this build";
}

// One round trip, parsed. NULL if the bridge did not answer or the answer is
// not JSON; *why says which. The caller checks "ok".
static kj *bridge(const char *req, int timeout_ms, const char **why) {
    char *resp = malloc(BRIDGE_RESP_CAP);
    if (!resp) { if (why) *why = "out of memory"; return NULL; }
    int n = kl_steam_backend_call(req, resp, BRIDGE_RESP_CAP, timeout_ms);
    kj *j = n >= 0 ? kj_parse(resp) : NULL;
    if (why) *why = n < 0 ? "no answer" : !j ? "an answer that is not JSON" : NULL;
    if (n >= 0 && !j && kl_env_on("KL_TRACE_STEAM", 0))
        fprintf(stderr, "  [steam] bridge answered: %.200s\n", resp);
    free(resp);
    return j;
}
static const char *bridge_error(const kj *j) {
    const char *e = kj_str(kj_get(j, "error"), NULL);
    return e ? e : "ok:false";
}

// ---- playing ----
// Steam's "In-game: <app>" for the run. On at a successful real init; off at
// SteamAPI_Shutdown, at exit, and on the app's own teardown (kl_steam_shutdown).
// A run that dies without any of those (a crash, a kill) is covered by the
// service: on the Mac the bridge connection is the run (kl_steam_bridge.c), and
// `steamdepot serve` clears "playing" when it closes.
static atomic_int g_playing;
static char g_off_req[96];
static void playing_on(void) {
    char req[96];
    snprintf(req, sizeof req, "{\"op\":\"playing\",\"app\":%u,\"on\":true}", APP_ID);
    snprintf(g_off_req, sizeof g_off_req, "{\"op\":\"playing\",\"app\":%u,\"on\":false}", APP_ID);
    const char *why;
    kj *j = bridge(req, 5000, &why);
    if (j && kj_is_true(kj_get(j, "ok"))) {
        atomic_store(&g_playing, 1);
        fprintf(stderr, "  [steam] playing on: Steam shows app %u as in-game\n", APP_ID);
        static int hooked;
        if (!hooked) { hooked = 1; atexit(kl_steam_shutdown); }
    } else {
        fprintf(stderr, "  [steam] playing on: not announced (%s)\n", j ? bridge_error(j) : why);
    }
    kj_free(j);
}
void kl_steam_shutdown(void) {
    if (!atomic_exchange(&g_playing, 0)) return;
    const char *why;
    kj *j = bridge(g_off_req, 2000, &why);
    fprintf(stderr, "  [steam] playing off: %s\n",
            j && kj_is_true(kj_get(j, "ok")) ? "Steam no longer shows the game" : j ? bridge_error(j) : why);
    kj_free(j);
}

// ---- ISteamUserStats: a cache of the real values, and every call NAMED --------------------
//
// With the bridge: SteamAPI_Init loads the account's stats and achievements
// (`stats`) BEFORE it queues UserStatsReceived_t, so every Get* answers from
// real values. Set* changes the cache. StoreStats sends ONE `store` with only
// what changed since the last one, off the game thread, and then posts
// UserStatsStored_t and a UserAchievementStored_t per achievement sent.
// ClearAchievement, ResetAllStats and UpdateAvgRateStat stay local: the
// contract has no way to say them, and nothing a test run does should take an
// achievement away from the account.
//
// Without it (the stub): the same cache, empty at start and never sent.
//
// Either way every distinct call is logged once with its arguments under
// "[steam-stats]" — the list of stats and achievements each game uses.
//
// Display attributes (name, desc, hidden) come from Steam's schema in the game
// language (`stats` with "lang"); without a bridge they answer "".
//
// Callback structs are pack(4) on Linux/Android (VALVE_CALLBACK_PACK_SMALL).
#pragma pack(push, 4)
typedef struct { uint64_t game; int32_t result; uint64_t user; } st_stats_received;   // 1101
typedef struct { uint64_t game; int32_t result; } st_stats_stored;                   // 1102
typedef struct { uint64_t game; uint8_t group; char name[128];
                 uint32_t cur, max; } st_ach_stored;                                 // 1103
typedef struct { uint64_t call; int32_t id; uint32_t n; } st_call_completed;          // 703
#pragma pack(pop)
#define EResultOK   1
#define EResultFail 2

typedef struct { char *name; int is_float, from_steam; double v, sent; } kstat;
typedef struct { char *name; int from_steam, unlocked, sent; uint32_t time;
                 char *dname, *ddesc; int hidden; } kach;   // display: Steam's schema, in the game language
static kstat *g_st;
static kach *g_ach;
static int g_nst, g_nach, g_capst, g_capach;
static int g_nach_steam;              // g_ach[0..n) came from Steam, in its order
static int g_stats_result = EResultOK;
static pthread_mutex_t g_smu = PTHREAD_MUTEX_INITIALIZER;

static kstat *stat_find(const char *n, int create, int is_float) {    // g_smu held
    if (!n) return NULL;
    for (int i = 0; i < g_nst; i++) if (!strcmp(g_st[i].name, n)) return &g_st[i];
    if (!create) return NULL;
    if (g_nst == g_capst) {
        int cap = g_capst ? g_capst * 2 : 32;
        kstat *p = realloc(g_st, (size_t)cap * sizeof *p);
        if (!p) return NULL;
        g_st = p; g_capst = cap;
    }
    kstat *s = &g_st[g_nst++];
    *s = (kstat){ strdup(n), is_float, 0, 0, 0 };
    return s;
}
static kach *ach_find(const char *n, int create) {                     // g_smu held
    if (!n) return NULL;
    for (int i = 0; i < g_nach; i++) if (!strcmp(g_ach[i].name, n)) return &g_ach[i];
    if (!create) return NULL;
    if (g_nach == g_capach) {
        int cap = g_capach ? g_capach * 2 : 64;
        kach *p = realloc(g_ach, (size_t)cap * sizeof *p);
        if (!p) return NULL;
        g_ach = p; g_capach = cap;
    }
    kach *a = &g_ach[g_nach++];
    *a = (kach){ strdup(n), 0, 0, 0, 0 };
    return a;
}

// Logged once per distinct call + arguments; `result` is how it was answered.
static void stats_note(const char *what, const char *name, const char *val, const char *result) {
    static char seen[512][160];
    static int nseen;
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    char key[160];
    snprintf(key, sizeof key, "%s(%s%s%s)", what, name ? name : "", val ? ", " : "", val ? val : "");
    pthread_mutex_lock(&mu);
    for (int i = 0; i < nseen; i++) if (!strcmp(seen[i], key)) { pthread_mutex_unlock(&mu); return; }
    if (nseen < 512) snprintf(seen[nseen++], sizeof seen[0], "%s", key);
    pthread_mutex_unlock(&mu);
    fprintf(stderr, "  [steam-stats] %s -> %s\n", key, result);
}
#define LOCAL_ONLY "ok (local only, not sent to Steam)"
#define CACHED     "ok (cached; goes to Steam with the next StoreStats)"

static void stats_load(void) {
    char req[128];
    // "lang": the achievement texts ("display") come back in the game's
    // language, which is what GetAchievementDisplayAttribute and the unlock
    // toast show.
    snprintf(req, sizeof req, "{\"op\":\"stats\",\"app\":%u,\"lang\":\"%s\"}", APP_ID, steam_lang());
    const char *why;
    kj *j = bridge(req, bridge_timeout(), &why);
    if (!j || !kj_is_true(kj_get(j, "ok"))) {
        g_stats_result = EResultFail;
        fprintf(stderr, "  [steam-stats] could not load stats from Steam (%s): UserStatsReceived_t will say "
                "k_EResultFail; writes are still cached and sent\n", j ? bridge_error(j) : why);
        kj_free(j);
        return;
    }
    int offline = kj_is_true(kj_get(j, "offline")), unlocked = 0;
    pthread_mutex_lock(&g_smu);
    kj *st = kj_get(j, "stats");
    for (kj *c = st && st->t == KJ_OBJ ? st->child : NULL; c; c = c->next) {
        int isf = !strcmp(kj_str(kj_get(c, "type"), "int"), "float");
        kstat *s = stat_find(c->key, 1, isf);
        if (!s) continue;
        s->is_float = isf;
        s->from_steam = 1;
        s->v = s->sent = kj_num(kj_get(c, "value"), 0);
    }
    kj *ac = kj_get(j, "achievements");
    for (kj *c = ac && ac->t == KJ_OBJ ? ac->child : NULL; c; c = c->next) {
        kach *a = ach_find(c->key, 1);
        if (!a) continue;
        a->from_steam = 1;
        a->unlocked = a->sent = kj_is_true(kj_get(c, "unlocked"));
        a->time = (uint32_t)kj_num(kj_get(c, "time"), 0);
        kj *d = kj_get(c, "display");
        if (d && d->t == KJ_OBJ) {
            const char *dn = kj_str(kj_get(d, "name"), NULL), *dd = kj_str(kj_get(d, "desc"), NULL);
            if (dn && !a->dname) a->dname = strdup(dn);
            if (dd && !a->ddesc) a->ddesc = strdup(dd);
            a->hidden = kj_is_true(kj_get(d, "hidden"));
        }
        unlocked += a->unlocked;
    }
    g_nach_steam = g_nach;
    fprintf(stderr, "  [steam-stats] loaded from Steam%s: %d stat(s), %d achievement(s), %d unlocked\n",
            offline ? " (offline: the service's cache)" : "", g_nst, g_nach, unlocked);
    for (int i = 0; i < g_nach; i++) {
        char when[32] = "";
        if (g_ach[i].unlocked && g_ach[i].time) {
            time_t t = (time_t)g_ach[i].time;
            struct tm tm;
            gmtime_r(&t, &tm);
            strftime(when, sizeof when, " %Y-%m-%d %H:%M UTC", &tm);
        }
        fprintf(stderr, "  [steam-stats]   %-32s %s%s\n", g_ach[i].name,
                g_ach[i].unlocked ? "unlocked" : "locked", when);
    }
    if (kl_env_on("KL_TRACE_STEAM", 0))
        for (int i = 0; i < g_nst; i++)
            fprintf(stderr, "  [steam-stats]   stat %-27s %g%s\n", g_st[i].name, g_st[i].v,
                    g_st[i].is_float ? " (float)" : "");
    pthread_mutex_unlock(&g_smu);
    kj_free(j);
}

static int account_init(char *err, size_t n) {
    char req[64];
    snprintf(req, sizeof req, "{\"op\":\"hello\",\"app\":%u}", APP_ID);
    const char *why;
    kj *j = bridge(req, bridge_timeout(), &why);
    uint64_t sid = j ? kj_u64(kj_get(j, "steamid"), 0) : 0;
    if (!j || !kj_is_true(kj_get(j, "ok")) || !sid) {
        const char *what = !j ? why : !kj_is_true(kj_get(j, "ok")) ? bridge_error(j) : "no steamid in the answer";
        if (require_real()) {
            snprintf(err, n, "no Steam: the Steam bridge (%s) did not answer hello (%s), and "
                     "KL_STEAM_REQUIRE_REAL is on", bridge_where(), what);
            kj_free(j);
            return 2;                                     // k_ESteamAPIInitResult_NoSteamClient
        }
        fprintf(stderr,
                "  [steam] !!! ============================================================\n"
                "  [steam] !!! NO REAL STEAM: the bridge (%s) did not answer hello (%s).\n"
                "  [steam] !!! Falling back to the STUB: fake user %llu, app %u owned,\n"
                "  [steam] !!! stats and achievements local only. Run `steamdepot serve`\n"
                "  [steam] !!! for the real account; KL_STEAM_REQUIRE_REAL=1 makes this fatal.\n"
                "  [steam] !!! ============================================================\n",
                bridge_where(), what, (unsigned long long)USER_ID, APP_ID);
        kj_free(j);
        return 0;
    }
    g_acct.steamid = sid;
    snprintf(g_acct.name, sizeof g_acct.name, "%s", kj_str(kj_get(j, "name"), ""));
    g_acct.owned = kj_is_true(kj_get(j, "owned"));
    g_acct.offline = kj_is_true(kj_get(j, "offline"));
    g_acct.real = 1;
    kj_free(j);
    fprintf(stderr, "  [steam] bridge (%s): hello -> steamid %s, name \"%s\", app %u %s%s\n",
            bridge_where(), kl_mask_sid(g_acct.steamid), g_acct.name, APP_ID,
            g_acct.owned ? "OWNED" : "NOT OWNED", g_acct.offline ? " (offline: cached answer)" : "");
    if (getenv("KL_STEAM_ID") || getenv("KL_STEAM_NAME"))
        fprintf(stderr, "  [steam] KL_STEAM_ID/KL_STEAM_NAME override the account's: reporting user %llu \"%s\"\n",
                (unsigned long long)USER_ID, steam_persona());
    if (!g_acct.owned) {
        snprintf(err, n, "app %u is not owned by this Steam account (%s, %llu)", APP_ID, g_acct.name,
                 (unsigned long long)g_acct.steamid);
        return 1;                                         // k_ESteamAPIInitResult_FailedGeneric
    }
    stats_load();
    playing_on();
    return 0;
}

static void stats_received(void) {
    st_stats_received r = { APP_ID, g_stats_result, USER_ID };
    post(1101, &r, sizeof r, 0);
}

static int ss_get_i(void *s, const char *n, int32_t *v) {
    (void)s;
    pthread_mutex_lock(&g_smu);
    kstat *st = stat_find(n, 0, 0);
    int32_t x = st ? (int32_t)st->v : 0;
    int steam = st && st->from_steam;
    pthread_mutex_unlock(&g_smu);
    if (v) *v = x;
    char r[96];
    snprintf(r, sizeof r, "%d (%s)", x, steam ? "from Steam" : g_acct.real ? "not in Steam's list: 0" : "stub");
    stats_note("GetStat", n, NULL, r);
    return 1;
}
static int ss_get_f(void *s, const char *n, float *v) {
    (void)s;
    pthread_mutex_lock(&g_smu);
    kstat *st = stat_find(n, 0, 1);
    float x = st ? (float)st->v : 0;
    int steam = st && st->from_steam;
    pthread_mutex_unlock(&g_smu);
    if (v) *v = x;
    char r[96];
    snprintf(r, sizeof r, "%g (%s)", x, steam ? "from Steam" : g_acct.real ? "not in Steam's list: 0" : "stub");
    stats_note("GetStat", n, NULL, r);
    return 1;
}
static void stat_set(const char *n, double v, int is_float) {
    pthread_mutex_lock(&g_smu);
    kstat *st = stat_find(n, 1, is_float);
    int known = st && st->from_steam;
    if (st) st->v = v;
    pthread_mutex_unlock(&g_smu);
    char b[32];
    snprintf(b, sizeof b, "%g", v);
    stats_note("SetStat", n, b, !g_acct.real ? LOCAL_ONLY : known ? CACHED : CACHED " — not in Steam's list");
}
static int  ss_set_i(void *s, const char *n, int32_t v) { (void)s; stat_set(n, v, 0); return 1; }
static int  ss_set_f(void *s, const char *n, float v)   { (void)s; stat_set(n, v, 1); return 1; }
static int  ss_avg(void *s, const char *n, float v, double len) {
    (void)s; char b[48]; snprintf(b, sizeof b, "%g over %g", v, len);
    stats_note("UpdateAvgRateStat", n, b, LOCAL_ONLY);
    return 1;
}
static int  ach_get(const char *what, const char *n, uint8_t *got, uint32_t *t) {
    pthread_mutex_lock(&g_smu);
    kach *a = ach_find(n, 0);
    int u = a && a->unlocked, steam = a && a->from_steam;
    uint32_t when = a ? a->time : 0;
    pthread_mutex_unlock(&g_smu);
    if (got) *got = (uint8_t)u;
    if (t) *t = u ? when : 0;
    stats_note(what, n, NULL, u ? (steam ? "unlocked (from Steam)" : "unlocked (this run)")
                                : (steam ? "locked (from Steam)" : g_acct.real ? "locked (not in Steam's list)" : "locked (stub)"));
    return 1;
}
static int  ss_get_ach(void *s, const char *n, uint8_t *got) { (void)s; return ach_get("GetAchievement", n, got, NULL); }
static int  ss_get_ach_t(void *s, const char *n, uint8_t *got, uint32_t *t) {
    (void)s; return ach_get("GetAchievementAndUnlockTime", n, got, t);
}
static int  ss_set_ach(void *s, const char *n) {
    (void)s;
    pthread_mutex_lock(&g_smu);
    kach *a = ach_find(n, 1);
    int already = a && a->unlocked, known = a && a->from_steam;
    if (a && !a->unlocked) { a->unlocked = 1; a->time = (uint32_t)time(NULL); }
    pthread_mutex_unlock(&g_smu);
    stats_note("SetAchievement", n, NULL, already ? "ok (already unlocked)" : !g_acct.real ? LOCAL_ONLY
               : known ? CACHED : CACHED " — not in Steam's list");
    return 1;
}
static int  ss_clear_ach(void *s, const char *n) {
    (void)s;
    pthread_mutex_lock(&g_smu);
    kach *a = ach_find(n, 0);
    if (a) a->unlocked = 0;          // `sent` stays: setting it again sends nothing
    pthread_mutex_unlock(&g_smu);
    stats_note("ClearAchievement", n, NULL, LOCAL_ONLY);
    return 1;
}
static int  ss_progress(void *s, const char *n, uint32_t cur, uint32_t max) {
    (void)s; char b[32]; snprintf(b, sizeof b, "%u/%u", cur, max);
    stats_note("IndicateAchievementProgress", n, b, "ok (progress toast only)");
    st_ach_stored r = { APP_ID, 0, {0}, cur, max };
    snprintf(r.name, sizeof r.name, "%s", n ? n : "");
    post(1103, &r, sizeof r, 0);
    return 1;
}

// One StoreStats, as sent: the request, what went into it (for the log and the
// callbacks), and how to put the cache back if it does not get through.
typedef struct { int idx; double was, now; } st_rev;
typedef struct {
    char *req, *summary;
    int nst; st_rev *st;
    int nach; int *ach;
} store_job;
static pthread_mutex_t g_store_mu = PTHREAD_MUTEX_INITIALIZER;

// The store's "unlocked" list -> the app's toast (kl_steam_set_unlock_handler).
// Each icon is fetched through the bridge's `icon` op first, so the handler is
// handed a local file. Without a handler the unlock is only logged; KL_TOAST=0
// skips the whole thing (no icon fetches either).
static void notify_unlocks(const kj *j) {
    kj *ul = kj_get(j, "unlocked");
    if (!ul || ul->t != KJ_ARR || !ul->child || !kl_env_on("KL_TOAST", 1)) return;
    kl_steam_unlock_fn fn = kl_steam_unlock_handler();
    for (kj *e = ul->child; e; e = e->next) {
        const char *api = kj_str(kj_get(e, "api"), "");
        const char *name = kj_str(kj_get(e, "name"), api);
        const char *desc = kj_str(kj_get(e, "desc"), "");
        const char *url = kj_str(kj_get(e, "icon"), NULL);
        char path[1024] = "";
        if (url && *url && fn) {
            kjb req = {0};
            kjb_add(&req, "{\"op\":\"icon\",\"url\":");
            kjb_str(&req, url);
            kjb_add(&req, "}");
            const char *why = NULL;
            kj *ij = req.p ? bridge(req.p, kl_env_int("KL_STEAM_ICON_TIMEOUT", 10000), &why) : NULL;
            if (ij && kj_is_true(kj_get(ij, "ok")))
                snprintf(path, sizeof path, "%s", kj_str(kj_get(ij, "path"), ""));
            else
                fprintf(stderr, "  [toast] icon for %s not fetched (%s)\n", api,
                        ij ? bridge_error(ij) : why ? why : "?");
            kj_free(ij);
            kjb_free(&req);
        }
        fprintf(stderr, "  [toast] achievement unlocked%s: %s \"%s\" — %s%s%s\n",
                stats_dry_run() ? " (dry run)" : "", api, name, desc,
                path[0] ? " | icon " : "", path);
        if (fn) fn(api, name, desc, path);
    }
}

static void *store_worker(void *arg) {
    store_job *jb = arg;
    pthread_mutex_lock(&g_store_mu);             // one at a time, in the game's order
    const char *why;
    kj *j = bridge(jb->req, bridge_timeout(), &why);
    int ok = j && kj_is_true(kj_get(j, "ok"));
    int stored = ok && kj_is_true(kj_get(j, "stored")), queued = ok && kj_is_true(kj_get(j, "queued"));
    const char *how = !ok ? NULL : stats_dry_run() ? "dry run (the account was not changed)"
                    : stored ? "sent to Steam" : queued ? "queued (offline)" : "accepted, neither stored nor queued";
    fprintf(stderr, "  [steam-stats] StoreStats: %s -> %s%s\n", jb->summary, how ? how : "FAILED: ",
            how ? "" : (j ? bridge_error(j) : why));
    if (ok) {
        st_stats_stored r = { APP_ID, EResultOK };
        post(1102, &r, sizeof r, 0);
        notify_unlocks(j);
        pthread_mutex_lock(&g_smu);
        for (int i = 0; i < jb->nach; i++) {
            st_ach_stored a = { APP_ID, 0, {0}, 0, 0 };
            snprintf(a.name, sizeof a.name, "%s", g_ach[jb->ach[i]].name);
            post(1103, &a, sizeof a, 0);
        }
        pthread_mutex_unlock(&g_smu);
    } else {
        // Not through: what this store carried is "changed" again, unless the
        // game has changed it since (then it is changed anyway).
        pthread_mutex_lock(&g_smu);
        for (int i = 0; i < jb->nst; i++)
            if (g_st[jb->st[i].idx].sent == jb->st[i].now) g_st[jb->st[i].idx].sent = jb->st[i].was;
        for (int i = 0; i < jb->nach; i++) g_ach[jb->ach[i]].sent = 0;
        pthread_mutex_unlock(&g_smu);
        st_stats_stored r = { APP_ID, EResultFail };
        post(1102, &r, sizeof r, 0);
    }
    pthread_mutex_unlock(&g_store_mu);
    kj_free(j);
    free(jb->req); free(jb->summary); free(jb->st); free(jb->ach); free(jb);
    return NULL;
}

static int  ss_store(void *s) {
    (void)s;
    if (!g_acct.real) {
        stats_note("StoreStats", NULL, NULL, LOCAL_ONLY);
        st_stats_stored r = { APP_ID, EResultOK };
        post(1102, &r, sizeof r, 0);
        return 1;
    }
    kjb req = {0}, sum = {0};
    store_job *jb = calloc(1, sizeof *jb);
    pthread_mutex_lock(&g_smu);
    jb->st = calloc((size_t)g_nst + 1, sizeof *jb->st);
    jb->ach = calloc((size_t)g_nach + 1, sizeof *jb->ach);
    kjb_fmt(&req, "{\"op\":\"store\",\"app\":%u,\"stats\":{", APP_ID);
    for (int i = 0; i < g_nst; i++) {
        kstat *st = &g_st[i];
        if (st->v == st->sent) continue;
        if (jb->nst) kjb_add(&req, ",");
        kjb_str(&req, st->name);
        if (st->is_float) kjb_fmt(&req, ":%.9g", st->v);
        else kjb_fmt(&req, ":%d", (int32_t)st->v);
        kjb_fmt(&sum, "%s%s=%g", sum.n ? ", " : "", st->name, st->v);
        jb->st[jb->nst++] = (st_rev){ i, st->sent, st->v };
        st->sent = st->v;
    }
    kjb_add(&req, "},\"achievements\":{");
    for (int i = 0; i < g_nach; i++) {
        kach *a = &g_ach[i];
        if (!a->unlocked || a->sent) continue;
        if (jb->nach) kjb_add(&req, ",");
        kjb_str(&req, a->name);
        kjb_add(&req, ":true");
        kjb_fmt(&sum, "%s%s unlocked", sum.n ? ", " : "", a->name);
        jb->ach[jb->nach++] = i;
        a->sent = 1;
    }
    pthread_mutex_unlock(&g_smu);
    kjb_fmt(&req, "},\"dry_run\":%s,\"lang\":", stats_dry_run() ? "true" : "false");
    kjb_str(&req, steam_lang());
    kjb_add(&req, "}");
    if (!jb->nst && !jb->nach) {
        stats_note("StoreStats", NULL, NULL, "ok (nothing changed since the last store: nothing sent)");
        st_stats_stored r = { APP_ID, EResultOK };
        post(1102, &r, sizeof r, 0);
        kjb_free(&req); kjb_free(&sum);
        free(jb->st); free(jb->ach); free(jb);
        return 1;
    }
    jb->req = req.p;
    jb->summary = sum.p;
    if (kl_env_on("KL_TRACE_STEAM", 0)) fprintf(stderr, "  [steam-stats] store request: %s\n", jb->req);
    // Off the game thread: Steam's StoreStats is asynchronous, and the round
    // trip can take as long as the service's logon.
    pthread_t th;
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&th, &at, store_worker, jb) != 0) store_worker(jb);
    pthread_attr_destroy(&at);
    return 1;
}
static int  ss_reset(void *s, uint8_t ach) {
    (void)s;
    stats_note("ResetAllStats", NULL, ach ? "and achievements" : "stats only",
               "ok (NOT done: never sent to Steam, cached values kept)");
    return 1;
}
static uint32_t ss_num_ach(void *s) {
    (void)s;
    pthread_mutex_lock(&g_smu); uint32_t n = (uint32_t)g_nach_steam; pthread_mutex_unlock(&g_smu);
    return n;
}
static const char *ss_ach_name(void *s, uint32_t i) {
    (void)s;
    pthread_mutex_lock(&g_smu);
    const char *n = i < (uint32_t)g_nach_steam ? g_ach[i].name : "";
    pthread_mutex_unlock(&g_smu);
    return n;
}
// "name", "desc" and "hidden" from Steam's schema in the game language (the
// `stats` load asks with "lang"); "" for anything else, or with no bridge. The
// strings are owned by the cache and never freed, so the pointer stays valid.
static const char *ss_ach_attr(void *s, const char *n, const char *k) {
    (void)s;
    const char *r = "";
    pthread_mutex_lock(&g_smu);
    kach *a = ach_find(n, 0);
    if (a && k) {
        if (!strcmp(k, "name") && a->dname) r = a->dname;
        else if (!strcmp(k, "desc") && a->ddesc) r = a->ddesc;
        else if (!strcmp(k, "hidden")) r = a->hidden ? "1" : "0";
    }
    pthread_mutex_unlock(&g_smu);
    stats_note("GetAchievementDisplayAttribute", n, k, *r ? "from Steam's schema" : "\"\" (no display data)");
    return r;
}
// RequestUserStats / RequestCurrentStats (pre-1.61): answer with the same
// UserStatsReceived_t init already queued, as a call result for the former.
static uint64_t ss_request_user(void *s, uint64_t user) {
    (void)s; st_stats_received r = { APP_ID, user == USER_ID ? g_stats_result : EResultFail, user };
    return post(1101, &r, sizeof r, 1);
}
static int  ss_request_current(void *s) { (void)s; stats_received(); return 1; }

// ---- the implemented slots -----------------------------------------------------------------------------
#define I(ver, m, f) { ver, m, 0, (void *)(f) }
#define I2(ver, m, n, f) { ver, m, n, (void *)(f) }
#define CLV "SteamClient023"
#define USV "SteamUser023"
#define GSV "SteamGameServer015"
#define UTV "SteamUtils011"
#define APV "STEAMAPPS_INTERFACE_VERSION009"
#define FRV "SteamFriends018"
#define NSV "SteamNetworkingSockets013"
#define NUV "SteamNetworkingUtils004"
#define SSV "STEAMUSERSTATS_INTERFACE_VERSION013"
static const impl g_impl[] = {
    I(CLV, "CreateSteamPipe", cl_pipe), I(CLV, "BReleaseSteamPipe", cl_true),
    I(CLV, "ConnectToGlobalUser", cl_user), I(CLV, "BShutdownIfAllPipesClosed", cl_true),
    I(CLV, "GetISteamUser", cl_get3), I(CLV, "GetISteamGameServer", cl_get3),
    I(CLV, "GetISteamFriends", cl_get3), I(CLV, "GetISteamUtils", cl_get2),
    I(CLV, "GetISteamMatchmaking", cl_get3), I(CLV, "GetISteamMatchmakingServers", cl_get3),
    I(CLV, "GetISteamGenericInterface", cl_get3), I(CLV, "GetISteamUserStats", cl_get3),
    I(CLV, "GetISteamGameServerStats", cl_get3), I(CLV, "GetISteamApps", cl_get3),
    I(CLV, "GetISteamNetworking", cl_get3), I(CLV, "GetISteamRemoteStorage", cl_get3),
    I(CLV, "GetISteamScreenshots", cl_get3), I(CLV, "GetISteamHTTP", cl_get3),
    I(CLV, "GetISteamController", cl_get3), I(CLV, "GetISteamUGC", cl_get3),
    I(CLV, "GetISteamMusic", cl_get3), I(CLV, "GetISteamHTMLSurface", cl_get3),
    I(CLV, "GetISteamInventory", cl_get3), I(CLV, "GetISteamVideo", cl_get3),
    I(CLV, "GetISteamParentalSettings", cl_get3), I(CLV, "GetISteamInput", cl_get3),
    I(CLV, "GetISteamParties", cl_get3), I(CLV, "GetISteamRemotePlay", cl_get3),

    I(USV, "GetHSteamUser", us_hsteamuser), I(USV, "BLoggedOn", us_true),
    I(USV, "GetSteamID", us_steamid), I(USV, "GetUserDataFolder", us_userdata_folder),
    I(USV, "GetPlayerSteamLevel", us_level), I(USV, "GetGameBadgeLevel", us_false),
    I(USV, "UserHasLicenseForApp", us_license), I(USV, "BIsBehindNAT", us_false),
    I(USV, "GetAuthSessionTicket", us_ticket), I(USV, "BeginAuthSession", us_begin_auth),
    I(USV, "BIsPhoneVerified", us_true), I(USV, "BIsTwoFactorEnabled", us_true),

    I(GSV, "BLoggedOn", us_true), I(GSV, "BSecure", us_false), I(GSV, "GetSteamID", gs_steamid),
    I(GSV, "InitGameServer", us_true), I(GSV, "WasRestartRequested", us_false),
    I(GSV, "GetAuthSessionTicket", us_ticket), I(GSV, "BeginAuthSession", us_begin_auth),
    I(GSV, "UserHasLicenseForApp", us_license), I(GSV, "BUpdateUserData", us_true),

    I(UTV, "GetAppID", ut_appid), I(UTV, "GetServerRealTime", ut_time),
    I(UTV, "GetIPCountry", ut_country), I(UTV, "GetSteamUILanguage", ut_lang),
    I(UTV, "GetConnectedUniverse", ut_universe), I(UTV, "GetCurrentBatteryPower", ut_battery),
    I(UTV, "IsAPICallCompleted", ut_call_done), I(UTV, "GetAPICallResult", ut_call_result),

    I(APV, "BIsSubscribed", ap_true), I(APV, "BIsLowViolence", ap_false),
    I(APV, "BIsCybercafe", ap_false), I(APV, "BIsVACBanned", ap_false),
    I(APV, "GetCurrentGameLanguage", ap_lang), I(APV, "GetAvailableGameLanguages", ap_lang),
    I(APV, "BIsSubscribedApp", ap_subscribed_app), I(APV, "BIsAppInstalled", ap_installed),
    I(APV, "GetEarliestPurchaseUnixTime", ap_purchase), I(APV, "GetCurrentBetaName", ap_beta),
    I(APV, "GetAppInstallDir", ap_install_dir), I(APV, "GetAppOwner", ap_owner),
    I(APV, "GetLaunchQueryParam", ap_empty), I(APV, "GetAppBuildId", ap_build),
    I(APV, "GetLaunchCommandLine", ap_cmdline),

    I("SteamNetworking006", "GetMaxPacketSize", nw_max_packet),
    I(FRV, "GetPersonaName", fr_name), I(FRV, "GetPersonaState", fr_state),
    I(FRV, "GetFriendPersonaName", fr_friend_name), I(FRV, "GetFriendCount", fr_zero),

    I(NSV, "CreateListenSocketIP", ns_listen_ip), I(NSV, "ConnectByIPAddress", ns_connect_ip),
    I(NSV, "CreateListenSocketP2P", ns_listen_p2p), I(NSV, "ConnectP2P", ns_connect_p2p),
    I(NSV, "AcceptConnection", ns_accept), I(NSV, "CloseConnection", ns_close),
    I(NSV, "CloseListenSocket", ns_close_listen),
    I(NSV, "SetConnectionUserData", ns_set_ud), I(NSV, "GetConnectionUserData", ns_get_ud),
    I(NSV, "SetConnectionName", ns_set_name), I(NSV, "GetConnectionName", ns_get_name),
    I(NSV, "SendMessageToConnection", ns_send), I(NSV, "SendMessages", ns_send_many),
    I(NSV, "FlushMessagesOnConnection", ns_flush),
    I(NSV, "ReceiveMessagesOnConnection", ns_recv), I(NSV, "GetConnectionInfo", ns_info),
    I(NSV, "GetConnectionRealTimeStatus", ns_status),
    I(NSV, "GetDetailedConnectionStatus", ns_detailed),
    I(NSV, "GetListenSocketAddress", ns_listen_addr), I(NSV, "CreateSocketPair", ns_pair),
    I(NSV, "ConfigureConnectionLanes", ns_lanes), I(NSV, "GetIdentity", ns_identity),
    I(NSV, "InitAuthentication", ns_avail), I(NSV, "GetAuthenticationStatus", ns_auth_status),
    I(NSV, "CreatePollGroup", ns_poll_create), I(NSV, "DestroyPollGroup", ns_poll_destroy),
    I(NSV, "SetConnectionPollGroup", ns_set_poll),
    I(NSV, "ReceiveMessagesOnPollGroup", ns_recv_poll), I(NSV, "RunCallbacks", ns_run_callbacks),

    I2(SSV, "GetStat", 0, ss_get_i), I2(SSV, "GetStat", 1, ss_get_f),
    I2(SSV, "SetStat", 0, ss_set_i), I2(SSV, "SetStat", 1, ss_set_f),
    I(SSV, "UpdateAvgRateStat", ss_avg), I(SSV, "GetAchievement", ss_get_ach),
    I(SSV, "SetAchievement", ss_set_ach), I(SSV, "ClearAchievement", ss_clear_ach),
    I(SSV, "GetAchievementAndUnlockTime", ss_get_ach_t), I(SSV, "StoreStats", ss_store),
    I(SSV, "GetAchievementDisplayAttribute", ss_ach_attr),
    I(SSV, "IndicateAchievementProgress", ss_progress), I(SSV, "GetNumAchievements", ss_num_ach),
    I(SSV, "GetAchievementName", ss_ach_name),
    I(SSV, "RequestUserStats", ss_request_user), I(SSV, "ResetAllStats", ss_reset),
    I(SSV, "RequestCurrentStats", ss_request_current),

    I(NUV, "AllocateMessage", nu_alloc), I(NUV, "GetRelayNetworkStatus", nu_relay),
    I(NUV, "CheckPingDataUpToDate", nu_true), I(NUV, "GetLocalTimestamp", nu_time),
    I(NUV, "SetDebugOutputFunction", nu_debug), I(NUV, "SetConfigValue", nu_set_config),
    I(NUV, "GetConfigValue", nu_get_config), I(NUV, "GetConfigValueInfo", nu_config_info),
    I(NUV, "IterateGenericEditableConfigValues", nu_iterate),
    I(NUV, "SteamNetworkingIPAddr_ToString", nu_addr_tostr),
    I(NUV, "SteamNetworkingIPAddr_ParseString", nu_addr_parse),
    I(NUV, "SteamNetworkingIPAddr_GetFakeIPType", nu_zero),
    I(NUV, "SteamNetworkingIdentity_ToString", nu_id_tostr),
    I(NUV, "SteamNetworkingIdentity_ParseString", nu_id_parse),
};
static const int g_nimpl = (int)(sizeof g_impl / sizeof *g_impl);

// ---- interface construction ------------------------------------------------------------
static long steam_unimpl(const char *name) {
    static struct { const char *n; unsigned c; } seen[512];
    static unsigned ns;
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mu);
    unsigned i = 0;
    for (; i < ns; i++) if (seen[i].n == name) break;
    if (i == ns && ns < 512) { seen[ns].n = name; seen[ns].c = 0; ns++; }
    unsigned c = i < 512 ? seen[i].c++ : 99;
    pthread_mutex_unlock(&mu);
    if (c < 3) fprintf(stderr, "  [steam] %s: not implemented -> 0\n", name);
    return 0;
}

// An OLDER version of an implemented interface takes the newer one's
// implementations BY METHOD NAME. Only the slot ORDER differs between versions
// (kl_steam_vtables.h has a row for each), and a method that keeps its name
// keeps its signature in every SDK this has been checked against — the
// implemented ones above are all plain getters. Metro Awakening (SDK 1.60) is
// the guest that asks for these.
static const struct { const char *old, *cur; } g_alias[] = {
    { "SteamClient021",                 CLV },
    { "SteamUtils010",                  UTV },
    { "SteamFriends017",                FRV },
    { "STEAMAPPS_INTERFACE_VERSION008", APV },
    { "STEAMUSERSTATS_INTERFACE_VERSION012", SSV },
    { "SteamNetworkingSockets012",      NSV },
};

static void *impl_for(const char *ver, const char *method, int nth) {
    for (size_t a = 0; a < sizeof g_alias / sizeof *g_alias; a++)
        if (!strcmp(ver, g_alias[a].old)) { ver = g_alias[a].cur; break; }
    for (int i = 0; i < g_nimpl; i++)
        if (!strcmp(g_impl[i].ver, ver) && !strcmp(g_impl[i].method, method) &&
            g_impl[i].nth == nth)
            return g_impl[i].fn;
    return NULL;
}

static sobj *iface(const char *ver) {
    if (!ver) return NULL;
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < g_nobjs; i++)
        if (!strcmp(g_objs[i]->ver, ver)) { pthread_mutex_unlock(&g_mu); return g_objs[i]; }
    const iface_desc *d = NULL;
    for (size_t i = 0; i < sizeof g_desc / sizeof *g_desc; i++)
        if (!strcmp(g_desc[i].ver, ver)) d = &g_desc[i];
    int n = 0;
    if (d) while (d->slots[n]) n++;
    else n = 128;
    sobj *o = calloc(1, sizeof *o);
    o->ver = strdup(ver);
    o->desc = d;
    o->vt = calloc((size_t)n + 1, sizeof *o->vt);
    for (int s = 0; s < n; s++) {
        void *fn = NULL;
        if (d) {
            int nth = 0;                          // which overload of this name
            for (int k = 0; k < s; k++) if (!strcmp(d->slots[k], d->slots[s])) nth++;
            fn = impl_for(ver, d->slots[s], nth);
        }
        if (!fn) {
            char nm[200];
            snprintf(nm, sizeof nm, "%s::%s (#%d)", ver, d ? d->slots[s] : "?", s);
            fn = kl_named_stub(nm, (void *)steam_unimpl);
        }
        o->vt[s] = fn;
    }
    if (g_nobjs < 64) g_objs[g_nobjs++] = o;
    pthread_mutex_unlock(&g_mu);
    fprintf(stderr, "  [steam] interface %s -> %p (%s, %d slots)\n", ver, (void *)o,
            d ? d->cls : "not in the SDK: every slot a logging stub", n);
    return o;
}

// ---- manual dispatch (Steamworks.NET) ------------------------------------------------------
//
// The C++ games here register CCallback objects and pump SteamAPI_RunCallbacks.
// Steamworks.NET (every Unity title: SUPERHOT VR's Frame build) does not: it
// calls SteamAPI_ManualDispatch_Init once, then every frame RunFrame and a
// GetNextCallback / FreeLastCallback loop that hands it CallbackMsg_t records,
// and it fetches call results itself with GetAPICallResult after the
// SteamAPICallCompleted_t (703) that announces each one. Same queue as the
// C++ pump (g_posted), drained the other way.
typedef struct { int32_t user; int32_t id; uint8_t *param; int32_t n; } st_cbmsg;   // CallbackMsg_t
static void *g_md_last;                      // the record FreeLastCallback releases
static st_call_completed g_md_completed;     // storage for a 703's payload
static void md_init(void) { fprintf(stderr, "  [steam] ManualDispatch_Init (Steamworks.NET dispatch)\n"); }
static void md_run_frame(int pipe) { (void)pipe; net_dispatch(); }
static int  md_next(int pipe, st_cbmsg *msg) {
    (void)pipe;
    int got = 0;
    pthread_mutex_lock(&g_cbmu);
    for (int i = 0; i < g_nposted && !got; i++) {
        posted *p = &g_posted[i];
        if (p->call && p->announced) continue;
        if (p->call) {
            p->announced = 1;
            g_md_completed = (st_call_completed){ p->call, p->id, (uint32_t)p->n };
            *msg = (st_cbmsg){ 1, 703, (uint8_t *)&g_md_completed, (int32_t)sizeof g_md_completed };
        } else {
            free(g_md_last);
            g_md_last = p->data;
            *msg = (st_cbmsg){ 1, p->id, p->data, (int32_t)p->n };
            memmove(p, p + 1, (size_t)(g_nposted - i - 1) * sizeof *p);
            g_nposted--;
        }
        got = 1;
    }
    pthread_mutex_unlock(&g_cbmu);
    if (got && kl_env_on("KL_TRACE_STEAM", 0))
        fprintf(stderr, "  [steam] ManualDispatch callback %d (%d bytes)\n", msg->id, msg->n);
    return got;
}
static void md_free_last(int pipe) {
    (void)pipe;
    pthread_mutex_lock(&g_cbmu);
    free(g_md_last); g_md_last = NULL;
    pthread_mutex_unlock(&g_cbmu);
}
static int  md_call_result(int pipe, uint64_t call, void *out, int cb, int expected, int *failed) {
    (void)pipe; return ut_call_result(NULL, call, out, cb, expected, failed);
}
static int  st_zero(void) { return 0; }

// ---- the FLAT API ----------------------------------------------------------------------------
//
// Steamworks.NET binds `SteamAPI_ISteamClient_GetISteamUser(self, ...)` and a
// thousand names like it by P/Invoke, i.e. dlsym off our libsteam_api handle,
// one name at a time as the managed side first calls each. A flat function is
// the C++ virtual with `this` made explicit, so each one is served by the SAME
// vtable implementation: the stub hands the call to kl_steam_flat_tramp
// (kl_steam_flat.S) with every argument register intact and the row below in
// x16; the trampoline asks kl_steam_flat_target which slot of `self`'s vtable
// that is — the object knows its interface VERSION, and the slot order is the
// version's — and tail-branches there. Overloads have distinct flat names
// (GetStatInt32 / GetStatFloat) and the row carries which overload it is.
//
// The cells are the pre-built, signed trace cells (kl_trace_stub): no code is
// generated at runtime, so this works on visionOS too.
//
// Accessors (`SteamAPI_SteamUser_v023()`, no arguments) go through the other
// trampoline, which turns the row's version string into iface(version).
typedef struct { const char *flat, *cls, *method; int nth; } flat_row;
typedef struct { const char *flat, *ver; } accessor_row;
#define KL_STEAM_FLAT(f, c, m, n) { f, c, m, n },
#define KL_STEAM_ACCESSOR(f, v)
static const flat_row g_flat_rows[] = {
#include "kl_steam_flat.h"
};
#undef KL_STEAM_FLAT
#undef KL_STEAM_ACCESSOR
#define KL_STEAM_FLAT(f, c, m, n)
#define KL_STEAM_ACCESSOR(f, v) { f, v },
static const accessor_row g_accessor_rows[] = {
#include "kl_steam_flat.h"
};
#undef KL_STEAM_FLAT
#undef KL_STEAM_ACCESSOR

extern void kl_steam_flat_tramp(void);
extern void kl_steam_accessor_tramp(void);

// Called from kl_steam_flat_tramp with the row and `self` (the guest's x0).
void *kl_steam_flat_target(const flat_row *r, sobj *self) {
    int ours = 0;
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < g_nobjs && !ours; i++) ours = g_objs[i] == self;
    pthread_mutex_unlock(&g_mu);
    if (!ours || !self->desc) {
        fprintf(stderr, "  [steam] %s on %s object %p -> 0\n", r->flat,
                ours ? "an undescribed" : "a foreign", (void *)self);
        return (void *)st_zero;
    }
    if (strcmp(self->desc->cls, r->cls) != 0)
        fprintf(stderr, "  [steam] %s called on a %s (%s) — dispatching by method name\n",
                r->flat, self->desc->cls, self->ver);
    for (int sl = 0, nth = 0; self->desc->slots[sl]; sl++)
        if (!strcmp(self->desc->slots[sl], r->method) && nth++ == r->nth)
            return self->vt[sl];
    fprintf(stderr, "  [steam] %s: %s has no such method -> 0\n", r->flat, self->ver);
    return (void *)st_zero;
}

// Called from kl_steam_accessor_tramp with the version string.
void *kl_steam_accessor_target(const char *ver) { return iface(ver); }

static void *flat_lookup(const char *name) {
    for (size_t i = 0; i < sizeof g_accessor_rows / sizeof *g_accessor_rows; i++)
        if (!strcmp(g_accessor_rows[i].flat, name))
            return kl_trace_stub(name, (void *)g_accessor_rows[i].ver,
                                 (void *)kl_steam_accessor_tramp);
    for (size_t i = 0; i < sizeof g_flat_rows / sizeof *g_flat_rows; i++)
        if (!strcmp(g_flat_rows[i].flat, name))
            return kl_trace_stub(name, (void *)&g_flat_rows[i], (void *)kl_steam_flat_tramp);
    return NULL;
}

// ---- the flat table ------------------------------------------------------------------------------------
typedef struct { const char *name; void *fn; } flat;
static const flat g_flat[] = {
    { "SteamInternal_SteamAPI_Init", (void *)st_init },
    { "SteamAPI_InitSafe", (void *)st_init_bool }, { "SteamAPI_Init", (void *)st_init_bool },
    { "SteamAPI_InitAnonymousUser", (void *)st_init_bool },
    { "SteamInternal_GameServer_Init_V2", (void *)st_gs_init },
    { "SteamAPI_Shutdown", (void *)st_shutdown }, { "SteamGameServer_Shutdown", (void *)st_void },
    { "SteamAPI_RunCallbacks", (void *)st_run_callbacks },
    { "SteamGameServer_RunCallbacks", (void *)st_run_callbacks },
    { "SteamAPI_RegisterCallback", (void *)st_register_cb },
    { "SteamAPI_UnregisterCallback", (void *)st_unregister_cb },
    { "SteamAPI_RegisterCallResult", (void *)st_register_result },
    { "SteamAPI_UnregisterCallResult", (void *)st_unregister_result },
    { "SteamAPI_GetHSteamUser", (void *)st_hsteamuser }, { "SteamAPI_GetHSteamPipe", (void *)st_hsteampipe },
    { "SteamGameServer_GetHSteamUser", (void *)st_gs_hsteamuser },
    { "SteamGameServer_GetHSteamPipe", (void *)st_hsteampipe },
    { "SteamInternal_ContextInit", (void *)st_context_init },
    { "SteamInternal_FindOrCreateUserInterface", (void *)st_find_user },
    { "SteamInternal_FindOrCreateGameServerInterface", (void *)st_find_user },
    { "SteamInternal_CreateInterface", (void *)st_create_iface },
    { "SteamAPI_IsSteamRunning", (void *)st_is_running }, { "SteamAPI_RestartAppIfNecessary", (void *)st_false },
    { "SteamAPI_SetMiniDumpComment", (void *)st_void }, { "SteamAPI_SetBreakpadAppID", (void *)st_void },
    { "SteamAPI_UseBreakpadCrashHandler", (void *)st_void },
    { "SteamAPI_SetTryCatchCallbacks", (void *)st_void },
    { "SteamAPI_WriteMiniDump", (void *)st_void },
    { "SteamGameServer_BSecure", (void *)st_false },
    { "SteamGameServer_GetSteamID", (void *)gs_steamid },
    { "SteamAPI_ManualDispatch_Init", (void *)md_init },
    { "SteamAPI_ManualDispatch_RunFrame", (void *)md_run_frame },
    { "SteamAPI_ManualDispatch_GetNextCallback", (void *)md_next },
    { "SteamAPI_ManualDispatch_FreeLastCallback", (void *)md_free_last },
    { "SteamAPI_ManualDispatch_GetAPICallResult", (void *)md_call_result },
    { "SteamAPI_ReleaseCurrentThreadMemory", (void *)st_void },
    { "SteamGameServer_ReleaseCurrentThreadMemory", (void *)st_void },
    { "SteamAPI_GetSteamInstallPath", (void *)st_install_path },
};

void *kl_steam_lookup(const char *name) {
    if (!name || (strncmp(name, "SteamAPI_", 9) && strncmp(name, "SteamInternal_", 14) &&
                  strncmp(name, "SteamGameServer_", 16)))
        return NULL;
    if (!kl_env_on("KL_STEAM_STUB", 1)) return NULL;
    for (size_t i = 0; i < sizeof g_flat / sizeof *g_flat; i++)
        if (!strcmp(g_flat[i].name, name)) return g_flat[i].fn;
    void *f = flat_lookup(name);
    if (f) return f;
    // Anything else in the flat API's namespace — the SteamNetworkingIdentity /
    // IPAddr struct helpers, the signalling objects — is a named stub that logs
    // and returns 0, not NULL: a NULL here is a managed EntryPointNotFound that
    // takes the game's whole Steam layer down with it (SUPERHOT), where a 0 is
    // an answer the caller already has a path for. Only the flat namespace:
    // the C++ guests' own SteamInternal_ / SteamAPI_ names keep the NULL that
    // lets the glibc door fall through to the guest's library.
    if (!strncmp(name, "SteamAPI_ISteam", 15) || !strncmp(name, "SteamAPI_Steam", 14))
        return kl_named_stub(name, (void *)steam_unimpl);
    return NULL;
}
