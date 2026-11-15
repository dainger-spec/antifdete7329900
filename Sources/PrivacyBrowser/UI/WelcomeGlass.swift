import AppKit
import Metal
import MetalPerformanceShaders
import QuartzCore
import SwiftUI

// The launch screen's glass (WelcomeSplash): the greeting's outline, revealed by the pen, made into
// clear glass lit by the horizon — the maths of the approved prototype's WebGL shader
// (design/prototypes/welcome.html), in Metal. The shader is compiled from its source as the app
// starts (`WelcomeGlassRenderer.prepare`): SwiftPM builds no .metal files here, and the system's
// compiler is always there at run time. Per frame: the masks are drawn by Core Graphics (the
// outline, cut to the pen's way), blurred on the GPU (Metal Performance Shaders) into the height
// maps, and the fragment shader shades each pixel from four samples (supersampled). Where Metal is
// missing or the shader does not build, `WelcomeFallbackGlass` draws the outline in SwiftUI instead.

/// The prototype's fragment shader in the Metal Shading Language, line for line.
enum WelcomeGlassShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct WelcomeVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct WelcomeUniforms {
        float2 size;      // the glass's pixels
        float2 origin;    // its top left in the window, pixels
        float2 view;      // the window, pixels
        float stroke;     // the font's widest stroke, pixels
        float softSlope;
        float sharpSlope;
        float softStep;
        float sharpStep;
        float alpha;
    };

    vertex WelcomeVertexOut welcomeVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
        WelcomeVertexOut out;
        out.position = float4(p, 0.0, 1.0);
        out.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
        return out;
    }

    static float tap(texture2d<float> t, sampler s, float2 uv) { return t.sample(s, uv).r; }

    // The height map's slope over a baseline of a few pixels (not one: its 8 bits would show as
    // ripples), four taps a side.
    static float3 normalOf(texture2d<float> t, sampler s, float2 uv, float2 size, float slope, float step) {
        float2 px = step / size;
        float2 d = px * 0.5;
        float r = tap(t, s, uv + float2(px.x, 0.0)) + tap(t, s, uv + float2(px.x, d.y)) + tap(t, s, uv + float2(px.x, -d.y)) + tap(t, s, uv + float2(px.x * 0.5, 0.0));
        float l = tap(t, s, uv - float2(px.x, 0.0)) + tap(t, s, uv - float2(px.x, d.y)) + tap(t, s, uv - float2(px.x, -d.y)) + tap(t, s, uv - float2(px.x * 0.5, 0.0));
        float b = tap(t, s, uv + float2(0.0, px.y)) + tap(t, s, uv + float2(d.x, px.y)) + tap(t, s, uv + float2(-d.x, px.y)) + tap(t, s, uv + float2(0.0, px.y * 0.5));
        float u = tap(t, s, uv - float2(0.0, px.y)) + tap(t, s, uv - float2(d.x, px.y)) + tap(t, s, uv - float2(-d.x, px.y)) + tap(t, s, uv - float2(0.0, px.y * 0.5));
        float2 g = float2(r - l, b - u) / (4.0 * step * 0.875);
        return normalize(float3(-g * slope, 1.0));
    }

    static float4 shade(float2 uv, constant WelcomeUniforms &u, sampler s,
                        texture2d<float> mask, texture2d<float> soft, texture2d<float> sharp, texture2d<float> glow,
                        texture2d<float> trail, texture2d<float> glint, texture2d<float> horizon) {
        float m = tap(mask, s, uv);
        float glowing = tap(glow, s, uv);
        float2 pos = u.origin + uv * u.size;
        if (m < 0.002) {
            float g = glowing * 0.07;
            return float4(float3(g), g) * u.alpha;
        }
        float h = tap(soft, s, uv);
        float3 n = normalOf(soft, s, uv, u.size, u.softSlope, u.softStep);
        float3 ns = normalOf(sharp, s, uv, u.size, u.sharpSlope, u.sharpStep);
        float3 cool = float3(0.90, 0.94, 1.0);
        // What is behind, seen through the rod: pulled toward its middle, as a convex rod bends it.
        // A touch of dispersion: red bends least, blue most.
        float2 bend = n.xy * u.stroke;
        float3 behind = float3(horizon.sample(s, (pos - bend * 0.44) / u.view).r,
                               horizon.sample(s, (pos - bend * 0.45) / u.view).g,
                               horizon.sample(s, (pos - bend * 0.465) / u.view).b);
        // The horizon's light under the letter: it lights the glass from below and behind.
        float below = dot(horizon.sample(s, (pos + float2(0.0, u.stroke * 1.1)) / u.view).rgb, float3(0.3333));
        // Clear body: what is behind, darkened a touch where the glass is thickest, a breath of cool white.
        float3 color = behind * (0.9 - 0.14 * h) + cool * (0.012 + 0.03 * h);
        // Toward its edges the rod gathers the light around it (a soft bevel), and the very edge
        // catches it (Fresnel): light lines, never a dark one.
        float bevel = 1.0 - n.z;
        color += cool * bevel * 0.28;
        float fresnel = pow(max(1.0 - ns.z, 0.0), 4.0);
        color += cool * fresnel * 0.30;
        // The key light, above and in front: a crisp narrow highlight along the upper edges, its bloom…
        float3 key = normalize(float3(-0.22, -0.82, 0.53));
        float3 halfway = normalize(key + float3(0.0, 0.0, 1.0));
        float spec = pow(max(dot(ns, halfway), 0.0), 48.0) * 2.1 + pow(max(dot(n, halfway), 0.0), 16.0) * 0.10;
        // …and the thin bright line the whole upper edge catches from it.
        float upper = fresnel * smoothstep(0.1, 0.8, -ns.y / max(length(ns.xy), 1e-3));
        color += float3(1.0) * (spec + upper * 0.55);
        // The horizon behind and below: a rim along the lower edges, brighter where its light is.
        float3 rimLight = normalize(float3(0.0, 0.94, 0.25));
        float rim = pow(max(dot(ns, rimLight), 0.0), 3.0) * 0.9 + pow(max(dot(n, rimLight), 0.0), 2.0) * 0.25;
        color += cool * rim * (0.12 + 1.1 * below);
        // A faint caustic: that light gathered inside, near the rod's top.
        float caustic = smoothstep(0.6, 0.9, h) * smoothstep(0.05, 0.4, -n.y) * (0.06 + 0.4 * below);
        color += cool * caustic * 0.45;
        // The pen's fresh stroke, and the light that runs along the finished word.
        float tr = tap(trail, s, uv);
        float gl = tap(glint, s, uv);
        color += cool * (tr * 0.22 + gl * 0.36) + float3(1.0) * spec * (tr * 0.45 + gl * 0.9);
        // Highlights roll off above 0.82 instead of clipping.
        float3 over = max(color - 0.82, 0.0);
        color = min(color, float3(0.82)) + 0.18 * (float3(1.0) - exp(-over / 0.18));
        float g = glowing * 0.07 * (1.0 - m);
        return float4(color * m + float3(g), m + g) * u.alpha;
    }

    // Four samples a pixel, on a rotated grid: no stair-steps on the highlights.
    fragment float4 welcomeGlass(WelcomeVertexOut in [[stage_in]], constant WelcomeUniforms &u [[buffer(0)]],
                                 texture2d<float> mask [[texture(0)]], texture2d<float> soft [[texture(1)]],
                                 texture2d<float> sharp [[texture(2)]], texture2d<float> glow [[texture(3)]],
                                 texture2d<float> trail [[texture(4)]], texture2d<float> glint [[texture(5)]],
                                 texture2d<float> horizon [[texture(6)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 px = 1.0 / u.size;
        float4 sum = shade(in.uv + float2(-0.125, -0.375) * px, u, s, mask, soft, sharp, glow, trail, glint, horizon)
                   + shade(in.uv + float2(0.375, -0.125) * px, u, s, mask, soft, sharp, glow, trail, glint, horizon)
                   + shade(in.uv + float2(0.125, 0.375) * px, u, s, mask, soft, sharp, glow, trail, glint, horizon)
                   + shade(in.uv + float2(-0.375, 0.125) * px, u, s, mask, soft, sharp, glow, trail, glint, horizon);
        return sum * 0.25;
    }
    """
}

/// Metal for the launch screen: the device, its queue and the compiled shader. Made once, in the
/// background, as the app starts with a launch screen to show; let go when the screen has opened.
final class WelcomeGlassRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState

    private init(device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState) {
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    /// The renderer, once it is made (read on the main thread).
    private(set) static var shared: WelcomeGlassRenderer?
    /// It is being made.
    private(set) static var isPreparing = false
    /// It could not be made on this Mac (no Metal, no Metal Performance Shaders, the shader did not
    /// build): the drawn glass then.
    private(set) static var unavailable = false

    /// Starts making it in the background (WelcomeLaunch, as the app starts): the shader's compile
    /// is done before the pen starts.
    static func prepare() {
        guard shared == nil, !isPreparing, !unavailable else { return }
        isPreparing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let made = make()
            DispatchQueue.main.async {
                shared = made
                unavailable = made == nil
                isPreparing = false
            }
        }
    }

    /// The renderer now, made here if need be (the snapshots' still pictures).
    static func prepareNow() -> WelcomeGlassRenderer? {
        if let shared { return shared }
        guard !unavailable else { return nil }
        shared = make()
        unavailable = shared == nil
        return shared
    }

    /// The launch screen has opened: the device, the queue and the shader go.
    static func release() {
        shared = nil
    }

    private static func make() -> WelcomeGlassRenderer? {
        guard let device = MTLCreateSystemDefaultDevice(), MPSSupportsMTLDevice(device),
              let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: WelcomeGlassShader.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "welcomeVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "welcomeGlass")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            return WelcomeGlassRenderer(device: device, queue: queue, pipeline: pipeline)
        } catch {
            return nil
        }
    }
}

/// One frame of the glass: what is written, in the glass's own frame (points, y down).
struct WelcomeGlassFrame {
    /// The greeting's outline.
    let outline: CGPath
    /// The pen's way so far; nil when the greeting is written whole.
    let revealed: CGPath?
    /// The pen's fresh stroke, and the settle's light (nil: none).
    let trail: CGPath?
    let glint: CGPath?
    /// The reveal's width and the font's widest stroke, points.
    let reveal: CGFloat
    let stroke: CGFloat
    /// The glass's size, and its top left in the window (points).
    let size: CGSize
    let origin: CGPoint
    /// The window, points, and its pixels a point.
    let view: CGSize
    let scale: CGFloat
    let alpha: Double
    /// The horizon's picture, the window's size at `scale`: what the glass bends.
    let horizon: CGImage
}

/// The textures one glass view keeps, and the drawing of a frame into them.
final class WelcomeGlassCanvas {
    private let renderer: WelcomeGlassRenderer
    private var width = 0
    private var height = 0
    private var maskContext: CGContext?
    private var lineContext: CGContext?
    private var mask: MTLTexture?
    private var soft: MTLTexture?
    private var sharp: MTLTexture?
    private var glow: MTLTexture?
    private var trailRaw: MTLTexture?
    private var trail: MTLTexture?
    private var glintRaw: MTLTexture?
    private var glint: MTLTexture?
    /// A pixel of nothing: the fresh stroke's and the settle's texture when there is none.
    private var empty: MTLTexture?
    private var horizonImage: CGImage?
    private var horizon: MTLTexture?
    private var horizonSoft: MTLTexture?
    private var blurs: [Int: MPSImageGaussianBlur] = [:]
    /// The masks hold the whole greeting already (nothing to draw again while it settles).
    private var whole = false

    init(renderer: WelcomeGlassRenderer) {
        self.renderer = renderer
    }

    /// Lets go of every texture (the screen has opened).
    func release() {
        maskContext = nil
        lineContext = nil
        mask = nil; soft = nil; sharp = nil; glow = nil
        trailRaw = nil; trail = nil; glintRaw = nil; glint = nil; empty = nil
        horizonImage = nil; horizon = nil; horizonSoft = nil
        blurs = [:]
        width = 0
        height = 0
    }

    /// Draws `frame` into the layer's next drawable.
    func draw(_ frame: WelcomeGlassFrame, into layer: CAMetalLayer) {
        guard let buffer = renderer.queue.makeCommandBuffer(), prepare(frame, buffer) else { return }
        guard let drawable = layer.nextDrawable() else { return }
        encode(frame, into: drawable.texture, buffer)
        buffer.present(drawable)
        buffer.commit()
    }

    /// `frame` as a picture (the snapshots: a cached picture of a window holds no Metal layer).
    func image(_ frame: WelcomeGlassFrame) -> CGImage? {
        guard let buffer = renderer.queue.makeCommandBuffer(), prepare(frame, buffer) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let target = renderer.device.makeTexture(descriptor: descriptor) else { return nil }
        encode(frame, into: target, buffer)
        if let blit = buffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        target.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    // MARK: Textures

    /// The masks drawn and blurred for `frame`; false when the textures cannot be made.
    private func prepare(_ frame: WelcomeGlassFrame, _ buffer: MTLCommandBuffer) -> Bool {
        let w = max(1, Int((frame.size.width * frame.scale).rounded()))
        let h = max(1, Int((frame.size.height * frame.scale).rounded()))
        if w != width || h != height {
            release()
            guard allocate(w, h) else { return false }
        }
        let sw = frame.stroke * frame.scale
        let softSigma = sw * 0.26, sharpSigma = max(1.2, sw * 0.08)
        if horizonImage !== frame.horizon {
            guard uploadHorizon(frame.horizon, sigma: sw * 0.07, buffer) else { return false }
        }
        guard let mask, let soft, let sharp, let glow else { return false }
        let full = frame.revealed == nil
        if !(full && whole) {
            draw(into: maskContext, frame) { context in
                if let revealed = frame.revealed {
                    context.addPath(frame.outline)
                    context.clip(using: .winding)
                    stroke(revealed, width: frame.reveal, in: context)
                } else {
                    context.addPath(frame.outline)
                    context.fillPath(using: .winding)
                }
            }
            upload(maskContext, to: mask)
            blur(mask, into: soft, sigma: softSigma, buffer)
            blur(mask, into: sharp, sigma: sharpSigma, buffer)
            blur(mask, into: glow, sigma: sw * 0.9, buffer)
            whole = full
        }
        // The pen's fresh stroke and the settle's light: cut to the outline, softened.
        for (path, width, sigma, raw, out) in [(frame.trail, frame.reveal * 1.1, sw * 0.18, trailRaw, trail),
                                                (frame.glint, frame.reveal * 1.4, sw * 0.3, glintRaw, glint)] {
            guard let path, let raw, let out else { continue }
            draw(into: lineContext, frame) { context in
                context.addPath(frame.outline)
                context.clip(using: .winding)
                stroke(path, width: width, in: context)
            }
            upload(lineContext, to: raw)
            blur(raw, into: out, sigma: sigma, buffer)
        }
        return true
    }

    private func encode(_ frame: WelcomeGlassFrame, into target: MTLTexture, _ buffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let sw = Float(frame.stroke * frame.scale)
        let softSigma = sw * 0.26, sharpSigma = max(1.2, sw * 0.08)
        var uniforms = WelcomeGlassUniforms(
            size: SIMD2(Float(width), Float(height)),
            origin: SIMD2(Float(frame.origin.x * frame.scale), Float(frame.origin.y * frame.scale)),
            view: SIMD2(Float(frame.view.width * frame.scale), Float(frame.view.height * frame.scale)),
            stroke: sw, softSlope: softSigma * 3.6, sharpSlope: sharpSigma * 3.9,
            softStep: max(1.5, softSigma * 0.45), sharpStep: max(1.2, sharpSigma * 0.6), alpha: Float(frame.alpha))
        encoder.setRenderPipelineState(renderer.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WelcomeGlassUniforms>.stride, index: 0)
        let textures: [MTLTexture?] = [mask, soft, sharp, glow, frame.trail == nil ? empty : trail,
                                       frame.glint == nil ? empty : glint, horizonSoft]
        for (index, texture) in textures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    private func allocate(_ w: Int, _ h: Int) -> Bool {
        width = w
        height = h
        func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, written: Bool) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            descriptor.usage = written ? [.shaderRead, .shaderWrite] : [.shaderRead]
            descriptor.storageMode = written ? .private : .managed
            return renderer.device.makeTexture(descriptor: descriptor)
        }
        mask = texture(.r8Unorm, w, h, written: false)
        trailRaw = texture(.r8Unorm, w, h, written: false)
        glintRaw = texture(.r8Unorm, w, h, written: false)
        soft = texture(.r8Unorm, w, h, written: true)
        sharp = texture(.r8Unorm, w, h, written: true)
        glow = texture(.r8Unorm, w, h, written: true)
        trail = texture(.r8Unorm, w, h, written: true)
        glint = texture(.r8Unorm, w, h, written: true)
        empty = texture(.r8Unorm, 1, 1, written: false)
        if let empty {
            var zero: UInt8 = 0
            empty.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 1)
        }
        maskContext = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        lineContext = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        whole = false
        return mask != nil && soft != nil && sharp != nil && glow != nil && trail != nil && glint != nil
            && maskContext != nil && lineContext != nil && empty != nil
    }

    private func uploadHorizon(_ image: CGImage, sigma: CGFloat, _ buffer: MTLCommandBuffer) -> Bool {
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed
        let blurred = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        blurred.usage = [.shaderRead, .shaderWrite]
        blurred.storageMode = .private
        guard let plain = renderer.device.makeTexture(descriptor: descriptor),
              let soft = renderer.device.makeTexture(descriptor: blurred) else { return false }
        plain.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: context.bytesPerRow)
        blur(plain, into: soft, sigma: sigma, buffer)
        horizon = plain
        horizonSoft = soft
        horizonImage = image
        return true
    }

    // MARK: Drawing

    /// Clears `context`, sets it to the glass's points with y down, and lets `body` draw in white.
    private func draw(into context: CGContext?, _ frame: WelcomeGlassFrame, _ body: (CGContext) -> Void) {
        guard let context else { return }
        context.resetClip()
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: frame.scale, y: -frame.scale)
        context.setFillColor(gray: 1, alpha: 1)
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setShouldAntialias(true)
        body(context)
        context.restoreGState()
    }

    private func stroke(_ path: CGPath, width: CGFloat, in context: CGContext) {
        context.addPath(path)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }

    private func upload(_ context: CGContext?, to texture: MTLTexture) {
        guard let context, let data = context.data else { return }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data,
                        bytesPerRow: context.bytesPerRow)
    }

    private func blur(_ source: MTLTexture, into destination: MTLTexture, sigma: CGFloat, _ buffer: MTLCommandBuffer) {
        let key = Int((sigma * 100).rounded())
        let kernel: MPSImageGaussianBlur
        if let cached = blurs[key] {
            kernel = cached
        } else {
            kernel = MPSImageGaussianBlur(device: renderer.device, sigma: Float(max(sigma, 0.1)))
            blurs[key] = kernel
        }
        kernel.encode(commandBuffer: buffer, sourceTexture: source, destinationTexture: destination)
    }
}

/// The shader's uniforms (`WelcomeUniforms` in the source: float2 is 8 bytes, aligned to 8).
struct WelcomeGlassUniforms {
    var size: SIMD2<Float>
    var origin: SIMD2<Float>
    var view: SIMD2<Float>
    var stroke: Float
    var softSlope: Float
    var sharpSlope: Float
    var softStep: Float
    var sharpStep: Float
    var alpha: Float
}

/// The glass as a layer of its own in the launch screen: a Metal layer the frames are drawn into
/// as SwiftUI's timeline gives them. It takes no clicks (the screen's own do). Its textures go when
/// SwiftUI takes it down — at the end of the opening.
struct WelcomeGlassSurface: NSViewRepresentable {
    let frame: WelcomeGlassFrame
    let renderer: WelcomeGlassRenderer

    func makeNSView(context: Context) -> WelcomeGlassNSView {
        WelcomeGlassNSView(renderer: renderer)
    }

    func updateNSView(_ view: WelcomeGlassNSView, context: Context) {
        view.show(frame)
    }

    static func dismantleNSView(_ view: WelcomeGlassNSView, coordinator: ()) {
        view.tearDown()
    }
}

final class WelcomeGlassNSView: NSView {
    private let canvas: WelcomeGlassCanvas
    private let device: MTLDevice

    init(renderer: WelcomeGlassRenderer) {
        canvas = WelcomeGlassCanvas(renderer: renderer)
        device = renderer.device
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        return layer
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ frame: WelcomeGlassFrame) {
        guard let layer = layer as? CAMetalLayer else { return }
        layer.contentsScale = frame.scale
        layer.drawableSize = CGSize(width: max(1, (frame.size.width * frame.scale).rounded()),
                                    height: max(1, (frame.size.height * frame.scale).rounded()))
        canvas.draw(frame, into: layer)
    }

    func tearDown() {
        canvas.release()
    }
}

/// The glass where Metal is not there: the outline, cut to the pen's way, a breath of cool white
/// with its edges and upper side catching the light. Nothing that needs the GPU.
struct WelcomeFallbackGlass: View {
    let outline: Path
    let revealed: Path?
    let reveal: CGFloat
    let stroke: CGFloat

    var body: some View {
        ZStack {
            outline.fill(Color(.sRGB, red: 0.90, green: 0.94, blue: 1.0, opacity: 0.12))
            outline.stroke(Color.white.opacity(0.42), lineWidth: max(1, stroke * 0.07))
            outline.stroke(Color.white.opacity(0.8), lineWidth: max(1, stroke * 0.1))
                .offset(y: -stroke * 0.12)
                .blur(radius: max(0.5, stroke * 0.03))
                .mask { outline.fill(Color.white) }
        }
        .compositingGroup()
        .mask {
            if let revealed {
                revealed.stroke(Color.white, style: StrokeStyle(lineWidth: reveal, lineCap: .round, lineJoin: .round))
            } else {
                Rectangle()
            }
        }
    }
}
