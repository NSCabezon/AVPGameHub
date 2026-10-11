// The viewer's hardware compositor. See kl_view_mtl.h for why it exists and
// what it replaces; this file is the pass.
//
// It is the macOS twin of visionos/Sources/KleptonCompositor.swift, and the
// shader and the matrices behind it are now literally the same code — both
// compile kl_reproject_msl() and both build their uniforms with
// kl_reproject_build(). The flip, the quad and the array-slice sampler are the
// bits that have to be right in both, and having them diverge would mean
// debugging the picture twice. What differs is only the destination — a
// CAMetalLayer drawable here, a cp_drawable there.
//
// It is also the only place the reprojection math can be *run* before the
// device is available: the pass is fed the pose the guest actually rendered
// with (kl_ovrp's stage-keyed record) instead of the current one, so mouse-look
// motion between the guest's frame and this composite is corrected here exactly
// as head motion is corrected on device.
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#include <pthread.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "kl_glfb.h"
#include "kl_ovrp.h"
#include "kl_reproject.h"
#include "kl_view_mtl.h"
#include "kl_vulkan.h"
#include "kl_env.h"
#include "kl_steam_bridge.h"
#include <math.h>

static const float *klvm_display_tan(int eye, const float *rendered, float out[4]);

// The liveness downsample. 64x64 is 16 KB read back in a completion handler —
// off the critical path and small enough not to matter, but enough resolution
// to tell a black frame from a lit one, which is the only question the HUD
// asks. Bigger buys nothing: this is a sparse sample of a 5-megapixel eye
// either way.
#define KLVM_STAT_DIM 64

static id<MTLDevice>              g_dev;
static id<MTLCommandQueue>        g_queue;
static id<MTLRenderPipelineState> g_pipe;      // the plain blit, for the liveness downsample
static id<MTLRenderPipelineState> g_pipe_rp;   // the reprojection pass
static id<MTLRenderPipelineState> g_pipe_ov;   // the GUEST's layers, blended, KL_GUEST_OVERLAYS
// KL_REPROJECT_DEPTH_MODE=2 / KL_CP_DEPTH_VIS (kl_reproject.h). The viewer has
// no depth attachment and no system reprojection to feed, so what depth buys
// here is the INSTRUMENT: the false-colour pass (KL_CP_DEPTH_VIS=1) and the
// once-a-second probe behind the [swim] line — the same shaders the device runs.
static id<MTLRenderPipelineState> g_pipe_dvis;
static id<MTLComputePipelineState> g_depth_probe;
static id<MTLBuffer>              g_depth_probe_buf[2];
static unsigned                   g_depth_probe_n, g_depth_frames, g_swim_frames;
static double                     g_depth_probe_t, g_swim_t0;
static id<MTLSamplerState>        g_samp;
static id<MTLSharedEvent>         g_event;
static id<MTLTexture>             g_stat;
static CAMetalLayer              *g_layer;
static int                        g_started;
static unsigned                   g_frames;
static uint64_t                   g_last_value;      // fence value last composited
static unsigned long             g_lit;   // atomics below: written on a Metal completion queue
// The FLAT guest's picture: kl_glfb's IOSurface-backed root surface, wrapped
// once. When set, the composite is klvm_present_flat — one blit, no pose, no
// overlays — and nothing anywhere reads pixels back. sRGB view over the BGRA
// bytes so sampling decodes and the sRGB drawable re-encodes: net identity,
// the same bytes the readback path showed.
static id<MTLTexture>             g_flat_tex;
static int                        g_flat_w, g_flat_h;

// Build one pipeline from one of kl_reproject.c's two shaders. Both are shared
// with the visionOS compositor; the only thing this file decides is which one
// runs and what it draws into.
static id<MTLRenderPipelineState> klvm_pipeline_blend(const char *msl, const char *vfn,
                                                      const char *ffn, const char *what,
                                                      int blend) {
    NSError *err = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:[NSString stringWithUTF8String:msl]
                                             options:nil error:&err];
    id<MTLFunction> vf = [lib newFunctionWithName:[NSString stringWithUTF8String:vfn]];
    id<MTLFunction> ff = [lib newFunctionWithName:[NSString stringWithUTF8String:ffn]];
    if (!vf || !ff) {
        fprintf(stderr, "  [vmtl] %s shader failed to compile: %s\n", what,
                err.localizedDescription.UTF8String ?: "?");
        return nil;
    }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = vf;
    pd.fragmentFunction = ff;
    // sRGB, so the encode from the eye's linear RGBA16F is the display
    // hardware's job. The readback path did this in software with powf(1/2.2)
    // per channel per pixel — 15 million calls a frame at 2198x2304, which is
    // why it needed a 64K-entry LUT to be affordable at all.
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    // Only the OVERLAY pass blends. The eye passes force alpha to 1.0 and must
    // — a guest leaves the eye texture's alpha at 0 because the layer is
    // composited opaque, so a blending eye pass hands the window server a
    // transparent frame over a correct picture. A UI quad's alpha is authored
    // and is the whole reason it is a separate layer.
    if (blend) {
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    }
    id<MTLRenderPipelineState> p = [g_dev newRenderPipelineStateWithDescriptor:pd
                                                                        error:&err];
    if (!p)
        fprintf(stderr, "  [vmtl] %s pipeline failed: %s\n", what,
                err.localizedDescription.UTF8String ?: "?");
    return p;
}

static id<MTLRenderPipelineState> klvm_pipeline(const char *msl, const char *vfn,
                                                const char *ffn, const char *what) {
    return klvm_pipeline_blend(msl, vfn, ffn, what, 0);
}

// The uniforms for this composite, in the viewer's degenerate case of it: one
// eye, no eye offset, and a display frustum defined to be the frustum the guest
// rendered with. That last one is what makes the reprojection pass reduce
// exactly to the blit when nothing has moved — the quad's corners land on
// NDC ±1 — so any difference in the picture is the pose delta and nothing else.
//
// `stage` is passed IN, not read here. kl_ovrp_last_complete_stage() advances
// whenever the guest finishes a frame, so reading it a second time inside one
// composite can return a different stage from the one whose texture is being
// sampled — and then this builds the pose of one picture to place another. It
// is a narrow window, but it is hit exactly when the guest is producing frames
// fastest, and the result is a picture reprojected by a delta that was never
// real. One read per composite, threaded through everything that needs it.
// The unwarp grid for the composite, cached.
//
// Rebuilt only when the rate map or the eye texture's size changes, which is
// the point of doing the unwarp this way: a rate map is static, so the squeeze
// is resolved once on the CPU into texture coordinates the rasterizer then
// interpolates for free. See kl_reproject.h.
static void klvm_s2p(void *ctx, float sx, float sy, float *px, float *py) {
    id<MTLRasterizationRateMap> m = (__bridge id<MTLRasterizationRateMap>)ctx;
    MTLSamplePosition p = [m mapScreenToPhysicalCoordinates:MTLSamplePositionMake(sx, sy)
                                                   forLayer:0];
    *px = p.x; *py = p.y;
}

static id<MTLBuffer> g_grid_buf;
static void         *g_grid_map;
static uint32_t      g_grid_w, g_grid_h, g_grid_verts;
static float         g_grid_vp[4];

// Which eye this window shows. One, because the window is one flat surface —
// but WHICH one is a question worth being able to ask: a guest under Oculus
// symmetric projection renders the two eyes into different sub-rects of one
// texture, so eye 1 is the one whose crop and whose quad can
// be wrong while eye 0 looks perfect. Without this the only instrument for that
// is a person wearing the headset.
//
// Pairs with KL_OVRP_EYE_TAN, which is what gives a host run a canted display
// to have the problem on in the first place.
// Side by side (the default for EVERY stereo guest, on every composite path —
// per-layer OpenXR projection layers, the reprojected eye and the plain blit):
// both eyes, left | right, each letterboxed by its own frustum — the SteamVR
// mirror window's layout. A mono guest, or one with no second eye to show, gets
// one eye at full window; so does KL_VIEW_EYE=0/1, which pins that eye. While
// one half is being drawn this names its eye, and everything that asks
// klvm_eye() (uniforms, crop, overlays) answers for that half.
static int g_cur_eye = -1;
static int klvm_sbs(void) {
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("KL_VIEW_EYE");
        on = !(e && (*e == '0' || *e == '1'));         // a pinned eye means single-eye
        if (on) fprintf(stderr, "  [view] both eyes side by side (KL_VIEW_EYE=0 or 1 "
                                "for one eye, full window)\n");
    }
    return on;
}
static int klvm_eye(void) {
    if (g_cur_eye >= 0) return g_cur_eye;
    static int eye = -1;
    if (eye < 0) {
        eye = kl_env_int("KL_VIEW_EYE", 0);
        if (eye != 1) eye = 0;
        if (eye) fprintf(stderr, "  [view] KL_VIEW_EYE=1: compositing the RIGHT eye\n");
    }
    return eye;
}

// `vp` is the guest's render viewport for this frame in eye-texture pixels, or
// NULL for the whole texture — kl_ovrp_render_pose.viewport, read from the same
// frame record the uniforms come from so the crop and the pose describe one
// picture. It is part of the cache key: Beat Saber changes it on entering a
// map, and a grid built for the menu's viewport crops the map's picture (or
// fails to crop it) with nothing reporting either.
static id<MTLBuffer> klvm_grid_buffer(id<MTLTexture> src, const float *vp,
                                      uint32_t *out_verts) {
    void *map = kl_glfb_eye_rate_map();
    uint32_t tw = src ? (uint32_t)src.width : 0, th = src ? (uint32_t)src.height : 0;
    float want_vp[4] = { 0, 0, 0, 0 };
    if (vp && vp[2] > 0 && vp[3] > 0) memcpy(want_vp, vp, sizeof want_vp);
    if (!g_grid_buf || map != g_grid_map || tw != g_grid_w || th != g_grid_h ||
        memcmp(want_vp, g_grid_vp, sizeof want_vp) != 0) {
        g_grid_map = map; g_grid_w = tw; g_grid_h = th;
        memcpy(g_grid_vp, want_vp, sizeof want_vp);
        int cropped = want_vp[2] > 0 && want_vp[3] > 0 &&
                      ((uint32_t)want_vp[2] != tw || (uint32_t)want_vp[3] != th ||
                       want_vp[0] != 0 || want_vp[1] != 0);
        uint32_t nx = 1, ny = 1;
        if (map) {
            // One cell per ZONE, so every grid vertex lands on a breakpoint of
            // the piecewise-linear map and the unwarp is exact rather than a
            // sampling of it. The zone counts travel with the map because a
            // built MTLRasterizationRateMap does not report them.
            id<MTLRasterizationRateMap> m = (__bridge id<MTLRasterizationRateMap>)map;
            MTLSize scr = [m screenSize];
            int zx = 0, zy = 0;
            kl_glfb_eye_rate_zones(&zx, &zy);
            if (zx > 0 && zy > 0) {
                // The map's own zones. Exact: a rate map is piecewise linear
                // with breakpoints at the zone boundaries, which are uniform in
                // SCREEN space, so a screen-uniform grid of exactly this many
                // cells has a vertex on every breakpoint.
                nx = (uint32_t)zx; ny = (uint32_t)zy;
            } else {
                // A map we did not build does not report its zones — but the
                // GRANULARITY cell count is recoverable, which is what ALVR's
                // DummyMetalRenderer does to reconstruct a descriptor. Uniform
                // in physical rather than screen space, so it is not
                // zone-aligned and the unwarp is a dense sampling of the curve
                // rather than an exact reproduction of it; at ~32px granules
                // the residual is well under a texel.
                MTLSize gran = [m physicalGranularity];
                MTLSize phys = [m physicalSizeForLayer:0];
                nx = gran.width  ? (uint32_t)(phys.width  / gran.width)  : 16;
                ny = gran.height ? (uint32_t)(phys.height / gran.height) : 16;
            }
            if (nx < 1) nx = 1;
            if (ny < 1) ny = 1;
            if (nx > KL_REPROJECT_GRID_MAX) nx = KL_REPROJECT_GRID_MAX;
            if (ny > KL_REPROJECT_GRID_MAX) ny = KL_REPROJECT_GRID_MAX;
            uint32_t n = kl_reproject_grid_entries(nx, ny);
            simd_float2 *tmp = calloc(n, sizeof *tmp);
            kl_reproject_grid_build(tmp, nx, ny, cropped ? want_vp : NULL,
                                    (float)scr.width, (float)scr.height,
                                    (float)tw, (float)th, klvm_s2p, map);
            g_grid_buf = [g_dev newBufferWithBytes:tmp length:n * sizeof *tmp
                                           options:MTLResourceStorageModeShared];
            free(tmp);
            fprintf(stderr, "  [view] unwarp grid %ux%u for a %ux%u eye texture "
                            "(screen %lux%lu, viewport %.0f,%.0f %.0fx%.0f)\n", nx, ny, tw, th,
                    (unsigned long)scr.width, (unsigned long)scr.height,
                    cropped ? want_vp[0] : 0.f, cropped ? want_vp[1] : 0.f,
                    cropped ? want_vp[2] : (float)tw, cropped ? want_vp[3] : (float)th);
        } else if (cropped) {
            // No rate map, but the guest still drew into part of the texture.
            // One cell is enough — with no map the mapping is affine, so the
            // four corners carry it exactly.
            uint32_t n = kl_reproject_grid_entries(1, 1);
            simd_float2 tmp[8];
            kl_reproject_grid_build(tmp, 1, 1, want_vp, (float)tw, (float)th,
                                    (float)tw, (float)th, NULL, NULL);
            g_grid_buf = [g_dev newBufferWithBytes:tmp length:n * sizeof *tmp
                                           options:MTLResourceStorageModeShared];
            fprintf(stderr, "  [view] render viewport %.0f,%.0f %.0fx%.0f of a %ux%u eye "
                            "texture — compositing that sub-rect\n",
                    want_vp[0], want_vp[1], want_vp[2], want_vp[3], tw, th);
        } else {
            uint32_t n = kl_reproject_grid_entries(1, 1);
            simd_float2 tmp[8];
            kl_reproject_grid_identity(tmp);
            g_grid_buf = [g_dev newBufferWithBytes:tmp length:n * sizeof *tmp
                                           options:MTLResourceStorageModeShared];
        }
        g_grid_verts = kl_reproject_grid_vertices(nx, ny);
    }
    if (out_verts) *out_verts = g_grid_verts;
    return g_grid_buf;
}

// Every shader in kl_reproject.c samples a `texture2d_array<float>`, and until
// Open Brush every eye texture that reached them was one: the GL provider
// allocates 2D arrays by construction (KleptonCompositor's `.type2DArray`), and
// BONELAB's Vulkan eye image carries two array layers because the eye IS the
// layer there. An OpenXR guest on Vulkan with one swapchain per eye produces a
// plain MTLTextureType2D, and binding that to an array-typed slot does not
// fail — it samples nothing useful, which composites as a FLAT COLOUR over a
// texture that is provably full of picture.
//
// A texture VIEW rather than a second pipeline: the type is the only thing
// wrong, the pixel format and the storage are already right, and one shader
// that every path shares is worth more than two that can drift. Cached, because
// a view per frame is an allocation per frame — there are at most eyes x stages
// of them.
//
// It can legitimately fail (a view needs the source's usage to permit it), and
// then it says so and returns the original, which composites exactly as badly
// as before but names the reason instead of leaving a flat colour to be read as
// a dead guest.
// Two eyes' worth of every compositor slot: the per-layer composite samples one
// texture per layer per eye, so a guest with three layers of three images in
// flight has eighteen distinct sources rather than the two the eye pass had. A
// cache that fills builds a fresh texture view on every frame for everything
// past it — correct, and an allocation per layer per frame.
#define KLVM_VIEWS 32
static struct { void *src; id<MTLTexture> view; } g_views[KLVM_VIEWS];

static id<MTLTexture> klvm_array_view(id<MTLTexture> src) {
    if (!src || src.textureType == MTLTextureType2DArray) return src;
    void *key = (__bridge void *)src;
    for (int i = 0; i < KLVM_VIEWS; i++)
        if (g_views[i].src == key) return g_views[i].view ?: src;
    id<MTLTexture> v = [src newTextureViewWithPixelFormat:src.pixelFormat
                                              textureType:MTLTextureType2DArray
                                                   levels:NSMakeRange(0, src.mipmapLevelCount)
                                                   slices:NSMakeRange(0, 1)];
    static int said;
    if (!v && !said) {
        said = 1;
        fprintf(stderr, "  [vmtl] the eye texture is MTLTextureType %u and an "
                        "array VIEW of it could not be made — the shaders sample "
                        "texture2d_array, so this composites as a flat colour\n",
                (unsigned)src.textureType);
    }
    for (int i = 0; i < KLVM_VIEWS; i++)
        if (!g_views[i].src) { g_views[i].src = key; g_views[i].view = v; break; }
    return v ?: src;
}

// The guest's PROJECTION layers, each drawn as its own quad with its own
// frustum, in submission order — see kl_ovrp.h. Returns how many were drawn.
//
// This replaces the eye pass rather than adding to it: the layers ARE the eye
// picture, and the single-eye path is what a guest that submits one projection
// layer (which is every guest but Steam Link) still takes, unchanged, because
// it files no list at all.
//
// No depth attachment and no blending here, so submission order is the whole
// of the ordering: layer 0 is the backdrop and each one after it draws over
// what is under it, which is what OpenXR's back-to-front means.
static int klvm_draw_proj_layers(id<MTLRenderCommandEncoder> enc, int eye,
                                 const kl_ovrp_proj_layer *list, int n,
                                 simd_float4x4 proj) {
    if (!g_pipe_rp) return 0;
    // Where the head is NOW. Each layer's quad corrects the delta against its
    // OWN render pose, which is why the pose travels in the record per layer.
    float px, py, pz, qx, qy, qz, qw;
    kl_ovrp_get_head_pose(&px, &py, &pz, &qx, &qy, &qz, &qw);
    simd_float4x4 device = simd_matrix4x4(simd_quaternion(qx, qy, qz, qw));
    int drawn = 0;
    for (int i = 0; i < n; i++) {
        kl_ovrp_proj_layer pl = list[i];
        if (pl.slot[eye] < 0) continue;      // this layer does not name this eye
        int slice = 0;
        void *tp = kl_glfb_eye_mtl_texture(eye, pl.slot[eye], &slice);
        if (!tp) {
            // Named once per layer index: "the guest submitted a layer we
            // cannot reach" and "the guest submitted fewer layers" are the same
            // picture, which is the failure this whole pass exists to end.
            static int said[8];
            if (i < 8 && !said[i]) {
                said[i] = 1;
                fprintf(stderr, "  [vmtl] projection layer %d has no MTLTexture in "
                                "slot %d for eye %d — not composited\n",
                        i, pl.slot[eye], eye);
            }
            continue;
        }
        // Through the array view for the reason the eye is: every shader in
        // kl_reproject.c samples a texture2d_array, and a plain 2D bound to one
        // returns nothing with no error at all.
        id<MTLTexture> t = klvm_array_view((__bridge id<MTLTexture>)tp);
        kl_reproject_uniforms u = kl_proj_layer_build(&pl, eye, device,
                                                      matrix_identity_float4x4,
                                                      proj, (uint32_t)slice);
        if (!u.visible) continue;
        [enc setRenderPipelineState:g_pipe_rp];
        [enc setVertexBytes:&u length:sizeof u atIndex:0];
        [enc setFragmentBytes:&u length:sizeof u atIndex:0];
        // Adapted from avp-play (MIT, github.com/myMartek/avp-play) runtime/gfx/kl_view_mtl.m.
        // The layer's own grid, not the identity: the picture may be only part
        // of the texture (kl_ovrp_proj_layer.rect).
        simd_float2 lgrid[KL_PROJ_LAYER_GRID_ENTRIES];
        kl_proj_layer_grid(&pl, lgrid);
        [enc setVertexBytes:lgrid length:sizeof lgrid atIndex:1];
        [enc setFragmentTexture:t atIndex:0];
        [enc setFragmentTexture:t atIndex:1];
        [enc setFragmentSamplerState:g_samp atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                vertexCount:kl_reproject_grid_vertices(1, 1)];
        drawn++;
    }
    return drawn;
}

// A frame the per-layer pass could not compose, held rather than presented
// black. Counted and named on the first, then once a second, because "the
// composite is holding" and "the guest has stopped" are the same still picture
// and a silent hold would hide either.
static unsigned long g_holds;
static void klvm_hold_frame(int nproj, int eye) {
    g_holds++;
    static double last;
    double now = (double)clock() / CLOCKS_PER_SEC;
    if (g_holds == 1 || now - last > 1.0) {
        last = now;
        char which[16];
        if (eye < 0) snprintf(which, sizeof which, "either eye");
        else snprintf(which, sizeof which, "eye %d", eye);
        fprintf(stderr, "  [vmtl] %d projection layer(s) submitted and none could be "
                        "composited for %s — holding the previous frame "
                        "(%lu so far)\n", nproj, which, g_holds);
    }
}

// One overlay's uniforms, for the eye this window is showing.
//
// The head pose here is the FULL one, translation included, where the eye pass
// deliberately drops it: an overlay is a thing at a place, and the delta between
// the head and that place is the whole geometry. `device_from_view` is identity
// because this viewer has no eye offset of its own — it renders one eye's
// picture into a flat window (see klvm_eye).
static kl_overlay_uniforms klvm_overlay_uniforms(const kl_ovrp_overlay *ov, int eye) {
    float px, py, pz, qx, qy, qz, qw;
    kl_ovrp_get_head_pose(&px, &py, &pz, &qx, &qy, &qz, &qw);
    simd_float4x4 device = simd_matrix4x4(simd_quaternion(qx, qy, qz, qw));
    device.columns[3] = simd_make_float4(px, py, pz, 1.0f);

    // The same projection the eye picture is placed with, so the overlay lands
    // at the angular size the eye pass would have given it. Read from the frame
    // record for the same reason klvm_uniforms does — the tangents are what the
    // guest was told to render with.
    int stage = kl_ovrp_last_complete_stage();
    if (stage < 0) stage = 0;
    kl_ovrp_render_pose r;
    int have = kl_ovrp_stage_render_pose(stage, &r);
    float shown[4];
    const float *t = have ? klvm_display_tan(eye, r.tangents[eye], shown) : (const float[]){1, 1, 1, 1};
    simd_float4x4 proj = kl_reproject_projection(t[0], t[1], t[2], t[3], 0.03f);
    return kl_overlay_build(ov, eye, device, matrix_identity_float4x4, proj);
}

// The layers that are NOT the eye — a guest's splash screens, loading screens
// and UI, which on an Unreal title is everything that is not the world.
//
// Drawn after the eye pass, in the same encoder and against the same depth: the
// eye quad sits at KL_REPROJECT_DEPTH (500 m by default) and an overlay at a few
// metres is in front of it, so ordering falls out of the geometry rather than
// out of the draw order. `KL_GUEST_OVERLAYS=0` is the A/B — NOT `KL_OVERLAYS`,
// which is the visionOS SYSTEM overlays (the Home indicator) and a different
// question with a confusingly similar name.
static void klvm_draw_overlays(id<MTLRenderCommandEncoder> enc, int eye, int stage) {
    (void)stage;
    static int on = -1;
    if (on < 0) on = kl_env_on("KL_GUEST_OVERLAYS", 1);
    if (!on || !g_pipe_ov) return;
    int n = kl_ovrp_overlay_count();
    // The two passes have to agree about where the head is. An overlay is placed
    // against the CURRENT head pose; the plain blit places the eye picture
    // nowhere at all (it fills the window). So on the blit fallback the overlay
    // slides across a picture that does not move, which looks like a placement
    // bug and is not one.
    if (n > 0 && !g_pipe_rp) {
        static int said;
        if (!said) {
            said = 1;
            fprintf(stderr, "  [vmtl] the eye picture is a flat blit and the overlay "
                            "below is POSED, so the two will disagree as the head "
                            "moves\n");
        }
    }
    for (int i = 0; i < n; i++) {
        kl_ovrp_overlay ov;
        if (!kl_ovrp_overlay_get(i, &ov)) continue;
        int tw = 0, th = 0;
        // Two producers, one consumer, in the order they can answer: a Vulkan
        // guest's layer image belongs to kl_vulkan, and everything else reaches
        // a compositor through kl_glfb's layer table — an OpenXR quad on GL is
        // bound there, and a Vulkan one is recorded there too. Asking kl_vulkan
        // first keeps RE4's path exactly as it was.
        void *texp = kl_vulkan_layer_mtl_texture(ov.layer_id, ov.stage, eye, &tw, &th);
        if (!texp) texp = kl_glfb_layer_mtl_texture(ov.layer_id, ov.stage, &tw, &th);
        // Named once per layer, because "the guest submitted a layer we cannot
        // reach" and "the guest submitted no layers" are the same picture.
        if (!texp) {
            static int said[8];
            int k = ov.layer_id & 7;
            if (!said[k]) {
                said[k] = 1;
                fprintf(stderr, "  [vmtl] overlay layer %d (shape %d, stage %d) has no "
                                "MTLTexture — not composited%s\n",
                        ov.layer_id, ov.shape, ov.stage,
                        kl_vulkan_guest_active() || kl_glfb_has_mtl_layer_provider()
                            ? ""
                            : " (no Metal layer provider is registered, so the "
                              "guest's own GL storage is all there is)");
            }
            continue;
        }
        kl_overlay_uniforms u = klvm_overlay_uniforms(&ov, eye);
        if (!u.visible) {
            static int said[8];
            int k = ov.layer_id & 7;
            if (!said[k]) {
                said[k] = 1;
                fprintf(stderr, "  [vmtl] overlay layer %d: shape %d %.2fx%.2f m — "
                                "REFUSED rather than drawn as a quad\n",
                        ov.layer_id, ov.shape, ov.size[0], ov.size[1]);
            }
            continue;
        }
        id<MTLTexture> t = (__bridge id<MTLTexture>)texp;
        [enc setRenderPipelineState:g_pipe_ov];
        [enc setVertexBytes:&u length:sizeof u atIndex:0];
        [enc setFragmentBytes:&u length:sizeof u atIndex:0];
        [enc setFragmentTexture:t atIndex:0];
        [enc setFragmentSamplerState:g_samp atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        static int said;
        if (!said) {
            said = 1;
            fprintf(stderr, "  [vmtl] compositing overlay layer %d: %.2fx%.2f m at "
                            "(%.2f %.2f %.2f), %dx%d texture%s\n",
                    ov.layer_id, ov.size[0], ov.size[1],
                    ov.pose[4], ov.pose[5], ov.pose[6], tw, th,
                    ov.head_locked ? ", HEAD-LOCKED" : "");
        }
    }
}

// The frustum this window SHOWS, which is the display's — kl_ovrp_eye_view, the
// frustum the frontend published — and not necessarily the one the frame was
// rendered with (the record's tangents). Those differ when a guest renders
// PAST the display: an OpenVR overscan (KL_OPENVR_OVERSCAN) renders each eye
// wider so the device compositor has a margin to reproject into, and Alyx
// symmetrises an asymmetric frustum. The device compositor projects through
// the drawable's own projection, so the margin is clipped there until the head
// turns into it; projecting through the record's tangents here instead showed
// the whole margin and shrank the picture by the overscan. With the two equal —
// every other guest — this is exactly what it was. KL_VIEW_FRUSTUM=rendered
// restores the record's.
static const float *klvm_display_tan(int eye, const float *rendered, float out[4]) {
    static int rend = -1;
    if (rend < 0) {
        const char *v = getenv("KL_VIEW_FRUSTUM");
        rend = v && !strcmp(v, "rendered");
    }
    if (rend || !rendered) return rendered;
    float t[4] = { 0, 0, 0, 0 };
    kl_ovrp_eye_view(eye, NULL, NULL, NULL, NULL, NULL, NULL, NULL, t);
    if (!(t[0] > 0 && t[1] > 0 && t[2] > 0 && t[3] > 0)) return rendered;
    static int said;
    if (!said && (fabsf(t[0] - rendered[0]) > 1e-3f || fabsf(t[1] - rendered[1]) > 1e-3f ||
                  fabsf(t[2] - rendered[2]) > 1e-3f || fabsf(t[3] - rendered[3]) > 1e-3f)) {
        said = 1;
        fprintf(stderr, "  [vmtl] eye %d rendered l=%.3f r=%.3f t=%.3f b=%.3f, shown through the "
                        "display's l=%.3f r=%.3f t=%.3f b=%.3f — the margin is the reprojection's "
                        "(KL_VIEW_FRUSTUM=rendered shows it all)\n", eye,
                rendered[0], rendered[1], rendered[2], rendered[3], t[0], t[1], t[2], t[3]);
    }
    memcpy(out, t, sizeof t);
    return out;
}

// KL_VIEW_SWIM=1 — the swim, as a number. For world points straight ahead of
// the head at 0.5, 1, 3 m and far away, where THIS composite draws the guest's
// picture of the point (the record's render pose, the same model-view the pass
// uses) against where the point really is from the head now: the angular error
// a world-fixed object shows, in arcminutes, mean and worst over 2 s. Zero is a
// world that stays put; a turn with a stale, unpredicted render pose leaves the
// neck's translation (the eyes swing on a lever about the neck) uncorrected,
// largest on near content. Monocular, at the head (the viewer's eye offset).
static void klvm_swim(const kl_ovrp_render_pose *r, const kl_reproject_uniforms *u,
                      const float hp[3], const float hq[4]) {
    static int on = -1;
    if (on < 0) on = kl_env_on("KL_VIEW_SWIM", 0);
    if (!on || !r || !r->serial) return;
    static const float dist[4] = { 0.5f, 1.0f, 3.0f, 1000.0f };
    static double sum[4], worst[4], dsum, t0;
    static unsigned n;
    simd_quatf qd = simd_quaternion(hq[0], hq[1], hq[2], hq[3]);
    simd_quatf qr = simd_quaternion(r->qx, r->qy, r->qz, r->qw);
    simd_float3 pd = simd_make_float3(hp[0], hp[1], hp[2]);
    simd_float3 pr = simd_make_float3(r->px, r->py, r->pz);
    for (int i = 0; i < 4; i++) {
        simd_float3 w = pd + simd_act(qd, simd_make_float3(0, 0, -dist[i]));
        simd_float3 v = simd_act(simd_inverse(qr), w - pr);          // render-head frame
        if (!(v.z < -1e-4f)) continue;
        simd_float3 qp = v * (u->depth / -v.z);                       // on the quad
        simd_float4 s = simd_mul(u->model_view, simd_make_float4(qp, 1.0f));
        simd_float3 sd = simd_normalize(s.xyz);
        float c = -sd.z; if (c > 1) c = 1;
        double e = acos(c) * 180.0 / M_PI * 60.0;                       // arcmin off the centre
        sum[i] += e; if (e > worst[i]) worst[i] = e;
    }
    dsum += 2.0 * acos(fmin(1.0, fabs(simd_dot(qd.vector, qr.vector)))) * 180.0 / M_PI;
    n++;
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    double now = ts.tv_sec + ts.tv_nsec * 1e-9;
    if (!t0) t0 = now;
    if (now - t0 >= 2.0 && n) {
        fprintf(stderr, "  [vmtl] swim over %u composites (arcmin, mean/worst): 0.5 m %.1f/%.1f, "
                        "1 m %.1f/%.1f, 3 m %.1f/%.1f, far %.1f/%.1f; render->display turn %.2f deg avg\n",
                n, sum[0] / n, worst[0], sum[1] / n, worst[1], sum[2] / n, worst[2], sum[3] / n, worst[3],
                dsum / n);
        for (int i = 0; i < 4; i++) sum[i] = worst[i] = 0;
        dsum = 0; n = 0; t0 = now;
    }
}

static kl_reproject_uniforms klvm_uniforms(int stage, uint32_t slice, int flip_y) {
    kl_ovrp_render_pose r;
    int have = kl_ovrp_stage_render_pose(stage, &r);

    // Where the head is now; the delta against r is what this pass corrects.
    // WITH its position, as the device compositor's originFromHead has it, so
    // the translation term (kl_reproject_build) differences two positions in
    // one space rather than the render position against the origin.
    simd_float4x4 device = matrix_identity_float4x4;
    float hp[3] = { 0, 0, 0 }, hq[4] = { 0, 0, 0, 1 };
    if (have) {
        kl_ovrp_get_head_pose(&hp[0], &hp[1], &hp[2], &hq[0], &hq[1], &hq[2], &hq[3]);
        device = simd_matrix4x4(simd_quaternion(hq[0], hq[1], hq[2], hq[3]));
        device.columns[3] = simd_make_float4(hp[0], hp[1], hp[2], 1.0f);
    }

    int eye = klvm_eye();
    float shown[4];
    const float *t = have ? klvm_display_tan(eye, r.tangents[eye], shown) : (const float[]){1, 1, 1, 1};
    simd_float4x4 proj = kl_reproject_projection(t[0], t[1], t[2], t[3], 0.03f);
    // grid_per_eye = 0: this window draws ONE eye, so the grid it binds has one
    // block and that block was built with this eye's viewport.
    kl_reproject_uniforms u = kl_reproject_build(have ? &r : NULL, eye, device,
                                                 matrix_identity_float4x4, proj, slice, flip_y, 0);
    if (have) klvm_swim(&r, &u, hp, hq);
    return u;
}

// Which frame of the guest's this composite would be showing, and 0 for "none
// yet". Two sources, because the two graphics APIs answer it in different
// places: ANGLE signals an MTLSharedEvent from inside its own command stream
// (kl_glfb), and a Vulkan guest has no such event — kl_vulkan waits for its
// queue at ovrp_EndFrame4 and publishes a serial instead. Both are monotonic and
// both mean "there is a NEW, COMPLETE picture", which is all this file wants of
// them.
//
// `*fenced` is the difference that matters at the encoder: a GL value is one the
// guest's queue really signals on our MTLSharedEvent, so the composite can WAIT
// on it, and a Vulkan serial is not — kl_vulkan already made the queue idle
// before publishing it. Waiting on the event for a Vulkan serial would be a
// command buffer that is committed and never executes: a presented drawable,
// healthy counters, and a black window (KL_CP_NOFENCE's failure, in the one
// place it cannot be turned off).
static uint64_t klvm_frame_value(int *fenced) {
    uint64_t v = kl_glfb_gpu_fence_value();
    if (fenced) *fenced = v != 0;
    return v ? v : (uint64_t)kl_vulkan_frame_serial();
}

// The first non-eye layer's MTLTexture, or NULL. Both producers, in the order
// klvm_draw_overlays asks them — this exists so the compositor can be STARTED
// by a guest that has no eye at all, and it has to find the same storage that
// pass will sample or the device would be picked from a texture nothing draws.
static void *klvm_first_layer_texture(void) {
    for (int i = 0; i < kl_ovrp_overlay_count(); i++) {
        kl_ovrp_overlay ov;
        if (!kl_ovrp_overlay_get(i, &ov)) continue;
        int w = 0, h = 0;
        void *t = kl_vulkan_layer_mtl_texture(ov.layer_id, ov.stage, 0, &w, &h);
        if (!t) t = kl_glfb_layer_mtl_texture(ov.layer_id, ov.stage, &w, &h);
        if (t) return t;
    }
    return NULL;
}

// ---- The achievement toast (host twin of KleptonHUD.swift's) -----------------
//
// kl_steam.c hands every achievement a StoreStats confirmed as unlocked to the
// unlock handler (kl_steam_bridge.h). On device the app registers one and
// draws the panel in the immersive layer; on the Mac THIS registers itself
// when nothing else has, and draws the same panel, rasterised by the same
// CoreText layout, flat at the top of the window — the verification surface
// for the panel's content and timing. KL_TOAST_TEST=1 queues a fake one 5 s
// after the viewer starts.
#define KLVM_TOAST_W 1024
#define KLVM_TOAST_H 288
#define KLVM_TOAST_QMAX 16
typedef struct { char *name, *desc, *icon; const char *header; } klvm_toast;   // header NULL: achievement; icon "-": none
static klvm_toast g_tq[KLVM_TOAST_QMAX];
static int g_tq_n;
static pthread_mutex_t g_tq_mu = PTHREAD_MUTEX_INITIALIZER;
static klvm_toast g_tcur;               // the one on screen (render thread only)
static double g_tcur_t0 = -1;
static id<MTLTexture> g_ttex;
static id<MTLRenderPipelineState> g_tpipe;
static double g_tstart = -1;            // viewer start, for KL_TOAST_TEST
static int g_ttest_fired;

static double klvm_now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + t.tv_nsec * 1e-9;
}

static void klvm_toast_push(const char *api, const char *name, const char *desc, const char *icon) {
    (void)api;
    pthread_mutex_lock(&g_tq_mu);
    if (g_tq_n < KLVM_TOAST_QMAX) {
        g_tq[g_tq_n++] = (klvm_toast){ strdup(name ? name : ""), strdup(desc ? desc : ""),
                                       strdup(icon ? icon : ""), NULL };
    }
    pthread_mutex_unlock(&g_tq_mu);
}

// "spanish"/"latam" -> Spanish, everything else English.
static int klvm_toast_es(void) {
    const char *l = kl_steam_game_language();
    return l && (!strncmp(l, "spanish", 7) || !strncmp(l, "latam", 5));
}
static const char *klvm_toast_header(void) {
    return klvm_toast_es() ? "\xF0\x9F\x8F\x86 Logro desbloqueado"
                           : "\xF0\x9F\x8F\x86 Achievement unlocked";
}

static CTLineRef klvm_line(const char *text, CTFontRef font, CGColorRef color, double max_w) {
    CFStringRef s = CFStringCreateWithCString(NULL, text ? text : "", kCFStringEncodingUTF8);
    if (!s) s = CFSTR("");
    const void *k[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
    const void *v[] = { font, color };
    CFDictionaryRef at = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks,
                                            &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef as = CFAttributedStringCreate(NULL, s, at);
    CTLineRef line = CTLineCreateWithAttributedString(as);
    CFAttributedStringRef es = CFAttributedStringCreate(NULL, CFSTR("…"), at);
    CTLineRef ell = CTLineCreateWithAttributedString(es);
    CTLineRef t = CTLineCreateTruncatedLine(line, max_w, kCTLineTruncationEnd, ell);
    if (t) { CFRelease(line); line = t; }
    CFRelease(ell); CFRelease(es); CFRelease(as); CFRelease(at); CFRelease(s);
    return line;
}

// The panel, 1024x288, premultiplied RGBA8 (sRGB), row 0 at the top. The
// layout is KleptonHUD.swift's ToastRaster, number for number.
static id<MTLTexture> klvm_toast_raster(const klvm_toast *t) {
    const int W = KLVM_TOAST_W, H = KLVM_TOAST_H;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, W, H, 8, W * 4, cs,
                                           kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!c) { CGColorSpaceRelease(cs); return nil; }
    CGContextClearRect(c, CGRectMake(0, 0, W, H));
    // Card: dark, slightly translucent, with a hairline gold edge.
    CGPathRef card = CGPathCreateWithRoundedRect(CGRectMake(4, 4, W - 8, H - 8), 56, 56, NULL);
    CGContextAddPath(c, card);
    CGContextSetRGBFillColor(c, 0.07, 0.08, 0.10, 0.92);
    CGContextFillPath(c);
    CGContextAddPath(c, card);
    CGContextSetRGBStrokeColor(c, 1.0, 0.80, 0.35, 0.55);
    CGContextSetLineWidth(c, 4);
    CGContextStrokePath(c);
    CGPathRelease(card);
    // Icon, 192 px, rounded, vertically centred; a gold placeholder without one.
    CGRect ir = CGRectMake(48, (H - 192) / 2.0, 192, 192);
    CGPathRef ip = CGPathCreateWithRoundedRect(ir, 28, 28, NULL);
    CGImageRef img = NULL;
    int no_icon = t->icon && !strcmp(t->icon, "-");
    if (t->icon && *t->icon && !no_icon) {
        CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)t->icon,
                                                             (CFIndex)strlen(t->icon), false);
        CGImageSourceRef src = u ? CGImageSourceCreateWithURL(u, NULL) : NULL;
        if (src) { img = CGImageSourceCreateImageAtIndex(src, 0, NULL); CFRelease(src); }
        if (u) CFRelease(u);
    }
    if (!no_icon) {
        CGContextSaveGState(c);
        CGContextAddPath(c, ip);
        CGContextClip(c);
        if (img) CGContextDrawImage(c, ir, img);
        else { CGContextSetRGBFillColor(c, 0.85, 0.66, 0.22, 1); CGContextFillRect(c, ir); }
        CGContextRestoreGState(c);
    }
    CGPathRelease(ip);
    if (img) CGImageRelease(img);
    // Text column.
    double x = no_icon ? 72 : 48 + 192 + 40, maxw = W - x - 48;
    CTFontRef fh = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, 34, NULL);
    CTFontRef fn = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, 50, NULL);
    CTFontRef fd = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 32, NULL);
    CGColorRef gold = CGColorCreateSRGB(1.0, 0.80, 0.35, 1);
    CGColorRef white = CGColorCreateSRGB(1, 1, 1, 1);
    CGColorRef grey = CGColorCreateSRGB(0.78, 0.80, 0.84, 1);
    CTLineRef lh = klvm_line(t->header ? t->header : klvm_toast_header(), fh, gold, maxw);
    CTLineRef ln = klvm_line(t->name, fn, white, maxw);
    // Baselines from the top: header 78, name 146, description lines 198 / 240.
    CGContextSetTextPosition(c, x, H - 78);  CTLineDraw(lh, c);
    CGContextSetTextPosition(c, x, H - 146); CTLineDraw(ln, c);
    if (t->desc && *t->desc) {
        // Two lines at most: wrap with a typesetter, truncate the second.
        CFStringRef s = CFStringCreateWithCString(NULL, t->desc, kCFStringEncodingUTF8);
        if (s) {
            const void *k[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
            const void *v[] = { fd, grey };
            CFDictionaryRef at = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks,
                                                    &kCFTypeDictionaryValueCallBacks);
            CFAttributedStringRef as = CFAttributedStringCreate(NULL, s, at);
            CTTypesetterRef ts = CTTypesetterCreateWithAttributedString(as);
            CFIndex len = CFStringGetLength(s);
            CFIndex n1 = CTTypesetterSuggestLineBreak(ts, 0, maxw);
            CTLineRef l1 = CTTypesetterCreateLine(ts, CFRangeMake(0, n1));
            CGContextSetTextPosition(c, x, H - 198); CTLineDraw(l1, c);
            CFRelease(l1);
            if (n1 < len) {
                CFStringRef rest = CFStringCreateWithSubstring(NULL, s, CFRangeMake(n1, len - n1));
                char buf[1024];
                if (rest && CFStringGetCString(rest, buf, sizeof buf, kCFStringEncodingUTF8)) {
                    CTLineRef l2 = klvm_line(buf, fd, grey, maxw);
                    CGContextSetTextPosition(c, x, H - 240); CTLineDraw(l2, c);
                    CFRelease(l2);
                }
                if (rest) CFRelease(rest);
            }
            CFRelease(ts); CFRelease(as); CFRelease(at); CFRelease(s);
        }
    }
    CFRelease(lh); CFRelease(ln);
    CFRelease(fh); CFRelease(fn); CFRelease(fd);
    CGColorRelease(gold); CGColorRelease(white); CGColorRelease(grey);

    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                     width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [g_dev newTextureWithDescriptor:td];
    [tex replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0
             withBytes:CGBitmapContextGetData(c) bytesPerRow:(NSUInteger)W * 4];
    CGContextRelease(c);
    CGColorSpaceRelease(cs);
    return tex;
}

static const char *klvm_toast_msl =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VO { float4 p [[position]]; float2 uv; };\n"
    "vertex VO klvm_toast_v(uint vid [[vertex_id]]) {\n"
    "  float2 c = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);\n"
    "  VO o; o.p = float4(c.x * 2 - 1, 1 - c.y * 2, 0, 1); o.uv = c; return o; }\n"
    "fragment float4 klvm_toast_f(VO i [[stage_in]], texture2d<float> t [[texture(0)]],\n"
    "                             sampler s [[sampler(0)]], constant float &a [[buffer(0)]]) {\n"
    "  return t.sample(s, i.uv) * a; }\n"
    "fragment float4 klvm_fade_f(VO i [[stage_in]], constant float4 &c [[buffer(0)]]) {\n"
    "  return float4(c.rgb * c.a, c.a); }\n";
static id<MTLRenderPipelineState> g_fpipe;    // the compositor fade (kl_ovrp_fade_color)

static void klvm_toast_start(void) {
    g_tstart = klvm_now();
    if (!kl_steam_unlock_handler()) kl_steam_set_unlock_handler(klvm_toast_push);
    NSError *err = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:[NSString stringWithUTF8String:klvm_toast_msl]
                                             options:nil error:&err];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"klvm_toast_v"];
    pd.fragmentFunction = [lib newFunctionWithName:@"klvm_toast_f"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;          // premultiplied
    pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    g_tpipe = pd.vertexFunction && pd.fragmentFunction
        ? [g_dev newRenderPipelineStateWithDescriptor:pd error:&err] : nil;
    pd.fragmentFunction = [lib newFunctionWithName:@"klvm_fade_f"];
    g_fpipe = pd.vertexFunction && pd.fragmentFunction
        ? [g_dev newRenderPipelineStateWithDescriptor:pd error:nil] : nil;
    if (!g_tpipe)
        fprintf(stderr, "  [toast] viewer toast pipeline failed: %s — unlocks are only logged\n",
                err.localizedDescription.UTF8String ?: "?");
}

// The compositor fade and the gate prompt (kl_ovrp.h), the host twins of
// KleptonHUD.swift's: the fade over the whole window, the prompt panel in its
// middle, both under the achievement toast.
static unsigned       g_pserial;
static int            g_pon;
static id<MTLTexture> g_ptex;
static void klvm_fade_prompt_draw(id<MTLCommandBuffer> cmd, id<MTLTexture> target) {
    float c[4];
    int fade = g_fpipe && kl_ovrp_fade_color(c);
    static int was_fading;
    if (fade != was_fading) {
        was_fading = fade;
        fprintf(stderr, "  [view] compositor fade %s (%.2f %.2f %.2f a %.2f)\n",
                fade ? "drawing" : "clear", c[0], c[1], c[2], c[3]);
    }
    char text[256];
    unsigned serial = kl_ovrp_prompt(text, sizeof text);
    if (serial != g_pserial) {
        g_pserial = serial;
        int was = g_pon;
        g_pon = text[0] != 0;
        g_ptex = nil;
        if (g_pon) {
            int es = klvm_toast_es();
            klvm_toast t = { (char *)(es ? "Pulsa el gatillo para empezar" : "Pull the trigger to start"),
                             strcmp(text, "-") ? text : (char *)"", (char *)"-",
                             es ? "Nivel cargado" : "Level loaded" };
            g_ptex = klvm_toast_raster(&t);
        }
        if (g_pon || was)
            fprintf(stderr, "  [view] gate prompt %s%s%s\n", g_pon ? "shown: " : "cleared", g_pon ? text : "",
                    g_pon && !g_ptex ? " (raster FAILED)" : "");
    }
    if (!fade && !g_ptex) return;
    double tw = target.width, th = target.height;
    MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
    p.colorAttachments[0].texture = target;
    p.colorAttachments[0].loadAction = MTLLoadActionLoad;
    p.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:p];
    enc.label = @"klepton viewer fade + prompt";
    if (fade) {
        [enc setViewport:(MTLViewport){ 0, 0, tw, th, 0.0, 1.0 }];
        [enc setRenderPipelineState:g_fpipe];
        [enc setFragmentBytes:c length:sizeof c atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    if (g_ptex && g_tpipe) {
        double w = fmin(tw * 0.6, KLVM_TOAST_W * fmax(th / 1400.0, 0.5));
        double h = w * KLVM_TOAST_H / KLVM_TOAST_W;
        float a = 1.0f;
        [enc setViewport:(MTLViewport){ (tw - w) * 0.5, (th - h) * 0.5, w, h, 0.0, 1.0 }];
        [enc setRenderPipelineState:g_tpipe];
        [enc setFragmentTexture:g_ptex atIndex:0];
        [enc setFragmentSamplerState:g_samp atIndex:0];
        [enc setFragmentBytes:&a length:sizeof a atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [enc endEncoding];
}

// Drawn last, over whatever the frame is. Fade 0.3 s in and out, 5 s on
// screen (KL_TOAST_SECS), then the next queued one.
static void klvm_toast_draw(id<MTLCommandBuffer> cmd, id<MTLTexture> target) {
    if (!target) return;
    klvm_fade_prompt_draw(cmd, target);
    if (!g_tpipe) return;
    double now = klvm_now();
    if (!g_ttest_fired && g_tstart > 0 && now - g_tstart >= 5.0 && kl_env_on("KL_TOAST_TEST", 0)) {
        g_ttest_fired = 1;
        int es = klvm_toast_es();
        klvm_toast_push("KL_TOAST_TEST", es ? "Prueba de logro" : "Test achievement",
                        es ? "KL_TOAST_TEST: un aviso falso para comprobar el panel."
                           : "KL_TOAST_TEST: a fake toast to check the panel.", "");
        fprintf(stderr, "  [toast] KL_TOAST_TEST: fake toast queued\n");
    }
    double secs = kl_env_float("KL_TOAST_SECS", 5.0);
    if (g_tcur_t0 >= 0 && now - g_tcur_t0 > secs) {
        free(g_tcur.name); free(g_tcur.desc); free(g_tcur.icon);
        memset(&g_tcur, 0, sizeof g_tcur);
        g_tcur_t0 = -1; g_ttex = nil;
    }
    if (g_tcur_t0 < 0) {
        pthread_mutex_lock(&g_tq_mu);
        int have = g_tq_n > 0;
        if (have) {
            g_tcur = g_tq[0];
            memmove(g_tq, g_tq + 1, (size_t)(g_tq_n - 1) * sizeof g_tq[0]);
            g_tq_n--;
        }
        pthread_mutex_unlock(&g_tq_mu);
        if (!have) return;
        g_ttex = klvm_toast_raster(&g_tcur);
        g_tcur_t0 = now;
        fprintf(stderr, "  [toast] showing \"%s\" (%s)\n", g_tcur.name, klvm_toast_header());
    }
    if (!g_ttex) return;
    double e = now - g_tcur_t0;
    float a = (float)fmin(1.0, fmin(e / 0.3, (secs - e) / 0.3));
    if (a <= 0) return;
    double tw = target.width, th = target.height;
    double w = fmin(tw * 0.6, KLVM_TOAST_W * fmax(th / 1400.0, 0.5));
    double h = w * KLVM_TOAST_H / KLVM_TOAST_W;
    MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
    p.colorAttachments[0].texture = target;
    p.colorAttachments[0].loadAction = MTLLoadActionLoad;
    p.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:p];
    enc.label = @"klepton viewer toast";
    [enc setViewport:(MTLViewport){ (tw - w) * 0.5, th * 0.06, w, h, 0.0, 1.0 }];
    [enc setRenderPipelineState:g_tpipe];
    [enc setFragmentTexture:g_ttex atIndex:0];
    [enc setFragmentSamplerState:g_samp atIndex:0];
    [enc setFragmentBytes:&a length:sizeof a atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [enc endEncoding];
}

int kl_viewmtl_start(void *metal_layer) {
    if (g_started) return 1;
    if (!metal_layer) return 0;

    // Nothing to composite until the guest has taken its eye textures, which
    // happens inside nativeRecreateGfxState. Returning 0 here is not a failure,
    // it is "not yet" — kl_view.c retries every frame.
    //
    // ...or until it has submitted a LAYER, which for a guest presenting its
    // whole frame as an OpenXR quad is the only thing it will ever do. Waiting
    // for an eye there is waiting forever, with a window that never opens and
    // a picture arriving intact the whole time.
    void *eyep = kl_glfb_eye_mtl_texture(0, 0, NULL);
    if (!eyep) eyep = klvm_first_layer_texture();
    // ...or a FLAT guest, whose whole picture is kl_glfb's IOSurface-backed
    // root surface — no eye, no layers, ever. Available from init, so this
    // starter succeeds on the first retry rather than seconds in.
    int flat_w = 0, flat_h = 0;
    void *flatp = eyep ? NULL : kl_glfb_flat_surface(&flat_w, &flat_h);
    if (!eyep && !flatp) return 0;

    // **The device is the EYE TEXTURE's, not MTLCreateSystemDefaultDevice() and
    // no longer ANGLE's either.** A drawable from a different device cannot be
    // the destination of a pass that samples this texture, so the only device
    // that can possibly be right is the one that owns the thing being sampled —
    // and asking the texture is the one phrasing that is right for both guests.
    // On GL that is ANGLE's device by construction (the extension requires the
    // eye texture to belong to the display's device); on the
    // Vulkan path it is MoltenVK's, and `kl_glfb_mtl_device()` answers NULL
    // there because ANGLE was never brought up at all. The flat surface is an
    // IOSurface, which belongs to no device until wrapped — ANGLE's is the one
    // rendering into it, so ANGLE's is the one that can sample it coherently.
    g_dev = eyep ? ((__bridge id<MTLTexture>)eyep).device
                 : (__bridge id<MTLDevice>)kl_glfb_mtl_device();
    if (!g_dev) return 0;
    if (flatp) {
        MTLTextureDescriptor *fd = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                         width:(NSUInteger)flat_w
                                        height:(NSUInteger)flat_h
                                     mipmapped:NO];
        fd.usage = MTLTextureUsageShaderRead;
        g_flat_tex = [g_dev newTextureWithDescriptor:fd
                                           iosurface:(IOSurfaceRef)flatp
                                               plane:0];
        if (!g_flat_tex) {
            static int said;
            if (!said++)
                fprintf(stderr, "  [vmtl] could not wrap the flat IOSurface in an "
                                "MTLTexture — the window stays black\n");
            g_dev = nil;
            return 0;
        }
        g_flat_w = flat_w;
        g_flat_h = flat_h;
    }
    g_queue = [g_dev newCommandQueue];
    g_event = [g_dev newSharedEvent];
    if (!g_queue || !g_event) {
        // WHICH of the two, and only once: this is retried every frame until it
        // takes, so an unnamed failure is a thousand identical lines that say
        // the compositor is down and not what is down about it.
        static int said;
        if (!said) {
            said = 1;
            fprintf(stderr, "  [vmtl] %s on %s — the hardware compositor cannot "
                            "start, so the window stays black\n",
                    !g_queue && !g_event ? "no command queue and no shared event"
                    : !g_queue          ? "newCommandQueue returned nil"
                                        : "newSharedEvent returned nil",
                    g_dev.name.UTF8String);
        }
        // Not half-started: a queue kept across a failed retry is a queue
        // leaked per frame.
        g_queue = nil; g_event = nil;
        return 0;
    }

    // The blit drives the liveness downsample, whose geometry is irrelevant to
    // counting lit pixels, and stands in if the reprojection shader fails.
    g_pipe = klvm_pipeline(kl_reproject_blit_msl(), "kl_blit_v", "kl_blit_f", "blit");
    if (!g_pipe) return 0;

    // The GUEST's non-eye layers.
    g_pipe_ov = klvm_pipeline_blend(kl_reproject_overlay_msl(), "kl_ov_v", "kl_ov_f",
                                    "overlay", 1);
    g_pipe_rp = klvm_pipeline(kl_reproject_msl(), "kl_reproject_v",
                              "kl_reproject_f", "reprojection");
    if (kl_reproject_depth_mode() == 2 || kl_reproject_depth_vis()) {
        NSError *derr = nil;
        id<MTLLibrary> dlib = [g_dev newLibraryWithSource:
                                  [NSString stringWithUTF8String:kl_reproject_depth_msl()]
                                                  options:nil error:&derr];
        if (!dlib)
            fprintf(stderr, "  [swim] depth shaders failed to compile: %s\n",
                    derr.localizedDescription.UTF8String ?: "?");
        if (dlib && kl_reproject_depth_vis())
            g_pipe_dvis = klvm_pipeline(kl_reproject_depth_msl(), "kl_reproject_depth_v",
                                        "kl_reproject_depthvis_f", "depth false-colour");
        id<MTLFunction> kf = [dlib newFunctionWithName:@"kl_depth_probe_k"];
        if (kf) g_depth_probe = [g_dev newComputePipelineStateWithFunction:kf error:&derr];
        for (int i = 0; i < 2 && g_depth_probe; i++)
            g_depth_probe_buf[i] = [g_dev newBufferWithLength:KL_DEPTH_PROBE_SIDE * KL_DEPTH_PROBE_SIDE
                                                              * sizeof(float)
                                                      options:MTLResourceStorageModeShared];
        fprintf(stderr, "  [swim] viewer: depth false-colour %s, depth probe %s\n",
                g_pipe_dvis ? "ON" : "off", g_depth_probe ? "on" : "OFF");
    }

    // Fall back rather than refuse to start. This is retried every frame, so
    // returning 0 on a shader that will never compile is a viewer that stays
    // black forever and says why exactly once — where the blit is a picture,
    // correct whenever the head has not moved since the guest rendered.
    if (!g_pipe_rp)
        fprintf(stderr, "  [vmtl] compositing through the plain BLIT instead — "
                        "no reprojection, no viewport crop\n");

    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    g_samp = [g_dev newSamplerStateWithDescriptor:sd];

    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                     width:KLVM_STAT_DIM height:KLVM_STAT_DIM
                                 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;      // so the completion handler can read it
    g_stat = [g_dev newTextureWithDescriptor:td];

    g_layer = (__bridge CAMetalLayer *)metal_layer;
    g_layer.device = g_dev;
    g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    g_layer.framebufferOnly = YES;

    // Registering the fence is what switches kl_glfb's swap handling from
    // "read the eye back" to "signal that the frame is done". From here on
    // nothing copies pixels.
    //
    // Only when ANGLE is the renderer. On the Vulkan path kl_glfb has no
    // context, no swap and nothing to signal, and registering an event it will
    // never touch would make kl_glfb_has_gpu_fence() answer yes for a fence
    // that does not exist — which is a claim the end-of-run report and
    // kl_ovrp's present gate both read.
    int gl = kl_glfb_mtl_device() != NULL;
    if (gl) kl_glfb_set_gpu_fence((__bridge void *)g_event);

    klvm_toast_start();
    g_started = 1;
    fprintf(stderr, "  [vmtl] hardware compositor on %s — no readback, "
                    "no CPU copies%s%s\n", g_dev.name.UTF8String,
            gl ? "" : ", VULKAN guest (the eye texture is MoltenVK's and the "
                      "frame seam is kl_vulkan's serial)",
            g_pipe_rp ? ", reprojecting against the guest's render pose" : "");
    return 1;
}

// The completion handler's half of the HUD. Same definition of "lit" as
// kl_glfb's capture (the sum of the three tone-mapped channels above 12), read
// off a 64x64 render of the same source, then scaled to the eye's pixel count
// so the number is comparable to the one the readback path printed.
static void klvm_read_stats(int src_w, int src_h) {
    uint8_t px[KLVM_STAT_DIM * KLVM_STAT_DIM * 4];
    [g_stat getBytes:px bytesPerRow:KLVM_STAT_DIM * 4
          fromRegion:MTLRegionMake2D(0, 0, KLVM_STAT_DIM, KLVM_STAT_DIM)
         mipmapLevel:0];
    unsigned lit = 0;
    for (int i = 0; i < KLVM_STAT_DIM * KLVM_STAT_DIM; i++) {
        // BGRA8_sRGB: the stored bytes are already the encoded values, which is
        // the same domain kl_glfb's powf(c, 1/2.2) produced. Channel order does
        // not matter to a sum.
        unsigned lum = px[i * 4] + px[i * 4 + 1] + px[i * 4 + 2];
        if (lum > 12) lit++;
    }
    double frac = (double)lit / (KLVM_STAT_DIM * KLVM_STAT_DIM);
    __atomic_store_n(&g_lit, (unsigned long)(frac * src_w * src_h), __ATOMIC_RELAXED);
}

// The measurement that says whether reprojection is doing anything: how far the
// head turned between the pose the guest rendered this picture with and the
// pose it is being shown at. Zero means the guest is keeping up and the pass is
// a blit; anything else is motion the composite is now hiding. Printed rarely,
// because it is a per-frame quantity and the interesting thing is its scale.
static void klvm_note_delta(int stage) {
    static unsigned n;
    static float worst;
    kl_ovrp_render_pose r;
    if (stage < 0 || !kl_ovrp_stage_render_pose(stage, &r)) return;
    float px, py, pz, qx, qy, qz, qw;
    kl_ovrp_get_head_pose(&px, &py, &pz, &qx, &qy, &qz, &qw);
    float d = kl_reproject_delta_degrees(&r, simd_matrix4x4(simd_quaternion(qx, qy, qz, qw)));
    if (d > worst) worst = d;
    if (++n % 120 == 0) {
        fprintf(stderr, "  [vmtl] timewarp: stage %d serial %llu, delta %.2f deg "
                        "(worst %.2f)\n", stage, (unsigned long long)r.serial,
                (double)d, (double)worst);
        worst = 0;
    }
}

// The flat guest's composite: the IOSurface the guest renders into, blitted to
// the drawable, letterboxed to the panel's aspect. Single-buffered storage, so
// the shared-event wait orders this pass after the last COMPLETED guest frame
// but cannot fence the next one out — for the 2D pairing shell that can show a
// partial repaint, which is the trade against the full-frame readback and
// pipeline stall every swap that this pass replaces.
static int klvm_present_flat(int win_w, int win_h) {
    int fenced = 0;
    uint64_t v = klvm_frame_value(&fenced);
    if (!v || v == g_last_value) return 0;   // no new guest frame
    if (win_w <= 0 || win_h <= 0) return 0;
    CGSize want = CGSizeMake(win_w, win_h);
    if (!CGSizeEqualToSize(g_layer.drawableSize, want)) g_layer.drawableSize = want;
    id<CAMetalDrawable> drawable = [g_layer nextDrawable];
    if (!drawable) return 0;
    id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
    if (!cmd) return 0;
    if (fenced) [cmd encodeWaitForEvent:g_event value:v];

    // The blit samples through the array view like every kl_reproject shader
    // (a plain 2D bound to a texture2d_array returns nothing, silently), and
    // flip 0 is the GL orientation — the same value every GL eye carries.
    id<MTLTexture> src = klvm_array_view(g_flat_tex);
    kl_blit_uniforms bu = { 0u, 0u };

    double scale = fmin((double)win_w / g_flat_w, (double)win_h / g_flat_h);
    double dw = g_flat_w * scale, dh = g_flat_h * scale;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
    enc.label = @"klepton viewer flat";
    [enc setViewport:(MTLViewport){ (win_w - dw) * 0.5, (win_h - dh) * 0.5,
                                    dw, dh, 0.0, 1.0 }];
    [enc setRenderPipelineState:g_pipe];
    [enc setFragmentTexture:src atIndex:0];
    [enc setFragmentTexture:src atIndex:1];
    [enc setFragmentSamplerState:g_samp atIndex:0];
    [enc setFragmentBytes:&bu length:sizeof bu atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];

    // The liveness downsample, same as the eye path's: the HUD's `lit` is the
    // only number separating a blank window from a dead pipeline.
    if (g_stat && src) {
        MTLRenderPassDescriptor *sp = [MTLRenderPassDescriptor renderPassDescriptor];
        sp.colorAttachments[0].texture = g_stat;
        sp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        sp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> se = [cmd renderCommandEncoderWithDescriptor:sp];
        se.label = @"klepton viewer liveness";
        [se setRenderPipelineState:g_pipe];
        [se setFragmentTexture:src atIndex:0];
        [se setFragmentTexture:src atIndex:1];
        [se setFragmentSamplerState:g_samp atIndex:0];
        [se setFragmentBytes:&bu length:sizeof bu atIndex:0];
        [se drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [se endEncoding];
        int cw = g_flat_w, ch = g_flat_h;
        [cmd addCompletedHandler:^(id<MTLCommandBuffer> b) {
            (void)b;
            klvm_read_stats(cw, ch);
        }];
    }

    klvm_toast_draw(cmd, drawable.texture);
    [cmd presentDrawable:drawable];
    [cmd commit];
    g_last_value = v;
    g_frames++;
    return 1;
}

// The aspect a half (or the window) is letterboxed to: the frustum the picture
// was rendered with, from the frame record. The texture's own shape is not it —
// a guest that renders a wider field than the stage image's aspect (Alyx:
// 3456x2880 of picture scaled into a 2290x2400 stage image) came out squeezed,
// which is how the viewer showed a too-tall picture.
static void klvm_eye_aspect(int stage, int eye, id<MTLTexture> src, double *w, double *h) {
    kl_ovrp_render_pose r;
    float shown[4];
    const float *t = kl_ovrp_stage_render_pose(stage, &r) ? klvm_display_tan(eye, r.tangents[eye], shown) : NULL;
    if (t && t[0] + t[1] > 0 && t[2] + t[3] > 0) { *w = t[0] + t[1]; *h = t[2] + t[3]; return; }
    *w = src ? (double)src.width : 1832; *h = src ? (double)src.height : 1920;
}

static void klvm_draw_eye_rp(id<MTLRenderCommandEncoder> enc, int stage, int eye,
                             id<MTLTexture> src, kl_blit_uniforms bu, int flip) {
        kl_reproject_uniforms u = klvm_uniforms(stage, bu.slice, flip);
        // KL_CP_DEPTH_VIS: the same quad, coloured by the game's depth.
        id<MTLTexture> dtex = nil;
        kl_ovrp_render_pose dr;
        if (g_pipe_dvis && kl_ovrp_stage_render_pose(stage, &dr) && (dr.depth_valid & (1 << eye))) {
            void *dp = kl_glfb_eye_mtl_depth(eye, stage);
            if (dp) dtex = (__bridge id<MTLTexture>)dp;
        }
        if (dtex) {
            kl_reproject_depth_uniforms du = kl_reproject_depth_build(&dr, eye, u.projection);
            [enc setRenderPipelineState:g_pipe_dvis];
            [enc setVertexBytes:&du length:sizeof du atIndex:2];
            [enc setFragmentTexture:dtex atIndex:2];
            [enc setFragmentTexture:dtex atIndex:3];
            g_depth_frames++;
        } else {
            [enc setRenderPipelineState:g_pipe_rp];
        }
        [enc setVertexBytes:&u length:sizeof u atIndex:0];
        [enc setFragmentBytes:&u length:sizeof u atIndex:0];
        // The unwarp grid. Identity until the guest's eye textures are
        // foveated, at which point it carries the squeeze this pass has to
        // undo (kl_reproject.h). A buffer rather than setVertexBytes: that
        // path caps at 4 KB and a grid dense enough to land on the map's zone
        // boundaries is bigger than that.
        uint32_t gverts = 0;
        // ...and the crop, from the same record the uniforms above came from,
        // for the eye this window is showing. The two are not interchangeable
        // — see klvm_eye — and the visionOS compositor, which draws both in one
        // pass, carries a grid block per eye rather than picking.
        kl_ovrp_render_pose vr;
        float vp[4] = { 0, 0, 0, 0 };
        if (kl_ovrp_stage_render_pose(stage, &vr)) {
            for (int i = 0; i < 4; i++) vp[i] = (float)vr.viewport[eye][i];
            // The same guard KleptonCompositor carries, and for the same reason:
            // a rect measured against another eye texture describes nothing
            // about this one, and cropping by it MAGNIFIES the picture by the
            // ratio rather than mis-placing it (kl_ovrp.h, viewport_of). Refuse
            // rather than rescale — with the two disagreeing, which texels the
            // guest wrote is not known.
            if (vp[2] > 0 && vr.viewport_of[0] > 0 && src &&
                ((uint32_t)vr.viewport_of[0] != (uint32_t)src.width ||
                 (uint32_t)vr.viewport_of[1] != (uint32_t)src.height)) {
                static int said_skew;
                if (!said_skew) {
                    said_skew = 1;
                    fprintf(stderr, "  [view] the render viewport is %dx%d of a %dx%d "
                                    "eye texture, but the texture in hand is %ux%u — "
                                    "NOT cropping, that rect describes another "
                                    "texture\n",
                            vr.viewport[eye][2], vr.viewport[eye][3],
                            vr.viewport_of[0], vr.viewport_of[1],
                            (unsigned)src.width, (unsigned)src.height);
                }
                vp[0] = vp[1] = vp[2] = vp[3] = 0;
            }
            // Once, and ALSO when it is zero — the same line KleptonCompositor
            // prints, so a host run and a device run answer "did the rect reach
            // the composite?" in the same words. `[ovrp] render viewport` is
            // the guest's own thread saying what it submitted; this is the
            // compositor saying what it read, and the two failures those
            // separate are indistinguishable by eye.
            static int said;
            if (!said) {
                said = 1;
                fprintf(stderr, "  [view] first render viewport read from the frame "
                                "record: %d,%d %dx%d (stage %d, serial %llu)%s\n",
                        vr.viewport[eye][0], vr.viewport[eye][1], vr.viewport[eye][2],
                        vr.viewport[eye][3], stage, (unsigned long long)vr.serial,
                        vr.viewport[eye][2] <= 0
                            ? "  <- ZERO, so no crop is applied; compare against "
                              "the [ovrp] render viewport line" : "");
            }
        }
        id<MTLBuffer> gbuf = klvm_grid_buffer(src, vp[2] > 0 ? vp : NULL, &gverts);
        [enc setVertexBuffer:gbuf offset:0 atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:gverts];
}

// Once a second, in depth mode 2 or under KL_CP_DEPTH_VIS: sample eye 0's
// depth (32x32, on the GPU, after this frame) for the [swim] line, and print
// that line — the viewer's half of it, with no anchors (there are none here).
static void klvm_depth_probe(id<MTLCommandBuffer> cmd, int stage) {
    if (!g_depth_probe) return;
    g_swim_frames++;
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    double now = ts.tv_sec + ts.tv_nsec * 1e-9;
    if (!g_swim_t0) g_swim_t0 = now;
    if (now - g_swim_t0 >= 1.0) {
        kl_reproject_swim_log(kl_reproject_depth_mode(), g_swim_frames, 0, 0, 0, 0, 0,
                              g_depth_frames);
        g_swim_frames = g_depth_frames = 0;
        g_swim_t0 = now;
    }
    if (now - g_depth_probe_t < 1.0) return;
    kl_ovrp_render_pose r;
    if (!kl_ovrp_stage_render_pose(stage, &r) || !(r.depth_valid & 1)) return;
    void *dp = kl_glfb_eye_mtl_depth(0, stage);
    if (!dp) return;
    g_depth_probe_t = now;
    id<MTLBuffer> buf = g_depth_probe_buf[g_depth_probe_n++ & 1];
    id<MTLComputeCommandEncoder> ce = [cmd computeCommandEncoder];
    if (!ce || !buf) return;
    ce.label = @"klepton depth probe";
    [ce setComputePipelineState:g_depth_probe];
    [ce setTexture:(__bridge id<MTLTexture>)dp atIndex:0];
    [ce setBuffer:buf offset:0 atIndex:0];
    [ce dispatchThreadgroups:MTLSizeMake(KL_DEPTH_PROBE_SIDE / 8, KL_DEPTH_PROBE_SIDE / 8, 1)
       threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [ce endEncoding];
    // The viewer's own frustum stands in for a drawable's: only its near plane
    // is read, for the clamp, and the probe reports raw and linear depth.
    simd_float4x4 proj = kl_reproject_projection(1, 1, 1, 1, 0.03f);
    kl_reproject_depth_uniforms du = kl_reproject_depth_build(&r, 0, proj);
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> b) {
        (void)b;
        kl_reproject_depth_probe_note((const float *)buf.contents, KL_DEPTH_PROBE_SIDE, &du);
    }];
}

int kl_viewmtl_present(int win_w, int win_h) {
    if (!g_started) return 0;
    if (g_flat_tex) return klvm_present_flat(win_w, win_h);

    // Re-read every frame rather than caching: Unity really does re-create its
    // eye textures at a different size partway through startup (1832x1920 ->
    // 2198x2304, measured), and a cached texture would silently become the
    // previous allocation.
    // ...and the STAGE has to be re-read too, now that there is more than one.
    // The eye swapchain is double-buffered (kl_ovrp.c, KLOVRP_STAGES_DEFAULT),
    // so stage 0 holds every other frame; sampling it unconditionally shows
    // half the frames and reads as a halved frame rate rather than as a bug.
    // The last *complete* stage is the same thing the visionOS compositor asks
    // for. It is read HERE and nowhere else in this composite: klvm_uniforms and
    // klvm_note_delta used to ask again, and two reads of a value the guest is
    // advancing pair one stage's picture with another stage's pose — the exact
    // failure this stage-keying exists to prevent.
    int stage = kl_ovrp_last_complete_stage();
    if (stage < 0) stage = 0;
    int slice = 0;
    int eye = klvm_eye();
    // Only when the guest's last frame actually carried one. The eye textures
    // outlive the frame that filled them, so without this the eye keeps being
    // drawn after the guest has stopped submitting a projection layer — and on
    // a guest that alternates (JKXR: a projection pair in the world, a quad in
    // the menu, out of the SAME swapchains) that is the menu composited twice,
    // once full-field underneath and once on its panel.
    void *texp = kl_ovrp_eye_layer_live()
                     ? kl_glfb_eye_mtl_texture(eye, stage, &slice) : NULL;
    // ...and how many projection layers the guest's last frame submitted. Any
    // at all and the eye pass below becomes the per-layer pass: they are the
    // same picture, described whole instead of flattened into one texture. Zero
    // is every guest that does not file the list, which is every guest but
    // Steam Link and every run under KL_XR_LAYERS=0.
    // Snapshotted HERE, before the frame fence is read below, and that order is
    // the whole of it: the guest publishes its frame's completion before the
    // records that describe it (klxr_EndFrame), so a list read first can only
    // be older than the fence read second — never newer, which would be drawing
    // layers whose blits this pass never waited for. Seen as one frame of a
    // picture from several frames ago.
    kl_ovrp_proj_layer g_list[8];
    int nproj = kl_ovrp_eye_layer_live()
        ? kl_ovrp_proj_layers_snapshot(g_list, (int)(sizeof g_list / sizeof g_list[0]))
        : 0;
    // No eye picture is not the same as no picture. A guest can present its
    // whole frame as an OpenXR quad layer and submit no projection layer at all
    // — JKXR does for its entire menu — and returning here showed a black window
    // for a run whose panel was arriving intact. The eye pass is skipped in that
    // case and the overlay pass below is the composite.
    if (!texp && nproj == 0 && kl_ovrp_overlay_count() == 0) return 0;
    id<MTLTexture> src = texp ? (__bridge id<MTLTexture>)texp : nil;
    // Every shader in kl_reproject.c samples a `texture2d_array<float>`, so a
    // source that is NOT an array is a bound type the shader cannot read — and
    // Metal does not refuse it, it returns nothing useful, which composites as a
    // flat colour over a texture that is provably full of picture. Named once,
    // because the two failures ("the guest drew nothing" and "we cannot sample
    // what it drew") are identical on screen.
    {
        static int said;
        if (!said) {
            said = 1;
            if (!src)
                fprintf(stderr, "  [vmtl] no eye texture — this guest's picture is "
                                "its composition layers alone; the eye pass is "
                                "skipped\n");
            else
                fprintf(stderr, "  [vmtl] eye source is MTLTexture type %u, %ux%u, "
                                "%lu array layer(s)%s\n",
                        (unsigned)src.textureType, (unsigned)src.width,
                        (unsigned)src.height, (unsigned long)src.arrayLength,
                        src.textureType == MTLTextureType2DArray
                            ? "" : "  <- NOT an array; sampled through an array view");
        }
    }
    // ...and this is that view. Dimensions, format and device are unchanged, so
    // everything below — the letterbox, the grid, the viewport guard — reads the
    // same numbers it always did.
    if (src) src = klvm_array_view(src);
    // Which way up the guest drew it, recorded with the texture — see
    // kl_reproject.h. Read per (eye, stage) rather than decided once, because
    // it is a property of the storage and not of this compositor.
    int flip = kl_glfb_eye_mtl_origin_top_left(eye, stage);

    int fenced = 0;
    uint64_t v = klvm_frame_value(&fenced);
    if (!v || v == g_last_value) return 0;   // no new guest frame

    if (win_w <= 0 || win_h <= 0) return 0;
    CGSize want = CGSizeMake(win_w, win_h);
    if (!CGSizeEqualToSize(g_layer.drawableSize, want)) g_layer.drawableSize = want;

    id<CAMetalDrawable> drawable = [g_layer nextDrawable];
    if (!drawable) return 0;
    id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
    if (!cmd) return 0;

    // The whole point of the shared event: the guest's frame is in ANGLE's
    // command queue, this pass is in ours, and Metal orders nothing across
    // queues on its own. Without this the compositor samples a texture the
    // guest may still be rendering into — which reads as intermittent tearing
    // and is exactly the kind of bug that gets blamed on the guest.
    //
    // ...when the value is one ANGLE's queue signals. A Vulkan serial is
    // published only after kl_vulkan has made the guest's queue idle, so the
    // ordering has already happened on the CPU and there is nothing to wait for
    // — see klvm_frame_value.
    if (fenced) [cmd encodeWaitForEvent:g_event value:v];

    // Side by side or one eye. SBS is the default for every stereo guest, on
    // every path below — per-layer, reprojected and plain blit alike — so the
    // window's shape no longer depends on which way the guest submits its
    // frame. One eye at full window when KL_VIEW_EYE pins one, or when the
    // guest has no second eye to show: a half left black is not a picture.
    int sbs = 0;
    if (klvm_sbs()) {
        if (nproj > 0) {
            int has[2] = { 0, 0 };
            for (int i = 0; i < nproj; i++) {
                if (g_list[i].slot[0] >= 0) has[0] = 1;
                if (g_list[i].slot[1] >= 0) has[1] = 1;
            }
            sbs = has[0] && has[1];
        } else if (src) {
            int s1 = 0;
            sbs = kl_glfb_eye_mtl_texture(1, stage, &s1) != NULL;
        } else {
            // Panels only (a guest's menu). Stereo if the frame record gives
            // the second eye a frustum, so the window keeps the same two-half
            // shape it has when the world comes back.
            kl_ovrp_render_pose r;
            sbs = kl_ovrp_stage_render_pose(stage, &r) &&
                  r.tangents[1][0] + r.tangents[1][1] > 0 &&
                  r.tangents[1][2] + r.tangents[1][3] > 0;
        }
    }

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
    enc.label = @"klepton viewer composite";
    [enc setFragmentSamplerState:g_samp atIndex:0];
    // The liveness pass below samples the pinned eye with these.
    kl_blit_uniforms bu = { (uint32_t)slice, (uint32_t)(flip ? 1 : 0) };

    int neyes = sbs ? 2 : 1;
    double cell_w = sbs ? win_w * 0.5 : (double)win_w;
    int drew = 0;
    for (int k = 0; k < neyes; k++) {
        int e = sbs ? k : eye;
        // While a half is drawn klvm_eye() names its eye, so the uniforms, the
        // crop and the overlays answer for that half. Left alone in single-eye
        // mode, where klvm_eye() already answers KL_VIEW_EYE.
        if (sbs) g_cur_eye = e;
        id<MTLTexture> es = src;
        int eslice = slice, eflip = flip;
        if (sbs && src) {
            void *ep = kl_glfb_eye_mtl_texture(e, stage, &eslice);
            es = ep ? klvm_array_view((__bridge id<MTLTexture>)ep) : nil;
            eflip = kl_glfb_eye_mtl_origin_top_left(e, stage);
        }

        // Letterbox: the eye is ~1832x1920, the window (or its half) is not.
        //
        // With no eye texture there is no picture to fit, but the overlay pass
        // still projects through the frustum the guest was given, so the
        // viewport has to keep THAT aspect or a panel comes out stretched by
        // the window's shape. The tangents are the frustum, so their ratio is
        // the aspect.
        double sw = 1832, sh = 1920;
        float et[4] = { 1, 1, 1, 1 };
        if (nproj > 0) {
            // The per-layer composite has no single source texture to fit: the
            // picture is several layers of DIFFERENT sizes and the guest changes
            // which of them it submits while it runs, so a window shaped by "the
            // texture in hand" changes shape frame to frame — which is the whole
            // picture jumping, not a letterbox detail. The display's own frustum
            // is what every layer is placed against, so its aspect is the
            // window's.
            kl_ovrp_eye_view(e, NULL, NULL, NULL, NULL, NULL, NULL, NULL, et);
            if (et[0] + et[1] > 0 && et[2] + et[3] > 0) {
                sw = et[0] + et[1];
                sh = et[2] + et[3];
            }
        } else if (es) { klvm_eye_aspect(stage, e, es, &sw, &sh); }
        else {
            kl_ovrp_render_pose r;
            const float *t = kl_ovrp_stage_render_pose(stage, &r) ? r.tangents[e] : NULL;
            if (t && t[0] + t[1] > 0 && t[2] + t[3] > 0) {
                sw = t[0] + t[1];
                sh = t[2] + t[3];
            }
        }
        double scale = fmin(cell_w / sw, (double)win_h / sh);
        double dw = sw * scale, dh = sh * scale;
        [enc setViewport:(MTLViewport){ k * cell_w + (cell_w - dw) * 0.5,
                                        (win_h - dh) * 0.5, dw, dh, 0.0, 1.0 }];
        // Slot 1 is the SECOND eye's texture, for a guest whose two eyes are
        // two unrelated MTLTextures rather than two slices of one
        // (kl_reproject.c, `src`). Each half composites ONE eye, so the same
        // texture goes into both slots and the shader's branch is a no-op
        // here. It is bound rather than left dangling because a fragment
        // function that DECLARES a texture and is given none samples undefined
        // storage, and the blit pipeline that ignores slot 1 costs nothing.
        if (es) {
            [enc setFragmentTexture:es atIndex:0];
            [enc setFragmentTexture:es atIndex:1];
        }
        kl_blit_uniforms ebu = { (uint32_t)eslice, (uint32_t)(eflip ? 1 : 0) };
        if (nproj > 0) {
            // The per-layer composite. The frustum is the DISPLAY's — what this
            // half is looking through — and every layer is then placed inside
            // it by its own tangents, never against another layer's. Taking it
            // from the frame record instead would take it from whichever layer
            // happened to be submitted last, which is a field of view that
            // changes while the guest runs and would move the picture with it.
            simd_float4x4 pproj = kl_reproject_projection(et[0], et[1], et[2], et[3], 0.03f);
            drew += klvm_draw_proj_layers(enc, e, g_list, nproj, pproj);
        } else if (!es) {
            // Nothing to draw here; the cleared drawable is the background the
            // overlay pass draws its panel onto.
        } else if (g_pipe_rp) {
            klvm_draw_eye_rp(enc, stage, e, es, ebu, eflip);
        } else {
            [enc setRenderPipelineState:g_pipe];
            [enc setFragmentBytes:&ebu length:sizeof ebu atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
        klvm_draw_overlays(enc, e, stage);
    }
    g_cur_eye = -1;

    // Per FRAME, not per half: one frame is one hold, one delta, one fence.
    if (nproj > 0 && !drew && kl_ovrp_overlay_count() == 0) {
        // Nothing composed in either half, and no panel to compose either. The
        // drawable is CLEARED, so presenting it is a black frame between two
        // good ones — flicker this compositor invents rather than flicker the
        // guest sent. The eye pass could not produce it: its texture outlives
        // the frame that filled it, so there was always something to draw.
        // Hold the previous frame instead, and count the hold.
        klvm_hold_frame(nproj, sbs ? -1 : eye);
        [enc endEncoding];
        [cmd commit];
        return 0;
    }
    if (nproj > 0 || (src && g_pipe_rp)) klvm_note_delta(stage);
    [enc endEncoding];

    // The liveness downsample, same source, same shader, 64x64. It is a second
    // pass rather than a readback of the drawable because a drawable with
    // framebufferOnly=YES cannot be read at all, and dropping that would cost
    // more than this pass does.
    // The liveness downsample: the HUD's `lit`, and the only number in the
    // viewer that says a blank window is a blank PICTURE rather than a dead
    // pipeline. So it must have something to look at even when there is no eye
    // — a guest whose whole frame is a quad would otherwise report lit=0 for a
    // panel that is arriving intact, which is an instrument answering
    // confidently about a subject it cannot see.
    id<MTLTexture> stat_src = src;
    if (!stat_src) {
        void *lp = klvm_first_layer_texture();
        // Through the array view for the same reason the eye is: every shader
        // in kl_reproject.c samples a texture2d_array, and a plain 2D bound to
        // one returns nothing with no error.
        if (lp) stat_src = klvm_array_view((__bridge id<MTLTexture>)lp);
    }
    if (g_stat && stat_src) {
        MTLRenderPassDescriptor *sp = [MTLRenderPassDescriptor renderPassDescriptor];
        sp.colorAttachments[0].texture = g_stat;
        sp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        sp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> se = [cmd renderCommandEncoderWithDescriptor:sp];
        se.label = @"klepton viewer liveness";
        [se setRenderPipelineState:g_pipe];
        [se setFragmentTexture:stat_src atIndex:0];
        [se setFragmentTexture:stat_src atIndex:1];
        [se setFragmentSamplerState:g_samp atIndex:0];
        kl_blit_uniforms sbu = { src ? bu.slice : 0u, bu.flip_y };
        [se setFragmentBytes:&sbu length:sizeof sbu atIndex:0];
        [se drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [se endEncoding];
        // The SOURCE's own size, which is what the fraction is scaled back up
        // to. `sw`/`sh` is the letterbox's aspect and is the eye's size only
        // when there is an eye — with a layer it is a ratio of tangents, and
        // scaling a fraction by 4 rounds every real picture down to lit=0.
        int cw = (int)stat_src.width, ch = (int)stat_src.height;
        [cmd addCompletedHandler:^(id<MTLCommandBuffer> b) {
            (void)b;
            klvm_read_stats(cw, ch);
        }];
    }

    klvm_depth_probe(cmd, stage);
    klvm_toast_draw(cmd, drawable.texture);
    [cmd presentDrawable:drawable];
    [cmd commit];
    g_last_value = v;
    g_frames++;
    return 1;
}

void kl_viewmtl_stop(void) {
    if (!g_started) return;
    // Unregister first: the guest may still be swapping, and a signal into a
    // released event is a crash rather than a missed frame.
    kl_glfb_set_gpu_fence(NULL);
    g_started = 0;
    g_pipe = nil; g_samp = nil; g_stat = nil; g_queue = nil;
    g_event = nil; g_layer = nil; g_dev = nil; g_flat_tex = nil;
    // The array views hold their source textures alive, and a restart would
    // otherwise match a stale key against a texture from the previous device.
    for (int i = 0; i < KLVM_VIEWS; i++) { g_views[i].src = NULL; g_views[i].view = nil; }
}

unsigned kl_viewmtl_frames(void) { return g_frames; }
unsigned long long kl_viewmtl_guest_frame(void) { return g_last_value; }
unsigned long kl_viewmtl_lit(void) {
    return __atomic_load_n(&g_lit, __ATOMIC_RELAXED);
}
