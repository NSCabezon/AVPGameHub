// kl_stream_client.c — see kl_stream_client.h.
//
// Threads: the CALLER's (the compositor's render thread on the headset) sends
// POSE and pulls frames; one receive thread owns the socket's read side,
// reassembly, the decoder and the 1 Hz housekeeping (HELLO retry, PING, IDR
// re-requests, the stats line). One mutex guards what the two share: the pose
// ring, the newest decoded frame and the counters.
//
// Loss policy, which is the part that decides what a person sees on Wi-Fi:
//
//   * A frame is complete when every fragment has arrived. When frame F
//     completes, every frame older than F that is still incomplete is dropped —
//     a picture that would be shown after a newer one is worse than none — and
//     every frame id between the previous completed frame and F counts as LOST.
//   * Before any of that, FEC (protocol v2): a VIDEO packet flagged PARITY is
//     the XOR of a group of fec_n data fragments; when exactly one fragment of
//     a group is missing it is rebuilt in place (klsc_fec_try), so a single
//     loss per group never becomes a lost frame.
//   * After any loss the next P-frames reference a picture the decoder never
//     had, so they are not submitted: the client waits for a keyframe and asks
//     for one (IDR_REQUEST), re-asking every KL_STREAM_IDR_MIN_S (0.25 s) until
//     it arrives. A decoder error is treated the same way.
//   * The decoder runs synchronously on the receive thread and only the newest
//     decoded picture is kept; the compositor pulls it once per display frame.

#include "kl_stream_client.h"
#include "kl_ovrp.h"
#include "kl_env.h"
#include "kl_audio.h"

#include <VideoToolbox/VideoToolbox.h>
#include <CoreMedia/CoreMedia.h>

#include <arpa/inet.h>
#include <errno.h>
#include <mach/mach_time.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define KLSC_RING   256
#define KLSC_SLOTS  8
#define KLSC_MAX_FRAME (24u << 20)   // a frame bigger than this is garbage, not video

// ---------------------------------------------------------------------------
// clock + log

double kl_stream_now(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom * 1e-9;
}

static kl_stream_log_fn g_log;
void kl_stream_set_log(kl_stream_log_fn fn) { g_log = fn; }

static void klsc_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void klsc_log(const char *fmt, ...) {
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    if (g_log) g_log(line);
    else { fprintf(stderr, "%s\n", line); fflush(stderr); }
}

// ---------------------------------------------------------------------------
// state

typedef struct {
    int       used;
    uint32_t  frame_id;
    uint32_t  frame_bytes;
    uint16_t  frag_count, got;
    uint8_t  *have;      // one byte per fragment
    size_t    have_cap;
    uint8_t  *buf;
    size_t    cap;
    kl_stream_video meta;
    double    t_last;
    // FEC (KL_STREAM_VIDEO_PARITY): one parity payload per group of fec_n
    uint16_t  fec_n, groups;
    uint8_t  *par;       // groups * KL_STREAM_MTU_PAYLOAD
    size_t    par_cap;
    uint8_t  *par_have;  // one byte per group
    size_t    par_have_cap;
} klsc_slot;

typedef struct {
    uint32_t pose_id;
    double   t_pose;
    float    p7[7];
} klsc_ring_entry;

struct kl_stream_client {
    int               fd;
    char              host[128];
    int               port;
    pthread_t         rx;
    volatile int      running;
    pthread_mutex_t   mu;

    uint32_t          seq[16];          // per type, per sender
    pthread_mutex_t   tx_mu;            // seq + send from two threads

    // HELLO / ACK
    int               have_display;
    kl_stream_hello   hello;
    double            last_hello;
    int               acked, refused, ended;
    double            t_ack;
    kl_stream_hello_ack ack;

    // pose ring (render thread writes, rx thread reads)
    uint32_t          next_pose_id;
    klsc_ring_entry   ring[KLSC_RING];

    // reassembly + decode (rx thread only)
    klsc_slot         slots[KLSC_SLOTS];
    int               have_completed;
    uint32_t          last_completed;
    int               need_idr;
    double            last_idr;
    uint32_t          last_good_frame;
    VTDecompressionSessionRef sess;
    CMVideoFormatDescriptionRef fmt;
    kl_stream_frame_info decoding;      // meta of the frame inside DecodeFrame

    // newest decoded frame (rx writes, render thread pulls)
    CVPixelBufferRef  latest;
    kl_stream_frame_info latest_info;
    double            t_last_video;     // last decoded frame, client clock

    // PING
    double            last_ping;
    float             rtt_ms;

    // counters: totals and the current 1 s window
    uint32_t          tot_decoded, tot_lost, tot_idr, tot_dec_err, tot_pose_miss,
                      tot_poses, tot_skipped, tot_fec_fixed;
    int               decode_bgra;      // KL_STREAM_DECODE_BGRA=1: the old BGRA output
    // cadence: intervals between decoded frames (rx thread)
    double            t_prev_decoded;
    double            w_iv_sum, w_iv_sq, t_iv_sum, t_iv_sq, t_decode_ms;
    uint32_t          w_iv_n, t_iv_n;
    uint32_t          w_decoded;
    double            w_decode_ms;
    uint64_t          w_bytes;
    double            w_p2p_ms;
    uint32_t          w_p2p_n;
    double            w_start;
    kl_stream_client_status st;         // the last published window

    // AUDIO (klsc_audio_*): rx thread pushes into a jitter ring, the audio
    // thread pops and feeds kl_audio (whose blocking write is the clock).
    pthread_mutex_t   au_mu;
    pthread_cond_t    au_cv;
    pthread_t         au_thread;
    int               au_started;
    int16_t          *au_ring;          // au_cap frames x 2 ch (mono is widened)
    size_t            au_cap, au_r, au_w;   // frames; au_w - au_r = buffered
    unsigned          au_rate;
    uint64_t          au_expect;        // next first_frame expected
    int               au_have_expect;
    uint32_t          au_pkts, au_gap_frames, au_late, au_underruns, au_overflow;
};

// ---------------------------------------------------------------------------
// send

static void klsc_hdr(kl_stream_client *c, kl_stream_hdr *h, uint16_t type) {
    h->magic = KL_STREAM_MAGIC;
    h->version = KL_STREAM_VERSION;
    h->type = type;
    h->seq = c->seq[type & 15]++;
}

static void klsc_send(kl_stream_client *c, void *pkt, size_t n, uint16_t type) {
    pthread_mutex_lock(&c->tx_mu);
    klsc_hdr(c, (kl_stream_hdr *)pkt, type);
    ssize_t r = send(c->fd, pkt, n, 0);
    pthread_mutex_unlock(&c->tx_mu);
    if (r < 0) {
        static double last;
        double now = kl_stream_now();
        // ECONNREFUSED is the host not listening yet (ICMP), which the HELLO
        // retry is for; anything else is worth a line, rate-limited.
        if (errno != ECONNREFUSED && now - last > 2.0) {
            last = now;
            klsc_log("[stream-client] send(type %u) failed: %s", type, strerror(errno));
        }
    }
}

static void klsc_send_hello(kl_stream_client *c) {
    kl_stream_hello h = c->hello;
    klsc_send(c, &h, sizeof h, KL_STREAM_HELLO);
    c->last_hello = kl_stream_now();
}

static void klsc_send_idr(kl_stream_client *c) {
    kl_stream_idr_request r = {0};
    r.last_good_frame_id = c->last_good_frame;
    klsc_send(c, &r, sizeof r, KL_STREAM_IDR_REQUEST);
    c->last_idr = kl_stream_now();
    pthread_mutex_lock(&c->mu);
    c->tot_idr++;
    pthread_mutex_unlock(&c->mu);
}

void kl_stream_client_set_display(kl_stream_client *c, const kl_stream_hello *h) {
    if (!c || !h) return;
    pthread_mutex_lock(&c->mu);
    c->hello = *h;
    c->have_display = 1;
    pthread_mutex_unlock(&c->mu);
    klsc_log("[stream-client] display: %s %.2f Hz, eye %ux%u, tan L(%.3f %.3f %.3f %.3f) "
             "R(%.3f %.3f %.3f %.3f), ipd %.1f mm — sending HELLO to %s:%d",
             h->device, (double)h->display_hz, h->eye_w, h->eye_h,
             (double)h->eye[0].tan_left, (double)h->eye[0].tan_right,
             (double)h->eye[0].tan_up, (double)h->eye[0].tan_down,
             (double)h->eye[1].tan_left, (double)h->eye[1].tan_right,
             (double)h->eye[1].tan_up, (double)h->eye[1].tan_down,
             (double)(h->eye[1].offset.x - h->eye[0].offset.x) * 1000.0, c->host, c->port);
    klsc_send_hello(c);
}

void kl_stream_hello_from_ovrp(kl_stream_hello *out, const float tan[2][4],
                               const char *device) {
    memset(out, 0, sizeof *out);
    snprintf(out->device, sizeof out->device, "%s", device ? device : "Klepton");
    out->display_hz = kl_ovrp_display_frequency();
    int w = 0, h = 0;
    kl_ovrp_eye_texture_size(&w, &h);
    out->eye_w = (uint32_t)(w > 0 ? w : 0);
    out->eye_h = (uint32_t)(h > 0 ? h : 0);
    for (int e = 0; e < 2; e++) {
        float p[3], q[4], t[4];
        kl_ovrp_eye_local(e, p, q);
        if (tan) memcpy(t, tan[e], sizeof t);
        else kl_ovrp_eye_view(e, NULL, NULL, NULL, NULL, NULL, NULL, NULL, t);
        out->eye[e].tan_left = t[0]; out->eye[e].tan_right = t[1];
        out->eye[e].tan_up = t[2];   out->eye[e].tan_down = t[3];
        out->eye[e].offset = (kl_stream_v3){ p[0], p[1], p[2] };
        out->eye[e].rotation = (kl_stream_q){ q[0], q[1], q[2], q[3] };
    }
    out->max_bitrate_kbps = (uint32_t)kl_env_int("KL_STREAM_MAX_KBPS", 0);
}

uint32_t kl_stream_client_send_pose(kl_stream_client *c, kl_stream_pose *p) {
    if (!c || !p) return 0;
    pthread_mutex_lock(&c->mu);
    int acked = c->acked && !c->ended;
    uint32_t id = 0;
    if (acked) {
        id = ++c->next_pose_id;
        klsc_ring_entry *r = &c->ring[id % KLSC_RING];
        r->pose_id = id;
        r->t_pose = p->t_pose;
        r->p7[0] = p->head_pos.x; r->p7[1] = p->head_pos.y; r->p7[2] = p->head_pos.z;
        r->p7[3] = p->head_rot.x; r->p7[4] = p->head_rot.y;
        r->p7[5] = p->head_rot.z; r->p7[6] = p->head_rot.w;
        c->tot_poses++;
    }
    pthread_mutex_unlock(&c->mu);
    // Nothing is sent before HELLO_ACK: the host has no session to put it in.
    if (!acked) return 0;
    p->pose_id = id;
    klsc_send(c, p, sizeof *p, KL_STREAM_POSE);
    return id;
}

uint32_t kl_stream_client_send_pose_from_ovrp(kl_stream_client *c, double t_pose,
                                              uint32_t connected_mask) {
    if (!c) return 0;
    kl_ovrp_frame_latch();
    kl_stream_pose p;
    memset(&p, 0, sizeof p);
    p.t_pose = t_pose;
    kl_ovrp_get_guest_head_pose(&p.head_pos.x, &p.head_pos.y, &p.head_pos.z,
                                &p.head_rot.x, &p.head_rot.y, &p.head_rot.z, &p.head_rot.w);
    float v[3] = {0}, a[3] = {0};
    if (kl_ovrp_head_motion(v, a)) {
        p.head_vel = (kl_stream_v3){ v[0], v[1], v[2] };
        p.head_ang_vel = (kl_stream_v3){ a[0], a[1], a[2] };
    }
    for (int h = 0; h < 2; h++) {
        kl_stream_hand *o = &p.hand[h];
        float pos[3], q[4], vel[3], ang[3];
        int set = kl_ovrp_hand_motion(h, pos, q, vel, ang);
        o->flags = (set ? KL_STREAM_HAND_TRACKED : 0)
                 | ((connected_mask >> h) & 1 ? KL_STREAM_HAND_CONNECTED : 0);
        o->pos = (kl_stream_v3){ pos[0], pos[1], pos[2] };
        o->rot = (kl_stream_q){ q[0], q[1], q[2], q[3] };
        if (kl_ovrp_hand_motion_known(h)) {
            o->vel = (kl_stream_v3){ vel[0], vel[1], vel[2] };
            o->ang_vel = (kl_stream_v3){ ang[0], ang[1], ang[2] };
        }
        kl_ovrp_controller_input(h, &o->buttons, &o->touches, &o->index_trigger,
                                 &o->hand_trigger, &o->stick_x, &o->stick_y);
        o->battery = -1;
    }
    return kl_stream_client_send_pose(c, &p);
}

// ---------------------------------------------------------------------------
// decode

static void klsc_decoded(void *refcon, void *frame_refcon, OSStatus status,
                         VTDecodeInfoFlags flags, CVImageBufferRef img,
                         CMTime pts, CMTime dur) {
    kl_stream_client *c = refcon;
    if (status != noErr || !img) {
        c->decoding.keyframe = -1;   // tells klsc_decode it failed
        return;
    }
    kl_stream_frame_info info = c->decoding;
    info.width = (int)CVPixelBufferGetWidth(img);
    info.height = (int)CVPixelBufferGetHeight(img);
    info.t_decoded = kl_stream_now();
    CVPixelBufferRetain(img);
    pthread_mutex_lock(&c->mu);
    if (c->latest) CVPixelBufferRelease(c->latest);   // superseded, never shown
    c->latest = img;
    c->latest_info = info;
    c->t_last_video = info.t_decoded;
    pthread_mutex_unlock(&c->mu);
}

static void klsc_drop_session(kl_stream_client *c) {
    if (c->sess) {
        VTDecompressionSessionWaitForAsynchronousFrames(c->sess);
        VTDecompressionSessionInvalidate(c->sess);
        CFRelease(c->sess);
        c->sess = NULL;
    }
}

static int klsc_make_session(kl_stream_client *c) {
    klsc_drop_session(c);
    // Native biplanar 4:2:0 by default — what the hardware decoder produces,
    // so no conversion pass inside VideoToolbox; the app converts to RGB in
    // the shader that splits the eyes (kl_stream_yuv_msl). 10-bit streams
    // (Main10) come out as x420. KL_STREAM_DECODE_BGRA=1 = the old BGRA output.
    int32_t pixfmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    const char *fmtname = "420v (native YUV)";
    if (c->decode_bgra) {
        pixfmt = kCVPixelFormatType_32BGRA;
        fmtname = "BGRA";
    } else {
        CFTypeRef bpc = CMFormatDescriptionGetExtension(c->fmt, CFSTR("BitsPerComponent"));
        int bits = 8;
        if (bpc && CFGetTypeID(bpc) == CFNumberGetTypeID()) CFNumberGetValue(bpc, kCFNumberIntType, &bits);
        if (bits > 8) {
            pixfmt = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
            fmtname = "x420 (native 10-bit YUV)";
        }
    }
    CFNumberRef pf = CFNumberCreate(NULL, kCFNumberSInt32Type, &pixfmt);
    CFDictionaryRef iosurf = CFDictionaryCreate(NULL, NULL, NULL, 0,
                                                &kCFTypeDictionaryKeyCallBacks,
                                                &kCFTypeDictionaryValueCallBacks);
    const void *keys[] = { kCVPixelBufferPixelFormatTypeKey,
                           kCVPixelBufferMetalCompatibilityKey,
                           kCVPixelBufferIOSurfacePropertiesKey };
    const void *vals[] = { pf, kCFBooleanTrue, iosurf };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 3,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    VTDecompressionOutputCallbackRecord cb = { klsc_decoded, c };
    OSStatus st = VTDecompressionSessionCreate(NULL, c->fmt, NULL, attrs, &cb, &c->sess);
    CFRelease(attrs); CFRelease(iosurf); CFRelease(pf);
    if (st != noErr) {
        klsc_log("[stream-client] VTDecompressionSessionCreate failed: %d", (int)st);
        c->sess = NULL;
        return -1;
    }
    VTSessionSetProperty(c->sess, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(c->fmt);
    klsc_log("[stream-client] HEVC decoder up: %dx%d (%s, IOSurface/Metal)",
             d.width, d.height, fmtname);
    return 0;
}

static uint32_t klsc_be32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

// 0 = a picture came out, -1 = undecodable (caller asks for an IDR).
static int klsc_decode(kl_stream_client *c, klsc_slot *s) {
    const uint8_t *buf = s->buf, *end = s->buf + s->frame_bytes;
    const uint8_t *ps[3] = {0};
    size_t ps_len[3] = {0};
    const uint8_t *sample = NULL;
    // Walk the length-prefixed NALs. Parameter sets are taken wherever they
    // are; the sample is everything from the first non-parameter-set NAL on.
    for (const uint8_t *p = buf; p + 4 <= end; ) {
        uint32_t n = klsc_be32(p);
        if (n == 0 || p + 4 + n > end) {
            klsc_log("[stream-client] frame %u: malformed NAL length %u at +%ld",
                     s->frame_id, n, (long)(p - buf));
            return -1;
        }
        int type = (p[4] >> 1) & 0x3f;
        if (type >= 32 && type <= 34 && !sample) {
            ps[type - 32] = p + 4;
            ps_len[type - 32] = n;
        } else if (!sample) {
            sample = p;
        }
        p += 4 + n;
    }
    if (!sample) return 0;   // parameter sets only: nothing to show, not an error

    if (ps[0] && ps[1] && ps[2]) {
        CMVideoFormatDescriptionRef fmt = NULL;
        OSStatus st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            NULL, 3, ps, ps_len, 4, NULL, &fmt);
        if (st != noErr || !fmt) {
            klsc_log("[stream-client] frame %u: bad parameter sets (%d)", s->frame_id, (int)st);
            return -1;
        }
        int same = c->fmt && CMFormatDescriptionEqual(c->fmt, fmt);
        if (same) {
            CFRelease(fmt);
        } else {
            if (c->fmt) CFRelease(c->fmt);
            c->fmt = fmt;
            if (!c->sess || !VTDecompressionSessionCanAcceptFormatDescription(c->sess, fmt)) {
                if (klsc_make_session(c) != 0) return -1;
            }
        }
    }
    if (!c->sess || !c->fmt) return -1;

    size_t len = (size_t)(end - sample);
    CMBlockBufferRef bb = NULL;
    // kCFAllocatorNull: the block points into the slot, which outlives the
    // synchronous decode below.
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(NULL, (void *)sample, len,
                                                     kCFAllocatorNull, NULL, 0, len,
                                                     0, &bb);
    if (st != noErr) return -1;
    CMSampleBufferRef sb = NULL;
    st = CMSampleBufferCreateReady(NULL, bb, c->fmt, 1, 0, NULL, 1, &len, &sb);
    CFRelease(bb);
    if (st != noErr || !sb) return -1;

    c->decoding.frame_id = s->frame_id;
    c->decoding.pose_id = s->meta.pose_id;
    c->decoding.t_pose = s->meta.t_pose;
    c->decoding.keyframe = (s->meta.flags & KL_STREAM_VIDEO_KEYFRAME) ? 1 : 0;
    memcpy(c->decoding.tan, s->meta.tan, sizeof c->decoding.tan);
    c->decoding.t_received = s->t_last;
    c->decoding.host_ms_render = s->meta.host_ms_render;
    c->decoding.host_ms_encode = s->meta.host_ms_encode;
    // The render pose, from the ring — the reason the ring exists.
    pthread_mutex_lock(&c->mu);
    klsc_ring_entry *r = &c->ring[s->meta.pose_id % KLSC_RING];
    c->decoding.have_pose = r->pose_id == s->meta.pose_id && s->meta.pose_id != 0;
    if (c->decoding.have_pose) memcpy(c->decoding.pose7, r->p7, sizeof r->p7);
    else if (s->meta.pose_id != 0) c->tot_pose_miss++;   // 0: rendered before any POSE
    pthread_mutex_unlock(&c->mu);

    double t0 = kl_stream_now();
    VTDecodeInfoFlags info = 0;
    st = VTDecompressionSessionDecodeFrame(c->sess, sb, 0, NULL, &info);
    VTDecompressionSessionWaitForAsynchronousFrames(c->sess);
    double ms = (kl_stream_now() - t0) * 1000.0;
    CFRelease(sb);
    if (st != noErr || c->decoding.keyframe < 0) {
        klsc_log("[stream-client] frame %u: decode failed (%d)", s->frame_id, (int)st);
        if (st == kVTInvalidSessionErr) klsc_drop_session(c);
        return -1;
    }
    double tnow = kl_stream_now();
    pthread_mutex_lock(&c->mu);
    c->tot_decoded++;
    c->w_decoded++;
    c->w_decode_ms += ms;
    if (c->t_prev_decoded > 0) {
        double iv = (tnow - c->t_prev_decoded) * 1000.0;
        c->w_iv_sum += iv; c->w_iv_sq += iv * iv; c->w_iv_n++;
        c->t_iv_sum += iv; c->t_iv_sq += iv * iv; c->t_iv_n++;
    }
    c->t_decode_ms += ms;
    c->t_prev_decoded = tnow;
    pthread_mutex_unlock(&c->mu);
    return 0;
}

// ---------------------------------------------------------------------------
// reassembly

static void klsc_free_slot(klsc_slot *s) { s->used = 0; }

static size_t klsc_frag_len(const klsc_slot *s, uint32_t i) {
    size_t off = (size_t)i * KL_STREAM_MTU_PAYLOAD;
    return s->frame_bytes - off < KL_STREAM_MTU_PAYLOAD ? s->frame_bytes - off : KL_STREAM_MTU_PAYLOAD;
}

// Group g has its parity and exactly one data fragment missing: rebuild it.
// Returns 1 when a fragment was rebuilt.
static int klsc_fec_try(kl_stream_client *c, klsc_slot *s, uint32_t g) {
    if (!s->fec_n || g >= s->groups || !s->par_have[g]) return 0;
    uint32_t a = g * s->fec_n, b = a + s->fec_n;
    if (b > s->frag_count) b = s->frag_count;
    uint32_t miss = 0, missing = 0;
    for (uint32_t i = a; i < b; i++) if (!s->have[i]) { missing = i; if (++miss > 1) return 0; }
    if (miss != 1) return 0;
    uint8_t tmp[KL_STREAM_MTU_PAYLOAD];
    size_t plen = klsc_frag_len(s, a);
    memcpy(tmp, s->par + (size_t)g * KL_STREAM_MTU_PAYLOAD, plen);
    for (uint32_t i = a; i < b; i++) {
        if (i == missing) continue;
        const uint8_t *src = s->buf + (size_t)i * KL_STREAM_MTU_PAYLOAD;
        size_t len = klsc_frag_len(s, i);
        for (size_t k = 0; k < len; k++) tmp[k] ^= src[k];
    }
    memcpy(s->buf + (size_t)missing * KL_STREAM_MTU_PAYLOAD, tmp, klsc_frag_len(s, missing));
    s->have[missing] = 1;
    s->got++;
    pthread_mutex_lock(&c->mu);
    c->tot_fec_fixed++;
    pthread_mutex_unlock(&c->mu);
    return 1;
}

static void klsc_complete(kl_stream_client *c, klsc_slot *s) {
    uint32_t f = s->frame_id;
    int broken = 0;
    if (c->have_completed) {
        uint32_t missing = f - c->last_completed - 1;
        if (missing > 0 && missing < 100000) {
            pthread_mutex_lock(&c->mu);
            c->tot_lost += missing;
            pthread_mutex_unlock(&c->mu);
            broken = 1;
        }
    }
    // Everything older and still incomplete is dead (already counted above).
    for (int i = 0; i < KLSC_SLOTS; i++) {
        klsc_slot *o = &c->slots[i];
        if (o != s && o->used && (int32_t)(o->frame_id - f) < 0) klsc_free_slot(o);
    }
    c->last_completed = f;
    c->have_completed = 1;

    int key = (s->meta.flags & KL_STREAM_VIDEO_KEYFRAME) != 0;
    if (broken) c->need_idr = 1;
    if (!c->sess && !key) c->need_idr = 1;
    if (c->need_idr && !key) {
        pthread_mutex_lock(&c->mu);
        c->tot_skipped++;
        pthread_mutex_unlock(&c->mu);
        if (kl_stream_now() - c->last_idr >= kl_env_float("KL_STREAM_IDR_MIN_S", 0.25f))
            klsc_send_idr(c);
        klsc_free_slot(s);
        return;
    }
    if (klsc_decode(c, s) != 0) {
        pthread_mutex_lock(&c->mu);
        c->tot_dec_err++;
        pthread_mutex_unlock(&c->mu);
        c->need_idr = 1;
        if (kl_stream_now() - c->last_idr >= kl_env_float("KL_STREAM_IDR_MIN_S", 0.25f))
            klsc_send_idr(c);
    } else {
        c->last_good_frame = f;
        if (key) c->need_idr = 0;
    }
    klsc_free_slot(s);
}

static void klsc_on_video(kl_stream_client *c, const uint8_t *pkt, size_t n) {
    if (n < sizeof(kl_stream_video)) return;
    kl_stream_video v;
    memcpy(&v, pkt, sizeof v);
    const uint8_t *payload = pkt + sizeof v;
    size_t plen = n - sizeof v;
    int parity = (v.flags & KL_STREAM_VIDEO_PARITY) != 0;
    if (v.frame_bytes == 0 || v.frame_bytes > KLSC_MAX_FRAME || v.frag_count == 0 ||
        (uint32_t)v.frag_count != (v.frame_bytes + KL_STREAM_MTU_PAYLOAD - 1) / KL_STREAM_MTU_PAYLOAD)
        return;
    uint32_t groups = v.fec_n ? ((uint32_t)v.frag_count + v.fec_n - 1) / v.fec_n : 0;
    if (parity ? (!v.fec_n || v.frag_index >= groups) : v.frag_index >= v.frag_count) return;
    // A parity packet's index is its group; its payload is as long as the
    // group's first data fragment.
    size_t off = (size_t)v.frag_index * (parity ? v.fec_n : 1u) * KL_STREAM_MTU_PAYLOAD;
    size_t want = v.frame_bytes - off < KL_STREAM_MTU_PAYLOAD ? v.frame_bytes - off
                                                              : KL_STREAM_MTU_PAYLOAD;
    if (plen != want) return;

    pthread_mutex_lock(&c->mu);
    c->w_bytes += plen;
    pthread_mutex_unlock(&c->mu);

    // Late: a fragment of a frame at or before one already completed.
    if (c->have_completed && (int32_t)(v.frame_id - c->last_completed) <= 0) return;

    klsc_slot *s = NULL, *freeslot = NULL, *oldest = NULL;
    for (int i = 0; i < KLSC_SLOTS; i++) {
        klsc_slot *o = &c->slots[i];
        if (o->used && o->frame_id == v.frame_id) { s = o; break; }
        if (!o->used) { if (!freeslot) freeslot = o; }
        else if (!oldest || (int32_t)(o->frame_id - oldest->frame_id) < 0) oldest = o;
    }
    if (!s) {
        s = freeslot;
        if (!s) {
            // Eight frames in flight and none complete: the oldest is not
            // coming. Counted when a newer frame completes past it.
            s = oldest;
            klsc_free_slot(s);
        }
        if (s->cap < v.frame_bytes) {
            free(s->buf);
            s->cap = v.frame_bytes + (v.frame_bytes >> 2);
            s->buf = malloc(s->cap);
            if (!s->buf) { s->cap = 0; return; }
        }
        if (s->have_cap < v.frag_count) {
            free(s->have);
            s->have_cap = v.frag_count;
            s->have = malloc(s->have_cap);
            if (!s->have) { s->have_cap = 0; return; }
        }
        if (groups && s->par_cap < (size_t)groups * KL_STREAM_MTU_PAYLOAD) {
            free(s->par);
            s->par_cap = (size_t)groups * KL_STREAM_MTU_PAYLOAD;
            s->par = malloc(s->par_cap);
            if (!s->par) { s->par_cap = 0; return; }
        }
        if (groups && s->par_have_cap < groups) {
            free(s->par_have);
            s->par_have_cap = groups;
            s->par_have = malloc(s->par_have_cap);
            if (!s->par_have) { s->par_have_cap = 0; return; }
        }
        memset(s->have, 0, v.frag_count);
        if (groups) memset(s->par_have, 0, groups);
        s->used = 1;
        s->frame_id = v.frame_id;
        s->frame_bytes = v.frame_bytes;
        s->frag_count = v.frag_count;
        s->fec_n = v.fec_n;
        s->groups = (uint16_t)groups;
        s->got = 0;
        s->meta = v;
        s->meta.flags &= ~KL_STREAM_VIDEO_PARITY;
    }
    if (s->frame_bytes != v.frame_bytes || s->frag_count != v.frag_count || s->fec_n != v.fec_n)
        return;
    uint32_t g;
    if (parity) {
        g = v.frag_index;
        if (s->par_have[g]) return;       // duplicate
        s->par_have[g] = 1;
        memcpy(s->par + (size_t)g * KL_STREAM_MTU_PAYLOAD, payload, plen);
    } else {
        if (s->have[v.frag_index]) return;    // duplicate
        s->have[v.frag_index] = 1;
        memcpy(s->buf + off, payload, plen);
        s->got++;
        g = s->fec_n ? v.frag_index / s->fec_n : 0;
    }
    s->t_last = kl_stream_now();
    if (s->fec_n) klsc_fec_try(c, s, g);
    if (s->got == s->frag_count) klsc_complete(c, s);
}

// ---------------------------------------------------------------------------
// audio (KL_STREAM_AUDIO packets)
//
// A jitter buffer between the network and kl_audio. The rx thread appends
// (filling a short gap from lost packets with silence, dropping late ones);
// the audio thread waits for KL_STREAM_AUDIO_PREBUFFER_MS (default 40) before
// it starts, then hands kl_audio 5 ms at a time — kl_audio_write blocks for
// as long as that takes to play, so the device paces the drain. The two
// clocks (the Mac's device, this one) drift apart slowly: more than
// KL_STREAM_AUDIO_MAX_MS (150) buffered drops the oldest down to the prebuffer
// target, running dry re-primes (one short gap). KL_STREAM_AUDIO_PLAY=0
// receives and counts without opening a device (the Mac harness).

static size_t klsc_au_buffered(kl_stream_client *c) { return c->au_w - c->au_r; }

static void *klsc_audio_main(void *arg) {
    kl_stream_client *c = arg;
    pthread_setname_np("Klepton stream audio");
    int play = kl_env_on("KL_STREAM_AUDIO_PLAY", 1);
    pthread_mutex_lock(&c->au_mu);
    unsigned rate = c->au_rate;
    pthread_mutex_unlock(&c->au_mu);
    if (play && kl_audio_open(rate, 2, 16) != 0) {
        klsc_log("[stream-client] audio: could not open the output at %u Hz — receiving without playing", rate);
        play = 0;
    }
    if (play) kl_audio_play();
    klsc_log("[stream-client] audio: %u Hz stereo, %s", rate, play ? "playing" : "not played (KL_STREAM_AUDIO_PLAY=0)");
    size_t chunk = rate / 200;             // 5 ms
    if (chunk < 32) chunk = 32;
    size_t prebuf = (size_t)(kl_env_float("KL_STREAM_AUDIO_PREBUFFER_MS", 40.0f) * rate / 1000.0f);
    int16_t *tmp = malloc(chunk * 2 * sizeof(int16_t));
    int primed = 0;
    pthread_mutex_lock(&c->au_mu);
    while (c->running) {
        size_t have = klsc_au_buffered(c);
        if (!primed) {
            if (have < prebuf) {
                struct timespec ts;
                clock_gettime(CLOCK_REALTIME, &ts);
                ts.tv_nsec += 10 * 1000000;
                if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
                pthread_cond_timedwait(&c->au_cv, &c->au_mu, &ts);
                continue;
            }
            primed = 1;
        }
        if (have < chunk) {                // ran dry: wait for the prebuffer again
            primed = 0;
            c->au_underruns++;
            continue;
        }
        for (size_t i = 0; i < chunk; i++) {
            size_t off = (c->au_r + i) % c->au_cap;
            tmp[i * 2] = c->au_ring[off * 2];
            tmp[i * 2 + 1] = c->au_ring[off * 2 + 1];
        }
        c->au_r += chunk;
        pthread_mutex_unlock(&c->au_mu);
        if (play) {
            if (kl_audio_write(tmp, chunk * 4) == 0) usleep(5000);
        } else {
            usleep((useconds_t)(chunk * 1000000ull / rate));
        }
        pthread_mutex_lock(&c->au_mu);
    }
    pthread_mutex_unlock(&c->au_mu);
    free(tmp);
    if (play) { kl_audio_pause(); kl_audio_flush(); }
    return NULL;
}

static void klsc_on_audio(kl_stream_client *c, const uint8_t *pkt, size_t n) {
    if (n < sizeof(kl_stream_audio) || !kl_env_on("KL_STREAM_AUDIO", 1)) return;
    kl_stream_audio a;
    memcpy(&a, pkt, sizeof a);
    if ((a.channels != 1 && a.channels != 2) || !a.frames || a.frames > KL_STREAM_AUDIO_MAX_FRAMES ||
        a.sample_rate < 8000 || a.sample_rate > 192000) return;
    if (n < sizeof a + (size_t)a.frames * a.channels * 2) return;
    const int16_t *pcm = (const int16_t *)(pkt + sizeof a);
    pthread_mutex_lock(&c->au_mu);
    if (!c->au_started) {
        c->au_rate = a.sample_rate;
        c->au_cap = a.sample_rate;           // 1 s
        c->au_ring = calloc(c->au_cap * 2, sizeof(int16_t));
        c->au_started = 1;
        if (pthread_create(&c->au_thread, NULL, klsc_audio_main, c) != 0) {
            klsc_log("[stream-client] audio: cannot start the audio thread");
            c->au_started = -1;
        }
    }
    if (c->au_started < 0 || a.sample_rate != c->au_rate) {   // rate changes are not followed
        pthread_mutex_unlock(&c->au_mu);
        return;
    }
    c->au_pkts++;
    if (c->au_have_expect) {
        if (a.first_frame < c->au_expect) {
            // Late or duplicate — or the host restarted its count (a new
            // session): only a big step back is taken as the latter.
            if (c->au_expect - a.first_frame < c->au_rate) { c->au_late++; pthread_mutex_unlock(&c->au_mu); return; }
        } else if (a.first_frame > c->au_expect) {
            uint64_t gap = a.first_frame - c->au_expect;
            if (gap <= c->au_rate / 10) {      // <= 100 ms lost: that much silence
                for (uint64_t i = 0; i < gap; i++) {
                    size_t off = c->au_w++ % c->au_cap;
                    c->au_ring[off * 2] = c->au_ring[off * 2 + 1] = 0;
                }
                c->au_gap_frames += (uint32_t)gap;
            }
        }
    }
    for (unsigned i = 0; i < a.frames; i++) {
        size_t off = c->au_w++ % c->au_cap;
        int16_t l = pcm[i * a.channels], r = a.channels == 2 ? pcm[i * 2 + 1] : l;
        c->au_ring[off * 2] = l;
        c->au_ring[off * 2 + 1] = r;
    }
    c->au_expect = a.first_frame + a.frames;
    c->au_have_expect = 1;
    size_t maxb = (size_t)(kl_env_float("KL_STREAM_AUDIO_MAX_MS", 150.0f) * c->au_rate / 1000.0f);
    if (maxb > c->au_cap - 1) maxb = c->au_cap - 1;
    if (klsc_au_buffered(c) > maxb) {
        size_t keep = (size_t)(kl_env_float("KL_STREAM_AUDIO_PREBUFFER_MS", 40.0f) * c->au_rate / 1000.0f);
        c->au_r = c->au_w - keep;
        c->au_overflow++;
    }
    pthread_cond_signal(&c->au_cv);
    pthread_mutex_unlock(&c->au_mu);
}

// ---------------------------------------------------------------------------
// receive thread

static void klsc_on_packet(kl_stream_client *c, const uint8_t *pkt, size_t n) {
    if (n < sizeof(kl_stream_hdr)) return;
    kl_stream_hdr h;
    memcpy(&h, pkt, sizeof h);
    if (h.magic != KL_STREAM_MAGIC) return;
    if (h.version != KL_STREAM_VERSION) {
        static int said;
        if (!said++) klsc_log("[stream-client] host speaks protocol v%u, we speak v%u",
                              h.version, KL_STREAM_VERSION);
        return;
    }
    switch (h.type) {
    case KL_STREAM_HELLO_ACK: {
        if (n < sizeof(kl_stream_hello_ack)) return;
        kl_stream_hello_ack a;
        memcpy(&a, pkt, sizeof a);
        a.guest[sizeof a.guest - 1] = 0;
        pthread_mutex_lock(&c->mu);
        int first = !c->acked && !c->refused;
        c->ack = a;
        if (a.status == KL_STREAM_OK) {
            if (!c->acked) c->t_ack = kl_stream_now();
            c->acked = 1;
        } else {
            c->refused = 1;
        }
        pthread_mutex_unlock(&c->mu);
        if (first)
            klsc_log("[stream-client] HELLO_ACK: status %u, guest \"%s\", codec %.4s, "
                     "%ux%u, %u kbps, host %.1f fps", a.status, a.guest,
                     (const char *)&a.codec, a.frame_w, a.frame_h, a.bitrate_kbps,
                     (double)a.host_fps_target);
        break;
    }
    case KL_STREAM_VIDEO:
        klsc_on_video(c, pkt, n);
        break;
    case KL_STREAM_AUDIO:
        klsc_on_audio(c, pkt, n);
        break;
    case KL_STREAM_HAPTICS: {
        if (n < sizeof(kl_stream_haptics)) return;
        kl_stream_haptics hp;
        memcpy(&hp, pkt, sizeof hp);
        // The existing path: KleptonControllers.pumpHaptics drains
        // kl_ovrp_haptics_pull every frame and drives the Sense actuator.
        if (hp.hand <= 1) {
            if (hp.amplitude > 0) kl_ovrp_haptics_apply((int)hp.hand, hp.amplitude, hp.seconds);
            else kl_ovrp_haptics_stop((int)hp.hand);
        }
        break;
    }
    case KL_STREAM_PING: {
        if (n < sizeof(kl_stream_ping)) return;
        kl_stream_ping p;
        memcpy(&p, pkt, sizeof p);
        p.t_reply = kl_stream_now();
        klsc_send(c, &p, sizeof p, KL_STREAM_PONG);
        break;
    }
    case KL_STREAM_PONG: {
        if (n < sizeof(kl_stream_ping)) return;
        kl_stream_ping p;
        memcpy(&p, pkt, sizeof p);
        float rtt = (float)((kl_stream_now() - p.t_send) * 1000.0);
        pthread_mutex_lock(&c->mu);
        c->rtt_ms = rtt;
        pthread_mutex_unlock(&c->mu);
        break;
    }
    case KL_STREAM_BYE:
        pthread_mutex_lock(&c->mu);
        int was = c->ended;
        c->ended = 1;
        pthread_mutex_unlock(&c->mu);
        if (!was) klsc_log("[stream-client] the host said BYE");
        break;
    default:
        break;
    }
}

static void klsc_window(kl_stream_client *c, double now) {
    pthread_mutex_lock(&c->mu);
    double dt = now - c->w_start;
    kl_stream_client_status *s = &c->st;
    s->video_fps = (float)(c->w_decoded / dt);
    s->decode_ms = c->w_decoded ? (float)(c->w_decode_ms / c->w_decoded) : 0;
    s->kbps = (float)(c->w_bytes * 8.0 / 1000.0 / dt);
    s->p2p_ms = c->w_p2p_n ? (float)(c->w_p2p_ms / c->w_p2p_n) : 0;
    s->rtt_ms = c->rtt_ms;
    if (c->w_iv_n) {
        double m = c->w_iv_sum / c->w_iv_n, var = c->w_iv_sq / c->w_iv_n - m * m;
        s->interval_ms = (float)m;
        s->interval_sd_ms = (float)(var > 0 ? sqrt(var) : 0);
    } else {
        s->interval_ms = s->interval_sd_ms = 0;
    }
    c->w_iv_sum = c->w_iv_sq = 0; c->w_iv_n = 0;
    c->w_decoded = 0; c->w_decode_ms = 0; c->w_bytes = 0;
    c->w_p2p_ms = 0; c->w_p2p_n = 0; c->w_start = now;
    uint32_t skipped = c->tot_skipped;
    pthread_mutex_unlock(&c->mu);

    kl_stream_client_status now_s;
    kl_stream_client_get_status(c, &now_s);
    char line[384];
    snprintf(line, sizeof line,
             "[stream-client] %s: video %.1f fps (interval %.1f sd %.1f ms), decode %.2f ms, "
             "lost %u, idr %u, fec-fixed %u, "
             "pose->photon %.1f ms, %.1f Mbps, rtt %.1f ms, pose-miss %u, skipped %u, "
             "dec-err %u, poses %u, audio %u pkts (%.0f ms buffered, %u underruns)",
             kl_stream_client_state_name(now_s.state), (double)now_s.video_fps,
             (double)now_s.interval_ms, (double)now_s.interval_sd_ms,
             (double)now_s.decode_ms, now_s.frames_lost, now_s.idr_requests, now_s.fec_fixed,
             (double)now_s.p2p_ms, (double)now_s.kbps / 1000.0, (double)now_s.rtt_ms,
             now_s.pose_misses, skipped, now_s.decode_errors, now_s.poses_sent,
             now_s.audio_packets, (double)now_s.audio_ms, now_s.audio_underruns);
    pthread_mutex_lock(&c->mu);
    memcpy(c->st.line, line, sizeof line);
    pthread_mutex_unlock(&c->mu);
    if (kl_env_on("KL_STREAM_LOG", 1)) klsc_log("%s", line);
}

static void *klsc_rx_main(void *arg) {
    kl_stream_client *c = arg;
    pthread_setname_np("Klepton stream rx");
    uint8_t *pkt = malloc(65536);
    c->w_start = kl_stream_now();
    while (c->running) {
        struct pollfd pfd = { .fd = c->fd, .events = POLLIN };
        int r = poll(&pfd, 1, 20);
        if (r > 0 && (pfd.revents & POLLIN)) {
            // Drain everything queued before the housekeeping below.
            for (int i = 0; i < 512; i++) {
                ssize_t n = recv(c->fd, pkt, 65536, MSG_DONTWAIT);
                if (n <= 0) break;
                klsc_on_packet(c, pkt, (size_t)n);
            }
        }
        double now = kl_stream_now();
        pthread_mutex_lock(&c->mu);
        int have_display = c->have_display, acked = c->acked, done = c->refused || c->ended;
        pthread_mutex_unlock(&c->mu);
        if (!done && have_display && !acked && now - c->last_hello >= 1.0) klsc_send_hello(c);
        if (!done && acked && now - c->last_ping >= 1.0) {
            kl_stream_ping p = {0};
            p.t_send = now;
            klsc_send(c, &p, sizeof p, KL_STREAM_PING);
            c->last_ping = now;
        }
        if (!done && acked && c->need_idr &&
            now - c->last_idr >= kl_env_float("KL_STREAM_IDR_MIN_S", 0.25f) * 2)
            klsc_send_idr(c);   // the keyframe did not come: ask again
        if (now - c->w_start >= 1.0) klsc_window(c, now);
    }
    free(pkt);
    return NULL;
}

// ---------------------------------------------------------------------------
// lifecycle

kl_stream_client *kl_stream_client_create(const char *host, int port) {
    if (!host || !*host) return NULL;
    if (port <= 0) port = KL_STREAM_PORT_DEFAULT;
    char ps[16];
    snprintf(ps, sizeof ps, "%d", port);
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    int gr = getaddrinfo(host, ps, &hints, &res);
    if (gr != 0 || !res) {
        klsc_log("[stream-client] cannot resolve %s: %s", host, gai_strerror(gr));
        return NULL;
    }
    int fd = -1;
    for (struct addrinfo *a = res; a; a = a->ai_next) {
        fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, a->ai_addr, a->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        klsc_log("[stream-client] cannot open a UDP socket to %s:%d: %s", host, port,
                 strerror(errno));
        return NULL;
    }
    // A keyframe of a 3.6K-wide stream is a few hundred fragments arriving in
    // a burst; the default receive buffer drops the tail of it.
    int rcv = kl_env_int("KL_STREAM_RCVBUF", 8 << 20);
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, sizeof rcv);

    kl_stream_client *c = calloc(1, sizeof *c);
    c->fd = fd;
    snprintf(c->host, sizeof c->host, "%s", host);
    c->port = port;
    pthread_mutex_init(&c->mu, NULL);
    pthread_mutex_init(&c->tx_mu, NULL);
    pthread_mutex_init(&c->au_mu, NULL);
    pthread_cond_init(&c->au_cv, NULL);
    c->running = 1;
    c->t_last_video = -1;
    c->last_idr = -1e9;
    c->decode_bgra = kl_env_on("KL_STREAM_DECODE_BGRA", 0);
    if (pthread_create(&c->rx, NULL, klsc_rx_main, c) != 0) {
        klsc_log("[stream-client] cannot start the receive thread");
        close(fd);
        free(c);
        return NULL;
    }
    klsc_log("[stream-client] socket open to %s:%d (protocol v%u)", host, port,
             KL_STREAM_VERSION);
    return c;
}

void kl_stream_client_destroy(kl_stream_client *c) {
    if (!c) return;
    c->running = 0;
    pthread_join(c->rx, NULL);
    pthread_mutex_lock(&c->au_mu);
    int au = c->au_started > 0;
    pthread_cond_broadcast(&c->au_cv);
    pthread_mutex_unlock(&c->au_mu);
    if (au) pthread_join(c->au_thread, NULL);
    if (c->au_pkts)
        klsc_log("[stream-client] audio: %u packets, %u frames of gaps filled, %u late, "
                 "%u underruns, %u overflows", c->au_pkts, c->au_gap_frames, c->au_late,
                 c->au_underruns, c->au_overflow);
    free(c->au_ring);
    pthread_mutex_destroy(&c->au_mu);
    pthread_cond_destroy(&c->au_cv);
    for (int i = 0; i < 3; i++) {
        kl_stream_hdr b = {0};
        klsc_send(c, &b, sizeof b, KL_STREAM_BYE);
    }
    klsc_log("[stream-client] BYE sent; %u frames decoded, %u lost, %u IDR requests",
             c->tot_decoded, c->tot_lost, c->tot_idr);
    close(c->fd);
    klsc_drop_session(c);
    if (c->fmt) CFRelease(c->fmt);
    if (c->latest) CVPixelBufferRelease(c->latest);
    for (int i = 0; i < KLSC_SLOTS; i++) {
        free(c->slots[i].buf); free(c->slots[i].have);
        free(c->slots[i].par); free(c->slots[i].par_have);
    }
    pthread_mutex_destroy(&c->mu);
    pthread_mutex_destroy(&c->tx_mu);
    free(c);
}

CVPixelBufferRef kl_stream_client_pull_frame(kl_stream_client *c,
                                             kl_stream_frame_info *info) {
    if (!c) return NULL;
    pthread_mutex_lock(&c->mu);
    CVPixelBufferRef pb = c->latest;
    if (pb && info) *info = c->latest_info;
    c->latest = NULL;
    pthread_mutex_unlock(&c->mu);
    return pb;
}

void kl_stream_client_note_displayed(kl_stream_client *c, double presentation_time,
                                     double t_pose) {
    if (!c) return;
    pthread_mutex_lock(&c->mu);
    c->w_p2p_ms += (presentation_time - t_pose) * 1000.0;
    c->w_p2p_n++;
    pthread_mutex_unlock(&c->mu);
}

const char *kl_stream_client_state_name(int state) {
    switch (state) {
    case KL_STREAM_CLIENT_CONNECTING: return "connecting";
    case KL_STREAM_CLIENT_WAITING:    return "waiting";
    case KL_STREAM_CLIENT_STREAMING:  return "streaming";
    case KL_STREAM_CLIENT_NO_SIGNAL:  return "no-signal";
    case KL_STREAM_CLIENT_REFUSED:    return "refused";
    case KL_STREAM_CLIENT_ENDED:      return "ended";
    default:                          return "?";
    }
}

void kl_stream_client_get_status(kl_stream_client *c, kl_stream_client_status *s) {
    if (!c || !s) return;
    double now = kl_stream_now();
    pthread_mutex_lock(&c->mu);
    *s = c->st;
    s->ack_status = c->ack.status;
    memcpy(s->guest, c->ack.guest, sizeof s->guest);
    s->frame_w = c->ack.frame_w;
    s->frame_h = c->ack.frame_h;
    s->bitrate_kbps = c->ack.bitrate_kbps;
    s->host_fps_target = c->ack.host_fps_target;
    s->since_video_s = c->t_last_video < 0 ? -1 : now - c->t_last_video;
    s->frames_decoded = c->tot_decoded;
    s->frames_lost = c->tot_lost;
    s->idr_requests = c->tot_idr;
    s->decode_errors = c->tot_dec_err;
    s->pose_misses = c->tot_pose_miss;
    s->poses_sent = c->tot_poses;
    s->fec_fixed = c->tot_fec_fixed;
    pthread_mutex_lock(&c->au_mu);
    s->audio_packets = c->au_pkts;
    s->audio_underruns = c->au_underruns;
    s->audio_gap_frames = c->au_gap_frames;
    s->audio_ms = c->au_rate ? (float)((double)(c->au_w - c->au_r) * 1000.0 / c->au_rate) : 0;
    pthread_mutex_unlock(&c->au_mu);
    s->decode_ms_mean = c->tot_decoded ? (float)(c->t_decode_ms / c->tot_decoded) : 0;
    if (c->t_iv_n) {
        double m = c->t_iv_sum / c->t_iv_n, var = c->t_iv_sq / c->t_iv_n - m * m;
        s->interval_ms_mean = (float)m;
        s->interval_sd_ms_all = (float)(var > 0 ? sqrt(var) : 0);
    }
    if (c->ended)        s->state = KL_STREAM_CLIENT_ENDED;
    else if (c->refused) s->state = KL_STREAM_CLIENT_REFUSED;
    else if (!c->acked)  s->state = KL_STREAM_CLIENT_CONNECTING;
    else {
        // "No signal" is a second without a decoded picture — measured from
        // the last picture, or from the ACK when there has never been one.
        double ref = c->t_last_video >= 0 ? c->t_last_video : c->t_ack;
        if (now - ref > kl_env_float("KL_STREAM_NOSIGNAL_S", 1.0f))
            s->state = KL_STREAM_CLIENT_NO_SIGNAL;
        else s->state = c->t_last_video >= 0 ? KL_STREAM_CLIENT_STREAMING
                                             : KL_STREAM_CLIENT_WAITING;
    }
    pthread_mutex_unlock(&c->mu);
}

// ---------------------------------------------------------------------------
// The eye split + YUV -> RGB shader (see kl_stream_client.h)

static const char k_yuv_msl[] =
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct KLSYOut { float4 pos [[position]]; };\n"
"struct KLSYU { uint x0; uint eye_w; uint frame_w; uint frame_h;\n"
"               float y_off; float y_scale; float c_off; float c_scale; };\n"
"vertex KLSYOut kl_stream_yuv_v(uint vid [[vertex_id]]) {\n"
"    float2 p = float2((vid << 1) & 2, vid & 2);\n"
"    KLSYOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); return o;\n"
"}\n"
"fragment float4 kl_stream_yuv_f(KLSYOut in [[stage_in]],\n"
"        texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]],\n"
"        constant KLSYU &u [[buffer(0)]]) {\n"
"    constexpr sampler ls(filter::linear, address::clamp_to_edge, coord::pixel);\n"
"    uint2 px = uint2(in.pos.xy);\n"
"    float y = ty.read(uint2(u.x0 + px.x, px.y)).r;\n"
"    // Chroma bilinear in its own (half-size) grid, clamped inside this eye's\n"
"    // half so the other eye never bleeds into the seam column.\n"
"    float2 cp = (float2(float(u.x0) + in.pos.x, in.pos.y)) * 0.5;\n"
"    float c0 = float(u.x0) * 0.5 + 0.5, c1 = float(u.x0 + u.eye_w) * 0.5 - 0.5;\n"
"    cp.x = clamp(cp.x, c0, c1);\n"
"    float2 c = tc.sample(ls, cp).rg;\n"
"    y = (y - u.y_off) * u.y_scale;\n"
"    c = (c - u.c_off) * u.c_scale;\n"
"    float3 rgb = float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x);\n"
"    // The stream carries sRGB-ENCODED values (the host's compose) and they are\n"
"    // stored as they are: the target is a bgra8Unorm VIEW of the _srgb stage\n"
"    // texture, so the bytes equal what a BGRA decode + blit leaves there and\n"
"    // no transfer curve is computed per pixel.\n"
"    return float4(saturate(rgb), 1.0);\n"
"}\n";

const char *kl_stream_yuv_msl(void) { return k_yuv_msl; }

void kl_stream_yuv_params(OSType pixfmt, kl_stream_yuv_uniforms *u) {
    memset(u, 0, sizeof *u);
    if (pixfmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
        // 10 bits in the top of 16: read as unorm16, x/1023.98 ~ v10/1023.
        u->y_off = 64.0f / 1023.0f;  u->y_scale = 1023.0f / 876.0f;
        u->c_off = 512.0f / 1023.0f; u->c_scale = 1023.0f / 896.0f;
    } else {
        u->y_off = 16.0f / 255.0f;   u->y_scale = 255.0f / 219.0f;
        u->c_off = 128.0f / 255.0f;  u->c_scale = 255.0f / 224.0f;
    }
}
