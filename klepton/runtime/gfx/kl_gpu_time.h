// GPU time per guest frame, read from Metal (kl_gpu_time.m). KL_GPU_TIME=1|2;
// unset, every call here returns at once and -[MTLCommandBuffer commit] is
// never touched.
// Adapted from Glovebox (MIT, github.com/glovebox-vr/glovebox) runtime/gfx/kl_gpu_time.h.
#ifndef KL_GPU_TIME_H
#define KL_GPU_TIME_H
#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

// 0 off, 1 log only, 2 log and report it to the game (GetFrameTiming).
int kl_gpu_time_mode(void);
// Timing is on: KL_GPU_TIME, or the live flag below. Cheap (one atomic load).
int kl_gpu_time_active(void);
// Turn timing on/off at runtime without the knob (the visionOS performance
// overlay). Takes effect from the next submit; no log line per second.
void kl_gpu_time_set_live(int on);
// Running total of every final frame's GPU ms and how many frames that was,
// since the process started (both 0 when timing never ran).
void kl_gpu_time_totals(double *sum_ms, uint64_t *frames);
// Time every command buffer committed on this MTLCommandQueue (the guest's:
// kl_vulkan.c hands over each queue the guest submits on).
void kl_gpu_time_watch(void *mtl_queue);
// The game has submitted both eyes: buffers committed from now on are the next frame's.
void kl_gpu_time_frame_end(void);
// The guest's GPU ms of a finished frame `frames_ago` closed frames back (0 when unknown).
float kl_gpu_time_frame_ms(unsigned frames_ago);

#ifdef __cplusplus
}
#endif
#endif
