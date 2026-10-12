// kl_stream_proto.h — "Jugar desde el Mac": the wire protocol between the
// headset (KleptonHub, the CLIENT) and the Mac running the game (the HOST).
//
// The headset keeps owning the Full Space: head, Sense controllers and hands
// are tracked there exactly as in standalone mode, and sent to the host. The
// host runs the guest (Alyx) under Klepton, feeds those poses into the same
// kl_ovrp_set_* seams the standalone compositor uses, encodes each submitted
// eye pair as one HEVC frame (left|right side by side) and sends it back,
// tagged with the POSE it was rendered with. The headset decodes it and hands
// it to the existing compositor/reprojection as if the guest had submitted it
// locally — so swim fixes (render anchor, depth reprojection) apply unchanged.
//
// Transport: one UDP socket each side. Host advertises Bonjour service
// KL_STREAM_BONJOUR on KL_STREAM_PORT_DEFAULT. All integers little-endian,
// all structs packed, floats IEEE-754 binary32, times binary64 seconds.
// Coordinate frame: the headset's tracking space as published to kl_ovrp
// today (metres, +Y up, -Z forward, OpenVR/ARKit right-handed).
//
// Clock: every timestamp in this protocol is the CLIENT's clock
// (CACurrentMediaTime on visionOS). The host never interprets it; it echoes
// it back so the client can match a video frame to the DeviceAnchor it sent.
//
// Versioning: bump KL_STREAM_VERSION on any layout change; a HELLO with a
// different version is answered with HELLO_ACK.status = KL_STREAM_ERR_VERSION.

#ifndef KL_STREAM_PROTO_H
#define KL_STREAM_PROTO_H

#include <stdint.h>

#define KL_STREAM_MAGIC        0x54534C4Bu   // "KLST"
#define KL_STREAM_VERSION      2u   // 2: VIDEO.fec_n + XOR parity packets
#define KL_STREAM_PORT_DEFAULT 9944
#define KL_STREAM_BONJOUR      "_klepton-stream._udp"
#define KL_STREAM_MTU_PAYLOAD  1200          // video bytes per VIDEO packet; fits a 1280 IPv6 MTU

enum kl_stream_type {
    KL_STREAM_HELLO       = 1,   // client -> host, ~1 Hz until HELLO_ACK
    KL_STREAM_HELLO_ACK   = 2,   // host -> client
    KL_STREAM_POSE        = 3,   // client -> host, every display frame (90 Hz)
    KL_STREAM_VIDEO       = 4,   // host -> client, one encoded eye pair in fragments
    KL_STREAM_IDR_REQUEST = 5,   // client -> host, after a lost/undecodable frame
    KL_STREAM_HAPTICS     = 6,   // host -> client, per hand, per host frame while buzzing
    KL_STREAM_PING        = 7,   // either way; PONG echoes t_send
    KL_STREAM_PONG        = 8,
    KL_STREAM_BYE         = 9,   // either way; stop streaming
    KL_STREAM_AUDIO       = 10,  // host -> client, the guest's PCM (additive in v2:
                                 // a v2 client without audio ignores the type)
};

enum kl_stream_status {
    KL_STREAM_OK          = 0,
    KL_STREAM_ERR_VERSION = 1,
    KL_STREAM_ERR_BUSY    = 2,   // another client is streaming
    KL_STREAM_ERR_GUEST   = 3,   // the host's guest failed to start
};

#pragma pack(push, 1)

typedef struct {
    uint32_t magic;      // KL_STREAM_MAGIC
    uint16_t version;    // KL_STREAM_VERSION
    uint16_t type;       // enum kl_stream_type
    uint32_t seq;        // per-sender, per-type, increments by 1
} kl_stream_hdr;

typedef struct { float x, y, z; } kl_stream_v3;
typedef struct { float x, y, z, w; } kl_stream_q;

// Per-eye display description: what kl_ovrp_set_eye_frustum / _offset /
// _rotation receive on the headset today. Tangents are positive, as
// kl_ovrp_set_eye_frustum takes them (left, right, top=up, bottom=down).
typedef struct {
    float        tan_left, tan_right, tan_up, tan_down;
    kl_stream_v3 offset;     // eye position in head space, metres
    kl_stream_q  rotation;   // eye view rotation in head space (cant)
} kl_stream_eye;

typedef struct {
    kl_stream_hdr h;
    char          device[32];        // NUL-terminated, informative
    float         display_hz;        // e.g. 90
    uint32_t      eye_w, eye_h;      // recommended per-eye render size
    kl_stream_eye eye[2];
    uint32_t      max_bitrate_kbps;  // client's decode/link budget hint, 0 = host decides
    uint32_t      flags;             // reserved, 0
} kl_stream_hello;

typedef struct {
    kl_stream_hdr h;
    uint32_t      status;            // enum kl_stream_status
    char          guest[32];         // e.g. "alyx", NUL-terminated
    uint32_t      codec;             // 'hvc1' fourcc (0x31637668)
    uint32_t      frame_w, frame_h;  // encoded frame: both eyes side by side
    uint32_t      bitrate_kbps;
    float         host_fps_target;   // e.g. 45
} kl_stream_hello_ack;

// Controller state, one per hand (0 = left, 1 = right). Buttons/touches use
// the same bit layout kl_ovrp_set_controller_input takes on the headset
// (KleptonControllers.swift produces it), so the host passes them through.
enum {
    KL_STREAM_HAND_TRACKED   = 1u << 0,  // pose valid (Sense controller tracked)
    KL_STREAM_HAND_CONNECTED = 1u << 1,  // controller connected (buttons valid)
};
typedef struct {
    uint32_t     flags;
    kl_stream_v3 pos;
    kl_stream_q  rot;
    kl_stream_v3 vel;          // m/s, tracking space
    kl_stream_v3 ang_vel;      // rad/s, tracking space
    uint32_t     buttons, touches;
    float        index_trigger, hand_trigger, stick_x, stick_y;
    int32_t      battery;      // 0..100, -1 unknown
} kl_stream_hand;

typedef struct {
    kl_stream_hdr  h;
    uint32_t       pose_id;    // increments per POSE; echoed in VIDEO
    double         t_pose;     // client clock: the instant this head pose IS ABOUT
                               // (the predicted presentation time of the anchor)
    kl_stream_v3   head_pos;
    kl_stream_q    head_rot;
    kl_stream_v3   head_vel;
    kl_stream_v3   head_ang_vel;
    kl_stream_hand hand[2];
} kl_stream_pose;

// One encoded frame = frag_count VIDEO packets with the same frame_id. Every
// fragment repeats the frame metadata, so any fragment that arrives first is
// enough to start reassembly. Payload: HEVC, length-prefixed NAL units
// (4-byte big-endian length, as in an hvcC sample); a keyframe carries
// VPS/SPS/PPS as its first NAL units.
//
// Forward error correction (v2): with fec_n > 0 the data fragments are taken
// in groups of fec_n (group g = fragments g*fec_n .. g*fec_n+fec_n-1, the last
// group may be shorter) and each group is followed by ONE parity packet:
// a VIDEO packet with KL_STREAM_VIDEO_PARITY set, frag_index = the GROUP index,
// and a payload that is the XOR of the group's data payloads, each zero-padded
// to the group's first (longest) fragment — so its length is
// min(KL_STREAM_MTU_PAYLOAD, frame_bytes - g*fec_n*KL_STREAM_MTU_PAYLOAD).
// Any ONE missing data fragment of a group is rebuilt from the others plus
// the parity. Encoder/decoder: runtime/net/kl_stream_tx.c / kl_stream_client.c.
enum {
    KL_STREAM_VIDEO_KEYFRAME = 1u << 0,
    KL_STREAM_VIDEO_PARITY   = 1u << 1,
};
typedef struct {
    kl_stream_hdr h;
    uint32_t      frame_id;      // increments per encoded frame
    uint32_t      pose_id;       // the POSE the guest rendered this frame with
    double        t_pose;        // that POSE's t_pose, echoed
    uint32_t      flags;
    uint32_t      frame_bytes;   // total payload bytes across fragments
    uint16_t      frag_index, frag_count;
    // What the guest says it rendered with (SUBMIT_PROJ), per eye, positive
    // tangents left, right, up, down — the compositor places each half with
    // these, exactly as it uses g_frame_tan locally.
    float         tan[2][4];
    float         host_ms_render;  // guest frame work (WaitGetPoses -> Submit)
    float         host_ms_encode;  // encode time of this frame
    uint16_t      fec_n;           // data fragments per parity group, 0 = no FEC (v2)
    uint16_t      reserved;
    // followed by payload bytes: min(KL_STREAM_MTU_PAYLOAD, frame_bytes - frag_index*KL_STREAM_MTU_PAYLOAD)
    // (a PARITY packet: see above)
} kl_stream_video;

typedef struct {
    kl_stream_hdr h;
    uint32_t      last_good_frame_id;
} kl_stream_idr_request;

typedef struct {
    kl_stream_hdr h;
    uint32_t      hand;          // 0 left, 1 right
    float         amplitude;     // 0..1, as kl_ovrp_haptics_pull reports
    float         seconds;       // how long to hold that level
} kl_stream_haptics;

typedef struct {
    kl_stream_hdr h;
    double        t_send;        // sender's clock; PONG echoes it
    double        t_reply;       // PONG: replier's clock, else 0
} kl_stream_ping;

// The guest's sound, as it left its mixer (before the host's resampler):
// interleaved signed 16-bit little-endian PCM, `frames` frames of `channels`
// channels at `sample_rate` Hz. `first_frame` counts frames since the host
// started sending (per stream; it restarts from 0 with a new sample_rate or
// channel count), so the client sees loss and reordering and fills a gap with
// silence. The host sends ~5 ms per packet (240 frames of 48 kHz stereo = 960
// bytes), each in one datagram, no FEC: a lost packet is 5 ms of silence.
typedef struct {
    kl_stream_hdr h;
    uint32_t      sample_rate;
    uint16_t      channels;      // 1 or 2
    uint16_t      frames;
    uint64_t      first_frame;
    // followed by frames * channels int16
} kl_stream_audio;
#define KL_STREAM_AUDIO_MAX_FRAMES 288   // 288 * 2 ch * 2 B = 1152 <= KL_STREAM_MTU_PAYLOAD

#pragma pack(pop)

#endif // KL_STREAM_PROTO_H
