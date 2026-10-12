// kl_stream_host_mtl.m — compose the guest's two eye textures side by side into
// an IOSurface-backed CVPixelBuffer and encode it with VideoToolbox HEVC.
// The C half (network, pacing, packetisation) is kl_stream_host.c.
//
// Compose: one render pass, two viewports, one full-screen triangle per eye
// sampling the stage's eye MTLTexture (kl_glfb_eye_mtl_texture — MoltenVK's on
// the Vulkan path) through a 2D-array view, the same way kl_view_mtl.m does.
// The whole eye texture is scaled into its half: the stage image IS what the
// guest rendered with the tangents VIDEO carries (kl_openvr's SUBMIT_PROJ), so
// no crop. A render viewport (kl_ovrp_render_pose.viewport) is honoured as a
// fraction when the guest files one; Alyx does not.
//
// Encode: VTCompressionSession, HEVC Main, hardware, low-latency rate control,
// real time, no reordering, keyframes only on request (plus the first), output
// as length-prefixed NAL units with VPS/SPS/PPS prepended on keyframes.
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <VideoToolbox/VideoToolbox.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "kl_stream_host.h"
#include "kl_glfb.h"
#include "kl_ovrp.h"
#include "kl_env.h"

#define SH "[stream-host] "

// Luma and chroma straight into the encoder's own 4:2:0 layout (NV12, video
// range, BT.709). Measured on the M1 Max at 3776x1824: handing VideoToolbox
// BGRA costs its internal RGB->YUV transfer, which caps throughput below 45 fps
// and queues frames (91 ms mean encode latency at 60 fps, 107 ms live), where
// 420v input encodes in ~20 ms even at 90 fps. The eye is sampled as LINEAR
// light (an sRGB texture decodes on sample) and re-encoded with the sRGB curve,
// so a linear-float eye format comes out the same.
static const char kMSL[] =
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VOut { float4 pos [[position]]; float2 uv; };\n"
"struct U { float4 rect; uint slice; uint flipY; };\n"   // rect: uv x0,y0,w,h
"vertex VOut kls_v(uint vid [[vertex_id]], constant U &u [[buffer(0)]]) {\n"
"    float2 p = float2((vid << 1) & 2, vid & 2);\n"
"    VOut o;\n"
"    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);\n"
"    float2 t = float2(p.x, u.flipY != 0u ? 1.0 - p.y : p.y);\n"
"    o.uv = u.rect.xy + t * u.rect.zw;\n"
"    return o;\n"
"}\n"
"static float3 rgb_prime(texture2d_array<float> tex, sampler s, float2 uv, uint slice) {\n"
"    float3 c = saturate(tex.sample(s, uv, slice).rgb);\n"
"    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);\n"
"}\n"
"fragment float kls_y(VOut in [[stage_in]], texture2d_array<float> tex [[texture(0)]],\n"
"                     sampler s [[sampler(0)]], constant U &u [[buffer(0)]]) {\n"
"    float3 c = rgb_prime(tex, s, in.uv, u.slice);\n"
"    float y = dot(c, float3(0.2126, 0.7152, 0.0722));\n"
"    return (16.0 + 219.0 * y) / 255.0;\n"
"}\n"
"fragment float2 kls_c(VOut in [[stage_in]], texture2d_array<float> tex [[texture(0)]],\n"
"                      sampler s [[sampler(0)]], constant U &u [[buffer(0)]]) {\n"
"    float3 c = rgb_prime(tex, s, in.uv, u.slice);\n"
"    float y = dot(c, float3(0.2126, 0.7152, 0.0722));\n"
"    float cb = (c.b - y) / 1.8556, cr = (c.r - y) / 1.5748;\n"
"    return (128.0 + 224.0 * float2(cb, cr)) / 255.0;\n"
"}\n"
"fragment float4 kls_pf(VOut in [[stage_in]], texture2d<float> ty [[texture(0)]],\n"
"                       texture2d<float> tc [[texture(1)]], sampler s [[sampler(0)]]) {\n"
"    float y = (ty.sample(s, in.uv).r * 255.0 - 16.0) / 219.0;\n"
"    float2 c = (tc.sample(s, in.uv).rg * 255.0 - 128.0) / 224.0;\n"
"    float3 rgb = float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x);\n"
"    rgb = saturate(rgb);\n"
"    return float4(select(pow((rgb + 0.055) / 1.055, 2.4), rgb / 12.92, rgb <= 0.04045), 1.0);\n"
"}\n";

typedef struct { float rect[4]; uint32_t slice, flipY; uint32_t pad[2]; } kls_u;

static id<MTLDevice> g_dev;
static id<MTLCommandQueue> g_q;
static id<MTLRenderPipelineState> g_pipe_y, g_pipe_c, g_ppipe;
static id<MTLSamplerState> g_samp;
static CVPixelBufferPoolRef g_pool;
static VTCompressionSessionRef g_vt;
static int g_w, g_h, g_kbps;
static float g_fps;
static kl_stream_enc_out_fn g_out;
static id<MTLTexture> g_last_y, g_last_c;   // the last composed frame, for the preview
static int g_inflight;
static NSLock *g_last_lock;

#define VIEWS 16
static struct { void *src; id<MTLTexture> view; } g_views[VIEWS];
static id<MTLTexture> array_view(id<MTLTexture> src) {
    if (!src || src.textureType == MTLTextureType2DArray) return src;
    void *key = (__bridge void *)src;
    for (int i = 0; i < VIEWS; i++)
        if (g_views[i].src == key) return g_views[i].view;
    id<MTLTexture> v = [src newTextureViewWithPixelFormat:src.pixelFormat
                                              textureType:MTLTextureType2DArray
                                                   levels:NSMakeRange(0, src.mipmapLevelCount)
                                                   slices:NSMakeRange(0, 1)];
    static int next;
    g_views[next].src = key; g_views[next].view = v;   // a ring: stale keys age out
    next = (next + 1) % VIEWS;
    return v;
}

// IOSurface planes -> MTLTextures, cached by surface (the pool recycles a handful).
#define SURFS 8
static struct { IOSurfaceRef s; id<MTLTexture> y, c; } g_surf[SURFS];
static int surface_textures(IOSurfaceRef s, int w, int h, id<MTLTexture> *ty, id<MTLTexture> *tc) {
    for (int i = 0; i < SURFS; i++)
        if (g_surf[i].s == s) { *ty = g_surf[i].y; *tc = g_surf[i].c; return *ty && *tc; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                     width:(NSUInteger)w height:(NSUInteger)h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> y = [g_dev newTextureWithDescriptor:td iosurface:s plane:0];
    td.pixelFormat = MTLPixelFormatRG8Unorm;
    td.width = (NSUInteger)(w / 2); td.height = (NSUInteger)(h / 2);
    id<MTLTexture> c = [g_dev newTextureWithDescriptor:td iosurface:s plane:1];
    static int next;
    if (g_surf[next].s) CFRelease(g_surf[next].s);
    g_surf[next].s = (IOSurfaceRef)CFRetain(s);
    g_surf[next].y = y; g_surf[next].c = c;
    next = (next + 1) % SURFS;
    *ty = y; *tc = c;
    return y && c;
}

static int metal_up(id<MTLDevice> dev) {
    if (g_dev) return g_dev == dev;
    g_dev = dev;
    g_q = [dev newCommandQueue];
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(kMSL) options:nil error:&err];
    if (!lib) {
        fprintf(stderr, SH "compose shader failed: %s\n", err.localizedDescription.UTF8String);
        g_dev = nil;
        return 0;
    }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"kls_v"];
    pd.fragmentFunction = [lib newFunctionWithName:@"kls_y"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatR8Unorm;
    g_pipe_y = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    pd.fragmentFunction = [lib newFunctionWithName:@"kls_c"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRG8Unorm;
    g_pipe_c = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    pd.fragmentFunction = [lib newFunctionWithName:@"kls_pf"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    g_ppipe = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    g_samp = [dev newSamplerStateWithDescriptor:sd];
    g_last_lock = [NSLock new];
    if (!g_pipe_y || !g_pipe_c || !g_q) { g_dev = nil; return 0; }
    fprintf(stderr, SH "composing on %s\n", dev.name.UTF8String);
    return 1;
}

// ---- encoder ----------------------------------------------------------------------

static void put_be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v;
}

static void vt_out(void *refcon, void *frame_refcon, OSStatus status, VTEncodeInfoFlags flags,
                   CMSampleBufferRef sb) {
    (void)refcon;
    kl_stream_frame_meta *m = (kl_stream_frame_meta *)frame_refcon;
    __atomic_sub_fetch(&g_inflight, 1, __ATOMIC_ACQ_REL);
    if (status != noErr || !sb || (flags & kVTEncodeInfo_FrameDropped)) {
        static int said;
        if (said++ < 8) fprintf(stderr, SH "encoder dropped frame %u (status %d)\n",
                                m ? m->frame_id : 0, (int)status);
        free(m);
        return;
    }
    float ms = (float)((kl_stream_host_now() - m->t_encode_start) * 1000.0);
    int key = 1;
    CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (att && CFArrayGetCount(att) > 0) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(att, 0);
        CFBooleanRef ns = CFDictionaryGetValue(d, kCMSampleAttachmentKey_NotSync);
        key = !(ns && CFBooleanGetValue(ns));
    }
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;
    size_t ps_bytes = 0;
    size_t nps = 0;
    int nal_len = 4;
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    if (key && fd) {
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, 0, NULL, NULL, &nps, &nal_len);
        for (size_t i = 0; i < nps; i++) {
            const uint8_t *p; size_t n;
            if (CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, i, &p, &n, NULL, NULL) == noErr)
                ps_bytes += 4 + n;
        }
    } else if (fd) {
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, 0, NULL, NULL, NULL, &nal_len);
    }
    if (nal_len != 4) {
        static int said;
        if (!said++) fprintf(stderr, SH "encoder NAL length size is %d, not 4 — frames dropped\n", nal_len);
        free(m);
        return;
    }
    uint8_t *au = malloc(ps_bytes + len);
    size_t o = 0;
    if (key && fd) {
        for (size_t i = 0; i < nps; i++) {
            const uint8_t *p; size_t n;
            if (CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, i, &p, &n, NULL, NULL) == noErr) {
                put_be32(au + o, (uint32_t)n);
                memcpy(au + o + 4, p, n);
                o += 4 + n;
            }
        }
    }
    if (len) CMBlockBufferCopyDataBytes(bb, 0, len, au + o);
    o += len;
    if (g_out) g_out(m, au, o, key, ms);
    free(au);
    free(m);
}

static void set_num(CFStringRef key, double v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &v);
    OSStatus s = VTSessionSetProperty(g_vt, key, n);
    if (s != noErr) fprintf(stderr, SH "VT property %s = %g refused (%d)\n",
                            CFStringGetCStringPtr(key, kCFStringEncodingUTF8) ?: "?", v, (int)s);
    CFRelease(n);
}
static void set_bool(CFStringRef key, Boolean b) {
    OSStatus s = VTSessionSetProperty(g_vt, key, b ? kCFBooleanTrue : kCFBooleanFalse);
    if (s != noErr) fprintf(stderr, SH "VT property %s refused (%d)\n",
                            CFStringGetCStringPtr(key, kCFStringEncodingUTF8) ?: "?", (int)s);
}

void kl_stream_enc_close(void) {
    if (g_vt) {
        VTCompressionSessionCompleteFrames(g_vt, kCMTimeInvalid);
        VTCompressionSessionInvalidate(g_vt);
        CFRelease(g_vt);
        g_vt = NULL;
    }
    if (g_pool) { CVPixelBufferPoolRelease(g_pool); g_pool = NULL; }
    for (int i = 0; i < SURFS; i++) {
        if (g_surf[i].s) CFRelease(g_surf[i].s);
        g_surf[i].s = NULL; g_surf[i].y = g_surf[i].c = nil;
    }
}

// The bitrate: AverageBitRate alone is a long-run target — in a fast head
// turn the low-latency rate control overshoots it 3-6x for a second or more,
// which is exactly when the link is tightest. DataRateLimits adds a hard cap:
// at most KL_STREAM_RATE_CAP (1.5) x the target over any KL_STREAM_RATE_WIN_S
// (0.5 s). KL_STREAM_RATE_CAP=0: no hard cap.
static void set_rate(int kbps) {
    set_num(kVTCompressionPropertyKey_AverageBitRate, (double)kbps * 1000.0);
    double cap = kl_env_float("KL_STREAM_RATE_CAP", 1.5f);
    double win = kl_env_float("KL_STREAM_RATE_WIN_S", 0.5f);
    if (cap <= 0 || win <= 0) return;
    double bytes = (double)kbps * 1000.0 / 8.0 * cap * win;
    NSArray *lim = @[ @(bytes), @(win) ];
    OSStatus s = VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_DataRateLimits,
                                      (__bridge CFArrayRef)lim);
    static int said;
    if (s != noErr && !said++)
        fprintf(stderr, SH "DataRateLimits refused (%d) — AverageBitRate only\n", (int)s);
}

static int enc_open(int w, int h, int kbps, float fps) {
    kl_stream_enc_close();
    NSDictionary *pba = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)pba, &g_pool) != kCVReturnSuccess) {
        fprintf(stderr, SH "CVPixelBufferPoolCreate failed\n");
        return -1;
    }
    NSDictionary *spec = @{
        (id)kVTVideoEncoderSpecification_EnableLowLatencyRateControl: @YES,
        (id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES,
    };
    OSStatus s = VTCompressionSessionCreate(NULL, w, h, kCMVideoCodecType_HEVC,
                                            (__bridge CFDictionaryRef)spec,
                                            (__bridge CFDictionaryRef)pba, NULL, vt_out, NULL, &g_vt);
    int lowlat = 1;
    if (s != noErr) {
        // Low-latency rate control is not offered for every codec/size on
        // every OS; a plain real-time hardware session is the fallback.
        fprintf(stderr, SH "HEVC low-latency session refused (%d) — retrying without "
                        "EnableLowLatencyRateControl\n", (int)s);
        lowlat = 0;
        NSDictionary *spec2 = @{
            (id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES,
        };
        s = VTCompressionSessionCreate(NULL, w, h, kCMVideoCodecType_HEVC,
                                       (__bridge CFDictionaryRef)spec2,
                                       (__bridge CFDictionaryRef)pba, NULL, vt_out, NULL, &g_vt);
    }
    if (s != noErr) {
        fprintf(stderr, SH "VTCompressionSessionCreate(HEVC %dx%d) failed: %d\n", w, h, (int)s);
        g_vt = NULL;
        return -1;
    }
    set_bool(kVTCompressionPropertyKey_RealTime, true);
    set_bool(kVTCompressionPropertyKey_AllowFrameReordering, false);
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_HEVC_Main_AutoLevel);
    set_rate(kbps);
    set_num(kVTCompressionPropertyKey_ExpectedFrameRate, fps);
    set_num(kVTCompressionPropertyKey_MaxKeyFrameInterval, 1000000);
    set_num(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 100000);
    if (!lowlat) set_num(kVTCompressionPropertyKey_MaxFrameDelayCount, 0);
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_ColorPrimaries,
                         kCVImageBufferColorPrimaries_ITU_R_709_2);
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_TransferFunction,
                         kCVImageBufferTransferFunction_ITU_R_709_2);
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_YCbCrMatrix,
                         kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    VTCompressionSessionPrepareToEncodeFrames(g_vt);
    g_w = w; g_h = h; g_kbps = kbps; g_fps = fps;
    fprintf(stderr, SH "HEVC encoder %dx%d, %d kbit/s, %.0f fps expected, %s rate control\n",
            w, h, kbps, (double)fps, lowlat ? "low-latency" : "default real-time");
    return 0;
}

int kl_stream_enc_frame(int stage, int w, int h, int kbps, float fps, int force_idr,
                        kl_stream_frame_meta *meta, kl_stream_enc_out_fn out) {
    @autoreleasepool {
        int slice[2] = { 0, 0 };
        void *tp[2] = { kl_glfb_eye_mtl_texture(0, stage, &slice[0]),
                        kl_glfb_eye_mtl_texture(1, stage, &slice[1]) };
        if (!tp[0]) return -1;
        id<MTLTexture> src[2] = { (__bridge id<MTLTexture>)tp[0],
                                  tp[1] ? (__bridge id<MTLTexture>)tp[1] : nil };
        if (!metal_up(src[0].device)) return -1;
        if (!g_vt || w != g_w || h != g_h || fps != g_fps) {
            if (enc_open(w, h, kbps, fps) != 0) return -1;
            force_idr = 1;
        } else if (kbps != g_kbps) {
            // The adaptive bitrate: retarget the live session. A new session
            // would cost a keyframe — the very thing a congested link can't take.
            set_rate(kbps);
            g_kbps = kbps;
        }
        // A bounded queue: if the encoder already holds this many frames it is
        // not keeping up, and queueing more only adds latency — skip this one.
        static int max_inflight = -1;
        if (max_inflight < 0) max_inflight = kl_env_int("KL_STREAM_MAX_INFLIGHT", 2);
        if (__atomic_load_n(&g_inflight, __ATOMIC_ACQUIRE) >= max_inflight) return -2;
        meta->t_compose_start = kl_stream_host_now();
        CVPixelBufferRef pb = NULL;
        if (CVPixelBufferPoolCreatePixelBuffer(NULL, g_pool, &pb) != kCVReturnSuccess || !pb) return -1;
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
                              kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
                              kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                              kCVAttachmentMode_ShouldPropagate);
        IOSurfaceRef surf = CVPixelBufferGetIOSurface(pb);
        id<MTLTexture> ty = nil, tc = nil;
        if (!surf || !surface_textures(surf, w, h, &ty, &tc)) { CVPixelBufferRelease(pb); return -1; }

        kl_ovrp_render_pose r;
        int have = kl_ovrp_stage_render_pose(stage, &r);
        kls_u u[2];
        id<MTLTexture> av[2] = { nil, nil };
        for (int e = 0; e < 2; e++) {
            id<MTLTexture> s = src[e] ?: src[0];
            av[e] = array_view(s);
            u[e] = (kls_u){ { 0, 0, 1, 1 }, (uint32_t)(src[e] ? slice[e] : slice[0]),
                            (uint32_t)(kl_glfb_eye_mtl_origin_top_left(src[e] ? e : 0, stage) ? 1 : 0),
                            { 0, 0 } };
            // The render viewport, as a fraction of the texture it was measured
            // against (kl_ovrp.h, viewport_of) — only when it describes this one.
            if (have && r.viewport[e][2] > 0 && r.viewport_of[0] == (int)s.width &&
                r.viewport_of[1] == (int)s.height) {
                u[e].rect[0] = (float)r.viewport[e][0] / (float)s.width;
                u[e].rect[1] = (float)r.viewport[e][1] / (float)s.height;
                u[e].rect[2] = (float)r.viewport[e][2] / (float)s.width;
                u[e].rect[3] = (float)r.viewport[e][3] / (float)s.height;
            }
        }
        id<MTLCommandBuffer> cmd = [g_q commandBuffer];
        for (int plane = 0; plane < 2; plane++) {
            id<MTLTexture> dst = plane ? tc : ty;
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = dst;
            pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
            [enc setRenderPipelineState:plane ? g_pipe_c : g_pipe_y];
            [enc setFragmentSamplerState:g_samp atIndex:0];
            double half = dst.width / 2.0;
            for (int e = 0; e < 2; e++) {
                if (!av[e]) continue;
                [enc setViewport:(MTLViewport){ e * half, 0, half, (double)dst.height, 0, 1 }];
                [enc setVertexBytes:&u[e] length:sizeof u[e] atIndex:0];
                [enc setFragmentBytes:&u[e] length:sizeof u[e] atIndex:0];
                [enc setFragmentTexture:av[e] atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            }
            [enc endEncoding];
        }
        [cmd commit];
        [cmd waitUntilCompleted];
        [g_last_lock lock];
        g_last_y = ty; g_last_c = tc;
        [g_last_lock unlock];

        meta->t_encode_start = kl_stream_host_now();
        kl_stream_frame_meta *m = malloc(sizeof *m);
        *m = *meta;
        g_out = out;
        NSDictionary *fp = force_idr ? @{ (id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES } : nil;
        CMTime pts = CMTimeMakeWithSeconds(meta->t_encode_start, 1000000);
        __atomic_add_fetch(&g_inflight, 1, __ATOMIC_ACQ_REL);
        OSStatus st = VTCompressionSessionEncodeFrame(g_vt, pb, pts, kCMTimeInvalid,
                                                      (__bridge CFDictionaryRef)fp, m, NULL);
        CVPixelBufferRelease(pb);
        if (st != noErr) {
            __atomic_sub_fetch(&g_inflight, 1, __ATOMIC_ACQ_REL);
            free(m);
            static int said;
            if (said++ < 8) fprintf(stderr, SH "VTCompressionSessionEncodeFrame failed: %d\n", (int)st);
            return -1;
        }
        return 0;
    }
}

int kl_stream_preview_present(void *metal_layer, int pw, int ph) {
    @autoreleasepool {
        if (!g_dev || !metal_layer || pw <= 0 || ph <= 0) return 0;
        [g_last_lock lock];
        id<MTLTexture> src = g_last_y, srcc = g_last_c;
        [g_last_lock unlock];
        if (!src || !srcc) return 0;
        CAMetalLayer *layer = (__bridge CAMetalLayer *)metal_layer;
        if (layer.device != g_dev) {
            layer.device = g_dev;
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
        }
        CGSize want = CGSizeMake(pw, ph);
        if (!CGSizeEqualToSize(layer.drawableSize, want)) layer.drawableSize = want;
        id<CAMetalDrawable> d = [layer nextDrawable];
        if (!d) return 0;
        id<MTLCommandBuffer> cmd = [g_q commandBuffer];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = d.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
        [enc setRenderPipelineState:g_ppipe];
        [enc setFragmentSamplerState:g_samp atIndex:0];
        double sc = fmin((double)pw / src.width, (double)ph / src.height);
        double dw = src.width * sc, dh = src.height * sc;
        [enc setViewport:(MTLViewport){ (pw - dw) / 2, (ph - dh) / 2, dw, dh, 0, 1 }];
        kls_u u = { { 0, 0, 1, 1 }, 0, 1, { 0, 0 } };
        [enc setVertexBytes:&u length:sizeof u atIndex:0];
        [enc setFragmentTexture:src atIndex:0];
        [enc setFragmentTexture:srcc atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        [cmd presentDrawable:d];
        [cmd commit];
        return 1;
    }
}
