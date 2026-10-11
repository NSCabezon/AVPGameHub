// The reprojection pass — see kl_reproject.h for what it corrects and why the
// two compositors share it.
//
// Nothing here touches Metal or Compositor Services: it is matrices and a
// string, so it builds for the host and the device out of the same source list
// and can be reasoned about (and, on the host, run) without a headset.
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "kl_reproject.h"
#include "kl_env.h"

// KL_REPROJECT_NOCANT=1 — treat device_from_view as having no rotation.
//
// The guest is told where each eye *is* (kl_ovrp_set_eye_offset pushes
// view.transform's translation) and what each eye's frustum *shape* is (the
// tangents, recovered from the drawable's projection). It is never told that
// the eye is also TURNED: nodes 0 and 1 report the head's orientation. So a
// picture the guest rendered has no cant in it, while this pass applies
// view.transform's rotation to place it — and that rotation is equal and
// opposite in the two eyes, which is the one error shape the visual system
// cannot merge. Set this if the composite is logging a non-zero per-eye view
// rotation; the real fix is to give the guest the cant, which is a change to
// kl_ovrp's eye nodes rather than to this file.
static int klr_nocant(void) {
    static int on = -1;
    if (on < 0) on = kl_env_on("KL_REPROJECT_NOCANT", 0);
    return on;
}

// Whether the head's TRANSLATION between the render pose and the display pose
// is corrected as parallax for a plane at KL_REPROJECT_DEPTH. On by default and
// inert at the default depth — see the argument at the chain below.
// KL_REPROJECT_TRANSLATE=0 restores the rotation-only correction.
// Latched on first use like every other knob here. File scope rather than
// function scope only so kl_reproject_reset_depth can clear it: the gate has to
// place the same quad at two distances in one process, and a depth that could
// only be chosen once would make the parallax assertion untestable.
static float s_depth = 0.0f;

void kl_reproject_reset_depth(void) { s_depth = 0.0f; }

// The chroma key in force. Plain scalars written by a UI thread and read by the
// render thread: each is a single aligned word, a torn read is not possible on
// this platform, and the worst a race can do is use one slider's previous value
// for one frame while a person is dragging it — the same argument
// kl_openxr_set_grip_tune makes for the controller dials.
//
// Defaults are VisionOSALVRClient's, unchanged, so a value found there
// transfers: off, a mid green (16, 124, 16), and a fade band of 0.35 to 0.7.
// The environment seeds them once so a run can be keyed without opening a
// panel, and DEBUG_ENV_VARS.md carries the names.
static int   s_chroma_on = -1;
static float s_chroma_key[3] = { 16.0f / 255.0f, 124.0f / 255.0f, 16.0f / 255.0f };
static float s_chroma_min = 0.35f, s_chroma_max = 0.7f;

static void klr_chroma_init(void) {
    if (s_chroma_on >= 0) return;
    const char *c = kl_env_str("KL_CHROMA_COLOR", NULL);
    if (c) sscanf(c, "%f,%f,%f", &s_chroma_key[0], &s_chroma_key[1], &s_chroma_key[2]);
    const char *r = kl_env_str("KL_CHROMA_RANGE", NULL);
    if (r) sscanf(r, "%f,%f", &s_chroma_min, &s_chroma_max);
    s_chroma_on = kl_env_on("KL_CHROMA", 0);
}

void kl_reproject_set_chroma(int on, const float rgb[3], float dmin, float dmax) {
    klr_chroma_init();
    if (rgb) for (int i = 0; i < 3; i++) s_chroma_key[i] = rgb[i];
    s_chroma_min = dmin;
    s_chroma_max = dmax;
    // Last, so a reader that sees it enabled sees the values with it.
    __atomic_store_n(&s_chroma_on, on ? 1 : 0, __ATOMIC_RELEASE);
}

int kl_reproject_chroma(float rgb[3], float *dmin, float *dmax) {
    klr_chroma_init();
    if (rgb) for (int i = 0; i < 3; i++) rgb[i] = s_chroma_key[i];
    if (dmin) *dmin = s_chroma_min;
    if (dmax) *dmax = s_chroma_max;
    return __atomic_load_n(&s_chroma_on, __ATOMIC_ACQUIRE);
}

// KL_REPROJECT_OFF=1: no timewarp at all. The picture is placed with the
// DISPLAY's own pose as if it had been rendered from it — no correction from
// the render pose toward the current head, rotation or translation. Between
// guest frames it moves with the head (judders at the guest's frame rate) but
// nothing of ours bends it: if a fault persists with this on, the reprojection
// math is exonerated. Defaults to on under KL_OPENVR_MINIMAL=1 (the OpenVR
// bridge's bisection switch), off otherwise.
int kl_reproject_off(void) {
    static int on = -1;
    if (on < 0) {
        on = kl_env_on("KL_REPROJECT_OFF", kl_env_on("KL_OPENVR_MINIMAL", 0));
        if (on) fprintf(stderr, "  [reproject] timewarp OFF (KL_REPROJECT_OFF): the picture "
                                "is shown at the display pose, uncorrected\n");
    }
    return on;
}

static int klr_translate(void) {
    static int on = -1;
    if (on < 0) on = kl_env_on("KL_REPROJECT_TRANSLATE", 1);
    return on;
}

// Whether the composite decodes its sample from sRGB. See kl_reproject.h for
// the full argument; the short version is that ANGLE forces an sRGB encode the
// guest explicitly asked to be without, and the extra decode undoes it.
//
// A plain int, written from the GL thread the first time the guest says so and
// read from the render thread every frame. Not atomic on purpose: it is one
// word, it only ever moves 0 -> 1, and the worst a torn read could do is
// composite one more frame with the old value.
//
// `KL_SRGB_DECODE` overrides it in both directions and is the A/B — the whole
// question is a judgement about brightness and the only instrument is a person
// looking at it, so being able to flip it inside a single session (rather than
// across two pairings) is the difference between settling it and arguing.
static int g_srgb_decode;

static int klr_srgb_forced(int *out) {
    const char *e = getenv("KL_SRGB_DECODE");
    if (!e || !*e) return 0;
    *out = kl_env_on("KL_SRGB_DECODE", 0);
    return 1;
}

void kl_reproject_set_srgb_decode(int on) {
    on = on ? 1 : 0;
    if (g_srgb_decode == on) return;
    g_srgb_decode = on;
    int forced;
    fprintf(stderr, "  [reproject] sRGB decode %s%s\n", on ? "ON" : "off",
            klr_srgb_forced(&forced) ? " (overridden by KL_SRGB_DECODE)" : "");
}

int kl_reproject_srgb_decode(void) {
    int forced;
    if (klr_srgb_forced(&forced)) return forced;
    return g_srgb_decode;
}

// The shader. Compiled from source at runtime by whichever compositor is
// running rather than shipped as a .metal, so it lives beside the math that
// feeds it — the uniforms below and the struct in this string are one
// contract, and having them in one file is how they stay one.
//
// Drawn as a 4-vertex triangle strip with no vertex buffer.
static const char kl_msl_reproject[] =
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"struct KLReproj {\n"
"    float4x4 projection;\n"
"    float4x4 modelView;\n"
"    float4   tangents;   // left, right, top, bottom — all positive\n"
"    uint     slice;\n"
"    float    depth;      // metres — see kl_reproject.h\n"
"    uint     visible;    // 0 = collapse the quad, this eye has no picture\n"
"    uint     srgbDecode; // 1 = the sample is an sRGB code value, not linear\n"
"    uint     flipY;      // 1 = the picture's origin is the TOP left (Vulkan)\n"
"    uint     gridEye;    // which grid BLOCK this view reads — kl_reproject.h\n"
"    uint     chromaOn;\n"
"    float    chromaMin;\n"
"    float    chromaMax;\n"
"    packed_float3 chromaKey;  // packed: matches the C side's three floats\n"
"};\n"
"\n"
// The sRGB EOTF, piecewise as the spec has it rather than a 2.2 power. The
// difference is confined to the bottom of the range, which is precisely where a
// wrong curve is most visible — a near-black that lifts is the artefact this
// whole path exists to remove, and approximating it would leave a smaller
// version of the same complaint.
"static float3 kl_srgb_to_linear(float3 c)\n"
"{\n"
"    float3 lo = c * (1.0 / 12.92);\n"
"    float3 hi = pow(max(c + 0.055, 0.0) * (1.0 / 1.055), 2.4);\n"
"    return select(lo, hi, c > 0.04045);\n"
"}\n"
"\n"
"static float4 kl_eye_sample(texture2d_array<float> tex, sampler samp,\n"
"                            float2 uv, uint slice, uint srgbDecode)\n"
"{\n"
"    float3 c = tex.sample(samp, uv, slice).rgb;\n"
"    return float4(srgbDecode != 0u ? kl_srgb_to_linear(c) : c, 1.0);\n"
"}\n"
"\n"
// `slice` travels as a flat varying because the fragment stage has no
// amplification_id: with both eyes drawn in one amplified pass, the uniform the
// fragment shader would have to read is not the one it can index to.
// `srgbDecode` rides along for the same reason `slice` does: it comes out of
// the per-view uniform, and with both eyes in one amplified pass the fragment
// stage cannot index the array it would have to read.
// `src` is the third, and it is there because the two eyes are not always two
// SLICES of one texture. They are for every guest that goes through the eye
// provider (it allocates one 2-slice array by construction) and for a Vulkan
// guest whose eye IS the layer (BONELAB). They are NOT for an OpenXR guest on
// Vulkan, which has one swapchain per eye and therefore two unrelated
// MTLTextures — Open Brush is the first, and there is no view, no slice and no
// binding that can make one texture argument reach both. So the pass binds up
// to two and each view says which is its own; when they really do share one,
// the same texture is bound twice and this reduces to exactly what it was.
"struct VOut { float4 pos [[position]]; float2 uv; uint slice [[flat]];\n"
"              uint srgb [[flat]]; uint src [[flat]];\n"
// The chroma parameters travel as flat varyings for the same reason `slice` and
// `srgbDecode` do: with both eyes drawn in one amplified pass the fragment stage
// has no amplification_id, so it cannot index the per-view uniform array it
// would otherwise read. Unlike the struct above these are varyings, not buffer
// members, so a float3 here costs nothing and hides nothing.
"              uint chromaOn [[flat]]; float3 chromaKey [[flat]];\n"
"              float2 chromaRange [[flat]]; };\n"
"\n"
// One place, so a rung of the probe ladder cannot disagree with the real pass
// about which eye it is looking at — which is the failure this whole file keeps
// paying for — an instrument answering confidently about the wrong subject. A
// texture argument cannot be selected into a variable in MSL, so
// this is a branch and not an index.
"static float4 kl_eye_sample2(texture2d_array<float> t0,\n"
"                             texture2d_array<float> t1, sampler samp,\n"
"                             float2 uv, uint slice, uint srgbDecode, uint src)\n"
"{\n"
"    return src == 0u ? kl_eye_sample(t0, samp, uv, slice, srgbDecode)\n"
"                     : kl_eye_sample(t1, samp, uv, slice, srgbDecode);\n"
"}\n"
"\n"
// ---- the chroma key -------------------------------------------------------
//
// Ported from VisionOSALVRClient with its maths unchanged, on purpose: the two
// distance dials are found by a person looking at a matte, and a value found
// there has to mean the same thing here or the numbers do not transfer.
//
// The test is in HSV with hue weighted four times value and twice saturation,
// which is what makes it a KEY rather than a colour comparison — a green screen
// under uneven light varies in brightness far more than in hue.
//
// **Which colour space this runs in is the sampled one**, i.e. linear when
// `srgbDecode` is set and raw code values otherwise, and the key colour is
// compared as authored. That is ALVR's convention rather than a defensible one
// — it compares an sRGB-authored key against a linearised frame — and it is
// kept because changing it would silently move every dial value. If this is
// ever made rigorous, the key colour has to be converted alongside, and the
// defaults restated.
"static float3 kl_rgb2hsv(float3 rgb)\n"
"{\n"
"    float cmax = max(rgb.r, max(rgb.g, rgb.b));\n"
"    float cmin = min(rgb.r, min(rgb.g, rgb.b));\n"
"    float delta = cmax - cmin;\n"
"    float3 hsv = float3(0.0, 0.0, cmax);\n"
"    if (cmax > cmin) {\n"
"        hsv.y = delta / cmax;\n"
"        if (rgb.r == cmax)      hsv.x = (rgb.g - rgb.b) / delta;\n"
"        else if (rgb.g == cmax) hsv.x = 2.0 + (rgb.b - rgb.r) / delta;\n"
"        else                    hsv.x = 4.0 + (rgb.r - rgb.g) / delta;\n"
"        hsv.x = fract(hsv.x / 6.0);\n"
"    }\n"
"    return hsv;\n"
"}\n"
"\n"
// 0 = key it out entirely, 1 = keep it entirely, between = the fade band.
// A pixel with almost no saturation or almost no value is KEPT whatever its
// hue: black and white have no meaningful hue, so measuring their distance to
// the key would matte out every shadow in the picture.
"static float kl_colorclose_hsv(float3 hsv, float3 keyHsv, float2 tol)\n"
"{\n"
"    if (hsv.b < 0.001 || hsv.g < 0.001) return 1.0;\n"
"    float d = length(float3(4.0, 1.0, 2.0) * (keyHsv - hsv));\n"
"    if (d < tol.x) return 0.0;\n"
"    if (d < tol.y) return (d - tol.x) / (tol.y - tol.x);\n"
"    return 1.0;\n"
"}\n"
"\n"
// The matte, as one call both the real pass and its opaque probe make.
//
// The colour is un-multiplied by the key as well as scaled — ALVR's
// `(rgb * mask) - (key * (1 - mask))` — which pulls the spill of the key colour
// out of edge pixels instead of leaving a green fringe around everything.
// Alpha carries the matte, and the compositor blends against passthrough.
"static float4 kl_chroma_apply(float4 c, uint on, float3 key, float2 range)\n"
"{\n"
"    if (on == 0u) return c;\n"
"    float mask = kl_colorclose_hsv(kl_rgb2hsv(c.rgb), kl_rgb2hsv(key), range);\n"
"    return float4((c.rgb * mask) - (key * (1.0 - mask)), c.a * mask);\n"
"}\n"
"\n"
// Off-screen on every axis (x, y and z all exceed w), so the clipper drops the
// primitive whole. This is how an eye with no texture yet is expressed now that
// the two eyes share one encoder and one draw call.
"static constant float4 kl_offscreen = float4(2.0, 2.0, 2.0, 1.0);\n"
"\n"
"// The guest's picture as a quad at KL_REPROJECT_DEPTH metres, sized by the\n"
"// tangents it was RENDERED with, in the space its render pose defines. The\n"
"// model-view then looks at it from where the head is now, and the projection\n"
"// is the one this drawable actually wants — so the stale pose and the\n"
"// frustum mismatch are corrected by the same two matrices.\n"
"//\n"
"// buffer(0) is an array — one entry per amplified view. A caller that draws a\n"
"// single view binds a single struct and lands on index 0.\n"
"vertex VOut kl_reproject_v(uint vid [[vertex_id]],\n"
"                           ushort amp [[amplification_id]],\n"
"                           constant KLReproj *ua [[buffer(0)]],\n"
"                           constant float2 *grid [[buffer(1)]])\n"
"{\n"
"    constant KLReproj &u = ua[amp];\n"
"    // The unwarp grid (kl_reproject.h): grid[0] is (nx, ny) and the texture\n"
"    // coordinates follow, one per grid vertex, ALREADY UNWARPED on the CPU.\n"
"    // A foveated eye texture is stored squeezed, and undoing that here — at a\n"
"    // few thousand vertices — rather than in the fragment shader is the whole\n"
"    // point: the rasterizer's interpolation does the work for free, and\n"
"    // because a rate map is piecewise linear between its zone boundaries, a\n"
"    // grid built on those boundaries is EXACT rather than an approximation.\n"
"    //\n"
"    // An unfoveated pass binds the 1x1 identity grid, and everything below\n"
"    // reduces to the two triangles that used to be a 4-vertex strip.\n"
"    //\n"
"    // The coordinates may start past 1: the two eyes can have been rendered\n"
"    // into DIFFERENT sub-rects of one texture (kl_reproject.h, `grid_per_eye`),\n"
"    // so a grid can carry one BLOCK per eye and u.gridEye says which is this\n"
"    // view's. Derived from the nx/ny read out of the header rather than passed\n"
"    // in, so a grid that fell back to the identity moves both the header and\n"
"    // every block's base together and no view can be left pointing past it.\n"
"    uint nx = uint(grid[0].x), ny = uint(grid[0].y);\n"
"    uint base = 1u + u.gridEye * (nx + 1u) * (ny + 1u);\n"
"    uint cell = vid / 6u, k = vid % 6u;\n"
"    uint2 g = uint2(cell % nx, cell / nx);\n"
"    // Two triangles a cell: (0,0)(1,0)(0,1) and (1,0)(1,1)(0,1).\n"
"    g.x += (k == 1u || k == 3u || k == 4u) ? 1u : 0u;\n"
"    g.y += (k == 2u || k == 4u || k == 5u) ? 1u : 0u;\n"
"    float2 c = float2(g) / float2(float(nx), float(ny));\n"
"    float d = u.depth;          // KL_REPROJECT_DEPTH\n"
"    float x = mix(-u.tangents.x, u.tangents.y, c.x) * d;\n"
"    float y = mix(-u.tangents.w, u.tangents.z, c.y) * d;\n"
"    VOut o;\n"
"    o.slice = u.slice;\n"
"    o.srgb = u.srgbDecode;\n"
"    o.chromaOn = u.chromaOn;\n"
"    o.chromaKey = float3(u.chromaKey);\n"
"    o.chromaRange = float2(u.chromaMin, u.chromaMax);\n"
"    // The amplification index IS the texture slot: the caller binds the views'\n"
"    // textures in the order it amplified them. A single-view pass amplifies\n"
"    // once, lands on 0, and binds one texture.\n"
"    o.src = uint(amp);\n"
"    o.pos = u.visible == 0u ? kl_offscreen\n"
"                            : u.projection * u.modelView * float4(x, y, -d, 1.0);\n"
"    // Same mapping as the plain blit below, and for the same reason. Derived\n"
"    // in the viewer against a frame known to be the right way up — do not\n"
"    // re-derive it from first principles about GL's origin, because ANGLE's\n"
"    // Metal backend has already had its say by the time we see the texture.\n"
"    //\n"
"    // The blit is the authority and this must track it. It was corrected to\n"
"    // uv.y = p.y (the picture was upside down); this quad's c.y = 1 is UP,\n"
"    // where the blit's p.y = 2 is also up, so the same convention written for\n"
"    // this parameterisation is uv.y = c.y. The two disagreed for exactly as\n"
"    // long as the reprojection pass had never run anywhere.\n"
"    //\n"
"    // Read from the grid rather than computed, which is what carries the\n"
"    // unwarp. The identity grid holds exactly float2(c.x, c.y), so the\n"
"    // convention derived above is preserved rather than re-derived — and the\n"
"    // table is built in this same uv space, so nothing here flips.\n"
"    float2 uv = grid[base + g.y * (nx + 1u) + g.x];\n"
// ...except for a guest whose framebuffer origin is the TOP left. That is
// Vulkan, and it is the one thing about the picture that the API the guest drew
// with decides rather than anything here (kl_reproject.h, `flip_y`). Applied
// AFTER the grid, which is exact today because the Vulkan path has no
// foveation: with a rate map in play the unwarp and the flip are both in the
// texture's own space and this composition would want checking against a
// foveated Vulkan eye, which nothing has produced yet.
"    if (u.flipY != 0u) uv.y = 1.0 - uv.y;\n"
"    o.uv = uv;\n"
"    return o;\n"
"}\n"
"\n"
"fragment float4 kl_reproject_f(VOut in [[stage_in]],\n"
"                               texture2d_array<float> tex [[texture(0)]],\n"
"                               texture2d_array<float> tex1 [[texture(1)]],\n"
"                               sampler samp [[sampler(0)]])\n"
"{\n"
"    float4 c = kl_eye_sample2(tex, tex1, samp, in.uv, in.slice, in.srgb, in.src);\n"
// Pure magenta is a render target's CLEAR colour, never a picture: Source 2
// clears to it, and any of its pixels that reach here are a region the guest
// did not draw (Alyx's unrendered band — kl_openvr.c, "the magenta band").
// Shown as black, the same as the outside of the frame, so a band the guest
// leaves can never read as a pink stripe. KL_CP_MAGENTA_KEY=0 shows it as is.
"#if KL_MAGENTA_KEY\n"
"    if (c.r > 0.98 && c.g < 0.02 && c.b > 0.98) c = float4(0.0, 0.0, 0.0, 1.0);\n"
"#endif\n"
// The matte is applied HERE and in no probe below. A rung of the probe ladder
// exists to answer "is the picture arriving", and one that could also be
// keyed out would answer that question with the matte's opinion — which is the
// failure mode this ladder was built to end.
"    return kl_chroma_apply(c, in.chromaOn, in.chromaKey, in.chromaRange);\n"
"}\n"
"\n"
// The probe ladder (KL_CP_PROBE). Same library, same vertex function, so each
// rung differs from the real pass in exactly one respect and nothing else moves.
// A picture that is black tells you nothing about WHICH link is dark; these do.
"fragment float4 kl_probe_solid_f(VOut in [[stage_in]])\n"
"{\n"
"    return float4(1.0, 0.0, 1.0, 1.0);            // magenta: geometry only\n"
"}\n"
"\n"
// The real sample with alpha forced opaque. If this is visible and the real pass
// is not, the guest's picture is arriving with alpha 0 and the fix is here.
"fragment float4 kl_probe_opaque_f(VOut in [[stage_in]],\n"
"                                  texture2d_array<float> tex [[texture(0)]],\n"
"                                  texture2d_array<float> tex1 [[texture(1)]],\n"
"                                  sampler samp [[sampler(0)]])\n"
"{\n"
"    return kl_eye_sample2(tex, tex1, samp, in.uv, in.slice, in.srgb, in.src);\n"
"}\n"
"\n"
// The eye texture over the whole viewport, ignoring the quad, the poses and the
// projection entirely — the viewer's proven path, on device. Visible here but
// not at rung 2 means the picture is fine and the REPROJECTION GEOMETRY is what
// is dark. Uses the same uv convention as kl_blit_v below.
"vertex VOut kl_probe_full_v(uint vid [[vertex_id]],\n"
"                            ushort amp [[amplification_id]],\n"
"                            constant KLReproj *ua [[buffer(0)]])\n"
"{\n"
"    float2 p = float2((vid << 1) & 2, vid & 2);\n"
"    VOut o;\n"
"    o.slice = ua[amp].slice;\n"
"    o.srgb = ua[amp].srgbDecode;\n"
"    o.chromaOn = ua[amp].chromaOn;\n"
"    o.chromaKey = float3(ua[amp].chromaKey);\n"
"    o.chromaRange = float2(ua[amp].chromaMin, ua[amp].chromaMax);\n"
"    o.src = uint(amp);\n"
"    o.pos = ua[amp].visible == 0u ? kl_offscreen\n"
"                                  : float4(p * 2.0 - 1.0, 0.0, 1.0);\n"
"    o.uv  = float2(p.x, ua[amp].flipY != 0u ? 1.0 - p.y : p.y);\n"
"    return o;\n"
"}\n"
"\n"
"fragment float4 kl_probe_full_f(VOut in [[stage_in]],\n"
"                                texture2d_array<float> tex [[texture(0)]],\n"
"                                texture2d_array<float> tex1 [[texture(1)]],\n"
"                                sampler samp [[sampler(0)]])\n"
"{\n"
"    return kl_eye_sample2(tex, tex1, samp, in.uv, in.slice, in.srgb, in.src);\n"
"}\n";

// The pass that existed before reprojection: a full-screen triangle, three
// vertices, no buffer, no seam down the middle where two triangles meet. Kept
// as the A/B — it is the one known to produce the right picture, so a wrong
// reprojected frame can be told from a wrong *frame*.
static const char kl_msl_blit[] =
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VOut { float4 pos [[position]]; float2 uv; };\n"
// Matches kl_blit_uniforms in kl_reproject.h. The flip lives in the FRAGMENT
// stage here rather than in the vertex shader, because this pass has no grid
// and no per-vertex table — one branch on a uniform is the whole difference
// between a GL guest's picture and a Vulkan guest's.
"struct KLBlit { uint slice; uint flipY; };\n"
"vertex VOut kl_blit_v(uint vid [[vertex_id]]) {\n"
"    float2 p = float2((vid << 1) & 2, vid & 2);\n"
"    VOut o;\n"
"    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);\n"
"    o.uv  = float2(p.x, p.y);\n"
"    return o;\n"
"}\n"
// Opaque, exactly as kl_eye_sample is, and not for tidiness: an eye layer is
// composited opaque by the runtime, so a guest has no reason to author alpha —
// Beat Saber 1.40 leaves 0 across the whole eye texture. Sampling that straight
// into a drawable hands the window server a fully transparent frame over a
// correct picture, which is the same failure as a black one and looks identical
// from inside. The A/B for "is the alpha the problem" is the reprojection path,
// which has forced 1.0 since it was written.
"fragment float4 kl_blit_f(VOut in [[stage_in]],\n"
"                          texture2d_array<float> tex [[texture(0)]],\n"
"                          sampler samp [[sampler(0)]],\n"
"                          constant KLBlit &u [[buffer(0)]]) {\n"
"    float2 uv = float2(in.uv.x, u.flipY != 0u ? 1.0 - in.uv.y : in.uv.y);\n"
"    return float4(tex.sample(samp, uv, u.slice).rgb, 1.0);\n"
"}\n";

// The OVERLAY pass — see kl_reproject.h.
//
// Deliberately not a variant of the reprojection shader above. That one places
// an EYE-CENTRED quad at a chosen depth and corrects only rotation, because a
// flat picture with no per-pixel depth cannot be moved. An overlay is somewhere:
// it has a position in the guest's tracking space, a real size in metres, and
// its parallax between the two eyes is the whole point of it being a layer
// rather than pixels. So the geometry is built in world units and the model-view
// keeps its translation.
//
// It also BLENDS, which the eye pass never does — the caller sets that on the
// pipeline, and the alpha here is the guest's own rather than the forced 1.0
// two doors down: a UI quad's transparency is authored, unlike an eye texture's
// (see kl_msl_blit for why that one is forced).
static const char kl_msl_overlay[] =
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VOut { float4 pos [[position]]; float2 uv; };\n"
// Matches kl_overlay_uniforms in kl_reproject.h.
"struct KLOv {\n"
"    float4x4 projection;\n"
"    float4x4 model_view;\n"
"    float2   half_size;\n"
"    float4   uv_rect;\n"      // x, y, w, h — the eye's ViewportRect as a fraction
"    uint     slice;\n"
"    uint     flip_y;\n"
"    uint     srgb_decode;\n"
"    uint     visible;\n"
"    uint     opaque;\n"
"};\n"
"vertex VOut kl_ov_v(uint vid [[vertex_id]],\n"
"                    constant KLOv *us [[buffer(0)]],\n"
"                    ushort amp [[amplification_id]]) {\n"
"    constant KLOv &u = us[amp];\n"
"    VOut o;\n"
"    if (u.visible == 0u) { o.pos = float4(2.0, 2.0, 2.0, 1.0); o.uv = float2(0); return o; }\n"
// A triangle strip in the quad's own plane, facing -Z, which is the convention
// ovrpLayerSubmit's Pose states its orientation in.
"    float2 c = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? -1.0 : 1.0);\n"
"    float4 p = float4(c * u.half_size, 0.0, 1.0);\n"
"    o.pos = u.projection * (u.model_view * p);\n"
// Bottom-left origin as the base, and `flip_y` meaning "the picture's origin is
// the TOP left" — the same convention as the reprojection pass above and as
// kl_glfb_eye_mtl_origin_top_left, rather than the mirror image of it. The two
// passes read the same field off two records and a flag that means opposite
// things in each is a wrong picture with nothing to catch it.
"    float2 t = float2((c.x + 1.0) * 0.5, (c.y + 1.0) * 0.5);\n"
"    if (u.flip_y != 0u) t.y = 1.0 - t.y;\n"
"    o.uv = u.uv_rect.xy + t * u.uv_rect.zw;\n"
"    return o;\n"
"}\n"
"fragment float4 kl_ov_f(VOut in [[stage_in]],\n"
"                        texture2d<float> tex [[texture(0)]],\n"
"                        sampler samp [[sampler(0)]],\n"
"                        constant KLOv *us [[buffer(0)]],\n"
"                        ushort amp [[amplification_id]]) {\n"
"    constant KLOv &u = us[amp];\n"
"    float4 c = tex.sample(samp, in.uv);\n"
"    if (u.srgb_decode != 0u) {\n"
"        float3 lo = c.rgb / 12.92;\n"
"        float3 hi = pow((c.rgb + 0.055) / 1.055, float3(2.4));\n"
"        c.rgb = select(hi, lo, c.rgb <= float3(0.04045));\n"
"    }\n"
"    if (u.opaque != 0u) c.a = 1.0;\n"
"    return c;\n"
"}\n";

// The EQUIRECT overlay — a 360 panorama drawn as a skybox behind everything,
// which is what AC Nexus shows during shader warmup and where the flat quad
// pass draws nothing (an equirect layer carries no quad size). A fullscreen
// triangle, and per fragment the view ray is reconstructed from the inverse
// projection and rotated into world space, then turned into equirect UV
// (longitude from atan2, latitude from acos). World-locked: the ray uses the
// eye's world rotation, so turning the head reveals different parts. One uniform
// per amplified view, indexed by [[amplification_id]] exactly as the quad pass.
static const char kl_msl_equirect[] =
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct EqOut { float4 pos [[position]]; float2 ndc; };\n"
"struct KLEq {\n"
"    float4x4 inv_proj;\n"
"    float4x4 world_rot;\n"
"    uint slice;\n"
"    uint flip_y;\n"
"    uint srgb_decode;\n"
"    uint visible;\n"
"    uint test;\n"
"    float hscale;\n"
"};\n"
"vertex EqOut kl_eq_v(uint vid [[vertex_id]],\n"
"                     constant KLEq *us [[buffer(0)]],\n"
"                     ushort amp [[amplification_id]]) {\n"
"    constant KLEq &u = us[amp];\n"
"    EqOut o;\n"
"    float2 p = float2((vid == 1u) ? 3.0 : -1.0, (vid == 2u) ? 3.0 : -1.0);\n"
"    if (u.visible == 0u) { o.pos = float4(2.0, 2.0, 2.0, 1.0); o.ndc = float2(0); return o; }\n"
"    // Finite far depth (reverse-Z ~1000 m), not 0: visionOS discards a\n"
"    // submitted frame whose depth is all 0 (infinity) as empty, so the\n"
"    // skybox must sit at a real distance to be kept and reprojected.\n"
"    o.pos = float4(p, 0.0001, 1.0);\n"
"    o.ndc = p;\n"
"    return o;\n"
"}\n"
"fragment float4 kl_eq_f(EqOut in [[stage_in]],\n"
"                        texture2d<float> tex [[texture(0)]],\n"
"                        sampler samp [[sampler(0)]],\n"
"                        constant KLEq *us [[buffer(0)]],\n"
"                        ushort amp [[amplification_id]]) {\n"
"    constant KLEq &u = us[amp];\n"
"    if (u.test == 1u) return float4(1.0, 0.0, 1.0, 1.0);\n"
"    float4 clip = float4(in.ndc, 1.0, 1.0);\n"
"    float4 vp = u.inv_proj * clip;\n"
"    float3 vdir = normalize(vp.xyz / vp.w);\n"
"    float3 wdir = normalize((u.world_rot * float4(vdir, 0.0)).xyz);\n"
"    const float PI = 3.14159265358979;\n"
"    float uu = atan2(wdir.x, -wdir.z) / (2.0 * PI) * u.hscale + 0.5;\n"
"    float vv = acos(clamp(wdir.y, -1.0, 1.0)) / PI;\n"
"    if (u.flip_y != 0u) vv = 1.0 - vv;\n"
"    if (u.test == 4u) return float4(wdir * 0.5 + 0.5, 1.0);\n"
"    if (u.test == 2u) return float4(uu, vv, 0.5, 1.0);\n"
"    float4 c = tex.sample(samp, float2(uu, vv));\n"
"    if (u.srgb_decode != 0u) {\n"
"        float3 lo = c.rgb / 12.92;\n"
"        float3 hi = pow((c.rgb + 0.055) / 1.055, float3(2.4));\n"
"        c.rgb = select(hi, lo, c.rgb <= float3(0.04045));\n"
"    }\n"
"    if (u.test == 3u) return float4(max(c.rgb, float3(0.2)), 1.0);\n"
"    c.a = 1.0;\n"
"    return c;\n"
"}\n";

const char *kl_reproject_equirect_msl(void) { return kl_msl_equirect; }

// The reprojection source with its one build-time switch in front of it
// (KL_CP_MAGENTA_KEY, read once: the pipeline is compiled once per run).
static char *g_msl_reproject;
static void kl_reproject_msl_build(void) {
    size_t n = strlen(kl_msl_reproject) + 64;
    char *s = malloc(n);
    if (!s) return;
    snprintf(s, n, "#define KL_MAGENTA_KEY %d\n%s", kl_env_on("KL_CP_MAGENTA_KEY", 1), kl_msl_reproject);
    g_msl_reproject = s;
}
const char *kl_reproject_msl(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, kl_reproject_msl_build);
    return g_msl_reproject ? g_msl_reproject : kl_msl_reproject;
}
const char *kl_reproject_blit_msl(void) { return kl_msl_blit; }
const char *kl_reproject_overlay_msl(void) { return kl_msl_overlay; }


// The unwarp grid. See kl_reproject.h for the layout and for why the unwarp
// lives here — at grid vertices, precomputed — rather than in the fragment
// shader.
void kl_reproject_grid_identity(simd_float2 *out) {
    if (!out) return;
    out[0] = simd_make_float2(1.0f, 1.0f);      // 1 x 1 cells
    out[1] = simd_make_float2(0.0f, 0.0f);
    out[2] = simd_make_float2(1.0f, 0.0f);
    out[3] = simd_make_float2(0.0f, 1.0f);
    out[4] = simd_make_float2(1.0f, 1.0f);
}

void kl_reproject_grid_build(simd_float2 *out, uint32_t nx, uint32_t ny,
                             const float *vp,
                             float screen_w, float screen_h,
                             float tex_w, float tex_h,
                             kl_reproject_s2p fn, void *ctx) {
    kl_reproject_grid_build_eye(out, 0, nx, ny, vp, screen_w, screen_h,
                                tex_w, tex_h, fn, ctx);
}

void kl_reproject_grid_build_eye(simd_float2 *out, uint32_t eye,
                                 uint32_t nx, uint32_t ny,
                                 const float *vp,
                                 float screen_w, float screen_h,
                                 float tex_w, float tex_h,
                                 kl_reproject_s2p fn, void *ctx) {
    // A degenerate grid would be a pass that draws nothing, which is a black
    // eye rather than an unfoveated one. Fall back to the identity, which is
    // the correct picture for an unwarped, fully-drawn texture and merely the
    // wrong one otherwise — the strictly better failure of the two.
    if (!out) return;
    if (nx == 0 || ny == 0 || nx > KL_REPROJECT_GRID_MAX ||
        ny > KL_REPROJECT_GRID_MAX || !(tex_w > 0) || !(tex_h > 0) ||
        !(screen_w > 0) || !(screen_h > 0)) {
        // The identity, in this EYE's block of a 1x1 grid: the shader derives
        // every block's base from the header it reads, so collapsing the header
        // to 1x1 moves eye 1's base to 5 whether this call or the other one
        // took the fallback. Writing it at 1 unconditionally would leave a
        // second eye reading whatever followed.
        kl_reproject_grid_identity(out);
        if (eye) {
            out[5] = simd_make_float2(0.0f, 0.0f);
            out[6] = simd_make_float2(1.0f, 0.0f);
            out[7] = simd_make_float2(0.0f, 1.0f);
            out[8] = simd_make_float2(1.0f, 1.0f);
        }
        return;
    }
    // The span the guest drew, in screen pixels. Absent or nonsensical means it
    // used the whole screen, which is what every guest that cannot answer does.
    float vx = 0, vy = 0, vw = screen_w, vh = screen_h;
    if (vp && vp[2] > 0 && vp[3] > 0) {
        vx = vp[0]; vy = vp[1]; vw = vp[2]; vh = vp[3];
        // Clamped rather than trusted: a rect reaching past the screen would
        // send this through the rate map at coordinates it was not built for,
        // and Metal's answer there is not defined by anything we can check.
        if (vx < 0) vx = 0;
        if (vy < 0) vy = 0;
        if (vx + vw > screen_w) vw = screen_w - vx;
        if (vy + vh > screen_h) vh = screen_h - vy;
        if (!(vw > 0) || !(vh > 0)) { vx = vy = 0; vw = screen_w; vh = screen_h; }
    }
    out[0] = simd_make_float2((float)nx, (float)ny);
    // Where this eye's block starts — the same arithmetic kl_reproject_build
    // puts in the uniform, and the reason it is not a second convention: both
    // read kl_reproject_grid_stride, so a block written here and the base
    // handed to the shader cannot disagree.
    const uint32_t base = 1u + eye * kl_reproject_grid_stride(nx, ny);
    for (uint32_t y = 0; y <= ny; y++) {
        for (uint32_t x = 0; x <= nx; x++) {
            // Grid vertex -> uv -> SCREEN pixels, inside the viewport. Top-left
            // origin throughout, which is both Metal's texture convention and
            // the one mapScreenToPhysicalCoordinates speaks, so no axis is
            // flipped anywhere in this function. The shader's separate question
            // of which corner is "up" in clip space is about the POSITION and
            // does not reach the coordinates built here.
            //
            // With a full-screen viewport this is exactly what it was before
            // the viewport existed, so the foveation measurements stand.
            float sx = vx + vw * (float)x / (float)nx;
            float sy = vy + vh * (float)y / (float)ny;
            float px = sx, py = sy;
            // No map is the identity, not a reason to give up: an unfoveated
            // eye with a shrunken viewport still has to be corrected, and it is
            // the commonest case of the two (KL_VRR=0, and every host run).
            if (fn) fn(ctx, sx, sy, &px, &py);
            out[base + y * (nx + 1) + x] = simd_make_float2(px / tex_w, py / tex_h);
        }
    }
}

// The rotation of a pose, as a matrix, with the translation dropped. Dropping
// it is the rotation-only decision in the header, not an oversight: a
// positional correction without per-pixel depth smears disocclusions.
static simd_float4x4 klr_rotation_of(simd_float4x4 m) {
    m.columns[3] = simd_make_float4(0, 0, 0, 1);
    // The other three columns can carry translation only through the last row,
    // which a rigid transform leaves as (0,0,0,1) anyway.
    return m;
}

static simd_float4x4 klr_rotation_of_quat(float x, float y, float z, float w) {
    // A pose that was never written is all zeros, and a zero quaternion is not
    // a rotation — it would collapse the quad to a point. Treat it as identity.
    float n = x * x + y * y + z * z + w * w;
    if (!(n > 1e-6f)) return matrix_identity_float4x4;
    return simd_matrix4x4(simd_quaternion(x, y, z, w));
}

// A full rigid transform from an ovrpPosef laid out as {qx,qy,qz,qw,px,py,pz}.
// Unlike klr_rotation_of_quat above this KEEPS the translation, which is the
// whole difference between an eye quad and an overlay: one is a picture placed
// in front of the eye, the other is an object somewhere in the room.
static simd_float4x4 klr_pose_matrix(const float p[7]) {
    simd_float4x4 m = klr_rotation_of_quat(p[0], p[1], p[2], p[3]);
    m.columns[3] = simd_make_float4(p[4], p[5], p[6], 1.0f);
    return m;
}

kl_reproject_uniforms kl_reproject_build(const kl_ovrp_render_pose *rendered, int eye,
                                         simd_float4x4 origin_from_device,
                                         simd_float4x4 device_from_view,
                                         simd_float4x4 projection,
                                         uint32_t slice, int flip_y,
                                         int grid_per_eye) {
    kl_reproject_uniforms u;
    u.projection = projection;
    u.slice = slice;
    // Which grid block this eye reads. `eye` and `slice` are not the same
    // number and neither could stand in for this one: an Array-layout guest has
    // slice == eye, a Stereo-layout one has two textures and slice 0 for both,
    // and a caller that built a single shared block wants block 0 whatever the
    // eye is.
    u.grid_eye = (grid_per_eye && eye == 1) ? 1u : 0u;
    // Passed in rather than read from a global, unlike srgb_decode below: the
    // flip is a property of ONE (eye, stage) texture and its recorded answer
    // lives in kl_glfb's eye table, which this file cannot reach without taking
    // a dependency `make reproject` exists without.
    u.flip_y = flip_y ? 1u : 0u;
    // Visible unless the caller says otherwise: only the visionOS compositor
    // has an eye it may have no picture for, and it clears the flag itself.
    u.visible = 1;
    // Not a caller's decision: it is a property of how the guest wrote the
    // texture, and both compositors must reach the same answer. See
    // kl_reproject_set_srgb_decode.
    u.srgb_decode = (uint32_t)kl_reproject_srgb_decode();
    // **500 m, and the 2 m that sat here was a misattribution.**
    //
    // The quad is eye-centred (device_from_view loses its translation below), so
    // it fills the viewport at ANY distance and our own picture does not depend
    // on this at all. What depends on it is the *system's* reprojection:
    // visionOS warps the submitted frame using the depth buffer we hand it, so
    // this number tells it how far away our content is, and it applies parallax
    // for a plane at that distance when the head translates between our
    // submission and scanout.
    //
    // A head *turn* is a rotation about the neck, so the eyes translate several
    // centimetres. At 2 m that is over a degree of parallax the system adds and
    // the content does not have — applied on the frames it chooses to correct
    // and not on the others, which is two images in two places. Placing the quad
    // far away makes the system's correction rotational, which is the only
    // correction that is right for a picture with no per-pixel depth.
    //
    // A frame that vanishes on device is depth WRITES being off, not this
    // distance: a depth buffer that is never written says "no geometry here"
    // whatever the quad's z is, and the attachment must be stored rather than
    // discarded (`.dontCare` -> `.store`). Distance cannot clip it either — the
    // drawable reports `depthRange = (far inf, near 0.1)`, an INFINITE far
    // plane. The compositor logs the quad's actual NDC depth beside that range,
    // so this is a number in the log rather than an argument.
    if (s_depth == 0.0f) {
        float v = kl_env_float("KL_REPROJECT_DEPTH", 0.0);
        s_depth = (v > 0.0f) ? v : KL_REPROJECT_DEPTH;
    }
    u.depth = s_depth;

    // Read per build rather than latched, so a slider moves the matte while it
    // is being dragged — the panel and the environment reach the shader through
    // exactly this call and no other.
    u.chroma_on = (uint32_t)kl_reproject_chroma(u.chroma_key, &u.chroma_min,
                                                &u.chroma_max);

    if (rendered && rendered->serial) {
        const float *t = rendered->tangents[(unsigned)eye > 1 ? 0 : eye];
        u.tangents = simd_make_float4(t[0], t[1], t[2], t[3]);
    } else {
        // No record: describe the default symmetric 90° frustum kl_ovrp reports
        // when nothing has overridden it, so the picture is placed at the size
        // it was drawn at rather than at an invented one.
        u.tangents = simd_make_float4(1, 1, 1, 1);
    }

    // The quad lives in the space the render pose defines. Take it to the
    // world with that pose, back to the head with the pose the display will
    // have, and then to the eye with the drawable's own view transform:
    //
    //     view <- device <- world <- render
    //
    // and the model-view is that whole chain, which is the inverse of the
    // chain written the other way round. All three have their translation
    // dropped — see each of the two arguments below for why, which are
    // different reasons and not one.
    //
    // `origin_from_device` is expected to be OpenXR's VIEW space, i.e. the
    // point midway between the eyes, because that is the space the guest
    // rendered about. Rotating about any other point moves the eyes along a
    // lever arm this correction does not model, and the error is largest on
    // near content while the measured delta stays small.
    //
    // With no record, the render rotation is defined to be the *display's* and
    // not identity. That is not a detail: a missing record means "we do not
    // know when this was drawn", and the only safe answer to that is to correct
    // nothing. Calling it identity instead would apply the head's entire
    // orientation as if it were a one-frame delta, and the picture would swing
    // around the room — which is what happens for every frame before the guest
    // first reaches ovrp_BeginFrame.
    simd_float4x4 device_rot = klr_rotation_of(origin_from_device);
    simd_float4x4 render_rot = rendered && rendered->serial && !kl_reproject_off()
        ? klr_rotation_of_quat(rendered->qx, rendered->qy, rendered->qz, rendered->qw)
        : device_rot;
    // device_from_view loses its translation too, and that is a correction of a
    // real double-count rather than a simplification. The guest rendered THIS
    // eye's picture from THIS eye's position — the offset is already in the
    // pixels. Viewing a head-centred quad from an offset eye applies it a second
    // time. Dropping the offset makes the quad eye-centred, so it fills the
    // viewport exactly at ANY distance and the depth is free to be chosen for
    // what the DISPLAY needs rather than for what the geometry needs. See
    // KL_REPROJECT_DEPTH above for what the display needs it for.
    // ...and the eye's own rotation, which the guest was never told about. See
    // klr_nocant: keeping it places the picture turned by an angle it was not
    // drawn with, oppositely in the two eyes.
    simd_float4x4 view_rot = klr_nocant() ? matrix_identity_float4x4
                                          : klr_rotation_of(device_from_view);
    // ---- and the TRANSLATION, which is the parallax ------------------------
    //
    // Everything above corrects rotation only, and that leaves a real error
    // that reads as swim: a head TURN is a rotation about the neck, so the eyes
    // translate several centimetres, and none of that was corrected here. It
    // was left to the system's own reprojection, which is why the quad sits at
    // 500 m — at that distance the system's correction is rotational and the
    // translation is simply not applied by anyone.
    //
    // The asymmetry that identified it: the eye displacement from a YAW is
    // lateral, and lateral motion of the whole picture is glaring; the
    // displacement from a PITCH is vertical and in depth, which is far less
    // visible. So the world swims when you look side to side and does not when
    // you nod — measured on device, JKXR, and it is one cause with the plain
    // translational swim rather than two.
    //
    // The correction is exact for content at `u.depth` and wrong for the rest,
    // which is the best a single plane can do: shifting a quad at depth d by
    // the head's displacement is an angular shift of |dP| / d, i.e. the parallax
    // of a plane at d. **At 500 m it is nothing**, so this is inert until
    // KL_REPROJECT_DEPTH names a distance near the content — which makes that
    // knob the whole experiment and this change safe by construction.
    //
    // Only the DIFFERENCE of the two positions is used, so a constant offset
    // between the guest's tracking space and the display's world origin (a
    // floor height, a recentre) cancels and neither space has to be the other.
    simd_float4x4 render_m = render_rot, device_m = device_rot;
    if (klr_translate() && rendered && rendered->serial && !kl_reproject_off()) {
        render_m.columns[3] = simd_make_float4(rendered->px, rendered->py,
                                               rendered->pz, 1.0f);
        device_m.columns[3] = origin_from_device.columns[3];
    }
    simd_float4x4 chain = simd_mul(simd_mul(simd_inverse(render_m), device_m),
                                   view_rot);
    u.model_view = simd_inverse(chain);
    return u;
}

kl_reproject_uniforms kl_proj_layer_build(const kl_ovrp_proj_layer *pl, int eye,
                                          simd_float4x4 origin_from_device,
                                          simd_float4x4 device_from_view,
                                          simd_float4x4 projection,
                                          uint32_t slice) {
    if ((unsigned)eye > 1) eye = 0;
    // Built through the eye pass rather than beside it: a projection layer IS
    // an eye picture, and two implementations of one placement is how the two
    // come to disagree. The record is synthesized because that call speaks the
    // frame record's vocabulary; `serial` is what marks it as real, and a layer
    // with no picture for this eye is refused below rather than described.
    kl_ovrp_render_pose r;
    memset(&r, 0, sizeof r);
    r.serial = 1;
    r.px = pl ? pl->pose[0] : 0.0f;
    r.py = pl ? pl->pose[1] : 0.0f;
    r.pz = pl ? pl->pose[2] : 0.0f;
    r.qx = pl ? pl->pose[3] : 0.0f;
    r.qy = pl ? pl->pose[4] : 0.0f;
    r.qz = pl ? pl->pose[5] : 0.0f;
    r.qw = pl ? pl->pose[6] : 1.0f;
    if (pl) memcpy(r.tangents, pl->tangents, sizeof r.tangents);
    // grid_per_eye = 1: this path binds kl_proj_layer_grid's two blocks. There
    // is no rate map to undo — a layer's picture is the guest's own swapchain
    // image — but the picture may be only PART of that image (the layer's
    // `rect`), and the two eyes' parts need not be the same.
    kl_reproject_uniforms u =
        kl_reproject_build(pl ? &r : NULL, eye, origin_from_device,
                           device_from_view, projection, slice,
                           pl ? pl->origin_top_left : 0, 1);
    if (!pl || pl->slot[eye] < 0) u.visible = 0;
    return u;
}

// Adapted from avp-play (MIT, github.com/myMartek/avp-play) runtime/gfx/kl_reproject.c
// (with the grid_per_eye = 1 above): identical to the identity grid for a
// full-texture rect, so only a guest that names a partial imageRect is affected.
void kl_proj_layer_grid(const kl_ovrp_proj_layer *pl, simd_float2 *out) {
    if (!out) return;
    out[0] = simd_make_float2(1.0f, 1.0f);      // 1 x 1 cells, one block per eye
    for (int e = 0; e < 2; e++) {
        float x0 = 0.0f, y0 = 0.0f, x1 = 1.0f, y1 = 1.0f;
        if (pl && pl->rect[e][2] > pl->rect[e][0] && pl->rect[e][3] > pl->rect[e][1]) {
            x0 = pl->rect[e][0]; y0 = pl->rect[e][1];
            x1 = pl->rect[e][2]; y1 = pl->rect[e][3];
        }
        // The grid is in the reprojection pass's own space, where v = 0 is the
        // BOTTOM of the picture, and the shader flips v afterwards for a picture
        // whose row 0 is its top. The rect is measured from row 0 either way, so
        // for such a picture it is mirrored here and comes out right there.
        float v0 = y0, v1 = y1;
        if (pl && pl->origin_top_left) { v0 = 1.0f - y1; v1 = 1.0f - y0; }
        simd_float2 *b = out + 1 + 4 * e;
        b[0] = simd_make_float2(x0, v0);
        b[1] = simd_make_float2(x1, v0);
        b[2] = simd_make_float2(x0, v1);
        b[3] = simd_make_float2(x1, v1);
    }
}

kl_overlay_uniforms kl_overlay_build(const kl_ovrp_overlay *ov, int eye,
                                     simd_float4x4 origin_from_device,
                                     simd_float4x4 device_from_view,
                                     simd_float4x4 projection) {
    kl_overlay_uniforms u;
    memset(&u, 0, sizeof u);
    u.projection = projection;
    u.model_view = matrix_identity_float4x4;
    u.uv_rect    = simd_make_float4(0, 0, 1, 1);
    u.slice      = 0;
    u.visible    = 0;
    if (!ov) return u;

    // Only the Quad is implemented, and an unimplemented shape is REFUSED
    // rather than drawn as a quad: a cylinder or an equirect placed as a flat
    // rectangle is a wrong picture with no error surface, where an absent one
    // is the failure that is already happening and is at least honest. The
    // caller names it (see kl_reproject.h).
    if (ov->shape != 0) return u;
    if (!(ov->size[0] > 0.0f) || !(ov->size[1] > 0.0f)) return u;

    // Which eyes were named. LEFT(1) and RIGHT(2) are how a guest shows
    // different pixels to each eye — two quads, one per eye — so drawing one of
    // those in both is the other eye's picture on top of this one's.
    if (ov->eye_visibility == 1 && eye != 0) return u;
    if (ov->eye_visibility == 2 && eye != 1) return u;

    u.half_size = simd_make_float2(ov->size[0] * 0.5f, ov->size[1] * 0.5f);

    // Which part of the layer texture this eye reads. The guest states it in
    // PIXELS of its own texture, so it is carried as a fraction for the reason
    // kl_ovrp_render_pose.viewport_of exists: the texture a compositor is
    // holding and the rect the guest filed can be one generation apart, and a
    // fraction is right for either.
    const int *r = ov->viewport[(unsigned)eye > 1 ? 0 : eye];
    if (ov->tex_w > 0 && ov->tex_h > 0 && r[2] > 0 && r[3] > 0)
        u.uv_rect = simd_make_float4((float)r[0] / (float)ov->tex_w,
                                     (float)r[1] / (float)ov->tex_h,
                                     (float)r[2] / (float)ov->tex_w,
                                     (float)r[3] / (float)ov->tex_h);

    // KL_OVERLAY_FLIP_X: mirror the sampled U. AC Nexus's menu panels read
    // horizontally mirrored ("backwards" text) - the guest fills them for a quad
    // it expects viewed from the opposite face than OVR's -Z Pose convention
    // states. Baked into uv_rect (start at the right edge, walk back with a
    // negative width) so no shader or struct change is needed. Off by default so
    // no other target regresses; promoted per-target once confirmed.
    if (kl_env_on("KL_OVERLAY_FLIP_X", 0)) {
        u.uv_rect.x += u.uv_rect.z;
        u.uv_rect.z  = -u.uv_rect.z;
    }
    // KL_OVERLAY_FLIP_Y: mirror the sampled V, independent of the shader's own
    // flip_y (which tracks origin_top_left). AC Nexus's panels come in 180-degree
    // rotated, so the readable result is FLIP_X + FLIP_Y together.
    if (kl_env_on("KL_OVERLAY_FLIP_Y", 0)) {
        u.uv_rect.y += u.uv_rect.w;
        u.uv_rect.w  = -u.uv_rect.w;
    }

    // world <- quad, then view <- world. Unlike the eye pass NOTHING is dropped
    // here: the layer has a position and the display's eye offset is what gives
    // it the stereo disparity a quad at 7 m is supposed to have.
    simd_float4x4 world_from_quad = klr_pose_matrix(ov->pose);
    if (ov->head_locked)
        // Stated, not silently treated as world-locked: the two differ by the
        // whole head pose. Nothing in the corpus submits one yet, so this arm
        // has never run against a guest.
        world_from_quad = simd_mul(origin_from_device, world_from_quad);
    simd_float4x4 world_from_view = simd_mul(origin_from_device, device_from_view);
    u.model_view = simd_mul(simd_inverse(world_from_view), world_from_quad);
    u.srgb_decode = (uint32_t)kl_reproject_srgb_decode();
    u.flip_y = ov->origin_top_left ? 1u : 0u;
    u.visible = 1;
    u.opaque = kl_env_on("KL_OVERLAY_OPAQUE", 0) ? 1u : 0u;
    return u;
}

float kl_reproject_ndc_depth(const kl_reproject_uniforms *u) {
    if (!u) return -1.0f;
    // The quad's centre, in the same space the vertex shader builds it in.
    simd_float4 p = simd_mul(simd_mul(u->projection, u->model_view),
                             simd_make_float4(0, 0, -u->depth, 1));
    return (p.w != 0.0f) ? p.z / p.w : -1.0f;
}

simd_float4x4 kl_reproject_projection(float left, float right, float top, float bottom,
                                      float near_z) {
    // Reverse-Z with an infinite far plane: near maps to 1, infinity to 0.
    // Metal clips to 0 <= z <= w, and the quad sits at 500 m where reverse-Z
    // has plenty of precision left. This exists for the viewer, which has no
    // Compositor Services to ask for a matrix.
    float w = right + left, h = top + bottom;
    simd_float4x4 p = (simd_float4x4){{
        { 2.0f / w, 0, 0, 0 },
        { 0, 2.0f / h, 0, 0 },
        { (right - left) / w, (top - bottom) / h, 0, -1 },
        { 0, 0, near_z, 0 },
    }};
    return p;
}

simd_float4 kl_reproject_tangents(simd_float4x4 p) {
    // Recovered from the two rows that carry x and y, so the depth convention
    // (reverse-Z, infinite far) does not enter into it. For a near plane at n:
    //   m00 = 2n/(r-l), m20 = (r+l)/(r-l)  =>  r/n = (1 + m20)/m00
    // and the tangents are r/n, l/n, t/n, b/n — so n cancels and never has to
    // be known.
    float m00 = p.columns[0][0], m11 = p.columns[1][1];
    float m20 = p.columns[2][0], m21 = p.columns[2][1];
    if (!(fabsf(m00) > 1e-9f) || !(fabsf(m11) > 1e-9f))
        return simd_make_float4(1, 1, 1, 1);
    float right  = ( 1.0f + m20) / m00;
    float left   = (-1.0f + m20) / m00;
    float top    = ( 1.0f + m21) / m11;
    float bottom = (-1.0f + m21) / m11;
    return simd_make_float4(fabsf(left), fabsf(right), fabsf(top), fabsf(bottom));
}

float kl_reproject_delta_degrees(const kl_ovrp_render_pose *rendered,
                                 simd_float4x4 origin_from_device) {
    if (!rendered || !rendered->serial) return 0.0f;
    simd_quatf a = simd_quaternion(rendered->qx, rendered->qy, rendered->qz, rendered->qw);
    simd_quatf b = simd_quaternion(klr_rotation_of(origin_from_device));
    simd_quatf d = simd_mul(simd_inverse(a), b);
    // The angle of the delta rotation, taken the short way round.
    float w = simd_real(d);
    if (w < 0) w = -w;
    if (w > 1.0f) w = 1.0f;
    return 2.0f * acosf(w) * (180.0f / 3.14159265358979f);
}

// ===========================================================================
// DEPTH REPROJECTION (KL_REPROJECT_DEPTH_MODE) — see kl_reproject.h.
// ===========================================================================

int kl_reproject_depth_mode(void) {
    static int m = -1;
    if (m < 0) {
        int v = kl_env_int("KL_REPROJECT_DEPTH_MODE", 0);
        m = (v >= 0 && v <= 2) ? v : 0;
        if (m)
            fprintf(stderr, "  [swim] KL_REPROJECT_DEPTH_MODE=%d: %s\n", m,
                    m == 1 ? "the drawable gets the RENDER pose's anchor (system "
                             "reprojects render -> scanout), 500 m quad depth"
                           : "render anchor + the game's real depth written per pixel");
    }
    return m;
}

int kl_reproject_depth_conv(void) {
    static int c = -1;
    if (c < 0) {
        const char *e = kl_env_str("KL_REPROJECT_DEPTH_CONV", NULL);
        c = (e && (e[0] == 'r' || e[0] == 'R' || e[0] == '1')) ? 1 : 0;
    }
    return c;
}

int kl_reproject_depth_vis(void) {
    static int v = -1;
    if (v < 0) v = kl_env_on("KL_CP_DEPTH_VIS", 0);
    return v;
}

float kl_reproject_depth_linear(float d, float m22, float m23, int conv) {
    if (conv == 1) {
        // Reverse-Z, infinite far, the same near the matrix states.
        if (!(fabsf(m22) > 1e-9f) || !(d > 1e-9f)) return -1.0f;
        float n = m23 / m22;
        return n > 0 ? n / d : -1.0f;
    }
    // The matrix literally: d = (m22 z + m23) / -z  =>  -z = m23 / (d + m22).
    float den = d + m22;
    if (!(fabsf(den) > 1e-9f)) return -1.0f;
    float z = m23 / den;
    return z > 0 ? z : -1.0f;
}

kl_reproject_depth_uniforms kl_reproject_depth_build(const kl_ovrp_render_pose *r,
                                                     int eye, simd_float4x4 projection) {
    kl_reproject_depth_uniforms u;
    memset(&u, 0, sizeof u);
    if ((unsigned)eye > 1) eye = 0;
    u.m22 = r ? r->depth_m22[eye] : 0.0f;
    u.m23 = r ? r->depth_m23[eye] : 0.0f;
    // The drawable's near plane. Its projection is reverse-Z with an infinite
    // far plane (kl_reproject_projection's shape, and Compositor Services'):
    // clip.z = near, clip.w = -z, so the near is the z of column 3. Anything
    // else is not that shape, and a conservative 10 cm stands in.
    float n = projection.columns[3][2];
    u.near_m = (n > 1e-4f && n < 1.0f) ? n : 0.1f;
    if (s_depth == 0.0f) {
        float v = kl_env_float("KL_REPROJECT_DEPTH", 0.0);
        s_depth = (v > 0.0f) ? v : KL_REPROJECT_DEPTH;
    }
    u.far_m = s_depth > u.near_m ? s_depth : KL_REPROJECT_DEPTH;
    u.conv = (uint32_t)kl_reproject_depth_conv();
    u.vis = (uint32_t)kl_reproject_depth_vis();
    return u;
}

// Appended to kl_msl_reproject (so it reuses that source's VOut helpers, the
// sample, the chroma matte and kl_offscreen) — compiled ONLY by a compositor in
// depth mode 2 or KL_CP_DEPTH_VIS, never by mode 0.
//
// The reconstruction. The eye picture is still the quad of kl_reproject_v —
// same grid, same uv, same placement — so the COLOUR of every pixel is exactly
// what mode 0 shows. What changes is the depth written for it. The quad vertex
// at grid coordinate c is the ray (tx, ty, -1) of the RENDER eye, with
// tx = mix(-l, r, c.x), ty = mix(-b, t, c.y); a pixel whose game depth says the
// surface is `dist` metres down the view axis is the point dist * ray, and
// projection * modelView * that point is
//
//     clip = dist * (PM * (tx, ty, -1, 0)) + PM * (0, 0, 0, 1)
//
// The first term is linear in c, so it interpolates as a varying (perspective-
// correct, like c itself and like the uv — it is the same parameterisation of
// the same plane); the second is constant per view. The fragment only has to
// read the game's depth, linearise it and write clip.z / clip.w.
static const char kl_msl_reproject_depth[] =
"\n"
"struct KLDepthU { float m22; float m23; float nearM; float farM;\n"
"                  uint conv; uint vis; uint pad0; uint pad1; };\n"
"struct VOutD { float4 pos [[position]]; float2 uv; uint slice [[flat]];\n"
"               uint srgb [[flat]]; uint src [[flat]];\n"
"               uint chromaOn [[flat]]; float3 chromaKey [[flat]];\n"
"               float2 chromaRange [[flat]];\n"
"               float4 dirClip; float4 orgClip [[flat]];\n"
"               float4 dparm [[flat]]; uint dflags [[flat]]; };\n"
"\n"
// kl_reproject_v, line for line, plus the three reconstruction varyings. A copy
// rather than a shared helper so that kl_msl_reproject — mode 0's source — is
// not touched at all; keep the two in step.
"vertex VOutD kl_reproject_depth_v(uint vid [[vertex_id]],\n"
"                                  ushort amp [[amplification_id]],\n"
"                                  constant KLReproj *ua [[buffer(0)]],\n"
"                                  constant float2 *grid [[buffer(1)]],\n"
"                                  constant KLDepthU *da [[buffer(2)]])\n"
"{\n"
"    constant KLReproj &u = ua[amp];\n"
"    constant KLDepthU &du = da[amp];\n"
"    uint nx = uint(grid[0].x), ny = uint(grid[0].y);\n"
"    uint base = 1u + u.gridEye * (nx + 1u) * (ny + 1u);\n"
"    uint cell = vid / 6u, k = vid % 6u;\n"
"    uint2 g = uint2(cell % nx, cell / nx);\n"
"    g.x += (k == 1u || k == 3u || k == 4u) ? 1u : 0u;\n"
"    g.y += (k == 2u || k == 4u || k == 5u) ? 1u : 0u;\n"
"    float2 c = float2(g) / float2(float(nx), float(ny));\n"
"    float d = u.depth;\n"
"    float tx = mix(-u.tangents.x, u.tangents.y, c.x);\n"
"    float ty = mix(-u.tangents.w, u.tangents.z, c.y);\n"
"    VOutD o;\n"
"    o.slice = u.slice;\n"
"    o.srgb = u.srgbDecode;\n"
"    o.chromaOn = u.chromaOn;\n"
"    o.chromaKey = float3(u.chromaKey);\n"
"    o.chromaRange = float2(u.chromaMin, u.chromaMax);\n"
"    o.src = uint(amp);\n"
"    float4x4 pm = u.projection * u.modelView;\n"
"    o.pos = u.visible == 0u ? kl_offscreen : pm * float4(tx * d, ty * d, -d, 1.0);\n"
"    float2 uv = grid[base + g.y * (nx + 1u) + g.x];\n"
"    if (u.flipY != 0u) uv.y = 1.0 - uv.y;\n"
"    o.uv = uv;\n"
"    o.dirClip = pm * float4(tx, ty, -1.0, 0.0);\n"
"    o.orgClip = pm * float4(0.0, 0.0, 0.0, 1.0);\n"
"    o.dparm = float4(du.m22, du.m23, du.nearM, du.farM);\n"
"    o.dflags = (du.conv & 1u) | ((du.vis & 1u) << 1);\n"
"    return o;\n"
"}\n"
"\n"
// Nearest, by texel: a depth value is not something to filter across an edge.
"static float kl_depth_read(depth2d<float> t, float2 uv)\n"
"{\n"
"    float2 sz = float2(float(t.get_width()), float(t.get_height()));\n"
"    uint2 p = uint2(clamp(uv * sz, float2(0.0), sz - 1.0));\n"
"    return t.read(p);\n"
"}\n"
"\n"
// kl_reproject_depth_linear, in MSL — keep the two identical.
"static float kl_depth_linear(float d, float m22, float m23, uint conv)\n"
"{\n"
"    if (conv == 1u) {\n"
"        if (!(abs(m22) > 1e-9) || !(d > 1e-9)) return -1.0;\n"
"        float n = m23 / m22;\n"
"        return n > 0.0 ? n / d : -1.0;\n"
"    }\n"
"    float den = d + m22;\n"
"    if (!(abs(den) > 1e-9)) return -1.0;\n"
"    float z = m23 / den;\n"
"    return z > 0.0 ? z : -1.0;\n"
"}\n"
"\n"
// Near red -> far blue on a log scale from the near clamp to the far one; a
// pixel with no finite depth is dark grey, so 'sky' is visibly its own answer.
"static float4 kl_depth_false_colour(float dist, float nearM, float farM)\n"
"{\n"
"    if (dist <= 0.0) return float4(0.12, 0.12, 0.12, 1.0);\n"
"    float t = saturate(log(max(dist, nearM) / nearM) / log(farM / nearM));\n"
"    float s = 1.0 - t;\n"
"    float3 jet = saturate(float3(1.5 - abs(4.0 * s - 3.0), 1.5 - abs(4.0 * s - 2.0),\n"
"                                 1.5 - abs(4.0 * s - 1.0)));\n"
"    return float4(jet, 1.0);\n"
"}\n"
"\n"
"static float kl_depth_dist_at(VOutD in, depth2d<float> dep0, depth2d<float> dep1)\n"
"{\n"
"    float raw = in.src == 0u ? kl_depth_read(dep0, in.uv) : kl_depth_read(dep1, in.uv);\n"
"    return kl_depth_linear(raw, in.dparm.x, in.dparm.y, in.dflags & 1u);\n"
"}\n"
"\n"
"struct FOutD { float4 color [[color(0)]]; float depth [[depth(any)]]; };\n"
"\n"
"fragment FOutD kl_reproject_depth_f(VOutD in [[stage_in]],\n"
"                                    texture2d_array<float> tex [[texture(0)]],\n"
"                                    texture2d_array<float> tex1 [[texture(1)]],\n"
"                                    depth2d<float> dep0 [[texture(2)]],\n"
"                                    depth2d<float> dep1 [[texture(3)]],\n"
"                                    sampler samp [[sampler(0)]])\n"
"{\n"
"    float4 c = kl_eye_sample2(tex, tex1, samp, in.uv, in.slice, in.srgb, in.src);\n"
"    bool band = c.r > 0.98 && c.g < 0.02 && c.b > 0.98;\n"
"#if KL_MAGENTA_KEY\n"
"    if (band) c = float4(0.0, 0.0, 0.0, 1.0);\n"
"#endif\n"
"    float nearM = in.dparm.z, farM = in.dparm.w;\n"
"    float dist = kl_depth_dist_at(in, dep0, dep1);\n"
"    FOutD o;\n"
"    o.color = (in.dflags & 2u) != 0u ? kl_depth_false_colour(band ? -1.0 : dist, nearM, farM)\n"
"                                     : kl_chroma_apply(c, in.chromaOn, in.chromaKey, in.chromaRange);\n"
// No finite depth, or the unrendered band: the far clamp — the 500 m the quad
// has always been at, never 0 (visionOS drops a frame whose depth is all 0).
"    if (band || !(dist > 0.0)) dist = farM;\n"
"    dist = clamp(dist, nearM, farM);\n"
"    float4 clip = dist * in.dirClip + in.orgClip;\n"
// Behind the display eye (only possible with a large render -> display delta):
// the quad's own depth, i.e. mode 1's answer for this pixel.
"    float z = clip.w > 1e-6 ? clip.z / clip.w : in.pos.z;\n"
"    o.depth = clamp(z, 1e-7, 1.0);\n"
"    return o;\n"
"}\n"
"\n"
"fragment float4 kl_reproject_depthvis_f(VOutD in [[stage_in]],\n"
"                                        depth2d<float> dep0 [[texture(2)]],\n"
"                                        depth2d<float> dep1 [[texture(3)]])\n"
"{\n"
"    return kl_depth_false_colour(kl_depth_dist_at(in, dep0, dep1), in.dparm.z, in.dparm.w);\n"
"}\n"
"\n"
"kernel void kl_depth_probe_k(depth2d<float> d [[texture(0)]],\n"
"                             device float *out [[buffer(0)]],\n"
"                             uint2 gid [[thread_position_in_grid]])\n"
"{\n"
"    const uint S = 32u;\n"
"    if (gid.x >= S || gid.y >= S) return;\n"
"    uint w = d.get_width(), h = d.get_height();\n"
"    uint2 p = uint2(((gid.x * 2u + 1u) * w) / (2u * S), ((gid.y * 2u + 1u) * h) / (2u * S));\n"
"    out[gid.y * S + gid.x] = d.read(p);\n"
"}\n";

static char *g_msl_reproject_depth;
static void kl_reproject_depth_msl_build(void) {
    size_t n = strlen(kl_msl_reproject) + strlen(kl_msl_reproject_depth) + 64;
    char *s = malloc(n);
    if (!s) return;
    snprintf(s, n, "#define KL_MAGENTA_KEY %d\n%s%s", kl_env_on("KL_CP_MAGENTA_KEY", 1),
             kl_msl_reproject, kl_msl_reproject_depth);
    g_msl_reproject_depth = s;
}
const char *kl_reproject_depth_msl(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, kl_reproject_depth_msl_build);
    return g_msl_reproject_depth ? g_msl_reproject_depth : "";
}

// ---- the [swim] line -------------------------------------------------------

static pthread_mutex_t g_dstat_mu = PTHREAD_MUTEX_INITIALIZER;
static struct {
    int   have, conv, nvalid, n;
    float raw_center, raw_median, raw_sky, raw_near;
    float lin_center, lin_median, lin_sky, lin_near;
    // The other convention's reading of the same samples, so one log line
    // settles KL_REPROJECT_DEPTH_CONV.
    float alt_center, alt_median, alt_near;
    float m22, m23;
} g_dstat;

static int klr_cmpf(const void *a, const void *b) {
    float x = *(const float *)a, y = *(const float *)b;
    return x < y ? -1 : x > y;
}

void kl_reproject_depth_probe_note(const float *raw, int side,
                                   const kl_reproject_depth_uniforms *u) {
    if (!raw || side <= 0 || side > 64 || !u) return;
    int n = side * side, conv = (int)u->conv;
    float lin[64 * 64], alt[64 * 64], rv[64 * 64];
    int nv = 0, na = 0;
    float near_d = 1e30f, near_raw = 0.0f, alt_near = 1e30f;
    for (int i = 0; i < n; i++) {
        float d = kl_reproject_depth_linear(raw[i], u->m22, u->m23, conv);
        float a = kl_reproject_depth_linear(raw[i], u->m22, u->m23, !conv);
        if (d > 0) { lin[nv++] = d; if (d < near_d) { near_d = d; near_raw = raw[i]; } }
        if (a > 0) { alt[na++] = a; if (a < alt_near) alt_near = a; }
        rv[i] = raw[i];
    }
    qsort(rv, (size_t)n, sizeof *rv, klr_cmpf);
    if (nv) qsort(lin, (size_t)nv, sizeof *lin, klr_cmpf);
    if (na) qsort(alt, (size_t)na, sizeof *alt, klr_cmpf);
    int ci = (side / 2) * side + side / 2, si = 1 * side + side / 2;   // centre; top-centre = "sky"
    pthread_mutex_lock(&g_dstat_mu);
    g_dstat.have = 1;
    g_dstat.conv = conv;
    g_dstat.n = n;
    g_dstat.nvalid = nv;
    g_dstat.m22 = u->m22; g_dstat.m23 = u->m23;
    g_dstat.raw_center = raw[ci];
    g_dstat.raw_sky = raw[si];
    g_dstat.raw_median = rv[n / 2];
    g_dstat.raw_near = near_raw;
    g_dstat.lin_center = kl_reproject_depth_linear(raw[ci], u->m22, u->m23, conv);
    g_dstat.lin_sky = kl_reproject_depth_linear(raw[si], u->m22, u->m23, conv);
    g_dstat.lin_median = nv ? lin[nv / 2] : -1.0f;
    g_dstat.lin_near = nv ? near_d : -1.0f;
    g_dstat.alt_center = kl_reproject_depth_linear(raw[ci], u->m22, u->m23, !conv);
    g_dstat.alt_median = na ? alt[na / 2] : -1.0f;
    g_dstat.alt_near = na ? alt_near : -1.0f;
    pthread_mutex_unlock(&g_dstat_mu);
}

void kl_reproject_swim_log(int mode, unsigned frames, double age_mean_ms,
                           double age_max_ms, unsigned ring_hits,
                           unsigned query_hits, unsigned fallbacks,
                           unsigned depth_frames) {
    char dpart[512] = "depth: no probe yet";
    pthread_mutex_lock(&g_dstat_mu);
    if (g_dstat.have) {
        const char *cn = g_dstat.conv ? "reverse" : "matrix";
        const char *an = g_dstat.conv ? "matrix" : "reverse";
        snprintf(dpart, sizeof dpart,
                 "depth (%s, m22 %.5f m23 %.5f): centre raw %.5f = %.2f m, sky raw %.5f "
                 "= %.2f m, median raw %.5f / %.2f m, nearest raw %.5f = %.3f m, %d/%d "
                 "finite | as %s: centre %.2f m, median %.2f m, nearest %.3f m",
                 cn, (double)g_dstat.m22, (double)g_dstat.m23,
                 (double)g_dstat.raw_center, (double)g_dstat.lin_center,
                 (double)g_dstat.raw_sky, (double)g_dstat.lin_sky,
                 (double)g_dstat.raw_median, (double)g_dstat.lin_median,
                 (double)g_dstat.raw_near, (double)g_dstat.lin_near,
                 g_dstat.nvalid, g_dstat.n, an, (double)g_dstat.alt_center,
                 (double)g_dstat.alt_median, (double)g_dstat.alt_near);
    }
    pthread_mutex_unlock(&g_dstat_mu);
    unsigned asked = ring_hits + query_hits + fallbacks;
    fprintf(stderr, "  [swim] mode %d, %u composites: anchor age mean %.1f ms max %.1f ms, "
                    "ring hit %u/%u, query %u, fallback %u, depth written on %u | %s "
                    "(-1 m = no finite depth)\n",
            mode, frames, age_mean_ms, age_max_ms, ring_hits, asked, query_hits,
            fallbacks, depth_frames, dpart);
}
