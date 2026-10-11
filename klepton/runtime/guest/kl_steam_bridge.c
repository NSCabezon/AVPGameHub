// The Steam bridge's transport — see kl_steam_bridge.h. What is SAID over it
// (hello, stats, store, playing) is kl_steam.c's business; this file only moves
// one line out and one line back.
#include "kl_steam_bridge.h"

#include <TargetConditionals.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static _Atomic(kl_steam_backend_fn) g_backend;

void kl_steam_set_backend(kl_steam_backend_fn fn) {
    atomic_store(&g_backend, fn);
    fprintf(stderr, "  [steam] bridge backend %s by the app\n", fn ? "registered" : "removed");
}
int kl_steam_has_backend(void) { return atomic_load(&g_backend) != NULL; }

static _Atomic(kl_steam_unlock_fn) g_unlock;
void kl_steam_set_unlock_handler(kl_steam_unlock_fn fn) {
    atomic_store(&g_unlock, fn);
    fprintf(stderr, "  [steam] achievement-unlock handler %s\n", fn ? "registered" : "removed");
}
kl_steam_unlock_fn kl_steam_unlock_handler(void) { return atomic_load(&g_unlock); }

// $KL_STEAM_BRIDGE, else ~/.steamdepot/bridge.sock.
const char *kl_steam_bridge_socket_path(void) {
    static char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    if (path[0]) return path;
    const char *e = getenv("KL_STEAM_BRIDGE");
    if (e && *e) snprintf(path, sizeof path, "%s", e);
    else {
        const char *home = getenv("HOME");
        snprintf(path, sizeof path, "%s/.steamdepot/bridge.sock", home && *home ? home : "/tmp");
    }
    return path;
}

#if TARGET_OS_OSX
// ONE connection for the life of the process, not one per request: the
// service ties "playing" to the connection (a client that goes away without
// saying "playing off" — a crash, a kill — is cleared when its socket closes),
// so the connection IS the run. Requests are serialised over it. A connection
// that breaks is reopened once per call, and the last "playing on" is said
// again on the new one, so a service restart does not silently end the session.
static int64_t now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static int g_fd = -1;
static char g_playing_req[128];
static pthread_mutex_t g_sockmu = PTHREAD_MUTEX_INITIALIZER;

static int sock_open(const char *path) {
    if (!path || !*path) return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    size_t pl = strlen(path);
    if (pl >= sizeof a.sun_path) { close(fd); return -1; }
    memcpy(a.sun_path, path, pl + 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) { close(fd); return -1; }
    return fd;
}

// -1: the connection is broken (nothing usable came back); -2: timed out.
static int sock_roundtrip(int fd, const char *req, char *resp, size_t cap, int timeout_ms) {
    int64_t deadline = now_ms() + timeout_ms;
    size_t rl = strlen(req), off = 0;
    while (off < rl + 1) {                         // the request, then its newline
        const char *p = off < rl ? req + off : "\n";
        size_t n = off < rl ? rl - off : 1;
        ssize_t w = write(fd, p, n);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        off += (size_t)w;
    }
    size_t got = 0;
    for (;;) {
        int left = (int)(deadline - now_ms());
        if (left <= 0) return -2;
        struct pollfd pf = { fd, POLLIN, 0 };
        int r = poll(&pf, 1, left);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) return -2;
        // One byte at a time past the newline would be wasted reads; the
        // service answers strictly one line per request, so nothing follows it.
        ssize_t n = read(fd, resp + got, cap - 1 - got);
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        if (n == 0) return -1;                     // closed before a full line
        size_t from = got;
        got += (size_t)n;
        char *nl = memchr(resp + from, '\n', (size_t)n);
        if (nl) { got = (size_t)(nl - resp); break; }
        if (got >= cap - 1) return -1;             // longer than the buffer: desynced
    }
    resp[got] = 0;
    return (int)got;
}

static int sock_call(const char *req, char *resp, size_t cap, int timeout_ms) {
    pthread_mutex_lock(&g_sockmu);
    int r = -1;
    for (int attempt = 0; attempt < 2; attempt++) {
        int fresh = 0;
        if (g_fd < 0) {
            g_fd = sock_open(kl_steam_bridge_socket_path());
            if (g_fd < 0) break;
            fresh = 1;
        }
        if (fresh && attempt > 0 && g_playing_req[0]) {   // a reconnect inside a session
            char tmp[256];
            if (sock_roundtrip(g_fd, g_playing_req, tmp, sizeof tmp, timeout_ms) >= 0)
                fprintf(stderr, "  [steam] bridge reconnected; playing on said again\n");
        }
        r = sock_roundtrip(g_fd, req, resp, cap, timeout_ms);
        if (r >= 0) break;
        close(g_fd);                               // a late answer must not answer the next request
        g_fd = -1;
        if (r == -2) { r = -1; break; }            // timed out: the service is there but slow; no retry
    }
    if (r >= 0 && strstr(req, "\"op\":\"playing\"")) {
        if (strstr(req, "\"on\":true")) snprintf(g_playing_req, sizeof g_playing_req, "%s", req);
        else g_playing_req[0] = 0;
    }
    pthread_mutex_unlock(&g_sockmu);
    return r;
}
#endif

int kl_steam_backend_call(const char *req, char *resp, size_t cap, int timeout_ms) {
    if (!req || !resp || cap < 2) return -1;
    resp[0] = 0;
    kl_steam_backend_fn fn = atomic_load(&g_backend);
    if (fn) {
        int n = fn(req, resp, cap, timeout_ms);
        if (n < 0 || (size_t)n >= cap) return -1;
        resp[n] = 0;
        return n;
    }
#if TARGET_OS_OSX
    return sock_call(req, resp, cap, timeout_ms);
#else
    return -1;                                     // on device only the app can reach Steam
#endif
}
