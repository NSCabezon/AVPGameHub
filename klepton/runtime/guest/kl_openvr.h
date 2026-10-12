// Klepton's own OpenVR runtime for the glibc door (kl_openvr.c): answers the
// libopenvr_api.so entry points Alyx's libvr.so imports (VR_InitInternal2,
// VR_GetGenericInterface, ...) with C++ interface objects backed by kl_ovrp —
// the same XR state kl_openxr serves OpenXR guests from. NULL for any other
// name. KL_OPENVR=0 leaves them to the guest's libopenvr_api (which then looks
// for a SteamVR install and fails).
#ifndef KL_OPENVR_H
#define KL_OPENVR_H
void *kl_openvr_lookup(const char *name);
// WaitGetPoses blocks in `wait` before latching the frame's poses (the frame
// pacer: KL_GUEST_PACE_HZ / KL_GUEST_PACE_DIV on visionOS, KL_STREAM_LOCK_FPS in the
// Mac stream host). NULL, the default, never waits.
void kl_openvr_set_frame_pacer(void (*wait)(void));
// Run a console command in the running game (Half-Life: Alyx build 10919
// only), on the game's own thread at its next input update — the same engine
// call KL_OPENVR_CMD_AT makes. Thread-safe; returns 0 when queued, -1 when the
// console is not reachable (another game, another build, not booted yet), -2
// when the small queue (8) is full. Commands longer than 127 bytes are cut.
int kl_openvr_console(const char *cmd);
// 1 once the game thread has found Alyx's engine client (the console works).
int kl_openvr_console_ready(void);
#endif
