import Foundation
import Metal
import QuartzCore
import CoreGraphics
import os
import simd

final class StarryMetalRenderer {
    
    // MARK: - Nested Types
    
    private struct LayerTextures {
        var base: MTLTexture?
        var satellites: MTLTexture?
        var satellitesScratch: MTLTexture?
        var shooting: MTLTexture?
        var shootingScratch: MTLTexture?
        var size: CGSize = .zero
    }
    
    // Swift-side copy of Moon uniforms used by MoonVertex/MoonFragment.
    // Memory layout matches Shaders.metal (float2, float2, float4, float4)
    private struct MoonUniformsSwift {
        var viewportSize: SIMD2<Float>   // width,height (points/pixels consistently)
        var centerPx: SIMD2<Float>       // center
        var params0: SIMD4<Float>        // radiusPx, phase, brightB, darkB
        var params1: SIMD4<Float>        // debugShowMask, pad, pad, pad
    }
    
    // Fragment buffer binding indices used by our quad-based fragment shaders
    private enum FragmentBufferIndex {
        static let quadUniforms = 0
    }
    
    // MARK: - Properties
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private weak var metalLayer: CAMetalLayer?
    private let log: OSLog
    
    // Pipelines
    private var compositePipeline: MTLRenderPipelineState!
    private var spriteOverPipeline: MTLRenderPipelineState!      // standard premultiplied alpha ("over")
    private var spriteAdditivePipeline: MTLRenderPipelineState!  // additive for trails
    private var decaySampledPipeline: MTLRenderPipelineState!    // old ping-pong decay (kept for fallback)
    private var decayInPlacePipeline: MTLRenderPipelineState!    // new in-place decay via blendColor
    private var moonPipeline: MTLRenderPipelineState!
    
    private var layerTex = LayerTextures()
    
    // Vertex buffers
    private var quadVertexBuffer: MTLBuffer? // for textured composite + decay fullscreen draws
    // Instanced sprite data (resized per frame)
    private var spriteBuffer: MTLBuffer?
    
    // Moon albedo textures (staging + final)
    private var moonAlbedoTexture: MTLTexture?              // final, private, sampled by fragment
    private var moonAlbedoStagingTexture: MTLTexture?       // shared, CPU-upload source
    private var moonAlbedoNeedsBlit: Bool = false           // if true, schedule blit at next render
    
    // Offscreen composite target for headless preview rendering
    private var offscreenComposite: MTLTexture?
    private var offscreenSize: CGSize = .zero
    
    // Track last valid drawable size we applied (to avoid spamming invalid sizes)
    private var lastAppliedDrawableSize: CGSize = .zero
    
    // Controls visual debug output (no-op now; retained API)
    private var debugOverlayEnabled: Bool = false
    
    // Trail decay control (FPS-agnostic half-lives). Always used; defaults to 0.5s if not set explicitly.
    private var satellitesHalfLifeSeconds: Double = 0.5
    private var shootingHalfLifeSeconds: Double = 0.5
    
    // Track time between frames (onscreen/headless)
    private var lastRenderTime: CFTimeInterval?
    private var lastHeadlessRenderTime: CFTimeInterval?
    
    // Diagnostics
    private var diagnosticsEnabled: Bool = true
    private var diagnosticsEveryNFrames: Int = 30
    private var frameIndex: UInt64 = 0
    // Debug switch: skip drawing satellites sprites (to verify decay is working)
    private var debugSkipSatellitesDraw: Bool = true
    // When true, stamp a small probe into satellites layer on the next frame (used when skipping draw)
    private var debugStampNextFrameSatellites: Bool = false
    
    // MARK: - Init (onscreen)
    
    init?(layer: CAMetalLayer, log: OSLog) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            os_log("Metal unavailable", log: log, type: .fault)
            return nil
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.metalLayer = layer
        self.log = log
        
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        // Allow blit readback if ever needed.
        layer.framebufferOnly = false
        layer.isOpaque = true
        
        do {
            try buildPipelines()
            buildQuad()
        } catch {
            os_log("Failed to build Metal pipelines: %{public}@", log: log, type: .fault, "\(error)")
            return nil
        }
    }
    
    // MARK: - Init (headless/offscreen)
    
    // Headless initializer for preview rendering to CGImage
    init?(log: OSLog) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            os_log("Metal unavailable", log: log, type: .fault)
            return nil
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.metalLayer = nil
        self.log = log
        
        do {
            try buildPipelines()
            buildQuad()
        } catch {
            os_log("Failed to build Metal pipelines (headless): %{public}@", log: log, type: .fault, "\(error)")
            return nil
        }
    }
    
    // MARK: - Setup
    
    private func buildPipelines() throws {
        let library = try makeShaderLibrary()
        // Composite textured quad (with tint uniform)
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "Composite"
            desc.vertexFunction = library.makeFunction(name: "TexturedQuadVertex")
            desc.fragmentFunction = library.makeFunction(name: "TexturedQuadFragmentTinted")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            let blend = desc.colorAttachments[0]
            blend?.isBlendingEnabled = true
            blend?.sourceRGBBlendFactor = .one
            blend?.sourceAlphaBlendFactor = .one
            blend?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            blend?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            blend?.rgbBlendOperation = .add
            blend?.alphaBlendOperation = .add
            compositePipeline = try device.makeRenderPipelineState(descriptor: desc)
        }
        // Sprite instanced pipeline: premultiplied alpha "over" for base sprites
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "SpritesOver"
            desc.vertexFunction = library.makeFunction(name: "SpriteVertex")
            desc.fragmentFunction = library.makeFunction(name: "SpriteFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            let blend = desc.colorAttachments[0]
            blend?.isBlendingEnabled = true
            blend?.sourceRGBBlendFactor = .one
            blend?.sourceAlphaBlendFactor = .one
            blend?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            blend?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            blend?.rgbBlendOperation = .add
            blend?.alphaBlendOperation = .add
            spriteOverPipeline = try device.makeRenderPipelineState(descriptor: desc)
        }
        // Sprite instanced pipeline: additive for trails (works with decay pass)
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "SpritesAdditive"
            desc.vertexFunction = library.makeFunction(name: "SpriteVertex")
            desc.fragmentFunction = library.makeFunction(name: "SpriteFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            let blend = desc.colorAttachments[0]
            blend?.isBlendingEnabled = true
            blend?.sourceRGBBlendFactor = .one
            blend?.sourceAlphaBlendFactor = .one
            blend?.destinationRGBBlendFactor = .one
            blend?.destinationAlphaBlendFactor = .one
            blend?.rgbBlendOperation = .add
            blend?.alphaBlendOperation = .add
            spriteAdditivePipeline = try device.makeRenderPipelineState(descriptor: desc)
        }
        // Decay sampled pipeline: robust pass that samples source texture and multiplies by keep into scratch target.
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "DecaySampled"
            desc.vertexFunction = library.makeFunction(name: "TexturedQuadVertex")
            desc.fragmentFunction = library.makeFunction(name: "DecaySampledFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            // No blending; we write keep * src directly into the scratch target.
            desc.colorAttachments[0].isBlendingEnabled = false
            decaySampledPipeline = try device.makeRenderPipelineState(descriptor: desc)
        }
        // Decay in-place pipeline: draw solid black with blending that scales dst by constant keep.
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "DecayInPlace"
            desc.vertexFunction = library.makeFunction(name: "TexturedQuadVertex")
            desc.fragmentFunction = library.makeFunction(name: "SolidBlackFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            let blend = desc.colorAttachments[0]!
            blend.isBlendingEnabled = true
            // out = src*srcFactor + dst*dstFactor
            // We want: out = dst * keep. So set srcFactor=0, dstFactor=blendColor (keep).
            blend.sourceRGBBlendFactor = .zero
            blend.sourceAlphaBlendFactor = .zero
            blend.destinationRGBBlendFactor = .blendColor
            blend.destinationAlphaBlendFactor = .blendAlpha
            blend.rgbBlendOperation = .add
            blend.alphaBlendOperation = .add
            decayInPlacePipeline = try device.makeRenderPipelineState(descriptor: desc)
        }
        // Moon pipeline
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "Moon"
            desc.vertexFunction = library.makeFunction(name: "MoonVertex")
            desc.fragmentFunction = library.makeFunction(name: "MoonFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            let blend = desc.colorAttachments[0]
            blend?.isBlendingEnabled = true
            blend?.sourceRGBBlendFactor = .one
            blend?.sourceAlphaBlendFactor = .one
            blend?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            blend?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            blend?.rgbBlendOperation = .add
            blend?.alphaBlendOperation = .add
            moonPipeline = try device.makeRenderPipelineState(descriptor: desc)
        }
    }
    
    // Try several ways to load a shader library to avoid "Unable to open mach-O" issues.
    private func makeShaderLibrary() throws -> MTLLibrary {
        // 1) Preferred: .metallib inside our bundle
        let bundle = Bundle(for: StarryMetalRenderer.self)
        if let urls = bundle.urls(forResourcesWithExtension: "metallib", subdirectory: nil) {
            for url in urls {
                do {
                    let lib = try device.makeLibrary(URL: url)
                    os_log("Loaded Metal library from URL: %{public}@", log: log, type: .info, url.lastPathComponent)
                    return lib
                } catch {
                    os_log("Failed to load metallib at %{public}@ : %{public}@", log: log, type: .error, url.path, "\(error)")
                    continue
                }
            }
        }
        // 2) Fallback: Xcode default library in our bundle (default.metallib)
        do {
            let lib = try device.makeDefaultLibrary(bundle: bundle)
            os_log("Loaded default Metal library via bundle", log: log, type: .info)
            return lib
        } catch {
            os_log("makeDefaultLibrary(bundle:) failed: %{public}@", log: log, type: .error, "\(error)")
        }
        // 3) Last resort: process default library (may not exist in plugin context)
        if let lib = device.makeDefaultLibrary() {
            os_log("Loaded process default Metal library", log: log, type: .info)
            return lib
        }
        throw NSError(domain: "StarryMetalRenderer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to load any Metal shader library"])
    }
    
    private func buildQuad() {
        // 6 vertices (two triangles) with position (x,y) and texCoord (u,v)
        struct V { var p: SIMD2<Float>; var t: SIMD2<Float> }
        let verts: [V] = [
            V(p: [-1, -1], t: [0, 1]),
            V(p: [ 1, -1], t: [1, 1]),
            V(p: [-1,  1], t: [0, 0]),
            V(p: [-1,  1], t: [0, 0]),
            V(p: [ 1, -1], t: [1, 1]),
            V(p: [ 1,  1], t: [1, 0])
        ]
        quadVertexBuffer = device.makeBuffer(bytes: verts,
                                             length: MemoryLayout<V>.stride * verts.count,
                                             options: .storageModeShared)
        quadVertexBuffer?.label = "FullScreenQuad"
    }
    
    // MARK: - Public
    
    func updateDrawableSize(size: CGSize, scale: CGFloat) {
        // Validate inputs to avoid CAMetalLayer logs about invalid sizes.
        guard scale > 0 else { return }
        let wPx = Int(round(size.width * scale))
        let hPx = Int(round(size.height * scale))
        // If either dimension is zero or negative, do not touch the layer or textures yet.
        guard wPx > 0, hPx > 0 else { return }
        
        // Apply to CAMetalLayer (only when changed) to avoid repeated log spam.
        if let layer = metalLayer {
            let newDrawable = CGSize(width: CGFloat(wPx), height: CGFloat(hPx))
            if newDrawable != lastAppliedDrawableSize {
                layer.contentsScale = scale
                layer.drawableSize = newDrawable
                lastAppliedDrawableSize = newDrawable
            } else {
                // Still update contentsScale in case only scale changed with same drawable size
                layer.contentsScale = scale
            }
        }
        // Allocate private textures at logical (unscaled) size when changed and valid.
        if size.width >= 1, size.height >= 1, size != layerTex.size {
            allocateTextures(size: size)
            // Immediately clear newly allocated render targets to avoid sampling uninitialized contents.
            clearOffscreenTextures(reason: "Resize/allocate")
            os_log("updateDrawableSize: allocated and cleared layer textures for size %{public}.0fx%{public}.0f",
                   log: log, type: .info, Double(size.width), Double(size.height))
            if metalLayer == nil {
                offscreenComposite = nil
                offscreenSize = .zero
            }
        }
    }
    
    // Allow external toggle of debug overlay visuals (no-op for now)
    func setDebugOverlayEnabled(_ enabled: Bool) {
        debugOverlayEnabled = enabled
    }
    
    // Diagnostics controls
    func setDiagnostics(enabled: Bool, everyNFrames: Int = 60) {
        diagnosticsEnabled = enabled
        diagnosticsEveryNFrames = max(1, everyNFrames)
        os_log("Diagnostics %{public}@", log: log, type: .info, enabled ? "ENABLED" : "disabled")
    }
    // For testing: skip drawing satellites (decay-only) to verify trails actually fade
    func setSkipSatellitesDrawingForDebug(_ skip: Bool) {
        debugSkipSatellitesDraw = skip
        os_log("Debug: skip satellites draw is %{public}@", log: log, type: .info, skip ? "ON" : "off")
    }
    
    // Expose trail half-life controls. Pass nil to reset to default 0.5s.
    func setTrailHalfLives(satellites: Double?, shooting: Double?) {
        satellitesHalfLifeSeconds = satellites ?? 0.5
        shootingHalfLifeSeconds = shooting ?? 0.5
        os_log("Trail half-lives updated: satellites=%{public}.3f s, shooting=%{public}.3f s",
               log: log, type: .info, satellitesHalfLifeSeconds, shootingHalfLifeSeconds)
    }
    
    // Prepare moon albedo textures and stage CPU upload for GPU blit (no blocking on main thread).
    func setMoonAlbedo(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return }
        os_log("setMoonAlbedo: preparing upload via staging+blit (%{public}dx%{public}d)", log: log, type: .info, width, height)
        
        // Create/resize final private texture if needed (R8)
        if moonAlbedoTexture == nil || moonAlbedoTexture!.width != width || moonAlbedoTexture!.height != height {
            let dstDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                                                                   width: width,
                                                                   height: height,
                                                                   mipmapped: false)
            dstDesc.usage = [.shaderRead]
            dstDesc.storageMode = .private
            moonAlbedoTexture = device.makeTexture(descriptor: dstDesc)
            moonAlbedoTexture?.label = "MoonAlbedo (private)"
            if moonAlbedoTexture == nil {
                os_log("setMoonAlbedo: failed to create destination texture", log: log, type: .error)
                return
            }
        }
        
        // Create staging shared texture
        let stagingDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                                                                   width: width,
                                                                   height: height,
                                                                   mipmapped: false)
        stagingDesc.storageMode = .shared
        stagingDesc.usage = [] // no special usage required for blit source
        guard let staging = device.makeTexture(descriptor: stagingDesc) else {
            os_log("setMoonAlbedo: failed to create staging texture", log: log, type: .error)
            return
        }
        staging.label = "MoonAlbedo (staging)"
        
        // Extract raw grayscale bytes from CGImage (convert if needed) into tight R8 buffer
        var bytesPerRow = width
        var uploadBytes: [UInt8]
        if let provider = image.dataProvider, let data = provider.data,
           image.bitsPerPixel == 8,
           image.colorSpace?.model == .monochrome,
           image.bytesPerRow == width {
            uploadBytes = [UInt8]((data as Data))
        } else {
            uploadBytes = [UInt8](repeating: 0, count: width * height)
            let cs = CGColorSpaceCreateDeviceGray()
            if let ctx = CGContext(data: &uploadBytes,
                                   width: width,
                                   height: height,
                                   bitsPerComponent: 8,
                                   bytesPerRow: width,
                                   space: cs,
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            } else {
                os_log("setMoonAlbedo: failed to create grayscale CGContext for conversion", log: log, type: .error)
            }
        }
        // Upload into staging (shared): cheap and non-blocking
        staging.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: uploadBytes,
                        bytesPerRow: bytesPerRow)
        
        // Store staging and mark for blit on next render command buffer
        moonAlbedoStagingTexture = staging
        moonAlbedoNeedsBlit = true
        os_log("setMoonAlbedo: staged bytes; will blit to private on next command buffer", log: log, type: .info)
    }
    
    func render(drawData: StarryDrawData) {
        // Prepare moon albedo textures if an upload is requested
        if let img = drawData.moonAlbedoImage {
            setMoonAlbedo(image: img)
        }
        // Ensure textures (only when logical size valid)
        if drawData.size.width >= 1, drawData.size.height >= 1, drawData.size != layerTex.size {
            allocateTextures(size: drawData.size)
            // Newly allocated: clear all
            clearOffscreenTextures(reason: "Allocate on render()")
        }
        if drawData.clearAll {
            os_log("Render: Clear requested via drawData.clearAll", log: log, type: .info)
            clearOffscreenTextures(reason: "UserClearAll")
        }
        
        // Time since last onscreen render (for FPS-agnostic decay)
        let now = CACurrentMediaTime()
        let dt: CFTimeInterval? = lastRenderTime.map { now - $0 }
        lastRenderTime = now
        
        // Skip work if there's nothing to draw and no decay/clear needed
        let willDecay = ((layerTex.satellites != nil) || (layerTex.shooting != nil)) && (dt ?? 0) > 0
        let nothingToDraw =
            drawData.baseSprites.isEmpty &&
            drawData.satellitesSprites.isEmpty &&
            drawData.shootingSprites.isEmpty &&
            drawData.moon == nil &&
            !willDecay &&
            drawData.clearAll == false
        if nothingToDraw {
            return
        }
        
        if diagnosticsEnabled && frameIndex % UInt64(diagnosticsEveryNFrames) == 0 {
            let satCount = drawData.satellitesSprites.count
            let shootCount = drawData.shootingSprites.count
            let dtSec = (dt ?? 0)
            let keepSat = decayKeep(forHalfLife: satellitesHalfLifeSeconds, dt: dt)
            let keepShoot = decayKeep(forHalfLife: shootingHalfLifeSeconds, dt: dt)
            // Sample up to 3 alpha values from satellites to see if they are 1.0 (suspicious)
            var alphaSamples: [Float] = []
            for i in 0..<min(3, satCount) {
                alphaSamples.append(drawData.satellitesSprites[i].colorPremul.w)
            }
            os_log("Frame #%{public}llu dt=%{public}.4f s | satSprites=%{public}d (alpha samples=%{public}@) keep(sat)=%{public}.4f keep(shoot)=%{public}.4f",
                   log: log, type: .debug,
                   frameIndex, dtSec, satCount, alphaSamples.description, keepSat, keepShoot)
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "Starry Frame CommandBuffer"
        
        // If a moon albedo upload is pending, schedule a GPU blit now (before any draws)
        if moonAlbedoNeedsBlit, let staging = moonAlbedoStagingTexture, let dst = moonAlbedoTexture {
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.label = "Blit MoonAlbedo staging->private"
                let srcOrigin = MTLOrigin(x: 0, y: 0, z: 0)
                let dstOrigin = MTLOrigin(x: 0, y: 0, z: 0)
                let size = MTLSize(width: staging.width, height: staging.height, depth: 1)
                blit.copy(from: staging,
                          sourceSlice: 0,
                          sourceLevel: 0,
                          sourceOrigin: srcOrigin,
                          sourceSize: size,
                          to: dst,
                          destinationSlice: 0,
                          destinationLevel: 0,
                          destinationOrigin: dstOrigin)
                blit.endEncoding()
                os_log("render: enqueued moon albedo GPU blit (%{public}dx%{public}d)", log: log, type: .info, dst.width, dst.height)
            }
            moonAlbedoNeedsBlit = false
            moonAlbedoStagingTexture = nil
        }
        
        // 1) Base layer: render sprites onto persistent base texture (no clear)
        if let baseTex = layerTex.base, !drawData.baseSprites.isEmpty {
            renderSprites(into: baseTex,
                          sprites: drawData.baseSprites,
                          pipeline: spriteOverPipeline,
                          commandBuffer: commandBuffer)
        }
        
        // 2) Satellites trail: decay then draw (additive blending works with decay to create trails)
        if layerTex.satellites != nil {
            applyDecay(into: .satellites, dt: dt, commandBuffer: commandBuffer)
            // If skipping satellites drawing for debug, stamp a probe once after a clear to observe decay.
            if debugSkipSatellitesDraw, debugStampNextFrameSatellites, let dst = layerTex.satellites {
                let sprites = makeDecayProbeSprites(target: dst)
                if !sprites.isEmpty {
                    os_log("Debug: stamping satellites decay probe (%{public}d sprites)", log: log, type: .info, sprites.count)
                    renderSprites(into: dst, sprites: sprites, pipeline: spriteAdditivePipeline, commandBuffer: commandBuffer)
                }
                debugStampNextFrameSatellites = false
            } else if !debugSkipSatellitesDraw,
                      !drawData.satellitesSprites.isEmpty,
                      let dst = layerTex.satellites {
                renderSprites(into: dst,
                              sprites: drawData.satellitesSprites,
                              pipeline: spriteAdditivePipeline,
                              commandBuffer: commandBuffer)
            }
        }
        
        // 3) Shooting stars trail: decay then draw (additive)
        if layerTex.shooting != nil {
            applyDecay(into: .shooting, dt: dt, commandBuffer: commandBuffer)
            if !drawData.shootingSprites.isEmpty, let dst = layerTex.shooting {
                renderSprites(into: dst,
                              sprites: drawData.shootingSprites,
                              pipeline: spriteAdditivePipeline,
                              commandBuffer: commandBuffer)
            }
        }

        // 4) Composite to drawable and draw moon on top
        guard let drawable = metalLayer?.nextDrawable() else {
            os_log("No CAMetalLayer drawable available this frame", log: log, type: .error)
            commandBuffer.commit()
            frameIndex &+= 1
            return
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else {
            commandBuffer.commit()
            frameIndex &+= 1
            return
        }
        encoder.pushDebugGroup("Composite+Moon")
        
        // Set viewport to drawable size
        let dvp = MTLViewport(originX: 0, originY: 0,
                              width: Double(drawable.texture.width),
                              height: Double(drawable.texture.height),
                              znear: 0, zfar: 1)
        encoder.setViewport(dvp)
        
        // Composite base + satellites + shooting (white tint)
        encoder.setRenderPipelineState(compositePipeline)
        if let quad = quadVertexBuffer {
            encoder.setVertexBuffer(quad, offset: 0, index: 0)
        }
        var whiteTint = SIMD4<Float>(1, 1, 1, 1)
        func drawTex(_ tex: MTLTexture?) {
            guard let t = tex else { return }
            encoder.setFragmentTexture(t, index: 0)
            encoder.setFragmentBytes(&whiteTint, length: MemoryLayout<SIMD4<Float>>.stride, index: FragmentBufferIndex.quadUniforms)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        drawTex(layerTex.base)
        drawTex(layerTex.satellites)
        drawTex(layerTex.shooting)
        
        // Moon
        if let moon = drawData.moon {
            encoder.setRenderPipelineState(moonPipeline)
            // Uniforms (match Shaders.metal packing)
            var uni = MoonUniformsSwift(
                viewportSize: SIMD2<Float>(Float(drawData.size.width), Float(drawData.size.height)),
                centerPx: moon.centerPx,
                params0: SIMD4<Float>(moon.radiusPx, moon.phaseFraction, moon.brightBrightness, moon.darkBrightness),
                params1: SIMD4<Float>(drawData.showLightAreaTextureFillMask ? 1.0 : 0.0, 0, 0, 0)
            )
            encoder.setVertexBytes(&uni, length: MemoryLayout<MoonUniformsSwift>.stride, index: 2)
            encoder.setFragmentBytes(&uni, length: MemoryLayout<MoonUniformsSwift>.stride, index: 2)
            if let albedo = moonAlbedoTexture {
                encoder.setFragmentTexture(albedo, index: 0)
            }
            // Draw quad (6 verts) via implicit corners in shader
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        encoder.popDebugGroup()
        encoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
        frameIndex &+= 1
    }
    
    // Headless preview: render same content into an offscreen texture and return CGImage.
    func renderToImage(drawData: StarryDrawData) -> CGImage? {
        // Prepare moon albedo if provided
        if let img = drawData.moonAlbedoImage {
            setMoonAlbedo(image: img)
        }
        
        // Ensure persistent textures only when valid size
        if drawData.size.width >= 1, drawData.size.height >= 1, drawData.size != layerTex.size {
            allocateTextures(size: drawData.size)
            clearOffscreenTextures(reason: "Allocate on renderToImage()")
        }
        if drawData.clearAll {
            os_log("RenderToImage: Clear requested via drawData.clearAll", log: log, type: .info)
            clearOffscreenTextures(reason: "UserClearAll(headless)")
        }
        // Ensure offscreen composite target (shared so CPU can read)
        ensureOffscreenComposite(size: drawData.size)
        guard let finalTarget = offscreenComposite else { return nil }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        commandBuffer.label = "Starry Headless CommandBuffer"
        
        // If a moon albedo upload is pending, schedule a GPU blit now
        if moonAlbedoNeedsBlit, let staging = moonAlbedoStagingTexture, let dst = moonAlbedoTexture {
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.label = "Blit MoonAlbedo staging->private (headless)"
                let srcOrigin = MTLOrigin(x: 0, y: 0, z: 0)
                let dstOrigin = MTLOrigin(x: 0, y: 0, z: 0)
                let size = MTLSize(width: staging.width, height: staging.height, depth: 1)
                blit.copy(from: staging,
                          sourceSlice: 0,
                          sourceLevel: 0,
                          sourceOrigin: srcOrigin,
                          sourceSize: size,
                          to: dst,
                          destinationSlice: 0,
                          destinationLevel: 0,
                          destinationOrigin: dstOrigin)
                blit.endEncoding()
                os_log("renderToImage: enqueued moon albedo GPU blit (%{public}dx%{public}d)", log: log, type: .info, dst.width, dst.height)
            }
            moonAlbedoNeedsBlit = false
            moonAlbedoStagingTexture = nil
        }
        
        // Time since last headless render (for FPS-agnostic decay)
        let now = CACurrentMediaTime()
        let dt: CFTimeInterval? = lastHeadlessRenderTime.map { now - $0 }
        lastHeadlessRenderTime = now
        
        if diagnosticsEnabled && frameIndex % UInt64(diagnosticsEveryNFrames) == 0 {
            let satCount = drawData.satellitesSprites.count
            let shootCount = drawData.shootingSprites.count
            let dtSec = (dt ?? 0)
            let keepSat = decayKeep(forHalfLife: satellitesHalfLifeSeconds, dt: dt)
            let keepShoot = decayKeep(forHalfLife: shootingHalfLifeSeconds, dt: dt)
            var alphaSamples: [Float] = []
            for i in 0..<min(3, satCount) {
                alphaSamples.append(drawData.satellitesSprites[i].colorPremul.w)
            }
            os_log("[Headless] Frame #%{public}llu dt=%{public}.4f s | satSprites=%{public}d (alpha samples=%{public}@) keep(sat)=%{public}.4f keep(shoot)=%{public}.4f",
                   log: log, type: .debug,
                   frameIndex, dtSec, satCount, alphaSamples.description, keepSat, keepShoot)
        }
        
        // 1) Base layer: render sprites onto persistent base texture (no clear)
        if let baseTex = layerTex.base, !drawData.baseSprites.isEmpty {
            renderSprites(into: baseTex,
                          sprites: drawData.baseSprites,
                          pipeline: spriteOverPipeline,
                          commandBuffer: commandBuffer)
        }
        
        // 2) Satellites trail: decay then draw (additive)
        if layerTex.satellites != nil {
            applyDecay(into: .satellites, dt: dt, commandBuffer: commandBuffer)
            // Stamp probe once after clear if skipping satellites draw
            if debugSkipSatellitesDraw, debugStampNextFrameSatellites, let dst = layerTex.satellites {
                let sprites = makeDecayProbeSprites(target: dst)
                if !sprites.isEmpty {
                    os_log("Debug(headless): stamping satellites decay probe (%{public}d sprites)", log: log, type: .info, sprites.count)
                    renderSprites(into: dst, sprites: sprites, pipeline: spriteAdditivePipeline, commandBuffer: commandBuffer)
                }
                debugStampNextFrameSatellites = false
            } else if !debugSkipSatellitesDraw,
                      !drawData.satellitesSprites.isEmpty,
                      let dst = layerTex.satellites {
                renderSprites(into: dst,
                              sprites: drawData.satellitesSprites,
                              pipeline: spriteAdditivePipeline,
                              commandBuffer: commandBuffer)
            }
        }
        
        // 3) Shooting stars trail: decay then draw (additive)
        if layerTex.shooting != nil {
            applyDecay(into: .shooting, dt: dt, commandBuffer: commandBuffer)
            if !drawData.shootingSprites.isEmpty, let dst = layerTex.shooting {
                renderSprites(into: dst,
                              sprites: drawData.shootingSprites,
                              pipeline: spriteAdditivePipeline,
                              commandBuffer: commandBuffer)
            }
        }
        
        // 4) Composite into offscreen target and draw moon
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = finalTarget
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return nil
        }
        encoder.pushDebugGroup("Headless Composite+Moon")
        
        let vp = MTLViewport(originX: 0, originY: 0,
                             width: Double(finalTarget.width),
                             height: Double(finalTarget.height),
                             znear: 0, zfar: 1)
        encoder.setViewport(vp)
        
        encoder.setRenderPipelineState(compositePipeline)
        if let quad = quadVertexBuffer {
            encoder.setVertexBuffer(quad, offset: 0, index: 0)
        }
        var whiteTint = SIMD4<Float>(1, 1, 1, 1)
        func drawTex(_ tex: MTLTexture?) {
            guard let t = tex else { return }
            encoder.setFragmentTexture(t, index: 0)
            encoder.setFragmentBytes(&whiteTint, length: MemoryLayout<SIMD4<Float>>.stride, index: FragmentBufferIndex.quadUniforms)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        drawTex(layerTex.base)
        drawTex(layerTex.satellites)
        drawTex(layerTex.shooting)
        
        // Moon (on top)
        if let moon = drawData.moon {
            encoder.setRenderPipelineState(moonPipeline)
            // Uniforms (match Shaders.metal packing)
            var uni = MoonUniformsSwift(
                viewportSize: SIMD2<Float>(Float(drawData.size.width), Float(drawData.size.height)),
                centerPx: moon.centerPx,
                params0: SIMD4<Float>(moon.radiusPx, moon.phaseFraction, moon.brightBrightness, moon.darkBrightness),
                params1: SIMD4<Float>(drawData.showLightAreaTextureFillMask ? 1.0 : 0.0, 0, 0, 0)
            )
            encoder.setVertexBytes(&uni, length: MemoryLayout<MoonUniformsSwift>.stride, index: 2)
            encoder.setFragmentBytes(&uni, length: MemoryLayout<MoonUniformsSwift>.stride, index: 2)
            if let albedo = moonAlbedoTexture {
                encoder.setFragmentTexture(albedo, index: 0)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        encoder.popDebugGroup()
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // Read back pixels into CPU buffer
        let w = finalTarget.width
        let h = finalTarget.height
        let bpp = 4
        let rowBytes = w * bpp
        var bytes = [UInt8](repeating: 0, count: rowBytes * h)
        let region = MTLRegionMake2D(0, 0, w, h)
        finalTarget.getBytes(&bytes, bytesPerRow: rowBytes, from: region, mipmapLevel: 0)
        
        // Create CGImage (BGRA8 premultiplied first, little-endian)
        let cs = CGColorSpaceCreateDeviceRGB()
        let provider = CGDataProvider(data: NSData(bytes: &bytes, length: bytes.count))!
        let alphaFirst = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(alphaFirst)
        return CGImage(width: w,
                       height: h,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: rowBytes,
                       space: cs,
                       bitmapInfo: bitmapInfo,
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }
    
    // MARK: - Helpers
    
    private func allocateTextures(size: CGSize) {
        layerTex.size = size
        let w = max(1, Int(size.width))
        let h = max(1, Int(size.height))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: w,
                                                            height: h,
                                                            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        layerTex.base = device.makeTexture(descriptor: desc)
        layerTex.base?.label = "BaseLayer"
        layerTex.satellites = device.makeTexture(descriptor: desc)
        layerTex.satellites?.label = "SatellitesLayer"
        layerTex.satellitesScratch = device.makeTexture(descriptor: desc)
        layerTex.satellitesScratch?.label = "SatellitesLayerScratch"
        layerTex.shooting = device.makeTexture(descriptor: desc)
        layerTex.shooting?.label = "ShootingStarsLayer"
        layerTex.shootingScratch = device.makeTexture(descriptor: desc)
        layerTex.shootingScratch?.label = "ShootingStarsLayerScratch"
        
        os_log("Allocated textures: base=%{public}@ sat=%{public}@ satScratch=%{public}@ shoot=%{public}@ shootScratch=%{public}@",
               log: log, type: .info,
               ptrString(layerTex.base!),
               ptrString(layerTex.satellites!),
               ptrString(layerTex.satellitesScratch!),
               ptrString(layerTex.shooting!),
               ptrString(layerTex.shootingScratch!))
    }
    
    private func ensureOffscreenComposite(size: CGSize) {
        if offscreenComposite != nil && offscreenSize == size { return }
        let w = max(1, Int(max(1, size.width)))
        let h = max(1, Int(max(1, size.height)))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: w,
                                                            height: h,
                                                            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        // Shared so CPU can read getBytes
        desc.storageMode = .shared
        offscreenComposite = device.makeTexture(descriptor: desc)
        offscreenComposite?.label = "OffscreenComposite"
        offscreenSize = size
    }
    
    private func clearOffscreenTextures(reason: String = "unspecified") {
        os_log("ClearOffscreenTextures: begin (reason=%{public}@)", log: log, type: .info, reason)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            os_log("ClearOffscreenTextures: failed to make command buffer", log: log, type: .error)
            return
        }
        func clear(texture: MTLTexture?) {
            guard let t = texture else { return }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = t
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                // Set viewport to texture size
                enc.pushDebugGroup("Clear \(t.label ?? "tex")")
                let vp = MTLViewport(originX: 0, originY: 0,
                                     width: Double(t.width), height: Double(t.height),
                                     znear: 0, zfar: 1)
                enc.setViewport(vp)
                enc.popDebugGroup()
                enc.endEncoding()
            }
        }
        clear(texture: layerTex.base)
        clear(texture: layerTex.satellites)
        clear(texture: layerTex.satellitesScratch)
        clear(texture: layerTex.shooting)
        clear(texture: layerTex.shootingScratch)
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        os_log("ClearOffscreenTextures: complete (reason=%{public}@)", log: log, type: .info, reason)
        
        // If we're skipping satellites drawing for debugging, arrange to stamp a probe on next frame.
        if debugSkipSatellitesDraw {
            debugStampNextFrameSatellites = true
            os_log("Debug: will stamp satellites decay probe next frame (after clear)", log: log, type: .info)
        }
    }
    
    private func renderSprites(into target: MTLTexture,
                               sprites: [SpriteInstance],
                               pipeline: MTLRenderPipelineState,
                               commandBuffer: MTLCommandBuffer) {
        guard !sprites.isEmpty else { return }
        // Ensure buffer capacity
        let byteCount = sprites.count * MemoryLayout<SpriteInstance>.stride
        if spriteBuffer == nil || (spriteBuffer!.length < byteCount) {
            spriteBuffer = device.makeBuffer(length: max(byteCount, 1024 * 16), options: .storageModeShared)
            spriteBuffer?.label = "SpriteInstanceBuffer"
        }
        if let buffer = spriteBuffer {
            let contents = buffer.contents()
            sprites.withUnsafeBytes { raw in
                if let src = raw.baseAddress {
                    memcpy(contents, src, min(byteCount, raw.count))
                }
            }
        }
        
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        encoder.pushDebugGroup("RenderSprites -> \(target.label ?? "tex")")
        // Set viewport to target size (in texels)
        let vp = MTLViewport(originX: 0, originY: 0,
                             width: Double(target.width),
                             height: Double(target.height),
                             znear: 0, zfar: 1)
        encoder.setViewport(vp)
        
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(spriteBuffer, offset: 0, index: 1)
        // IMPORTANT: use the actual render target size in TEXELS so SpriteVertex maths
        // matches the units used by SpriteInstance.centerPx/halfSizePx (pixel-like).
        var uni = SpriteUniforms(viewportSize: SIMD2<Float>(Float(target.width), Float(target.height)))
        encoder.setVertexBytes(&uni, length: MemoryLayout<SpriteUniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: sprites.count)
        encoder.popDebugGroup()
        encoder.endEncoding()
    }
    
    private enum TrailLayer {
        case satellites
        case shooting
    }
    
    private func decayKeep(forHalfLife halfLife: Double, dt: CFTimeInterval?) -> Float {
        let dtSec: Double = {
            if let d = dt, d > 0 { return d }
            return 1.0 / 60.0 // conservative nominal frame time
        }()
        return Float(pow(0.5, dtSec / max(halfLife, 1e-6)))
    }
    
    private func applyDecay(into which: TrailLayer,
                            dt: CFTimeInterval?,
                            commandBuffer: MTLCommandBuffer) {
        // Compute per-frame keep based on dt and half-life: keep = 0.5^(dt/halfLife)
        let halfLife: Double = (which == .satellites) ? satellitesHalfLifeSeconds : shootingHalfLifeSeconds
        let keep = decayKeep(forHalfLife: halfLife, dt: dt)
        
        if diagnosticsEnabled && frameIndex % UInt64(diagnosticsEveryNFrames) == 0 {
            os_log("Decay pass for %{public}@ keep=%{public}.4f (halfLife=%{public}.3f s, dt=%{public}.4f s)",
                   log: log, type: .debug,
                   (which == .satellites ? "satellites" : "shooting"),
                   keep, halfLife, (dt ?? 0))
        }
        
        // If keep is effectively zero, clear the target texture for efficiency.
        if keep <= 1e-6 {
            let target: MTLTexture? = (which == .satellites) ? layerTex.satellites : layerTex.shooting
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd),
               let t = target {
                enc.pushDebugGroup("Decay Clear -> \(t.label ?? "tex")")
                let vp = MTLViewport(originX: 0, originY: 0,
                                     width: Double(t.width), height: Double(t.height),
                                     znear: 0, zfar: 1)
                enc.setViewport(vp)
                enc.popDebugGroup()
                enc.endEncoding()
            }
            return
        }
        
        // In-place decay via blending: out = dst * keep (no ping-pong, robust)
        let target: MTLTexture? = (which == .satellites) ? layerTex.satellites : layerTex.shooting
        guard let dst = target else { return }
        
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        encoder.pushDebugGroup("DecayInPlace -> \(dst.label ?? "tex") keep=\(keep)")
        let vp = MTLViewport(originX: 0, originY: 0,
                             width: Double(dst.width),
                             height: Double(dst.height),
                             znear: 0, zfar: 1)
        encoder.setViewport(vp)
        encoder.setRenderPipelineState(decayInPlacePipeline)
        if let quad = quadVertexBuffer {
            encoder.setVertexBuffer(quad, offset: 0, index: 0)
        }
        // Use constant blend color to scale destination by keep
        encoder.setBlendColor(red: Float(Double(keep)), green: Float(Double(keep)), blue: Float(Double(keep)), alpha: Float(Double(keep)))
        // Draw fullscreen (output color is black; blending scales dst by keep)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.popDebugGroup()
        encoder.endEncoding()
    }
    
    private func ptrString(_ t: MTLTexture) -> String {
        let p = Unmanaged.passUnretained(t as AnyObject).toOpaque()
        return String(describing: p)
    }
    
    // MARK: - Debug helpers
    
    // Create a small set of bright circular sprites to act as a decay probe.
    // Stamped into the satellites trail layer when debugSkipSatellitesDraw is true,
    // on the first frame after a clear.
    private func makeDecayProbeSprites(target: MTLTexture) -> [SpriteInstance] {
        let w = target.width
        let h = target.height
        guard w > 0, h > 0 else { return [] }
        
        let cx = Float(w) * 0.5
        let cy = Float(h) * 0.5
        let r: Float = max(2.0, Float(min(w, h)) * 0.01) // ~1% of min dimension, at least 2px radius
        let color = SIMD4<Float>(1, 1, 1, 1) // premultiplied white
        
        // Five dots: center and four compass points at 20% of min dimension
        let d = Float(min(w, h)) * 0.20
        let positions: [SIMD2<Float>] = [
            SIMD2<Float>(cx, cy),
            SIMD2<Float>(cx - d, cy),
            SIMD2<Float>(cx + d, cy),
            SIMD2<Float>(cx, cy - d),
            SIMD2<Float>(cx, cy + d)
        ]
        let half = SIMD2<Float>(r, r)
        let shape: SpriteShape = .circle
        return positions.map { p in
            SpriteInstance(centerPx: p, halfSizePx: half, colorPremul: color, shape: shape)
        }
    }
}
