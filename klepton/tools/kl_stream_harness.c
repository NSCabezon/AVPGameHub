// kl_stream_harness — the headset client's C half, run on the Mac.
//
// Links the SAME runtime/net/kl_stream_client.c the visionOS app links (and
// the rest of the runtime, for kl_ovrp), plays the headset against a host —
// normally build/kl_stream_testhost — and checks what comes back:
//
//   * HELLO from kl_ovrp's display description (a Vision-Pro-shaped frustum
//     and IPD pushed through the same kl_ovrp_set_eye_* seams the compositor
//     uses), retried until HELLO_ACK;
//   * POSE at the display rate through kl_stream_client_send_pose_from_ovrp,
//     with a head yawing at --yaw deg/s, so the host's world-locked grid moves;
//   * VIDEO reassembled + decoded; every pulled frame must carry a pose that
//     is still in the 64-entry ring, and must be what that pose rendered;
//   * every pulled frame published the way the app does it (blit for BGRA,
//     the kl_stream_yuv_msl render pass for native YUV), timed;
//   * PNGs of a few published frames (both eyes side by side) for eyeballing.
//
//   * the session's state as the hub's HUD would show it, logged on every
//     change ("harness: +12.3 s state waiting -> streaming"); "no-signal"
//     before the first picture while the host is alive (booting) fails.
//
// Usage: kl_stream_harness <host> [port] [--seconds N] [--out DIR] [--yaw DPS]
//                          [--expect-loss] [--png-every N] [--eye WxH]
//                          [--expect-end bye|lost] [--game]
//                          [--hands] [--aim YAW,PITCH] [--click T[,T...]]
//                          [--png-at T[,T...]] [--pose-gap T]
// (--eye: the recommended per-eye size HELLO carries; the device sends its
// panel size, 3072x2465 on the Vision Pro. --expect-end: run until the session
// ENDS — at most --seconds — and require that reason: the host's BYE, or its
// silence after video, as when it dies without one.)
//
// Against a real game (m_boot KL_STREAM_HOST=1 <target>) rather than the test
// host: --game tolerates pose misses (a guest that stalls for seconds — a PSO
// compile — renders with a pose that has left the client's ring; counted, not
// fatal). --hands publishes both controllers as tracked and connected, at rest
// in front of the head; --aim points the RIGHT one (yaw left-positive, pitch
// up-positive, degrees: its aim ray, kl_openxr's aim pose); --click pulls the
// right index trigger for 0.25 s at each time (seconds from start), which is
// how a laser-pointer menu is pressed; --png-at writes a frame at each time.
// --pose-gap: send no POSE for 3 s from T (past the host's 2 s timeout), as a
// stalled client does; the host must resume the session when POSEs return,
// and frames must flow again (checked: a frame decoded after the gap).
// Exit 0 when it decoded frames and every frame matched its ring pose.

#include "kl_stream_client.h"
#include "kl_ovrp.h"

#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// tools/kl_stream_harness_mtl.m: the app's decoded-frame -> eye-texture step.
int harness_publish(CVPixelBufferRef pb, double *gpu_ms, double *wall_ms);
int harness_publish_png(const char *path);

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    // Count the host's AUDIO, do not play it out of the Mac's speakers
    // (KL_STREAM_AUDIO_PLAY=1 to listen).
    setenv("KL_STREAM_AUDIO_PLAY", "0", 0);
    const char *host = "127.0.0.1";
    int port = 0, png_every = 90, expect_loss = 0, eye_w = 1888, eye_h = 1792, expect_end = 0;
    double seconds = 6, yaw_dps = 20;
    int game = 0, hands = 0;
    float aim_yaw = 0, aim_pitch = 0;
    double clicks[16], png_at[32];
    int n_clicks = 0, n_png_at = 0, png_at_i = 0;
    double pose_gap = -1;
    unsigned frames_after_gap = 0;
    const char *out = "build/stream";
    int positional = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];
        else if (!strcmp(argv[i], "--yaw") && i + 1 < argc) yaw_dps = atof(argv[++i]);
        else if (!strcmp(argv[i], "--png-every") && i + 1 < argc) png_every = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--expect-loss")) expect_loss = 1;
        else if (!strcmp(argv[i], "--expect-end") && i + 1 < argc) {
            i++;
            expect_end = !strcmp(argv[i], "bye") ? KL_STREAM_END_BYE
                       : !strcmp(argv[i], "lost") ? KL_STREAM_END_LOST : -1;
            if (expect_end < 0) { fprintf(stderr, "harness: --expect-end bye|lost\n"); return 2; }
        }
        else if (!strcmp(argv[i], "--eye") && i + 1 < argc) sscanf(argv[++i], "%dx%d", &eye_w, &eye_h);
        else if (!strcmp(argv[i], "--game")) game = 1;
        else if (!strcmp(argv[i], "--pose-gap") && i + 1 < argc) pose_gap = atof(argv[++i]);
        else if (!strcmp(argv[i], "--hands")) hands = 1;
        else if (!strcmp(argv[i], "--aim") && i + 1 < argc) {
            sscanf(argv[++i], "%f,%f", &aim_yaw, &aim_pitch);
            hands = 1;
        }
        else if ((!strcmp(argv[i], "--click") || !strcmp(argv[i], "--png-at")) && i + 1 < argc) {
            int is_click = argv[i][2] == 'c';
            char *list = argv[++i], *save = NULL;
            for (char *t = strtok_r(list, ",", &save); t; t = strtok_r(NULL, ",", &save)) {
                if (is_click && n_clicks < 16) clicks[n_clicks++] = atof(t);
                else if (!is_click && n_png_at < 32) png_at[n_png_at++] = atof(t);
            }
            if (is_click) hands = 1;
        }
        else if (positional == 0) { host = argv[i]; positional++; }
        else if (positional == 1) { port = atoi(argv[i]); positional++; }
    }
    mkdir(out, 0755);

    // The display, through the compositor's own seams (values measured on the
    // device: per-eye asymmetric tangents, ~63 mm IPD, 90 Hz).
    kl_ovrp_set_eye_frustum(0, 1.0f, 0.83f, 0.93f, 1.09f);
    kl_ovrp_set_eye_frustum(1, 0.83f, 1.0f, 0.93f, 1.09f);
    kl_ovrp_set_eye_offset(0, -0.0315f, 0, 0);
    kl_ovrp_set_eye_offset(1, 0.0315f, 0, 0);
    kl_ovrp_set_display_frequency(90);
    kl_ovrp_set_eye_texture_size(eye_w, eye_h);

    kl_stream_client *c = kl_stream_client_create(host, port);
    if (!c) { fprintf(stderr, "harness: no client\n"); return 2; }
    const float tan[2][4] = { { 1.0f, 0.83f, 0.93f, 1.09f }, { 0.83f, 1.0f, 0.93f, 1.09f } };
    kl_stream_hello hello;
    kl_stream_hello_from_ovrp(&hello, tan, "harness");
    kl_stream_client_set_display(c, &hello);

    double t0 = kl_stream_now(), next = t0, period = 1.0 / 90;
    unsigned frames = 0, mismatched = 0, missing = 0, pngs = 0, pub_fail = 0;
    double pub_gpu = 0, pub_wall = 0;
    uint32_t last_frame = 0;
    float yaw = 0;
    int last_state = -1, nosignal_booting = 0, saw_booting = 0;
    double t_last_state = -1, t_first_pic = -1, t_ended = -1;
    while (kl_stream_now() - t0 < seconds) {
        double now = kl_stream_now();
        // The state the HUD reads, every 50 ms.
        if (now - t_last_state >= 0.05) {
            t_last_state = now;
            kl_stream_client_status ss;
            kl_stream_client_get_status(c, &ss);
            if (ss.host_state == KL_STREAM_HOST_BOOTING) saw_booting = 1;
            if (ss.state != last_state) {
                printf("harness: +%.1f s state %s -> %s (host %s %.1f s, %u guest frames, "
                       "since rx %.1f s, audio %u pkts, %u frames decoded%s)\n", now - t0,
                       last_state < 0 ? "-" : kl_stream_client_state_name(last_state),
                       kl_stream_client_state_name(ss.state),
                       ss.host_state == KL_STREAM_HOST_BOOTING ? "booting"
                       : ss.host_state == KL_STREAM_HOST_RUNNING ? "running" : "?",
                       (double)ss.host_seconds, ss.host_guest_frames, ss.since_rx_s,
                       ss.audio_packets, ss.frames_decoded,
                       ss.state == KL_STREAM_CLIENT_ENDED
                           ? (ss.end_reason == KL_STREAM_END_BYE ? ", ended: BYE" : ", ended: host silent")
                           : "");
                last_state = ss.state;
            }
            if (ss.state == KL_STREAM_CLIENT_NO_SIGNAL && ss.frames_decoded == 0 &&
                ss.host_state == KL_STREAM_HOST_BOOTING) nosignal_booting++;
            if (ss.state == KL_STREAM_CLIENT_ENDED) {
                t_ended = now;
                if (expect_end) break;
            }
        }
        if (next > now) { usleep((useconds_t)((next - now) * 1e6)); continue; }
        next += period;
        double t_present = now + 0.030;     // a typical prediction horizon
        yaw = (float)(yaw_dps * (now - t0) * M_PI / 180);
        float s = sinf(yaw / 2), w = cosf(yaw / 2);
        kl_ovrp_set_head_pose_time(t_present);
        kl_ovrp_set_head_pose(0, 1.6f, 0, 0, s, 0, w);
        int pressed = 0;
        if (hands) {
            // Both controllers at rest in front of the head, the right one
            // aimed: yaw about +Y, then pitch about the yawed +X.
            for (int h = 0; h < 2; h++) {
                float hy = h ? aim_yaw : 0, hp = h ? aim_pitch : -20.0f;
                float cy = cosf(hy * (float)M_PI / 360), sy = sinf(hy * (float)M_PI / 360);
                float cp = cosf(hp * (float)M_PI / 360), sp = sinf(hp * (float)M_PI / 360);
                // q = qyaw * qpitch
                float qx = cy * sp, qy = sy * cp, qz = -sy * sp, qw = cy * cp;
                kl_ovrp_set_hand_motion(h, h ? 0.15f : -0.15f, 1.3f, -0.3f, qx, qy, qz, qw,
                                        0, 0, 0, 0, 0, 0);
            }
            double el = now - t0;
            for (int k = 0; k < n_clicks; k++)
                if (el >= clicks[k] && el < clicks[k] + 0.25) pressed = 1;
            static int was_pressed;
            if (pressed != was_pressed)
                printf("harness: +%.1f s right trigger %s (aim yaw %.1f pitch %.1f)\n", el,
                       pressed ? "PULLED" : "released", (double)aim_yaw, (double)aim_pitch);
            was_pressed = pressed;
            kl_ovrp_set_controller_input(0, 0, 0, 0, 0, 0, 0);
            kl_ovrp_set_controller_input(1, pressed ? KL_OVRP_RAW_RINDEX_TRIGGER : 0,
                                         KL_OVRP_RAW_RINDEX_TRIGGER, pressed ? 1.0f : 0.0f,
                                         0, 0, 0);
        }
        int in_gap = pose_gap >= 0 && now - t0 >= pose_gap && now - t0 < pose_gap + 3.0;
        if (!in_gap) kl_stream_client_send_pose_from_ovrp(c, t_present, hands ? 3u : 0u);

        kl_stream_frame_info info;
        CVPixelBufferRef pb = kl_stream_client_pull_frame(c, &info);
        if (!pb) continue;
        if (t_first_pic < 0) {
            t_first_pic = now;
            printf("harness: +%.1f s first picture\n", now - t0);
        }
        frames++;
        if (pose_gap >= 0 && now - t0 > pose_gap + 3.5) frames_after_gap++;
        if (!info.have_pose) { if (info.pose_id != 0) missing++; }
        else {
            // The pose the frame says it rendered with must be the one we sent
            // with that id: same t_pose, and a yaw consistent with that time.
            double ty = yaw_dps * ((info.t_pose - 0.030) - t0) * M_PI / 180;
            float qy = sinf((float)ty / 2);
            if (fabsf(qy - info.pose7[4]) > 2e-3f) mismatched++;
        }
        if (info.frame_id <= last_frame) mismatched++;
        last_frame = info.frame_id;
        kl_stream_client_note_displayed(c, t_present, info.t_pose);
        double pg = 0, pw = 0;
        if (harness_publish(pb, &pg, &pw) == 0) { pub_gpu += pg; pub_wall += pw; }
        else pub_fail++;
        int png_due = 0;
        while (png_at_i < n_png_at && now - t0 >= png_at[png_at_i]) { png_due = 1; png_at_i++; }
        if (frames == 1 || png_due || (png_every > 0 && frames % (unsigned)png_every == 0)) {
            char p[512];
            snprintf(p, sizeof p, "%s/frame_%05u.png", out, info.frame_id);
            if (harness_publish_png(p)) {
                pngs++;
                printf("harness: wrote %s (%dx%d, pose %u, key %d, host render %.1f ms, "
                       "encode %.1f ms, decode->now %.1f ms)\n", p, info.width, info.height,
                       info.pose_id, info.keyframe, info.host_ms_render, info.host_ms_encode,
                       (kl_stream_now() - info.t_decoded) * 1000);
            }
        }
        CVPixelBufferRelease(pb);
    }
    kl_stream_client_status st;
    kl_stream_client_get_status(c, &st);
    printf("harness: %u frames pulled, %u decoded, %u lost, %u IDR requests, %u decode errors, "
           "%u pose misses, %u ring mismatches, %u PNGs, state %s, last line: %s\n",
           frames, st.frames_decoded, st.frames_lost, st.idr_requests, st.decode_errors,
           st.pose_misses, mismatched, pngs, kl_stream_client_state_name(st.state), st.line);
    printf("harness: decode %.2f ms mean (%s), publish %.2f ms GPU / %.2f ms wall mean, "
           "decode+publish %.2f ms; cadence: decoded every %.2f ms, sd %.2f ms; fec-fixed %u\n",
           st.decode_ms_mean, getenv("KL_STREAM_DECODE_BGRA") && atoi(getenv("KL_STREAM_DECODE_BGRA")) ? "BGRA" : "native YUV",
           frames ? pub_gpu / frames : 0.0, frames ? pub_wall / frames : 0.0,
           st.decode_ms_mean + (frames ? pub_wall / frames : 0.0),
           st.interval_ms_mean, st.interval_sd_ms_all, st.fec_fixed);
    printf("harness: audio %u packets, %u underruns, %u frames of gaps, %.0f ms buffered at the end\n",
           st.audio_packets, st.audio_underruns, st.audio_gap_frames, (double)st.audio_ms);
    kl_stream_client_destroy(c);
    // --game: a real guest's multi-second stalls outlive the pose ring; say so.
    if (game && missing) printf("harness: %u frames rendered with a pose no longer in the ring "
                                "(guest stalls; --game: not a failure)\n", missing);
    int ok = frames > 0 && mismatched == 0 && (game || missing == 0) && st.decode_errors == 0 &&
             pub_fail == 0;
    // Loss must have been SEEN and survived: recovered by parity, or by IDR.
    if (expect_loss) ok = ok && (st.fec_fixed > 0 || (st.frames_lost > 0 && st.idr_requests > 0));
    if (saw_booting || expect_end)
        printf("harness: first picture at %+.1f s; host BOOTING seen %s; no-signal while booting: %d polls; "
               "ended %s (%s)\n", t_first_pic >= 0 ? t_first_pic - t0 : -1.0, saw_booting ? "yes" : "no",
               nosignal_booting, t_ended >= 0 ? "yes" : "no",
               st.end_reason == KL_STREAM_END_BYE ? "BYE" : st.end_reason == KL_STREAM_END_LOST ? "host silent" : "-");
    ok = ok && nosignal_booting == 0;
    if (expect_end) ok = ok && st.state == KL_STREAM_CLIENT_ENDED && st.end_reason == expect_end;
    if (pose_gap >= 0) {
        printf("harness: %u frames pulled after the %.1f s pose gap\n", frames_after_gap, pose_gap);
        ok = ok && frames_after_gap > 0;
    }
    printf("harness: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
