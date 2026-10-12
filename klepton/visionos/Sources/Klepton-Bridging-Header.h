// The whole C surface the Swift app sees.
//
// Swift owns the platform layer, C owns the guest, and the
// seam between them is a plain C header — no Objective-C anywhere. That is not
// an aesthetic choice, it is what keeps the boundary narrow: everything below
// is four functions, and the guest-facing complexity (JNIEnv, jobjects, ELF
// images) never crosses into Swift at all.
#import "kl_app.h"
// The compositor widens the seam by three headers, and only for the compositor: kl_glfb
// owns the eye-texture provider (the MTLTexture the guest renders into),
// kl_ovrp owns the pose-in seam ARKit answers and the stage-keyed record of
// what each frame was rendered with, and kl_reproject owns the composite pass
// that consumes that record — shader and matrices both, shared with the macOS
// viewer so the picture is only ever debugged once. Everything guest-facing
// still stays on the C side.
#import "kl_glfb.h"
#import "kl_ovrp.h"
#import "kl_openxr.h"
#import "kl_reproject.h"
// ...and by one more for audio: kl_audio owns the CoreAudio output unit, but
// the AVAudioSession it needs on this platform can only be configured from
// Swift (KleptonAudio.swift). Three calls cross: the session's measured rate
// going in, and the two ways the OS takes the stream away coming back.
#import "kl_audio.h"
// ...and by two for the flat guest's window. kl_present says WHAT SHAPE
// of picture the guest is producing — one flat image wants a WindowGroup, an
// eye pair wants the ImmersiveSpace — and kl_mono is what a window then talks
// to: the newest presented frame out, the pointer and the keyboard in. Both are
// shared with kl_view.c, so the host viewer and this app cannot disagree about
// what a click is.
#import "kl_present.h"
#import "kl_mono.h"
// ...and by one for the VULKAN guest's frame seam. The compositor needs one
// thing from it and nothing else: WHEN a Vulkan guest's eye picture is
// complete. On the GL path that is an MTLSharedEvent kl_glfb signals from
// inside ANGLE's command stream; there is no such event on this path, so
// kl_vulkan publishes a serial instead and the compositor reads it exactly
// where it reads the fence value. The eye TEXTURE still arrives through
// kl_glfb's own table, so nothing else about this seam widens.
#import "kl_vulkan.h"
// ...and by one for Steam: the guest's Steamworks stand-in (kl_steam.c) asks
// the user's real Steam account through a backend the app registers
// (KleptonSteamBridge.swift), and the app says "playing off" on teardown.
#import "kl_steam_bridge.h"
// Adapted from avp-play (MIT, github.com/myMartek/avp-play) visionos/Sources/Klepton-Bridging-Header.h.
// One call, declared here rather than importing kl_mediandk.h: that header is
// the guest-facing media table and wants <stdio.h> and CoreVideo context the
// Swift side has no other use for.
void kl_mediandk_set_video_default(int on);
// ...and by two for the in-game quick settings and performance overlay
// (KleptonQuickSettings.swift): kl_gpu_time's live timing switch and running
// total (the overlay's GPU ms, the session record's average), and kl_openvr's
// console entry point (Alyx's antialiasing changed live via vr_fidelity_level).
// Foveation's live switch is in kl_vulkan.h, already above.
#import "kl_gpu_time.h"
#import "kl_openvr.h"
#import "kl_stream_client.h"
