// GPU time per guest frame, read from Metal itself (KL_GPU_TIME, default off).
// Adapted from Glovebox (MIT, github.com/glovebox-vr/glovebox) runtime/gfx/kl_gpu_time.m
// — the commit hook and the per-frame union only; its snapshot, foveation,
// per-pass profiler and encoder-merge parts are not ported.
//
// MoltenVK has no timestamp queries worth the name on Apple GPUs, but every
// MTLCommandBuffer knows when the GPU started and finished it. So every command
// buffer committed on a queue the guest submits to gets a completed handler,
// and a frame's GPU time is the UNION of its buffers' [GPUStartTime,
// GPUEndTime] intervals: overlap between neighbouring buffers is counted once
// and the idle gaps between them not at all. The [perf] frame-seam line in
// kl_vulkan.c measures the CPU side of the same frame; this is the GPU side.
//
// A buffer belongs to the frame that was open when it was committed; the frame
// closes at kl_gpu_time_frame_end (kl_openvr.c calls it when both eyes are
// submitted). A frame is final once every buffer committed in it has completed.
//
// The hook is a method swizzle of the command buffer class's -commit, installed
// once from the first watched queue's own buffer class; buffers of any other
// queue (the compositor's, ANGLE's) pass straight through. Unset KL_GPU_TIME
// (or 0) installs nothing: kl_gpu_time_watch returns before touching Metal.
//   KL_GPU_TIME=1      log the per-frame GPU ms every KL_GPU_TIME_LOG s (default 1)
//   KL_GPU_TIME=2      ...and report it to the game as GetFrameTiming's
//                      m_flTotalRenderGpuMs (kl_openvr.c) instead of the CPU work
//
// LIVE timing (kl_gpu_time_set_live): the visionOS performance overlay turns
// timing on and off at runtime without KL_GPU_TIME — the same hook, no log
// line. The swizzle stays installed once made; while neither the knob nor the
// live flag is on, the hooked -commit is one relaxed atomic load and the
// original call. Every final frame also feeds a running total
// (kl_gpu_time_totals) that the session record and the overlay read.
#include <os/lock.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>

#include "kl_gpu_time.h"

enum { kRing = 16, kMaxQueues = 8 };
typedef struct {
    uint32_t frame;          // which frame this slot holds
    uint32_t committed, completed;
    double busy;             // seconds of union GPU time so far
    double last_end;         // end of the latest interval already counted
} slot;

static os_unfair_lock g_lk = OS_UNFAIR_LOCK_INIT;
static void *g_queues[kMaxQueues];
static int g_nqueues;
static uint32_t g_frame = 1;     // the open frame (0 means "none" in a slot)
static slot g_slots[kRing];
static IMP g_commit;             // the original -commit
static _Atomic int g_live;       // kl_gpu_time_set_live
static double g_total_ms;        // every final frame's GPU ms, summed (under g_lk)
static uint64_t g_total_n;

int kl_gpu_time_mode(void) {
    static int mode = -1;
    if (mode < 0) {
        const char *e = getenv("KL_GPU_TIME");
        int v = e && *e ? atoi(e) : 0;
        mode = v <= 0 ? 0 : v == 2 ? 2 : 1;
    }
    return mode;
}

int kl_gpu_time_active(void) {
    return kl_gpu_time_mode() || atomic_load_explicit(&g_live, memory_order_relaxed);
}

void kl_gpu_time_set_live(int on) {
    int was = atomic_exchange(&g_live, on ? 1 : 0);
    if (was != (on ? 1 : 0))
        fprintf(stderr, "  [perf] gpu time: live timing %s (overlay)%s\n", on ? "ON" : "off",
                kl_gpu_time_mode() ? "; KL_GPU_TIME keeps it on anyway" : "");
}

void kl_gpu_time_totals(double *sum_ms, uint64_t *frames) {
    os_unfair_lock_lock(&g_lk);
    if (sum_ms) *sum_ms = g_total_ms;
    if (frames) *frames = g_total_n;
    os_unfair_lock_unlock(&g_lk);
}

static double mono_s(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static slot *slot_of(uint32_t f) {
    slot *s = &g_slots[f % kRing];
    if (s->frame != f) { memset(s, 0, sizeof *s); s->frame = f; }
    return s;
}

static void on_complete(uint32_t f, double start, double end) {
    os_unfair_lock_lock(&g_lk);
    slot *s = &g_slots[f % kRing];
    if (s->frame == f) {
        if (end > start && start > 0) {
            double from = start > s->last_end ? start : s->last_end;
            if (end > from) s->busy += end - from;
            if (end > s->last_end) s->last_end = end;
        }
        s->completed++;
    }
    os_unfair_lock_unlock(&g_lk);
}

static int watched(void *q) {
    for (int i = 0; i < g_nqueues; i++) if (g_queues[i] == q) return 1;
    return 0;
}

static void kl_commit(id self, SEL sel) {
    id<MTLCommandBuffer> cb = (id<MTLCommandBuffer>)self;
    if (!kl_gpu_time_active()) { ((void (*)(id, SEL))g_commit)(self, sel); return; }
    void *q = (__bridge void *)[cb commandQueue];
    os_unfair_lock_lock(&g_lk);
    int mine = watched(q);
    uint32_t f = g_frame;
    if (mine) slot_of(f)->committed++;
    os_unfair_lock_unlock(&g_lk);
    if (mine) {
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            on_complete(f, done.GPUStartTime, done.GPUEndTime);
        }];
    }
    ((void (*)(id, SEL))g_commit)(self, sel);
}

void kl_gpu_time_watch(void *mtl_queue) {
    if (!mtl_queue || !kl_gpu_time_active()) return;
    os_unfair_lock_lock(&g_lk);
    int have = watched(mtl_queue);
    if (!have && g_nqueues < kMaxQueues) g_queues[g_nqueues++] = mtl_queue;
    int first = !g_commit;
    os_unfair_lock_unlock(&g_lk);
    if (have || !first) return;
    // The class that actually implements -commit for this device's buffers.
    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)mtl_queue;
    Class c;
    @autoreleasepool { c = object_getClass([q commandBuffer]); }
    Method m = class_getInstanceMethod(c, @selector(commit));
    if (!m) { fprintf(stderr, "  [perf] gpu time: %s has no -commit; GPU time stays 0\n", class_getName(c)); return; }
    // Add the hook on the concrete class itself (so a superclass shared with
    // other command buffer kinds is left alone), keeping the inherited IMP.
    IMP orig = method_getImplementation(m);
    os_unfair_lock_lock(&g_lk);
    g_commit = orig;
    os_unfair_lock_unlock(&g_lk);
    if (!class_addMethod(c, @selector(commit), (IMP)kl_commit, method_getTypeEncoding(m)))
        method_setImplementation(m, (IMP)kl_commit);
    fprintf(stderr, "  [perf] gpu time: timing %s -commit on the guest's queue (KL_GPU_TIME=%d%s)\n",
            class_getName(c), kl_gpu_time_mode(),
            kl_gpu_time_mode() == 2 ? ": reported to the game as TotalRenderGpuMs"
            : !kl_gpu_time_mode() ? ": live, for the overlay" : "");
}

// The guest's GPU ms of the latest final frame at least `frames_ago` closed
// frames back (0 = the frame closed most recently, or the one before it while
// its buffers are still in flight), and which frame that was in *frame. 0 with
// *frame = 0 when nothing is known.
static float latest_ms(unsigned frames_ago, uint32_t *frame) {
    float ms = 0;
    uint32_t got = 0;
    os_unfair_lock_lock(&g_lk);
    for (unsigned back = 1 + frames_ago; back < kRing - 1 && back < g_frame; back++) {
        uint32_t f = g_frame - back;
        slot *s = &g_slots[f % kRing];
        if (s->frame != f) break;
        if (s->committed && s->completed == s->committed) { ms = (float)(s->busy * 1e3); got = f; break; }
    }
    os_unfair_lock_unlock(&g_lk);
    *frame = got;
    return ms;
}

float kl_gpu_time_frame_ms(unsigned frames_ago) {
    uint32_t f;
    return g_commit ? latest_ms(frames_ago, &f) : 0;
}

void kl_gpu_time_frame_end(void) {
    if (!kl_gpu_time_active()) return;
    os_unfair_lock_lock(&g_lk);
    int on = g_commit != NULL;
    if (on) { g_frame++; slot_of(g_frame); }
    os_unfair_lock_unlock(&g_lk);
    if (!on) return;
    // Every KL_GPU_TIME_LOG seconds (default 1): the finished frames' GPU time.
    static uint32_t last_f;
    static unsigned n;
    static double sum, worst, since, every;
    if (!every) { const char *e = getenv("KL_GPU_TIME_LOG"); every = e && atof(e) > 0 ? atof(e) : 1.0; }
    uint32_t f;
    float ms = latest_ms(0, &f);
    if (f && f != last_f) {
        last_f = f; sum += ms; n++; if (ms > worst) worst = ms;
        os_unfair_lock_lock(&g_lk);
        g_total_ms += ms; g_total_n++;
        os_unfair_lock_unlock(&g_lk);
    }
    if (!kl_gpu_time_mode()) return;     // live only: no log line
    double now = mono_s();
    if (!since) since = now;
    if (now - since >= every) {
        if (n)
            fprintf(stderr, "  [perf] gpu time over %u frames: %.2f ms avg / %.2f ms worst per frame "
                            "(union of the guest's Metal command buffers; KL_GPU_TIME)\n",
                    n, sum / n, worst);
        sum = worst = 0; n = 0; since = now;
    }
}
