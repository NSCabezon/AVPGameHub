// kl_stream_client.h — the headset half of "Jugar desde el Mac".
//
// The CLIENT side of kl_stream_proto.h: one UDP socket to the host, a receive
// thread that reassembles VIDEO fragments into frames, decodes them with
// VideoToolbox (HEVC, length-prefixed NALs, parameter sets from the keyframe's
// leading NALs) and keeps the newest decoded picture for the compositor to
// pull. The send side is called from the compositor's render thread: one POSE
// per display frame, built from the same kl_ovrp values the compositor and
// KleptonControllers publish locally.
//
// Plain C on purpose (CoreVideo/VideoToolbox, BSD sockets, pthreads — no
// Metal, no Swift): the same file builds into the visionOS app through
// libklepton and into the Mac-side harness (tools/kl_stream_harness.c), so the
// reassembly/decoding path the headset runs is the one tested on the Mac.
//
// What it deliberately does NOT do: touch the compositor. The app pulls a
// decoded CVPixelBuffer plus the pose it was rendered with
// (kl_stream_client_pull_frame) and publishes it through the same seam a local
// guest uses (KleptonStreamClient.swift: kl_glfb_note_eye_mtl_texture +
// kl_ovrp_frame_end_external).
//
// Every timestamp is the CLIENT's clock: kl_stream_now(), which is
// mach_absolute_time in seconds — the clock CACurrentMediaTime, ARKit and
// LayerRenderer presentation times are on.
#ifndef KL_STREAM_CLIENT_H
#define KL_STREAM_CLIENT_H

#include <stdint.h>
#include <CoreVideo/CoreVideo.h>
#include "kl_stream_proto.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct kl_stream_client kl_stream_client;

// Seconds on the client clock (== CACurrentMediaTime()).
double kl_stream_now(void);

// Where the client's log lines go. Default: stderr. The app routes them to
// NSLog so they reach the device console. Set before create.
typedef void (*kl_stream_log_fn)(const char *line);
void kl_stream_set_log(kl_stream_log_fn fn);

// Resolve `host` (IPv4/IPv6 literal or name) and open the socket. port <= 0
// means KL_STREAM_PORT_DEFAULT. Starts the receive thread at once; no HELLO is
// sent until a display description exists (kl_stream_client_set_display).
// NULL on failure (reason logged).
kl_stream_client *kl_stream_client_create(const char *host, int port);

// Sends BYE (three times — it is UDP and nothing acks it), stops and joins the
// receive thread, releases everything. NULL is a no-op.
void kl_stream_client_destroy(kl_stream_client *c);

// The display description HELLO carries (header ignored, filled here). HELLO is
// then sent at ~1 Hz until HELLO_ACK arrives. Calling it again re-sends.
void kl_stream_client_set_display(kl_stream_client *c, const kl_stream_hello *h);

// Fill a HELLO body from what the compositor published into kl_ovrp: eye
// offsets/cant (kl_ovrp_eye_local), display Hz, recommended eye size. `tan`
// are the RAW per-eye tangents the compositor gave kl_ovrp_set_eye_frustum
// (left, right, up, down); NULL falls back to kl_ovrp_eye_view's.
void kl_stream_hello_from_ovrp(kl_stream_hello *out, const float tan[2][4],
                               const char *device);

// One POSE. Fills the header and pose_id (returned), records (pose_id, t_pose,
// head pose) in the 256-entry ring VIDEO frames are matched against, and sends.
uint32_t kl_stream_client_send_pose(kl_stream_client *c, kl_stream_pose *p);

// ...the same, built from kl_ovrp: latches (kl_ovrp_frame_latch — in stream
// mode no guest runs in this process, so the client IS the latch's reader) and
// reads head pose + motion, both hands' pose/motion and controller input.
// `t_pose` is the predicted presentation time the head pose was predicted to;
// `connected_mask` bit h = a controller (not a bare hand) drives hand h.
uint32_t kl_stream_client_send_pose_from_ovrp(kl_stream_client *c, double t_pose,
                                              uint32_t connected_mask);

typedef struct {
    uint32_t frame_id;
    uint32_t pose_id;
    double   t_pose;        // as echoed by the host
    int      have_pose;     // pose_id was still in the ring
    float    pose7[7];      // ring[pose_id]: head px,py,pz,qx,qy,qz,qw
    float    tan[2][4];     // VIDEO.tan: left, right, up, down per eye
    int      keyframe;
    int      width, height; // decoded frame (both eyes side by side)
    double   t_received;    // last fragment in
    double   t_decoded;     // decoder output
    float    host_ms_render, host_ms_encode;
} kl_stream_frame_info;

// The newest decoded frame since the last pull (+1 retained; caller
// CVPixelBufferRelease's it), or NULL. Older undisplayed frames are dropped.
CVPixelBufferRef kl_stream_client_pull_frame(kl_stream_client *c,
                                             kl_stream_frame_info *info);

// The compositor tells us when a pulled frame first went to the display:
// pose->photon = presentation_time - t_pose.
void kl_stream_client_note_displayed(kl_stream_client *c, double presentation_time,
                                     double t_pose);

enum {
    KL_STREAM_CLIENT_CONNECTING = 0,  // no HELLO_ACK yet
    KL_STREAM_CLIENT_WAITING    = 1,  // acked, no picture decoded yet
    KL_STREAM_CLIENT_STREAMING  = 2,  // pictures arriving
    KL_STREAM_CLIENT_NO_SIGNAL  = 3,  // acked, > 1 s since the last decoded frame
    KL_STREAM_CLIENT_REFUSED    = 4,  // HELLO_ACK.status != OK
    KL_STREAM_CLIENT_ENDED      = 5,  // host sent BYE
};

typedef struct {
    int      state;
    uint32_t ack_status;
    char     guest[32];
    uint32_t frame_w, frame_h, bitrate_kbps;
    float    host_fps_target;
    double   since_video_s;     // since the last decoded frame; -1 = never
    // The last full second.
    float    video_fps, decode_ms, kbps, rtt_ms, p2p_ms;
    float    interval_ms, interval_sd_ms;   // between decoded frames: cadence
    uint32_t fec_fixed;         // total fragments rebuilt from parity
    // Whole-session means: decode, and the decoded-frame interval + its sd.
    float    decode_ms_mean, interval_ms_mean, interval_sd_ms_all;
    // Totals.
    uint32_t frames_decoded, frames_lost, idr_requests, decode_errors,
             pose_misses, poses_sent;
    // AUDIO: packets received, jitter-buffer depth now, times it ran dry,
    // frames of silence put in for lost packets.
    uint32_t audio_packets, audio_underruns, audio_gap_frames;
    float    audio_ms;
    char     line[384];         // the last [stream-client] stats line
} kl_stream_client_status;

void kl_stream_client_get_status(kl_stream_client *c, kl_stream_client_status *s);

// The decoded picture is native biplanar 4:2:0 ('420v', or 'x420' for a
// 10-bit stream) unless KL_STREAM_DECODE_BGRA=1. The app turns it into the
// per-eye RGB stage textures with this Metal source — vertex kl_stream_yuv_v,
// fragment kl_stream_yuv_f (texture 0 = luma plane as R8/R16Unorm, texture 1 =
// chroma plane as RG8/RG16Unorm, buffer 0 = kl_stream_yuv_uniforms), one
// render pass per eye (slice) into a bgra8Unorm (NOT _srgb) VIEW of the
// bgra8Unorm_srgb stage texture, sized eye_w x frame_h: it writes the
// sRGB-encoded bytes as they are (texture usage needs .pixelFormatView).
// Shared by KleptonStreamClient.swift and the Mac harness, so the conversion
// the headset runs is the one measured and checked on the Mac.
typedef struct {
    uint32_t x0, eye_w, frame_w, frame_h;   // x0 = eye * eye_w
    float    y_off, y_scale, c_off, c_scale;
} kl_stream_yuv_uniforms;
const char *kl_stream_yuv_msl(void);
// Range constants for a decoded pixel format (x0/eye_w/frame_* left 0).
void kl_stream_yuv_params(OSType pixfmt, kl_stream_yuv_uniforms *u);
const char *kl_stream_client_state_name(int state);

#ifdef __cplusplus
}
#endif
#endif
