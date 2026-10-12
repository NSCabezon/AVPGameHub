// kl_stream_host.c — the Mac side of "Jugar desde el Mac": UDP server,
// Bonjour, pose-in, frame-out pacing, packetisation and the 1 s HUD line.
// The Metal compose + VideoToolbox encode live in kl_stream_host_mtl.m.
//
// Threads:
//   net    — owns the socket's receive side and is the ONLY thread that
//            publishes poses into kl_ovrp (its seqlock is single-writer).
//            Also Bonjour, PING, client timeout and the stats line.
//   frame  — polls kl_vulkan_frame_serial(); on a new guest frame pulls the
//            haptics envelope, composes and hands the frame to the encoder.
//   VT     — VideoToolbox's output thread fragments and sends VIDEO.
//   main   — waits for quit, or runs the KL_STREAM_PREVIEW window.
//
// Knobs (all optional):
//   KL_STREAM_HOST=1             select this frontend (m_boot)
//   KL_STREAM_PORT=9944          UDP port (KL_STREAM_PORT_DEFAULT)
//   KL_STREAM_NAME=<s>           Bonjour instance name (default: computer name)
//   KL_STREAM_BITRATE_KBPS=100000  average bitrate; capped by HELLO.max_bitrate_kbps
//   KL_STREAM_FPS=<lock or 60>   ExpectedFrameRate / HELLO_ACK.host_fps_target
//   KL_STREAM_LOCK_FPS=45        pace the guest's WaitGetPoses to this rate and tell
//                                it a display of this rate (0 = free-running, the
//                                client's Hz). Even cadence; the headset reprojects
//                                to 90 Hz.
//   KL_STREAM_SCALE=<unset>      unset: encoded eye size = what the guest SUBMITS
//                                (its rendered rect, KL_STREAM_MAX_EYE caps the
//                                longest side). Set: HELLO eye size x this.
//   KL_STREAM_MAX_EYE=0          cap on the auto eye size's longest side (0 = none)
//   KL_STREAM_MAX_MPIX=7.0       cap on the auto frame's megapixels, both eyes (0 = none):
//                                the encoder's 45 fps budget (~2.4 ms/MP on M1 Max)
//   KL_STREAM_PACE_MBPS=300      pace each frame's packets at this rate...
//   KL_STREAM_PACE_FRAC=0.75     ...but over at most this fraction of the frame interval
//   KL_STREAM_PACE_MS=<unset>    set: a fixed spread per frame instead (0 = burst)
//   KL_STREAM_TXQ_MAX=2          frames queued/sending before a guest frame is not
//                                encoded (busy skip; never drop an encoded frame)
//   KL_STREAM_IDR_MIN_MS=500     at most one forced keyframe per this long
//   KL_STREAM_ABR=1              adaptive bitrate (stats_tick): down x KL_STREAM_ABR_DOWN
//                                (0.7) on a congested second (x0.85 on 2+ IDR asks), up 5% per
//                                KL_STREAM_ABR_UP_S (2) clean ones, floor KL_STREAM_MIN_KBPS
//   KL_STREAM_CONNECTED_TX=1     send video on a connect()ed socket (0 = sendto, slow)
//   KL_STREAM_SNDBUF=8388608     SO_SNDBUF of the sockets
//   KL_STREAM_FEC=10             one XOR parity packet per N fragments (0 = off)
//   KL_STREAM_TEST_DROP=0        drop this fraction of VIDEO packets (loss tests)
//   KL_STREAM_TEST_LINK_MBPS=0   the sender blocks as on a link this fast (loopback tests)
//   KL_STREAM_WAIT=1             wait for the first HELLO before booting the guest
//                                (0 = boot now with the built-in Vision Pro defaults)
//   KL_STREAM_TIMEOUT_MS=2000    no POSE for this long = client gone
//   KL_STREAM_PREVIEW=1          local preview window of the encoded SBS frame
//   KL_STREAM_BONJOUR=0          do not advertise (loopback tests)
//   KL_STREAM_AUDIO=1            send the guest's sound to the headset (AUDIO)
//   KL_STREAM_AUDIO_LOCAL=0      ...and also play it on the Mac (1); default
//                                silent here while the tap is on
//
// The headset is told how the session is going without asking: STATUS once a
// second (BOOTING from the HELLO until the first frame is encoded — Alyx's
// boot is tens of seconds of no picture — then RUNNING), and BYE when the game
// ends: the guest's own exit/_exit (kl_fault_add_exit_hook — Alyx's "Quit"
// ends in _exit(0), past atexit), a host exit(), a fatal signal in the guest
// (the fault reporter) or SIGINT/SIGTERM on m_boot. Without the BYE the
// headset kept showing the last picture.
#include "kl_stream_host.h"
#include "kl_stream_proto.h"

#include <arpa/inet.h>
#include <dns_sd.h>
#include <errno.h>
#include <math.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <mach/mach.h>
#include <mach/thread_policy.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "kl_audio.h"
#include "kl_env.h"
#include "kl_fault.h"
#include "kl_openvr.h"
#include "kl_ovrp.h"
#include "kl_openxr.h"
#include "kl_stream_tx.h"
#include "kl_vulkan.h"
#include <mach/mach_time.h>

#define SH "[stream-host] "

double kl_stream_host_now(void) {
    struct timespec t;
    clock_gettime(CLOCK_UPTIME_RAW, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}
static uint64_t mono_ns(void) {     // the frame record's clock (submit_ns)
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

int kl_stream_host_enabled(void) { return kl_env_on("KL_STREAM_HOST", 0); }

// ---- state ------------------------------------------------------------------

static int g_fd = -1;
static int g_port;
static char g_guest[32] = "guest";
static DNSServiceRef g_dns;

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_cv = PTHREAD_COND_INITIALIZER;
static struct {
    int      active;               // a client is streaming
    int      configured;           // a HELLO has been applied to kl_ovrp, ever
    struct sockaddr_storage addr;
    socklen_t addr_len;
    double   last_heard;           // host time of the last POSE/HELLO from it
    int      timed_out;            // went silent (not BYE): its POSEs resume it
    // what the encoder is asked for
    int      frame_w, frame_h, kbps;
    float    fps;
    // what the guest was configured with (for the late-config warning)
    float    hz;
    uint32_t eye_w, eye_h;
    float    tan[2][4];
} C;
static int g_guest_running;        // set once the guest thread exists
static volatile int g_idr;         // a keyframe is wanted (granted at most every KL_STREAM_IDR_MIN_MS)
static double g_last_key_t = -1e9; // host time the last keyframe was handed to the encoder
// The video socket: a second socket on the same port, connect()ed to the
// client. An UNconnected sendto() costs a route + NECP policy lookup per
// datagram — measured ~0.13-0.16 ms each on a Mac with VPN/network extensions
// installed, i.e. a ceiling of ~6-8k packets/s (~60-80 Mbit/s) that a 6K
// keyframe hits at once. A connected socket skips that: >200k packets/s.
// SO_REUSEPORT on both; the connected one is the more specific match, so the
// client's own packets arrive on it (the net thread reads both). Never
// closed — a new client re-connect()s it — so a send racing a reconnect
// cannot hit a recycled descriptor.
static int g_tx_fd = -1;
static int g_tx_fd_ok;             // connected to C.addr
static int g_sndbuf;               // what SO_SNDBUF was granted
static uint32_t g_seq[16];         // per-type send sequence
static uint32_t g_frame_id;
static double g_pace_period, g_pace_next;   // KL_STREAM_LOCK_FPS (pace_wait)
static volatile int g_pace_off;   // KL_STREAM_LOCK_AB: this half is free-running
// STATUS: when the guest was started (kl_stream_host_run) and when its first
// frame went to the encoder (0 = not yet: BOOTING).
static volatile double g_t_boot, g_t_first_frame;
static volatile int g_bye_sent;

// pose_id -> host receipt time, for the pose-age statistic
#define POSE_RING 1024
static struct { uint32_t id; uint64_t ns; double t; float q[4]; } g_pose_ring[POSE_RING];

static struct {
    unsigned frames, keyframes, packets, poses, send_err;
    double   enc_ms, compose_ms, age_ms, render_ms, send_ms;
    unsigned retries, skipped, untagged;
    float    tag_err_deg;   // worst angle between the frame record's head and the echoed POSE's
    unsigned age_n;
    uint64_t bytes;
    double   rtt_ms;
    unsigned long long total_frames, total_key;
    unsigned parity, dropped, queue_drops;
    // guest cadence: intervals between new guest frames (frame thread)
    double   iv_sum, iv_sq;
    unsigned iv_n;
    double   iv_max;
    // the guest's own frame clock: WaitGetPoses to WaitGetPoses (pace_wait)
    double   wgp_sum, wgp_sq, wgp_max;
    unsigned wgp_n, wgp_late, wgp_wake_late;   // overran the slot / woke > 1 ms late
    // frames actually handed to the encoder: the cadence the headset gets
    double   enc_sum, enc_sq, enc_max;
    unsigned enc_n;
    unsigned audio_pkts, audio_frames;   // AUDIO sent this window
    // the sender, per window (KL_STREAM_HOST_TXLOG line)
    unsigned p_n, k_n;                   // P / key frames sent
    uint64_t p_bytes, k_bytes;
    size_t   p_max, k_max;
    unsigned q_max;                      // deepest the sender queue got
    unsigned busy_skips;                 // guest frames not encoded: the sender was behind
    unsigned idr_req, idr_forced, idr_deferred;   // client asks / keyframes forced / asks held back
    double   pace_ms;
} S;

// ---- adaptive bitrate ----------------------------------------------------------
// The encoder's AverageBitRate follows the link: down by KL_STREAM_ABR_DOWN
// (x0.7) on a second with pressure — the sender fell behind (busy skips, queue
// drops), the client lost frames (IDR_REQUEST), the socket refused (ENOBUFS) —
// and back up by 5% of the ceiling per KL_STREAM_ABR_UP_S (2) clean seconds.
// The ceiling is the session's C.kbps; the floor KL_STREAM_MIN_KBPS (15% of
// it, at least 8000). A change is a property set on the live session, never a
// new encoder (which would cost a keyframe). KL_STREAM_ABR=0 holds C.kbps.
static volatile int g_abr_kbps;      // current target; 0 = not started
static int g_abr_clean;              // consecutive seconds without pressure

static void hdr_init(kl_stream_hdr *h, uint16_t type) {
    h->magic = KL_STREAM_MAGIC;
    h->version = KL_STREAM_VERSION;
    h->type = type;
    h->seq = __atomic_fetch_add(&g_seq[type & 15], 1, __ATOMIC_RELAXED);
}

static const char *addr_str(const struct sockaddr_storage *a, char *buf, size_t n) {
    char ip[INET6_ADDRSTRLEN] = "?";
    int port = 0;
    if (a->ss_family == AF_INET) {
        const struct sockaddr_in *s = (const struct sockaddr_in *)a;
        inet_ntop(AF_INET, &s->sin_addr, ip, sizeof ip);
        port = ntohs(s->sin_port);
    } else if (a->ss_family == AF_INET6) {
        const struct sockaddr_in6 *s = (const struct sockaddr_in6 *)a;
        inet_ntop(AF_INET6, &s->sin6_addr, ip, sizeof ip);
        port = ntohs(s->sin6_port);
    }
    snprintf(buf, n, "%s:%d", ip, port);
    return buf;
}

// Address + port as IPv6 (an IPv4 address as its v4-mapped form): the
// listening socket reports a v4 peer as ::ffff:a.b.c.d, the connected video
// socket's recvfrom as a plain sockaddr_in — the same client either way.
static int addr_norm(const struct sockaddr_storage *a, socklen_t al,
                     struct in6_addr *ip, uint16_t *port, uint32_t *scope) {
    if (a->ss_family == AF_INET6 && al >= sizeof(struct sockaddr_in6)) {
        const struct sockaddr_in6 *s6 = (const struct sockaddr_in6 *)a;
        *ip = s6->sin6_addr; *port = s6->sin6_port; *scope = s6->sin6_scope_id;
        return 1;
    }
    if (a->ss_family == AF_INET && al >= sizeof(struct sockaddr_in)) {
        const struct sockaddr_in *s4 = (const struct sockaddr_in *)a;
        memset(ip, 0, sizeof *ip);
        ip->s6_addr[10] = ip->s6_addr[11] = 0xff;
        memcpy(&ip->s6_addr[12], &s4->sin_addr, 4);
        *port = s4->sin_port; *scope = 0;
        return 1;
    }
    return 0;
}

static int addr_eq(const struct sockaddr_storage *a, socklen_t al,
                   const struct sockaddr_storage *b, socklen_t bl) {
    struct in6_addr ia, ib;
    uint16_t pa, pb;
    uint32_t sa, sb;
    if (!addr_norm(a, al, &ia, &pa, &sa) || !addr_norm(b, bl, &ib, &pb, &sb))
        return al == bl && memcmp(a, b, al) == 0;
    return pa == pb && sa == sb && memcmp(&ia, &ib, sizeof ia) == 0;
}

// Send to the current client. From any thread: sendto on one UDP socket is
// thread-safe; the address is copied under the lock. ENOBUFS (the interface
// queue is full — a 200 KB frame is ~170 packets in one burst) is retried
// briefly rather than dropped, since a lost fragment is a lost frame.
static int send_client(const void *buf, size_t n) {
    struct sockaddr_storage a;
    socklen_t al;
    pthread_mutex_lock(&g_mu);
    int on = C.active;
    a = C.addr; al = C.addr_len;
    int cfd = g_tx_fd_ok ? g_tx_fd : -1;
    pthread_mutex_unlock(&g_mu);
    if (!on || g_fd < 0) return -1;
    for (int tries = 0; tries < 200; tries++) {
        ssize_t r = cfd >= 0 ? send(cfd, buf, n, 0)
                             : sendto(g_fd, buf, n, 0, (const struct sockaddr *)&a, al);
        if (r == (ssize_t)n) return 0;
        if (errno != ENOBUFS && errno != EAGAIN) break;
        S.retries++;
        usleep(50);
    }
    S.send_err++;
    return -1;
}

static void send_to(const struct sockaddr_storage *a, socklen_t al, const void *buf, size_t n) {
    sendto(g_fd, buf, n, 0, (const struct sockaddr *)a, al);
}

// BYE to the connected client, three times (UDP, nothing acks it), once per
// process. Takes no lock and does no stdio, so the fault reporter can call it
// from a signal handler and the exit hook from a guest thread that may be
// anywhere: C is read as it stands (the process is ending; a torn read costs
// at worst a BYE nobody hears, and the headset's own silence timeout covers
// that). 1 if it was sent now.
static int send_bye_now(void) {
    if (__atomic_exchange_n(&g_bye_sent, 1, __ATOMIC_ACQ_REL)) return 0;
    if (!C.active || g_fd < 0) return 0;
    kl_stream_hdr bye;
    hdr_init(&bye, KL_STREAM_BYE);
    for (int i = 0; i < 3; i++) {
        if (g_tx_fd_ok && g_tx_fd >= 0) send(g_tx_fd, &bye, sizeof bye, 0);
        else sendto(g_fd, &bye, sizeof bye, 0, (const struct sockaddr *)&C.addr, C.addr_len);
    }
    return 1;
}

// The guest ended the process itself (kl_libc.c's exit doors): Alyx's Quit.
static void on_guest_exit(int status) {
    if (send_bye_now())
        fprintf(stderr, SH "the game is exiting (status %d): BYE sent to the headset\n", status);
}
// A host-side exit() (main() returning, a fail path): the same.
static void on_host_atexit(void) {
    if (send_bye_now()) fprintf(stderr, SH "exiting: BYE sent to the headset\n");
}
// A fatal signal in the guest: kl_fault's report is running, the process dies next.
static void on_fault_report(FILE *f) {
    if (send_bye_now()) fprintf(f, SH "fatal signal: BYE sent to the headset\n");
}

// STATUS to the client: BOOTING until the first frame is encoded, then RUNNING.
static void send_keepalive(double now) {
    kl_stream_keepalive k;
    memset(&k, 0, sizeof k);
    hdr_init(&k.h, KL_STREAM_STATUS);
    double first = g_t_first_frame;
    k.state = first > 0 ? KL_STREAM_HOST_RUNNING : KL_STREAM_HOST_BOOTING;
    double since = first > 0 ? first : g_t_boot;
    k.seconds = since > 0 && now > since ? (float)(now - since) : 0.0f;
    unsigned long long gf = kl_vulkan_frame_serial();
    k.guest_frames = gf > 0xffffffffull ? 0xffffffffu : (uint32_t)gf;
    send_client(&k, sizeof k);
}

static int bind_port_socket(int reuseport) {
    int fd = socket(AF_INET6, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    int off = 0, one = 1;
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof off);
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (reuseport) setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
    int big = kl_env_int("KL_STREAM_SNDBUF", 8 << 20);
    while (big > (256 << 10) && setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &big, sizeof big) != 0) big /= 2;
    big = 4 << 20;
    while (big > (256 << 10) && setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &big, sizeof big) != 0) big /= 2;
    struct sockaddr_in6 a;
    memset(&a, 0, sizeof a);
    a.sin6_family = AF_INET6;
    a.sin6_len = sizeof a;
    a.sin6_port = htons((uint16_t)g_port);
    a.sin6_addr = in6addr_any;
    if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0) {
        int e = errno;
        close(fd);
        errno = e;
        return -1;
    }
    return fd;
}

// Point the video socket at the (new) client. Net thread, g_mu held.
static void tx_fd_connect_locked(void) {
    g_tx_fd_ok = 0;
    if (!kl_env_on("KL_STREAM_CONNECTED_TX", 1)) return;
    if (g_tx_fd < 0) {
        g_tx_fd = bind_port_socket(1);
        if (g_tx_fd < 0) {
            fprintf(stderr, SH "video socket: bind :%d failed (%s) — sending with sendto, slower\n",
                    g_port, strerror(errno));
            return;
        }
        socklen_t l = sizeof g_sndbuf;
        getsockopt(g_tx_fd, SOL_SOCKET, SO_SNDBUF, &g_sndbuf, &l);
    }
    if (connect(g_tx_fd, (const struct sockaddr *)&C.addr, C.addr_len) != 0) {
        fprintf(stderr, SH "video socket: connect failed (%s) — sending with sendto, slower\n",
                strerror(errno));
        return;
    }
    g_tx_fd_ok = 1;
    fprintf(stderr, SH "video socket connected to the client (SO_SNDBUF %d KiB)\n", g_sndbuf >> 10);
}

// A keyframe is wanted (the client lost a frame, or the sender had to drop
// one). Granted by the frame thread at most every KL_STREAM_IDR_MIN_MS, so a
// burst of requests is ONE keyframe, never a storm of them.
static void want_idr(void) { g_idr = 1; }

// ---- display description -> kl_ovrp ------------------------------------------

// KL_STREAM_LOCK_FPS (default 45; 0 = off).
static float lock_fps(void) {
    float f = kl_env_float("KL_STREAM_LOCK_FPS", 45.0f);
    return f >= 10.0f && f <= 240.0f ? f : 0.0f;
}
// Auto encode size (KL_STREAM_SCALE unset): follow what the guest submits.
static int auto_size(void) {
    const char *e = getenv("KL_STREAM_SCALE");
    return !e || !*e;
}


static void apply_display(const char *who, const char *device, float hz,
                          uint32_t eye_w, uint32_t eye_h, const kl_stream_eye eye[2]) {
    int late = __atomic_load_n(&g_guest_running, __ATOMIC_ACQUIRE);
    int changed = hz != C.hz || eye_w != C.eye_w || eye_h != C.eye_h;
    for (int e = 0; e < 2; e++) {
        const kl_stream_eye *d = &eye[e];
        if (d->tan_left != C.tan[e][0] || d->tan_right != C.tan[e][1] ||
            d->tan_up != C.tan[e][2] || d->tan_down != C.tan[e][3]) changed = 1;
        kl_ovrp_set_eye_frustum(e, d->tan_left, d->tan_right, d->tan_up, d->tan_down);
        kl_ovrp_set_eye_offset(e, d->offset.x, d->offset.y, d->offset.z);
        kl_ovrp_set_eye_rotation(e, d->rotation.x, d->rotation.y, d->rotation.z, d->rotation.w);
        C.tan[e][0] = d->tan_left; C.tan[e][1] = d->tan_right;
        C.tan[e][2] = d->tan_up;   C.tan[e][3] = d->tan_down;
    }
    // With the lock the guest is told the LOCKED rate: Alyx paces its own
    // frame timing/prediction against the display it is told about, and the
    // headset reprojects to its real 90 Hz.
    float told = lock_fps() > 0 ? lock_fps() : hz;
    if (told > 0) kl_ovrp_set_display_frequency(told);
    if (eye_w && eye_h) kl_ovrp_set_eye_texture_size((int)eye_w, (int)eye_h);
    C.hz = hz; C.eye_w = eye_w; C.eye_h = eye_h;
    fprintf(stderr, SH "display from %s (%s): %.1f Hz, eye %ux%u, IPD %.1f mm, "
                    "tan L(l %.4f r %.4f u %.4f d %.4f) R(l %.4f r %.4f u %.4f d %.4f)\n",
            who, device, (double)hz, eye_w, eye_h,
            (double)((eye[1].offset.x - eye[0].offset.x) * 1000.0f),
            (double)eye[0].tan_left, (double)eye[0].tan_right, (double)eye[0].tan_up,
            (double)eye[0].tan_down, (double)eye[1].tan_left, (double)eye[1].tan_right,
            (double)eye[1].tan_up, (double)eye[1].tan_down);
    if (late && changed)
        fprintf(stderr, SH "LATE display description: the guest is already running. The "
                        "frustum and eye offsets apply from the next frame (kl_ovrp reads them "
                        "per frame); the eye size re-creates the stage images; the display rate "
                        "is a number Alyx read once at boot and keeps. Each VIDEO frame still "
                        "carries the tangents the guest actually rendered with, so the headset "
                        "places it correctly — at worst with less field than it asked for.\n");
}

// The Vision Pro-like description the fake client also sends: tangents from
// the device (eye 0 wider on its temporal/left side, mirrored for eye 1), the
// 66.9 mm IPD of the bench unit, 90 Hz, 1888x1824 per eye.
static void default_eyes(kl_stream_eye eye[2]) {
    memset(eye, 0, 2 * sizeof eye[0]);
    const float ipd = 0.0669f;
    eye[0].tan_left = 1.7321f; eye[0].tan_right = 1.0f;
    eye[0].tan_up = 1.0f;      eye[0].tan_down = 1.1918f;
    eye[1].tan_left = 1.0f;    eye[1].tan_right = 1.7321f;
    eye[1].tan_up = 1.0f;      eye[1].tan_down = 1.1918f;
    eye[0].offset.x = -ipd * 0.5f;
    eye[1].offset.x =  ipd * 0.5f;
    eye[0].rotation.w = eye[1].rotation.w = 1.0f;
}

static void frame_size_for(uint32_t eye_w, uint32_t eye_h, int *fw, int *fh) {
    float sc = kl_env_float("KL_STREAM_SCALE", 1.0f);
    if (!(sc > 0.1f && sc <= 2.0f)) sc = 1.0f;
    int w = (int)((float)eye_w * sc + 0.5f) & ~1;
    int h = (int)((float)eye_h * sc + 0.5f) & ~1;
    if (w < 64) w = 64;
    if (h < 64) h = 64;
    *fw = 2 * w; *fh = h;
}

void kl_stream_host_apply_defaults(void) {
    kl_stream_eye eye[2];
    default_eyes(eye);
    pthread_mutex_lock(&g_mu);
    apply_display("built-in defaults", "Vision Pro (no client yet)", 90.0f, 1888, 1824, eye);
    frame_size_for(1888, 1824, &C.frame_w, &C.frame_h);
    pthread_mutex_unlock(&g_mu);
}

// ---- receive ------------------------------------------------------------------

static void on_hello(const kl_stream_hello *m, size_t n,
                     const struct sockaddr_storage *from, socklen_t fl) {
    kl_stream_hello_ack ack;
    memset(&ack, 0, sizeof ack);
    hdr_init(&ack.h, KL_STREAM_HELLO_ACK);
    snprintf(ack.guest, sizeof ack.guest, "%s", g_guest);
    ack.codec = 0x31637668u;   // 'hvc1'
    char who[80];
    addr_str(from, who, sizeof who);
    if (n < sizeof *m || m->h.version != KL_STREAM_VERSION) {
        ack.status = KL_STREAM_ERR_VERSION;
        fprintf(stderr, SH "HELLO from %s refused: version %u (we speak %u) or size %zu\n",
                who, m->h.version, KL_STREAM_VERSION, n);
        send_to(from, fl, &ack, sizeof ack);
        return;
    }
    double now = kl_stream_host_now();
    double timeout = kl_env_int("KL_STREAM_TIMEOUT_MS", 2000) / 1000.0;
    pthread_mutex_lock(&g_mu);
    int same = C.active && addr_eq(&C.addr, C.addr_len, from, fl);
    if (C.active && !same && now - C.last_heard < timeout) {
        pthread_mutex_unlock(&g_mu);
        ack.status = KL_STREAM_ERR_BUSY;
        fprintf(stderr, SH "HELLO from %s refused: busy streaming to another client\n", who);
        send_to(from, fl, &ack, sizeof ack);
        return;
    }
    char dev[33];
    memcpy(dev, m->device, 32); dev[32] = 0;
    if (!same) {
        apply_display(who, dev, m->display_hz, m->eye_w, m->eye_h, m->eye);
        frame_size_for(m->eye_w, m->eye_h, &C.frame_w, &C.frame_h);
        int kbps = kl_env_int("KL_STREAM_BITRATE_KBPS", 100000);
        if (m->max_bitrate_kbps && (int)m->max_bitrate_kbps < kbps) kbps = (int)m->max_bitrate_kbps;
        C.kbps = kbps;
        C.fps = kl_env_float("KL_STREAM_FPS", lock_fps() > 0 ? lock_fps() : 60.0f);
        C.addr = *from; C.addr_len = fl;
        C.active = 1;
        C.timed_out = 0;
        tx_fd_connect_locked();
        g_abr_kbps = kbps;
        g_abr_clean = 0;
        // A new session numbers its poses from scratch, so a pose_id the guest
        // rendered with in a previous session must not be echoed as one of
        // this client's: frames until its first POSE is drawn go out with 0.
        memset(g_pose_ring, 0, sizeof g_pose_ring);
        g_last_key_t = -1e9;   // the new client's first frame is a keyframe, now
        g_idr = 1;
        fprintf(stderr, SH "client %s connected: streaming %s%dx%d HEVC at %d kbit/s, %.0f fps target%s\n",
                who, auto_size() ? "(until the guest submits) " : "", C.frame_w, C.frame_h, C.kbps,
                (double)C.fps, lock_fps() > 0 ? " (locked)" : "");
    }
    C.last_heard = now;
    C.configured = 1;
    ack.status = KL_STREAM_OK;
    ack.frame_w = (uint32_t)C.frame_w;
    ack.frame_h = (uint32_t)C.frame_h;
    ack.bitrate_kbps = (uint32_t)C.kbps;
    ack.host_fps_target = C.fps;
    pthread_cond_broadcast(&g_cv);
    pthread_mutex_unlock(&g_mu);
    send_to(from, fl, &ack, sizeof ack);
}

static void on_pose(const kl_stream_pose *m, size_t n,
                    const struct sockaddr_storage *from, socklen_t fl) {
    if (n < sizeof *m) return;
    pthread_mutex_lock(&g_mu);
    // A client that went silent past KL_STREAM_TIMEOUT_MS and then speaks
    // again from the same socket was stalled, not gone: resume it with a
    // keyframe. Its client never saw an end (PING/PONG kept flowing — only the
    // POSEs stopped: on a Mac harness, a GPU stall in its frame loop while the
    // game loaded a level) and would otherwise wait forever on a host that
    // ignores its POSEs. A BYE or a new HELLO clears this.
    int resumed = 0;
    if (!C.active && C.timed_out && addr_eq(&C.addr, C.addr_len, from, fl)) {
        C.active = 1;
        C.timed_out = 0;
        g_idr = 1;
        resumed = 1;
    }
    int ok = C.active && addr_eq(&C.addr, C.addr_len, from, fl);
    if (ok) C.last_heard = kl_stream_host_now();
    pthread_mutex_unlock(&g_mu);
    if (resumed) fprintf(stderr, SH "client is back (POSE after a timeout): streaming resumed\n");
    if (!ok) return;
    uint64_t ns = mono_ns();
    g_pose_ring[m->pose_id % POSE_RING].id = m->pose_id;
    g_pose_ring[m->pose_id % POSE_RING].ns = ns;
    g_pose_ring[m->pose_id % POSE_RING].t = m->t_pose;
    g_pose_ring[m->pose_id % POSE_RING].q[0] = m->head_rot.x;
    g_pose_ring[m->pose_id % POSE_RING].q[1] = m->head_rot.y;
    g_pose_ring[m->pose_id % POSE_RING].q[2] = m->head_rot.z;
    g_pose_ring[m->pose_id % POSE_RING].q[3] = m->head_rot.w;
    S.poses++;
    // The head: tag, time, pose — in that order, from this one thread. The
    // tag travels through the guest's frame latch into the frame record, which
    // is how VIDEO names the pose the frame was rendered with.
    kl_ovrp_set_head_pose_tag(m->pose_id);
    kl_ovrp_set_head_pose_time(m->t_pose);
    kl_ovrp_set_head_pose(m->head_pos.x, m->head_pos.y, m->head_pos.z,
                          m->head_rot.x, m->head_rot.y, m->head_rot.z, m->head_rot.w);
    for (int hand = 0; hand < 2; hand++) {
        const kl_stream_hand *h = &m->hand[hand];
        if (h->flags & KL_STREAM_HAND_TRACKED)
            kl_ovrp_set_hand_motion(hand, h->pos.x, h->pos.y, h->pos.z,
                                    h->rot.x, h->rot.y, h->rot.z, h->rot.w,
                                    h->vel.x, h->vel.y, h->vel.z,
                                    h->ang_vel.x, h->ang_vel.y, h->ang_vel.z);
        if (h->flags & KL_STREAM_HAND_CONNECTED)
            kl_ovrp_set_controller_input(hand, h->buttons, h->touches, h->index_trigger,
                                         h->hand_trigger, h->stick_x, h->stick_y);
    }
}

static void on_packet(const uint8_t *buf, size_t n, const struct sockaddr_storage *from_in,
                      socklen_t fl) {
    if (n < sizeof(kl_stream_hdr)) return;
    // Everything downstream (C.addr, replies through the dual-stack listening
    // socket, connect()) wants the IPv6 form; the video socket reports a v4
    // peer as AF_INET.
    struct sockaddr_storage f6;
    const struct sockaddr_storage *from = from_in;
    if (from_in->ss_family == AF_INET) {
        struct sockaddr_in6 *s6 = (struct sockaddr_in6 *)&f6;
        uint32_t scope;
        memset(&f6, 0, sizeof f6);
        s6->sin6_family = AF_INET6;
        s6->sin6_len = sizeof *s6;
        addr_norm(from_in, fl, &s6->sin6_addr, &s6->sin6_port, &scope);
        from = &f6;
        fl = sizeof *s6;
    }
    kl_stream_hdr h;
    memcpy(&h, buf, sizeof h);
    if (h.magic != KL_STREAM_MAGIC) return;
    if (h.type == KL_STREAM_HELLO) { on_hello((const kl_stream_hello *)buf, n, from, fl); return; }
    if (h.version != KL_STREAM_VERSION) return;
    switch (h.type) {
    case KL_STREAM_POSE:
        on_pose((const kl_stream_pose *)buf, n, from, fl);
        break;
    case KL_STREAM_IDR_REQUEST:
        want_idr();
        S.idr_req++;   // counted in the 1 s line, and a loss signal for the ABR
        break;
    case KL_STREAM_PING:
        if (n >= sizeof(kl_stream_ping)) {
            kl_stream_ping p;
            memcpy(&p, buf, sizeof p);
            hdr_init(&p.h, KL_STREAM_PONG);
            p.t_reply = kl_stream_host_now();
            send_to(from, fl, &p, sizeof p);
        }
        break;
    case KL_STREAM_PONG:
        if (n >= sizeof(kl_stream_ping)) {
            kl_stream_ping p;
            memcpy(&p, buf, sizeof p);
            S.rtt_ms = (kl_stream_host_now() - p.t_send) * 1000.0;
        }
        break;
    case KL_STREAM_BYE: {
        pthread_mutex_lock(&g_mu);
        int was = C.active && addr_eq(&C.addr, C.addr_len, from, fl);
        if (was) C.active = 0;
        if (was || addr_eq(&C.addr, C.addr_len, from, fl)) C.timed_out = 0;
        pthread_mutex_unlock(&g_mu);
        if (was) fprintf(stderr, SH "client said BYE — streaming stopped, the guest keeps running\n");
        break;
    }
    default:
        break;
    }
}

// ---- the 1 s line ----------------------------------------------------------------

static void stats_tick(double dt) {
    char who[80] = "none";
    pthread_mutex_lock(&g_mu);
    int on = C.active;
    if (on) addr_str(&C.addr, who, sizeof who);
    pthread_mutex_unlock(&g_mu);
    unsigned f = S.frames;
    if (!on && !f) return;   // quiet while nobody is connected
    fprintf(stderr, SH "%.1f fps encoded, encode %.1f ms (compose %.1f, send %.1f), render %.1f ms, "
                    "%.1f Mbit/s, %.0f pkt/s, pose %.0f Hz, pose age %.1f ms, rtt %.2f ms, "
                    "client %s, total %llu frames (%llu key)%s\n",
            f / dt, f ? S.enc_ms / f : 0.0, f ? S.compose_ms / f : 0.0, f ? S.send_ms / f : 0.0,
            f ? S.render_ms / f : 0.0,
            (double)S.bytes * 8.0 / 1e6 / dt, S.packets / dt, S.poses / dt,
            S.age_n ? S.age_ms / S.age_n : 0.0, S.rtt_ms, who,
            S.total_frames, S.total_key, S.send_err ? " SEND ERRORS" : "");
    if (S.iv_n) {
        double m = S.iv_sum / S.iv_n, var = S.iv_sq / S.iv_n - m * m;
        fprintf(stderr, SH "  guest cadence: %.1f fps, interval %.1f ms, sd %.2f ms, max %.1f ms; "
                           "%u parity pkts (FEC %d), pace %.1f ms%s%s\n",
                S.iv_n / dt, m, var > 0 ? sqrt(var) : 0.0, S.iv_max, S.parity,
                kl_env_int("KL_STREAM_FEC", 10), (double)kl_env_float("KL_STREAM_PACE_MS", 8.0f),
                S.dropped ? " (test drops on)" : "",
                g_pace_period <= 0 ? " [free]" : g_pace_off ? " [AB: free]" : " [locked]");
    }
    if (S.wgp_n) {
        double m = S.wgp_sum / S.wgp_n, var = S.wgp_sq / S.wgp_n - m * m;
        fprintf(stderr, SH "  guest WaitGetPoses: %.1f fps, interval %.1f ms, sd %.2f ms, max %.1f ms, "
                           "%u overran their slot, %u woke >1 ms late%s\n",
                S.wgp_n / dt, m, var > 0 ? sqrt(var) : 0.0, S.wgp_max, S.wgp_late, S.wgp_wake_late,
                g_pace_off ? " [AB: free]" : " [locked]");
    }
    if (S.enc_n) {
        double m = S.enc_sum / S.enc_n, var = S.enc_sq / S.enc_n - m * m;
        fprintf(stderr, SH "  frames encoded: %.1f fps, interval %.1f ms, sd %.2f ms, max %.1f ms%s\n",
                S.enc_n / dt, m, var > 0 ? sqrt(var) : 0.0, S.enc_max,
                g_pace_period <= 0 ? " [free]" : g_pace_off ? " [AB: free]" : " [locked]");
    }
    if (S.audio_pkts) fprintf(stderr, SH "  audio: %u packets, %.1f kHz of guest PCM sent\n",
                              S.audio_pkts, S.audio_frames / dt / 1000.0);
    if (S.queue_drops) fprintf(stderr, SH "  %u encoded frames dropped: the sender queue was full\n",
                               S.queue_drops);
    if (S.retries) fprintf(stderr, SH "  %u sends retried on a full interface queue (ENOBUFS)\n", S.retries);
    // The adaptive bitrate's step, then the sender's line.
    // Congestion (the sender itself fell behind or was refused) cuts hard;
    // loss alone (the client asked for keyframes more than once) gently —
    // Wi-Fi drops packets without being full, and FEC + one keyframe cover it.
    int congested = S.busy_skips > 1 || S.queue_drops || S.retries > 20 || S.send_err;
    int lossy = S.idr_req >= 2;
    int pressure = congested || lossy;
    int kmax = C.kbps, kprev = g_abr_kbps;
    if (on && kmax > 0 && kl_env_on("KL_STREAM_ABR", 1)) {
        int kmin = kl_env_int("KL_STREAM_MIN_KBPS", kmax * 15 / 100 > 8000 ? kmax * 15 / 100 : 8000);
        if (kmin > kmax) kmin = kmax;
        int k = kprev > 0 ? kprev : kmax;
        if (pressure) {
            k = (int)(k * (congested ? kl_env_float("KL_STREAM_ABR_DOWN", 0.7f)
                                     : kl_env_float("KL_STREAM_ABR_LOSS_DOWN", 0.85f)));
            // A congested sender was busy all second: what it got out IS the
            // link's rate. Go straight under it rather than in 0.7x steps
            // (100 -> 70 -> 49 -> 34 Mbit/s was 3-4 s of low fps per turn).
            int sent_kbps = (int)((double)S.bytes * 8.0 / 1000.0 / dt);
            if (congested && S.busy_skips > 5 && sent_kbps * 85 / 100 < k) k = sent_kbps * 85 / 100;
            g_abr_clean = 0;
        } else if (++g_abr_clean >= kl_env_int("KL_STREAM_ABR_UP_S", 2)) {
            k += kmax / 20;
            g_abr_clean = 0;
        }
        if (k < kmin) k = kmin;
        if (k > kmax) k = kmax;
        g_abr_kbps = k;
    } else if (on) {
        g_abr_kbps = kmax;
    }
    if (f || S.busy_skips || S.queue_drops) {
        fprintf(stderr, SH "  sender: %.1f Mbit/s, P %u avg %.0f max %.0f KB, key %u avg %.0f max %.0f KB, "
                           "queue max %u, busy skips %u, queue drops %u, IDR asked %u forced %u held %u, "
                           "pace %.1f ms, bitrate %d kbit/s%s%s\n",
                (double)S.bytes * 8.0 / 1e6 / dt, S.p_n, S.p_n ? S.p_bytes / 1024.0 / S.p_n : 0.0,
                S.p_max / 1024.0, S.k_n, S.k_n ? S.k_bytes / 1024.0 / S.k_n : 0.0, S.k_max / 1024.0,
                S.q_max, S.busy_skips, S.queue_drops, S.idr_req, S.idr_forced, S.idr_deferred,
                f ? S.pace_ms / f : 0.0, kprev,
                g_abr_kbps != kprev ? (g_abr_kbps < kprev ? " -> down" : " -> up") : "",
                g_tx_fd_ok ? "" : " (unconnected sendto)");
    }
    S.p_n = S.k_n = 0; S.p_bytes = S.k_bytes = 0; S.p_max = S.k_max = 0;
    S.q_max = S.busy_skips = S.idr_req = S.idr_forced = S.idr_deferred = 0;
    S.pace_ms = 0;
    if (f) fprintf(stderr, SH "  pose tag check: frame head vs echoed POSE head differ by %.3f deg "
                           "at worst%s\n", (double)S.tag_err_deg,
                   S.untagged ? " (some frames rendered before this client's first POSE: sent as pose_id 0)" : "");
    if (S.skipped) fprintf(stderr, SH "  %u guest frames skipped: the encoder was already holding "
                                   "KL_STREAM_MAX_INFLIGHT frames\n", S.skipped);
    S.frames = S.keyframes = S.packets = S.poses = S.send_err = 0;
    S.enc_ms = S.compose_ms = S.age_ms = S.render_ms = S.send_ms = 0;
    S.retries = S.skipped = S.untagged = 0;
    S.parity = S.dropped = S.queue_drops = 0;
    S.audio_pkts = S.audio_frames = 0;
    S.iv_sum = S.iv_sq = S.iv_max = 0; S.iv_n = 0;
    S.wgp_sum = S.wgp_sq = S.wgp_max = 0; S.wgp_n = 0; S.wgp_late = S.wgp_wake_late = 0;
    S.enc_sum = S.enc_sq = S.enc_max = 0; S.enc_n = 0;
    S.tag_err_deg = 0;
    S.age_n = 0;
    S.bytes = 0;
}

static void *net_thread(void *arg) {
    (void)arg;
    uint8_t buf[2048];
    double t_stats = kl_stream_host_now(), t_ping = t_stats, t_keep = 0;
    int keep_state = 0, keep_on = 0;
    double timeout = kl_env_int("KL_STREAM_TIMEOUT_MS", 2000) / 1000.0;
    for (;;) {
        // [0] the listening socket, [1] the video socket (the connected
        // client's own packets land there), [2] Bonjour.
        struct pollfd pf[3] = { { g_fd, POLLIN, 0 }, { g_tx_fd, POLLIN, 0 }, { -1, POLLIN, 0 } };
        if (g_dns) pf[2].fd = DNSServiceRefSockFD(g_dns);
        int r = poll(pf, 3, 10);
        for (int k = 0; k < 2 && r > 0; k++) {
            if (pf[k].fd >= 0 && (pf[k].revents & POLLERR)) {
                // A connected socket reports the peer's ICMP unreachable here;
                // reading SO_ERROR clears it (else poll spins on it).
                int e = 0; socklen_t el = sizeof e;
                getsockopt(pf[k].fd, SOL_SOCKET, SO_ERROR, &e, &el);
            }
            if (pf[k].fd < 0 || !(pf[k].revents & POLLIN)) continue;
            for (;;) {
                struct sockaddr_storage from;
                socklen_t fl = sizeof from;
                ssize_t n = recvfrom(pf[k].fd, buf, sizeof buf, MSG_DONTWAIT,
                                     (struct sockaddr *)&from, &fl);
                if (n <= 0) break;
                on_packet(buf, (size_t)n, &from, fl);
            }
        }
        if (r > 0 && pf[2].fd >= 0 && (pf[2].revents & POLLIN)) DNSServiceProcessResult(g_dns);
        double now = kl_stream_host_now();
        pthread_mutex_lock(&g_mu);
        int gone = C.active && now - C.last_heard > timeout;
        if (gone) { C.active = 0; C.timed_out = 1; }
        int on = C.active;
        pthread_mutex_unlock(&g_mu);
        if (gone)
            fprintf(stderr, SH "client timed out (no POSE for %.1f s) — streaming stopped, the "
                            "guest keeps running (a POSE from it resumes)\n", timeout);
        // STATUS: once a second, at once for a new client or a state change.
        int st = g_t_first_frame > 0 ? KL_STREAM_HOST_RUNNING : KL_STREAM_HOST_BOOTING;
        if (on && (!keep_on || st != keep_state || now - t_keep >= 1.0)) {
            send_keepalive(now);
            t_keep = now;
            keep_state = st;
        }
        keep_on = on;
        if (on && now - t_ping >= 1.0) {
            kl_stream_ping p;
            memset(&p, 0, sizeof p);
            hdr_init(&p.h, KL_STREAM_PING);
            p.t_send = now;
            send_client(&p, sizeof p);
            t_ping = now;
        }
        if (now - t_stats >= 1.0) {
            stats_tick(now - t_stats);
            t_stats = now;
        }
    }
    return NULL;
}

static void DNSSD_API dns_cb(DNSServiceRef ref, DNSServiceFlags flags, DNSServiceErrorType err,
                             const char *name, const char *type, const char *domain, void *ctx) {
    (void)ref; (void)flags; (void)ctx;
    if (err) fprintf(stderr, SH "Bonjour registration failed: %d\n", (int)err);
    else     fprintf(stderr, SH "Bonjour: '%s' %s%s\n", name, type, domain);
}

// ---- audio (KL_STREAM_AUDIO) ---------------------------------------------------
//
// kl_audio's tap hands us every guest buffer on the guest's audio thread, in
// the guest's format (Alyx through SDL: s16 stereo, 48 kHz), before the
// Mac's resampler. Cut into ~5 ms AUDIO packets and sent at once: the guest's
// feeder already runs at the device's pace (kl_audio_write blocks), so the
// packets leave at real time with no clock of our own. Mono is sent as mono,
// more than two channels as the first two. Only the first producer is
// streamed (Alyx has one; Steam Link's second stream would be mixed in the
// Mac's ring, which is past the tap).
static pthread_mutex_t g_au_mu = PTHREAD_MUTEX_INITIALIZER;
static struct {
    const void *src;
    unsigned rate, ch;
    uint64_t next_frame;          // first_frame of the packet being filled
    unsigned fill;                // frames in pkt
    unsigned per_pkt;             // ~5 ms
    struct { kl_stream_audio a; int16_t pcm[KL_STREAM_AUDIO_MAX_FRAMES * 2]; } pkt;
} A;

static void audio_flush_locked(void) {
    if (!A.fill) return;
    hdr_init(&A.pkt.a.h, KL_STREAM_AUDIO);
    A.pkt.a.sample_rate = A.rate;
    A.pkt.a.channels = (uint16_t)A.ch;
    A.pkt.a.frames = (uint16_t)A.fill;
    A.pkt.a.first_frame = A.next_frame;
    size_t n = sizeof A.pkt.a + (size_t)A.fill * A.ch * sizeof(int16_t);
    if (send_client(&A.pkt, n) == 0) { S.audio_pkts++; S.audio_frames += A.fill; }
    A.next_frame += A.fill;
    A.fill = 0;
}

static void audio_tap(const void *src, const int16_t *pcm, size_t frames,
                      unsigned rate, unsigned channels) {
    if (!rate || !channels) return;
    pthread_mutex_lock(&g_mu);
    int on = C.active;
    pthread_mutex_unlock(&g_mu);
    pthread_mutex_lock(&g_au_mu);
    if (!A.src) A.src = src;
    if (src != A.src || !on) {          // a second producer, or nobody to hear it
        if (!on) { A.fill = 0; }
        pthread_mutex_unlock(&g_au_mu);
        return;
    }
    unsigned ch = channels > 2 ? 2 : channels;
    if (rate != A.rate || ch != A.ch) {
        A.fill = 0;
        A.rate = rate; A.ch = ch; A.next_frame = 0;
        A.per_pkt = rate / 200;          // 5 ms
        if (A.per_pkt < 32) A.per_pkt = 32;
        if (A.per_pkt > KL_STREAM_AUDIO_MAX_FRAMES) A.per_pkt = KL_STREAM_AUDIO_MAX_FRAMES;
        fprintf(stderr, SH "audio: streaming the guest's %u Hz, %u ch (s16) in %u-frame packets\n",
                rate, ch, A.per_pkt);
    }
    for (size_t i = 0; i < frames; i++) {
        const int16_t *f = pcm + i * channels;
        int16_t *o = A.pkt.pcm + (size_t)A.fill * ch;
        o[0] = f[0];
        if (ch == 2) o[1] = f[1];
        if (++A.fill >= A.per_pkt) audio_flush_locked();
    }
    pthread_mutex_unlock(&g_au_mu);
}

int kl_stream_host_start(const char *guest) {
    if (guest) snprintf(g_guest, sizeof g_guest, "%s", guest);
    g_port = kl_env_int("KL_STREAM_PORT", KL_STREAM_PORT_DEFAULT);
    // One dual-stack socket: the headset may reach the Mac over IPv6
    // link-local as easily as over IPv4.
    // Bound WITHOUT SO_REUSEPORT, so a second host on this port still fails
    // here; the option is set after the bind, for the video socket's sake
    // (tx_fd_connect_locked), which only checks it at its own bind.
    g_fd = bind_port_socket(0);
    if (g_fd < 0) {
        fprintf(stderr, SH "bind :%d failed: %s\n", g_port, strerror(errno));
        return -1;
    }
    {
        int one = 1;
        setsockopt(g_fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
    }
    if (!kl_env_on("KL_STREAM_BONJOUR", 1)) {
        fprintf(stderr, SH "Bonjour off (KL_STREAM_BONJOUR=0): reachable by address only\n");
    } else {
    TXTRecordRef txt;
    TXTRecordCreate(&txt, 0, NULL);
    TXTRecordSetValue(&txt, "guest", (uint8_t)strlen(g_guest), g_guest);
    char v[8];
    snprintf(v, sizeof v, "%u", KL_STREAM_VERSION);
    TXTRecordSetValue(&txt, "v", (uint8_t)strlen(v), v);
    DNSServiceErrorType e = DNSServiceRegister(&g_dns, 0, 0, getenv("KL_STREAM_NAME"),
                                               KL_STREAM_BONJOUR, NULL, NULL,
                                               htons((uint16_t)g_port),
                                               TXTRecordGetLength(&txt),
                                               TXTRecordGetBytesPtr(&txt), dns_cb, NULL);
    TXTRecordDeallocate(&txt);
    if (e != kDNSServiceErr_NoError) {
        fprintf(stderr, SH "DNSServiceRegister failed (%d) — reachable by address only\n", (int)e);
        g_dns = NULL;
    }
    }
    pthread_t t;
    if (pthread_create(&t, NULL, net_thread, NULL)) { perror(SH "pthread_create"); return -1; }
    pthread_detach(t);
    // Every way this process can end tells the headset (see the top).
    kl_fault_add_exit_hook(on_guest_exit);
    kl_fault_add_reporter(on_fault_report);
    atexit(on_host_atexit);
    fprintf(stderr, SH "listening on UDP :%d (%s), guest '%s'\n", g_port, KL_STREAM_BONJOUR, g_guest);
    if (kl_env_on("KL_STREAM_AUDIO", 1)) {
        int local = kl_env_on("KL_STREAM_AUDIO_LOCAL", 0);
        kl_audio_set_tap(audio_tap, !local);
        fprintf(stderr, SH "audio to the headset on (KL_STREAM_AUDIO=0: off); %s\n",
                local ? "also playing on the Mac (KL_STREAM_AUDIO_LOCAL=1)"
                      : "the Mac stays silent (KL_STREAM_AUDIO_LOCAL=1 plays it here too)");
    }
    return 0;
}

int kl_stream_host_wait_hello(double timeout_s, const volatile int *quit) {
    double t_end = timeout_s >= 0 ? kl_stream_host_now() + timeout_s : 0;
    pthread_mutex_lock(&g_mu);
    while (!C.configured && !(quit && *quit) && (timeout_s < 0 || kl_stream_host_now() < t_end)) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_nsec += 100 * 1000000L;
        if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
        pthread_cond_timedwait(&g_cv, &g_mu, &ts);
    }
    int got = C.configured;
    pthread_mutex_unlock(&g_mu);
    return got;
}

// ---- frame out ---------------------------------------------------------------------

// The encoder's output goes through a queue to the sender thread, which paces
// each frame's packets (kl_stream_tx.c) without holding VideoToolbox's
// callback thread. When a newer frame is already waiting the current one is
// sent out at once (`hurry`), so pacing never adds a frame of latency.
//
// Congestion is handled BEFORE the encoder, never after it: the frame thread
// does not encode a guest frame while the sender still has KL_STREAM_TXQ_MAX
// (2) frames queued or in flight (a "busy skip" — the reference chain stays
// intact, the headset reprojects the last picture). Dropping an ENCODED
// P-frame breaks every later frame and costs a keyframe, 5-10x the size of a
// P-frame, which is what used to snowball into a keyframe on every frame
// ("33 encoded frames dropped: the sender queue was full" each second). The
// queue below is sized so that a drop is a last resort (TXQ slots).
#define TXQ 8
static struct {
    kl_stream_frame_meta m;
    uint8_t *au;
    size_t   n;
    int      key;
    float    ms_encode;
} g_txq[TXQ];
static unsigned g_txq_head, g_txq_tail;      // head = next to send (or being sent)
static pthread_mutex_t g_txq_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_txq_cv = PTHREAD_COND_INITIALIZER;
static volatile int g_tx_hurry;

// Frames queued or being sent.
static unsigned txq_depth(void) {
    pthread_mutex_lock(&g_txq_mu);
    unsigned d = g_txq_tail - g_txq_head;
    pthread_mutex_unlock(&g_txq_mu);
    return d;
}

static void on_encoded(const kl_stream_frame_meta *m, const uint8_t *au, size_t n,
                       int keyframe, float ms_encode) {
    uint8_t *copy = malloc(n ? n : 1);
    if (!copy) return;
    memcpy(copy, au, n);
    pthread_mutex_lock(&g_txq_mu);
    if (g_txq_tail - g_txq_head >= TXQ) {
        // Last resort (the frame thread's busy skip should have prevented it):
        // drop it and ask for ONE keyframe, since every later P-frame would
        // reference this one. want_idr is rate-limited, so this cannot storm.
        pthread_mutex_unlock(&g_txq_mu);
        free(copy);
        S.queue_drops++;
        want_idr();
        return;
    }
    if (keyframe) g_last_key_t = kl_stream_host_now();   // also the encoder's own (re-created session)
    unsigned i = g_txq_tail % TXQ;
    g_txq[i].m = *m; g_txq[i].au = copy; g_txq[i].n = n;
    g_txq[i].key = keyframe; g_txq[i].ms_encode = ms_encode;
    g_txq_tail++;
    unsigned d = g_txq_tail - g_txq_head;
    if (d > S.q_max) S.q_max = d;
    g_tx_hurry = d > 1;
    pthread_cond_signal(&g_txq_cv);
    pthread_mutex_unlock(&g_txq_mu);
}

static int tx_send(void *ctx, void *pkt, size_t n) {
    (void)ctx;
    hdr_init((kl_stream_hdr *)pkt, KL_STREAM_VIDEO);
    // KL_STREAM_TEST_LINK_MBPS: the sender blocks as if the interface drained
    // at this rate — a slow link on loopback, for testing the busy skip and
    // the adaptive bitrate (0 = off).
    static double link_bps = -1, t_free;
    if (link_bps < 0) link_bps = kl_env_float("KL_STREAM_TEST_LINK_MBPS", 0.0f) * 1e6;
    if (link_bps > 0) {
        double now = kl_stream_host_now();
        if (t_free < now - 0.002) t_free = now;   // idle: no credit; else absorb sleep overshoot
        t_free += (double)n * 8.0 / link_bps;
        double d = t_free - now;
        if (d > 0.0002) {
            struct timespec ts = { (time_t)d, (long)((d - (double)(time_t)d) * 1e9) };
            nanosleep(&ts, NULL);
        }
    }
    return send_client(pkt, n);
}

// How long to spread this frame's packets over. KL_STREAM_PACE_MS set: that,
// fixed (0 = burst). Unset: at KL_STREAM_PACE_MBPS (300 Mbit/s) — a P-frame
// leaves in a few ms, no added latency — capped at KL_STREAM_PACE_FRAC (0.75)
// of the frame interval, so a keyframe is spread over most of its slot
// instead of hitting the access point as one 400-packet burst.
static double pace_for(size_t n, float fps) {
    static int fixed = -1;
    static double fixed_s, mbps, frac;
    if (fixed < 0) {
        const char *e = getenv("KL_STREAM_PACE_MS");
        fixed = e && *e;
        fixed_s = kl_env_float("KL_STREAM_PACE_MS", 0.0f) / 1000.0;
        mbps = kl_env_float("KL_STREAM_PACE_MBPS", 300.0f);
        frac = kl_env_float("KL_STREAM_PACE_FRAC", 0.75f);
    }
    if (fixed) return fixed_s;
    if (mbps <= 0) return 0;
    double s = (double)n * 8.0 / (mbps * 1e6);
    double cap = fps > 0 ? frac / fps : 0.012;
    return s < cap ? s : cap;
}

static void send_frame(const kl_stream_frame_meta *m, const uint8_t *au, size_t n,
                       int keyframe, float ms_encode) {
    kl_stream_video v;
    memset(&v, 0, sizeof v);
    v.frame_id = m->frame_id;
    v.pose_id = m->pose_id;
    v.t_pose = m->t_pose;
    v.flags = keyframe ? KL_STREAM_VIDEO_KEYFRAME : 0;
    memcpy(v.tan, m->tan, sizeof v.tan);
    v.host_ms_render = m->ms_render;
    v.host_ms_encode = ms_encode;
    static int fec = -1;
    static double drop;
    if (fec < 0) {
        fec = kl_env_int("KL_STREAM_FEC", 10);
        drop = kl_env_float("KL_STREAM_TEST_DROP", 0.0f);
        const char *pe = getenv("KL_STREAM_PACE_MS");
        if (pe && *pe)
            fprintf(stderr, SH "sender: FEC %d (1 XOR parity packet per N fragments, 0 = off), "
                            "pace %.1f ms per frame (KL_STREAM_PACE_MS; 0 = burst), test drop %.3f\n",
                    fec, (double)kl_env_float("KL_STREAM_PACE_MS", 0.0f), drop);
        else
            fprintf(stderr, SH "sender: FEC %d (1 XOR parity packet per N fragments, 0 = off), "
                            "paced at %.0f Mbit/s up to %.0f%% of the frame interval "
                            "(KL_STREAM_PACE_MBPS / _FRAC; KL_STREAM_PACE_MS=x fixes it), "
                            "at most %d frames queued (KL_STREAM_TXQ_MAX), test drop %.3f\n",
                    fec, (double)kl_env_float("KL_STREAM_PACE_MBPS", 300.0f),
                    100.0 * kl_env_float("KL_STREAM_PACE_FRAC", 0.75f),
                    kl_env_int("KL_STREAM_TXQ_MAX", 2), drop);
    }
    pthread_mutex_lock(&g_mu);
    float fps = C.fps;
    pthread_mutex_unlock(&g_mu);
    double pace_s = pace_for(n, fps);
    kl_stream_tx_result r;
    double t_send0 = kl_stream_host_now();
    if (kl_stream_tx_frame(&v, au, n, fec, pace_s, &g_tx_hurry, drop, tx_send, NULL, &r) != 0) {
        fprintf(stderr, SH "frame %u is %zu bytes — more fragments than the protocol can "
                        "number; dropped (lower KL_STREAM_BITRATE_KBPS)\n", m->frame_id, n);
        want_idr();
        return;
    }
    S.send_ms += (kl_stream_host_now() - t_send0) * 1000.0;
    S.pace_ms += pace_s * 1000.0;
    S.frames++;
    S.total_frames++;
    if (keyframe) {
        S.keyframes++; S.total_key++;
        S.k_n++; S.k_bytes += n; if (n > S.k_max) S.k_max = n;
    } else {
        S.p_n++; S.p_bytes += n; if (n > S.p_max) S.p_max = n;
    }
    S.packets += r.sent;
    S.parity += r.parity;
    S.dropped += r.dropped;
    S.bytes += n;
    S.enc_ms += ms_encode;
    S.compose_ms += (m->t_encode_start - m->t_compose_start) * 1000.0;
    S.render_ms += m->ms_render;
    if (m->pose_host_ns) {
        S.age_ms += (double)(mono_ns() - m->pose_host_ns) / 1e6;
        S.age_n++;
    }
}

static void *sender_thread(void *arg) {
    (void)arg;
    pthread_setname_np("klepton stream tx");
    for (;;) {
        pthread_mutex_lock(&g_txq_mu);
        while (g_txq_head == g_txq_tail) pthread_cond_wait(&g_txq_cv, &g_txq_mu);
        unsigned i = g_txq_head % TXQ;
        kl_stream_frame_meta m = g_txq[i].m;
        uint8_t *au = g_txq[i].au;
        size_t n = g_txq[i].n;
        int key = g_txq[i].key;
        float ms = g_txq[i].ms_encode;
        g_tx_hurry = g_txq_tail - g_txq_head > 1;
        pthread_mutex_unlock(&g_txq_mu);
        send_frame(&m, au, n, key, ms);
        free(au);
        pthread_mutex_lock(&g_txq_mu);
        g_txq_head++;
        g_tx_hurry = g_txq_tail - g_txq_head > 1;
        pthread_mutex_unlock(&g_txq_mu);
    }
    return NULL;
}

// ---- KL_STREAM_LOCK_FPS: the guest's frame clock ----------------------------
// The host has no compositor vsync: Alyx's WaitGetPoses returns at once and the
// guest runs as fast as the Mac lets it — 33-40 fps wandering, which the
// headset shows as judder against its 90 Hz. This makes WaitGetPoses return on
// a fixed grid of 1/lock seconds instead. A frame that overruns its slot by
// less than half a period keeps the grid (the next one starts at once); more
// than that re-anchors the grid at now rather than bursting to catch up.
// The interval between WaitGetPoses RETURNS (when the game starts a frame,
// which is what sets the picture cadence), for the 1 s line.
static void note_wgp(double t) {
    static double t_prev;
    if (t_prev > 0) {
        double iv = (t - t_prev) * 1000.0;
        S.wgp_sum += iv; S.wgp_sq += iv * iv; S.wgp_n++;
        if (iv > S.wgp_max) S.wgp_max = iv;
    }
    t_prev = t;
}

static void pace_wait(void) {
    static mach_timebase_info_data_t tb;
    static double ab_s = -1;
    if (!tb.denom) mach_timebase_info(&tb);
    double now = kl_stream_host_now();
    // KL_STREAM_LOCK_AB=<s>: alternate locked / free every <s> seconds, for an
    // A/B of the cadence inside one run (the 1 s line says which is on).
    if (ab_s < 0) ab_s = kl_env_float("KL_STREAM_LOCK_AB", 0.0f);
    if (ab_s > 0 && ((long)(now / ab_s) & 1)) {
        g_pace_next = 0; g_pace_off = 1;
        note_wgp(now);
        return;
    }
    g_pace_off = 0;
    if (g_pace_next <= 0) g_pace_next = now;
    static int qos;
    if (!qos++) {
        // The game's frame thread decides the cadence: wake it like one.
        // (Measured on a loaded Mac: at default QoS 30+ of 45 wakes a second
        // came > 1 ms late, sd 3 ms on a grid that was otherwise exact.)
        int rq = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        fprintf(stderr, SH "pacer: guest frame thread QoS user-interactive: %s\n", rq ? strerror(rq) : "ok");
        if (kl_env_on("KL_STREAM_PACE_RT", 0)) {
            // Mach time-constraint (real-time) policy for the waiting thread:
            // period = the lock, a small computation budget. Experimental.
            thread_time_constraint_policy_data_t pol;
            double tps = (double)tb.denom / tb.numer * 1e9;   // ticks per second
            pol.period = (uint32_t)(g_pace_period * tps);
            pol.computation = (uint32_t)(0.002 * tps);
            pol.constraint = (uint32_t)(0.004 * tps);
            pol.preemptible = 1;
            kern_return_t kr = thread_policy_set(pthread_mach_thread_np(pthread_self()),
                                                 THREAD_TIME_CONSTRAINT_POLICY,
                                                 (thread_policy_t)&pol, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
            fprintf(stderr, SH "pacer: real-time policy (KL_STREAM_PACE_RT=1): %s\n", kr ? "refused" : "ok");
        }
    }
    if (now < g_pace_next) {
        // Sleep to KL_STREAM_PACE_SPIN_MS (1.5) before the slot, then spin:
        // the kernel's wake-up is the jitter, not the clock.
        static double spin = -1;
        if (spin < 0) spin = kl_env_float("KL_STREAM_PACE_SPIN_MS", 1.5f) / 1000.0;
        double sleep_to = g_pace_next - spin;
        if (sleep_to > now) {
            uint64_t ticks = (uint64_t)((sleep_to - now) * 1e9 * tb.denom / tb.numer);
            mach_wait_until(mach_absolute_time() + ticks);
        }
        while (kl_stream_host_now() < g_pace_next) { /* spin */ }
        if (kl_stream_host_now() - g_pace_next > 0.001) S.wgp_wake_late++;
    } else if (now - g_pace_next > 0.002) {
        S.wgp_late++;
        // Overran its slot: start now and re-anchor the grid here. Never
        // catch up — a short frame after a long one is the 27/17 ms
        // alternation that reads as judder (measured: sd 6.5 ms that way).
        g_pace_next = now;
    }
    note_wgp(kl_stream_host_now());
    g_pace_next += g_pace_period;
}

void kl_stream_host_install_pacer(void) {
    float f = lock_fps();
    if (f <= 0) {
        fprintf(stderr, SH "frame rate NOT locked (KL_STREAM_LOCK_FPS=0): the guest runs free\n");
        return;
    }
    g_pace_period = 1.0 / f;
    kl_openvr_set_frame_pacer(pace_wait);
    // ...and xrWaitFrame, for an OpenXR guest (Metro Awakening): the same wait,
    // at the same place in its frame (before the pose latch).
    kl_openxr_set_frame_pacer(pace_wait);
    fprintf(stderr, SH "frame rate locked to %.1f fps: WaitGetPoses/xrWaitFrame paced to %.1f ms, the guest is "
                    "told a %.1f Hz display (KL_STREAM_LOCK_FPS=0 to run free)\n",
            (double)f, 1000.0 / f, (double)f);
}

static volatile int g_sig;
static void on_sig(int s) { (void)s; g_sig = 1; }

typedef struct { const volatile int *quit; } frame_args;

// The encoded eye size when KL_STREAM_SCALE is unset: the largest rect the
// guest submitted over the last ~60 frames (Alyx's dynamic resolution may
// alternate sizes frame to frame; the max is what keeps every frame 1:1 or
// downscaled, never upscaled), adopted once it has been the target for 30
// frames so a change re-creates the encoder (a keyframe) rarely. Even sizes.
static void pick_auto_size(int *fw, int *fh) {
    static int cur_w, cur_h, cand_w, cand_h, cand_n, said;
    static int hist_w[64], hist_h[64], hist_i;
    int w = 0, h = 0;
    for (int e = 0; e < 2; e++) {
        int ew = 0, eh = 0;
        if (kl_ovrp_submit_size(e, &ew, &eh)) { if (ew > w) w = ew; if (eh > h) h = eh; }
    }
    if (w <= 0 || h <= 0) {
        if (cur_w) { *fw = 2 * cur_w; *fh = cur_h; }
        return;   // nothing submitted yet: the HELLO-derived size
    }
    int w0 = w, h0 = h;
    int cap = kl_env_int("KL_STREAM_MAX_EYE", 0);
    if (cap > 0 && (w > cap || h > cap)) {
        double sc = (double)cap / (w > h ? w : h);
        w = (int)(w * sc + 0.5); h = (int)(h * sc + 0.5);
    }
    // The encoder's budget: VideoToolbox HEVC on the M1 Max takes ~2.4 ms per
    // megapixel of the side-by-side frame and does not overlap frames, so its
    // throughput is 1/latency (4608x1920 22 ms, 6144x2400 35.6 ms). 7 MP is
    // ~17 ms: 45 fps with room for the compose. 0 = no budget.
    float mpix = kl_env_float("KL_STREAM_MAX_MPIX", 7.0f);
    if (mpix > 0 && 2.0 * w * h > mpix * 1e6) {
        double sc = sqrt(mpix * 1e6 / (2.0 * w * h));
        w = (int)(w * sc + 0.5); h = (int)(h * sc + 0.5);
    }
    w = (w + 1) & ~1; h = (h + 1) & ~1;
    hist_w[hist_i % 64] = w; hist_h[hist_i % 64] = h; hist_i++;
    int mw = 0, mh = 0;
    for (int i = 0; i < 64 && i < hist_i; i++) {
        if (hist_w[i] > mw) mw = hist_w[i];
        if (hist_h[i] > mh) mh = hist_h[i];
    }
    if (!cur_w) { cur_w = mw; cur_h = mh; }
    else if (mw != cur_w || mh != cur_h) {
        if (mw == cand_w && mh == cand_h) cand_n++;
        else { cand_w = mw; cand_h = mh; cand_n = 1; }
        if (cand_n >= 30) { cur_w = cand_w; cur_h = cand_h; cand_n = 0; said = 0; }
    } else cand_n = 0;
    if (!said++)
        fprintf(stderr, SH "encode size follows the guest: it submits %dx%d per eye -> encoding "
                        "%dx%d (both eyes; KL_STREAM_MAX_MPIX %.1f / KL_STREAM_MAX_EYE cap it, "
                        "KL_STREAM_SCALE overrides)\n", w0, h0,
                2 * cur_w, cur_h, (double)kl_env_float("KL_STREAM_MAX_MPIX", 7.0f));
    *fw = 2 * cur_w; *fh = cur_h;
}

static void *frame_thread(void *arg) {
    const volatile int *quit = ((frame_args *)arg)->quit;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    unsigned long long last = kl_vulkan_frame_serial();
    int said_first = 0;
    while (!(quit && *quit) && !g_sig) {
        unsigned long long s = kl_vulkan_frame_serial();
        if (s == last) { usleep(500); continue; }
        last = s;
        {
            static double t_prev;
            double tn = kl_stream_host_now();
            if (t_prev > 0) {
                double iv = (tn - t_prev) * 1000.0;
                S.iv_sum += iv; S.iv_sq += iv * iv; S.iv_n++;
                if (iv > S.iv_max) S.iv_max = iv;
            }
            t_prev = tn;
        }
        // The haptics envelope: once per hand per guest frame (kl_ovrp.h), and
        // forwarded only while someone can feel it.
        pthread_mutex_lock(&g_mu);
        int on = C.active;
        int fw = C.frame_w, fh = C.frame_h, kbps = C.kbps;
        float fps = C.fps;
        pthread_mutex_unlock(&g_mu);
        for (int hand = 0; hand < 2; hand++) {
            float amp = 0, secs = 0;
            if (kl_ovrp_haptics_pull(hand, &amp, &secs) && on) {
                kl_stream_haptics hp;
                memset(&hp, 0, sizeof hp);
                hdr_init(&hp.h, KL_STREAM_HAPTICS);
                hp.hand = (uint32_t)hand;
                hp.amplitude = amp;
                hp.seconds = secs;
                send_client(&hp, sizeof hp);
            }
        }
        if (!on || fw <= 0) continue;
        int stage = kl_ovrp_last_complete_stage();
        if (stage < 0) continue;
        if (auto_size()) pick_auto_size(&fw, &fh);
        kl_ovrp_render_pose r;
        if (!kl_ovrp_stage_render_pose(stage, &r)) continue;
        kl_stream_frame_meta m;
        memset(&m, 0, sizeof m);
        m.pose_id = (uint32_t)r.head_tag;
        m.t_pose = r.head_time;
        memcpy(m.tan, r.tangents, sizeof m.tan);
        uint64_t now_ns = mono_ns();
        m.ms_render = r.submit_ns && now_ns > r.submit_ns ? (float)((now_ns - r.submit_ns) / 1e6) : 0;
        if (g_pose_ring[m.pose_id % POSE_RING].id == m.pose_id && r.head_tag &&
            g_pose_ring[m.pose_id % POSE_RING].t == r.head_time) {
            m.pose_host_ns = g_pose_ring[m.pose_id % POSE_RING].ns;
            // The tag's own check: the head the frame record says the guest
            // drew with must BE the head of the POSE we are about to echo.
            const float *q = g_pose_ring[m.pose_id % POSE_RING].q;
            // In double, from the vector part: acos of a float dot product near
            // 1 cannot resolve less than ~0.04 deg.
            double cx = (double)q[3] * r.qx - (double)q[0] * r.qw - ((double)q[1] * r.qz - (double)q[2] * r.qy);
            double cy = (double)q[3] * r.qy - (double)q[1] * r.qw - ((double)q[2] * r.qx - (double)q[0] * r.qz);
            double cz = (double)q[3] * r.qz - (double)q[2] * r.qw - ((double)q[0] * r.qy - (double)q[1] * r.qx);
            double sn = sqrt(cx * cx + cy * cy + cz * cz);
            float deg = (float)(2.0 * asin(sn > 1.0 ? 1.0 : sn) * 57.29577951308232);
            if (deg > S.tag_err_deg) S.tag_err_deg = deg;
        } else {
            // Rendered with no pose of THIS client's (before its first POSE, or
            // with the previous session's): pose_id 0 = "not yours".
            m.pose_id = 0;
            m.t_pose = 0;
            S.untagged++;
        }
        m.frame_id = g_frame_id + 1;
        // Busy skip: the sender is still on earlier frames, so this guest frame
        // is not encoded at all (see "frame out"). Nothing breaks: the next
        // encoded frame references the last one sent.
        static int txq_max = -1;
        if (txq_max < 0) txq_max = kl_env_int("KL_STREAM_TXQ_MAX", 2);
        if (txq_max > 0 && txq_depth() >= (unsigned)txq_max) { S.busy_skips++; continue; }
        // The adaptive bitrate (stats_tick), under the session's ceiling.
        int abr = g_abr_kbps;
        if (abr > 0 && abr < kbps) kbps = abr;
        // One keyframe per KL_STREAM_IDR_MIN_MS (500) at most: requests in
        // between (the client re-asking while the last keyframe is still in
        // flight, a burst of losses) are folded into the one already sent.
        static double idr_min = -1;
        if (idr_min < 0) idr_min = kl_env_int("KL_STREAM_IDR_MIN_MS", 500) / 1000.0;
        int idr = 0;
        if (g_idr) {
            if (kl_stream_host_now() - g_last_key_t >= idr_min)
                idr = __atomic_exchange_n(&g_idr, 0, __ATOMIC_ACQ_REL);
            else
                S.idr_deferred++;
        }
        int rc = kl_stream_enc_frame(stage, fw, fh, kbps, fps, idr, &m, on_encoded);
        if (rc == -2) S.skipped++;
        if (rc == 0 && idr) { g_last_key_t = kl_stream_host_now(); S.idr_forced++; }
        if (rc == 0) {
            static double t_prev_enc;
            double tn = kl_stream_host_now();
            if (t_prev_enc > 0) {
                double iv = (tn - t_prev_enc) * 1000.0;
                S.enc_sum += iv; S.enc_sq += iv * iv; S.enc_n++;
                if (iv > S.enc_max) S.enc_max = iv;
            }
            t_prev_enc = tn;
            g_frame_id++;
            if (!said_first) g_t_first_frame = kl_stream_host_now();
            if (!said_first++)
                fprintf(stderr, SH "first frame to the encoder: stage %d, pose_id %u, tangents "
                                "L(%.3f %.3f %.3f %.3f) R(%.3f %.3f %.3f %.3f)\n", stage, m.pose_id,
                        (double)m.tan[0][0], (double)m.tan[0][1], (double)m.tan[0][2],
                        (double)m.tan[0][3], (double)m.tan[1][0], (double)m.tan[1][1],
                        (double)m.tan[1][2], (double)m.tan[1][3]);
        } else if (idr) {
            g_idr = 1;    // not consumed
        }
    }
    return NULL;
}

#if __has_include(<SDL3/SDL.h>)
#include <SDL3/SDL.h>
#include <SDL3/SDL_metal.h>
static int preview_loop(const volatile int *quit) {
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        fprintf(stderr, SH "preview: SDL_Init failed: %s\n", SDL_GetError());
        return -1;
    }
    SDL_Window *win = SDL_CreateWindow("Klepton stream host (preview)", 1280, 640,
                                       SDL_WINDOW_METAL | SDL_WINDOW_RESIZABLE);
    SDL_MetalView mv = win ? SDL_Metal_CreateView(win) : NULL;
    void *layer = mv ? SDL_Metal_GetLayer(mv) : NULL;
    if (!layer) {
        fprintf(stderr, SH "preview: no Metal window (%s)\n", SDL_GetError());
        if (win) SDL_DestroyWindow(win);
        SDL_Quit();
        return -1;
    }
    while (!(quit && *quit) && !g_sig) {
        SDL_Event ev;
        while (SDL_PollEvent(&ev))
            if (ev.type == SDL_EVENT_QUIT || ev.type == SDL_EVENT_WINDOW_CLOSE_REQUESTED) g_sig = 1;
        int pw = 0, ph = 0;
        SDL_GetWindowSizeInPixels(win, &pw, &ph);
        kl_stream_preview_present(layer, pw, ph);
        SDL_Delay(16);
    }
    SDL_Metal_DestroyView(mv);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}
#else
static int preview_loop(const volatile int *quit) {
    (void)quit;
    fprintf(stderr, SH "preview: built without SDL3\n");
    return -1;
}
#endif

int kl_stream_host_run(const volatile int *quit) {
    __atomic_store_n(&g_guest_running, 1, __ATOMIC_RELEASE);
    g_t_boot = kl_stream_host_now();
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);
    static frame_args fa;
    fa.quit = quit;
    pthread_t ft, st;
    if (pthread_create(&st, NULL, sender_thread, NULL)) { perror(SH "pthread_create"); return 1; }
    pthread_detach(st);
    if (pthread_create(&ft, NULL, frame_thread, &fa)) { perror(SH "pthread_create"); return 1; }
    fprintf(stderr, SH "frame-out running (audio stays on this Mac's output in this milestone)%s\n",
            kl_env_on("KL_STREAM_PREVIEW", 0) ? "; preview window on" : "");
    if (!kl_env_on("KL_STREAM_PREVIEW", 0) || preview_loop(quit) != 0)
        while (!(quit && *quit) && !g_sig) usleep(20000);
    g_sig = 1;
    pthread_join(ft, NULL);
    // Tell the client we are going, then stop.
    if (send_bye_now()) fprintf(stderr, SH "stopping (%s): BYE sent to the headset\n",
                                g_sig ? "signal / preview closed" : "quit");
    kl_stream_enc_close();
    fprintf(stderr, SH "stopped: %llu frames encoded (%llu keyframes)\n", S.total_frames, S.total_key);
    return 0;
}
