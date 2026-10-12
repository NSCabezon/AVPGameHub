// kl_stream_harness_mtl.m — the headset's "decoded frame -> per-eye stage
// texture" step (KleptonStreamFramePublisher in KleptonStreamClient.swift),
// redone on the Mac so the harness can time it and check its output:
//
//   BGRA decode (KL_STREAM_DECODE_BGRA=1): one blit per eye into a 2-slice
//     bgra8Unorm_srgb texture, as the Swift publisher does.
//   native 420v/x420: one render pass per eye with kl_stream_yuv_msl() — the
//     SAME shader source the app compiles — into the same kind of texture.
//
// harness_publish() waits for the GPU and reports its GPU time and the wall
// time of the whole step; harness_publish_png() reads the two slices back and
// writes them side by side, so the PNGs are what the compositor would sample.
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>

#include "kl_stream_client.h"

static id<MTLDevice> g_dev;
static id<MTLCommandQueue> g_q;
static id<MTLRenderPipelineState> g_pipe;
static CVMetalTextureCacheRef g_cache;
static id<MTLTexture> g_stage, g_stage_unorm;
static int g_ew, g_h;

static int up(void) {
    if (g_dev) return 1;
    g_dev = MTLCreateSystemDefaultDevice();
    if (!g_dev) return 0;
    g_q = [g_dev newCommandQueue];
    CVMetalTextureCacheCreate(NULL, NULL, g_dev, NULL, &g_cache);
    NSError *err = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(kl_stream_yuv_msl()) options:nil error:&err];
    if (!lib) { fprintf(stderr, "harness: yuv shader: %s\n", err.localizedDescription.UTF8String); return 0; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"kl_stream_yuv_v"];
    pd.fragmentFunction = [lib newFunctionWithName:@"kl_stream_yuv_f"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    g_pipe = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!g_pipe) { fprintf(stderr, "harness: yuv pipeline: %s\n", err.localizedDescription.UTF8String); return 0; }
    return 1;
}

static id<MTLTexture> plane(CVPixelBufferRef pb, size_t p, MTLPixelFormat f, CVMetalTextureRef *keep) {
    size_t w = CVPixelBufferGetWidthOfPlane(pb, p), h = CVPixelBufferGetHeightOfPlane(pb, p);
    if (CVMetalTextureCacheCreateTextureFromImage(NULL, g_cache, pb, NULL, f, w, h, p, keep) != kCVReturnSuccess)
        return nil;
    return CVMetalTextureGetTexture(*keep);
}

int harness_publish(CVPixelBufferRef pb, double *gpu_ms, double *wall_ms) {
    @autoreleasepool {
        if (!up()) return -1;
        double t0 = kl_stream_now();
        int W = (int)CVPixelBufferGetWidth(pb), H = (int)CVPixelBufferGetHeight(pb), ew = W / 2;
        if (!g_stage || ew != g_ew || H != g_h) {
            MTLTextureDescriptor *d = [MTLTextureDescriptor new];
            d.textureType = MTLTextureType2DArray;
            d.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
            d.width = (NSUInteger)ew; d.height = (NSUInteger)H; d.arrayLength = 2;
            d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;
            d.storageMode = MTLStorageModePrivate;
            g_stage = [g_dev newTextureWithDescriptor:d];
            g_stage_unorm = [g_stage newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm];
            g_ew = ew; g_h = H;
        }
        OSType fmt = CVPixelBufferGetPixelFormatType(pb);
        id<MTLCommandBuffer> cmd = [g_q commandBuffer];
        CVMetalTextureRef k0 = NULL, k1 = NULL;
        if (fmt == kCVPixelFormatType_32BGRA) {
            id<MTLTexture> src = plane(pb, 0, MTLPixelFormatBGRA8Unorm_sRGB, &k0);
            if (!src) return -1;
            // CVMetalTextureCacheCreateTextureFromImage with plane 0 on a
            // non-planar buffer: fine, it is the only plane.
            id<MTLBlitCommandEncoder> b = [cmd blitCommandEncoder];
            for (int e = 0; e < 2; e++)
                [b copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake((NSUInteger)(e * ew), 0, 0)
                        sourceSize:MTLSizeMake((NSUInteger)ew, (NSUInteger)H, 1) toTexture:g_stage
                  destinationSlice:(NSUInteger)e destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            [b endEncoding];
        } else {
            int ten = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
            id<MTLTexture> ty = plane(pb, 0, ten ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm, &k0);
            id<MTLTexture> tc = plane(pb, 1, ten ? MTLPixelFormatRG16Unorm : MTLPixelFormatRG8Unorm, &k1);
            if (!ty || !tc) { if (k0) CFRelease(k0); if (k1) CFRelease(k1); return -1; }
            kl_stream_yuv_uniforms u;
            kl_stream_yuv_params(fmt, &u);
            u.eye_w = (uint32_t)ew; u.frame_w = (uint32_t)W; u.frame_h = (uint32_t)H;
            for (int e = 0; e < 2; e++) {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = g_stage_unorm;
                rp.colorAttachments[0].slice = (NSUInteger)e;
                rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rp];
                [enc setRenderPipelineState:g_pipe];
                u.x0 = (uint32_t)(e * ew);
                [enc setFragmentBytes:&u length:sizeof u atIndex:0];
                [enc setFragmentTexture:ty atIndex:0];
                [enc setFragmentTexture:tc atIndex:1];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [enc endEncoding];
            }
        }
        [cmd commit];
        [cmd waitUntilCompleted];
        if (k0) CFRelease(k0);
        if (k1) CFRelease(k1);
        if (gpu_ms) *gpu_ms = (cmd.GPUEndTime - cmd.GPUStartTime) * 1000.0;
        if (wall_ms) *wall_ms = (kl_stream_now() - t0) * 1000.0;
        return cmd.status == MTLCommandBufferStatusCompleted ? 0 : -1;
    }
}

// The two published slices, side by side, as a PNG.
int harness_publish_png(const char *path) {
    @autoreleasepool {
        if (!g_stage) return 0;
        size_t ew = (size_t)g_ew, h = (size_t)g_h, row = ew * 2 * 4;
        id<MTLBuffer> buf = [g_dev newBufferWithLength:row * h options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cmd = [g_q commandBuffer];
        id<MTLBlitCommandEncoder> b = [cmd blitCommandEncoder];
        for (int e = 0; e < 2; e++)
            [b copyFromTexture:g_stage sourceSlice:(NSUInteger)e sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                    sourceSize:MTLSizeMake(ew, h, 1) toBuffer:buf destinationOffset:(NSUInteger)e * ew * 4
               destinationBytesPerRow:row destinationBytesPerImage:row * h];
        [b endEncoding];
        [cmd commit];
        [cmd waitUntilCompleted];
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef cg = CGBitmapContextCreate(buf.contents, ew * 2, h, 8, row, cs,
                                                kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        int ok = 0;
        if (cg) {
            CGImageRef img = CGBitmapContextCreateImage(cg);
            NSURL *url = [NSURL fileURLWithPath:@(path)];
            CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
            if (d) { CGImageDestinationAddImage(d, img, NULL); ok = CGImageDestinationFinalize(d); CFRelease(d); }
            CGImageRelease(img);
            CGContextRelease(cg);
        }
        CGColorSpaceRelease(cs);
        return ok;
    }
}
