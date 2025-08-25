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
        var shooting: MTLTexture?
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
    
    // MARK: - Properties
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private weak var metalLayer: CAMetalLayer?
    private let log: OSLog
    
    // Pipelines
    private var compositePipeline: MTLRenderPipelineState!
    private var spritePipeline: MTLRenderPipelineState!
    private var decayPipeline: MTLRenderPipelineState!
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
    
    // Test toggle: skip moon albedo uploads to isolate stalls caused by replaceRegion/driver compression.
    // Re-enable uploads now that we only send albedo when dirty and use staging + GPU blit to private.
    private let testSkipMoonAlbedoUploads: Bool = false
    private var skippedMoonUploadCount: UInt64 = 0
    private var drawableNilLogCount: UInt64 = 0
    
    // Track last debug mask state for rate-limited logging
    private var lastDebugShowMask: Bool = false
    
    // Instrumentation for decay
    private var frameCounter: UInt64 = 0
    private var headlessFrameCounter: UInt64 = 0
    private var decayLogCount: UInt64 = 0
    private let decayLogFirstN: UInt64 = 8
    private let decayLogEveryNFrames: UInt64 = 180
    // Optional: force a visible decay pulse periodically to verify the pass is effective.
    // Set >0 (e.g., 240) to clamp keepFactor to pulse value every N frames for each layer.
    private let debugForceDecayPulseEveryNFrames: UInt64 = 0   // disabled by default
    private let debugDecayPulseKeep: Float = 0.80               // multiply trails by 0.8 on pulse frames
    
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
        layer.framebufferOnly = true
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
        // Composite textured quad
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "Composite"
            desc.vertexFunction = library.makeFunction(name: "TexturedQuadVertex")
            desc.fragmentFunction = library.makeFunction(name: "TexturedQuadFragment")
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
        // Sprite instanced pipeline
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "Sprites"
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
            spritePipeline = try device.makeRenderPipelineState(descriptor: desc)
        }
        // Decay pipeline: robust multiply via src = keepColor, srcFactor = dest, dstFactor = 0
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "Decay"
            desc.vertexFunction = library.makeFunction(name: "TexturedQuadVertex") // fullscreen quad
            desc.fragmentFunction = library.makeFunction(name: "DecayFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            let blend = desc.colorAttachments[0]
            blend?.isBlendingEnabled = true
            // out = src * dst + dst * 0 = keep * dst
            blend?.sourceRGBBlendFactor = .destinationColor
            blend?.sourceAlphaBlendFactor = .destinationAlpha
            blend?.destinationRGBBlendFactor = .zero
            blend?.destinationAlphaBlendFactor = .zero
            blend?.rgbBlendOperation = .add
            blend?.alphaBlendOperation = .add
            decayPipeline = try device.makeRenderPipelineState(descriptor: desc)
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
            clearOffscreenTextures()
            os_log("updateDrawableSize: allocated and cleared layer textures for size %{public}.0fx%{public}.0f",
                   log: log, type: .info, Double(size.width), Double(size.height))
            if metalLayer == nil {
                offscreenComposite = nil
                offscreenSize = .zero
            }
        }
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
        frameCounter &+= 1
        
        // Prepare moon albedo textures if an upload is requested
        if let img = drawData.moonAlbedoImage {
            if testSkipMoonAlbedoUploads {
                skippedMoonUploadCount &+= 1
                if skippedMoonUploadCount <= 5 || (skippedMoonUploadCount % 60 == 0) {
                    os_log("TEST: Skipping moon albedo upload this frame (count=%{public}llu, img=%{public}dx%{public}d)",
                           log: log, type: .info,
                           skippedMoonUploadCount, img.width, img.height)
                }
            } else {
                setMoonAlbedo(image: img)
            }
        }
        // Ensure textures (only when logical size valid)
        if drawData.size.width >= 1, drawData.size.height >= 1, drawData.size != layerTex.size {
            allocateTextures(size: drawData.size)
            // Newly allocated: clear all
            clearOffscreenTextures()
        }
        if drawData.clearAll {
            clearOffscreenTextures()
        }
        
        // Skip expensive work if there's nothing to draw and no decay/clear needed
        let nothingToDraw =
            drawData.baseSprites.isEmpty &&
            drawData.satellitesSprites.isEmpty &&
            drawData.shootingSprites.isEmpty &&
            drawData.moon == nil &&
            drawData.satellitesKeepFactor >= 1.0 &&
            drawData.shootingKeepFactor >= 1.0 &&
            drawData.clearAll == false
        if nothingToDraw {
            return
        }
        
        // Log mask toggle changes
        if drawData.showLightAreaTextureFillMask != lastDebugShowMask {
            lastDebugShowMask = drawData.showLightAreaTextureFillMask
            os_log("Moon debug mask is now %{public}@", log: log, type: .info, lastDebugShowMask ? "ENABLED" : "disabled")
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
                          viewport: drawData.size,
                          commandBuffer: commandBuffer)
        }
        
        // 2) Satellites trail: decay then draw
        if let satTex = layerTex.satellites {
            var keep = drawData.satellitesKeepFactor
            let willApplyDecay = keep < 1.0
            if debugForceDecayPulseEveryNFrames > 0 && (frameCounter % debugForceDecayPulseEveryNFrames == 0) {
                keep = min(keep, debugDecayPulseKeep)
                logDecayDecision(layer: "Satellites", texture: satTex, keep: keep, action: "PULSE")
            } else if willApplyDecay {
                logDecayDecision(layer: "Satellites", texture: satTex, keep: keep, action: keep <= 0 ? "CLEAR" : "MULTIPLY")
            } else {
                logDecayDecision(layer: "Satellites", texture: satTex, keep: keep, action: "SKIP(keep=1)")
            }
            if keep < 1.0 {
                applyDecay(into: satTex,
                           keepFactor: keep,
                           commandBuffer: commandBuffer)
            }
            if !drawData.satellitesSprites.isEmpty {
                renderSprites(into: satTex,
                              sprites: drawData.satellitesSprites,
                              viewport: drawData.size,
                              commandBuffer: commandBuffer)
            }
        }
        
        // 3) Shooting stars trail: decay then draw
        if let shootTex = layerTex.shooting {
            var keep = drawData.shootingKeepFactor
            let willApplyDecay = keep < 1.0
            if debugForceDecayPulseEveryNFrames > 0 && (frameCounter % debugForceDecayPulseEveryNFrames == 0) {
                keep = min(keep, debugDecayPulseKeep)
                logDecayDecision(layer: "Shooting", texture: shootTex, keep: keep, action: "PULSE")
            } else if willApplyDecay {
                logDecayDecision(layer: "Shooting", texture: shootTex, keep: keep, action: keep <= 0 ? "CLEAR" : "MULTIPLY")
            } else {
                logDecayDecision(layer: "Shooting", texture: shootTex, keep: keep, action: "SKIP(keep=1)")
            }
            if keep < 1.0 {
                applyDecay(into: shootTex,
                           keepFactor: keep,
                           commandBuffer: commandBuffer)
            }
            if !drawData.shootingSprites.isEmpty {
                renderSprites(into: shootTex,
                              sprites: drawData.shootingSprites,
                              viewport: drawData.size,
                              commandBuffer: commandBuffer)
            }
        }
        
        // 4) Composite to drawable and draw moon on top
        guard let drawable = metalLayer?.nextDrawable() else {
            drawableNilLogCount &+= 1
            if drawableNilLogCount <= 5 || (drawableNilLogCount % 60 == 0) {
                os_log("No CAMetalLayer drawable available this frame (count=%{public}llu)", log: log, type: .error, drawableNilLogCount)
            }
            commandBuffer.commit()
            return
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else {
            commandBuffer.commit()
            return
        }
        
        // Set viewport to drawable size
        let dvp = MTLViewport(originX: 0, originY: 0,
                              width: Double(drawable.texture.width),
                              height: Double(drawable.texture.height),
                              znear: 0, zfar: 1)
        encoder.setViewport(dvp)
        
        // Composite base, satellites, shooting
        encoder.setRenderPipelineState(compositePipeline)
        if let quad = quadVertexBuffer {
            encoder.setVertexBuffer(quad, offset: 0, index: 0)
        } else {
            os_log("WARN: quadVertexBuffer is nil during composite", log: log, type: .error)
        }
        func drawTex(_ tex: MTLTexture?) {
            guard let t = tex else { return }
            encoder.setFragmentTexture(t, index: 0)
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
        
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    // Headless preview: render same content into an offscreen texture and return CGImage.
    func renderToImage(drawData: StarryDrawData) -> CGImage? {
        headlessFrameCounter &+= 1
        
        // Prepare moon albedo if provided
        if let img = drawData.moonAlbedoImage {
            if testSkipMoonAlbedoUploads {
                skippedMoonUploadCount &+= 1
                if skippedMoonUploadCount <= 5 || (skippedMoonUploadCount % 60 == 0) {
                    os_log("TEST(headless): Skipping moon albedo upload this frame (count=%{public}llu, img=%{public}dx%{public}d)",
                           log: log, type: .info,
                           skippedMoonUploadCount, img.width, img.height)
                }
            } else {
                setMoonAlbedo(image: img)
            }
        }
        
        // Ensure persistent textures only when valid size
        if drawData.size.width >= 1, drawData.size.height >= 1, drawData.size != layerTex.size {
            allocateTextures(size: drawData.size)
            clearOffscreenTextures()
        }
        if drawData.clearAll {
            clearOffscreenTextures()
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
        
        // 1) Base layer: render sprites onto persistent base texture (no clear)
        if let baseTex = layerTex.base, !drawData.baseSprites.isEmpty {
            renderSprites(into: baseTex,
                          sprites: drawData.baseSprites,
                          viewport: drawData.size,
                          commandBuffer: commandBuffer)
        }
        
        // 2) Satellites trail: decay then draw
        if let satTex = layerTex.satellites {
            var keep = drawData.satellitesKeepFactor
            if debugForceDecayPulseEveryNFrames > 0 && (headlessFrameCounter % debugForceDecayPulseEveryNFrames == 0) {
                keep = min(keep, debugDecayPulseKeep)
                logDecayDecision(layer: "Satellites(headless)", texture: satTex, keep: keep, action: "PULSE")
            } else {
                logDecayDecision(layer: "Satellites(headless)", texture: satTex, keep: keep, action: keep < 1.0 ? (keep <= 0 ? "CLEAR" : "MULTIPLY") : "SKIP(keep=1)")
            }
            if keep < 1.0 {
                applyDecay(into: satTex,
                           keepFactor: keep,
                           commandBuffer: commandBuffer)
            }
            if !drawData.satellitesSprites.isEmpty {
                renderSprites(into: satTex,
                              sprites: drawData.satellitesSprites,
                              viewport: drawData.size,
                              commandBuffer: commandBuffer)
            }
        }
        
        // 3) Shooting stars trail: decay then draw
        if let shootTex = layerTex.shooting {
            var keep = drawData.shootingKeepFactor
            if debugForceDecayPulseEveryNFrames > 0 && (headlessFrameCounter % debugForceDecayPulseEveryNFrames == 0) {
                keep = min(keep, debugDecayPulseKeep)
                logDecayDecision(layer: "Shooting(headless)", texture: shootTex, keep: keep, action: "PULSE")
            } else {
                logDecayDecision(layer: "Shooting(headless)", texture: shootTex, keep: keep, action: keep < 1.0 ? (keep <= 0 ? "CLEAR" : "MULTIPLY") : "SKIP(keep=1)")
            }
            if keep < 1.0 {
                applyDecay(into: shootTex,
                           keepFactor: keep,
                           commandBuffer: commandBuffer)
            }
            if !drawData.shootingSprites.isEmpty {
                renderSprites(into: shootTex,
                              sprites: drawData.shootingSprites,
                              viewport: drawData.size,
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
        
        let vp = MTLViewport(originX: 0, originY: 0,
                             width: Double(finalTarget.width),
                             height: Double(finalTarget.height),
                             znear: 0, zfar: 1)
        encoder.setViewport(vp)
        
        // Composite base, satellites, shooting
        encoder.setRenderPipelineState(compositePipeline)
        if let quad = quadVertexBuffer {
            encoder.setVertexBuffer(quad, offset: 0, index: 0)
        } else {
            os_log("WARN(headless): quadVertexBuffer is nil during composite", log: log, type: .error)
        }
        func drawTex(_ tex: MTLTexture?) {
            guard let t = tex else { return }
            encoder.setFragmentTexture(t, index: 0)
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
        layerTex.shooting = device.makeTexture(descriptor: desc)
        layerTex.shooting?.label = "ShootingStarsLayer"
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
    
    private func clearOffscreenTextures() {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        func clear(texture: MTLTexture?) {
            guard let t = texture else { return }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = t
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                // Set viewport to texture size
                let vp = MTLViewport(originX: 0, originY: 0,
                                     width: Double(t.width), height: Double(t.height),
                                     znear: 0, zfar: 1)
                enc.setViewport(vp)
                enc.endEncoding()
            }
        }
        clear(texture: layerTex.base)
        clear(texture: layerTex.satellites)
        clear(texture: layerTex.shooting)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
    
    private func renderSprites(into target: MTLTexture,
                               sprites: [SpriteInstance],
                               viewport: CGSize,
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
        // Set viewport to target size
        let vp = MTLViewport(originX: 0, originY: 0,
                             width: Double(target.width),
                             height: Double(target.height),
                             znear: 0, zfar: 1)
        encoder.setViewport(vp)
        
        encoder.setRenderPipelineState(spritePipeline)
        encoder.setVertexBuffer(spriteBuffer, offset: 0, index: 1)
        var uni = SpriteUniforms(viewportSize: SIMD2<Float>(Float(viewport.width), Float(viewport.height)))
        encoder.setVertexBytes(&uni, length: MemoryLayout<SpriteUniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: sprites.count)
        encoder.endEncoding()
    }
    
    private func applyDecay(into target: MTLTexture,
                            keepFactor: Float,
                            commandBuffer: MTLCommandBuffer) {
        // If keepFactor == 0 -> clear
        if keepFactor <= 0 {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                // Set viewport to texture size
                let vp = MTLViewport(originX: 0, originY: 0,
                                     width: Double(target.width), height: Double(target.height),
                                     znear: 0, zfar: 1)
                enc.setViewport(vp)
                enc.endEncoding()
            }
            return
        }
        
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        // Set viewport to texture size
        let vp = MTLViewport(originX: 0, originY: 0,
                             width: Double(target.width),
                             height: Double(target.height),
                             znear: 0, zfar: 1)
        encoder.setViewport(vp)
        
        encoder.setRenderPipelineState(decayPipeline)
        if let quad = quadVertexBuffer {
            encoder.setVertexBuffer(quad, offset: 0, index: 0)
        } else {
            os_log("WARN: quadVertexBuffer is nil during decay", log: log, type: .error)
        }
        // Pass keep color to fragment; blending uses srcFactor = dest, so out = keep * dest.
        var keepColor = SIMD4<Float>(repeating: keepFactor)
        encoder.setFragmentBytes(&keepColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }
    
    // MARK: - Debug logging
    
    private func logDecayDecision(layer: String, texture: MTLTexture, keep: Float, action: String) {
        // Rate-limit: log first N times and then every M frames thereafter
        let shouldLogEarly = decayLogCount < decayLogFirstN
        let shouldLogPeriodic = ((frameCounter % decayLogEveryNFrames) == 0)
        if !(shouldLogEarly || shouldLogPeriodic) { return }
        decayLogCount &+= 1
        os_log("Decay[%{public}@] frame=%{public}llu tex=%{public}@ size=%{public}dx%{public}d keep=%{public}.3f action=%{public}@",
               log: log, type: .info,
               layer, frameCounter, texture.label ?? "unnamed", texture.width, texture.height, Double(keep), action)
    }
}
