// An OpenVR runtime of our own, for the glibc door — see kl_openvr.h.
//
// WHICH LAYER
//
// Alyx's libvr.so imports seven entry points from libopenvr_api.so
// (VR_InitInternal2, VR_GetGenericInterface, VR_IsInterfaceVersionValid,
// VR_GetInitToken, VR_ShutdownInternal and the two error-name calls) and then
// talks to the C++ interface objects VR_GetGenericInterface returns — never
// FnTable, never a vrserver of its own. libopenvr_api's half of that is only a
// client that looks for SteamVR (openvrpaths.vrpath) and fails without it. So,
// like the Steam stub, this answers at the export layer: those imports bind
// here through the glibc ABI tier, and the objects handed back are ours, with
// vtables generated from OpenVR's public openvr.h (kl_openvr_vtables.h,
// tools/gen_openvr_vtables.py). Every slot exists; unimplemented ones log
// "IVRx_nnn::Method (#slot)" and return 0, which for the error-returning ones
// is "None". Private versions (IVRInputInternal_002, IVRMailbox_001,
// IVRIPCResourceManagerClient_004) and ones that differ from the public header
// (IVRApplications_007) get 128 logging slots.
//
// WHERE THE ANSWERS COME FROM
//
// kl_ovrp is the one XR state hub in this tree: the frontend (the macOS viewer,
// ARKit + Compositor Services on device, or nothing — a headless run gets a
// head standing at eye height with the hands parked in front) publishes head,
// hands, controller input and the eye frustum there, and kl_openxr already
// reads it back for OpenXR guests. This is a third reader of the same seam:
//
//   IVRSystem      device 0 = HMD, 1 = left hand, 2 = right hand (Touch-style
//                  controllers, "oculus_touch"); eye frusta, eye-to-head and the
//                  render-target size from kl_ovrp_eye_view / _eye_texture_size
//   IVRCompositor  WaitGetPoses = the frame latch; Submit copies the guest's
//                  VkImage (VRVulkanTextureData_t) into an MTLTexture-backed
//                  image of ours on the guest's own queue, and the frame is
//                  filed through exactly the seams kl_openxr files an OpenXR
//                  Vulkan frame through (kl_glfb_note_eye_mtl_texture,
//                  kl_ovrp_frame_end_external, kl_vulkan_frame_done) — so
//                  whatever composites an OpenXR guest composites this one
//   IVRInput       Alyx's own action set (the names are in libclient), bound
//                  by a built-in table to Touch-style inputs: trigger, grip,
//                  stick, A/B/X/Y, menu — see k_bind below
//   IVRChaperone   a 2 x 2 m play area
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdatomic.h>
#include <time.h>

#include "klepton.h"
#include "kl_env.h"
#include "kl_ovrp.h"
#include "kl_glfb.h"
#include "kl_vulkan.h"
#include "kl_openvr.h"
#include "kl_reproject.h"
#include "kl_gpu_time.h"     // KL_GPU_TIME: the frame close and GetFrameTiming

#if __has_include(<vulkan/vulkan.h>)
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#define KLOVR_VULKAN 1
#endif

#define TRACE(...) do { if (kl_env_on("KL_TRACE_OPENVR", 0)) fprintf(stderr, "  [openvr] " __VA_ARGS__); } while (0)

// ---- KL_OPENVR_MINIMAL: the whole pipeline with every stage of ours OFF ----------
// A bisection switch. Each stage this bridge (and the compositor) adds between
// the game's picture and the display has its own knob; MINIMAL=1 flips every
// one of those knobs' DEFAULTS to "off", and a knob set explicitly still wins —
// so a run list is MINIMAL=1, then MINIMAL=1 plus one stage turned back on:
//
//   stage                       knob (normal default -> minimal default)
//   head prediction             KL_OPENVR_PREDICT         1 -> 0
//   overscan                    KL_OPENVR_OVERSCAN        0.12 -> 0
//   symmetric frustum           KL_OPENVR_SYM_PROJ        1 -> 0
//   adopted "rendered with"     KL_OPENVR_SUBMIT_PROJ     1 -> 0  (0 = show the
//     tangents                                                    frustum OFFERED)
//   stage rescale               KL_OPENVR_STAGE_SCALE     1 -> 0  (0 = the stage
//                                                                 image is the
//                                                                 rendered rect, 1:1)
//   Touch raw-frame hands       KL_OPENVR_TOUCH_FRAME     1 -> 0
//   hand velocities             KL_OPENVR_HAND_VEL        1 -> 0  (0 = zeros)
//   frame timing (auto-fid.)    KL_OPENVR_FRAME_TIMING    1 -> 0
//   compositor timewarp         KL_REPROJECT_OFF          0 -> 1  (kl_reproject.c:
//                                                                 1 = the picture
//                                                                 is shown with no
//                                                                 correction toward
//                                                                 the current head)
//
// Alyx's auto-fidelity is the game's: fix the level with KL_GLIBC_ARGS
// (+vr_fidelity_level_auto 0 +vr_fidelity_level N). The state of every stage is
// printed once, so a device log says exactly which pipeline ran.
static int ovr_minimal(void) {
    static int m = -1;
    if (m < 0) m = kl_env_on("KL_OPENVR_MINIMAL", 0);
    return m;
}
static int ovr_stage(const char *knob, int normal) {
    return kl_env_on(knob, ovr_minimal() ? 0 : normal);
}
static void ovr_pipeline_report(void);

// ---- openvr.h types, the ones crossing the ABI (layouts measured: arm64) -------------
typedef struct { float m[3][4]; } HmdMatrix34_t;
typedef struct { float m[4][4]; } HmdMatrix44_t;
typedef struct {                       // 80 bytes
    HmdMatrix34_t mDeviceToAbsoluteTracking;
    float vVelocity[3], vAngularVelocity[3];
    int32_t eTrackingResult;           // TrackingResult_Running_OK = 200
    uint8_t bPoseIsValid, bDeviceIsConnected, pad[2];
} TrackedDevicePose_t;
typedef struct { const void *pVertexData; uint32_t unTriangleCount; } HiddenAreaMesh_t;
typedef struct { void *handle; int32_t eType, eColorSpace; } Texture_t;           // eType 2 = Vulkan
typedef struct {                       // 64 bytes
    uint64_t m_nImage;
    void *m_pDevice, *m_pPhysicalDevice, *m_pInstance, *m_pQueue;
    uint32_t m_nQueueFamilyIndex, m_nWidth, m_nHeight, m_nFormat, m_nSampleCount;
} VRVulkanTextureData_t;
typedef struct { float uMin, vMin, uMax, vMax; } VRTextureBounds_t;
typedef struct { uint64_t ulActionSet, ulRestrictedToDevice, ulSecondaryActionSet;
                 uint32_t unPadding; int32_t nPriority; } VRActiveActionSet_t;

enum { DEV_HMD = 0, DEV_LEFT = 1, DEV_RIGHT = 2, NDEV = 3 };

// ---- interface objects -------------------------------------------------------------------
typedef struct { const char *ver, *cls; const char *const *slots; } iface_desc;
#define KL_OVR_IFACE(ver, cls, ...) { ver, cls, (const char *const[]){ __VA_ARGS__, NULL } },
static const iface_desc g_desc[] = {
#include "kl_openvr_vtables.h"
// Private SteamVR interfaces, not in openvr.h: slot order reversed from
// libvr.so's call sites (see the implementations below).
KL_OVR_IFACE("IVRMailbox_001", "IVRMailbox (private)",
             "RegisterMailbox", "UndoRegisterMailbox", "SendMessage", "ReadMessage")
};
#undef KL_OVR_IFACE

typedef struct { void **vt; const char *ver; } vobj;
typedef struct { const char *ver, *method; void *fn; } impl;
static vobj *iface(const char *ver);

// ---- pose math -------------------------------------------------------------------------------
static void quat_to_m34(const float q[4], const float p[3], HmdMatrix34_t *o) {
    float x = q[0], y = q[1], z = q[2], w = q[3];
    o->m[0][0] = 1 - 2 * (y * y + z * z); o->m[0][1] = 2 * (x * y - z * w); o->m[0][2] = 2 * (x * z + y * w);
    o->m[1][0] = 2 * (x * y + z * w); o->m[1][1] = 1 - 2 * (x * x + z * z); o->m[1][2] = 2 * (y * z - x * w);
    o->m[2][0] = 2 * (x * z - y * w); o->m[2][1] = 2 * (y * z + x * w); o->m[2][2] = 1 - 2 * (x * x + y * y);
    o->m[0][3] = p[0]; o->m[1][3] = p[1]; o->m[2][3] = p[2];
}
static void quat_conj_mul(const float a[4], const float b[4], float o[4]) {   // conj(a) * b
    float ax = -a[0], ay = -a[1], az = -a[2], aw = a[3];
    o[0] = aw * b[0] + ax * b[3] + ay * b[2] - az * b[1];
    o[1] = aw * b[1] - ax * b[2] + ay * b[3] + az * b[0];
    o[2] = aw * b[2] + ax * b[1] - ay * b[0] + az * b[3];
    o[3] = aw * b[3] - ax * b[0] - ay * b[1] - az * b[2];
}
static void quat_rotate_inv(const float q[4], const float v[3], float o[3]) {  // conj(q) v q
    float c[4] = { -q[0], -q[1], -q[2], q[3] };
    float vx = v[0], vy = v[1], vz = v[2];
    float tx = 2 * (c[1] * vz - c[2] * vy), ty = 2 * (c[2] * vx - c[0] * vz), tz = 2 * (c[0] * vy - c[1] * vx);
    o[0] = vx + c[3] * tx + (c[1] * tz - c[2] * ty);
    o[1] = vy + c[3] * ty + (c[2] * tx - c[0] * tz);
    o[2] = vz + c[3] * tz + (c[0] * ty - c[1] * tx);
}

static void quat_mul(const float a[4], const float b[4], float o[4]) {        // a * b
    float x = a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1];
    float y = a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0];
    float z = a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3];
    float w = a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2];
    o[0] = x; o[1] = y; o[2] = z; o[3] = w;
}
static void quat_rotate(const float q[4], const float v[3], float o[3]) {      // q v conj(q)
    float c[4] = { -q[0], -q[1], -q[2], q[3] };
    quat_rotate_inv(c, v, o);
}
// The rotation of a 3x4 pose matrix as a quaternion (Shepperd: branch on the
// largest diagonal term so the square root never sees a near-zero argument).
static void m34_to_quat(const HmdMatrix34_t *m, float q[4]) {
    float m00 = m->m[0][0], m11 = m->m[1][1], m22 = m->m[2][2], tr = m00 + m11 + m22;
    if (tr > 0) {
        float s = sqrtf(tr + 1.0f) * 2;
        q[3] = 0.25f * s; q[0] = (m->m[2][1] - m->m[1][2]) / s;
        q[1] = (m->m[0][2] - m->m[2][0]) / s; q[2] = (m->m[1][0] - m->m[0][1]) / s;
    } else if (m00 > m11 && m00 > m22) {
        float s = sqrtf(1.0f + m00 - m11 - m22) * 2;
        q[3] = (m->m[2][1] - m->m[1][2]) / s; q[0] = 0.25f * s;
        q[1] = (m->m[0][1] + m->m[1][0]) / s; q[2] = (m->m[0][2] + m->m[2][0]) / s;
    } else if (m11 > m22) {
        float s = sqrtf(1.0f + m11 - m00 - m22) * 2;
        q[3] = (m->m[0][2] - m->m[2][0]) / s; q[0] = (m->m[0][1] + m->m[1][0]) / s;
        q[1] = 0.25f * s; q[2] = (m->m[1][2] + m->m[2][1]) / s;
    } else {
        float s = sqrtf(1.0f + m22 - m00 - m11) * 2;
        q[3] = (m->m[1][0] - m->m[0][1]) / s; q[0] = (m->m[0][2] + m->m[2][0]) / s;
        q[1] = (m->m[1][2] + m->m[2][1]) / s; q[2] = 0.25f * s;
    }
}
// The angle between two orientations, by atan2 of the relative quaternion's
// vector part against its scalar — NOT 2*acos(dot), whose float32 floor is
// 0.056 deg exactly where a consistency trace lives (see klxr_quat_deg).
static float quat_deg(const float a[4], const float b[4]) {
    float r[4];
    quat_conj_mul(b, a, r);                                   // conj(b) * a
    float v = sqrtf(r[0] * r[0] + r[1] * r[1] + r[2] * r[2]), w = fabsf(r[3]);
    return 2.0f * atan2f(v, w) * 57.29577951308232f;
}

static int g_origin = 1;                 // TrackingUniverseStanding

// ---- head prediction: the head as it will be when the frame is SEEN -------------
// kl_ovrp_frame_latch pins the head as the tracker last published it — the
// head of the moment WaitGetPoses returns. The picture drawn from it reaches
// the eye a whole frame of work later (WaitGetPoses -> Submit is 30-40 ms on
// device) plus the compositor's own refresh, and for all of that the
// compositor must reproject by however far the head moved: on a turn that is
// the black edge (see overscan) and, since the correction is a rotation about
// a fixed depth, the translation and parallax it cannot correct — the swim.
// Rendering from the head PREDICTED to the frame's display time leaves the
// compositor only the prediction's error to correct.
//
// The predicting is the frontend's (kl_ovrp_head_predict_delta: a timestamped
// queryDeviceAnchor on device, capped like OpenXR's at 50 ms), exactly as the
// OpenXR path asks it (klxr_frame_head_delta) — the same seam, not a second
// extrapolator. It answers a delta against the latched head, applied on the
// left: pose' = delta o pose, so eye offsets composed onto the head survive.
//
// Computed ONCE per frame, in WaitGetPoses, and every pose this bridge answers
// for the HMD until the next WaitGetPoses reads that one delta: the render and
// game poses, GetLastPoses, GetDeviceToAbsoluteTrackingPose, the frame-timing
// pose AND the pose the frame is declared with (g_frame_pose). The declared
// pose has to be the rendered one — a compositor correcting from a pose the
// game did not draw from corrects a difference that was never there, which is
// a swim of its own (KL_XR_POSE_TRACE's argument).
//
// A host run has no tracker (kl_ovrp_set_head_at is the visionOS
// compositor's): the delta comes back invalid and every pose is the latched
// head, which is exactly what this bridge answered before. KL_OPENVR_PREDICT=0
// is the A/B on device. The controllers are NOT moved by it: the frontend
// already predicts each PSVR2 Sense controller on its own measured motion
// (AccessoryTrackingProvider.predictAnchor, to the compositor's presentation
// time — KleptonControllers.sensePose), and the head's delta applied to a hand
// would be wrong, a hand does not hang off the head.
// target_s: the CLOCK_MONOTONIC instant the delta predicts to (0 when not
// valid) — dated into the frame record for KL_REPROJECT_DEPTH_MODE.
typedef struct { int valid; float q[4], p[3]; double ahead_ms, target_s; } head_delta;
static head_delta g_pred;                // this frame's; guarded by g_pred_mu
static pthread_mutex_t g_pred_mu = PTHREAD_MUTEX_INITIALIZER;
static head_delta pred_get(void) {
    pthread_mutex_lock(&g_pred_mu);
    head_delta d = g_pred;
    pthread_mutex_unlock(&g_pred_mu);
    return d;
}
static void pred_apply(const head_delta *d, float p[3], float q[4]) {
    if (!d || !d->valid) return;
    float rp[3], rq[4];
    quat_rotate(d->q, p, rp);
    quat_mul(d->q, q, rq);
    for (int i = 0; i < 3; i++) p[i] = rp[i] + d->p[i];
    memcpy(q, rq, sizeof rq);
}

// ---- the controller pose an OpenVR guest expects: an Oculus Touch's RAW pose ----
// We present the controllers as Quest 2 Touch (ControllerType oculus_touch,
// RenderModelName oculus_quest2_controller_*), and Alyx binds its hand to
// `/user/hand/*/pose/raw` (hlvr/cfg/bindings_touch.json). Under SteamVR's
// Oculus driver that is the Touch's TRACKED origin — the render model's own
// origin, the pose the model is drawn around and every title's per-controller
// hand offset is measured from. It is NOT the grip.
//
// What the frontend publishes (kl_ovrp_hand_motion) is neither: it is Apple's
// `.grip` for the PSVR2 Sense, turned into the hilt frame Beat Saber was tuned
// against (KleptonControllers.swift, KLSenseTune):
//
//     P = G · T(KL_SENSE_POS) · Rx(5.037 PSVR2 tilt + KL_SENSE_PITCH -37)
//
// The OpenXR path turns P back into an OpenXR grip with Rx(+37)
// (KL_XR_GRIP_PITCH, confirmed by eye against the Quest 2 model SteamVR itself
// draws through Steam Link), and the render model states the Touch's tracked
// origin in that grip's frame (tools/rendermodel_frames.py on
// oculus_quest2_controller_*.json): 9.6 cm forward along the grip's -Z, 3.4 cm
// down its -Y, 0.7 cm IN (toward the other hand), and pitched 20.6 degrees
// nose-down. So, for the right hand (X mirrored for the left)
//
//     raw = P · Rx(+37) · [T(HAND_POS) · R(HAND_ROT)] · T(-0.007, -0.0342, -0.0961) · Rx(-20.6)
//
// The X term is INWARD: the right model's `openxr_grip` sits at x = +0.007 in
// the tracked frame, so the tracked origin is at -0.007 in the grip's — the
// inverse Glovebox's klvr_core.cpp make_raw_from_grip() takes, which plays
// Alyx on these same Sense controllers. This bridge had it OUTWARD (as kl_ovrp's
// KLOVRP_TOUCH_TRACKED_X still does): 1.4 cm per hand, 2.8 cm too wide between
// hands held parallel. KL_OPENVR_TOUCH_X_OUT=1 restores the outward sign.
//
// Handing P over as the raw pose (what this bridge did) puts the Touch's origin
// at the grip — about 10 cm back down the handle, which on a held controller
// is mostly straight DOWN — and 16.4 degrees nose-down of where it should be,
// and every hand a title hangs off that origin inherits both.
//
// KL_OPENVR_HAND_POS="x,y,z" (metres) and KL_OPENVR_HAND_ROT="x,y,z" (degrees,
// X then Y then Z) tune it in the GRIP's frame — +X right, +Y up, -Z along the
// handle through the fist — so a rotation turns the hand about the palm rather
// than swinging it on an arc about the controller's ring. `_L`/`_R` per hand;
// the shared form mirrors X (and yaw/roll) for the left hand, as KL_SENSE_POS
// does. KL_OPENVR_TOUCH_FRAME=0 hands the published pose over unchanged (the
// old behaviour, the A/B). OVRPlugin and OpenXR guests never come through here.
#define KLOVR_HILT_UNDO_DEG   37.0f       // = -KLSenseTune.hiltPitch's default
#define KLOVR_TOUCH_X        (-0.007000f) // tracked origin in the RIGHT Touch's OpenXR grip (inward)
#define KLOVR_TOUCH_Y        (-0.034157f)
#define KLOVR_TOUCH_Z        (-0.096073f)
#define KLOVR_TOUCH_PITCH_DEG (-20.60f)

static void quat_euler_xyz(const float deg[3], float q[4]) {  // Rx * Ry * Rz
    float h[3], s[3], c[3];
    for (int i = 0; i < 3; i++) { h[i] = deg[i] * 0.5f * 3.14159265358979f / 180.0f; s[i] = sinf(h[i]); c[i] = cosf(h[i]); }
    float qx[4] = { s[0], 0, 0, c[0] }, qy[4] = { 0, s[1], 0, c[1] }, qz[4] = { 0, 0, s[2], c[2] }, t[4];
    quat_mul(qx, qy, t);
    quat_mul(t, qz, q);
}
// "x,y,z" from <base>_L / <base>_R, else <base> (X term mirrored for the left
// hand when `mirror_x`, the Y/Z terms too for a rotation via `mirror_yz`).
static int hand_triple(const char *base, int hand, int mirror_yz, float v[3]) {
    char k[64];
    snprintf(k, sizeof k, "%s_%c", base, hand ? 'R' : 'L');
    const char *e = getenv(k);
    int shared = 0;
    if (!e || !*e) { e = getenv(base); shared = 1; }
    if (!e || !*e) return 0;
    if (sscanf(e, "%f,%f,%f", &v[0], &v[1], &v[2]) != 3) {
        fprintf(stderr, "  [openvr] %s=%s is not three comma-separated numbers — ignored\n",
                shared ? base : k, e);
        return 0;
    }
    if (shared && hand == 0) {
        if (mirror_yz) { v[1] = -v[1]; v[2] = -v[2]; } else v[0] = -v[0];
    }
    fprintf(stderr, "  [openvr] %s: hand %d %.3f %.3f %.3f\n", shared ? base : k, hand,
            (double)v[0], (double)v[1], (double)v[2]);
    return 1;
}

typedef struct { int on; float pre[4], off[3], post[4]; } touch_frame;
static const touch_frame *touch_frame_for(int hand) {
    static touch_frame tf[2];
    static int init;
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mu);
    if (!init) {
        int on = ovr_stage("KL_OPENVR_TOUCH_FRAME", 1);
        float xs = kl_env_on("KL_OPENVR_TOUCH_X_OUT", 0) ? -1.0f : 1.0f;
        for (int h = 0; h < 2; h++) {
            touch_frame *t = &tf[h];
            t->on = on;
            float mx = h == 0 ? -1.0f : 1.0f;
            // pre = Rx(+37) * R(HAND_ROT); the HAND_POS offset is applied in
            // the grip frame after Rx(+37) and before HAND_ROT, so a rotation
            // turns about the (moved) palm.
            float undo[3] = { KLOVR_HILT_UNDO_DEG, 0, 0 }, qu[4], rot[3] = { 0, 0, 0 }, qr[4];
            quat_euler_xyz(undo, qu);
            hand_triple("KL_OPENVR_HAND_ROT", h, 1, rot);
            quat_euler_xyz(rot, qr);
            quat_mul(qu, qr, t->pre);
            float pos[3] = { 0, 0, 0 }, tr[3] = { xs * mx * KLOVR_TOUCH_X, KLOVR_TOUCH_Y, KLOVR_TOUCH_Z };
            hand_triple("KL_OPENVR_HAND_POS", h, 0, pos);
            // offset from P's origin, in P's frame:
            //   Rx(37)·pos + Rx(37)·R(rot)·tracked
            float a[3], b[3];
            quat_rotate(qu, pos, a);
            quat_rotate(t->pre, tr, b);
            for (int i = 0; i < 3; i++) t->off[i] = a[i] + b[i];
            float pitch[3] = { KLOVR_TOUCH_PITCH_DEG, 0, 0 }, qp[4];
            quat_euler_xyz(pitch, qp);
            quat_mul(t->pre, qp, t->post);           // P-relative orientation of raw
        }
        fprintf(stderr, "  [openvr] controller pose: %s (KL_OPENVR_TOUCH_FRAME), tracked origin %s "
                        "(KL_OPENVR_TOUCH_X_OUT); right hand raw = P + "
                        "(%.4f, %.4f, %.4f) m in P's frame, turned (%.4f, %.4f, %.4f, %.4f)\n",
                on ? "Oculus Touch raw (tracked origin) from the published hilt" : "published pose unchanged",
                xs > 0 ? "0.7 cm inward (render model, Glovebox)" : "0.7 cm OUTWARD (old sign)",
                (double)tf[1].off[0], (double)tf[1].off[1], (double)tf[1].off[2],
                (double)tf[1].post[0], (double)tf[1].post[1], (double)tf[1].post[2], (double)tf[1].post[3]);
        init = 1;
    }
    pthread_mutex_unlock(&mu);
    return &tf[hand ? 1 : 0];
}

// KL_OPENVR_FAKE_HAND="x,y,z[,pitch,yaw,roll]" — diagnostic, host runs: place
// each hand's APPLE GRIP (G, where the real hand holds the Sense) at a fixed
// head-relative spot and orientation (right hand as given, left mirrored in
// X), and build the published pose from it with the frontend's default Sense
// tune — so a Mac run shows where the guest draws a hand relative to a known
// grip, the same chain the device runs.
static int fake_hand(int hand, float p[3], float q[4]) {
    static int n = -1;
    static float v[6];
    if (n < 0) {
        const char *e = getenv("KL_OPENVR_FAKE_HAND");
        n = e ? sscanf(e, "%f,%f,%f,%f,%f,%f", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) : 0;
        if (n < 3) n = 0;
        if (n) fprintf(stderr, "  [openvr] KL_OPENVR_FAKE_HAND: grip at head + (%.3f, %.3f, %.3f), "
                               "euler %.1f %.1f %.1f\n", (double)v[0], (double)v[1], (double)v[2],
                       (double)v[3], (double)v[4], (double)v[5]);
    }
    if (!n) return 0;
    float hp[3], hq[4];
    kl_ovrp_get_guest_head_pose(&hp[0], &hp[1], &hp[2], &hq[0], &hq[1], &hq[2], &hq[3]);
    float mx = hand == 0 ? -1.0f : 1.0f;
    float off[3] = { mx * v[0], v[1], v[2] }, w[3];
    float e[3] = { v[3], mx * v[4], mx * v[5] }, gq[4], g[4];
    quat_rotate(hq, off, w);
    quat_euler_xyz(e, gq);
    quat_mul(hq, gq, g);
    // ...and KLSenseTune's defaults: T(-0.005 mirrored, 0.02, -0.02) in G's
    // frame, then Rx(5.037 - 37).
    float s[3] = { mx * -0.005f, 0.02f, -0.02f }, sw[3], tilt[3] = { 5.037f - 37.0f, 0, 0 }, tq[4];
    quat_rotate(g, s, sw);
    quat_euler_xyz(tilt, tq);
    quat_mul(g, tq, q);
    for (int i = 0; i < 3; i++) p[i] = hp[i] + w[i] + sw[i];
    return 1;
}

static void openvr_hand_pose(int hand, float p[3], float q[4], float v[3], float a[3]) {
    const touch_frame *t = touch_frame_for(hand);
    if (!t->on) return;
    float d[3], r[4];
    quat_rotate(q, t->off, d);
    quat_mul(q, t->post, r);
    for (int i = 0; i < 3; i++) p[i] += d[i];
    memcpy(q, r, sizeof r);
    // A point carried rigidly at offset d moves at v + w x d (velocity and
    // angular velocity are both in tracking space).
    v[0] += a[1] * d[2] - a[2] * d[1];
    v[1] += a[2] * d[0] - a[0] * d[2];
    v[2] += a[0] * d[1] - a[1] * d[0];
}

// Device pose in the guest's tracking universe. Seated is the standing frame
// lowered by the eye height kl_ovrp's floor origin adds. The HMD is the
// frame's predicted head (above).
static void device_pose(int dev, TrackedDevicePose_t *o) {
    memset(o, 0, sizeof *o);
    float p[3], q[4], v[3] = {0}, a[3] = {0};
    int known = 1;
    if (dev == DEV_HMD) {
        kl_ovrp_get_guest_head_pose(&p[0], &p[1], &p[2], &q[0], &q[1], &q[2], &q[3]);
        kl_ovrp_head_motion(v, a);
        head_delta d = pred_get();
        pred_apply(&d, p, q);
    } else if (dev == DEV_LEFT || dev == DEV_RIGHT) {
        int hand = dev == DEV_LEFT ? 0 : 1;
        known = kl_ovrp_hand_motion(hand, p, q, v, a);
        known = 1;                        // the parked default still tracks the head
        fake_hand(hand, p, q);
        openvr_hand_pose(hand, p, q, v, a);
        // KL_OPENVR_HAND_VEL=0: report the controller as moving at zero, so a
        // guest that extrapolates the pose by its velocity (or reads the ω×r
        // term above, which amplifies a noisy ω by the lever arm) cannot add
        // motion of its own. The A/B for "the hands tremble".
        static int vel = -1;
        if (vel < 0) vel = ovr_stage("KL_OPENVR_HAND_VEL", 1);
        if (!vel) { memset(v, 0, sizeof v); memset(a, 0, sizeof a); }
    } else {
        return;
    }
    if (g_origin == 0) p[1] -= kl_ovrp_eye_height();
    quat_to_m34(q, p, &o->mDeviceToAbsoluteTracking);
    memcpy(o->vVelocity, v, sizeof v);
    memcpy(o->vAngularVelocity, a, sizeof a);
    o->eTrackingResult = 200;
    o->bPoseIsValid = (uint8_t)known;
    o->bDeviceIsConnected = 1;
}

// ---- unimplemented slots ------------------------------------------------------------------------
static long ovr_unimpl(const char *name) {
    static struct { const char *n; unsigned c; } seen[512];
    static unsigned ns;
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mu);
    unsigned i = 0;
    for (; i < ns; i++) if (seen[i].n == name) break;
    if (i == ns && ns < 512) { seen[ns].n = name; seen[ns].c = 0; ns++; }
    unsigned c = i < 512 ? seen[i].c++ : 99;
    pthread_mutex_unlock(&mu);
    if (c < 3) fprintf(stderr, "  [openvr] %s: not implemented -> 0\n", name);
    return 0;
}

// ---- IVRSystem ------------------------------------------------------------------------------------
// ---- overscan: render past the display's edge ----------------------------------
// Alyx runs at 25-30 fps on device against a 90-100 Hz display, so the
// compositor shows each picture for three or four refreshes, reprojected every
// time to where the head is NOW. A picture that covers exactly the display's
// frustum has nothing past its edge, so on any head turn the leading edge of
// the view is outside the picture: black (clamp-to-zero in the compositor's
// sampler; magenta before the hidden-area fix). The margin has to be RENDERED.
//
// KL_OPENVR_OVERSCAN=<f> widens every eye's frustum by f per side — each of the
// four tangents x (1 + f) — and says so everywhere the frustum is stated:
// GetProjectionRaw, GetProjectionMatrix (built from it) and the tangents the
// frame is declared with (g_frame_tan, from the same eye_tangents()). Submit
// then reads back the projection the game actually rendered with and adopts it
// (see "rendered with tangents" below), so the declared frustum is the wider
// one in fact and not only in intent. Nothing else derives from the frustum:
// GetEyeToHeadTransform is a pose, the hidden-area mesh hides nothing.
//
// The compositor handles a declared frustum WIDER than the display without
// being told: kl_reproject places the picture as a quad sized by its declared
// tangents, at the declared pose, and draws it through the DISPLAY's own
// projection from the current head (KleptonCompositor: drawable.
// computeProjection). The margin falls outside the display's clip volume and is
// clipped while the head is still, and swings in when it turns; nothing is
// scaled to fit. That is the same mechanism that already carries Alyx's own
// horizontally widened render (it symmetrises the canted Vision Pro frustum:
// l=r=1.73 for an offered l=1.73/r=1.00).
//
// Default 0.12 for `alyx` (about 3 degrees of extra field on each side at the
// Vision Pro's tangents: 60 -> 62.7 deg out, 45 -> 48.2 up, 50 -> 53.2 down),
// 0 for anything else. Clamped to [0, 0.5].
extern const char *kl_driver_target_name(void);
static float overscan(void) {
    static float f = -1.0f;
    if (f < 0.0f) {
        const char *tg = kl_driver_target_name();
        float def = tg && !strcmp(tg, "alyx") && !ovr_minimal() ? 0.12f : 0.0f;
        float v = kl_env_float("KL_OPENVR_OVERSCAN", def);
        if (!(v > 0.0f)) v = 0.0f;
        if (v > 0.5f) v = 0.5f;
        f = v;
        fprintf(stderr, "  [openvr] overscan %.3f: every eye frustum %s (KL_OPENVR_OVERSCAN)\n",
                (double)f, f > 0 ? "widened by that much per side — GetProjectionRaw/Matrix and the "
                                   "frame declared to the compositor" : "exactly the display's");
    }
    return f;
}
// ...and the render target with it, so the pixel density at the centre of the
// view is unchanged: the same tangent span per pixel, more pixels. That costs
// GPU — (1 + f)^2, about 25% more pixels at 0.12 — and Alyx's auto-fidelity
// (frame timing, below) answers a heavier frame by dropping a level, which
// lands near the old pixel count anyway. OFF by default since the first device
// runs (GPU-bound, the extra pixels cost frame rate): the size is kept and the
// same pixels spread over the wider field (density -1/(1+f)).
// KL_OPENVR_OVERSCAN_RT=1 turns the scaling back on.
static float overscan_rt(void) {
    static float s = -1.0f;
    if (s < 0.0f) s = overscan() > 0 && kl_env_on("KL_OPENVR_OVERSCAN_RT", 0) ? 1.0f + overscan() : 1.0f;
    return s;
}

// KL_OPENVR_RT_SCALE scales the recommended render target size, and with it
// every fidelity level Alyx derives from it (its levels are 0.78x..1.5x of this
// size) and our stage images. 1 by default; 0.7 halves the pixels. The
// overscan's own factor multiplies it.
static void eye_size(uint32_t *w, uint32_t *h) {
    int ew = 0, eh = 0;
    kl_ovrp_eye_texture_size(&ew, &eh);
    if (ew <= 0 || eh <= 0) { ew = kl_env_int("KL_OPENVR_EYE_W", 1832); eh = kl_env_int("KL_OPENVR_EYE_H", 1920); }
    float sc = kl_env_float("KL_OPENVR_RT_SCALE", 1.0f);
    if (!(sc > 0.2f && sc < 2.0f)) sc = 1.0f;
    sc *= overscan_rt();
    if (sc != 1.0f) {
        ew = (int)(ew * sc + 0.5f) & ~7; eh = (int)(eh * sc + 0.5f) & ~7;
    }
    static int said;
    if (!said++ && overscan() > 0)
        fprintf(stderr, "  [openvr] recommended render target %dx%d per eye (%s; KL_OPENVR_OVERSCAN_RT=%d)\n",
                ew, eh, overscan_rt() > 1.0f ? "scaled with the overscan: same density, more pixels"
                                             : "NOT scaled with the overscan: same pixels, lower density",
                overscan_rt() > 1.0f);
    *w = (uint32_t)ew; *h = (uint32_t)eh;
}
static void sys_rt_size(void *s, uint32_t *w, uint32_t *h) { (void)s; eye_size(w, h); }
// The frustum the game is told to render — the display's, widened by the
// overscan. Every path that states a frustum reads it here.
// ---- the magenta band: offer each eye a horizontally SYMMETRIC frustum ----------
// Alyx renders both eyes into one two-layer image with a symmetric projection
// whatever it is offered (offered l=1.94/r=1.12 on the canted Vision Pro eye
// with the 0.12 overscan, rendered l=r=1.94: "rendered with tangents" in the
// log). With an asymmetric offer AND the overscan, it then leaves part of the
// RIGHT eye's temporal side unrendered — on the Mac with KL_OVRP_EYE_TAN=vision
// everything past tangent ~1.25 of a display that reaches 1.94 — and that is
// the render target's clear colour, MAGENTA, inside the frame the compositor
// shows. It is plainest on a loading screen: Alyx calls SuspendRendering(1)
// and stops submitting, so the compositor reprojects that one stale frame for
// as long as the load takes and every head turn swings the band, then the
// black past the frame's edge, into view. Without the overscan the same offer
// renders whole (the band arrived with KL_OPENVR_OVERSCAN), and offering the
// symmetric frustum it renders anyway renders whole WITH it — same image size,
// same pixels Alyx was already allocating; the compositor places the picture
// by the tangents it was rendered with (Submit adopts them), so nothing else
// changes. KL_OPENVR_SYM_PROJ=0 offers the display's own asymmetric frustum.
static void eye_tangents(int eye, float t[4]) {      // left, right, top, bottom; positive
    float px, py, pz, qx, qy, qz, qw;
    kl_ovrp_eye_view(eye, &px, &py, &pz, &qx, &qy, &qz, &qw, t);
    if (t[0] <= 0 || t[1] <= 0 || t[2] <= 0 || t[3] <= 0) t[0] = t[1] = t[2] = t[3] = 1.0f;
    float k = 1.0f + overscan();
    for (int i = 0; i < 4; i++) t[i] *= k;
    // Symmetric horizontally: see "the magenta band" below.
    static int sym = -1;
    if (sym < 0) sym = ovr_stage("KL_OPENVR_SYM_PROJ", 1);
    if (sym) { float m = fmaxf(t[0], t[1]); t[0] = t[1] = m; }
}
static void sys_proj_raw(void *s, int eye, float *l, float *r, float *t, float *b) {
    (void)s;
    float tan[4];
    eye_tangents(eye, tan);
    // OpenVR's raw projection: left and top negative. The game's matrix puts
    // `b` at the top of its image (Alyx renders up = b), so the display's UP
    // tangent goes in b and DOWN in -t. The other way round mirrored the
    // display's asymmetric cone (up 1.0, down 1.19) and every picture sat
    // ~11 deg low, head-locked: the world tilted while turning and receded
    // looking up (2026-10-08; a symmetric KL_OVRP_EYE_TAN made it vanish).
    *l = -tan[0]; *r = tan[1]; *t = -tan[3]; *b = tan[2];
}
static HmdMatrix44_t sys_proj(void *s, int eye, float zn, float zf) {
    float l, r, t, b;
    sys_proj_raw(s, eye, &l, &r, &t, &b);
    HmdMatrix44_t m;
    memset(&m, 0, sizeof m);
    float idx = 1.0f / (r - l), idy = 1.0f / (b - t), sx = r + l, sy = b + t;
    m.m[0][0] = 2 * idx; m.m[0][2] = sx * idx;
    m.m[1][1] = 2 * idy; m.m[1][2] = sy * idy;
    m.m[2][2] = -zf / (zf - zn); m.m[2][3] = -zf * zn / (zf - zn);   // D3D-style, as openvr computes it
    m.m[3][2] = -1.0f;
    return m;
}
static int sys_distortion(void *s, int eye, float u, float v, float *out) {
    (void)s; (void)eye;
    for (int i = 0; i < 3; i++) { out[i * 2] = u; out[i * 2 + 1] = v; }
    return 1;
}
// GetEyeToHeadTransform: the eye in head space, read as the constant it is
// (kl_ovrp_eye_local) — the display's offset from the eye midpoint the head
// pose is published at, and the cant if KL_OVRP_EYE_CANT gives it to the guest.
// It used to be the DIFFERENCE of two world-space reads, the eye view and the
// head: before the first WaitGetPoses latch each of those is a read of the LIVE
// head, published from another thread at the display rate, so a head moving
// while the game asked put that motion into a transform the game reads once and
// keeps — a per-eye offset and turn baked into every frame after. Logged with
// the numbers so a device log says what the game was told.
static HmdMatrix34_t sys_eye_to_head(void *s, int eye) {
    (void)s;
    float lp[3], lq[4];
    kl_ovrp_eye_local(eye ? 1 : 0, lp, lq);
    if (fabsf(lp[0]) < 1e-4f && fabsf(lp[1]) < 1e-4f && fabsf(lp[2]) < 1e-4f)   // no frontend yet
        lp[0] = eye ? 0.032f : -0.032f;
    static int said;
    if (said < 8) {
        said++;
        fprintf(stderr, "  [openvr] GetEyeToHeadTransform(eye %d) -> (%.4f, %.4f, %.4f) m, turned "
                        "(%.4f, %.4f, %.4f, %.4f)\n", eye, (double)lp[0], (double)lp[1], (double)lp[2],
                (double)lq[0], (double)lq[1], (double)lq[2], (double)lq[3]);
    }
    HmdMatrix34_t m;
    quat_to_m34(lq, lp, &m);
    return m;
}
static int sys_vsync(void *s, float *sec, uint64_t *frame) {
    (void)s;
    static uint64_t n;
    if (sec) *sec = 0.0f;
    if (frame) *frame = ++n;
    return 1;
}
static void sys_output_device(void *s, uint64_t *dev, int type, void *instance) {
    (void)s; (void)type;
    if (dev) *dev = (uint64_t)(uintptr_t)kl_vulkan_xr_physical_device(instance);
}
static int sys_false(void *s) { (void)s; return 0; }
static int sys_true(void *s) { (void)s; return 1; }
// GetDeviceToAbsoluteTrackingPose(origin, fPredictedSecondsToPhotonsFromNow, ...).
// OpenVR defines `predict` as an interval from now to the photons the caller
// cares about. It is answered here with the FRAME's head — the one predicted
// once in WaitGetPoses — whatever interval is named, and deliberately:
//   * a caller works its interval out of GetTimeSinceLastVsync and
//     Prop_SecondsFromVsyncToPhotons, and this runtime has no vsync to time
//     against (GetTimeSinceLastVsync answers 0), so the number it names is not
//     a measurement of anything here;
//   * a second, independently predicted head inside one frame is the "draws
//     from one head, declares another" fault if the game renders anything
//     from it (KL_XR_POSE_TRACE's argument), and the declared pose is the
//     WaitGetPoses one.
// Before the first WaitGetPoses (no delta yet) it is the latched head, as
// before. The interval asked is logged once, and KL_OPENVR_POSE_TRACE counts
// the frames this is asked on and differences its head against the declared one.
enum { PT_WAIT, PT_ABS, PT_LAST, PT_SUBMIT, PT_N };        // KL_OPENVR_POSE_TRACE sources
static void pose_trace_note(int src, const TrackedDevicePose_t *hmd);
static void sys_poses(void *s, int origin, float predict, TrackedDevicePose_t *out, uint32_t n) {
    (void)s; (void)origin;
    static int said;
    if (!said++)
        fprintf(stderr, "  [openvr] GetDeviceToAbsoluteTrackingPose(predict %.1f ms) — answered with "
                        "the frame's head (predicted once at WaitGetPoses), not a second prediction\n",
                (double)predict * 1000.0);
    for (uint32_t i = 0; i < n; i++) device_pose((int)i, &out[i]);
    if (n > 0) pose_trace_note(PT_ABS, &out[0]);
}
static HmdMatrix34_t sys_seated_to_standing(void *s) {
    (void)s;
    float q[4] = { 0, 0, 0, 1 }, p[3] = { 0, kl_ovrp_eye_height(), 0 };
    HmdMatrix34_t m;
    quat_to_m34(q, p, &m);
    return m;
}
static uint32_t sys_sorted(void *s, int cls, uint32_t *out, uint32_t cap, uint32_t rel) {
    (void)s; (void)rel;
    uint32_t n = 0;
    if (cls == 1) { if (cap > n && out) out[n] = DEV_HMD; n++; }
    if (cls == 2) {
        if (cap > n && out) out[n] = DEV_LEFT; n++;
        if (cap > n && out) out[n] = DEV_RIGHT; n++;
    }
    return n;
}
static int sys_activity(void *s, uint32_t i) { (void)s; (void)i; return 1; }       // UserInteraction
static uint32_t sys_index_for_role(void *s, int role) {
    (void)s; return role == 1 ? DEV_LEFT : role == 2 ? DEV_RIGHT : 0xFFFFFFFFu;
}
static int sys_role_for_index(void *s, uint32_t i) { (void)s; return i == DEV_LEFT ? 1 : i == DEV_RIGHT ? 2 : 0; }
static int sys_class(void *s, uint32_t i) { (void)s; return i == DEV_HMD ? 1 : i < NDEV ? 2 : 0; }
static int sys_connected(void *s, uint32_t i) { (void)s; return i < NDEV; }

// Tracked-device properties: the few a game asks to decide what it is talking
// to. Unknown ones answer TrackedProp_UnknownProperty (4), never a guess.
#define PERR_OK 0
#define PERR_WRONGTYPE 1
#define PERR_TOOSMALL 3
#define PERR_UNKNOWN 4
// KL_OPENVR_INPUT_TRACE: each distinct (call, device, property) asked, once.
static void prop_note(const char *call, uint32_t dev, int prop, int answered) {
    static int on = -1;
    if (on < 0) on = kl_env_on("KL_OPENVR_INPUT_TRACE", 0);
    if (!on) return;
    static struct { const char *c; uint32_t d; int p; } seen[256];
    static int n;
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mu);
    for (int i = 0; i < n; i++) if (seen[i].c == call && seen[i].d == dev && seen[i].p == prop) { pthread_mutex_unlock(&mu); return; }
    if (n < 256) { seen[n].c = call; seen[n].d = dev; seen[n].p = prop; n++; }
    pthread_mutex_unlock(&mu);
    fprintf(stderr, "  [openvr] %s(device %u, prop %d) -> %s\n", call, dev, prop, answered ? "answered" : "UNKNOWN");
}
static const char *prop_string(uint32_t dev, int prop) {
    int left = dev == DEV_LEFT;
    switch (prop) {
    case 1000: return "oculus";                                     // TrackingSystemName
    case 1001: return dev == DEV_HMD ? "Klepton Vision Pro" :
                      left ? "Oculus Quest2 (Left Controller)" : "Oculus Quest2 (Right Controller)";
    case 1002: return dev == DEV_HMD ? "KLEPTON-HMD" : left ? "KLEPTON-L" : "KLEPTON-R";
    case 1003: return dev == DEV_HMD ? "generic_hmd" :
                      left ? "oculus_quest2_controller_left" : "oculus_quest2_controller_right";
    case 1005: return dev == DEV_HMD ? "Apple" : "Oculus";           // ManufacturerName
    case 1037: return dev == DEV_HMD ? "" : "{oculus}/input/touch_profile.json";
    case 7000: return dev == DEV_HMD ? "" : "oculus_touch";           // ControllerType
    default:   return NULL;
    }
}
static uint32_t sys_prop_string(void *s, uint32_t dev, int prop, char *buf, uint32_t n, int *err) {
    (void)s;
    const char *v = dev < NDEV ? prop_string(dev, prop) : NULL;
    prop_note("GetStringTrackedDeviceProperty", dev, prop, v != NULL);
    if (!v) { if (err) *err = PERR_UNKNOWN; if (buf && n) buf[0] = 0; return 0; }
    uint32_t need = (uint32_t)strlen(v) + 1;
    if (buf && n >= need) { memcpy(buf, v, need); if (err) *err = PERR_OK; }
    else if (err) *err = buf ? PERR_TOOSMALL : PERR_OK;
    return need;
}
static float sys_prop_float(void *s, uint32_t dev, int prop, int *err) {
    (void)s; (void)dev;
    float v = 0; int ok = 1;
    switch (prop) {
    case 2001: v = 0.011f; break;                                      // SecondsFromVsyncToPhotons
    case 2002: v = kl_ovrp_display_frequency() > 0 ? kl_ovrp_display_frequency() : 90.0f; break;
    case 2003: v = 0.064f; break;                                      // UserIpdMeters
    case 2014: v = 1.0f; break;                                        // DeviceBatteryPercentage
    default: ok = 0;
    }
    prop_note("GetFloatTrackedDeviceProperty", dev, prop, ok);
    if (err) *err = ok ? PERR_OK : PERR_UNKNOWN;
    return v;
}
static int32_t sys_prop_int(void *s, uint32_t dev, int prop, int *err) {
    (void)s;
    int32_t v = 0; int ok = 1;
    switch (prop) {
    case 1029: v = dev == DEV_HMD ? 1 : 2; break;                      // DeviceClass
    case 3007: v = dev == DEV_LEFT ? 1 : dev == DEV_RIGHT ? 2 : 0; break;   // ControllerRoleHint
    default: ok = 0;
    }
    prop_note("GetInt32TrackedDeviceProperty", dev, prop, ok);
    if (err) *err = ok ? PERR_OK : PERR_UNKNOWN;
    return v;
}
static int sys_prop_bool(void *s, uint32_t dev, int prop, int *err) {
    (void)s; prop_note("GetBoolTrackedDeviceProperty", dev, prop, 0);
    if (err) *err = PERR_UNKNOWN;
    return 0;
}
static uint64_t sys_prop_u64(void *s, uint32_t dev, int prop, int *err) {
    (void)s; prop_note("GetUint64TrackedDeviceProperty", dev, prop, 0);
    if (err) *err = PERR_UNKNOWN;
    return 0;
}
static HmdMatrix34_t sys_prop_m34(void *s, uint32_t dev, int prop, int *err) {
    (void)s; prop_note("GetMatrix34TrackedDeviceProperty", dev, prop, 0);
    HmdMatrix34_t m;
    memset(&m, 0, sizeof m);
    if (err) *err = PERR_UNKNOWN;
    return m;
}
static uint32_t sys_prop_array(void *s, uint32_t dev, int prop, uint32_t tag, void *buf, uint32_t n, int *err) {
    (void)s; (void)tag; (void)buf; (void)n; prop_note("GetArrayTrackedDeviceProperty", dev, prop, 0);
    if (err) *err = PERR_UNKNOWN;
    return 0;
}
static const char *sys_prop_err_name(void *s, int e) { (void)s; return e ? "TrackedProp_UnknownProperty" : "TrackedProp_Success"; }
// Events: what a freshly started SteamVR session tells a scene app once —
// every device activated, the user interacting with the headset (worn), and
// nobody else holding input focus or the dashboard. VREvent_t is packed 4 on
// Linux: type, device, age, then the data union at +12.
static const struct { uint32_t type, dev; } k_start_events[] = {
    { 100, DEV_HMD }, { 100, DEV_LEFT }, { 100, DEV_RIGHT },        // TrackedDeviceActivated
    { 103, DEV_HMD },                                                // TrackedDeviceUserInteractionStarted
    { 401, 0xFFFFFFFFu },                                            // InputFocusReleased
    { 503, 0xFFFFFFFFu },                                            // DashboardDeactivated
};
static _Atomic int g_ev_next;
static int sys_poll(void *s, void *ev, uint32_t n) {
    (void)s;
    if (!ev || n < 12) return 0;
    int i = atomic_fetch_add(&g_ev_next, 1);
    if (i >= (int)(sizeof k_start_events / sizeof *k_start_events)) {
        atomic_store(&g_ev_next, 64);
        return 0;
    }
    memset(ev, 0, n);
    uint32_t *e = ev;
    e[0] = k_start_events[i].type; e[1] = k_start_events[i].dev;
    TRACE("PollNextEvent -> %u (device %d)\n", e[0], (int)e[1]);
    return 1;
}
static int sys_poll_pose(void *s, int o, void *ev, uint32_t n, void *p) { (void)o; (void)p; return sys_poll(s, ev, n); }
// The hidden-area mesh: what of the eye texture no lens shows. There is no such
// area on a Vision Pro at our frustum, but answering an EMPTY mesh is not "no
// mask" to Source 2 — with no mesh it builds a mask of its own, and builds the
// same one for both eyes: left eye's (on the canted Vision Pro frustum, the
// right ~11% of the texture plus a bottom-right block), so the RIGHT eye's
// temporal edge was masked off and left at the render target's clear colour —
// the magenta/pink stripe. One zero-area triangle is a mesh that hides nothing.
// KL_OPENVR_HIDDEN_MESH=0 restores the empty answer.
static HiddenAreaMesh_t sys_hidden(void *s, int eye, int type) {
    (void)s; (void)eye;
    static const float degenerate[6] = { 0, 0, 0, 0, 0, 0 };     // HmdVector2_t x3
    if (!kl_env_on("KL_OPENVR_HIDDEN_MESH", 1)) return (HiddenAreaMesh_t){ NULL, 0 };
    static int said;
    if (said < 6) { said++; TRACE("GetHiddenAreaMesh(eye %d, type %d) -> one degenerate triangle\n", eye, type); }
    return (HiddenAreaMesh_t){ degenerate, 1 };
}
static const char *sys_runtime_version(void *s) { (void)s; return "2.5.1"; }
static int sys_set_sdk(void *s, uint32_t maj, uint32_t min, uint32_t build) {
    (void)s;
    fprintf(stderr, "  [openvr] guest built against OpenVR %u.%u.%u\n", maj, min, build);
    return 0;                                                          // VRInitError_None
}

// ---- IVRCompositor --------------------------------------------------------------------------------
static TrackedDevicePose_t g_last[NDEV];
static float g_frame_pose[7], g_frame_tan[8];
static unsigned long long g_frames;

static void co_set_space(void *s, int o) { (void)s; g_origin = o; }
static int co_get_space(void *s) { (void)s; return g_origin; }
// ---- frame timing, for the game's auto-fidelity ---------------------------------
// Alyx scales its render resolution (fidelity levels 0..8, 0.78x..1.5x of the
// recommended size) from IVRCompositor::GetFrameTiming: frames that take longer
// than a vsync drop a level. Answering "no timing" (false) left it at its
// default level whatever the frame rate — 13 MP per eye at ~20 fps on device,
// with the compositor reprojecting 70-80 ms old frames. So the frame intervals
// are measured here: WaitGetPoses to WaitGetPoses (the client interval) and
// WaitGetPoses to the second Submit returning (Submit waits for the eye copy,
// which is queued behind the game's own GPU work on its queue, so that span is
// the frame's CPU+GPU time). ON by default; KL_OPENVR_FRAME_TIMING=0 answers
// "no timing" again. Measured on device (GPU-bound): 25-31 fps against ~20
// without, at no visible cost. On the Mac (CPU-bound) it is the other way —
// 51 fps against 62 — because the game reads the span as GPU time and its
// auto-fidelity oscillates between levels there; set it to 0 for host work.
typedef struct { uint32_t index; double t_wait, t_submit, interval_ms, work_ms; } frame_time;
#define FT_RING 32
static frame_time g_ft[FT_RING];
static uint32_t g_ft_index;
static double now_s(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}
static void ft_wait(void) {
    double t = now_s();
    frame_time *prev = &g_ft[g_ft_index % FT_RING];
    frame_time *f = &g_ft[(g_ft_index + 1) % FT_RING];
    memset(f, 0, sizeof *f);
    f->index = g_ft_index + 1;
    f->t_wait = t;
    f->interval_ms = prev->t_wait > 0 ? (t - prev->t_wait) * 1000.0 : 0.0;
    __atomic_store_n(&g_ft_index, f->index, __ATOMIC_RELEASE);
}
// The frame's work, smoothed: what the head prediction reads to say how far
// ahead this frame will be seen. Written by the submitting thread, read at the
// next WaitGetPoses; a torn double is not possible on arm64.
static double g_work_ema_ms;
// The prediction's own numbers, for the 5-second line: how far ahead it asked
// and how far it moved the head, so an A/B on device is a number in the log.
static double g_pred_win_ahead, g_pred_win_deg, g_pred_win_worst;
static unsigned g_pred_win_n, g_pred_win_valid;
static void ft_submitted(void) {
    frame_time *f = &g_ft[g_ft_index % FT_RING];
    f->t_submit = now_s();
    f->work_ms = (f->t_submit - f->t_wait) * 1000.0;
    if (f->work_ms > 0 && f->work_ms < 1000.0)
        g_work_ema_ms = g_work_ema_ms > 0 ? g_work_ema_ms * 0.9 + f->work_ms * 0.1 : f->work_ms;
    static double win_start; static unsigned win_n; static double win_work;
    if (!win_start) win_start = f->t_submit;
    win_n++; win_work += f->work_ms;
    if (f->t_submit - win_start >= 5.0) {
        fprintf(stderr, "  [openvr] guest %.1f fps, frame work %.1f ms (WaitGetPoses -> Submit), "
                        "display %.0f Hz", win_n / (f->t_submit - win_start), win_work / win_n,
                (double)kl_ovrp_display_frequency());
        if (g_pred_win_valid)
            fprintf(stderr, "; head predicted %.1f ms ahead on %u/%u frames, moved %.2f deg avg / "
                            "%.2f worst\n", g_pred_win_ahead / g_pred_win_valid, g_pred_win_valid,
                    g_pred_win_n, g_pred_win_deg / g_pred_win_valid, g_pred_win_worst);
        else
            fprintf(stderr, "; head NOT predicted (%s)\n",
                    ovr_stage("KL_OPENVR_PREDICT", 1) ? "no tracker answers — latched head" : "KL_OPENVR_PREDICT=0");
        win_start = f->t_submit; win_n = 0; win_work = 0;
        g_pred_win_ahead = g_pred_win_deg = g_pred_win_worst = 0; g_pred_win_n = g_pred_win_valid = 0;
    }
}
// Compositor_FrameTiming, packed 4 on Linux: six uint32, a double at +24,
// sixteen floats from +32 (PreSubmitGpu, PostSubmitGpu, TotalRenderGpu,
// CompositorRenderGpu, CompositorRenderCpu, CompositorIdleCpu,
// ClientFrameInterval, ...), the HMD pose at +96.
static int co_frame_timing(void *s, uint8_t *t, uint32_t frames_ago) {
    (void)s;
    if (!t || !ovr_stage("KL_OPENVR_FRAME_TIMING", 1)) return 0;
    uint32_t idx = __atomic_load_n(&g_ft_index, __ATOMIC_ACQUIRE);
    if (frames_ago + 1 >= FT_RING || idx <= frames_ago + 1) return 0;
    // The newest COMPLETE frame is the one before the frame in flight.
    const frame_time *f = &g_ft[(idx - 1 - frames_ago) % FT_RING];
    if (!f->t_submit) return 0;
    uint32_t size;
    memcpy(&size, t, 4);
    if (size < 96) return 0;
    memset(t + 4, 0, size - 4);
    float hz = kl_ovrp_display_frequency();
    double vsync_ms = 1000.0 / (hz > 0 ? hz : 90.0);
    uint32_t presents = 1, dropped = f->interval_ms > vsync_ms * 1.5
                                   ? (uint32_t)(f->interval_ms / vsync_ms + 0.5) - 1 : 0;
    float work = (float)f->work_ms, interval = (float)f->interval_ms;
    memcpy(t + 4, &f->index, 4);
    memcpy(t + 8, &presents, 4);
    memcpy(t + 16, &dropped, 4);
    memcpy(t + 24, &f->t_submit, 8);
    memcpy(t + 32, &work, 4);            // PreSubmitGpuMs
    // KL_GPU_TIME=2: the GPU's own time for the frame (kl_gpu_time.m) instead
    // of the CPU work, once one is known. Any other value leaves it as it was.
    float gpu = kl_gpu_time_mode() == 2 ? kl_gpu_time_frame_ms(frames_ago) : 0;
    memcpy(t + 40, gpu > 0 ? &gpu : &work, 4);   // TotalRenderGpuMs
    memcpy(t + 56, &interval, 4);        // ClientFrameIntervalMs
    if (size >= 96 + sizeof(TrackedDevicePose_t)) memcpy(t + 96, &g_last[0], sizeof(TrackedDevicePose_t));
    return 1;
}
static uint32_t co_frame_timings(void *s, uint8_t *t, uint32_t n) {
    uint32_t got = 0, size = 0;
    if (!t || !n) return 0;
    memcpy(&size, t, 4);
    for (uint32_t i = 0; i < n; i++) {
        uint8_t *e = t + (size_t)i * size;
        memcpy(e, &size, 4);
        if (!co_frame_timing(s, e, n - 1 - i)) continue;   // oldest first
        got++;
    }
    return got;
}

// ---- KL_OPENVR_POSE_TRACE: is the rendered head the declared head? -----------
// The KL_XR_POSE_TRACE instrument for this bridge (on with either knob). Per
// frame, the HMD pose each entry point handed the game — WaitGetPoses,
// GetDeviceToAbsoluteTrackingPose, GetLastPoses — and the pose the game SAYS it
// rendered with (Alyx submits VRTextureWithPose_t, flag 0x08: the matrix at +16
// is OpenVR's "actual pose used to render scene textures"), each differenced
// against the pose the frame is DECLARED to the compositor with (g_frame_pose,
// in the same tracking universe). Reported once a second as worst degrees /
// metres with the count of frames each source was asked on. A row of zeros is
// a consistent runtime; a non-zero "submitted" row with prediction on is the
// game rendering from a head other than the one declared — the swim this
// bridge must not cause. The first answer of each source per frame is the one
// recorded (the one the game built the frame on).
static const char *const k_pt_name[PT_N] = {
    "WaitGetPoses", "GetDeviceToAbsoluteTrackingPose", "GetLastPoses", "submitted (TextureWithPose)"
};
static int pose_trace_on(void) {
    static int on = -1;
    if (on < 0) on = kl_env_on("KL_OPENVR_POSE_TRACE", kl_env_on("KL_XR_POSE_TRACE", 0));
    return on;
}
static struct { uint32_t frame; uint8_t have[PT_N]; float p[PT_N][3], q[PT_N][4]; } g_pt;
static pthread_mutex_t g_pt_mu = PTHREAD_MUTEX_INITIALIZER;
static void pose_trace_note(int src, const TrackedDevicePose_t *hmd) {
    if (!pose_trace_on() || !hmd || src < 0 || src >= PT_N) return;
    pthread_mutex_lock(&g_pt_mu);
    uint32_t fr = __atomic_load_n(&g_ft_index, __ATOMIC_ACQUIRE);
    if (g_pt.frame != fr) { g_pt.frame = fr; memset(g_pt.have, 0, sizeof g_pt.have); }
    if (!g_pt.have[src]) {
        g_pt.have[src] = 1;
        const HmdMatrix34_t *m = &hmd->mDeviceToAbsoluteTracking;
        g_pt.p[src][0] = m->m[0][3]; g_pt.p[src][1] = m->m[1][3]; g_pt.p[src][2] = m->m[2][3];
        m34_to_quat(m, g_pt.q[src]);
    }
    pthread_mutex_unlock(&g_pt_mu);
}
// Once per filed frame, against the pose it was filed with.
static void pose_trace_report(const float pose7[7]) {
    if (!pose_trace_on()) return;
    static double t0;
    static unsigned frames, seen[PT_N];
    static float worst_deg[PT_N], worst_m[PT_N];
    float dp[3] = { pose7[0], pose7[1] - (g_origin == 0 ? kl_ovrp_eye_height() : 0.0f), pose7[2] };
    float dq[4] = { pose7[3], pose7[4], pose7[5], pose7[6] };
    pthread_mutex_lock(&g_pt_mu);
    frames++;
    for (int i = 0; i < PT_N; i++) {
        if (!g_pt.have[i]) continue;
        seen[i]++;
        float deg = quat_deg(g_pt.q[i], dq);
        float dx = g_pt.p[i][0] - dp[0], dy = g_pt.p[i][1] - dp[1], dz = g_pt.p[i][2] - dp[2];
        float m = sqrtf(dx * dx + dy * dy + dz * dz);
        if (deg > worst_deg[i]) worst_deg[i] = deg;
        if (m > worst_m[i]) worst_m[i] = m;
    }
    memset(g_pt.have, 0, sizeof g_pt.have);
    pthread_mutex_unlock(&g_pt_mu);
    double now = now_s();
    if (!t0) t0 = now;
    if (now - t0 < 1.0) return;
    fprintf(stderr, "  [openvr] pose agreement over %u frame(s), each HMD pose vs the DECLARED one:\n", frames);
    for (int i = 0; i < PT_N; i++)
        fprintf(stderr, "  [openvr]   %-32s asked on %3u, worst %.3f deg / %.4f m\n", k_pt_name[i],
                seen[i], (double)worst_deg[i], (double)worst_m[i]);
    t0 = now; frames = 0;
    memset(seen, 0, sizeof seen); memset(worst_deg, 0, sizeof worst_deg); memset(worst_m, 0, sizeof worst_m);
}

// The frame's head prediction (see "head prediction" above), once, right after
// the latch it is a delta against.
//
// How far ahead: to when this frame is first SEEN. It is drawn for the frame's
// work — WaitGetPoses to the second Submit returning, which on device includes
// the GPU (Submit waits on the eye copy queued behind the game's own work) —
// smoothed over recent frames, and then waits for the compositor's next
// refresh and its scanout: one display period stands in for that. On device
// that is ~35 ms + ~10 ms. Capped at 50 ms for OpenXR's reason (past that a
// tracker's extrapolation overshoots and is worse than late), and the cap is
// what a slow frame gets. KL_OPENVR_PREDICT_MS=<ms> fixes the interval instead
// (still capped) — the knob for tuning it by eye.
#define OVR_PREDICT_MAX_MS 50.0
static void predict_frame(void) {
    head_delta d = { 0, { 0, 0, 0, 1 }, { 0, 0, 0 }, 0, 0 };
    static int on = -1;
    static float fixed_ms;
    if (on < 0) {
        on = ovr_stage("KL_OPENVR_PREDICT", 1);
        fixed_ms = kl_env_float("KL_OPENVR_PREDICT_MS", 0.0f);
    }
    if (on) {
        float hz = kl_ovrp_display_frequency();
        double period = 1000.0 / (hz > 0 ? hz : 90.0);
        // To when the frame is first SEEN: its work, then the wait for the
        // compositor's next frame (half a period on average), then that
        // frame's own lead to its presentation (kl_ovrp_head_lead_s, measured
        // off the frontend; one period when it dates nothing).
        double lead = kl_ovrp_head_lead_s() * 1000.0;
        double ahead = fixed_ms > 0 ? (double)fixed_ms
                                    : g_work_ema_ms + (lead > 0 ? lead + period * 0.5 : period);
        if (ahead < 0) ahead = 0;
        static double cap = -1;
        if (cap < 0) cap = kl_env_float("KL_OPENVR_PREDICT_MAX_MS", (float)OVR_PREDICT_MAX_MS);
        if (ahead > cap) ahead = cap;
        d.ahead_ms = ahead;
        d.target_s = now_s() + ahead / 1000.0;
        d.valid = kl_ovrp_head_predict_delta(d.target_s, d.q, d.p);
        if (!d.valid) { d.q[0] = d.q[1] = d.q[2] = 0; d.q[3] = 1; d.p[0] = d.p[1] = d.p[2] = 0; }
    }
    pthread_mutex_lock(&g_pred_mu);
    g_pred = d;
    pthread_mutex_unlock(&g_pred_mu);
    g_pred_win_n++;
    static int said_on, said_off;
    if (d.valid) {
        static const float ident[4] = { 0, 0, 0, 1 };
        double deg = quat_deg(d.q, ident);
        g_pred_win_valid++; g_pred_win_ahead += d.ahead_ms; g_pred_win_deg += deg;
        if (deg > g_pred_win_worst) g_pred_win_worst = deg;
        if (!said_on++)
            fprintf(stderr, "  [openvr] head prediction ON: the frame's head predicted %.1f ms ahead "
                            "(%s), capped %.0f ms, applied to every HMD pose AND the declared pose "
                            "(KL_OPENVR_PREDICT=0 for the latched head). From here the [ovrp] \"guest "
                            "submitted a pose ... from the one it was handed\" line measures this "
                            "prediction, not the game\n", d.ahead_ms,
                    fixed_ms > 0 ? "KL_OPENVR_PREDICT_MS" : "frame work, smoothed, + one display period",
                    OVR_PREDICT_MAX_MS);
    } else if (!said_off++) {
        fprintf(stderr, "  [openvr] head prediction %s: every pose is the latched head, as before\n",
                on ? "asked, but no tracker answers (host run: no frontend predicts)" : "off (KL_OPENVR_PREDICT=0)");
    }
}

// Once, at the first WaitGetPoses: which stages of the pipeline this run has.
static void ovr_pipeline_report(void) {
    static int said;
    if (said++) return;
    fprintf(stderr, "  [openvr] PIPELINE%s: predict %d, overscan %.3f, sym_proj %d, submit_proj "
                    "(adopted tangents) %d, stage_scale %d, touch_frame %d, hand_vel %d, "
                    "frame_timing %d, reproject_off %d (KL_OPENVR_MINIMAL turns every stage off; "
                    "a knob set explicitly wins)\n",
            ovr_minimal() ? " MINIMAL" : "",
            ovr_stage("KL_OPENVR_PREDICT", 1), (double)overscan(),
            ovr_stage("KL_OPENVR_SYM_PROJ", 1), ovr_stage("KL_OPENVR_SUBMIT_PROJ", 1),
            ovr_stage("KL_OPENVR_STAGE_SCALE", 1), ovr_stage("KL_OPENVR_TOUCH_FRAME", 1),
            ovr_stage("KL_OPENVR_HAND_VEL", 1), ovr_stage("KL_OPENVR_FRAME_TIMING", 1),
            kl_reproject_off());
}

// ---- KL_OPENVR_HAND_TRACE: is the hand the game is handed smooth? --------------
// Once per frame (at WaitGetPoses, the poses the frame is built on), per hand:
// the step from the previous frame and the SECOND difference (p[n] - 2p[n-1] +
// p[n-2]: zero for steady motion, large for a pose that jitters or jumps back
// and forth — a tremor is this number, not the step), how many frames the
// published sample did not change at all (a source that stops and restarts:
// ARKit hand tracking of a hand gripping a controller does exactly that), the
// largest velocity and angular velocity reported to the game, and the head
// prediction's translation (the part of the head the compositor's rotational
// timewarp cannot correct). One line per hand every 5 s by default
// (=1), every second with =2, off with =0.
static void hand_trace_frame(void) {
    static int on = -1;
    if (on < 0) on = kl_env_int("KL_OPENVR_HAND_TRACE", 1);
    if (!on) return;
    typedef struct {
        int have; float p1[3], p2[3], q1[4], q2[4], raw[7];
        unsigned frames, repeats;
        double step_m, step_deg, jit_m, jit_deg;
        float step_m_max, step_deg_max, jit_m_max, jit_deg_max, v_max, w_max;
    } ht;
    static ht h[2];
    static double t0, pred_max_m, pred_sum_m;
    static unsigned pred_n;
    head_delta d = pred_get();
    if (d.valid) {
        double m = sqrt((double)d.p[0] * d.p[0] + (double)d.p[1] * d.p[1] + (double)d.p[2] * d.p[2]);
        pred_sum_m += m; pred_n++;
        if (m > pred_max_m) pred_max_m = m;
    }
    for (int k = 0; k < 2; k++) {
        ht *s = &h[k];
        const HmdMatrix34_t *M = &g_last[k ? DEV_RIGHT : DEV_LEFT].mDeviceToAbsoluteTracking;
        float p[3] = { M->m[0][3], M->m[1][3], M->m[2][3] }, q[4];
        m34_to_quat(M, q);
        float raw[7], rv[3], ra[3];
        kl_ovrp_hand_motion(k, raw, raw + 3, rv, ra);
        if (s->have && !memcmp(raw, s->raw, sizeof raw)) s->repeats++;
        memcpy(s->raw, raw, sizeof raw);
        const float *vv = g_last[k ? DEV_RIGHT : DEV_LEFT].vVelocity;
        const float *aa = g_last[k ? DEV_RIGHT : DEV_LEFT].vAngularVelocity;
        float vm = sqrtf(vv[0] * vv[0] + vv[1] * vv[1] + vv[2] * vv[2]);
        float wm = sqrtf(aa[0] * aa[0] + aa[1] * aa[1] + aa[2] * aa[2]);
        if (vm > s->v_max) s->v_max = vm;
        if (wm > s->w_max) s->w_max = wm;
        if (s->have >= 1) {
            float dx = p[0] - s->p1[0], dy = p[1] - s->p1[1], dz = p[2] - s->p1[2];
            float st = sqrtf(dx * dx + dy * dy + dz * dz), sd = quat_deg(q, s->q1);
            s->step_m += st; s->step_deg += sd;
            if (st > s->step_m_max) s->step_m_max = st;
            if (sd > s->step_deg_max) s->step_deg_max = sd;
        }
        if (s->have >= 2) {
            float j[3];
            for (int i = 0; i < 3; i++) j[i] = p[i] - 2 * s->p1[i] + s->p2[i];
            float jm = sqrtf(j[0] * j[0] + j[1] * j[1] + j[2] * j[2]);
            // Rotational second difference: the turn this frame minus the turn
            // last frame, as an angle (r1 = q1 q2^-1, r0 = q q1^-1; |r0 r1^-1|).
            float r0[4], r1[4];
            float iq1[4] = { -s->q1[0], -s->q1[1], -s->q1[2], s->q1[3] };
            float iq2[4] = { -s->q2[0], -s->q2[1], -s->q2[2], s->q2[3] };
            quat_mul(q, iq1, r0); quat_mul(s->q1, iq2, r1);
            float jd = quat_deg(r0, r1);
            s->jit_m += jm; s->jit_deg += jd;
            if (jm > s->jit_m_max) s->jit_m_max = jm;
            if (jd > s->jit_deg_max) s->jit_deg_max = jd;
        }
        memcpy(s->p2, s->p1, sizeof s->p2); memcpy(s->q2, s->q1, sizeof s->q2);
        memcpy(s->p1, p, sizeof s->p1); memcpy(s->q1, q, sizeof s->q1);
        if (s->have < 2) s->have++;
        s->frames++;
    }
    double now = now_s();
    if (!t0) t0 = now;
    if (now - t0 < (on >= 2 ? 1.0 : 5.0)) return;
    for (int k = 0; k < 2; k++) {
        ht *s = &h[k];
        unsigned n1 = s->frames > 1 ? s->frames - 1 : 1, n2 = s->frames > 2 ? s->frames - 2 : 1;
        fprintf(stderr, "  [openvr] hand %c over %u frames: step %.1f/%.1f mm %.2f/%.2f deg (mean/max), "
                        "JITTER %.1f/%.1f mm %.2f/%.2f deg, published sample repeated on %u, "
                        "|v| max %.2f m/s |w| max %.1f rad/s\n", k ? 'R' : 'L', s->frames,
                s->step_m / n1 * 1000, (double)s->step_m_max * 1000, s->step_deg / n1, (double)s->step_deg_max,
                s->jit_m / n2 * 1000, (double)s->jit_m_max * 1000, s->jit_deg / n2, (double)s->jit_deg_max,
                s->repeats, (double)s->v_max, (double)s->w_max);
        s->frames = s->repeats = 0;
        s->step_m = s->step_deg = s->jit_m = s->jit_deg = 0;
        s->step_m_max = s->step_deg_max = s->jit_m_max = s->jit_deg_max = s->v_max = s->w_max = 0;
    }
    if (pred_n)
        fprintf(stderr, "  [openvr] head prediction moved the head %.1f mm avg / %.1f mm worst "
                        "(translation: the compositor's timewarp does not correct it)\n",
                pred_sum_m / pred_n * 1000, pred_max_m * 1000);
    pred_sum_m = pred_max_m = 0; pred_n = 0;
    t0 = now;
}

// The guest frame pacer (KL_GUEST_PACE_HZ / KL_GUEST_PACE_DIV): the visionOS
// app installs one only when a knob is set, and it blocks here until the
// compositor has published enough poses. NULL — the default, and always on the
// host — and WaitGetPoses returns at once, as it always has. Before ft_wait, so
// the time spent held is neither "frame work" (which the head prediction reads
// as how far ahead the frame is seen) nor anything the frame's pose was taken
// before: the latch below is the head after the wait.
static void (*g_frame_pacer)(void);
void kl_openvr_set_frame_pacer(void (*wait)(void)) { g_frame_pacer = wait; }

static int co_wait_get_poses(void *s, TrackedDevicePose_t *render, uint32_t n,
                             TrackedDevicePose_t *game, uint32_t gn) {
    (void)s;
    if (g_frame_pacer) g_frame_pacer();
    ovr_pipeline_report();
    ft_wait();
    // The frame starts here, exactly as xrWaitFrame starts an OpenXR one: pin
    // the poses this frame will be drawn with...
    kl_ovrp_frame_latch();
    kl_ovrp_frame_begin_external();
    // ...and move the head to when the frame will be seen, once, for every
    // pose below and every pose asked until the next WaitGetPoses.
    predict_frame();
    for (int d = 0; d < NDEV; d++) device_pose(d, &g_last[d]);
    hand_trace_frame();
    for (uint32_t i = 0; render && i < n; i++) {
        if (i < NDEV) render[i] = g_last[i]; else memset(&render[i], 0, sizeof *render);
    }
    for (uint32_t i = 0; game && i < gn; i++) {
        if (i < NDEV) game[i] = g_last[i]; else memset(&game[i], 0, sizeof *game);
    }
    pose_trace_note(PT_WAIT, &g_last[DEV_HMD]);
    // The pose the frame is declared with: the same latched head, moved by the
    // same delta, so it is the head the game was handed — in kl_ovrp's space
    // (the seated offset is the guest's view of it, not the compositor's).
    kl_ovrp_get_guest_head_pose(&g_frame_pose[0], &g_frame_pose[1], &g_frame_pose[2],
                                &g_frame_pose[3], &g_frame_pose[4], &g_frame_pose[5], &g_frame_pose[6]);
    {
        head_delta d = pred_get();
        pred_apply(&d, g_frame_pose, g_frame_pose + 3);
        // The declared pose is now the PREDICTED head, so the frame is about
        // the predicted instant, not the latched sample's (which
        // kl_ovrp_frame_begin_external filed). Same clock re-basing the
        // prediction itself used, so the compositor can ask the tracker for
        // the very anchor this pose came from (KL_REPROJECT_DEPTH_MODE >= 1).
        if (d.valid && d.target_s > 0)
            kl_ovrp_frame_set_pose_time(kl_ovrp_tracker_time(d.target_s));
    }
    eye_tangents(0, g_frame_tan);
    eye_tangents(1, g_frame_tan + 4);
    return 0;
}
static int co_last_poses(void *s, TrackedDevicePose_t *render, uint32_t n,
                         TrackedDevicePose_t *game, uint32_t gn) {
    (void)s;
    for (uint32_t i = 0; render && i < n; i++) { if (i < NDEV) render[i] = g_last[i]; else memset(&render[i], 0, sizeof *render); }
    for (uint32_t i = 0; game && i < gn; i++) { if (i < NDEV) game[i] = g_last[i]; else memset(&game[i], 0, sizeof *game); }
    if ((render && n) || (game && gn)) pose_trace_note(PT_LAST, &g_last[DEV_HMD]);
    return 0;
}
static int co_last_pose_idx(void *s, uint32_t i, TrackedDevicePose_t *r, TrackedDevicePose_t *g) {
    (void)s;
    if (i >= NDEV) return 1;
    if (r) *r = g_last[i];
    if (g) *g = g_last[i];
    if (i == DEV_HMD) pose_trace_note(PT_LAST, &g_last[DEV_HMD]);
    return 0;
}

// The eye copy: guest image -> an MTLTexture-backed image of ours, per eye per
// stage, recorded and submitted on the guest's queue. OpenVR requires the
// submitted image to be in TRANSFER_SRC_OPTIMAL, so the copy needs no layout
// change on the guest's side.
#define OVR_STAGES 3
static unsigned long long g_frames_for_dump;
#ifdef KLOVR_VULKAN
static struct {
    VkDevice dev;
    VkQueue q;
    uint32_t qf;
    VkCommandPool pool;
    VkCommandBuffer cb[2][OVR_STAGES];
    VkFence fence[2][OVR_STAGES];
    VkFence sync;                         // the zero-copy path's "the game's frame is done"
    uint64_t dst[2][OVR_STAGES];
    uint32_t w[2], h[2], fmt[2];
    void *mtl[2][OVR_STAGES];             // the MTLTexture behind dst, as the compositor knows it
    uint8_t in_place[2][OVR_STAGES];      // the compositor slot points at the GAME's image instead
    // KL_OPENVR_STAGE_SCALE=0: per (eye, stage) images sized exactly to the
    // rendered rect, one per size seen (Alyx's dynamic resolution alternates
    // a few), never freed — a diagnostic's memory, not a setting's.
    struct { uint32_t w, h, fmt; uint64_t img; void *mtl; } native[2][OVR_STAGES][4];
    // KL_REPROJECT_DEPTH_MODE=2: the game's depth for (eye, stage), copied at
    // Submit beside the colour — sized to the rendered rect, so the colour
    // stage's normalised uv addresses it whether or not the colour was scaled.
    struct { uint32_t w, h, fmt; uint64_t img; void *mtl; } depth[2][OVR_STAGES];
    PFN_vkCreateCommandPool CreateCommandPool;
    PFN_vkAllocateCommandBuffers AllocateCommandBuffers;
    PFN_vkBeginCommandBuffer BeginCommandBuffer;
    PFN_vkEndCommandBuffer EndCommandBuffer;
    PFN_vkResetCommandBuffer ResetCommandBuffer;
    PFN_vkCmdPipelineBarrier CmdPipelineBarrier;
    PFN_vkCmdCopyImage CmdCopyImage;
    PFN_vkCmdBlitImage CmdBlitImage;
    PFN_vkCmdCopyImageToBuffer CmdCopyImageToBuffer;
    PFN_vkQueueSubmit QueueSubmit;
    PFN_vkCreateFence CreateFence;
    PFN_vkWaitForFences WaitForFences;
    PFN_vkResetFences ResetFences;
} V;

static int vk_setup(const VRVulkanTextureData_t *t) {
    if (V.dev == (VkDevice)t->m_pDevice && V.pool) return 0;
    PFN_vkGetDeviceProcAddr gdpa = (PFN_vkGetDeviceProcAddr)kl_vulkan_sym("vkGetDeviceProcAddr");
    if (!gdpa) return -1;
    memset(&V, 0, sizeof V);
    V.dev = (VkDevice)t->m_pDevice;
    V.q = (VkQueue)t->m_pQueue;
    V.qf = t->m_nQueueFamilyIndex;
#define R(f) V.f = (PFN_vk##f)gdpa(V.dev, "vk" #f)
    R(CreateCommandPool); R(AllocateCommandBuffers); R(BeginCommandBuffer); R(EndCommandBuffer);
    R(ResetCommandBuffer); R(CmdPipelineBarrier); R(CmdCopyImage); R(CmdBlitImage);
    R(QueueSubmit); R(CreateFence); R(WaitForFences); R(ResetFences); R(CmdCopyImageToBuffer);
#undef R
    VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = V.qf };
    if (!V.CreateCommandPool || V.CreateCommandPool(V.dev, &pci, NULL, &V.pool) != VK_SUCCESS) return -1;
    VkCommandBufferAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = V.pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = OVR_STAGES };
    VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT };
    for (int e = 0; e < 2; e++) {
        V.AllocateCommandBuffers(V.dev, &ai, V.cb[e]);
        for (int k = 0; k < OVR_STAGES; k++) V.CreateFence(V.dev, &fci, NULL, &V.fence[e][k]);
    }
    fprintf(stderr, "  [openvr] Vulkan submit path ready (device %p, queue family %u)\n",
            (void *)V.dev, V.qf);
    return 0;
}

// KL_OPENVR_DUMP=<dir>: write the guest's submitted image (the layer this eye
// reads, whole, before any scaling) and our stage image after the copy, once,
// at submitted frame KL_OPENVR_DUMP_AT (default 300), as quarter-size PPMs —
// eyeN_src.ppm / eyeN_dst.ppm. The ground truth for "is it the picture or the
// compositor": what the game drew versus what the compositor is handed.
static void vk_dump(const VRVulkanTextureData_t *t, VkImage img, uint32_t layer, uint32_t w, uint32_t h,
                    const char *name) {
    const char *dir = getenv("KL_OPENVR_DUMP");
    if (!dir || !*dir || !t->m_pPhysicalDevice) return;
    PFN_vkGetDeviceProcAddr gdpa = (PFN_vkGetDeviceProcAddr)kl_vulkan_sym("vkGetDeviceProcAddr");
    PFN_vkGetInstanceProcAddr gipa = (PFN_vkGetInstanceProcAddr)kl_vulkan_sym("vkGetInstanceProcAddr");
    if (!gdpa || !gipa) return;
#define D(f) PFN_vk##f f = (PFN_vk##f)gdpa(V.dev, "vk" #f)
    D(CreateBuffer); D(GetBufferMemoryRequirements); D(AllocateMemory); D(BindBufferMemory);
    D(MapMemory); D(DestroyBuffer); D(FreeMemory);
#undef D
    PFN_vkGetPhysicalDeviceMemoryProperties gmp = (PFN_vkGetPhysicalDeviceMemoryProperties)
        gipa((VkInstance)t->m_pInstance, "vkGetPhysicalDeviceMemoryProperties");
    if (!CreateBuffer || !gmp) return;
    VkDeviceSize sz = (VkDeviceSize)w * h * 4;
    VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = sz,
                               .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
    VkBuffer buf; VkDeviceMemory mem; VkMemoryRequirements mr;
    if (CreateBuffer(V.dev, &bci, NULL, &buf) != VK_SUCCESS) return;
    GetBufferMemoryRequirements(V.dev, buf, &mr);
    VkPhysicalDeviceMemoryProperties mp; gmp((VkPhysicalDevice)t->m_pPhysicalDevice, &mp);
    uint32_t ti = 0;
    for (; ti < mp.memoryTypeCount; ti++)
        if ((mr.memoryTypeBits & (1u << ti)) &&
            (mp.memoryTypes[ti].propertyFlags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))
                == (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) break;
    VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
                                 .memoryTypeIndex = ti };
    if (ti == mp.memoryTypeCount || AllocateMemory(V.dev, &mai, NULL, &mem) != VK_SUCCESS) { DestroyBuffer(V.dev, buf, NULL); return; }
    BindBufferMemory(V.dev, buf, mem, 0);
    VkCommandBuffer cb = V.cb[0][0];
    V.WaitForFences(V.dev, 1, &V.fence[0][0], VK_TRUE, UINT64_MAX);
    V.ResetFences(V.dev, 1, &V.fence[0][0]);
    V.ResetCommandBuffer(cb, 0);
    VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    V.BeginCommandBuffer(cb, &bi);
    VkImageMemoryBarrier bar = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = img, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, layer, 1 } };
    // The guest's image is already TRANSFER_SRC (OpenVR's contract); ours is
    // SHADER_READ after the copy. Say so, or UNDEFINED would let it be discarded.
    bar.oldLayout = name[5] == 's' ? VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL : VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    V.CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &bar);
    VkBufferImageCopy reg = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, layer, 1 },
                              .imageExtent = { w, h, 1 } };
    V.CmdCopyImageToBuffer(cb, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buf, 1, &reg);
    if (name[5] != 's') {                         // give ours back to the compositor as it was
        bar.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL; bar.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        bar.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT; bar.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        V.CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0, NULL, 1, &bar);
    }
    V.EndCommandBuffer(cb);
    VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
    V.QueueSubmit(V.q, 1, &si, V.fence[0][0]);
    V.WaitForFences(V.dev, 1, &V.fence[0][0], VK_TRUE, UINT64_MAX);
    uint8_t *px = NULL;
    if (MapMemory(V.dev, mem, 0, sz, 0, (void **)&px) == VK_SUCCESS && px) {
        char path[1024];
        snprintf(path, sizeof path, "%s/%s.ppm", dir, name);
        FILE *f = fopen(path, "wb");
        if (f) {
            uint32_t ow = w / 4, oh = h / 4;
            fprintf(f, "P6\n%u %u\n255\n", ow, oh);
            for (uint32_t y = 0; y < oh; y++)
                for (uint32_t x = 0; x < ow; x++) {
                    const uint8_t *p = px + ((size_t)(y * 4) * w + x * 4) * 4;
                    fputc(p[0], f); fputc(p[1], f); fputc(p[2], f);
                }
            fclose(f);
            fprintf(stderr, "  [openvr] dumped %s (%ux%u, layer %u)\n", path, w, h, layer);
        }
    }
    FreeMemory(V.dev, mem, NULL);
    DestroyBuffer(V.dev, buf, NULL);
}

// KL_OPENVR_DUMP's depth twin: our depth copy for this eye, as a quarter-size
// PFM of the RAW game depth values (eyeN_depth.pfm), beside the PPMs. The
// ground truth for KL_REPROJECT_DEPTH_CONV — open it and look at which end the
// sky is.
static void vk_dump_depth(const VRVulkanTextureData_t *t, VkImage img, uint32_t w, uint32_t h,
                          const char *name) {
    const char *dir = getenv("KL_OPENVR_DUMP");
    if (!dir || !*dir || !t->m_pPhysicalDevice) return;
    PFN_vkGetDeviceProcAddr gdpa = (PFN_vkGetDeviceProcAddr)kl_vulkan_sym("vkGetDeviceProcAddr");
    PFN_vkGetInstanceProcAddr gipa = (PFN_vkGetInstanceProcAddr)kl_vulkan_sym("vkGetInstanceProcAddr");
    if (!gdpa || !gipa) return;
#define D(f) PFN_vk##f f = (PFN_vk##f)gdpa(V.dev, "vk" #f)
    D(CreateBuffer); D(GetBufferMemoryRequirements); D(AllocateMemory); D(BindBufferMemory);
    D(MapMemory); D(DestroyBuffer); D(FreeMemory);
#undef D
    PFN_vkGetPhysicalDeviceMemoryProperties gmp = (PFN_vkGetPhysicalDeviceMemoryProperties)
        gipa((VkInstance)t->m_pInstance, "vkGetPhysicalDeviceMemoryProperties");
    if (!CreateBuffer || !gmp) return;
    VkDeviceSize sz = (VkDeviceSize)w * h * 4;
    VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = sz,
                               .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
    VkBuffer buf; VkDeviceMemory mem; VkMemoryRequirements mr;
    if (CreateBuffer(V.dev, &bci, NULL, &buf) != VK_SUCCESS) return;
    GetBufferMemoryRequirements(V.dev, buf, &mr);
    VkPhysicalDeviceMemoryProperties mp; gmp((VkPhysicalDevice)t->m_pPhysicalDevice, &mp);
    uint32_t ti = 0;
    for (; ti < mp.memoryTypeCount; ti++)
        if ((mr.memoryTypeBits & (1u << ti)) &&
            (mp.memoryTypes[ti].propertyFlags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))
                == (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) break;
    VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
                                 .memoryTypeIndex = ti };
    if (ti == mp.memoryTypeCount || AllocateMemory(V.dev, &mai, NULL, &mem) != VK_SUCCESS) { DestroyBuffer(V.dev, buf, NULL); return; }
    BindBufferMemory(V.dev, buf, mem, 0);
    VkCommandBuffer cb = V.cb[0][0];
    V.WaitForFences(V.dev, 1, &V.fence[0][0], VK_TRUE, UINT64_MAX);
    V.ResetFences(V.dev, 1, &V.fence[0][0]);
    V.ResetCommandBuffer(cb, 0);
    VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    V.BeginCommandBuffer(cb, &bi);
    VkImageMemoryBarrier bar = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = img, .subresourceRange = { VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT, 0, 1, 0, 1 } };
    V.CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &bar);
    VkBufferImageCopy reg = { .imageSubresource = { VK_IMAGE_ASPECT_DEPTH_BIT, 0, 0, 1 },
                              .imageExtent = { w, h, 1 } };
    V.CmdCopyImageToBuffer(cb, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buf, 1, &reg);
    bar.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL; bar.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    bar.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT; bar.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    V.CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0, NULL, 1, &bar);
    V.EndCommandBuffer(cb);
    VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
    V.QueueSubmit(V.q, 1, &si, V.fence[0][0]);
    V.WaitForFences(V.dev, 1, &V.fence[0][0], VK_TRUE, UINT64_MAX);
    float *px = NULL;
    if (MapMemory(V.dev, mem, 0, sz, 0, (void **)&px) == VK_SUCCESS && px) {
        char path[1024];
        snprintf(path, sizeof path, "%s/%s.pfm", dir, name);
        FILE *f = fopen(path, "wb");
        if (f) {
            uint32_t ow = w / 4, oh = h / 4;
            fprintf(f, "Pf\n%u %u\n-1.0\n", ow, oh);           // little-endian, rows bottom-up
            for (uint32_t y = oh; y-- > 0;)
                for (uint32_t x = 0; x < ow; x++) {
                    float v = px[(size_t)(y * 4) * w + x * 4];
                    fwrite(&v, sizeof v, 1, f);
                }
            fclose(f);
            fprintf(stderr, "  [openvr] dumped %s (%ux%u raw game depth, centre %.5f)\n", path, w, h,
                    (double)px[(size_t)(h / 2) * w + w / 2]);
        }
    }
    FreeMemory(V.dev, mem, NULL);
    DestroyBuffer(V.dev, buf, NULL);
}

// ---- zero copy -----------------------------------------------------------------------
// The compositor samples the game's own eye image in place: the MTLTexture
// MoltenVK keeps behind the VkImage the game submitted, the eye's array layer
// as the slice. That removes, per eye per frame, a full-resolution blit
// (4608x2880 -> the stage image, on device) — and its read and its write of
// ~50 MB — which is a large share of a GPU-bound frame.
//
// Taken only when nothing would need the copy's help: full bounds (the
// compositor has no per-frame sub-rect for an external frame) and no vertical
// flip. Anything else falls back to the copy, per submit.
//
// **It is only correct for a game that ROTATES its eye images, and Alyx does
// not.** The compositor does not sample a frame once: it re-reads the last
// complete stage on every display refresh (timewarp, 90-120 Hz) until the next
// frame is filed. Sampled in place, the image the compositor is reading is the
// image the game is RENDERING its next frame into. Measured on the Mac
// (KL_OPENVR_ZEROCOPY=2, forced): 7 of 20 back-to-back window captures of the
// VR menu showed the world pass with the hands and the Panorama panels missing
// — a half-rendered frame, which on screen is the menu FLICKERING. The vertical
// stripes seen earlier did not reproduce on the Mac; they are most likely the
// same race caught at another point of the game's frame. Nothing about the
// sampling itself is wrong: MoltenVK's texture for the game's image is a
// 2-layer MTLTextureType2DArray, RGBA8 sRGB (fmt 43) like our stage images, and
// the layer as the slice gives the right eye (left != right, measured).
//
// What Alyx does (logged by the "eye images" line below): ONE 2-layer image
// per render size, rewritten every frame. Its dynamic resolution flips between
// 2688x2880 and 1728x1824, each size its own image, so a run sees "2 distinct"
// images — which read as a two-image rotation and is not one: between size
// changes, every frame is the same image. The "same image" detector that
// tripped "after a few hundred frames" was therefore right, not a false trip —
// it tripped at the first stretch without a size change. Real zero copy for
// Alyx needs the game to render into OUR rotating images, i.e. answering
// IVRIPCResourceManagerClient (refused today, see the interface table).
//
// So the decision is per FRAME, from evidence: in place only once the image
// has changed on every one of the last ZC_STREAK frames (a rotation of two or
// more), and back to the copy on the first repeat. Per frame and not per eye,
// because both eyes of one frame have to come from the same place — Alyx's two
// eyes are two layers of one image, so they repeat together anyway. A frame's
// first eye decides; its second follows. Under Alyx this is the copy, always,
// with one line saying why.
//
// Leaving in place has a second half that used to be missing: the compositor's
// per-(eye, stage) table still points at the game's image, and the copy only
// re-exports its own images when their SIZE changes — so after a fallback the
// slots the zero-copy frames had touched kept sampling the game's live image
// while the copy wrote elsewhere (a stage table of mixed sources, measured).
// in_place[][] remembers which slots those are and the copy points them back.
//
// Ordering: the game submitted its rendering before Submit, on the queue it
// handed us. One empty submission with a fence on that queue, waited on once
// per frame (after its last eye), is "the picture is complete" — the same
// point the copy's fence used to mark, minus the copy. Reuse is then the
// rotation's: the image of frame N is not rewritten before frame N+1 is filed.
// A game that stops rotating exactly after an in-place frame races for that
// one frame; that cannot be seen coming from here.
//
// KL_OPENVR_ZEROCOPY: 0 (default) the copy; 1 in place when the game rotates
// (the copy for Alyx); 2 in place ALWAYS — a diagnostic that reproduces the
// race, never a setting.
#define ZC_STREAK 8
static int zc_mode(void) {
    static int on = -1;
    if (on < 0) on = kl_env_int("KL_OPENVR_ZEROCOPY", 0);
    return on;
}

// Called once per submit, BEFORE either path, so the streak sees every frame
// whichever path the frame then takes. Returns whether this frame may be
// sampled in place. `first`: no eye of this frame has been submitted yet.
static int zc_frame_ok(int first, uint64_t image) {
    static uint64_t prev;
    static int streak, ok;
    if (!first) return ok;                // a frame's second eye follows its first
    streak = image != prev ? (streak < 1000000 ? streak + 1 : streak) : 0;
    prev = image;
    int was = ok;
    ok = zc_mode() == 2 || streak >= ZC_STREAK;
    if (zc_mode() && was != ok) {
        static int said;
        if (said < 6) { said++;
            if (ok)
                fprintf(stderr, "  [openvr] zero-copy: the game rotates its eye images (a new "
                                "one on each of the last %d frames) — sampling them in place\n",
                        ZC_STREAK);
            else
                fprintf(stderr, "  [openvr] zero-copy: the game submitted the image it submitted "
                                "last frame — it renders into ONE image, which the compositor "
                                "would be reading while the game redraws it; copying\n"); }
    }
    if (zc_mode() == 1 && !ok && !was) {
        static unsigned long long n;
        if (++n == 600) fprintf(stderr, "  [openvr] zero-copy: never taken in 600 frames — "
                                        "the game renders every frame into the same image "
                                        "(Alyx does; see vk_zero_copy_eye)\n");
    }
    return ok;
}

static int vk_zero_copy_eye(int eye, int stage, const VRVulkanTextureData_t *t,
                            const VRTextureBounds_t *b, uint32_t layer, int frame_ok, int last) {
    if (!zc_mode() || !frame_ok) return -1;
    if (b && (b->uMin != 0.0f || b->uMax != 1.0f || b->vMin != 0.0f || b->vMax != 1.0f)) return -1;
    if (vk_setup(t) != 0) return -1;
    void *mtl = kl_vulkan_xr_image_mtl(t->m_nImage);
    if (!mtl) return -1;
    kl_glfb_note_eye_mtl_texture(eye, stage, mtl, (int)layer, (int)t->m_nWidth, (int)t->m_nHeight);
    V.in_place[eye][stage] = 1;
    static int said;
    if (!said) { said = 1;
        fprintf(stderr, "  [openvr] zero-copy: the compositor samples the game's %ux%u eye "
                        "image in place (no per-eye blit)\n", t->m_nWidth, t->m_nHeight); }
    if (last) {                           // both eyes in: wait for the game's frame
        if (!V.sync) {
            VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
            if (V.CreateFence(V.dev, &fci, NULL, &V.sync) != VK_SUCCESS) return -1;
        }
        VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO };
        if (V.QueueSubmit(V.q, 1, &si, V.sync) != VK_SUCCESS) return -1;
        V.WaitForFences(V.dev, 1, &V.sync, VK_TRUE, UINT64_MAX);
        V.ResetFences(V.dev, 1, &V.sync);
    }
    return 0;
}

// KL_REPROJECT_DEPTH_MODE=2: the game's depth for one eye, as Submit's
// VRTextureDepthInfo_t names it, and whether the copy below took it.
typedef struct { const VRVulkanTextureData_t *t; uint32_t layer; int ok; } ovr_depth_src;

// Record, into the eye's own copy command buffer (same submit, same fence, so
// the depth is complete exactly when the colour is), a copy of the DEPTH aspect
// of the rendered rect into our per-(eye, stage) depth image. Returns whether
// it did. The rect is copied 1:1 at its own size whatever the colour path
// does with it (scaled or native), so the colour stage's normalised uv
// addresses it unchanged — the compositor samples both at one uv.
//
// Layouts: the game's depth is read as TRANSFER_SRC_OPTIMAL, as its colour is
// (OpenVR's contract for the colour; it states none for the depth). MoltenVK
// treats image layouts as no-ops, so this is a memory dependency on the game's
// depth writes and nothing else.
static int vk_record_depth(VkCommandBuffer cb, int eye, int stage, const ovr_depth_src *ds,
                           int32_t x0, int32_t y0, int32_t x1, int32_t y1, int vflip) {
    const VRVulkanTextureData_t *dt = ds->t;
    static int said_skip;
    const char *why = NULL;
    if (!dt->m_nImage) why = "no image";
    else if (vflip) why = "the colour is flipped (vMin > vMax) and a depth copy cannot flip";
    else if (dt->m_nSampleCount > 1) why = "the depth is multisampled";
    else if ((uint32_t)x1 > dt->m_nWidth || (uint32_t)y1 > dt->m_nHeight)
        why = "the rendered rect is outside the depth image";
    if (why) {
        if (said_skip < 4) { said_skip++;
            fprintf(stderr, "  [swim] eye %d depth NOT copied: %s (%ux%u fmt %u samples %u) — this "
                            "frame composites without depth\n", eye, why, dt->m_nWidth, dt->m_nHeight,
                    dt->m_nFormat, dt->m_nSampleCount); }
        return 0;
    }
    uint32_t rw = (uint32_t)(x1 - x0), rh = (uint32_t)(y1 - y0);
    VkFormat fmt = (VkFormat)dt->m_nFormat;
    VkImageAspectFlags all = VK_IMAGE_ASPECT_DEPTH_BIT;
    if (fmt == VK_FORMAT_D16_UNORM_S8_UINT || fmt == VK_FORMAT_D24_UNORM_S8_UINT ||
        fmt == VK_FORMAT_D32_SFLOAT_S8_UINT)
        all |= VK_IMAGE_ASPECT_STENCIL_BIT;
    // Only formats the compositor can sample as depth2d<float> through
    // MoltenVK's MTLTexture: D32 and D32S8 (Alyx's). Anything else is named.
    if (fmt != VK_FORMAT_D32_SFLOAT && fmt != VK_FORMAT_D32_SFLOAT_S8_UINT) {
        if (said_skip < 4) { said_skip++;
            fprintf(stderr, "  [swim] eye %d depth format %u is not D32/D32S8 — not copied\n",
                    eye, (unsigned)fmt); }
        return 0;
    }
    __typeof__(V.depth[0][0]) *slot = &V.depth[eye][stage];
    if (!slot->img || slot->w != rw || slot->h != rh || slot->fmt != (uint32_t)fmt) {
        // Re-created on a size change and the old one left allocated: the
        // compositor may be sampling it this instant (the colour path's
        // native images make the same choice). With a fixed fidelity level
        // there is one size for the whole run.
        uint64_t im = kl_vulkan_xr_image(rw, rh, 1, 1, (long long)fmt, 2);
        void *mtl = im ? kl_vulkan_xr_image_mtl(im) : NULL;
        if (!im || !mtl) {
            if (said_skip < 4) { said_skip++;
                fprintf(stderr, "  [swim] eye %d stage %d: could not create/export a %ux%u depth "
                                "image (fmt %u)\n", eye, stage, rw, rh, (unsigned)fmt); }
            return 0;
        }
        slot->img = im; slot->mtl = mtl; slot->w = rw; slot->h = rh; slot->fmt = (uint32_t)fmt;
        kl_glfb_note_eye_mtl_depth(eye, stage, mtl, (int)rw, (int)rh);
        static int said;
        if (said < 2 * OVR_STAGES) { said++;
            fprintf(stderr, "  [swim] eye %d stage %d: depth copy %ux%u fmt %u (layer %u of the "
                            "game's %ux%u depth)\n", eye, stage, rw, rh, (unsigned)fmt, ds->layer,
                    dt->m_nWidth, dt->m_nHeight); }
    }
    VkImage src = (VkImage)(uintptr_t)dt->m_nImage, dst = (VkImage)(uintptr_t)slot->img;
    VkImageMemoryBarrier bar[2] = {
        { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
          .srcAccessMask = VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
          .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT, .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
          .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
          .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = src,
          .subresourceRange = { all, 0, 1, ds->layer, 1 } },
        { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .srcAccessMask = 0,
          .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
          .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
          .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = dst,
          .subresourceRange = { all, 0, 1, 0, 1 } },
    };
    V.CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, NULL, 0, NULL, 2, bar);
    VkImageCopy reg = { .srcSubresource = { VK_IMAGE_ASPECT_DEPTH_BIT, 0, ds->layer, 1 },
                        .srcOffset = { x0, y0, 0 },
                        .dstSubresource = { VK_IMAGE_ASPECT_DEPTH_BIT, 0, 0, 1 },
                        .extent = { rw, rh, 1 } };
    V.CmdCopyImage(cb, src, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, dst,
                   VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &reg);
    VkImageMemoryBarrier done = bar[1];
    done.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    done.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    done.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    done.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    V.CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                         0, 0, NULL, 0, NULL, 1, &done);
    return 1;
}

static int vk_copy_eye(int eye, int stage, const VRVulkanTextureData_t *t, const VRTextureBounds_t *b,
                       uint32_t layer, ovr_depth_src *ds) {
    if (vk_setup(t) != 0) return -1;
    int32_t x0 = 0, y0 = 0, x1 = (int32_t)t->m_nWidth, y1 = (int32_t)t->m_nHeight;
    if (b) {
        x0 = (int32_t)(b->uMin * t->m_nWidth); x1 = (int32_t)(b->uMax * t->m_nWidth);
        y0 = (int32_t)(fminf(b->vMin, b->vMax) * t->m_nHeight);
        y1 = (int32_t)(fmaxf(b->vMin, b->vMax) * t->m_nHeight);
    }
    // vMin > vMax is OpenVR's way of saying "flipped vertically" (a GL-style
    // bottom-up image); the blit flips it back by reading the rows reversed.
    int vflip = b && b->vMin > b->vMax;
    // The stage images are one fixed size — the render target size we
    // recommend — and whatever the guest submits is BLITTED to fill them. Alyx
    // renders at a dynamic resolution and alternates between textures of
    // different sizes (2688x2880 and 1728x1824 on consecutive frames), and
    // sizing the stage images to the submission re-created and re-exported
    // them every frame.
    uint32_t w, h;
    eye_size(&w, &h);
    if (!w || !h || x1 <= x0 || y1 <= y0) return -1;
    // KL_OPENVR_STAGE_SCALE=0 (KL_OPENVR_MINIMAL): no rescale. The stage image
    // is exactly the rendered rect, copied 1:1, and the compositor slot is
    // pointed at it for this frame — the picture reaches the compositor with
    // the game's own pixel grid. Falls back to the scaled stage (said once) if
    // the game cycles through more sizes than the cache holds.
    static int scale = -1;
    if (scale < 0) scale = ovr_stage("KL_OPENVR_STAGE_SCALE", 1);
    VkImage native_dst = VK_NULL_HANDLE;
    if (!scale) {
        uint32_t rw = (uint32_t)(x1 - x0), rh = (uint32_t)(y1 - y0);
        int k = 0;
        for (; k < 4; k++) {
            if (!V.native[eye][stage][k].img) break;
            if (V.native[eye][stage][k].w == rw && V.native[eye][stage][k].h == rh &&
                V.native[eye][stage][k].fmt == t->m_nFormat) break;
        }
        if (k < 4 && !V.native[eye][stage][k].img) {
            uint64_t im = kl_vulkan_xr_image(rw, rh, 1, 1, (long long)t->m_nFormat, 0);
            void *mtl = im ? kl_vulkan_xr_image_mtl(im) : NULL;
            if (im && mtl) {
                V.native[eye][stage][k].w = rw; V.native[eye][stage][k].h = rh;
                V.native[eye][stage][k].fmt = t->m_nFormat;
                V.native[eye][stage][k].img = im; V.native[eye][stage][k].mtl = mtl;
                static int said;
                if (said < 12) { said++;
                    fprintf(stderr, "  [openvr] eye %d stage %d: native %ux%u stage image (no rescale, "
                                    "KL_OPENVR_STAGE_SCALE=0), size %d of 4\n", eye, stage, rw, rh, k + 1); }
            } else k = 4;
        }
        if (k < 4) {
            native_dst = (VkImage)(uintptr_t)V.native[eye][stage][k].img;
            kl_glfb_note_eye_mtl_texture(eye, stage, V.native[eye][stage][k].mtl, 0, (int)rw, (int)rh);
            V.in_place[eye][stage] = 1;   // the slot is not V.dst's: re-point it if scaling resumes
            w = rw; h = rh;
        } else {
            static int said;
            if (!said++) fprintf(stderr, "  [openvr] native stage: more than 4 render sizes — "
                                         "falling back to the scaled stage\n");
        }
    }
    if (!native_dst && (V.w[eye] != w || V.h[eye] != h || V.fmt[eye] != t->m_nFormat)) {
        for (int k = 0; k < OVR_STAGES; k++) {
            V.dst[eye][k] = kl_vulkan_xr_image(w, h, 1, 1, (long long)t->m_nFormat, 0);
            void *mtl = kl_vulkan_xr_image_mtl(V.dst[eye][k]);
            V.mtl[eye][k] = mtl;
            V.in_place[eye][k] = 0;
            if (mtl) kl_glfb_note_eye_mtl_texture(eye, k, mtl, 0, (int)w, (int)h);
        }
        V.w[eye] = w; V.h[eye] = h; V.fmt[eye] = t->m_nFormat;
        fprintf(stderr, "  [openvr] eye %d: %ux%u fmt %u — %d stage image(s) exported to the compositor\n",
                eye, w, h, t->m_nFormat, OVR_STAGES);
    }
    // A slot the zero-copy path last pointed at the game's image: point it back
    // at ours, or the compositor keeps sampling the game's (see above).
    if (!native_dst && V.in_place[eye][stage]) {
        V.in_place[eye][stage] = 0;
        if (V.mtl[eye][stage]) kl_glfb_note_eye_mtl_texture(eye, stage, V.mtl[eye][stage], 0, (int)w, (int)h);
    }
    VkImage src = (VkImage)(uintptr_t)t->m_nImage, dst = (VkImage)(uintptr_t)V.dst[eye][stage];
    if (native_dst) dst = native_dst;
    if (!dst) return -1;
    V.WaitForFences(V.dev, 1, &V.fence[eye][stage], VK_TRUE, UINT64_MAX);
    V.ResetFences(V.dev, 1, &V.fence[eye][stage]);
    VkCommandBuffer cb = V.cb[eye][stage];
    V.ResetCommandBuffer(cb, 0);
    VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    V.BeginCommandBuffer(cb, &bi);
    VkImageSubresourceRange rng = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
    VkImageSubresourceRange srng = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, layer, 1 };
    VkImageMemoryBarrier bar[2] = {
        { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT,
          .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT, .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
          .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
          .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = src, .subresourceRange = srng },
        { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .srcAccessMask = 0,
          .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
          .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
          .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = dst, .subresourceRange = rng },
    };
    V.CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, NULL, 0, NULL, 2, bar);
    if (!vflip && x0 == 0 && y0 == 0 && (uint32_t)x1 == w && (uint32_t)y1 == h &&
        t->m_nWidth == w && t->m_nHeight == h) {
        VkImageCopy reg = { .srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, layer, 1 },
                            .dstSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
                            .extent = { w, h, 1 } };
        V.CmdCopyImage(cb, src, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, dst,
                       VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &reg);
    } else {
        VkImageBlit reg = { .srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, layer, 1 },
                            .srcOffsets = { { x0, vflip ? y1 : y0, 0 }, { x1, vflip ? y0 : y1, 1 } },
                            .dstSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
                            .dstOffsets = { { 0, 0, 0 }, { (int32_t)w, (int32_t)h, 1 } } };
        V.CmdBlitImage(cb, src, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, dst,
                       VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &reg, VK_FILTER_LINEAR);
    }
    VkImageMemoryBarrier done = bar[1];
    done.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    done.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    done.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    done.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    V.CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                         0, 0, NULL, 0, NULL, 1, &done);
    if (ds && ds->t) ds->ok = vk_record_depth(cb, eye, stage, ds, x0, y0, x1, y1, vflip);
    V.EndCommandBuffer(cb);
    VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
    V.QueueSubmit(V.q, 1, &si, V.fence[eye][stage]);
    // The compositor samples this image the moment the frame is filed, so it
    // has to be complete by then. One small copy; waiting is the honest answer.
    V.WaitForFences(V.dev, 1, &V.fence[eye][stage], VK_TRUE, UINT64_MAX);
    if (g_frames_for_dump == (unsigned long long)kl_env_int("KL_OPENVR_DUMP_AT", 300) && getenv("KL_OPENVR_DUMP")) {
        char nm[32];
        snprintf(nm, sizeof nm, "eye%d_src", eye);
        vk_dump(t, src, layer, t->m_nWidth, t->m_nHeight, nm);
        snprintf(nm, sizeof nm, "eye%d_dst", eye);
        vk_dump(t, dst, 0, w, h, nm);
        if (ds && ds->ok) {
            snprintf(nm, sizeof nm, "eye%d_depth", eye);
            vk_dump_depth(t, (VkImage)(uintptr_t)V.depth[eye][stage].img,
                          V.depth[eye][stage].w, V.depth[eye][stage].h, nm);
        }
    }
    return 0;
}
#endif

static unsigned g_submitted_mask;
static int g_stage;
// Submit flags that change what the texture handle points at.
#define SUBMIT_TEXTURE_WITH_POSE   0x08     // Texture_t is a VRTextureWithPose_t (same handle)
#define SUBMIT_VULKAN_ARRAY_DATA   0x40     // handle is a VRVulkanTextureArrayData_t
// VRVulkanTextureArrayData_t: the texture data plus which layer of an array
// image this eye is. Alyx renders both eyes into ONE two-layer image and
// submits it twice with this flag — layer 0 left, layer 1 right — with full
// bounds. Ignoring the flag copied layer 0 into both eyes: two identical
// pictures shown with two different eye poses, which reads as wrong depth and
// a shifted, cropped image in a headset (and is invisible in a one-eye viewer).
typedef struct { VRVulkanTextureData_t t; uint32_t m_unArrayIndex, m_unArraySize; } VRVulkanTextureArrayData_t;

static int co_submit_impl(int eye, const Texture_t *tex, const VRTextureBounds_t *b, int flags,
                          int layer_override) {
    static int seen;
    if (seen++ < 6) {
        const VRVulkanTextureData_t *vt = tex && tex->eType == 2 ? tex->handle : NULL;
        fprintf(stderr, "  [openvr] Submit(eye %d, type %d, color %d, flags %#x%s) texture %ux%u fmt %u, "
                        "bounds u %.3f..%.3f v %.3f..%.3f\n", eye,
                tex ? tex->eType : -1, tex ? (int)tex->eColorSpace : -1, flags,
                vt && (flags & SUBMIT_VULKAN_ARRAY_DATA) ? " array" : "",
                vt ? vt->m_nWidth : 0, vt ? vt->m_nHeight : 0, vt ? vt->m_nFormat : 0,
                b ? b->uMin : 0.f, b ? b->uMax : 1.f, b ? b->vMin : 0.f, b ? b->vMax : 1.f);
    }
    if (eye < 0 || eye > 1 || !tex || !tex->handle) return 101;          // InvalidTexture
    if (tex->eType != 2) {
        static int said;
        if (!said++) fprintf(stderr, "  [openvr] Submit with texture type %d — only Vulkan (2) is served\n", tex->eType);
        return 101;
    }
    // Submit_TextureWithPose (0x08): the Texture_t is a VRTextureWithPose_t and
    // the HmdMatrix34_t at +16 is the pose the game says it rendered this eye's
    // picture with — the ground truth KL_OPENVR_POSE_TRACE holds the declared
    // pose against. Eye 0's is the frame's (both eyes are one head).
    if ((flags & SUBMIT_TEXTURE_WITH_POSE) && eye == 0 && pose_trace_on()) {
        TrackedDevicePose_t sp;
        memset(&sp, 0, sizeof sp);
        memcpy(&sp.mDeviceToAbsoluteTracking, (const uint8_t *)tex + 16, sizeof sp.mDeviceToAbsoluteTracking);
        pose_trace_note(PT_SUBMIT, &sp);
    }
#ifdef KLOVR_VULKAN
    // Submit_TextureWithDepth (0x10, part of Alyx's 0x258 = TextureWithMotion):
    // the Texture_t is a VRTextureWithPoseAndDepth_t, whose depth info carries
    // the PROJECTION the picture was actually rendered with. Alyx does not render
    // exactly the frustum GetProjectionRaw describes (on device it renders
    // 4608x2880 for a 3072x2465 recommendation — a wider field), so filing the
    // frame with our tangents stretched a wider picture into a narrower frustum:
    // an image that looks rotated/shifted, and an edge of whatever lies past
    // the rendered area. The frame's tangents come from that matrix instead
    // (KL_OPENVR_SUBMIT_PROJ=0 keeps ours). Layout, pack 8: Texture_t 16, pose
    // 48 at +16, depth { handle 8, HmdMatrix44 at +72, range } at +64.
    // What the depth the game hands us looks like (VRTextureDepthInfo_t at +64:
    // handle, mProjection at +72, vRange at +136) — the input positional
    // reprojection would need. Logged for the first frames, both eyes.
    if (flags & 0x10) {
        static int said;
        if (said < 4) {
            said++;
            const uint8_t *tb = (const uint8_t *)tex;
            const VRVulkanTextureData_t *dv = *(const VRVulkanTextureData_t *const *)(tb + 64);
            const float *pm = (const float *)(tb + 72), *rg = (const float *)(tb + 136);
            fprintf(stderr, "  [openvr] eye %d depth: handle %p", eye, (const void *)dv);
            if (dv) {
                fprintf(stderr, " image %#llx %ux%u fmt %u samples %u",
                        (unsigned long long)dv->m_nImage, dv->m_nWidth, dv->m_nHeight,
                        dv->m_nFormat, dv->m_nSampleCount);
                if (flags & SUBMIT_VULKAN_ARRAY_DATA)
                    fprintf(stderr, " layer %u of %u", ((const VRVulkanTextureArrayData_t *)dv)->m_unArrayIndex,
                            ((const VRVulkanTextureArrayData_t *)dv)->m_unArraySize);
            }
            fprintf(stderr, "; range %.4f..%.4f; projection row2 (%.5f %.5f %.5f %.5f) row3 (%.3f %.3f %.3f %.3f)\n",
                    (double)rg[0], (double)rg[1], (double)pm[8], (double)pm[9], (double)pm[10], (double)pm[11],
                    (double)pm[12], (double)pm[13], (double)pm[14], (double)pm[15]);
        }
    }
    if ((flags & 0x10) && ovr_stage("KL_OPENVR_SUBMIT_PROJ", 1)) {
        const float *m = (const float *)((const uint8_t *)tex + 72);     // row-major 4x4
        float m00 = m[0], m02 = m[2], m11 = m[5], m12 = m[6];
        if (m00 != 0.0f && m11 != 0.0f) {
            float rl = 2.0f / m00, sx = m02 * rl, bt = 2.0f / m11, sy = m12 * bt;
            float r = (sx + rl) * 0.5f, l = (sx - rl) * 0.5f, b2 = (sy + bt) * 0.5f, t2 = (sy - bt) * 0.5f;
            float tn[4] = { -l, r, b2, -t2 };                 // left, right, up, down; positive
            // Up is b, down is -t (see sys_proj_raw); a matrix built the other
            // way round shows up as both negative — flip it then.
            if (tn[2] < 0 && tn[3] < 0) { tn[2] = -tn[2]; tn[3] = -tn[3]; }
            static int said;
            if (said < 4) { said++;
                fprintf(stderr, "  [openvr] eye %d rendered with tangents l=%.4f r=%.4f u=%.4f d=%.4f "
                                "(we offered l=%.4f r=%.4f u=%.4f d=%.4f)\n", eye, tn[0], tn[1], tn[2], tn[3],
                        g_frame_tan[eye * 4 + 0], g_frame_tan[eye * 4 + 1],
                        g_frame_tan[eye * 4 + 2], g_frame_tan[eye * 4 + 3]); }
            if (tn[0] > 0 && tn[1] > 0 && tn[2] > 0 && tn[3] > 0)
                memcpy(g_frame_tan + eye * 4, tn, sizeof tn);
        }
    }
    uint32_t layer = layer_override >= 0 ? (uint32_t)layer_override : 0;
    if (layer_override < 0 && (flags & SUBMIT_VULKAN_ARRAY_DATA))
        layer = ((const VRVulkanTextureArrayData_t *)tex->handle)->m_unArrayIndex;
    {
        static int said;
        if (said < 4) { said++;
            fprintf(stderr, "  [openvr] eye %d <- array layer %u\n", eye, layer); }
        // How many distinct images the game rotates its eyes through — whether
        // the compositor could sample them in place (see the zero-copy path).
        // Distinct is not enough on its own: Alyx shows 2, one per render size,
        // and still repeats the same image on almost every frame. The count of
        // frames whose image differs from the previous frame's is the rotation.
        static uint64_t seen[8], last; static int nseen, reported, changed;
        uint64_t im = ((const VRVulkanTextureData_t *)tex->handle)->m_nImage;
        int k = 0;
        while (k < nseen && seen[k] != im) k++;
        if (k == nseen && nseen < 8) seen[nseen++] = im;
        if (g_submitted_mask == 0) { changed += im != last; last = im; }
        if (!reported && g_frames >= 600) {
            reported = 1;
            fprintf(stderr, "  [openvr] the game's eye images: %d distinct over 600 frames, a "
                            "different one from the frame before on %d of them%s\n", nseen, changed,
                    changed < 540 ? " — it renders into one image, not a rotation" : "");
        }
    }
    // KL_REPROJECT_DEPTH_MODE=2: the depth Submit_TextureWithDepth carries,
    // copied beside the colour (vk_record_depth) and its projection filed with
    // the frame. Nothing here runs in any other mode — not even the read.
    ovr_depth_src dsrc = { NULL, 0, 0 }, *dsp = NULL;
    float dm22 = 0, dm23 = 0, drange[2] = { 0, 1 };
    int want_depth = kl_reproject_depth_mode() == 2;
    if (want_depth && (flags & 0x10)) {
        const uint8_t *tb = (const uint8_t *)tex;
        const VRVulkanTextureData_t *dv = *(const VRVulkanTextureData_t *const *)(tb + 64);
        const float *pm = (const float *)(tb + 72), *rg = (const float *)(tb + 136);
        dm22 = pm[10]; dm23 = pm[11]; drange[0] = rg[0]; drange[1] = rg[1];
        if (dv) {
            dsrc.t = dv;
            dsrc.layer = (flags & SUBMIT_VULKAN_ARRAY_DATA)
                ? ((const VRVulkanTextureArrayData_t *)dv)->m_unArrayIndex : layer;
            dsp = &dsrc;
        }
    } else if (want_depth) {
        static int said;
        if (!said++) fprintf(stderr, "  [swim] KL_REPROJECT_DEPTH_MODE=2 but Submit carries no depth "
                                     "(flags %#x lack 0x10) — mode 1 behaviour\n", flags);
    }
    const VRVulkanTextureData_t *vtd = (const VRVulkanTextureData_t *)tex->handle;
    int zc_ok = zc_frame_ok(g_submitted_mask == 0, vtd->m_nImage);
    if (vk_zero_copy_eye(eye, g_stage, vtd, b, layer, zc_ok,
                         (g_submitted_mask | (1u << eye)) == 3) != 0 &&
        vk_copy_eye(eye, g_stage, (const VRVulkanTextureData_t *)tex->handle, b, layer, dsp) != 0) return 101;
    if (want_depth) kl_ovrp_frame_set_depth(eye, dm22, dm23, drange[0], drange[1], dsrc.ok);
#else
    (void)b;
    return 101;
#endif
    g_submitted_mask |= 1u << eye;
    if (g_submitted_mask == 3) {
        // Both eyes in: file the frame through the same seams an OpenXR frame
        // uses, with the pose and frusta it was drawn with.
        kl_ovrp_frame_end_external(g_stage, g_frame_pose, g_frame_tan);
        pose_trace_report(g_frame_pose);
        ft_submitted();
        kl_gpu_time_frame_end();            // KL_GPU_TIME; returns at once when unset
#ifdef KLOVR_VULKAN
        g_frames_for_dump++;
#endif
        kl_vulkan_frame_done(g_stage);
        if (!g_frames++ || (g_frames & (g_frames - 1)) == 0)
            fprintf(stderr, "  [openvr] frame %llu submitted (stage %d)\n", g_frames - 1, g_stage);
        g_submitted_mask = 0;
        g_stage = (g_stage + 1) % OVR_STAGES;
    }
    return 0;
}
static int co_submit(void *s, int eye, const Texture_t *tex, const VRTextureBounds_t *b, int flags) {
    (void)s;
    return co_submit_impl(eye, tex, b, flags, -1);
}
static int co_submit_array(void *s, int eye, const Texture_t *tex, uint32_t idx, const VRTextureBounds_t *b, int flags) {
    (void)s;
    return co_submit_impl(eye, tex, b, flags, (int)idx);
}
static void co_void(void *s) { (void)s; }
// Fades and the grid are the compositor's to draw. SteamVR hides a level load
// and Alyx's "press to start" gate behind them; without them the player sees
// the stale start screen or the paused, half-started level. Each request is
// filed with kl_ovrp (kl_ovrp_fade_to / kl_ovrp_grid_to, one CLOCK_MONOTONIC
// clock) and the frontend's compositor draws the current colour head-locked
// over the scene (KleptonHUD.swift, kl_view_mtl.m). A BACKGROUND fade colours
// what SteamVR shows behind a scene that is not submitting — never over it —
// so it is only remembered and answered back. The grid is drawn as black.
// KL_OPENVR_FADE=0: the old behaviour — nothing drawn, every read fully clear.
// Typed, because a float or an HmdColor_t comes back in s0-s3 and a generic
// stub leaves those as garbage.
typedef struct { float r, g, b, a; } HmdColor_t;
static HmdColor_t g_fade_bg;
static int fade_on(void) {
    static int on = -1;
    if (on < 0) {
        on = kl_env_on("KL_OPENVR_FADE", 1);
        fprintf(stderr, "  [openvr] compositor fades %s (KL_OPENVR_FADE)\n", on ? "ON" : "off");
    }
    return on;
}
static HmdColor_t co_fade_color(void *s, int background) {
    (void)s;
    if (!fade_on()) return (HmdColor_t){ 0, 0, 0, 0 };
    if (background & 0xff) return g_fade_bg;
    float c[4];
    kl_ovrp_fade_current(c);
    return (HmdColor_t){ c[0], c[1], c[2], c[3] };
}
static float co_grid_alpha(void *s) { (void)s; return fade_on() ? kl_ovrp_grid_alpha() : 0.0f; }
static void co_fade_to(void *s, float t, float r, float g, float b, float a, int bg) {
    (void)s;
    bg &= 0xff;                                   // a C++ bool: only the low byte is defined
    static float last[6] = { -1, -1, -1, -1, -1, -1 };
    float cur[6] = { r, g, b, a, t, (float)bg };
    if (memcmp(cur, last, sizeof cur)) {           // once per change, not per frame
        memcpy(last, cur, sizeof cur);
        fprintf(stderr, "  [openvr] fade -> %.2f %.2f %.2f %.2f over %.2f s%s%s\n",
                r, g, b, a, t, bg ? " (background)" : "", fade_on() ? "" : " (ignored, KL_OPENVR_FADE=0)");
    }
    if (!fade_on()) return;
    if (bg) { g_fade_bg = (HmdColor_t){ r, g, b, a }; return; }
    kl_ovrp_fade_to(r, g, b, a, t);
}
static void co_fade_grid(void *s, float t, int in) {
    (void)s;
    in &= 0xff;
    static int last = -1;
    if (in != last) {
        last = in;
        fprintf(stderr, "  [openvr] fade grid %s over %.2f s%s\n", in ? "IN" : "out", t,
                fade_on() ? "" : " (ignored, KL_OPENVR_FADE=0)");
    }
    if (fade_on()) kl_ovrp_grid_to(in ? 1.0f : 0.0f, t);
}
static void co_suspend(void *s, int on) {
    (void)s;
    TRACE("SuspendRendering(%d)\n", on);
}
static int co_false(void *s) { (void)s; return 0; }
static int co_true(void *s) { (void)s; return 1; }
static float co_time_remaining(void *s) { (void)s; return 0.005f; }
static uint32_t co_vk_inst_ext(void *s, char *buf, uint32_t n) { (void)s; if (buf && n) buf[0] = 0; return 1; }
static uint32_t co_vk_dev_ext(void *s, void *pd, char *buf, uint32_t n) { (void)s; (void)pd; if (buf && n) buf[0] = 0; return 1; }
// The scene focus belongs to us: libvr compares this with its own pid, and 0
// (no scene app) reads as "another app has focus".
static uint32_t co_focus_process(void *s) { (void)s; return (uint32_t)getpid(); }

// ---- IVRInput ------------------------------------------------------------------------------------
//
// Alyx's action set is fixed (hlvr/cfg/actions.json) and SteamVR's binding UI
// does not exist here, so each action is bound by NAME to the Touch-style
// inputs kl_ovrp holds — exactly as the game's own Oculus Touch bindings
// (hlvr/cfg/bindings_touch.json) bind them, which is what its prompts, tutorials
// and the "press <button> to start" gate after every load assume:
//
//   trigger (either)    TriggerPull (pull), MenuInteract, MenuDismiss, Use, GGLock
//   grip (either)       HandCurl (pull), Use, GGLock
//   X / A (lower)       HealthPen, ToggleLaserSight, ArmGrenade, ArmXenGrenade,
//                       SqueezeXenGrenade; right A: EjectClip, OpenChamber
//   right B (upper)     Reload, ReleaseSlide, AltFire, ToggleBurstFire
//   right trigger       Fire
//   left Y / Start      ToggleMenu
//   left stick          Teleport (any direction), TeleportTurn (position),
//                       Walk / AdjustHeight (click)
//   right stick         TurnLeft / TurnRight / WalkMantle (north) /
//                       ShiftDashJump + MoveBack (south), ContinuousTurn
//                       (position), ShowInventory (click)
//   either stick        Scroll (position)
//   poses / skeletons   HandPose* / HandSkeleton* — the controller
//
// The table this replaced was written "in the spirit of" those bindings before
// the file was at hand, and differed where it mattered: MenuDismiss — the
// action behind Alyx's "Pulsa <origin> para empezar" gate after a load — was on
// B/Y, so the trigger the prompt (and every player) reaches for did nothing, the
// level never started, and the hands stayed dead until the pause menu. (The
// trigger alone was not enough: the guest patch alyx-startup-no-pause also kept
// the level from pausing behind its gate, the state MenuDismiss is read in —
// disabled 2026-10-07, see kl_guestpatch.c and KL_OPENVR_GATE_TRACE below.)
// KL_OPENVR_LEGACY_BINDINGS=1 is not offered: the old table has no basis.
//
// A handle carries what it was bound to, so the per-frame reads are a switch.
enum { SRC_NONE, SRC_TRIGGER, SRC_GRIP, SRC_LOWER, SRC_UPPER, SRC_STICK, SRC_STICK_Y,
       SRC_STICK_X, SRC_STICK_UP, SRC_STICK_DOWN, SRC_STICK_LEFT, SRC_STICK_RIGHT,
       SRC_STICK_CLICK, SRC_MENU, SRC_POSE, SRC_SKELETON, SRC_HAPTIC,
       SRC_TRIGGER_OR_GRIP, SRC_STICK_ANY };
typedef struct { const char *suffix; int src; int hand; } bind;     // hand: -1 either, 0 L, 1 R
static const bind k_bind[] = {
    // /actions/default
    { "/in/TriggerPull", SRC_TRIGGER, -1 }, { "/in/HandCurl", SRC_GRIP, -1 },
    { "/in/HandPoseLeft", SRC_POSE, 0 }, { "/in/HandPoseRight", SRC_POSE, 1 },
    { "/in/HandSkeletonLeft", SRC_SKELETON, 0 }, { "/in/HandSkeletonRight", SRC_SKELETON, 1 },
    { "/in/HapticVibration", SRC_HAPTIC, -1 },
    // /actions/dev
    { "/in/ToggleMenu", SRC_MENU, -1 },
    { "/in/MenuInteract", SRC_TRIGGER, -1 }, { "/in/MenuDismiss", SRC_TRIGGER, -1 },
    // /actions/interact
    { "/in/Use", SRC_TRIGGER_OR_GRIP, -1 }, { "/in/UseGrip", SRC_GRIP, -1 },
    { "/in/GGLock", SRC_TRIGGER_OR_GRIP, -1 },
    { "/in/HealthPen", SRC_LOWER, -1 }, { "/in/ToggleLaserSight", SRC_LOWER, -1 },
    { "/in/ArmGrenade", SRC_LOWER, -1 }, { "/in/ArmXenGrenade", SRC_LOWER, -1 },
    { "/in/SqueezeXenGrenade", SRC_LOWER, -1 },
    // /actions/weapon
    { "/in/Fire", SRC_TRIGGER, 1 },
    { "/in/ShowInventory", SRC_STICK_CLICK, 1 },
    { "/in/Reload", SRC_UPPER, 1 }, { "/in/ReleaseSlide", SRC_UPPER, 1 },
    { "/in/AltFire", SRC_UPPER, 1 }, { "/in/ToggleBurstFire", SRC_UPPER, 1 },
    { "/in/EjectClip", SRC_LOWER, 1 }, { "/in/OpenChamber", SRC_LOWER, 1 },
    // /actions/move
    { "/in/Teleport", SRC_STICK_ANY, 0 }, { "/in/TeleportTurn", SRC_STICK, 0 },
    { "/in/Walk", SRC_STICK_CLICK, 0 }, { "/in/AdjustHeight", SRC_STICK_CLICK, 0 },
    { "/in/TurnLeft", SRC_STICK_LEFT, 1 }, { "/in/TurnRight", SRC_STICK_RIGHT, 1 },
    { "/in/WalkMantle", SRC_STICK_UP, 1 }, { "/in/ShiftDashJump", SRC_STICK_DOWN, 1 },
    { "/in/MoveBack", SRC_STICK_DOWN, 1 }, { "/in/ContinuousTurn", SRC_STICK, 1 },
    // /actions/scroll
    { "/in/Scroll", SRC_STICK, -1 },
};

#define MAX_ACTIONS 256
// prev/cur/seen per restriction (any, left, right): bChanged is "since the
// previous UpdateActionState", not "since the previous read", so the state a
// read compares against is the one latched at the last update. Per-read made a
// press read as changed on every call once the guest asked for both hands.
typedef struct { char name[128]; int src, hand; int prev[3], cur[3]; unsigned seen[3]; int polled; } action;
static unsigned g_update_n;
static action g_actions[MAX_ACTIONS];
static int g_nactions;
static char g_sets[32][96];
static int g_nsets;
static pthread_mutex_t g_imu = PTHREAD_MUTEX_INITIALIZER;
static float g_input_time;

#define H_SOURCE_LEFT  1
#define H_SOURCE_RIGHT 2
#define H_SOURCE_HEAD  3

// KL_OPENVR_INPUT_TRACE=1: once every 5 s, how many times each IVRInput call
// was made since the last report and the action sets the last
// UpdateActionState activated — the "what does the game ask for in play" view.
enum { IT_UPDATE, IT_DIGITAL, IT_ANALOG, IT_POSE_NOW, IT_POSE_NEXT, IT_SKEL, IT_BONE_COUNT,
       IT_BONE_DATA, IT_BONE_REF, IT_BONE_HIER, IT_SUMMARY, IT_ORIGINS, IT_TRACK_LEVEL, IT_N };
static const char *const k_it_name[IT_N] = {
    "UpdateActionState", "GetDigitalActionData", "GetAnalogActionData", "GetPoseActionDataRelativeToNow",
    "GetPoseActionDataForNextFrame", "GetSkeletalActionData", "GetBoneCount", "GetSkeletalBoneData",
    "GetSkeletalReferenceTransforms", "GetBoneHierarchy", "GetSkeletalSummaryData", "GetActionOrigins",
    "GetSkeletalTrackingLevel"
};
static _Atomic unsigned g_it_count[IT_N];
static char g_it_sets[256];
static int input_trace_on(void) {
    static int on = -1;
    if (on < 0) on = kl_env_on("KL_OPENVR_INPUT_TRACE", 0);
    return on;
}
#define IN_NOTE(k) do { if (input_trace_on()) atomic_fetch_add(&g_it_count[k], 1); } while (0)
static void input_trace_report(float now) {
    static float t0;
    if (!input_trace_on()) return;
    if (!t0) t0 = now;
    if (now - t0 < 5.0f) return;
    t0 = now;
    fprintf(stderr, "  [openvr] input calls over 5 s (sets: %s):", g_it_sets);
    for (int i = 0; i < IT_N; i++) {
        unsigned c = atomic_exchange(&g_it_count[i], 0);
        if (c) fprintf(stderr, " %s %u", k_it_name[i], c);
    }
    fprintf(stderr, "\n");
}

static int in_manifest(void *s, const char *p) {
    (void)s;
    fprintf(stderr, "  [openvr] action manifest %s — bindings are the built-in Touch table\n", p ? p : "(null)");
    return 0;
}
static int in_set_handle(void *s, const char *name, uint64_t *h) {
    (void)s;
    pthread_mutex_lock(&g_imu);
    int i = 0;
    for (; i < g_nsets; i++) if (!strcasecmp(g_sets[i], name)) break;
    if (i == g_nsets && g_nsets < 32) snprintf(g_sets[g_nsets++], sizeof g_sets[0], "%s", name);
    pthread_mutex_unlock(&g_imu);
    *h = 0x1000 + (uint64_t)i;
    return 0;
}
static int in_action_handle(void *s, const char *name, uint64_t *h) {
    (void)s;
    pthread_mutex_lock(&g_imu);
    int i = 0;
    for (; i < g_nactions; i++) if (!strcasecmp(g_actions[i].name, name)) break;
    if (i == g_nactions && g_nactions < MAX_ACTIONS) {
        action *a = &g_actions[g_nactions++];
        snprintf(a->name, sizeof a->name, "%s", name);
        a->src = SRC_NONE; a->hand = -1;
        size_t nl = strlen(name);
        for (size_t k = 0; k < sizeof k_bind / sizeof *k_bind; k++) {
            size_t sl = strlen(k_bind[k].suffix);
            if (nl >= sl && !strcasecmp(name + nl - sl, k_bind[k].suffix)) {
                a->src = k_bind[k].src; a->hand = k_bind[k].hand; break;
            }
        }
        TRACE("action %s -> source %d, hand %d\n", name, a->src, a->hand);
        if (a->src == SRC_NONE) fprintf(stderr, "  [openvr] action %s has no binding (reads inactive)\n", name);
    }
    pthread_mutex_unlock(&g_imu);
    *h = 0x2000 + (uint64_t)i;
    return 0;
}
static int in_source_handle(void *s, const char *path, uint64_t *h) {
    (void)s;
    *h = !strcmp(path, "/user/hand/left") ? H_SOURCE_LEFT : !strcmp(path, "/user/hand/right") ? H_SOURCE_RIGHT
       : !strcmp(path, "/user/head") ? H_SOURCE_HEAD : 0x100 + (uint64_t)(strlen(path) & 0xff);
    return 0;
}
static void skel_advance(float now);
static void alyx_gate_trace(void);
static int in_update(void *s, const VRActiveActionSet_t *sets, uint32_t size, uint32_t n) {
    (void)s;
    g_update_n++;
    alyx_gate_trace();
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    g_input_time = (float)t.tv_sec + (float)t.tv_nsec * 1e-9f;
    skel_advance(g_input_time);
    IN_NOTE(IT_UPDATE);
    if (input_trace_on() && sets && size >= sizeof *sets) {
        char buf[256]; size_t o = 0;
        buf[0] = 0;
        for (uint32_t i = 0; i < n && o + 2 < sizeof buf; i++) {
            const VRActiveActionSet_t *a = (const VRActiveActionSet_t *)((const uint8_t *)sets + (size_t)i * size);
            uint64_t k = a->ulActionSet - 0x1000;
            int w = snprintf(buf + o, sizeof buf - o, "%s%s", i ? "," : "",
                             k < (uint64_t)g_nsets ? g_sets[k] : "?");
            if (w > 0) o += (size_t)w;
            if (a->ulRestrictedToDevice) {
                w = snprintf(buf + o, sizeof buf - o, "[dev %llu]", (unsigned long long)a->ulRestrictedToDevice);
                if (w > 0 && o + (size_t)w < sizeof buf) o += (size_t)w;
            }
        }
        memcpy(g_it_sets, buf, sizeof g_it_sets < sizeof buf ? sizeof g_it_sets : sizeof buf);
        g_it_sets[sizeof g_it_sets - 1] = 0;
    }
    input_trace_report(g_input_time);
    return 0;
}
static action *act_of(uint64_t h) {
    uint64_t i = h - 0x2000;
    return (h >= 0x2000 && i < (uint64_t)g_nactions) ? &g_actions[i] : NULL;
}
// One hand's value for a source: digital (on) and analog (x, y).
static void read_src(int src, int hand, int *on, float *x, float *y) {
    uint32_t b = 0, t = 0; float trig = 0, grip = 0, sx = 0, sy = 0;
    kl_ovrp_controller_input(hand, &b, &t, &trig, &grip, &sx, &sy);
    *on = 0; *x = 0; *y = 0;
    int right = hand == 1;
    switch (src) {
    case SRC_TRIGGER: *x = trig; *on = trig > 0.5f; break;
    case SRC_GRIP:    *x = grip; *on = grip > 0.5f; break;
    case SRC_LOWER:   *on = (b & (right ? KL_OVRP_RAW_A : KL_OVRP_RAW_X)) != 0; *x = (float)*on; break;
    case SRC_UPPER:   *on = (b & (right ? KL_OVRP_RAW_B : KL_OVRP_RAW_Y)) != 0; *x = (float)*on; break;
    case SRC_STICK:   *x = sx; *y = sy; *on = fabsf(sx) > 0.3f || fabsf(sy) > 0.3f; break;
    case SRC_STICK_X: *x = sx; *on = fabsf(sx) > 0.5f; break;
    case SRC_STICK_Y: *x = sy; *y = sy; *on = fabsf(sy) > 0.5f; break;
    case SRC_STICK_UP:    *on = sy > 0.7f; *x = (float)*on; break;
    case SRC_STICK_DOWN:  *on = sy < -0.7f; *x = (float)*on; break;
    case SRC_STICK_LEFT:  *on = sx < -0.7f; *x = (float)*on; break;
    case SRC_STICK_RIGHT: *on = sx > 0.7f; *x = (float)*on; break;
    case SRC_STICK_CLICK: *on = (b & (right ? KL_OVRP_RAW_RTHUMBSTICK : KL_OVRP_RAW_LTHUMBSTICK)) != 0; *x = (float)*on; break;
    case SRC_MENU:    *on = (b & KL_OVRP_RAW_START) != 0 || (!right && (b & KL_OVRP_RAW_Y)); *x = (float)*on; break;
    case SRC_TRIGGER_OR_GRIP: *x = fmaxf(trig, grip); *on = trig > 0.5f || grip > 0.5f; break;
    case SRC_STICK_ANY: *on = sx * sx + sy * sy > 0.49f; *x = (float)*on; break;
    default: break;
    }
}
// IVRSystem::GetControllerState — the legacy input path, which Alyx still
// polls (outside its action sets, e.g. for "Press Trigger To Start" while a
// level loads). VRControllerState_t: packet number, pressed and touched masks
// by EVRButtonId, and five axes; axis 0 the stick, axis 1 the trigger, axis 2
// the grip, which is where a Touch controller's driver reports them.
typedef struct { float x, y; } VRControllerAxis_t;
typedef struct __attribute__((packed, aligned(4))) {
    uint32_t unPacketNum; uint64_t ulButtonPressed, ulButtonTouched; VRControllerAxis_t rAxis[5];
} VRControllerState_t;
static int sys_controller_state(void *s, uint32_t dev, VRControllerState_t *st, uint32_t size) {
    (void)s;
    if (!st || size < sizeof *st || (dev != DEV_LEFT && dev != DEV_RIGHT)) return 0;
    int hand = dev == DEV_RIGHT;
    uint32_t b = 0, t = 0; float trig = 0, grip = 0, sx = 0, sy = 0;
    if (!kl_ovrp_controller_input(hand, &b, &t, &trig, &grip, &sx, &sy)) return 0;
    static uint32_t packet;
    memset(st, 0, sizeof *st);
    st->unPacketNum = ++packet;
    uint64_t p = 0;
    if (b & KL_OVRP_RAW_START) p |= 1ull << 1;                                  // ApplicationMenu
    if (grip > 0.5f) p |= 1ull << 2 | 1ull << 34;                              // Grip, Axis2
    if (b & (hand ? KL_OVRP_RAW_A : KL_OVRP_RAW_X)) p |= 1ull << 7;             // A
    if (b & (hand ? KL_OVRP_RAW_B : KL_OVRP_RAW_Y)) p |= 1ull << 1;             // B/Y as the menu button
    if (b & (hand ? KL_OVRP_RAW_RTHUMBSTICK : KL_OVRP_RAW_LTHUMBSTICK)) p |= 1ull << 32;
    if (trig > 0.5f) p |= 1ull << 33;                                          // Axis1 = trigger
    st->ulButtonPressed = p;
    st->ulButtonTouched = p;
    st->rAxis[0] = (VRControllerAxis_t){ sx, sy };
    st->rAxis[1].x = trig;
    st->rAxis[2].x = grip;
    return 1;
}

// Which hands an action reads: the restriction the guest asked for, else the
// binding's own hand, else both (OR / larger magnitude).
static int hands_for(const action *a, uint64_t restrict_to, int out[2]) {
    // A one-handed binding asked about the other hand: nothing is bound there.
    if (a->hand >= 0 && ((restrict_to == H_SOURCE_LEFT && a->hand != 0) ||
                         (restrict_to == H_SOURCE_RIGHT && a->hand != 1))) { out[0] = a->hand; return 0; }
    if (restrict_to == H_SOURCE_LEFT) { out[0] = 0; return 1; }
    if (restrict_to == H_SOURCE_RIGHT) { out[0] = 1; return 1; }
    if (a->hand >= 0) { out[0] = a->hand; return 1; }
    out[0] = 0; out[1] = 1; return 2;
}
static int in_digital(void *s, uint64_t h, uint8_t *d, uint32_t size, uint64_t restrict_to) {
    IN_NOTE(IT_DIGITAL);
    (void)s;
    if (!d || size < 24) return 4;
    memset(d, 0, 24);
    action *a = act_of(h);
    if (!a) return 3;
    if (a->src == SRC_NONE || a->src == SRC_POSE || a->src == SRC_SKELETON || a->src == SRC_HAPTIC) return 0;
    int hs[2], n = hands_for(a, restrict_to, hs), on = 0, src_hand = hs[0];
    for (int i = 0; i < n; i++) {
        int o; float x, y;
        read_src(a->src, hs[i], &o, &x, &y);
        if (o && !on) { on = 1; src_hand = hs[i]; }
    }
    int slot = restrict_to == H_SOURCE_RIGHT ? 2 : restrict_to == H_SOURCE_LEFT ? 1 : 0;
    d[0] = n > 0;                                                     // bActive: bound on that hand
    uint64_t origin = src_hand ? H_SOURCE_RIGHT : H_SOURCE_LEFT;
    memcpy(d + 8, &origin, 8);
    d[16] = (uint8_t)on;
    if (a->seen[slot] != g_update_n) {               // first read since an update
        a->prev[slot] = a->cur[slot];
        a->seen[slot] = g_update_n;
    }
    a->cur[slot] = on;
    d[17] = (uint8_t)(on != a->prev[slot]);
    float ut = 0; memcpy(d + 20, &ut, 4);
    if (!a->polled || (d[17] && kl_env_on("KL_TRACE_OPENVR", 0))) {
        a->polled = 1;
        TRACE("digital %s%s: state %d changed %d\n", a->name,
              restrict_to == H_SOURCE_LEFT ? " (left)" : restrict_to == H_SOURCE_RIGHT ? " (right)" : "",
              d[16], d[17]);
    }
    return 0;
}
static int in_analog(void *s, uint64_t h, uint8_t *d, uint32_t size, uint64_t restrict_to) {
    IN_NOTE(IT_ANALOG);
    (void)s;
    if (!d || size < 48) return 4;
    memset(d, 0, 48);
    action *a = act_of(h);
    if (!a) return 3;
    if (a->src == SRC_NONE || a->src == SRC_POSE || a->src == SRC_SKELETON || a->src == SRC_HAPTIC) return 0;
    int hs[2], n = hands_for(a, restrict_to, hs), src_hand = hs[0];
    float bx = 0, by = 0;
    for (int i = 0; i < n; i++) {
        int o; float x, y;
        read_src(a->src, hs[i], &o, &x, &y);
        if (fabsf(x) + fabsf(y) > fabsf(bx) + fabsf(by)) { bx = x; by = y; src_hand = hs[i]; }
    }
    d[0] = n > 0;
    uint64_t origin = src_hand ? H_SOURCE_RIGHT : H_SOURCE_LEFT;
    memcpy(d + 8, &origin, 8);
    memcpy(d + 16, &bx, 4); memcpy(d + 20, &by, 4);
    return 0;
}
static int pose_data(uint64_t h, int origin, uint8_t *d, uint32_t size, uint64_t restrict_to) {
    if (!d || size < 96) return 4;
    memset(d, 0, 96);
    action *a = act_of(h);
    if (!a) return 3;
    int hand = restrict_to == H_SOURCE_LEFT ? 0 : restrict_to == H_SOURCE_RIGHT ? 1 : a->hand;
    // A skeleton action is a pose action too: SteamVR answers it with the
    // skeleton's base pose (/pose/raw for a Touch), and Alyx asks for its
    // in-game hands exactly that way — GetPoseActionDataRelativeToNow on
    // HandSkeletonLeft/Right, the HandPose actions being the menus'. Answering
    // only SRC_POSE left the in-game hand inactive (no hand, nothing to grab).
    int skel = a->src == SRC_SKELETON && kl_env_on("KL_OPENVR_SKELETON", 1);
    if (!a->polled) {
        a->polled = 1;
        fprintf(stderr, "  [openvr] pose data asked of %s (restricted to %llu): %s\n", a->name,
                (unsigned long long)restrict_to,
                (a->src == SRC_POSE || skel) && hand >= 0 ? "answered with the controller pose" : "INACTIVE");
    }
    if ((a->src != SRC_POSE && !skel) || hand < 0) return 0;
    int saved = g_origin;
    g_origin = origin;
    TrackedDevicePose_t p;
    device_pose(hand ? DEV_RIGHT : DEV_LEFT, &p);
    g_origin = saved;
    d[0] = 1;
    uint64_t o = hand ? H_SOURCE_RIGHT : H_SOURCE_LEFT;
    memcpy(d + 8, &o, 8);
    memcpy(d + 16, &p, sizeof p);
    return 0;
}
static int in_pose_now(void *s, uint64_t h, int origin, float secs, uint8_t *d, uint32_t size, uint64_t r) {
    IN_NOTE(IT_POSE_NOW);
    (void)s; (void)secs; return pose_data(h, origin, d, size, r);
}
static int in_pose_next(void *s, uint64_t h, int origin, uint8_t *d, uint32_t size, uint64_t r) {
    IN_NOTE(IT_POSE_NEXT);
    (void)s; return pose_data(h, origin, d, size, r);
}
// ---- skeletal input: a Touch hand, animated from trigger, grip and touches ----
// Half-Life: Alyx draws and animates the player's hands IN GAME from
// /actions/default/in/HandSkeletonLeft/Right (bindings_touch.json binds them to
// /user/hand/*/input/skeleton/*) — the finger curls, and whether there is a hand
// to draw at all. The pause menu and the main menu draw from the pose actions
// alone, which is why hands worked there and nowhere else. This bridge used to
// answer the skeleton as INACTIVE (bActive 0) with no bones (GetBoneCount and
// GetSkeletalBoneData -> NoData): in game no hand appeared, nothing could be
// grabbed, and a hand left over from the menu stayed frozen where it was (ALVR
// documents the same "frozen hand" for a skeleton component never fed).
//
// Now the skeleton is what SteamVR's Oculus driver serves for a Touch
// (EVRSkeletalTrackingLevel Partial): SteamVR's 31-bone hand, rooted at the
// controller's /pose/raw (the pose Alyx's HandPose actions bind, so the two
// agree), animated between ALVR's measured Touch poses — kl_openvr_hand.h —
// by the thumb touch, the index trigger (touch, then pull) and the grip.
// KL_OPENVR_SKELETON=0 restores the old inactive answer, the A/B.
#include "kl_openvr_hand.h"

// EVRSkeletalTransformSpace / EVRSkeletalMotionRange / EVRSkeletalReferencePose
enum { SK_MODEL = 0, SK_PARENT = 1 };
enum { SK_WITH_CONTROLLER = 0, SK_WITHOUT_CONTROLLER = 1 };
enum { SK_BIND = 0, SK_OPEN = 1, SK_FIST = 2, SK_GRIP_LIMIT = 3 };
static const int8_t k_bone_parent[KLOVR_BONES] = {
    -1, 0,  1, 2, 3, 4,  1, 6, 7, 8, 9,  1, 11, 12, 13, 14,  1, 16, 17, 18, 19,
     1, 21, 22, 23, 24,  0, 0, 0, 0, 0
};
static const char *const k_bone_name[KLOVR_BONES] = {
    "Root", "Wrist", "Thumb0", "Thumb1", "Thumb2", "Thumb3",
    "IndexFinger0", "IndexFinger1", "IndexFinger2", "IndexFinger3", "IndexFinger4",
    "MiddleFinger0", "MiddleFinger1", "MiddleFinger2", "MiddleFinger3", "MiddleFinger4",
    "RingFinger0", "RingFinger1", "RingFinger2", "RingFinger3", "RingFinger4",
    "PinkyFinger0", "PinkyFinger1", "PinkyFinger2", "PinkyFinger3", "PinkyFinger4",
    "Aux_Thumb", "Aux_IndexFinger", "Aux_MiddleFinger", "Aux_RingFinger", "Aux_PinkyFinger"
};
static int skeleton_on(void) {
    static int on = -1;
    if (on < 0) {
        on = kl_env_on("KL_OPENVR_SKELETON", 1);
        fprintf(stderr, "  [openvr] hand skeleton: %s (KL_OPENVR_SKELETON)\n",
                on ? "active, 31 bones animated from trigger/grip/touches (Touch, partial tracking)"
                   : "INACTIVE (no bones) — in-game hands will not appear");
    }
    return on;
}
// The skeleton's hand: 0/1 from the action's binding (HandSkeletonLeft/Right).
static int skel_hand(uint64_t h) {
    action *a = act_of(h);
    if (!a || a->src != SRC_SKELETON) return -1;
    return a->hand;
}
static void bone_lerp(klovr_bone *o, const klovr_bone *a, const klovr_bone *b, float t) {
    for (int i = 0; i < 3; i++) o->p[i] = a->p[i] + (b->p[i] - a->p[i]) * t;
    o->p[3] = 1.0f;
    float d = 0, q[4];
    for (int i = 0; i < 4; i++) d += a->q[i] * b->q[i];
    float sgn = d < 0 ? -1.0f : 1.0f;
    d = fabsf(d);
    float wa, wb;
    if (d > 0.9995f) { wa = 1.0f - t; wb = t; }
    else {
        float th = acosf(d), st = sinf(th);
        wa = sinf((1.0f - t) * th) / st; wb = sinf(t * th) / st;
    }
    float n = 0;
    for (int i = 0; i < 4; i++) { q[i] = a->q[i] * wa + b->q[i] * wb * sgn; n += q[i] * q[i]; }
    n = n > 0 ? 1.0f / sqrtf(n) : 1.0f;
    for (int i = 0; i < 4; i++) o->q[i] = q[i] * n;
}
// Per-hand animation state, advanced once per UpdateActionState: touches ease
// in and out over ~60 ms as a Touch driver's do, so a finger lifting off a
// button moves rather than teleports.
static struct { float thumb, index; float t; } g_skel_anim[2];
static void skel_inputs(int hand, int *thumb_touch, int *index_touch, float *trig, float *grip) {
    uint32_t b = 0, t = 0; float tr = 0, gr = 0, sx = 0, sy = 0;
    kl_ovrp_controller_input(hand, &b, &t, &tr, &gr, &sx, &sy);
    uint32_t face = hand ? (KL_OVRP_RAW_A | KL_OVRP_RAW_B | KL_OVRP_RAW_RTHUMBSTICK)
                         : (KL_OVRP_RAW_X | KL_OVRP_RAW_Y | KL_OVRP_RAW_LTHUMBSTICK);
    *thumb_touch = ((t | b) & face) != 0 || fabsf(sx) > 0.1f || fabsf(sy) > 0.1f;
    *index_touch = (t & (hand ? KL_OVRP_RAW_RINDEX_TRIGGER : KL_OVRP_RAW_LINDEX_TRIGGER)) != 0 || tr > 0.02f;
    *trig = tr < 0 ? 0 : tr > 1 ? 1 : tr;
    *grip = gr < 0 ? 0 : gr > 1 ? 1 : gr;
}
static void skel_advance(float now) {
    for (int h = 0; h < 2; h++) {
        int tt, it; float tr, gr;
        skel_inputs(h, &tt, &it, &tr, &gr);
        float dt = g_skel_anim[h].t > 0 ? now - g_skel_anim[h].t : 1.0f;
        if (!(dt >= 0) || dt > 1.0f) dt = 1.0f;
        float k = 1.0f - expf(-dt / 0.06f);
        g_skel_anim[h].thumb += ((float)tt - g_skel_anim[h].thumb) * k;
        g_skel_anim[h].index += ((float)it - g_skel_anim[h].index) * k;
        g_skel_anim[h].t = now;
    }
}
// The hand in PARENT space — ALVR's Controller::GetBoneTransform, with the
// touch animation progress from g_skel_anim.
static void skel_parent(int hand, int with_controller, klovr_bone out[KLOVR_BONES]) {
    int left = hand == 0, tt, it; float trig, grip;
    skel_inputs(hand, &tt, &it, &trig, &grip);
    float thumb_p = g_skel_anim[hand & 1].thumb, index_p = g_skel_anim[hand & 1].index;
    klovr_bone a[KLOVR_BONES], b[KLOVR_BONES];
    memset(a, 0, sizeof a); memset(b, 0, sizeof b);
    out[0] = (klovr_bone){ { 0, 0, 0, 1 }, { 1, 0, 0, 0 } };
    out[1] = left ? (klovr_bone){ { -0.034038f, 0.036503f, 0.164722f, 1 }, { -0.055147f, -0.078608f, -0.920279f, 0.379296f } }
                  : (klovr_bone){ {  0.034038f, 0.036503f, 0.164722f, 1 }, { -0.055147f, -0.078608f,  0.920279f, -0.379296f } };
    klovr_GetThumbBoneTransform(with_controller, left, 0, a);
    klovr_GetThumbBoneTransform(with_controller, left, 1, b);
    for (int i = 2; i < 6; i++) bone_lerp(&out[i], &a[i], &b[i], thumb_p);
    if (trig > 0) {
        klovr_GetTriggerBoneTransform(with_controller, left, 1, 0, a);
        klovr_GetTriggerBoneTransform(with_controller, left, 1, 1, b);
        for (int i = 6; i < KLOVR_BONES; i++) bone_lerp(&out[i], &a[i], &b[i], trig);
    } else {
        klovr_GetTriggerBoneTransform(with_controller, left, 0, 0, a);
        klovr_GetTriggerBoneTransform(with_controller, left, 1, 0, b);
        for (int i = 6; i < KLOVR_BONES; i++) bone_lerp(&out[i], &a[i], &b[i], index_p);
    }
    if (grip > 0) {
        klovr_GetGripClickBoneTransform(with_controller, left, b);
        for (int i = 11; i < 26; i++) bone_lerp(&out[i], &out[i], &b[i], grip);
        for (int i = 28; i < KLOVR_BONES; i++) bone_lerp(&out[i], &out[i], &b[i], grip);
    }
}
// A reference pose: open = nothing touched or pulled, fist = everything
// curled (trigger and grip clicked, thumb down), bind = the open hand.
static void skel_reference(int hand, int pose, klovr_bone out[KLOVR_BONES]) {
    int left = hand == 0;
    klovr_bone a[KLOVR_BONES];
    memset(a, 0, sizeof a);
    out[0] = (klovr_bone){ { 0, 0, 0, 1 }, { 1, 0, 0, 0 } };
    out[1] = left ? (klovr_bone){ { -0.034038f, 0.036503f, 0.164722f, 1 }, { -0.055147f, -0.078608f, -0.920279f, 0.379296f } }
                  : (klovr_bone){ {  0.034038f, 0.036503f, 0.164722f, 1 }, { -0.055147f, -0.078608f,  0.920279f, -0.379296f } };
    int fist = pose == SK_FIST || pose == SK_GRIP_LIMIT;
    klovr_GetThumbBoneTransform(0, left, fist, out);
    klovr_GetTriggerBoneTransform(0, left, fist, fist, out);
    if (fist) {
        klovr_GetGripClickBoneTransform(0, left, a);
        for (int i = 11; i < 26; i++) out[i] = a[i];
        for (int i = 28; i < KLOVR_BONES; i++) out[i] = a[i];
    }
}
// Parent space -> model space (relative to the root): compose down the chain.
// The aux bones hang off the root, so they are the same in both.
static void skel_to_model(klovr_bone b[KLOVR_BONES]) {
    for (int i = 1; i < KLOVR_BONES; i++) {
        int pi = k_bone_parent[i];
        if (pi <= 0) continue;                       // root's children: root is identity
        const klovr_bone *pb = &b[pi];
        // (w, x, y, z) -> (x, y, z, w) for the helpers
        float pq[4] = { pb->q[1], pb->q[2], pb->q[3], pb->q[0] };
        float lq[4] = { b[i].q[1], b[i].q[2], b[i].q[3], b[i].q[0] }, oq[4], op[3];
        quat_rotate(pq, b[i].p, op);
        quat_mul(pq, lq, oq);
        for (int k = 0; k < 3; k++) b[i].p[k] = pb->p[k] + op[k];
        b[i].q[0] = oq[3]; b[i].q[1] = oq[0]; b[i].q[2] = oq[1]; b[i].q[3] = oq[2];
    }
}
// GetSkeletalActionData(action, InputSkeletalActionData_t *, size): bActive,
// activeOrigin.
static int in_skeletal(void *s, uint64_t h, uint8_t *d, uint32_t size) {
    IN_NOTE(IT_SKEL);
    (void)s;
    if (!d || size < 16) return 4;
    memset(d, 0, 16);
    action *a = act_of(h);
    if (!a) return 3;
    int hand = skel_hand(h);
    if (hand < 0 || !skeleton_on()) return 0;
    d[0] = 1;
    uint64_t o = hand ? H_SOURCE_RIGHT : H_SOURCE_LEFT;
    memcpy(d + 8, &o, 8);
    return 0;
}
static int in_bone_count(void *s, uint64_t h, uint32_t *n) {
    IN_NOTE(IT_BONE_COUNT);
    (void)s;
    if (!n) return 4;
    *n = 0;
    if (skel_hand(h) < 0 || !skeleton_on()) return 13;               // NoData
    *n = KLOVR_BONES;
    return 0;
}
static int in_bone_hierarchy(void *s, uint64_t h, int32_t *out, uint32_t n) {
    IN_NOTE(IT_BONE_HIER);
    (void)s;
    if (skel_hand(h) < 0 || !skeleton_on()) return 13;
    if (!out || n < KLOVR_BONES) return 4;                           // InvalidParam (size mismatch)
    for (int i = 0; i < KLOVR_BONES; i++) out[i] = k_bone_parent[i];
    return 0;
}
static int in_bone_name(void *s, uint64_t h, int32_t bone, char *buf, uint32_t n) {
    (void)s;
    if (skel_hand(h) < 0 || !skeleton_on()) return 13;
    if (bone < 0 || bone >= KLOVR_BONES) return 4;
    const char *v = k_bone_name[bone];
    if (!buf || n < strlen(v) + 1) return 14;
    memcpy(buf, v, strlen(v) + 1);
    return 0;
}
static int in_skel_reference(void *s, uint64_t h, int space, int pose, klovr_bone *out, uint32_t n) {
    IN_NOTE(IT_BONE_REF);
    (void)s;
    int hand = skel_hand(h);
    if (hand < 0 || !skeleton_on()) return 13;
    prop_note("GetSkeletalReferenceTransforms(hand,space*10+pose)", (uint32_t)hand, space * 10 + pose, 1);
    if (!out || n != KLOVR_BONES) return 4;
    skel_reference(hand, pose, out);
    if (space == SK_MODEL) skel_to_model(out);
    return 0;
}
static int in_bone_data(void *s, uint64_t h, int space, int range, klovr_bone *out, uint32_t n) {
    IN_NOTE(IT_BONE_DATA);
    (void)s;
    int hand = skel_hand(h);
    if (hand < 0 || !skeleton_on()) return 13;
    if (!out || n != KLOVR_BONES) {
        static int said;
        if (said++ < 4) fprintf(stderr, "  [openvr] GetSkeletalBoneData asked for %u bones (we have %d)\n", n, KLOVR_BONES);
        return 4;
    }
    skel_parent(hand, range != SK_WITHOUT_CONTROLLER, out);
    if (space == SK_MODEL) skel_to_model(out);
    static int said;
    if (!said++)
        fprintf(stderr, "  [openvr] GetSkeletalBoneData: first answer (hand %d, %s space, %s)\n", hand,
                space == SK_MODEL ? "model" : "parent", range == SK_WITHOUT_CONTROLLER ? "without controller" : "with controller");
    return 0;
}
static int in_dominant(void *s, int *role) { (void)s; if (role) *role = 2; return 0; }
static int in_no_data(void *s) { (void)s; return 13; }                 // VRInputError_NoData
static int in_tracking_level(void *s, uint64_t h, int *lvl) {
    IN_NOTE(IT_TRACK_LEVEL);      // Partial: a Touch
    (void)s; if (lvl) *lvl = skel_hand(h) >= 0 && skeleton_on() ? 1 : 0; return 0;
}
static int in_summary(void *s, uint64_t h, int type, float *out) {
    IN_NOTE(IT_SUMMARY);
    (void)s; (void)type;
    action *a = act_of(h);
    if (!out) return 4;
    memset(out, 0, 9 * sizeof(float));
    if (!a || a->hand < 0) return 0;
    uint32_t b, t; float trig, grip, sx, sy;
    kl_ovrp_controller_input(a->hand, &b, &t, &trig, &grip, &sx, &sy);
    out[0] = (t & (a->hand ? KL_OVRP_RAW_A | KL_OVRP_RAW_B : KL_OVRP_RAW_X | KL_OVRP_RAW_Y)) ? 0.5f : 0.0f; // thumb
    out[1] = trig;                                                       // index
    out[2] = out[3] = out[4] = grip;                                     // middle, ring, pinky
    return 0;
}
static int in_haptic(void *s, uint64_t h, float start, float dur, float freq, float amp, uint64_t restrict_to) {
    (void)s; (void)h; (void)start; (void)freq;
    int hand = restrict_to == H_SOURCE_LEFT ? 0 : restrict_to == H_SOURCE_RIGHT ? 1 : -1;
    if (hand < 0) { kl_ovrp_haptics_apply(0, amp, dur); hand = 1; }
    kl_ovrp_haptics_apply(hand, amp, dur);
    return 0;
}
static int in_false(void *s) { (void)s; return 0; }
// Where an action is bound. Measured on the Mac (KL_TRACE_OPENVR=1): Alyx
// registers every action, calls GetActionOrigins / GetOriginLocalizedName /
// GetBindingVariant, and then never calls GetDigitalActionData at all — while
// those three were logging stubs returning None with the out-array left
// zeroed, i.e. "bound to nothing" (k_ulInvalidInputValueHandle). The origins
// are the hand source handles the action reads from.
// The ORIGINS of an action — what a game names in a prompt ("press <origin> to
// start") and looks up with GetOriginLocalizedName. SteamVR answers one origin
// per bound input COMPONENT ("/user/hand/left/input/trigger"), named by hand,
// controller and button; this bridge answered the hand itself, so Alyx's
// post-load gate read "Pulsa Left Hand para empezar" and named no button at
// all. Origins are now (hand, source) handles, named for the PS VR2 Sense
// buttons the frontend maps onto the Touch layout (KleptonControllers).
#define H_ORIGIN_BASE 0x10000000ull
static uint64_t origin_handle(int hand, int src) { return H_ORIGIN_BASE + (uint64_t)hand * 0x100 + (uint64_t)src; }
static int origin_decode(uint64_t o, int *hand, int *src) {
    if (o == H_SOURCE_LEFT || o == H_SOURCE_RIGHT) { *hand = o == H_SOURCE_RIGHT; *src = SRC_NONE; return 1; }
    if (o < H_ORIGIN_BASE || o >= H_ORIGIN_BASE + 0x200) return 0;
    *hand = (int)((o - H_ORIGIN_BASE) >> 8); *src = (int)((o - H_ORIGIN_BASE) & 0xff);
    return 1;
}
static const char *origin_input_name(int hand, int src) {
    switch (src) {
    case SRC_TRIGGER: return "Trigger";
    case SRC_GRIP: return "Grip";
    case SRC_TRIGGER_OR_GRIP: return "Trigger";
    case SRC_LOWER: return hand ? "Cross Button" : "Square Button";
    case SRC_UPPER: return hand ? "Circle Button" : "Triangle Button";
    case SRC_MENU: return hand ? "Options Button" : "Create Button";
    case SRC_STICK_CLICK: return "Stick Click";
    case SRC_STICK: case SRC_STICK_X: case SRC_STICK_Y: case SRC_STICK_ANY:
    case SRC_STICK_UP: case SRC_STICK_DOWN: case SRC_STICK_LEFT: case SRC_STICK_RIGHT: return "Stick";
    default: return NULL;
    }
}
static int in_origins(void *s, uint64_t set, uint64_t h, uint64_t *out, uint32_t n) {
    IN_NOTE(IT_ORIGINS);
    (void)s; (void)set;
    if (!out || !n) return 4;                                          // InvalidParam
    memset(out, 0, (size_t)n * sizeof *out);
    action *a = act_of(h);
    if (!a) return 3;                                                  // InvalidHandle
    uint32_t k = 0;
    if (a->src != SRC_NONE) {
        // Poses, skeletons and haptics keep the hand: there is no button.
        int comp = origin_input_name(1, a->src) != NULL;
        if (a->hand != 1 && k < n) out[k++] = comp ? origin_handle(0, a->src) : H_SOURCE_LEFT;
        if (a->hand != 0 && k < n) out[k++] = comp ? origin_handle(1, a->src) : H_SOURCE_RIGHT;
    }
    static int said;                       // called every frame for the skeletons
    if (said < 64) { said++; TRACE("GetActionOrigins %s -> %u origin(s)\n", a->name, k); }
    return 0;
}
// GetOriginLocalizedName(origin, buf, size, unStringSectionsToInclude):
// VRInputString_Hand 0x01, _ControllerType 0x02, _InputSource 0x04, All = -1.
static int in_origin_name(void *s, uint64_t origin, char *buf, uint32_t n, int32_t bits) {
    (void)s;
    char v[96];
    int hand = 0, src = SRC_NONE;
    if (origin == H_SOURCE_HEAD) snprintf(v, sizeof v, "Headset");
    else if (origin_decode(origin, &hand, &src)) {
        const char *in = origin_input_name(hand, src);
        if (bits == 0) bits = -1;
        size_t o = 0;
        v[0] = 0;
        if (bits & 0x01) o += (size_t)snprintf(v + o, sizeof v - o, "%s", hand ? "Right" : "Left");
        if ((bits & 0x02) && o < sizeof v)
            o += (size_t)snprintf(v + o, sizeof v - o, "%sSense", o ? " " : "");
        if ((bits & 0x04) && in && o < sizeof v)
            o += (size_t)snprintf(v + o, sizeof v - o, "%s%s", o ? " " : "", in);
        if (!in && o < sizeof v) o += (size_t)snprintf(v + o, sizeof v - o, "%sHand", o ? " " : "");
        if (!o) snprintf(v, sizeof v, "%s", in ? in : (hand ? "Right Hand" : "Left Hand"));
    } else return 3;
    static int said;
    if (said < 16) { said++; fprintf(stderr, "  [openvr] GetOriginLocalizedName(%#llx, sections %#x) -> \"%s\"\n",
                                     (unsigned long long)origin, (unsigned)bits, v); }
    if (!buf || n < strlen(v) + 1) return 14;                          // BufferTooSmall
    memcpy(buf, v, strlen(v) + 1);
    return 0;
}
typedef struct { uint64_t devicePath; uint32_t trackedDeviceIndex; char rchRenderModelComponentName[128]; } InputOriginInfo_t;
static int in_origin_info(void *s, uint64_t origin, InputOriginInfo_t *o, uint32_t size) {
    (void)s;
    if (!o || size < sizeof *o) return 4;
    memset(o, 0, size);
    int hand = 0, src = SRC_NONE;
    if (origin == H_SOURCE_HEAD) { o->devicePath = H_SOURCE_HEAD; o->trackedDeviceIndex = DEV_HMD; return 0; }
    if (!origin_decode(origin, &hand, &src)) return 3;
    o->devicePath = hand ? H_SOURCE_RIGHT : H_SOURCE_LEFT;
    o->trackedDeviceIndex = hand ? DEV_RIGHT : DEV_LEFT;
    const char *comp = src == SRC_TRIGGER || src == SRC_TRIGGER_OR_GRIP ? "trigger" : src == SRC_GRIP ? "grip"
                     : src == SRC_LOWER ? (hand ? "a" : "x") : src == SRC_UPPER ? (hand ? "b" : "y")
                     : src == SRC_MENU ? "menu" : origin_input_name(hand, src) ? "thumbstick" : "";
    snprintf(o->rchRenderModelComponentName, sizeof o->rchRenderModelComponentName, "%s", comp);
    return 0;
}
// No variant in the built-in bindings: the empty string, as SteamVR answers.
static int in_binding_variant(void *s, uint64_t dev, char *buf, uint32_t n) {
    (void)s; (void)dev;
    if (buf && n) buf[0] = 0;
    return 0;
}

// ---- IVRChaperone -------------------------------------------------------------------------------
static int ch_state(void *s) { (void)s; return 1; }                     // ChaperoneCalibrationState_OK
static int ch_size(void *s, float *x, float *z) { (void)s; if (x) *x = 2; if (z) *z = 2; return 1; }
static int ch_rect(void *s, float *q) {
    (void)s;
    static const float r[12] = { -1, 0, -1,  1, 0, -1,  1, 0, 1,  -1, 0, 1 };
    if (q) memcpy(q, r, sizeof r);
    return 1;
}

// ---- IVRSettings: every key reads as unset ---------------------------------------------------
static int st_get_bool(void *s, const char *sec, const char *k, int *err) { (void)s; (void)sec; (void)k; if (err) *err = 2; return 0; }
static float st_get_float(void *s, const char *sec, const char *k, int *err) { (void)s; (void)sec; (void)k; if (err) *err = 2; return 0; }
static void st_get_string(void *s, const char *sec, const char *k, char *buf, uint32_t n, int *err) {
    (void)s; (void)sec; (void)k; if (buf && n) buf[0] = 0; if (err) *err = 2;
}

// ---- IVRMailbox: SteamVR's message bus, private ------------------------------------------------
// The layout, from libvr.so (CVr owns the object at +0x800):
//   #0 RegisterMailbox(name, &handle) -> error     (0x95b38, the handle at +0x250)
//   #1 UndoRegisterMailbox(handle)                  (0xb610c)
//   #2 SendMessage(handle, address, json) -> error  (0x98be8)
//   #3 ReadMessage(handle, buf, size, &needed) -> error: 0 a message, 2 the
//      buffer is short (resized to needed and read again), anything else none
//      (0xb579c, polled every frame)
// Messages are JSON dispatched on "type". Half-Life: Alyx registers
// "hlvr/mailbox", waits for {"type":"ready"} from the SteamVR web helper that
// hosts its VR menu ("Mongoose"), and 15 s without one is a message box and
// exit ("Timed out waiting for response from Mongoose"). There is no web
// helper here, so every mailbox is told "ready" once, on its first read; what
// the game sends back is logged and dropped.
#define MBOX_MAX 8
static struct { char name[96]; int told; } g_mbox[MBOX_MAX];
static int g_nmbox;
static pthread_mutex_t g_mbmu = PTHREAD_MUTEX_INITIALIZER;
static int mb_register(void *s, const char *name, uint64_t *h) {
    (void)s;
    pthread_mutex_lock(&g_mbmu);
    int i = g_nmbox < MBOX_MAX ? g_nmbox++ : -1;
    if (i >= 0) { snprintf(g_mbox[i].name, sizeof g_mbox[i].name, "%s", name ? name : ""); g_mbox[i].told = 0; }
    pthread_mutex_unlock(&g_mbmu);
    fprintf(stderr, "  [openvr] IVRMailbox::RegisterMailbox(\"%s\") -> %d\n", name ? name : "", i + 1);
    if (i < 0) return 1;
    if (h) *h = (uint64_t)i + 1;
    return 0;
}
static int mb_unregister(void *s, uint64_t h) { (void)s; (void)h; return 0; }
// KL_GATE_TOAST (default off; =1 shows it): Alyx's interstitial messages carry the "press to
// start" gate — after each load it sends {"type": "show_message", "text":
// "Pulsa Trigger para empezar"} and, once the trigger unpauses the level,
// {"type": "end_loading"}. SteamVR's web helper draws that text; here the
// frontend shows a head-locked prompt (kl_ovrp_set_prompt) until end_loading
// (or the next begin_loading / hide_message).
static int mb_json_str(const char *msg, const char *key, char *out, size_t n) {
    char pat[64];
    snprintf(pat, sizeof pat, "\"%s\"", key);
    const char *p = msg ? strstr(msg, pat) : NULL;
    if (!p) return 0;
    p += strlen(pat);
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p++ != ':') return 0;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p++ != '"') return 0;
    size_t i = 0;
    while (*p && *p != '"' && i + 1 < n) {
        if (*p == '\\' && p[1]) p++;
        out[i++] = *p++;
    }
    out[i] = 0;
    return 1;
}
static void mb_gate_prompt(const char *addr, const char *msg) {
    static int on = -1;
    if (on < 0) on = kl_env_on("KL_GATE_TOAST", 0);
    if (!addr || strcmp(addr, "hlvr/interstitials")) return;
    char type[48], text[200];
    if (!mb_json_str(msg, "type", type, sizeof type)) return;
    // The grid (FadeGrid) is drawn only while a load is in progress: black over
    // the stale frame from begin_loading, revealed again at end_loading. Alyx
    // fades it in at boot and out only at a level's gate, so without this the
    // main menu (whose load ends without a gate) would stay black.
    if (fade_on()) {
        if (!strcmp(type, "begin_loading")) {
            fprintf(stderr, "  [openvr] load begins: grid drawn (alpha %.2f)\n", kl_ovrp_grid_alpha());
            kl_ovrp_grid_mask(1.0f, 0.0f);
        } else if (!strcmp(type, "end_loading") || !strcmp(type, "show_message")) {
            // show_message is the level's start gate: the load is done and the
            // paused level should be seen (as on SteamVR), not black until the
            // trigger — end_loading only comes after the unpause.
            fprintf(stderr, "  [openvr] load ends (%s): grid hidden over 0.5 s\n", type);
            kl_ovrp_grid_mask(0.0f, 0.5f);
        }
    }
    if (!on) return;
    if (!strcmp(type, "show_message")) {
        if (!mb_json_str(msg, "text", text, sizeof text) || !text[0]) snprintf(text, sizeof text, "-");
        fprintf(stderr, "  [openvr] gate prompt ON: \"%s\" (KL_GATE_TOAST)\n", text);
        kl_ovrp_set_prompt(text);
    } else if (!strcmp(type, "end_loading") || !strcmp(type, "begin_loading") || !strcmp(type, "hide_message")) {
        char cur[8];
        kl_ovrp_prompt(cur, sizeof cur);
        if (cur[0]) fprintf(stderr, "  [openvr] gate prompt off (%s)\n", type);
        kl_ovrp_set_prompt(NULL);
    }
}
static int mb_send(void *s, uint64_t h, const char *addr, const char *msg) {
    (void)s;
    static int n;
    if (n++ < 16)
        fprintf(stderr, "  [openvr] IVRMailbox::SendMessage(#%llu -> \"%s\"): %.200s\n",
                (unsigned long long)h, addr ? addr : "", msg ? msg : "");
    mb_gate_prompt(addr, msg);
    return 0;
}
static int mb_read(void *s, uint64_t h, char *buf, uint32_t size, uint32_t *needed) {
    (void)s;
    static const char ready[] = "{\"type\":\"ready\"}";
    if (h < 1 || h > MBOX_MAX) return 1;
    pthread_mutex_lock(&g_mbmu);
    int told = g_mbox[h - 1].told;
    pthread_mutex_unlock(&g_mbmu);
    if (told) return 1;
    if (needed) *needed = sizeof ready;
    if (!buf || size < sizeof ready) return 2;
    memcpy(buf, ready, sizeof ready);
    pthread_mutex_lock(&g_mbmu);
    g_mbox[h - 1].told = 1;
    pthread_mutex_unlock(&g_mbmu);
    fprintf(stderr, "  [openvr] IVRMailbox: told \"%s\" %s (no SteamVR web helper here)\n",
            g_mbox[h - 1].name, ready);
    return 0;
}

// ---- KL_OPENVR_GATE_TRACE: Alyx's "press to start" gate, read from libclient ----
// After every load Alyx holds the level behind an interstitial ("Pulsa <origin>
// para empezar") and only ends it — mailbox "end_loading", hands in, world
// sound up — when its menu controller says the level is live. Measured in
// hlvr/bin/linuxsteamrtarm64/libclient.so (build 10919):
//
//   menu controller   static object at 0x25872b0 + 0x60 (fn 0xf83200 returns it)
//     +0xa0  u32     a mode (2 = the per-frame input handler 0xf95ae8 is off)
//     +0xa4  u32     menu state (3 = loading gate, 7 = game menu)
//     +0x78  s32     "pause after N frames" countdown; -1 once pause/unpause ran
//   gate test 0xf83210: still loading while state is 0 or 3, or countdown >= 0
//   loading state     0x25e1bb0 + 0x610 (1 shown, 2 waiting, 3 ending -> end_loading)
//
// This prints those words whenever they change, so a run says which half of
// the test holds the gate shut. Read-only; the code word at 0xf83210 is checked
// first, so another build reads nothing.
static const uint8_t *alyx_client(void);
// KL_OPENVR_CMD_AT="<secs>:<command>[;<secs>:<command>...]" — a test harness:
// runs each console command on the game's own thread (through libclient's
// engine client, the call its menu makes for "setpause") once that many
// seconds have passed since the first UpdateActionState. For scripted Mac runs
// that need the menu's route (startup map, then "load <save>") with no hand on
// a laser pointer. Build 10919 only, like the trace.
static void alyx_cmd_at(void) {
    static int n = -1;
    static struct { float at; char cmd[96]; int done; } c[8];
    static double t0;
    if (n == 0) return;
    if (n < 0) {
        n = 0;
        const char *e = getenv("KL_OPENVR_CMD_AT");
        while (e && *e && n < 8) {
            char *end; float v = strtof(e, &end);
            if (end == e || *end != ':') break;
            const char *s = end + 1, *t = strchr(s, ';');
            size_t l = t ? (size_t)(t - s) : strlen(s);
            if (l >= sizeof c[0].cmd) l = sizeof c[0].cmd - 1;
            c[n].at = v; memcpy(c[n].cmd, s, l); c[n].cmd[l] = 0; c[n].done = 0; n++;
            e = t ? t + 1 : s + l;
        }
        struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
        t0 = (double)ts.tv_sec + ts.tv_nsec * 1e-9;
        if (!n) return;
    }
    const uint8_t *cl = alyx_client();
    if (!cl) return;
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    double now = (double)ts.tv_sec + ts.tv_nsec * 1e-9 - t0;
    for (int i = 0; i < n; i++) {
        if (c[i].done || now < c[i].at) continue;
        c[i].done = 1;
        void *eng; memcpy(&eng, cl + 0x26b94a8, sizeof eng);     // IVEngineClient * (0xf81c44)
        if (!eng) continue;
        void **vt = *(void ***)eng;
        void (*cmd)(void *, int, const char *, int, int) = (void (*)(void *, int, const char *, int, int))vt[0xd0 / 8];
        fprintf(stderr, "  [openvr] console at %.0f s: \"%s\" (KL_OPENVR_CMD_AT)\n", now, c[i].cmd);
        cmd(eng, 0, c[i].cmd, 0, 0);
    }
}

// kl_openvr_console: commands queued from any thread (the visionOS quick
// settings, Siri), run on the game's thread from in_update — the engine's
// console is not thread-safe, and the input update is where the game expects
// its own menu's commands. g_con_ready is published once libclient checks out
// (build 10919) and its engine client pointer is set; until then a command is
// refused rather than queued for a game that may never answer.
static pthread_mutex_t g_con_mu = PTHREAD_MUTEX_INITIALIZER;
static char g_con_q[8][128];
static _Atomic int g_con_n;
static _Atomic int g_con_ready;

int kl_openvr_console_ready(void) { return atomic_load(&g_con_ready); }

int kl_openvr_console(const char *cmd) {
    if (!cmd || !*cmd) return -1;
    if (!atomic_load(&g_con_ready)) {
        fprintf(stderr, "  [openvr] console: \"%s\" refused (no Alyx engine client yet)\n", cmd);
        return -1;
    }
    pthread_mutex_lock(&g_con_mu);
    int r = -2;
    if (g_con_n < 8) {
        snprintf(g_con_q[g_con_n], sizeof g_con_q[0], "%s", cmd);
        g_con_n++;
        r = 0;
    }
    pthread_mutex_unlock(&g_con_mu);
    fprintf(stderr, "  [openvr] console: \"%s\" %s\n", cmd, r ? "refused (queue full)" : "queued");
    return r;
}

// Game thread, every input update. Resolves the engine client at most once a
// second until it is found, then drains the queue.
static void alyx_console_drain(void) {
    static double next_try;
    static void *eng;
    if (!eng) {
        struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
        double now = (double)ts.tv_sec + ts.tv_nsec * 1e-9;
        if (now < next_try) return;
        next_try = now + 1.0;
        const uint8_t *cl = alyx_client();
        if (!cl) return;
        memcpy(&eng, cl + 0x26b94a8, sizeof eng);     // IVEngineClient * (0xf81c44)
        if (!eng) return;
        atomic_store(&g_con_ready, 1);
        fprintf(stderr, "  [openvr] console: Alyx engine client found; runtime commands available\n");
    }
    if (!g_con_n) return;           // racy peek; a command missed now runs next update
    char q[8][128];
    pthread_mutex_lock(&g_con_mu);
    int n = g_con_n;
    memcpy(q, g_con_q, sizeof q[0] * (size_t)n);
    g_con_n = 0;
    pthread_mutex_unlock(&g_con_mu);
    void **vt = *(void ***)eng;
    void (*cmd)(void *, int, const char *, int, int) = (void (*)(void *, int, const char *, int, int))vt[0xd0 / 8];
    for (int i = 0; i < n; i++) {
        fprintf(stderr, "  [openvr] console: running \"%s\"\n", q[i]);
        cmd(eng, 0, q[i], 0, 0);
    }
}

static const uint8_t *alyx_client(void) {
    static const uint8_t *cl;
    static int bad;
    if (cl || bad) return cl;
    kl_image *img = kl_find_image("libclient.so");
    const uint8_t *b = img ? (const uint8_t *)kl_base(img) : NULL;
    if (!b) return NULL;
    uint32_t w = 0;
    memcpy(&w, b + 0xf83210, 4);
    if (w != 0xaa0003e1u) {
        fprintf(stderr, "  [openvr] libclient.so is not build 10919 (0x%08x at 0xf83210): gate trace / console knobs off\n", w);
        bad = 1;
        return NULL;
    }
    return cl = b;
}

static void alyx_gate_trace(void) {
    static int on = -1;
    static const uint8_t *cl;
    static int32_t last[8];
    static int have;
    alyx_cmd_at();
    alyx_console_drain();
    if (on < 0) on = kl_env_on("KL_OPENVR_GATE_TRACE", 0);
    if (!on) return;
    if (!cl) {
        if (!(cl = alyx_client())) return;
        fprintf(stderr, "  [openvr] gate trace: libclient.so at %p (KL_OPENVR_GATE_TRACE)\n", (void *)cl);
    }
    const uint8_t *mc = cl + 0x25872b0 + 0x60, *ld = cl + 0x25e1bb0;
    int32_t v[8];
    memcpy(&v[0], mc + 0xa0, 4); memcpy(&v[1], mc + 0xa4, 4); memcpy(&v[2], mc + 0x78, 4);
    memcpy(&v[3], mc + 0x7c, 4); v[4] = mc[0x98]; memcpy(&v[5], ld + 0x610, 4);
    v[6] = mc[0x6f] | mc[0x70] << 8; v[7] = ld[0x608];
    if (have && !memcmp(v, last, sizeof v)) return;
    have = 1; memcpy(last, v, sizeof v);
    fprintf(stderr, "  [openvr] gate: mode(a0) %d state(a4) %d countdown(78) %d frames(7c) %d paused-by-countdown(98) %d"
                    " | loading %d sleeping %d | dismiss last L%d R%d -> %s\n",
            v[0], v[1], v[2], v[3], v[4], v[5], v[7], v[6] & 1, (v[6] >> 8) & 1,
            (v[1] == 0 || v[1] == 3 || v[2] >= 0) ? "GATE HELD" : "gate open");
}

// ---- IVRRenderModels: one invisible model for every name -----------------------
// Alyx asks for the controllers' render models once a level has STARTED:
// libvr's loader (0xb5080) reads Prop_RenderModelName_String (1003), asks
// GetComponentCount, and with no components loads the model itself —
// LoadRenderModel_Async, then LoadTexture_Async on the model's
// diffuseTextureId — and builds an engine mesh from the two (0xb4164). An
// answer of 0 with a NULL RenderModel_t * crashed it (libvr.so+0xb53bc reads
// +0x18 of the model); NotSupported (200) is survived, but the loader treats
// any error other than Loading (100) as a failure to retry, and logs "VR
// failure loading render model <name>: 200" every frame of play — 17661 lines
// in a two-minute Mac run, each a write to the log from the render loop.
//
// The game draws the hands itself (the controller is never shown in play), so
// what it is handed is the smallest thing the loader accepts: one triangle with
// all three corners at the origin (nothing to rasterize) and a 4x4 grey
// texture. Layouts are OpenVR's under `#pragma pack(push, 4)` (Linux), which
// libvr confirms: diffuseTextureId at +0x18 of RenderModel_t (natural alignment
// would put it at +0x1c), the texture's pixels at +4 of RenderModel_TextureMap_t
// (`ldur x3, [x21, #4]`, 0xb45c0), and a texture id <= 0 skips the texture.
// KL_OPENVR_RENDER_MODELS=0 restores the NotSupported answer — the A/B.
#define RM_NOT_SUPPORTED 200
#pragma pack(push, 4)
typedef struct { float pos[3], normal[3], uv[2]; } RenderModel_Vertex_t;
typedef struct {
    const RenderModel_Vertex_t *rVertexData; uint32_t unVertexCount;
    const uint16_t *rIndexData; uint32_t unTriangleCount; int32_t diffuseTextureId;
} RenderModel_t;
typedef struct {
    uint16_t unWidth, unHeight; const uint8_t *rubTextureMapData; int32_t format; uint16_t unMipLevels;
} RenderModel_TextureMap_t;
#pragma pack(pop)
_Static_assert(sizeof(RenderModel_Vertex_t) == 32, "RenderModel_Vertex_t");
_Static_assert(__builtin_offsetof(RenderModel_t, rIndexData) == 12, "RenderModel_t pack(4)");
_Static_assert(__builtin_offsetof(RenderModel_t, diffuseTextureId) == 24, "RenderModel_t pack(4)");
_Static_assert(sizeof(RenderModel_t) == 28, "RenderModel_t pack(4)");
_Static_assert(__builtin_offsetof(RenderModel_TextureMap_t, rubTextureMapData) == 4, "TextureMap pack(4)");
_Static_assert(__builtin_offsetof(RenderModel_TextureMap_t, format) == 12, "TextureMap pack(4)");
_Static_assert(sizeof(RenderModel_TextureMap_t) == 20, "TextureMap pack(4)");
#define RM_TEXTURE_ID 1
static const RenderModel_Vertex_t k_rm_verts[3] = {
    { { 0, 0, 0 }, { 0, 0, 1 }, { 0, 0 } }, { { 0, 0, 0 }, { 0, 0, 1 }, { 1, 0 } },
    { { 0, 0, 0 }, { 0, 0, 1 }, { 0, 1 } },
};
static const uint16_t k_rm_index[3] = { 0, 1, 2 };
// Filled at run time, not by an initializer: pack(4) puts a pointer at +12 /
// +4, and the linker refuses an unaligned pointer in static data ("pointer not
// aligned"), so the structs are written through memcpy'd fields instead.
static RenderModel_t g_rm_model;
static RenderModel_TextureMap_t g_rm_texture;

static const uint8_t k_rm_pixels[4 * 4 * 4] = {
#define RM_PX 0x80, 0x80, 0x80, 0xff
    RM_PX, RM_PX, RM_PX, RM_PX, RM_PX, RM_PX, RM_PX, RM_PX,
    RM_PX, RM_PX, RM_PX, RM_PX, RM_PX, RM_PX, RM_PX, RM_PX,
#undef RM_PX
};
static void rm_fill(void) {
    const RenderModel_Vertex_t *v = k_rm_verts; const uint16_t *ix = k_rm_index; const uint8_t *px = k_rm_pixels;
    uint32_t nv = 3, nt = 1; int32_t tid = RM_TEXTURE_ID, fmt = 0;   // EVRRenderModelTextureFormat RGBA8_SRGB
    uint16_t w = 4, h = 4, mips = 1;
    memcpy(&g_rm_model.rVertexData, &v, sizeof v);   memcpy(&g_rm_model.unVertexCount, &nv, 4);
    memcpy(&g_rm_model.rIndexData, &ix, sizeof ix);  memcpy(&g_rm_model.unTriangleCount, &nt, 4);
    memcpy(&g_rm_model.diffuseTextureId, &tid, 4);
    memcpy(&g_rm_texture.unWidth, &w, 2); memcpy(&g_rm_texture.unHeight, &h, 2);
    memcpy(&g_rm_texture.rubTextureMapData, &px, sizeof px);
    memcpy(&g_rm_texture.format, &fmt, 4); memcpy(&g_rm_texture.unMipLevels, &mips, 2);
}
static int rm_on(void) {
    static int on = -1;
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, rm_fill);
    if (on < 0) on = kl_env_on("KL_OPENVR_RENDER_MODELS", 1);
    return on;
}
static int rm_load_model(void *s, const char *name, void **out) {
    (void)s;
    static _Atomic int said;
    int on = rm_on();
    if (out) *out = on ? (void *)&g_rm_model : NULL;
    if (atomic_fetch_add(&said, 1) < 4)
        fprintf(stderr, "  [openvr] LoadRenderModel_Async(\"%s\") -> %s\n", name ? name : "",
                on ? "None: an empty model (one zero-area triangle; KL_OPENVR_RENDER_MODELS)"
                   : "NotSupported (KL_OPENVR_RENDER_MODELS=0)");
    return on ? 0 : RM_NOT_SUPPORTED;
}
static int rm_load_texture(void *s, int32_t id, void **out) {
    (void)s;
    int ok = rm_on() && id == RM_TEXTURE_ID;
    if (out) *out = ok ? (void *)&g_rm_texture : NULL;
    return ok ? 0 : RM_NOT_SUPPORTED;
}
// No components: the loader then takes the model whole (0xb51a8 -> 0xb5444).
static uint32_t rm_component_count(void *s, const char *name) { (void)s; (void)name; return 0; }
static uint32_t rm_component_name(void *s, const char *name, uint32_t i, char *buf, uint32_t n) {
    (void)s; (void)name; (void)i; if (buf && n) buf[0] = 0; return 0;
}
static uint64_t rm_component_mask(void *s, const char *name, const char *comp) { (void)s; (void)name; (void)comp; return 0; }
static uint32_t rm_component_model(void *s, const char *name, const char *comp, char *buf, uint32_t n) {
    (void)s; (void)name; (void)comp; if (buf && n) buf[0] = 0; return 0;
}
static int rm_component_state(void *s, const char *name, const char *comp, const void *a, const void *b, void *st) {
    (void)s; (void)name; (void)comp; (void)a; (void)b; (void)st; return 0;
}
static int rm_has_component(void *s, const char *name, const char *comp) { (void)s; (void)name; (void)comp; return 0; }
static uint32_t rm_model_name(void *s, uint32_t i, char *buf, uint32_t n) { (void)s; (void)i; if (buf && n) buf[0] = 0; return 0; }
static int rm_load_d3d(void *s, int32_t id, void *dev, void **out) { (void)s; (void)id; (void)dev; if (out) *out = NULL; return RM_NOT_SUPPORTED; }
static int rm_load_into_d3d(void *s, int32_t id, void *tex) { (void)s; (void)id; (void)tex; return RM_NOT_SUPPORTED; }
static void rm_free(void *s, void *p) { (void)s; (void)p; }
static uint32_t rm_zero_u32(void *s) { (void)s; return 0; }
static uint32_t rm_name_err(void *s, const char *name, char *buf, uint32_t n, int *err) {
    (void)s; (void)name;
    if (buf && n) buf[0] = 0;
    if (err) *err = RM_NOT_SUPPORTED;
    return 0;
}
static const char *rm_err_name(void *s, int e) {
    (void)s;
    return e == 0 ? "VRRenderModelError_None" : e == 100 ? "VRRenderModelError_Loading"
         : e == RM_NOT_SUPPORTED ? "VRRenderModelError_NotSupported" : "VRRenderModelError_Unknown";
}

// ---- implemented slots ----------------------------------------------------------------------------
#define SYS "IVRSystem_026"
#define COMP "IVRCompositor_029"
#define INP "IVRInput_011"
#define CHAP "IVRChaperone_004"
#define SETT "IVRSettings_003"
static const impl g_impl[] = {
    { "IVRMailbox_001", "RegisterMailbox", (void *)mb_register },
    { "IVRMailbox_001", "UndoRegisterMailbox", (void *)mb_unregister },
    { "IVRMailbox_001", "SendMessage", (void *)mb_send },
    { "IVRMailbox_001", "ReadMessage", (void *)mb_read },
    { SYS, "GetRecommendedRenderTargetSize", (void *)sys_rt_size },
    { SYS, "GetProjectionMatrix", (void *)sys_proj }, { SYS, "GetProjectionRaw", (void *)sys_proj_raw },
    { SYS, "ComputeDistortion", (void *)sys_distortion },
    { SYS, "GetEyeToHeadTransform", (void *)sys_eye_to_head },
    { SYS, "GetTimeSinceLastVsync", (void *)sys_vsync },
    { SYS, "GetOutputDevice", (void *)sys_output_device },
    { SYS, "IsDisplayOnDesktop", (void *)sys_false },
    { SYS, "GetDeviceToAbsoluteTrackingPose", (void *)sys_poses },
    { SYS, "GetSeatedZeroPoseToStandingAbsoluteTrackingPose", (void *)sys_seated_to_standing },
    { SYS, "GetSortedTrackedDeviceIndicesOfClass", (void *)sys_sorted },
    { SYS, "GetTrackedDeviceActivityLevel", (void *)sys_activity },
    { SYS, "GetTrackedDeviceIndexForControllerRole", (void *)sys_index_for_role },
    { SYS, "GetControllerRoleForTrackedDeviceIndex", (void *)sys_role_for_index },
    { SYS, "GetTrackedDeviceClass", (void *)sys_class }, { SYS, "IsTrackedDeviceConnected", (void *)sys_connected },
    { SYS, "GetBoolTrackedDeviceProperty", (void *)sys_prop_bool },
    { SYS, "GetFloatTrackedDeviceProperty", (void *)sys_prop_float },
    { SYS, "GetInt32TrackedDeviceProperty", (void *)sys_prop_int },
    { SYS, "GetUint64TrackedDeviceProperty", (void *)sys_prop_u64 },
    { SYS, "GetMatrix34TrackedDeviceProperty", (void *)sys_prop_m34 },
    { SYS, "GetArrayTrackedDeviceProperty", (void *)sys_prop_array },
    { SYS, "GetStringTrackedDeviceProperty", (void *)sys_prop_string },
    { SYS, "GetPropErrorNameFromEnum", (void *)sys_prop_err_name },
    { SYS, "GetControllerState", (void *)sys_controller_state },
    { SYS, "PollNextEvent", (void *)sys_poll }, { SYS, "PollNextEventWithPose", (void *)sys_poll_pose },
    { SYS, "GetHiddenAreaMesh", (void *)sys_hidden },
    { SYS, "IsInputAvailable", (void *)sys_true }, { SYS, "IsSteamVRDrawingControllers", (void *)sys_false },
    { SYS, "ShouldApplicationPause", (void *)sys_false },
    { SYS, "ShouldApplicationReduceRenderingWork", (void *)sys_false },
    { SYS, "GetRuntimeVersion", (void *)sys_runtime_version }, { SYS, "SetSDKVersion", (void *)sys_set_sdk },

    { COMP, "SetTrackingSpace", (void *)co_set_space }, { COMP, "GetTrackingSpace", (void *)co_get_space },
    { COMP, "WaitGetPoses", (void *)co_wait_get_poses }, { COMP, "GetLastPoses", (void *)co_last_poses },
    { COMP, "GetLastPoseForTrackedDeviceIndex", (void *)co_last_pose_idx },
    { COMP, "Submit", (void *)co_submit }, { COMP, "SubmitWithArrayIndex", (void *)co_submit_array },
    { COMP, "FadeToColor", (void *)co_fade_to }, { COMP, "GetCurrentFadeColor", (void *)co_fade_color },
    { COMP, "FadeGrid", (void *)co_fade_grid }, { COMP, "GetCurrentGridAlpha", (void *)co_grid_alpha },
    // Both return void in IVRCompositor_029; there is no override to clear.
    { COMP, "ClearSkyboxOverride", (void *)co_void }, { COMP, "ClearStageOverride", (void *)co_void },
    { COMP, "SuspendRendering", (void *)co_suspend },
    { COMP, "ClearLastSubmittedFrame", (void *)co_void }, { COMP, "PostPresentHandoff", (void *)co_void },
    { COMP, "GetFrameTiming", (void *)co_frame_timing },
    { COMP, "GetFrameTimings", (void *)co_frame_timings }, { COMP, "GetFrameTimeRemaining", (void *)co_time_remaining },
    { COMP, "IsFullscreen", (void *)co_true }, { COMP, "CanRenderScene", (void *)co_true },
    { COMP, "GetCurrentSceneFocusProcess", (void *)co_focus_process },
    { COMP, "GetLastFrameRenderer", (void *)co_focus_process },
    { COMP, "IsMirrorWindowVisible", (void *)co_false },
    { COMP, "ShouldAppRenderWithLowResources", (void *)co_false },
    { COMP, "GetVulkanInstanceExtensionsRequired", (void *)co_vk_inst_ext },
    { COMP, "GetVulkanDeviceExtensionsRequired", (void *)co_vk_dev_ext },
    { COMP, "IsMotionSmoothingEnabled", (void *)co_false }, { COMP, "IsMotionSmoothingSupported", (void *)co_false },
    { COMP, "IsCurrentSceneFocusAppLoading", (void *)co_false },

    { INP, "SetActionManifestPath", (void *)in_manifest }, { INP, "GetActionSetHandle", (void *)in_set_handle },
    { INP, "GetActionHandle", (void *)in_action_handle }, { INP, "GetInputSourceHandle", (void *)in_source_handle },
    { INP, "UpdateActionState", (void *)in_update },
    { INP, "GetDigitalActionData", (void *)in_digital }, { INP, "GetAnalogActionData", (void *)in_analog },
    { INP, "GetPoseActionDataRelativeToNow", (void *)in_pose_now },
    { INP, "GetPoseActionDataForNextFrame", (void *)in_pose_next },
    { INP, "GetSkeletalActionData", (void *)in_skeletal }, { INP, "GetDominantHand", (void *)in_dominant },
    { INP, "GetBoneCount", (void *)in_bone_count }, { INP, "GetSkeletalBoneData", (void *)in_bone_data },
    { INP, "GetBoneHierarchy", (void *)in_bone_hierarchy }, { INP, "GetBoneName", (void *)in_bone_name },
    { INP, "GetSkeletalReferenceTransforms", (void *)in_skel_reference },
    { INP, "GetSkeletalBoneDataCompressed", (void *)in_no_data },
    { INP, "GetSkeletalTrackingLevel", (void *)in_tracking_level },
    { INP, "GetSkeletalSummaryData", (void *)in_summary },
    { INP, "TriggerHapticVibrationAction", (void *)in_haptic },
    { INP, "IsUsingLegacyInput", (void *)in_false },
    { INP, "GetActionOrigins", (void *)in_origins }, { INP, "GetOriginLocalizedName", (void *)in_origin_name },
    { INP, "GetOriginTrackedDeviceInfo", (void *)in_origin_info },
    { INP, "GetBindingVariant", (void *)in_binding_variant },

    { "IVRRenderModels_006", "LoadRenderModel_Async", (void *)rm_load_model },
    { "IVRRenderModels_006", "FreeRenderModel", (void *)rm_free },
    { "IVRRenderModels_006", "LoadTexture_Async", (void *)rm_load_texture },
    { "IVRRenderModels_006", "FreeTexture", (void *)rm_free },
    { "IVRRenderModels_006", "LoadTextureD3D11_Async", (void *)rm_load_d3d },
    { "IVRRenderModels_006", "LoadIntoTextureD3D11_Async", (void *)rm_load_into_d3d },
    { "IVRRenderModels_006", "FreeTextureD3D11", (void *)rm_free },
    { "IVRRenderModels_006", "GetRenderModelName", (void *)rm_model_name },
    { "IVRRenderModels_006", "GetRenderModelCount", (void *)rm_zero_u32 },
    { "IVRRenderModels_006", "GetComponentCount", (void *)rm_component_count },
    { "IVRRenderModels_006", "GetComponentName", (void *)rm_component_name },
    { "IVRRenderModels_006", "GetComponentButtonMask", (void *)rm_component_mask },
    { "IVRRenderModels_006", "GetComponentRenderModelName", (void *)rm_component_model },
    { "IVRRenderModels_006", "GetComponentStateForDevicePath", (void *)rm_component_state },
    { "IVRRenderModels_006", "GetComponentState", (void *)rm_component_state },
    { "IVRRenderModels_006", "RenderModelHasComponent", (void *)rm_has_component },
    { "IVRRenderModels_006", "GetRenderModelThumbnailURL", (void *)rm_name_err },
    { "IVRRenderModels_006", "GetRenderModelOriginalPath", (void *)rm_name_err },
    { "IVRRenderModels_006", "GetRenderModelErrorNameFromEnum", (void *)rm_err_name },

    { CHAP, "GetCalibrationState", (void *)ch_state }, { CHAP, "GetPlayAreaSize", (void *)ch_size },
    { CHAP, "GetPlayAreaRect", (void *)ch_rect }, { CHAP, "AreBoundsVisible", (void *)co_false },

    { SETT, "GetBool", (void *)st_get_bool }, { SETT, "GetInt32", (void *)st_get_bool },
    { SETT, "GetFloat", (void *)st_get_float }, { SETT, "GetString", (void *)st_get_string },
};

static void *impl_for(const char *ver, const char *m) {
    for (size_t i = 0; i < sizeof g_impl / sizeof *g_impl; i++)
        if (!strcmp(g_impl[i].ver, ver) && !strcmp(g_impl[i].method, m)) return g_impl[i].fn;
    return NULL;
}

static vobj *g_objs[48];
static int g_nobjs;
static pthread_mutex_t g_omu = PTHREAD_MUTEX_INITIALIZER;
static vobj *iface(const char *ver) {
    if (!ver) return NULL;
    pthread_mutex_lock(&g_omu);
    for (int i = 0; i < g_nobjs; i++)
        if (!strcmp(g_objs[i]->ver, ver)) { pthread_mutex_unlock(&g_omu); return g_objs[i]; }
    const iface_desc *d = NULL;
    for (size_t i = 0; i < sizeof g_desc / sizeof *g_desc; i++)
        if (!strcmp(g_desc[i].ver, ver)) d = &g_desc[i];
    int n = 0;
    if (d) while (d->slots[n]) n++;
    else n = 128;
    vobj *o = calloc(1, sizeof *o);
    o->ver = strdup(ver);
    o->vt = calloc((size_t)n + 1, sizeof *o->vt);
    for (int s = 0; s < n; s++) {
        void *fn = d ? impl_for(ver, d->slots[s]) : NULL;
        if (!fn) {
            char nm[200];
            snprintf(nm, sizeof nm, "%s::%s (#%d)", ver, d ? d->slots[s] : "?", s);
            fn = kl_named_stub(nm, (void *)ovr_unimpl);
        }
        o->vt[s] = fn;
    }
    if (g_nobjs < 48) g_objs[g_nobjs++] = o;
    pthread_mutex_unlock(&g_omu);
    fprintf(stderr, "  [openvr] interface %s -> %p (%s, %d slots)\n", ver, (void *)o,
            d ? d->cls : "not in the public header: every slot a logging stub", n);
    return o;
}

// ---- the exports -----------------------------------------------------------------------------------
static uint32_t g_token = 1;
static uint32_t vr_init(int *err, int type, const char *info) {
    if (err) *err = 0;
    fprintf(stderr, "  [openvr] VR_InitInternal2(type %d%s%s) -> OK: Klepton's runtime "
                    "(HMD + two Touch-style controllers via kl_ovrp)\n",
            type, info ? ", " : "", info ? info : "");
    return g_token;
}
static void vr_shutdown(void) { fprintf(stderr, "  [openvr] VR_ShutdownInternal\n"); g_token++; }
static void *vr_generic(const char *ver, int *err) {
    if (err) *err = 0;
    if (ver && !strncmp(ver, "FnTable:", 8)) {
        fprintf(stderr, "  [openvr] %s: FnTable interfaces are not served\n", ver);
        if (err) *err = 105;                           // VRInitError_Init_InterfaceNotFound
        return NULL;
    }
    // SteamVR's private shared-texture service. libvr's CVr::CreateSwapchain
    // uses it to allocate the eye swapchains in vrserver and import them back
    // by fd (VK_KHR_external_memory_fd), which MoltenVK cannot import. Without
    // it libvr says "No IPCResourceManagerClient available. Using copies!" and
    // renders into its own images, which IVRCompositor::Submit hands us — the
    // path kl_openvr already serves. A logging stub here instead answered
    // NewSharedVulkanImage with false and the engine crashed on the NULL
    // swapchain (CVr::CreateSwapchain NewSharedVulkanImage failed).
    if (ver && !strncmp(ver, "IVRIPCResourceManagerClient", 27)) {
        fprintf(stderr, "  [openvr] %s: refused — libvr falls back to its own eye images "
                        "and Submit\n", ver);
        if (err) *err = 105;
        return NULL;
    }
    return iface(ver);
}
static int vr_valid(const char *ver) { (void)ver; return 1; }
static uint32_t vr_token(void) { return g_token; }
static const char *vr_err_symbol(int e) { if (e) fprintf(stderr, "  [openvr] asked to name init error %d\n", e); return e ? "VRInitError_Unknown" : "VRInitError_None"; }
static const char *vr_err_english(int e) { return e ? "Unknown error (Klepton OpenVR)" : "No Error (0)"; }
static int vr_true(void) { return 1; }

typedef struct { const char *name; void *fn; } flat;
static const flat g_flat[] = {
    { "VR_InitInternal2", (void *)vr_init }, { "VR_InitInternal", (void *)vr_init },
    { "VR_ShutdownInternal", (void *)vr_shutdown },
    { "VR_GetGenericInterface", (void *)vr_generic },
    { "VR_IsInterfaceVersionValid", (void *)vr_valid },
    { "VR_GetInitToken", (void *)vr_token },
    { "VR_GetVRInitErrorAsSymbol", (void *)vr_err_symbol },
    { "VR_GetVRInitErrorAsEnglishDescription", (void *)vr_err_english },
    { "VR_GetStringForHmdError", (void *)vr_err_english },
    { "VR_IsHmdPresent", (void *)vr_true }, { "VR_IsRuntimeInstalled", (void *)vr_true },
};

void *kl_openvr_lookup(const char *name) {
    if (!name || name[0] != 'V' || strncmp(name, "VR_", 3)) return NULL;
    if (!kl_env_on("KL_OPENVR", 1)) return NULL;
    for (size_t i = 0; i < sizeof g_flat / sizeof *g_flat; i++)
        if (!strcmp(g_flat[i].name, name)) return g_flat[i].fn;
    return NULL;
}
