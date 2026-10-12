// kl_stream_host — the Mac (HOST) side of "Jugar desde el Mac".
//
// KL_STREAM_HOST=1 is the alternative to KL_VIEW=1: instead of a window whose
// mouse drives the head, a UDP server whose headset drives it. The two halves
// meet the guest at the same seams the viewer and the visionOS compositor use:
//
//   pose in    — POSE packets -> kl_ovrp_set_head_pose_tag/_time + _set_head_pose,
//                kl_ovrp_set_hand_motion (TRACKED), kl_ovrp_set_controller_input
//                (CONNECTED). The display description in HELLO ->
//                kl_ovrp_set_eye_frustum/_offset/_rotation, _display_frequency,
//                _eye_texture_size.
//   frame out  — every completed guest frame (kl_vulkan_frame_serial advancing):
//                both eyes of kl_ovrp_last_complete_stage() composed side by
//                side into an IOSurface NV12 CVPixelBuffer, HEVC-encoded with
//                VideoToolbox (kl_stream_host_mtl.m) and sent as VIDEO
//                fragments, tagged with the pose_id/t_pose the frame was
//                RENDERED with (kl_ovrp_render_pose.head_tag/head_time).
//
// The wire protocol is runtime/net/kl_stream_proto.h. Host-only: named by the
// m_boot rule alone, never in RUNTIME_SHIP.
#ifndef KL_STREAM_HOST_H
#define KL_STREAM_HOST_H

#include <stddef.h>
#include <stdint.h>

// KL_STREAM_HOST=1.
int kl_stream_host_enabled(void);

// Open the UDP socket on KL_STREAM_PORT, register the Bonjour service and
// start the network thread. `guest` is what HELLO_ACK names. 0 on success.
int kl_stream_host_start(const char *guest);

// Block until a client's HELLO has been applied to kl_ovrp (returns 1), the
// timeout passes (0; timeout_s < 0 waits forever) or *quit is set (0).
int kl_stream_host_wait_hello(double timeout_s, const volatile int *quit);

// Apply the built-in Vision Pro-like display description (the same numbers
// the fake client sends) when the guest is started before any client.
void kl_stream_host_apply_defaults(void);

// KL_STREAM_LOCK_FPS (default 45): pace the guest's WaitGetPoses to that rate
// (kl_openvr_set_frame_pacer). Call before the guest starts.
void kl_stream_host_install_pacer(void);

// The frame/encode loop and, with KL_STREAM_PREVIEW=1, a local SDL preview
// window on the calling (main) thread. Returns when *quit is set.
int kl_stream_host_run(const volatile int *quit);

// ---- between kl_stream_host.c and kl_stream_host_mtl.m --------------------

typedef struct {
    uint32_t frame_id;
    uint32_t pose_id;
    double   t_pose;
    float    tan[2][4];
    float    ms_render;
    double   t_compose_start;   // host CLOCK_UPTIME_RAW seconds
    double   t_encode_start;
    uint64_t pose_host_ns;      // when the host received the echoed pose (0 = unknown)
} kl_stream_frame_meta;

// The encoder's output: one access unit as length-prefixed NAL units (4-byte
// big-endian), VPS/SPS/PPS first on a keyframe. Called on a VideoToolbox thread.
typedef void (*kl_stream_enc_out_fn)(const kl_stream_frame_meta *m,
                                     const uint8_t *au, size_t n, int keyframe,
                                     float ms_encode);

// Compose `stage`'s two eyes side by side into a w x h frame and encode it.
// (Re)creates the encoder when w/h/fps change; a kbps change retargets the live
// session (AverageBitRate, no keyframe). Returns 0 when a frame
// was handed to the encoder, -1 if there was nothing to compose yet, -2 when
// it was skipped because the encoder already holds KL_STREAM_MAX_INFLIGHT.
int  kl_stream_enc_frame(int stage, int w, int h, int kbps, float fps,
                         int force_idr, kl_stream_frame_meta *m,
                         kl_stream_enc_out_fn out);
void kl_stream_enc_close(void);
// The last composed frame into a CAMetalLayer (the preview). 1 if drawn.
int  kl_stream_preview_present(void *metal_layer, int pw, int ph);

double kl_stream_host_now(void);     // CLOCK_UPTIME_RAW seconds (== CACurrentMediaTime)

#endif
