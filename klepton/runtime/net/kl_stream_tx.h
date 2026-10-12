// kl_stream_tx — one encoded frame -> VIDEO packets, shared by the real host
// (kl_stream_host.c) and the test host (tools/kl_stream_testhost.m) so both
// put the same bytes on the wire:
//
//   * fragmentation into KL_STREAM_MTU_PAYLOAD pieces (kl_stream_proto.h);
//   * XOR parity per group of fec_n fragments (KL_STREAM_FEC), sent right
//     after its group — any one lost fragment per group is rebuilt by the
//     client without a keyframe;
//   * pacing: the frame's packets spread evenly over pace_s seconds instead
//     of one burst of 100-600 datagrams, which is what overflows a Wi-Fi
//     access point's queue (KL_STREAM_PACE_MS). `hurry` (when non-NULL and
//     set) makes the rest of the frame go at once — the caller sets it when a
//     newer frame is already waiting, so pacing never adds a frame of delay;
//   * optional simulated loss (drop_p), for loss tests on loopback.
//
// Plain C, host-only (not in the shipping runtime: the headset only receives).
#ifndef KL_STREAM_TX_H
#define KL_STREAM_TX_H

#include <stddef.h>
#include <stdint.h>
#include "kl_stream_proto.h"

// Sends one VIDEO packet (header magic/version/type/seq are the callee's to
// fill, as each sender numbers its own). 0 = sent.
typedef int (*kl_stream_tx_fn)(void *ctx, void *pkt, size_t n);

typedef struct {
    unsigned data, parity;      // packets built
    unsigned sent, failed;      // ...handed to the socket / refused by it
    unsigned dropped;           // simulated loss (drop_p)
    double   ms;                // first packet to last
} kl_stream_tx_result;

// `meta` supplies frame_id, pose_id, t_pose, flags (KEYFRAME), tan and the
// host timings; frame_bytes, frag_index/count, fec_n and the header are
// filled here. fec_n <= 0 = no parity. pace_s <= 0 = one burst. Returns 0, or
// -1 when the frame needs more fragments than the protocol can number.
int kl_stream_tx_frame(const kl_stream_video *meta, const uint8_t *au, size_t n,
                       int fec_n, double pace_s, const volatile int *hurry,
                       double drop_p, kl_stream_tx_fn send, void *ctx,
                       kl_stream_tx_result *r);

#endif
