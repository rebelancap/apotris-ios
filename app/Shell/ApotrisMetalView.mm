#import "ApotrisMetalView.h"

#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>

#include "AppBridge.h"

// Mirrors liba_window.cpp's SDL dest-rect math: draw the full 512x512 texture
// at windowScale, centered, letting the drawable clip it (rowStart/rowEnd
// content placement is handled by the engine reading those globals).
extern float windowScale;

static NSString* const kShaderSource = @""
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VSOut { float4 pos [[position]]; float2 uv; };\n"
// params.x = filter (0 sharp, 1 lcd, 2 crt); params.y = output px per texel.
"struct Uniforms { float2 drawableSize; float2 params; float4 destRect; };\n"
"vertex VSOut blit_vs(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {\n"
"    float2 quad[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };\n"
"    float2 q = quad[vid];\n"
"    float2 px = float2(u.destRect.x + q.x * u.destRect.z,\n"
"                       u.destRect.y + q.y * u.destRect.w);\n"
"    float2 ndc = float2(px.x / u.drawableSize.x * 2.0 - 1.0,\n"
"                        1.0 - px.y / u.drawableSize.y * 2.0);\n"
"    VSOut out; out.pos = float4(ndc, 0, 1); out.uv = q; return out;\n"
"}\n"
"fragment float4 blit_fs(VSOut in [[stage_in]],\n"
"                        texture2d<float> tex [[texture(0)]],\n"
"                        sampler s [[sampler(0)]],\n"
"                        constant Uniforms& u [[buffer(0)]]) {\n"
"    const float2 texSize = float2(512.0, 512.0);\n"
"    int mode = int(u.params.x + 0.5);\n"
"    float ppt = max(u.params.y, 1.0);\n"
"    float2 px = in.uv * texSize;\n"
"    // sharp-bilinear (Themaister): the texel interior stays fully flat and\n"
"    // only the last output pixel at each edge blends — crisp like nearest but\n"
"    // without the non-integer-scale shimmer. Uses ppt (output px per texel),\n"
"    // not fwidth, which is unreliable under visionOS foveated rendering.\n"
"    float2 tf = floor(px);\n"
"    float2 region = 0.5 - 0.5 / ppt;\n"
"    float2 cd = fract(px) - 0.5;\n"
"    float2 f = (cd - clamp(cd, -region, region)) * ppt + 0.5;\n"
"    float3 col = tex.sample(s, (tf + f) / texSize).rgb;\n"
"    if (mode == 1) {\n"           // LCD: per-pixel grid + faint tint
"        float2 f = fract(px);\n"
"        float2 dedge = min(f, 1.0 - f);\n"
"        float g = min(dedge.x, dedge.y);\n"
"        float wid = clamp(1.1 / ppt, 0.02, 0.35);\n"
"        col *= mix(0.76, 1.0, smoothstep(0.0, wid, g));\n"
"        col *= float3(0.96, 1.0, 0.95);\n"
"    } else if (mode == 2) {\n"    // CRT: scanlines + slight bloom
"        float beam = 0.5 + 0.5 * cos((px.y - 0.5) * 6.2831853);\n"
"        col *= mix(0.58, 1.06, beam);\n"
"        col = clamp(col + col * 0.12, 0.0, 1.0);\n"
"    }\n"
"    return float4(col, 1.0);\n"
"}\n";

typedef struct {
    simd_float2 drawableSize;
    simd_float2 params;   // x = filter mode, y = output px per texel
    simd_float4 destRect; // pixel-snapped x, y, w, h
} BlitUniforms;

@implementation ApotrisMetalView {
    CADisplayLink* _displayLink;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLTexture> _texture;
    id<MTLSamplerState> _sampler;
    CFTimeInterval _lastGameTick;
    int _filterMode; // 0 sharp, 1 lcd, 2 crt
}

- (void)setFilterMode:(NSInteger)mode {
    _filterMode = (int)mode;
}

+ (Class)layerClass {
    return [CAMetalLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self setupMetal];
        self.multipleTouchEnabled = YES;
        self.userInteractionEnabled = NO; // gestures live in the overlay view

        // visionOS gamepad claim lives on a dedicated interactive host view
        // (PadClaim in GameScreen.swift) — a claim on this userInteractionEnabled
        // = NO view is inert on device. See VISION-PRO-GUIDE §1.3.

        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(appDidEnterBackground)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(appWillEnterForeground)
                   name:UIApplicationWillEnterForegroundNotification
                 object:nil];
    }
    return self;
}

- (void)appDidEnterBackground {
    _displayLink.paused = YES;
}

- (void)appWillEnterForeground {
    _displayLink.paused = NO;
}

- (CAMetalLayer*)metalLayer {
    return (CAMetalLayer*)self.layer;
}

- (void)setupMetal {
    _device = MTLCreateSystemDefaultDevice();
    _queue = [_device newCommandQueue];

    CAMetalLayer* layer = [self metalLayer];
    layer.device = _device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;

    NSError* error = nil;
    id<MTLLibrary> lib = [_device newLibraryWithSource:kShaderSource
                                               options:nil
                                                 error:&error];
    NSAssert(lib, @"Metal shader compile failed: %@", error);

    MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [lib newFunctionWithName:@"blit_vs"];
    desc.fragmentFunction = [lib newFunctionWithName:@"blit_fs"];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    _pipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&error];
    NSAssert(_pipeline, @"Pipeline create failed: %@", error);

    MTLTextureDescriptor* texDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:512
                                    height:512
                                 mipmapped:NO];
    texDesc.usage = MTLTextureUsageShaderRead;
#if TARGET_OS_SIMULATOR
    texDesc.storageMode = MTLStorageModeShared;
#endif
    _texture = [_device newTextureWithDescriptor:texDesc];

    // Linear sampler; the fragment shader does sharp-bilinear so pixels stay
    // crisp while non-integer-scale seams are antialiased.
    MTLSamplerDescriptor* sampDesc = [MTLSamplerDescriptor new];
    sampDesc.minFilter = MTLSamplerMinMagFilterLinear;
    sampDesc.magFilter = MTLSamplerMinMagFilterLinear;
    _sampler = [_device newSamplerStateWithDescriptor:sampDesc];

    _displayLink = [CADisplayLink displayLinkWithTarget:self
                                               selector:@selector(displayTick:)];
    if (@available(iOS 15.0, *)) {
        _displayLink.preferredFrameRateRange =
            CAFrameRateRangeMake(60, 120, 60);
    }
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                       forMode:NSRunLoopCommonModes];
    _lastGameTick = 0;
}

- (void)setPaused:(BOOL)paused {
    _displayLink.paused = paused;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat scale = self.traitCollection.displayScale;
    if (scale <= 0)
        scale = 2.0;
#if TARGET_OS_VISION
    // visionOS composites and reprojects the window onto a very high angular-
    // resolution display; supersample generously so the compositor has real
    // pixels to reproject rather than upscaling an under-resolved drawable.
    scale *= 3.0;
#else
    // iOS is already at native retina; a 2x supersample cleans up the
    // sharp-bilinear pixel edges (SSAA) at non-integer game scale.
    scale *= 2.0;
#endif
    CGSize sizePx = CGSizeMake(self.bounds.size.width * scale,
                               self.bounds.size.height * scale);
    if (sizePx.width < 1 || sizePx.height < 1)
        return;
    // Cap the drawable so we never exceed Metal texture limits on huge windows.
    CGFloat maxDim = 8192.0;
    CGFloat over = MAX(sizePx.width, sizePx.height) / maxDim;
    if (over > 1.0) {
        sizePx.width /= over;
        sizePx.height /= over;
        scale /= over;
    }
    [self metalLayer].contentsScale = scale;
    [self metalLayer].drawableSize = sizePx;
    apotris_set_drawable_size((int)sizePx.width, (int)sizePx.height);
}

- (void)displayTick:(CADisplayLink*)link {
    // Session policy + mix gain: ticked here rather than off gameplay so the
    // menus and attract demo duck too.
    apotris_audio_tick();

    // Pace the game to 60 Hz regardless of display refresh.
    CFTimeInterval now = link.timestamp;
    if (now - _lastGameTick >= (1.0 / 61.0)) {
        _lastGameTick = now;
        apotris_frame_tick();
    }

    const uint8_t* frame = apotris_latest_frame();
    [_texture replaceRegion:MTLRegionMake2D(0, 0, 512, 512)
                mipmapLevel:0
                  withBytes:frame
                bytesPerRow:512 * 4];

    id<CAMetalDrawable> drawable = [[self metalLayer] nextDrawable];
    if (!drawable)
        return;

    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    BlitUniforms uniforms;
    CGSize ds = [self metalLayer].drawableSize;
    uniforms.drawableSize = simd_make_float2((float)ds.width, (float)ds.height);
    // Snap the dest rect to whole pixels — fractional offsets bleed slivers
    // of adjacent framebuffer columns at the edges.
    float w = floorf(512.0f * windowScale);
    float x0 = floorf(-(w - (float)ds.width) / 2.0f);
    float y0 = floorf(-(w - (float)ds.height) / 2.0f);
    uniforms.destRect = simd_make_float4(x0, y0, w, w);
    uniforms.params = simd_make_float2((float)_filterMode, w / 512.0f);

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc =
        [cmd renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:_pipeline];
    [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [enc setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [enc setFragmentTexture:_texture atIndex:0];
    [enc setFragmentSamplerState:_sampler atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
            vertexStart:0
            vertexCount:4];
    [enc endEncoding];
    [cmd presentDrawable:drawable];
    [cmd commit];
}

- (void)removeFromSuperview {
    [_displayLink invalidate];
    [super removeFromSuperview];
}

@end
