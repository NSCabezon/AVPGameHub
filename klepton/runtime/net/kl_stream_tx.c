// kl_stream_tx.c — see kl_stream_tx.h.
#include "kl_stream_tx.h"

#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double tx_now(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom * 1e-9;
}

static void tx_sleep_until(double t) {
    double d = t - tx_now();
    if (d <= 0) return;
    struct timespec ts = { (time_t)d, (long)((d - (double)(time_t)d) * 1e9) };
    nanosleep(&ts, NULL);
}

int kl_stream_tx_frame(const kl_stream_video *meta, const uint8_t *au, size_t n,
                       int fec_n, double pace_s, const volatile int *hurry,
                       double drop_p, kl_stream_tx_fn send, void *ctx,
                       kl_stream_tx_result *r) {
    kl_stream_tx_result res;
    memset(&res, 0, sizeof res);
    uint32_t count = (uint32_t)((n + KL_STREAM_MTU_PAYLOAD - 1) / KL_STREAM_MTU_PAYLOAD);
    if (count == 0 || count > 0xffff) { if (r) *r = res; return -1; }
    if (fec_n < 0) fec_n = 0;
    if (fec_n > 255) fec_n = 255;
    uint32_t groups = fec_n ? (count + (uint32_t)fec_n - 1) / (uint32_t)fec_n : 0;
    uint32_t total = count + groups;

    uint8_t pkt[sizeof(kl_stream_video) + KL_STREAM_MTU_PAYLOAD];
    uint8_t parity[KL_STREAM_MTU_PAYLOAD];
    kl_stream_video *v = (kl_stream_video *)pkt;
    *v = *meta;
    v->flags &= ~KL_STREAM_VIDEO_PARITY;
    v->frame_bytes = (uint32_t)n;
    v->frag_count = (uint16_t)count;
    v->fec_n = (uint16_t)fec_n;
    v->reserved = 0;

    double t0 = tx_now();
    // Pacing in micro-bursts: a packet is sent when its slot (t0 + i*step)
    // comes; sleeping only once the schedule is >= 0.25 ms ahead keeps the
    // syscall count sane at 50k+ packets/s.
    double step = pace_s > 0 && total > 1 ? pace_s / (double)total : 0;
    uint32_t slot = 0;
    size_t plen = 0;
    for (uint32_t i = 0; i < count; i++) {
        size_t off = (size_t)i * KL_STREAM_MTU_PAYLOAD;
        size_t len = n - off < KL_STREAM_MTU_PAYLOAD ? n - off : KL_STREAM_MTU_PAYLOAD;
        if (fec_n && i % (uint32_t)fec_n == 0) {
            plen = len;                         // the group's first = longest
            memset(parity, 0, sizeof parity);
        }
        for (int pass = 0; pass < (fec_n ? 2 : 1); pass++) {
            int is_par = pass == 1;
            if (is_par) {
                int last_of_group = (i + 1) % (uint32_t)fec_n == 0 || i + 1 == count;
                if (!last_of_group) break;
            }
            if (step > 0 && !(hurry && *hurry)) {
                double due = t0 + step * (double)slot;
                if (due - tx_now() >= 0.00025) tx_sleep_until(due);
            }
            slot++;
            if (is_par) {
                v->flags |= KL_STREAM_VIDEO_PARITY;
                v->frag_index = (uint16_t)(i / (uint32_t)fec_n);
                memcpy(pkt + sizeof *v, parity, plen);
                res.parity++;
            } else {
                v->flags &= ~KL_STREAM_VIDEO_PARITY;
                v->frag_index = (uint16_t)i;
                memcpy(pkt + sizeof *v, au + off, len);
                if (fec_n) {
                    const uint8_t *src = au + off;
                    for (size_t k = 0; k < len; k++) parity[k] ^= src[k];
                }
                res.data++;
            }
            if (drop_p > 0 && (double)arc4random() / 4294967295.0 < drop_p) { res.dropped++; continue; }
            if (send(ctx, pkt, sizeof *v + (is_par ? plen : len)) == 0) res.sent++;
            else res.failed++;
        }
    }
    res.ms = (tx_now() - t0) * 1000.0;
    if (r) *r = res;
    return 0;
}
