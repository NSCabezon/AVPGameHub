// kl_stream_testhost — a tiny HOST for "Jugar desde el Mac", with a synthetic
// scene instead of a game, for testing the headset client
// (runtime/net/kl_stream_client.c + visionos/Sources/KleptonStreamClient.swift)
// without Alyx, without the real host and without a headset.
//
// It speaks runtime/net/kl_stream_proto.h exactly as the real host must:
//
//   * advertises KL_STREAM_BONJOUR (so the hub's "Jugar desde el Mac" button
//     lights up), listens on UDP KL_STREAM_PORT_DEFAULT;
//   * HELLO -> HELLO_ACK (version checked, BUSY for a second headset);
//   * renders, per eye, a WORLD-LOCKED grid computed from the newest POSE it
//     received (head pose x eye cant, through that eye's tangents from HELLO)
//     plus a head-locked label "L"/"R" and the frame/pose counters, side by
//     side into one BGRA CVPixelBuffer;
//   * encodes it HEVC with VTCompressionSession (real time, low-latency rate
//     control where available, no frame reordering, long GOP, keyframe on
//     IDR_REQUEST) and sends VIDEO fragments carrying the pose_id/t_pose echo
//     and the tangents it rendered with;
//   * answers PING with PONG, sends a HAPTICS buzz now and then
//     (KL_TESTHOST_HAPTICS_S), BYE on exit (Ctrl-C or KL_TESTHOST_SECONDS).
//
// A correct client shows the grid STILL in the world while the head turns —
// the picture is reprojected from the pose it was rendered with — and the
// labels riding with the head.
//
// Knobs (env):
//   KL_TESTHOST_PORT     9944     UDP port
//   KL_TESTHOST_NAME     host     Bonjour instance name
//   KL_TESTHOST_FPS      72       render/encode rate
//   KL_TESTHOST_EYE      1024     cap on the per-eye size (longest side)
//   KL_TESTHOST_KBPS     30000    average bitrate
//   KL_TESTHOST_GOP      600      frames between scheduled keyframes
//   KL_TESTHOST_DROP     0        probability of dropping each VIDEO packet (data or parity)
//   KL_STREAM_FEC        10       XOR parity packet per N fragments (0 = off)
//   KL_STREAM_PACE_MS    8        spread a frame's packets over this long (0 = burst)
//   KL_TESTHOST_HAPTICS_S 0       seconds between haptic buzzes (0 = never)
//   KL_TESTHOST_SECONDS  0        run time, then BYE and exit (0 = forever)
//   KL_TESTHOST_LOWLAT   1        try EnableLowLatencyRateControl
//   KL_TESTHOST_BOOT_S   0        after a new client's HELLO, no video for this long:
//                                 STATUS says BOOTING (a game loading on the Mac)
//   KL_TESTHOST_VANISH   0        1: end without a BYE (a host that died) — the
//                                 client must notice the silence on its own
//
// Build: make build/kl_stream_testhost      Run: ./build/kl_stream_testhost

#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#include <dns_sd.h>
#include <arpa/inet.h>
#include <mach/mach_time.h>
#include <math.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "kl_stream_proto.h"
#include "kl_stream_tx.h"

static double now_s(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom * 1e-9;
}
static int env_int(const char *k, int d) { const char *v = getenv(k); return v && *v ? atoi(v) : d; }
static double env_f(const char *k, double d) { const char *v = getenv(k); return v && *v ? atof(v) : d; }

// ---------------------------------------------------------------------------
// state shared between the receive thread and the render loop

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_fd = -1;
static struct sockaddr_storage g_client;
static socklen_t g_client_len;
static int g_have_client;
static double g_client_last;          // last packet from the client
static double g_client_t0;            // when the current client's first HELLO came
static kl_stream_hello g_hello;
static kl_stream_pose g_pose;         // newest POSE
static int g_have_pose;
static int g_idr_wanted;
static uint32_t g_seq[16];
static uint32_t g_frame_w, g_frame_h; // encoded frame (both eyes)
static atomic_int g_quit;
static unsigned g_poses_rx, g_idr_rx;
static double g_rtt_ms;

static void send_to_client(void *pkt, size_t n, uint16_t type) {
    kl_stream_hdr *h = pkt;
    h->magic = KL_STREAM_MAGIC;
    h->version = KL_STREAM_VERSION;
    h->type = type;
    h->seq = g_seq[type & 15]++;
    if (g_have_client)
        sendto(g_fd, pkt, n, 0, (struct sockaddr *)&g_client, g_client_len);
}

static int same_addr(const struct sockaddr_storage *a, socklen_t al,
                     const struct sockaddr_storage *b, socklen_t bl) {
    return al == bl && memcmp(a, b, al) == 0;
}

static void addr_str(const struct sockaddr_storage *a, char *out, size_t n) {
    char ip[INET6_ADDRSTRLEN] = "?";
    int port = 0;
    if (a->ss_family == AF_INET) {
        const struct sockaddr_in *s = (const void *)a;
        inet_ntop(AF_INET, &s->sin_addr, ip, sizeof ip); port = ntohs(s->sin_port);
    } else if (a->ss_family == AF_INET6) {
        const struct sockaddr_in6 *s = (const void *)a;
        inet_ntop(AF_INET6, &s->sin6_addr, ip, sizeof ip); port = ntohs(s->sin6_port);
    }
    snprintf(out, n, "%s:%d", ip, port);
}

static void choose_frame_size(void) {
    // The client's recommended eye size, capped (the synthetic scene is drawn
    // on the CPU) and rounded to 16 so no encoder crop/pad is involved.
    int cap = env_int("KL_TESTHOST_EYE", 1024);
    double w = g_hello.eye_w ? g_hello.eye_w : 1024, h = g_hello.eye_h ? g_hello.eye_h : 1024;
    double s = fmin(1.0, cap / fmax(w, h));
    int ew = ((int)(w * s) + 15) & ~15, eh = ((int)(h * s) + 15) & ~15;
    g_frame_w = (uint32_t)(ew * 2);
    g_frame_h = (uint32_t)eh;
}

static void *rx_main(void *arg) {
    uint8_t buf[65536];
    while (!atomic_load(&g_quit)) {
        struct sockaddr_storage from;
        socklen_t fl = sizeof from;
        ssize_t n = recvfrom(g_fd, buf, sizeof buf, 0, (struct sockaddr *)&from, &fl);
        if (n < (ssize_t)sizeof(kl_stream_hdr)) continue;
        kl_stream_hdr h;
        memcpy(&h, buf, sizeof h);
        if (h.magic != KL_STREAM_MAGIC) continue;
        char who[96];
        addr_str(&from, who, sizeof who);
        pthread_mutex_lock(&g_mu);
        int from_client = g_have_client && same_addr(&from, fl, &g_client, g_client_len);
        if (from_client) g_client_last = now_s();
        switch (h.type) {
        case KL_STREAM_HELLO: {
            kl_stream_hello_ack a = {0};
            a.codec = 0x31637668;   // 'hvc1'
            snprintf(a.guest, sizeof a.guest, "testhost");
            if (h.version != KL_STREAM_VERSION || n < (ssize_t)sizeof(kl_stream_hello)) {
                a.status = KL_STREAM_ERR_VERSION;
            } else if (g_have_client && !from_client && now_s() - g_client_last < 3.0) {
                a.status = KL_STREAM_ERR_BUSY;
            } else {
                int fresh = !from_client;
                memcpy(&g_hello, buf, sizeof g_hello);
                g_hello.device[sizeof g_hello.device - 1] = 0;
                g_client = from; g_client_len = fl; g_have_client = 1;
                g_client_last = now_s();
                choose_frame_size();
                g_idr_wanted = 1;
                a.status = KL_STREAM_OK;
                if (fresh) {
                    const kl_stream_eye *e = g_hello.eye;
                    printf("[testhost] HELLO from %s (%s): %.2f Hz, eye %ux%u, "
                           "L tan(%.3f %.3f %.3f %.3f) R tan(%.3f %.3f %.3f %.3f), "
                           "ipd %.1f mm -> encoding %ux%u\n", who, g_hello.device,
                           g_hello.display_hz, g_hello.eye_w, g_hello.eye_h,
                           e[0].tan_left, e[0].tan_right, e[0].tan_up, e[0].tan_down,
                           e[1].tan_left, e[1].tan_right, e[1].tan_up, e[1].tan_down,
                           (e[1].offset.x - e[0].offset.x) * 1000, g_frame_w, g_frame_h);
                    g_have_pose = 0;
                    g_client_t0 = now_s();
                }
            }
            a.frame_w = g_frame_w; a.frame_h = g_frame_h;
            a.bitrate_kbps = (uint32_t)env_int("KL_TESTHOST_KBPS", 30000);
            a.host_fps_target = (float)env_f("KL_TESTHOST_FPS", 72);
            // Reply to the sender even when refusing it.
            struct sockaddr_storage keep = g_client; socklen_t kl = g_client_len; int kh = g_have_client;
            g_client = from; g_client_len = fl; g_have_client = 1;
            send_to_client(&a, sizeof a, KL_STREAM_HELLO_ACK);
            if (a.status != KL_STREAM_OK) {
                printf("[testhost] refused HELLO from %s: status %u\n", who, a.status);
                g_client = keep; g_client_len = kl; g_have_client = kh;
            }
            break;
        }
        case KL_STREAM_POSE:
            if (from_client && n >= (ssize_t)sizeof(kl_stream_pose)) {
                kl_stream_pose p;
                memcpy(&p, buf, sizeof p);
                if (!g_have_pose || (int32_t)(p.pose_id - g_pose.pose_id) > 0) g_pose = p;
                g_have_pose = 1;
                g_poses_rx++;
            }
            break;
        case KL_STREAM_IDR_REQUEST:
            if (from_client) { g_idr_wanted = 1; g_idr_rx++; }
            break;
        case KL_STREAM_PING:
            if (from_client && n >= (ssize_t)sizeof(kl_stream_ping)) {
                kl_stream_ping p;
                memcpy(&p, buf, sizeof p);
                p.t_reply = now_s();
                send_to_client(&p, sizeof p, KL_STREAM_PONG);
            }
            break;
        case KL_STREAM_PONG:
            if (from_client && n >= (ssize_t)sizeof(kl_stream_ping)) {
                kl_stream_ping p;
                memcpy(&p, buf, sizeof p);
                g_rtt_ms = (now_s() - p.t_send) * 1000;
            }
            break;
        case KL_STREAM_BYE:
            if (from_client) {
                printf("[testhost] BYE from %s — waiting for the next HELLO\n", who);
                g_have_client = 0; g_have_pose = 0;
            }
            break;
        }
        pthread_mutex_unlock(&g_mu);
    }
    return NULL;
}

// ---------------------------------------------------------------------------
// the synthetic scene

typedef struct { float x, y, z, w; } quat;
static quat qmul(quat a, quat b) {
    return (quat){ a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
                   a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
                   a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w,
                   a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z };
}
static void qrot(quat q, const float v[3], float o[3]) {
    // o = q v q*
    float tx = 2 * (q.y * v[2] - q.z * v[1]);
    float ty = 2 * (q.z * v[0] - q.x * v[2]);
    float tz = 2 * (q.x * v[1] - q.y * v[0]);
    o[0] = v[0] + q.w * tx + (q.y * tz - q.z * ty);
    o[1] = v[1] + q.w * ty + (q.z * tx - q.x * tz);
    o[2] = v[2] + q.w * tz + (q.x * ty - q.y * tx);
}

// One eye into its half of the BGRA buffer. Pure function of the view
// direction: a world-locked panorama with a 10-degree grid, a red meridian at
// yaw 0 (straight ahead at session start, -Z), a green horizon, 90-degree
// quadrants tinted differently, and checkers below the horizon.
static void render_eye(uint8_t *base, size_t stride, int x0, int ew, int eh,
                       quat view, const kl_stream_eye *eye) {
    float tl = eye->tan_left, tr = eye->tan_right, tu = eye->tan_up, td = eye->tan_down;
    if (!(tl > 0 && tr > 0 && tu > 0 && td > 0)) tl = tr = tu = td = 1;
    // Shaded in 2x2 blocks: the scene is a CPU loop with a handful of trig
    // calls per sample, and a full-resolution pass caps the host near 25 fps.
    dispatch_apply((size_t)(eh / 2), dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(size_t yb) {
        size_t y = yb * 2;
        uint8_t *row = base + y * stride + (size_t)x0 * 4;
        uint8_t *row2 = row + stride;
        float vy = tu - ((float)y + 1.0f) / eh * (tu + td);
        // Grid line half-width in degrees, roughly 1.5 px at this resolution.
        float px_deg = (atanf(tl) + atanf(tr)) * 57.29578f / ew;
        float lw = 0.75f * px_deg * 2;
        for (int x = 0; x + 1 < ew; x += 2) {
            float vx = -tl + ((float)x + 1.0f) / ew * (tl + tr);
            float d0[3] = { vx, vy, -1 }, d[3];
            qrot(view, d0, d);
            float inv = 1.0f / sqrtf(d[0]*d[0] + d[1]*d[1] + d[2]*d[2]);
            d[0] *= inv; d[1] *= inv; d[2] *= inv;
            float yaw = atan2f(d[0], -d[2]) * 57.29578f;      // 0 = -Z, + = right
            float pitch = asinf(fmaxf(-1, fminf(1, d[1]))) * 57.29578f;
            float r, g, b;
            int quad = (int)floorf((yaw + 180.0f) / 90.0f) & 3;
            static const float tint[4][3] = { {0.20f,0.22f,0.45f}, {0.40f,0.22f,0.30f},
                                              {0.18f,0.38f,0.30f}, {0.38f,0.36f,0.18f} };
            r = tint[quad][0]; g = tint[quad][1]; b = tint[quad][2];
            if (pitch < 0) {
                int ck = ((int)floorf(yaw / 15.0f) + (int)floorf(pitch / 15.0f)) & 1;
                float k = ck ? 0.55f : 0.35f;
                r *= k; g *= k; b *= k;
            } else {
                float k = 0.6f + 0.4f * pitch / 90.0f;
                r *= k; g *= k; b *= k;
            }
            // 10-degree grid (yaw lines thin towards the poles naturally).
            float fy = fabsf(remainderf(yaw, 10.0f)), fp = fabsf(remainderf(pitch, 10.0f));
            float lwy = lw / fmaxf(0.15f, cosf(pitch / 57.29578f));
            if (fy < lwy || fp < lw) { r = g = b = 0.92f; }
            if (fabsf(yaw) < lwy * 2.5f && fabsf(pitch) < 80) { r = 1; g = 0.15f; b = 0.1f; }
            if (fabsf(pitch) < lw * 2.5f) { r = 0.1f; g = 1; b = 0.2f; }
            uint32_t px = (uint32_t)(fminf(b, 1) * 255) | (uint32_t)(fminf(g, 1) * 255) << 8
                        | (uint32_t)(fminf(r, 1) * 255) << 16 | 0xff000000u;
            memcpy(row + x * 4, &px, 4);  memcpy(row + x * 4 + 4, &px, 4);
            memcpy(row2 + x * 4, &px, 4); memcpy(row2 + x * 4 + 4, &px, 4);
        }
    });
}

static void draw_text(CGContextRef cg, const char *s, double size, double x, double y,
                      CGColorRef color) {
    CTFontRef font = CTFontCreateWithName(CFSTR("Menlo-Bold"), size, NULL);
    CFStringRef str = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
    const void *k[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
    const void *v[] = { font, color };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef as = CFAttributedStringCreate(NULL, str, attrs);
    CTLineRef line = CTLineCreateWithAttributedString(as);
    CGContextSetTextPosition(cg, x, y);
    CTLineDraw(line, cg);
    CFRelease(line); CFRelease(as); CFRelease(attrs); CFRelease(str); CFRelease(font);
}

// Head-locked overlay: the eye's letter in the middle of its own frustum and
// the counters, drawn into the CVPixelBuffer through CoreGraphics.
static void render_labels(CVPixelBufferRef pb, int ew, int eh, uint32_t frame_id,
                          const kl_stream_pose *p) {
    void *base = CVPixelBufferGetBaseAddress(pb);
    size_t stride = CVPixelBufferGetBytesPerRow(pb);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg = CGBitmapContextCreate(base, (size_t)ew * 2, (size_t)eh, 8, stride, cs,
                                            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!cg) return;
    CGColorRef white = CGColorCreateGenericRGB(1, 1, 1, 1);
    CGColorRef black = CGColorCreateGenericRGB(0, 0, 0, 0.6);
    for (int e = 0; e < 2; e++) {
        // Centre of the eye's own frustum (tangent 0,0) in pixels.
        const kl_stream_eye *eye = &g_hello.eye[e];
        float tl = eye->tan_left > 0 ? eye->tan_left : 1, tr = eye->tan_right > 0 ? eye->tan_right : 1;
        float tu = eye->tan_up > 0 ? eye->tan_up : 1, td = eye->tan_down > 0 ? eye->tan_down : 1;
        double cx = e * ew + ew * tl / (tl + tr);
        double cy_top = eh * tu / (tu + td);           // from the top
        double sz = eh * 0.16;
        CGContextSetFillColorWithColor(cg, black);
        CGContextFillRect(cg, CGRectMake(cx - sz * 0.45, eh - cy_top - sz * 0.42, sz * 0.9, sz * 0.95));
        draw_text(cg, e ? "R" : "L", sz, cx - sz * 0.31, eh - cy_top - sz * 0.3, white);
        char line[160];
        snprintf(line, sizeof line, "frame %u  pose %u", frame_id, p ? p->pose_id : 0);
        double fs = eh * 0.035;
        CGContextSetFillColorWithColor(cg, black);
        CGContextFillRect(cg, CGRectMake(e * ew + fs, eh - fs * 3.2, fs * 13, fs * 1.6));
        draw_text(cg, line, fs, e * ew + fs * 1.4, eh - fs * 2.6, white);
        if (p) {
            snprintf(line, sizeof line, "head %+.2f %+.2f %+.2f", p->head_pos.x, p->head_pos.y,
                     p->head_pos.z);
            CGContextSetFillColorWithColor(cg, black);
        CGContextFillRect(cg, CGRectMake(e * ew + fs, eh - fs * 5.0, fs * 13, fs * 1.6));
            draw_text(cg, line, fs, e * ew + fs * 1.4, eh - fs * 4.4, white);
        }
    }
    CGColorRelease(white); CGColorRelease(black);
    CGContextRelease(cg);
}

// ---------------------------------------------------------------------------
// encode + send

static VTCompressionSessionRef g_enc;
static uint32_t g_enc_w, g_enc_h;
static uint32_t g_frame_id;
static uint64_t g_bytes_sent;
static unsigned g_frames_sent, g_keyframes;

typedef struct {
    uint32_t pose_id; double t_pose; float tan[2][4];
    double t_render0, t_render1, t_enc0;
} frame_meta;

static int tx_send(void *ctx, void *pkt, size_t n) {
    (void)ctx;
    pthread_mutex_lock(&g_mu);
    int ok = g_have_client;
    send_to_client(pkt, n, KL_STREAM_VIDEO);
    pthread_mutex_unlock(&g_mu);
    return ok ? 0 : -1;
}

// Through the real host's sender (runtime/net/kl_stream_tx.c): same FEC and
// pacing knobs (KL_STREAM_FEC, KL_STREAM_PACE_MS), plus KL_TESTHOST_DROP.
static unsigned g_fec_parity, g_tx_dropped;
static void send_frame(const uint8_t *data, size_t len, const frame_meta *m, int key) {
    static double drop = -1, pace_s;
    static int fec;
    if (drop < 0) {
        drop = env_f("KL_TESTHOST_DROP", 0);
        fec = env_int("KL_STREAM_FEC", 10);
        pace_s = env_f("KL_STREAM_PACE_MS", 8) / 1000.0;
        printf("[testhost] sender: FEC %d, pace %.1f ms, drop %.3f\n", fec, pace_s * 1000, drop);
    }
    uint32_t id = ++g_frame_id;
    kl_stream_video v = {0};
    v.frame_id = id;
    v.pose_id = m->pose_id;
    v.t_pose = m->t_pose;
    v.flags = key ? KL_STREAM_VIDEO_KEYFRAME : 0;
    memcpy(v.tan, m->tan, sizeof v.tan);
    v.host_ms_render = (float)((m->t_render1 - m->t_render0) * 1000);
    v.host_ms_encode = (float)((now_s() - m->t_enc0) * 1000);
    kl_stream_tx_result r;
    if (kl_stream_tx_frame(&v, data, len, fec, pace_s, NULL, drop, tx_send, NULL, &r) != 0) return;
    g_fec_parity += r.parity;
    g_tx_dropped += r.dropped;
    g_bytes_sent += len;
    g_frames_sent++;
    if (key) g_keyframes++;
}

static void on_encoded(const frame_meta *m, OSStatus st, CMSampleBufferRef sb) {
    if (st != noErr || !sb) { fprintf(stderr, "[testhost] encode failed: %d\n", (int)st); return; }
    CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    int key = 1;
    if (att && CFArrayGetCount(att) > 0) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(att, 0);
        CFBooleanRef notsync = CFDictionaryGetValue(d, kCMSampleAttachmentKey_NotSync);
        key = !(notsync && CFBooleanGetValue(notsync));
    }
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t blen = CMBlockBufferGetDataLength(bb);
    NSMutableData *out = [NSMutableData dataWithCapacity:blen + 512];
    if (key) {
        // VPS, SPS, PPS as the keyframe's leading NAL units, 4-byte BE lengths.
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
        size_t count = 0; int hlen = 0;
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, 0, NULL, NULL, &count, &hlen);
        for (size_t i = 0; i < count; i++) {
            const uint8_t *ps; size_t psl;
            if (CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, i, &ps, &psl, NULL, NULL) != noErr)
                continue;
            uint8_t be[4] = { (uint8_t)(psl >> 24), (uint8_t)(psl >> 16), (uint8_t)(psl >> 8), (uint8_t)psl };
            [out appendBytes:be length:4];
            [out appendBytes:ps length:psl];
        }
    }
    size_t at = out.length;
    out.length = at + blen;
    CMBlockBufferCopyDataBytes(bb, 0, blen, (uint8_t *)out.mutableBytes + at);
    send_frame(out.bytes, out.length, m, key);
}

static int make_encoder(uint32_t w, uint32_t h) {
    if (g_enc) {
        VTCompressionSessionCompleteFrames(g_enc, kCMTimeInvalid);
        VTCompressionSessionInvalidate(g_enc);
        CFRelease(g_enc);
        g_enc = NULL;
    }
    int lowlat = env_int("KL_TESTHOST_LOWLAT", 1);
    for (int attempt = 0; attempt < 2; attempt++) {
        int ll = lowlat && attempt == 0;
        CFMutableDictionaryRef spec = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(spec, kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder, kCFBooleanTrue);
        if (ll) CFDictionarySetValue(spec, kVTVideoEncoderSpecification_EnableLowLatencyRateControl, kCFBooleanTrue);
        OSStatus st = VTCompressionSessionCreate(NULL, (int32_t)w, (int32_t)h, kCMVideoCodecType_HEVC,
                                                 spec, NULL, NULL, NULL, NULL, &g_enc);
        CFRelease(spec);
        if (st != noErr) {
            fprintf(stderr, "[testhost] VTCompressionSessionCreate (%s) failed: %d\n",
                    ll ? "low latency" : "plain", (int)st);
            g_enc = NULL;
            continue;
        }
        int kbps = env_int("KL_TESTHOST_KBPS", 30000), gop = env_int("KL_TESTHOST_GOP", 600);
        double fps = env_f("KL_TESTHOST_FPS", 72);
        int32_t bps = kbps * 1000;
        CFNumberRef nb = CFNumberCreate(NULL, kCFNumberSInt32Type, &bps);
        CFNumberRef ng = CFNumberCreate(NULL, kCFNumberIntType, &gop);
        CFNumberRef nf = CFNumberCreate(NULL, kCFNumberDoubleType, &fps);
        VTSessionSetProperty(g_enc, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
        VTSessionSetProperty(g_enc, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
        VTSessionSetProperty(g_enc, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel);
        VTSessionSetProperty(g_enc, kVTCompressionPropertyKey_AverageBitRate, nb);
        VTSessionSetProperty(g_enc, kVTCompressionPropertyKey_MaxKeyFrameInterval, ng);
        VTSessionSetProperty(g_enc, kVTCompressionPropertyKey_ExpectedFrameRate, nf);
        CFRelease(nb); CFRelease(ng); CFRelease(nf);
        VTCompressionSessionPrepareToEncodeFrames(g_enc);
        g_enc_w = w; g_enc_h = h;
        printf("[testhost] HEVC encoder %ux%u, %d kbps, GOP %d, %s rate control\n", w, h, kbps, gop,
               ll ? "low-latency" : "default");
        return 0;
    }
    return -1;
}

// ---------------------------------------------------------------------------

static DNSServiceRef g_dns;

static void on_signal(int s) { atomic_store(&g_quit, 1); }

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        int port = env_int("KL_TESTHOST_PORT", KL_STREAM_PORT_DEFAULT);
        g_fd = socket(AF_INET6, SOCK_DGRAM, 0);
        int off = 0;
        setsockopt(g_fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof off);
        int big = 4 << 20;
        setsockopt(g_fd, SOL_SOCKET, SO_SNDBUF, &big, sizeof big);
        struct sockaddr_in6 a = { .sin6_family = AF_INET6, .sin6_port = htons((uint16_t)port),
                                  .sin6_addr = in6addr_any, .sin6_len = sizeof a };
        if (bind(g_fd, (struct sockaddr *)&a, sizeof a) != 0) {
            perror("[testhost] bind");
            return 1;
        }
        struct timeval tv = { 0, 200000 };
        setsockopt(g_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);

        char hn[128] = "Klepton test host";
        const char *name = getenv("KL_TESTHOST_NAME");
        if (!name || !*name) {
            NSString *h = [[NSHost currentHost] localizedName];
            if (h.length) snprintf(hn, sizeof hn, "%s (test)", h.UTF8String);
            name = hn;
        }
        DNSServiceErrorType de = DNSServiceRegister(&g_dns, 0, 0, name, KL_STREAM_BONJOUR, NULL, NULL,
                                                    htons((uint16_t)port), 0, NULL, NULL, NULL);
        if (de == kDNSServiceErr_NoError) DNSServiceSetDispatchQueue(g_dns, dispatch_get_main_queue());
        printf("[testhost] listening on UDP %d, Bonjour %s \"%s\" (%s)\n", port, KL_STREAM_BONJOUR,
               name, de == kDNSServiceErr_NoError ? "registered" : "FAILED");

        signal(SIGINT, on_signal);
        signal(SIGTERM, on_signal);
        pthread_t rx;
        pthread_create(&rx, NULL, rx_main, NULL);

        double fps = env_f("KL_TESTHOST_FPS", 72);
        double period = 1.0 / fps;
        double run_s = env_f("KL_TESTHOST_SECONDS", 0);
        double hap_s = env_f("KL_TESTHOST_HAPTICS_S", 0);
        double t_start = now_s(), next = t_start, last_report = t_start, last_ping = 0, last_hap = t_start;
        double last_idr = -1;
        CVPixelBufferPoolRef pool = NULL;
        uint32_t pool_w = 0, pool_h = 0;
        unsigned rendered = 0, hap_hand = 0;
        double boot_s = env_f("KL_TESTHOST_BOOT_S", 0);
        int was_booting = -1;

        while (!atomic_load(&g_quit)) {
            // Run the main queue briefly (Bonjour callbacks) and pace.
            double now = now_s();
            if (next > now) {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, next - now, true);
                continue;
            }
            next += period;
            if (next < now) next = now + period;   // fell behind: do not burst
            if (run_s > 0 && now - t_start > run_s) break;

            pthread_mutex_lock(&g_mu);
            int have = g_have_client;
            int stale = have && now - g_client_last > 5.0;
            if (stale) {
                printf("[testhost] client silent for 5 s — dropping it\n");
                g_have_client = 0; g_have_pose = 0; have = 0;
            }
            kl_stream_pose pose = g_pose;
            int have_pose = g_have_pose;
            kl_stream_hello hello = g_hello;
            uint32_t fw = g_frame_w, fh = g_frame_h;
            int idr = g_idr_wanted;
            if (idr && (last_idr < 0 || now - last_idr > 0.1)) { g_idr_wanted = 0; last_idr = now; }
            else idr = 0;
            pthread_mutex_unlock(&g_mu);

            // KL_TESTHOST_BOOT_S: the "game" is still loading — keepalive, no video.
            pthread_mutex_lock(&g_mu);
            double since_hello = now - g_client_t0;
            pthread_mutex_unlock(&g_mu);
            int booting = have && since_hello < boot_s;
            if (have && (now - last_ping > 1.0 || booting != was_booting)) {
                kl_stream_ping p = { .t_send = now };
                kl_stream_keepalive k = { .state = booting ? KL_STREAM_HOST_BOOTING : KL_STREAM_HOST_RUNNING,
                                          .seconds = (float)(booting ? since_hello : since_hello - boot_s),
                                          .guest_frames = rendered };
                pthread_mutex_lock(&g_mu);
                send_to_client(&p, sizeof p, KL_STREAM_PING);
                send_to_client(&k, sizeof k, KL_STREAM_STATUS);
                pthread_mutex_unlock(&g_mu);
                if (booting != was_booting)
                    printf("[testhost] STATUS %s\n", booting ? "BOOTING (no video yet)" : "RUNNING");
                was_booting = booting;
                last_ping = now;
            }
            if (have && hap_s > 0 && now - last_hap > hap_s) {
                kl_stream_haptics h = { .hand = hap_hand, .amplitude = 0.8f, .seconds = 0.15f };
                pthread_mutex_lock(&g_mu);
                send_to_client(&h, sizeof h, KL_STREAM_HAPTICS);
                pthread_mutex_unlock(&g_mu);
                printf("[testhost] HAPTICS hand %u 0.8 x 0.15 s\n", hap_hand);
                hap_hand ^= 1; last_hap = now;
            }
            if (now - last_report >= 1.0) {
                double dt = now - last_report;
                pthread_mutex_lock(&g_mu);
                unsigned prx = g_poses_rx, irx = g_idr_rx; g_poses_rx = 0;
                double rtt = g_rtt_ms;
                pthread_mutex_unlock(&g_mu);
                if (have)
                    printf("[testhost] sent %.1f fps (%u key total), %.1f Mbps, poses in %.1f/s "
                           "(last id %u, age %.1f ms), IDR requests %u, rtt %.1f ms, "
                           "parity %u, dropped %u\n",
                           g_frames_sent / dt, g_keyframes, g_bytes_sent * 8 / dt / 1e6, prx / dt,
                           pose.pose_id, have_pose ? (now - pose.t_pose) * 1000 : 0, irx, rtt,
                           g_fec_parity, g_tx_dropped);
                g_frames_sent = 0; g_bytes_sent = 0; last_report = now;
            }
            if (!have || !fw || !fh || booting) continue;

            if (!g_enc || g_enc_w != fw || g_enc_h != fh) {
                if (make_encoder(fw, fh) != 0) { fprintf(stderr, "[testhost] no encoder\n"); break; }
                idr = 1;
            }
            if (!pool || pool_w != fw || pool_h != fh) {
                if (pool) CVPixelBufferPoolRelease(pool);
                NSDictionary *attrs = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                                         (id)kCVPixelBufferWidthKey: @(fw),
                                         (id)kCVPixelBufferHeightKey: @(fh),
                                         (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
                CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &pool);
                pool_w = fw; pool_h = fh;
            }
            CVPixelBufferRef pb = NULL;
            if (CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pb) != kCVReturnSuccess) continue;

            frame_meta m = {0};
            m.t_render0 = now_s();
            quat head = { 0, 0, 0, 1 };
            if (have_pose) {
                head = (quat){ pose.head_rot.x, pose.head_rot.y, pose.head_rot.z, pose.head_rot.w };
                m.pose_id = pose.pose_id;
                m.t_pose = pose.t_pose;
            }
            CVPixelBufferLockBaseAddress(pb, 0);
            uint8_t *base = CVPixelBufferGetBaseAddress(pb);
            size_t stride = CVPixelBufferGetBytesPerRow(pb);
            int ew = (int)fw / 2, eh = (int)fh;
            for (int e = 0; e < 2; e++) {
                const kl_stream_eye *eye = &hello.eye[e];
                quat er = { eye->rotation.x, eye->rotation.y, eye->rotation.z, eye->rotation.w };
                if (er.x == 0 && er.y == 0 && er.z == 0 && er.w == 0) er.w = 1;
                render_eye(base, stride, e * ew, ew, eh, qmul(head, er), eye);
                m.tan[e][0] = eye->tan_left > 0 ? eye->tan_left : 1;
                m.tan[e][1] = eye->tan_right > 0 ? eye->tan_right : 1;
                m.tan[e][2] = eye->tan_up > 0 ? eye->tan_up : 1;
                m.tan[e][3] = eye->tan_down > 0 ? eye->tan_down : 1;
            }
            render_labels(pb, ew, eh, g_frame_id + 1, have_pose ? &pose : NULL);
            CVPixelBufferUnlockBaseAddress(pb, 0);
            m.t_render1 = now_s();
            m.t_enc0 = m.t_render1;

            NSDictionary *props = idr ? @{ (id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES } : nil;
            CMTime pts = CMTimeMake((int64_t)rendered, (int32_t)lround(fps));
            frame_meta *mp = malloc(sizeof *mp);
            *mp = m;
            OSStatus st = VTCompressionSessionEncodeFrameWithOutputHandler(
                g_enc, pb, pts, kCMTimeInvalid, (__bridge CFDictionaryRef)props, NULL,
                ^(OSStatus s, VTEncodeInfoFlags f, CMSampleBufferRef sb) { on_encoded(mp, s, sb); free(mp); });
            if (st != noErr) { fprintf(stderr, "[testhost] encode submit failed: %d\n", (int)st); free(mp); }
            // No CompleteFrames here: with reordering off the encoder emits each
            // frame as soon as it is done, on its own thread, while this loop
            // shades the next one.
            CVPixelBufferRelease(pb);
            rendered++;
            if (idr) printf("[testhost] keyframe forced (frame %u)\n", g_frame_id);
        }

        if (env_int("KL_TESTHOST_VANISH", 0)) {
            printf("[testhost] exiting WITHOUT a BYE (KL_TESTHOST_VANISH=1)\n");
        } else {
            printf("[testhost] exiting — BYE\n");
            pthread_mutex_lock(&g_mu);
            for (int i = 0; i < 3; i++) { kl_stream_hdr b = {0}; send_to_client(&b, sizeof b, KL_STREAM_BYE); }
            pthread_mutex_unlock(&g_mu);
        }
        atomic_store(&g_quit, 1);
        pthread_join(rx, NULL);
        if (g_dns) DNSServiceRefDeallocate(g_dns);
        return 0;
    }
}
