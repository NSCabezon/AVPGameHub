// kl_stream_fakeclient — a stand-in for the headset side of "Jugar desde el
// Mac", for testing the host (KL_STREAM_HOST=1) with no Vision Pro.
//
// It says HELLO with a Vision Pro-like display (tangents l=1.7321 r=1.0 u=1.0
// d=1.1918 on eye 0, mirrored on eye 1, IPD 66.9 mm, 90 Hz, 1888x1824 per
// eye), then sends POSE at 90 Hz with a slowly yawing head, receives VIDEO,
// reassembles it, decodes it with VTDecompressionSession, writes every Nth
// decoded frame as a PNG, and prints once a second: frames received / decoded
// / lost, mean latency from the POSE send to the VIDEO frame complete (matched
// by the echoed pose_id), decode ms, bitrate and RTT.
//
//   build/kl_stream_fakeclient [-h host] [-p port] [-o dir] [-n every] [-t secs]
//                              [-a yaw_amp_deg] [-P period_s] [-b max_kbps]
//                              [-e WxH eye size] [-z display_hz] [-f tangent_scale]
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <VideoToolbox/VideoToolbox.h>

#include <arpa/inet.h>
#include <errno.h>
#include <math.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "kl_stream_proto.h"

static double now_s(void) {   // CLOCK_UPTIME_RAW == CACurrentMediaTime, the headset's clock
    struct timespec t;
    clock_gettime(CLOCK_UPTIME_RAW, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static int g_fd;
static uint32_t g_seq[16];
static void hdr(kl_stream_hdr *h, uint16_t type) {
    h->magic = KL_STREAM_MAGIC;
    h->version = KL_STREAM_VERSION;
    h->type = type;
    h->seq = __atomic_fetch_add(&g_seq[type & 15], 1, __ATOMIC_RELAXED);
}
static void tx(const void *p, size_t n) { send(g_fd, p, n, 0); }

// ---- options ----
static const char *o_host = "127.0.0.1", *o_dir = NULL;
static int o_port = KL_STREAM_PORT_DEFAULT, o_every = 30, o_kbps = 0, o_eye_w = 1888, o_eye_h = 1824;
static float o_hz = 90, o_tan_scale = 1;
static double o_secs = 30, o_amp = 25, o_period = 8;

// ---- poses ----
#define RING 4096
static struct { uint32_t id; double t_send, t_pose; float yaw; } g_sent[RING];
static volatile int g_streaming, g_stop;
static double g_t0;

static void *pose_thread(void *arg) {
    (void)arg;
    uint32_t id = 0;
    double next = now_s();
    while (!g_stop) {
        double t = now_s();
        if (t < next) { usleep((useconds_t)((next - t) * 1e6)); continue; }
        next += 1.0 / 90.0;
        if (t - next > 0.1) next = t;
        if (!g_streaming) continue;
        kl_stream_pose p;
        memset(&p, 0, sizeof p);
        hdr(&p.h, KL_STREAM_POSE);
        p.pose_id = ++id;
        // The pose is "about" the instant it would be presented: a real
        // headset predicts its DeviceAnchor ~2 frames ahead. The host never
        // reads this clock; it only echoes it.
        p.t_pose = t + 2.0 / 90.0;
        float yaw = (float)(o_amp * M_PI / 180.0 * sin(2.0 * M_PI * (t - g_t0) / o_period));
        p.head_pos = (kl_stream_v3){ 0.0f, 1.6f, 0.0f };
        p.head_rot = (kl_stream_q){ 0.0f, sinf(yaw * 0.5f), 0.0f, cosf(yaw * 0.5f) };
        p.head_ang_vel.y = (float)(o_amp * M_PI / 180.0 * 2.0 * M_PI / o_period *
                                   cos(2.0 * M_PI * (t - g_t0) / o_period));
        for (int h = 0; h < 2; h++) {
            kl_stream_hand *hd = &p.hand[h];
            hd->flags = KL_STREAM_HAND_TRACKED | KL_STREAM_HAND_CONNECTED;
            hd->pos = (kl_stream_v3){ h ? 0.22f : -0.22f, 1.35f, -0.40f };
            hd->rot = (kl_stream_q){ 0, 0, 0, 1 };
            hd->battery = -1;
        }
        g_sent[id % RING].id = id;
        g_sent[id % RING].t_send = t;
        g_sent[id % RING].t_pose = p.t_pose;
        g_sent[id % RING].yaw = yaw * 180.0f / (float)M_PI;
        tx(&p, sizeof p);
    }
    return NULL;
}

// ---- reassembly ----
#define SLOTS 8
typedef struct {
    int used;
    uint32_t frame_id, pose_id, flags, bytes, count, got;
    double t_pose, t_first;
    float tan[2][4], ms_render, ms_encode;
    uint8_t *buf, *have;
} slot;
static slot g_slot[SLOTS];

// ---- stats ----
static struct {
    unsigned frames, decoded, lost, haptics, key, tpose_bad, untagged;
    double lat_ms, dec_ms, enc_ms, render_ms, rtt_ms, reasm_ms;
    uint64_t bytes;
} W, T;   // W = this second, T = totals

// ---- decode ----
static VTDecompressionSessionRef g_dec;
static CMVideoFormatDescriptionRef g_fmt;
static int g_need_key = 1;
static unsigned g_decoded_total;
static dispatch_queue_t g_png_q;

typedef struct { uint32_t frame_id, pose_id; double t_dec; float yaw; } dec_ctx;

static void write_png(CVPixelBufferRef pb, uint32_t frame_id, uint32_t pose_id, float yaw) {
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), w, h, 8, bpr, cs,
                                             kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;   // a copy
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (!img) return;
    char path[1024];
    snprintf(path, sizeof path, "%s/frame_%06u_pose%06u_yaw%+05.1f.png", o_dir, frame_id, pose_id, (double)yaw);
    NSString *ps = @(path);
    dispatch_async(g_png_q, ^{
        CFURLRef url = CFURLCreateWithFileSystemPath(NULL, (__bridge CFStringRef)ps, kCFURLPOSIXPathStyle, false);
        CGImageDestinationRef d = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
        if (d) { CGImageDestinationAddImage(d, img, NULL); CGImageDestinationFinalize(d); CFRelease(d); }
        CFRelease(url);
        CGImageRelease(img);
    });
    printf("  wrote %s\n", path);
}

static void dec_out(void *refcon, void *frame_refcon, OSStatus st, VTDecodeInfoFlags flags,
                    CVImageBufferRef img, CMTime pts, CMTime dur) {
    (void)refcon; (void)flags; (void)pts; (void)dur;
    dec_ctx *c = frame_refcon;
    if (st != noErr || !img) {
        fprintf(stderr, "  decode of frame %u failed: %d — asking for an IDR\n", c->frame_id, (int)st);
        g_need_key = 1;
        free(c);
        return;
    }
    double ms = (now_s() - c->t_dec) * 1000.0;
    W.decoded++; T.decoded++;
    W.dec_ms += ms; T.dec_ms += ms;
    g_decoded_total++;
    if (o_dir && (g_decoded_total == 1 || g_decoded_total % (unsigned)o_every == 0))
        write_png(img, c->frame_id, c->pose_id, c->yaw);
    free(c);
}

static int make_decoder(const uint8_t *const ps[3], const size_t psz[3]) {
    CMVideoFormatDescriptionRef fd = NULL;
    OSStatus s = CMVideoFormatDescriptionCreateFromHEVCParameterSets(NULL, 3, ps, psz, 4, NULL, &fd);
    if (s != noErr) { fprintf(stderr, "  bad HEVC parameter sets: %d\n", (int)s); return -1; }
    if (g_dec && g_fmt && CMFormatDescriptionEqual(fd, g_fmt)) { CFRelease(fd); return 0; }
    if (g_dec) { VTDecompressionSessionInvalidate(g_dec); CFRelease(g_dec); g_dec = NULL; }
    if (g_fmt) CFRelease(g_fmt);
    g_fmt = fd;
    CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(fd);
    NSDictionary *dst = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    VTDecompressionOutputCallbackRecord cb = { dec_out, NULL };
    s = VTDecompressionSessionCreate(NULL, fd, NULL, (__bridge CFDictionaryRef)dst, &cb, &g_dec);
    if (s != noErr) { fprintf(stderr, "  VTDecompressionSessionCreate: %d\n", (int)s); g_dec = NULL; return -1; }
    VTSessionSetProperty(g_dec, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    printf("  decoder: HEVC %dx%d\n", dim.width, dim.height);
    return 0;
}

static void request_idr(uint32_t last_good) {
    kl_stream_idr_request r;
    memset(&r, 0, sizeof r);
    hdr(&r.h, KL_STREAM_IDR_REQUEST);
    r.last_good_frame_id = last_good;
    tx(&r, sizeof r);
}

static uint32_t g_last_complete;

static void frame_complete(slot *s) {
    double t = now_s();
    W.frames++; T.frames++;
    W.bytes += s->bytes; T.bytes += s->bytes;
    W.enc_ms += s->ms_encode; T.enc_ms += s->ms_encode;
    W.render_ms += s->ms_render; T.render_ms += s->ms_render;
    W.reasm_ms += (t - s->t_first) * 1000.0; T.reasm_ms += (t - s->t_first) * 1000.0;
    float yaw = 0;
    if (!s->pose_id) {
        W.untagged++; T.untagged++;      // rendered before our first POSE
    } else if (g_sent[s->pose_id % RING].id == s->pose_id) {
        double lat = (t - g_sent[s->pose_id % RING].t_send) * 1000.0;
        W.lat_ms += lat; T.lat_ms += lat;
        if (g_sent[s->pose_id % RING].t_pose != s->t_pose) { W.tpose_bad++; T.tpose_bad++; }
        yaw = g_sent[s->pose_id % RING].yaw;
    } else {
        W.tpose_bad++; T.tpose_bad++;
    }
    int key = (s->flags & KL_STREAM_VIDEO_KEYFRAME) != 0;
    if (key) { W.key++; T.key++; }
    static float last_tan[2][4];
    if (memcmp(last_tan, s->tan, sizeof last_tan)) {
        memcpy(last_tan, s->tan, sizeof last_tan);
        printf("  frame %u rendered with tangents L(l %.4f r %.4f u %.4f d %.4f) R(l %.4f r %.4f u %.4f d %.4f)\n",
               s->frame_id, s->tan[0][0], s->tan[0][1], s->tan[0][2], s->tan[0][3],
               s->tan[1][0], s->tan[1][1], s->tan[1][2], s->tan[1][3]);
    }
    if (g_last_complete && s->frame_id > g_last_complete + 1) {
        unsigned gap = s->frame_id - g_last_complete - 1;
        W.lost += gap; T.lost += gap;
        if (!key) { g_need_key = 1; request_idr(g_last_complete); }
    }
    if (s->frame_id > g_last_complete) g_last_complete = s->frame_id;
    if (g_need_key && !key) return;

    // Split the access unit: leading VPS/SPS/PPS (keyframes) feed the format
    // description; the rest is the sample, still length-prefixed.
    const uint8_t *p = s->buf, *end = s->buf + s->bytes;
    const uint8_t *ps[3] = { 0 }; size_t psz[3] = { 0 };
    while (p + 4 <= end) {
        uint32_t n = (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
        if (p + 4 + n > end || n == 0) break;
        int type = (p[4] >> 1) & 0x3f;
        if (type < 32 || type > 34) break;
        ps[type - 32] = p + 4; psz[type - 32] = n;
        p += 4 + n;
    }
    if (key) {
        if (!ps[0] || !ps[1] || !ps[2]) { fprintf(stderr, "  keyframe %u without VPS/SPS/PPS\n", s->frame_id); return; }
        if (make_decoder(ps, psz) != 0) return;
        g_need_key = 0;
    }
    if (!g_dec || p >= end) return;
    size_t n = (size_t)(end - p);
    CMBlockBufferRef bb = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, n, NULL, NULL, 0, n, 0, &bb) != noErr) return;
    CMBlockBufferReplaceDataBytes(p, bb, 0, n);
    CMSampleBufferRef sb = NULL;
    size_t ssz = n;
    CMSampleBufferCreateReady(NULL, bb, g_fmt, 1, 0, NULL, 1, &ssz, &sb);
    CFRelease(bb);
    if (!sb) return;
    dec_ctx *c = malloc(sizeof *c);
    c->frame_id = s->frame_id; c->pose_id = s->pose_id; c->t_dec = now_s(); c->yaw = yaw;
    OSStatus st = VTDecompressionSessionDecodeFrame(g_dec, sb, kVTDecodeFrame_EnableAsynchronousDecompression, c, NULL);
    CFRelease(sb);
    if (st != noErr) {
        fprintf(stderr, "  DecodeFrame(%u): %d\n", s->frame_id, (int)st);
        free(c);
        g_need_key = 1;
        request_idr(g_last_complete);
    }
}

static void on_video(const uint8_t *buf, size_t n) {
    if (n < sizeof(kl_stream_video)) return;
    kl_stream_video v;
    memcpy(&v, buf, sizeof v);
    // v2 parity packets (FEC) are not used by this stand-in: it reassembles
    // data fragments only (the headset client rebuilds from parity).
    if (v.flags & KL_STREAM_VIDEO_PARITY) return;
    if (!v.frag_count || v.frag_index >= v.frag_count) return;
    if (g_last_complete && v.frame_id <= g_last_complete) return;   // late fragment of a done/abandoned frame
    slot *s = NULL, *spare = NULL;
    for (int i = 0; i < SLOTS && !s; i++)
        if (g_slot[i].used && g_slot[i].frame_id == v.frame_id) s = &g_slot[i];
    for (int i = 0; i < SLOTS && !s && !spare; i++)
        if (!g_slot[i].used) spare = &g_slot[i];
    if (!s && !spare) {           // all busy: the oldest incomplete frame is abandoned
        spare = &g_slot[0];
        for (int i = 1; i < SLOTS; i++)
            if (g_slot[i].frame_id < spare->frame_id) spare = &g_slot[i];
    }
    if (!s) {
        s = spare;
        if (s->used) { free(s->buf); free(s->have); }
        memset(s, 0, sizeof *s);
        s->used = 1;
        s->frame_id = v.frame_id; s->pose_id = v.pose_id; s->t_pose = v.t_pose;
        s->flags = v.flags; s->bytes = v.frame_bytes; s->count = v.frag_count;
        memcpy(s->tan, v.tan, sizeof s->tan);
        s->ms_render = v.host_ms_render; s->ms_encode = v.host_ms_encode;
        s->buf = malloc(v.frame_bytes ? v.frame_bytes : 1);
        s->have = calloc(v.frag_count, 1);
        s->t_first = now_s();
    }
    if (s->have[v.frag_index]) return;
    size_t off = (size_t)v.frag_index * KL_STREAM_MTU_PAYLOAD;
    size_t len = n - sizeof v;
    if (off + len > s->bytes) return;
    memcpy(s->buf + off, buf + sizeof v, len);
    s->have[v.frag_index] = 1;
    if (++s->got == s->count) {
        frame_complete(s);
        free(s->buf); free(s->have);
        memset(s, 0, sizeof *s);
    }
}

static void print_window(double dt, int final) {
    typeof(W) *x = final ? &T : &W;
    unsigned f = x->frames ? x->frames : 1, d = x->decoded ? x->decoded : 1;
    printf("[fakeclient]%s %.1f fps received, %.1f decoded, %u lost, %u key, latency %.1f ms "
           "(pose send -> frame complete), reassembly %.1f ms, decode %.1f ms, host encode %.1f ms, "
           "host render %.1f ms, %.1f Mbit/s, rtt %.2f ms, haptics %u, untagged %u%s\n",
           final ? " TOTAL" : "", x->frames / dt, x->decoded / dt, x->lost, x->key, x->lat_ms / f,
           x->reasm_ms / f, x->dec_ms / d, x->enc_ms / f, x->render_ms / f,
           (double)x->bytes * 8 / 1e6 / dt, W.rtt_ms, x->haptics, x->untagged,
           x->tpose_bad ? " (t_pose echo MISMATCH)" : "");
    fflush(stdout);
}

int main(int argc, char **argv) {
    int c;
    while ((c = getopt(argc, argv, "h:p:o:n:t:a:P:b:e:z:f:")) != -1) {
        switch (c) {
        case 'h': o_host = optarg; break;
        case 'p': o_port = atoi(optarg); break;
        case 'o': o_dir = optarg; break;
        case 'n': o_every = atoi(optarg) > 0 ? atoi(optarg) : 30; break;
        case 't': o_secs = atof(optarg); break;
        case 'a': o_amp = atof(optarg); break;
        case 'P': o_period = atof(optarg); break;
        case 'b': o_kbps = atoi(optarg); break;
        case 'e': sscanf(optarg, "%dx%d", &o_eye_w, &o_eye_h); break;
        case 'z': o_hz = (float)atof(optarg); break;
        case 'f': o_tan_scale = (float)atof(optarg); break;
        default:
            fprintf(stderr, "usage: %s [-h host] [-p port] [-o png_dir] [-n every] [-t secs] "
                            "[-a yaw_amp_deg] [-P period_s] [-b max_kbps] [-e WxH] [-z hz] [-f tan_scale]\n", argv[0]);
            return 2;
        }
    }
    if (o_dir) {
        char cmd[1100];
        snprintf(cmd, sizeof cmd, "mkdir -p '%s'", o_dir);
        system(cmd);
    }
    g_png_q = dispatch_queue_create("png", DISPATCH_QUEUE_SERIAL);
    struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_DGRAM }, *ai;
    char port[16];
    snprintf(port, sizeof port, "%d", o_port);
    if (getaddrinfo(o_host, port, &hints, &ai) != 0) { fprintf(stderr, "cannot resolve %s\n", o_host); return 1; }
    g_fd = socket(ai->ai_family, SOCK_DGRAM, 0);
    int big = 8 << 20;
    while (big > (256 << 10) && setsockopt(g_fd, SOL_SOCKET, SO_RCVBUF, &big, sizeof big) != 0) big /= 2;
    if (connect(g_fd, ai->ai_addr, ai->ai_addrlen) != 0) { perror("connect"); return 1; }
    freeaddrinfo(ai);
    printf("[fakeclient] -> %s:%d, %.0f s, yaw ±%.0f° over %.1f s, PNG every %d decoded frame(s)%s%s\n",
           o_host, o_port, o_secs, o_amp, o_period, o_every, o_dir ? " into " : "", o_dir ? o_dir : "");

    kl_stream_hello hello;
    memset(&hello, 0, sizeof hello);
    snprintf(hello.device, sizeof hello.device, "fakeclient (Vision Pro-like)");
    hello.display_hz = o_hz;
    hello.eye_w = (uint32_t)o_eye_w; hello.eye_h = (uint32_t)o_eye_h;
    const float ipd = 0.0669f, k = o_tan_scale;
    hello.eye[0] = (kl_stream_eye){ 1.7321f * k, 1.0f * k, 1.0f * k, 1.1918f * k, { -ipd / 2, 0, 0 }, { 0, 0, 0, 1 } };
    hello.eye[1] = (kl_stream_eye){ 1.0f * k, 1.7321f * k, 1.0f * k, 1.1918f * k, {  ipd / 2, 0, 0 }, { 0, 0, 0, 1 } };
    hello.max_bitrate_kbps = (uint32_t)o_kbps;

    pthread_t pt;
    g_t0 = now_s();
    pthread_create(&pt, NULL, pose_thread, NULL);

    uint8_t *buf = malloc(65536);
    double t_start = now_s(), t_hello = 0, t_win = 0, t_ping = 0, t_stream = 0;
    for (;;) {
        double t = now_s();
        if (!g_streaming && t - t_start > 900) { printf("[fakeclient] no HELLO_ACK in 900 s\n"); return 1; }
        if (!g_streaming && t - t_hello >= 1.0) {
            hdr(&hello.h, KL_STREAM_HELLO);
            tx(&hello, sizeof hello);
            t_hello = t;
        }
        if (g_streaming && t - t_stream >= o_secs) break;
        if (g_streaming && t - t_ping >= 1.0) {
            kl_stream_ping p;
            memset(&p, 0, sizeof p);
            hdr(&p.h, KL_STREAM_PING);
            p.t_send = t;
            tx(&p, sizeof p);
            t_ping = t;
        }
        if (g_streaming && t - t_win >= 1.0) {
            if (t_win > 0) print_window(t - t_win, 0);
            memset(&W, 0, offsetof(typeof(W), rtt_ms));
            W.bytes = 0; W.reasm_ms = 0;
            t_win = t;
        }
        struct pollfd pf = { g_fd, POLLIN, 0 };
        if (poll(&pf, 1, 5) <= 0) continue;
        for (;;) {
            ssize_t n = recv(g_fd, buf, 65536, MSG_DONTWAIT);
            if (n <= 0) break;
            if ((size_t)n < sizeof(kl_stream_hdr)) continue;
            kl_stream_hdr h;
            memcpy(&h, buf, sizeof h);
            if (h.magic != KL_STREAM_MAGIC) continue;
            switch (h.type) {
            case KL_STREAM_HELLO_ACK: {
                kl_stream_hello_ack a;
                if ((size_t)n < sizeof a) break;
                memcpy(&a, buf, sizeof a);
                if (g_streaming) break;
                if (a.status != KL_STREAM_OK) {
                    printf("[fakeclient] HELLO_ACK status %u — %s\n", a.status,
                           a.status == KL_STREAM_ERR_BUSY ? "busy" : a.status == KL_STREAM_ERR_VERSION
                           ? "version mismatch" : "guest failed");
                    return 1;
                }
                printf("[fakeclient] HELLO_ACK: guest '%.32s', codec %.4s, %ux%u, %u kbit/s, host fps target %.0f\n",
                       a.guest, (const char *)&a.codec, a.frame_w, a.frame_h, a.bitrate_kbps,
                       (double)a.host_fps_target);
                g_streaming = 1;
                t_stream = now_s();
                break;
            }
            case KL_STREAM_VIDEO: on_video(buf, (size_t)n); break;
            case KL_STREAM_HAPTICS: W.haptics++; T.haptics++; break;
            case KL_STREAM_PING: {
                kl_stream_ping p;
                if ((size_t)n < sizeof p) break;
                memcpy(&p, buf, sizeof p);
                hdr(&p.h, KL_STREAM_PONG);
                p.t_reply = now_s();
                tx(&p, sizeof p);
                break;
            }
            case KL_STREAM_PONG: {
                kl_stream_ping p;
                if ((size_t)n < sizeof p) break;
                memcpy(&p, buf, sizeof p);
                W.rtt_ms = (now_s() - p.t_send) * 1000.0;
                break;
            }
            case KL_STREAM_BYE:
                printf("[fakeclient] host said BYE\n");
                g_stop = 1;
                break;
            default: break;
            }
        }
        if (g_stop) break;
    }
    g_stop = 1;
    kl_stream_hdr bye;
    hdr(&bye, KL_STREAM_BYE);
    tx(&bye, sizeof bye);
    if (g_dec) VTDecompressionSessionWaitForAsynchronousFrames(g_dec);
    dispatch_sync(g_png_q, ^{});
    double dt = t_stream > 0 ? now_s() - t_stream : 1;
    print_window(dt, 1);
    pthread_join(pt, NULL);
    return T.frames ? 0 : 1;
}
