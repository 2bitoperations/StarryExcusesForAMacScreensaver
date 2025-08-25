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
    
    // MARK: - Properties
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private weak var metalLayer: CAMetalLayer?
    private let log: OSLog
    
    // Pipelines
    private var compositePipeline: MTLRenderPipelineState!
    private var spritePipeline: MTLRenderPipelineState!
    private var decayPipeline: MTLRenderPipelineState!          // legacy blend-based (kept for reference; unused)
    private var decaySampledPipeline: MTLRenderPipelineState!   // robust sampled copy: dst = keep * src
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
    
    // Strong visual diagnostics for decay (temporary)
    // 1) Force a visible decay pulse periodically to verify the pass is effective.
    // Set to >0 (e.g., 10) to clamp keepFactor to pulse value every N frames for each layer.
    private let debugForceDecayPulseEveryNFrames: UInt64 = 10    // was 0 (disabled). Use 10 to make decay unmistakable.
    private let debugDecayPulseKeep: Float = 0.85                // multiply trails by 0.85 on pulse frames
    
    // 2) Draw a one-time bright probe dot into each trail layer after a clear/resize.
    // If decay works, this dot will fade away even with no sprites drawn over it.
    private let debugDrawDecayProbe: Bool = true
    private var decayProbeInitializedSat: Bool = false
    private var decayProbeInitializedShoot: Bool = false

    // 3) Readback diagnostics: sample center pixel periodically from each trail texture after decay+emission.
    // Increase to every frame for this investigation.
    private let debugReadbackEveryNFrames: UInt64 = 1
    private var rbBufferSat: MTLBuffer?
    private var rbBufferShoot: MTLBuffer?
    private var rbLogCounter: UInt64 = 0
    // Added readbacks: base layer and final onscreen drawable (center pixel)
    private var rbBufferBase: MTLBuffer?
    private var rbBufferDrawable: MTLBuffer?
    
    // Additional debug: offscreen trails-only composite and readbacks
    private var debugTrailsComposite: MTLTexture?
    private var rbBufferTrailsCenter: MTLBuffer?
    private var rbBufferTrailsROI: MTLBuffer?
    // Use a 64x64 ROI centered; bytesPerRow must be multiple of 256 for texture->buffer blit, so 64*4 = 256 is perfect.
    private let debugROIHSize: Int = 32 // half-size -> ROI width/height = 64

    // Visual diagnostic: present trails-only onscreen once every N frames (0 disables)
    private let debugPresentTrailsOnlyEveryNFrames: UInt64 = 50
    
    // NEW: per-layer tint diagnostic (visually confirms which layer contributes to the composite)
    // base=bluish, satellites=greenish, shooting=reddish
    private let debugTintLayers: Bool = true
    
    // NEW: ROI buffers for each layer and the onscreen drawable
    private var rbBufferBaseROI: MTLBuffer?
    private var rbBufferSatROI: MTLBuffer?
    private var rbBufferShootROI: MTLBuffer?
    private var rbBufferDrawableROI: MTLBuffer?
    
    // NEW: one-shot probe verification buffers (compare base vs trail layer at center pixel)
    private var probeCheckScheduled: Bool = false
    private var rbProbeBase: MTLBuffer?
    private var rbProbeSat: MTLBuffer?
    private var rbProbeShoot: MTLBuffer?
    
    // NEW: phase readbacks around decay for deeper debugging
    private let debugPhaseReadbacks: Bool = true
    private var rbSatPre: MTLBuffer?
    private var rbSatPostDecay: MTLBuffer?
    private var rbSatPostEmit: MTLBuffer?
    private var rbShootPre: MTLBuffer?
    private var rbShootPostDecay: MTLBuffer?
    private var rbShootPostEmit: MTLBuffer?
    private var lastKeepSatUsed: Float = 1.0
    private var lastKeepShootUsed: Float = 1.0
    
    // Track when we explicitly clear, to correlate with logs
    private var lastClearReason: String = "none"
    
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
        // For diagnostics, allow blit readback from the drawable.
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
        // Composite textured quad (tinted for diagnostics)
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "CompositeTinted"
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
        // Decay pipeline (legacy blend-constant approach) — kept for reference; not used now.
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "Decay (blend-constant legacy)"
            desc.vertexFunction = library.makeFunction(name: "TexturedQuadVertex")
            desc.fragmentFunction = library.makeFunction(name: "DecayFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            let blend = desc.colorAttachments[0]
            blend?.isBlendingEnabled = true
            // out = src * dst + dst * 0 = keep * dst (src=keepColor, srcFactor=dst, dstFactor=0)
            blend?.sourceRGBBlendFactor = .destinationColor
            blend?.sourceAlphaBlendFactor = .destinationAlpha
            blend?.destinationRGBBlendFactor = .zero
            blend?.destinationAlphaBlendFactor = .zero
            blend?.rgbBlendOperation = .add
            blend?.alphaBlendOperation = .add
            decayPipeline = try device.makeRenderPipelineState(descriptor: desc)
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
            // Invalidate debug trails composite to force reallocation at new size
            debugTrailsComposite = nil
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
            clearOffscreenTextures(reason: "Allocate on render()")
        }
        if drawData.clearAll {
            os_log("Render: Clear requested via drawData.clearAll (reason=UserClearAll)", log: log, type: .info)
            clearOffscreenTextures(reason: "UserClearAll")
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
        
        // Optional: pre-decay center readbacks (phase diagnostics)
        if shouldReadbackThisFrame() && debugPhaseReadbacks {
            ensurePhaseReadbackBuffers()
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.label = "PhaseReadback-PreDecay"
                if let sat = layerTex.satellites, let buf = rbSatPre {
                    enqueueCenterReadback(blit: blit, texture: sat, buffer: buf)
                }
                if let shoot = layerTex.shooting, let buf = rbShootPre {
                    enqueueCenterReadback(blit: blit, texture: shoot, buffer: buf)
                }
                blit.endEncoding()
            }
        }
        
        // 1) Base layer: render sprites onto persistent base texture (no clear)
        if let baseTex = layerTex.base, !drawData.baseSprites.isEmpty {
            os_log("renderSprites: target=%{public}@ ptr=%{public}@ count=%{public}d",
                   log: log, type: .debug,
                   baseTex.label ?? "Base?", ptrString(baseTex), drawData.baseSprites.count)
            renderSprites(into: baseTex,
                          sprites: drawData.baseSprites,
                          viewport: drawData.size,
                          commandBuffer: commandBuffer)
        }
        
        // 2) Satellites trail: decay then draw (with optional diagnostics)
        if let satTexCurrent = layerTex.satellites {
            var keep = drawData.satellitesKeepFactor
            let willApplyDecay = keep < 1.0
            if debugForceDecayPulseEveryNFrames > 0 && (frameCounter % debugForceDecayPulseEveryNFrames == 0) {
                keep = min(keep, debugDecayPulseKeep)
                logDecayDecision(layer: "Satellites", texture: satTexCurrent, keep: keep, action: "PULSE")
            } else if willApplyDecay {
                logDecayDecision(layer: "Satellites", texture: satTexCurrent, keep: keep, action: keep <= 0 ? "CLEAR" : "DECAY_SAMPLE")
            } else {
                logDecayDecision(layer: "Satellites", texture: satTexCurrent, keep: keep, action: "SKIP(keep=1)")
            }
            lastKeepSatUsed = keep
            if keep < 1.0 {
                os_log("Decay(Sat): src=%{public}@ dst(scratch)=%{public}@ keep=%{public}.3f",
                       log: log, type: .debug,
                       ptrString(layerTex.satellites!), ptrString(layerTex.satellitesScratch!), Double(keep))
                applyDecay(into: .satellites, keepFactor: keep, commandBuffer: commandBuffer)
                if shouldReadbackThisFrame() && debugPhaseReadbacks {
                    if let blit = commandBuffer.makeBlitCommandEncoder() {
                        blit.label = "PhaseReadback-Sat-PostDecay"
                        if let satPost = layerTex.satellites, let buf = rbSatPostDecay {
                            enqueueCenterReadback(blit: blit, texture: satPost, buffer: buf)
                        }
                        blit.endEncoding()
                    }
                }
            } else {
                if shouldReadbackThisFrame() && debugPhaseReadbacks {
                    if let blit = commandBuffer.makeBlitCommandEncoder() {
                        blit.label = "PhaseReadback-Sat-NoDecay"
                        if let satNo = layerTex.satellites, let buf = rbSatPostDecay {
                            enqueueCenterReadback(blit: blit, texture: satNo, buffer: buf)
                        }
                        blit.endEncoding()
                    }
                }
            }
            // Draw a one-time probe dot to test decay (center of screen)
            if debugDrawDecayProbe && !decayProbeInitializedSat, let dst = layerTex.satellites {
                drawDecayProbe(into: dst, viewport: drawData.size, commandBuffer: commandBuffer, label: "SatProbe")
                decayProbeInitializedSat = true
                // Immediately schedule a one-shot base vs satellite center readback to confirm no write into base.
                scheduleProbeCenterReadbacks(commandBuffer: commandBuffer)
            }
            if !drawData.satellitesSprites.isEmpty, let dst = layerTex.satellites {
                os_log("renderSprites: target=%{public}@ ptr=%{public}@ count=%{public}d",
                       log: log, type: .debug,
                       dst.label ?? "Satellites?", ptrString(dst), drawData.satellitesSprites.count)
                renderSprites(into: dst,
                              sprites: drawData.satellitesSprites,
                              viewport: drawData.size,
                              commandBuffer: commandBuffer)
                if shouldReadbackThisFrame() && debugPhaseReadbacks {
                    if let blit = commandBuffer.makeBlitCommandEncoder() {
                        blit.label = "PhaseReadback-Sat-PostEmit"
                        if let satPostEmit = layerTex.satellites, let buf = rbSatPostEmit {
                            enqueueCenterReadback(blit: blit, texture: satPostEmit, buffer: buf)
                        }
                        blit.endEncoding()
                    }
                }
            } else {
                if shouldReadbackThisFrame() && debugPhaseReadbacks {
                    // Still capture postEmit (same as postDecay when no emission)
                    if let blit = commandBuffer.makeBlitCommandEncoder() {
                        blit.label = "PhaseReadback-Sat-PostEmit(NoSprites)"
                        if let satPostEmit = layerTex.satellites, let buf = rbSatPostEmit {
                            enqueueCenterReadback(blit: blit, texture: satPostEmit, buffer: buf)
                        }
                        blit.endEncoding()
                    }
                }
            }
        }
        
        // 3) Shooting stars trail: decay then draw (with optional diagnostics)
        if let shootTexCurrent = layerTex.shooting {
            var keep = drawData.shootingKeepFactor
            let willApplyDecay = keep < 1.0
            if debugForceDecayPulseEveryNFrames > 0 && (frameCounter % debugForceDecayPulseEveryNFrames == 0) {
                keep = min(keep, debugDecayPulseKeep)
                logDecayDecision(layer: "Shooting", texture: shootTexCurrent, keep: keep, action: "PULSE")
            } else if willApplyDecay {
                logDecayDecision(layer: "Shooting", texture: shootTexCurrent, keep: keep, action: keep <= 0 ? "CLEAR" : "DECAY_SAMPLE")
            } else {
                logDecayDecision(layer: "Shooting", texture: shootTexCurrent, keep: keep, action: "SKIP(keep=1)")
            }
            lastKeepShootUsed = keep
            if keep < 1.0 {
                os_log("Decay(Shoot): src=%{public}@ dst(scratch)=%{public}@ keep=%{public}.3f",
                       log: log, type: .debug,
                       ptrString(layerTex.shooting!), ptrString(layerTex.shootingScratch!), Double(keep))
                applyDecay(into: .shooting, keepFactor: keep, commandBuffer: commandBuffer)
                if shouldReadbackThisFrame() && debugPhaseReadbacks {
                    if let blit = commandBuffer.makeBlitCommandEncoder() {
                        blit.label = "PhaseReadback-Shoot-PostDecay"
                        if let shPost = layerTex.shooting, let buf = rbShootPostDecay {
                            enqueueCenterReadback(blit: blit, texture: shPost, buffer: buf)
                        }
                        blit.endEncoding()
                    }
                }
            } else {
                if shouldReadbackThisFrame() && debugPhaseReadbacks {
                    if let blit = commandBuffer.makeBlitCommandEncoder() {
                        blit.label = "PhaseReadback-Shoot-NoDecay"
                        if let shNo = layerTex.shooting, let buf = rbShootPostDecay {
                            enqueueCenterReadback(blit: blit, texture: shNo, buffer: buf)
                        }
                        blit.endEncoding()
                    }
                }
            }
            // One-time probe dot
            if debugDrawDecayProbe && !decayProbeInitializedShoot, let dst = layerTex.shooting {
                drawDecayProbe(into: dst, viewport: drawData.size, commandBuffer: commandBuffer, label: "ShootProbe")
                decayProbeInitializedShoot = true
                scheduleProbeCenterReadbacks(commandBuffer: commandBuffer)
            }
            if !drawData.shootingSprites.isEmpty, let dst = layerTex.shooting {
                os_log("renderSprites: target=%{public}@ ptr=%{public}@ count=%{public}d",
                       log: log, type: .debug,
                       dst.label ?? "Shooting?", ptrString(dst), drawData.shootingSprites.count)
                renderSprites(into: dst,
                              sprites: drawData.shootingSprites,
                              viewport: drawData.size,
                              commandBuffer: commandBuffer)
                if shouldReadbackThisFrame() && debugPhaseReadbacks {
                    if let blit = commandBuffer.makeBlitCommandEncoder() {
                        blit.label = "PhaseReadback-Shoot-PostEmit"
                        if let shPostEmit = layerTex.shooting, let buf = rbShootPostEmit {
                            enqueueCenterReadback(blit: blit, texture: shPostEmit, buffer: buf)
                        }
                        blit.endEncoding()
                    }
                }
            } else {
                if shouldReadbackThisFrame() && debugPhaseReadbacks {
                    if let blit = commandBuffer.makeBlitCommandEncoder() {
                        blit.label = "PhaseReadback-Shoot-PostEmit(NoSprites)"
                        if let shPostEmit = layerTex.shooting, let buf = rbShootPostEmit {
                            enqueueCenterReadback(blit: blit, texture: shPostEmit, buffer: buf)
                        }
                        blit.endEncoding()
                    }
                }
            }
        }

        // 3.5) Readback diagnostics: sample center pixel and 64x64 ROI from each layer post-decay+emission
        if shouldReadbackThisFrame() {
            ensureReadbackBuffers()
            ensureDebugTrailsComposite(size: drawData.size)
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.label = "LayerCentersAndROIsReadback"
                if let base = layerTex.base, let bufC = rbBufferBase, let bufROI = rbBufferBaseROI {
                    enqueueCenterReadback(blit: blit, texture: base, buffer: bufC)
                    enqueueROIReadback(blit: blit, texture: base, halfSize: debugROIHSize, buffer: bufROI)
                }
                if let sat = layerTex.satellites, let bufC = rbBufferSat, let bufROI = rbBufferSatROI {
                    enqueueCenterReadback(blit: blit, texture: sat, buffer: bufC)
                    enqueueROIReadback(blit: blit, texture: sat, halfSize: debugROIHSize, buffer: bufROI)
                }
                if let shoot = layerTex.shooting, let bufC = rbBufferShoot, let bufROI = rbBufferShootROI {
                    enqueueCenterReadback(blit: blit, texture: shoot, buffer: bufC)
                    enqueueROIReadback(blit: blit, texture: shoot, halfSize: debugROIHSize, buffer: bufROI)
                }
                blit.endEncoding()
            }
            // Trails-only composite into debug texture
            if let debugTex = debugTrailsComposite {
                compositeTrailsOnly(into: debugTex, viewport: drawData.size, commandBuffer: commandBuffer)
                // Readback center pixel and a 64x64 ROI around center from the trails-only debug composite.
                if let blit2 = commandBuffer.makeBlitCommandEncoder() {
                    blit2.label = "TrailsOnlyReadbacks"
                    if let cbuf = rbBufferTrailsCenter {
                        enqueueCenterReadback(blit: blit2, texture: debugTex, buffer: cbuf)
                    }
                    if let robuf = rbBufferTrailsROI {
                        enqueueROIReadback(blit: blit2, texture: debugTex, halfSize: debugROIHSize, buffer: robuf)
                    }
                    blit2.endEncoding()
                    os_log("Debug: enqueued trails-only composite and readbacks", log: log, type: .info)
                } else {
                    os_log("Debug: failed to create blit encoder for trails-only readbacks", log: log, type: .error)
                }
            } else {
                os_log("Debug: debugTrailsComposite is nil — trails-only readback skipped", log: log, type: .error)
            }
            // We'll enqueue the drawable readback after composite encoding, below.
            commandBuffer.addCompletedHandler { [weak self] _ in
                self?.logReadbackValues()
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
        encoder.pushDebugGroup("Composite+Moon")
        
        // Set viewport to drawable size
        let dvp = MTLViewport(originX: 0, originY: 0,
                              width: Double(drawable.texture.width),
                              height: Double(drawable.texture.height),
                              znear: 0, zfar: 1)
        encoder.setViewport(dvp)
        
        // Decide if this frame should present trails-only onscreen (visual diagnostic)
        let presentTrailsOnlyThisFrame = (debugPresentTrailsOnlyEveryNFrames > 0) && ((frameCounter % (debugPresentTrailsOnlyEveryNFrames * 2)) <= debugReadbackEveryNFrames)
        if presentTrailsOnlyThisFrame {
            os_log("Debug: presenting trails-only this frame", log: log, type: .info)
        }
        
        // Log a concise summary each readback interval (and at first few frames)
        if (frameCounter < 5) || shouldReadbackThisFrame() {
            os_log("Frame #%{public}llu summary: baseSprites=%{public}d satSprites=%{public}d shootSprites=%{public}d keep(sat)=%.3f keep(shoot)=%.3f presentTrailsOnly=%{public}@ clearReason=%{public}@",
                   log: log, type: .info,
                   frameCounter, drawData.baseSprites.count, drawData.satellitesSprites.count, drawData.shootingSprites.count,
                   Double(drawData.satellitesKeepFactor), Double(drawData.shootingKeepFactor),
                   presentTrailsOnlyThisFrame ? "YES" : "no", lastClearReason)
        }
        
        // Composite with per-layer tint
        encoder.setRenderPipelineState(compositePipeline)
        if let quad = quadVertexBuffer {
            encoder.setVertexBuffer(quad, offset: 0, index: 0)
        } else {
            os_log("WARN: quadVertexBuffer is nil during composite", log: log, type: .error)
        }
        func tint(_ r: Float, _ g: Float, _ b: Float) -> SIMD4<Float> {
            return debugTintLayers ? SIMD4<Float>(r, g, b, 1.0) : SIMD4<Float>(1, 1, 1, 1)
        }
        func drawTex(_ tex: MTLTexture?, tintColor: SIMD4<Float>) {
            guard let t = tex else { return }
            var color = tintColor
            encoder.setFragmentTexture(t, index: 0)
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        if presentTrailsOnlyThisFrame {
            // Trails-only: omit base; draw satellites + shooting
            drawTex(layerTex.satellites, tintColor: tint(0.6, 1.0, 0.6)) // greenish
            drawTex(layerTex.shooting, tintColor: tint(1.0, 0.5, 0.5))   // reddish
        } else {
            // Normal: base + satellites + shooting
            drawTex(layerTex.base, tintColor: tint(0.7, 0.9, 1.0))       // bluish
            drawTex(layerTex.satellites, tintColor: tint(0.6, 1.0, 0.6)) // greenish
            drawTex(layerTex.shooting, tintColor: tint(1.0, 0.5, 0.5))   // reddish
        }
        
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
        
        // 4.5) Read back the center pixel and ROI of the onscreen drawable after composite (for comparison)
        if shouldReadbackThisFrame() {
            ensureReadbackBuffers()
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.label = "DrawableCenterAndROIReadback"
                if let buf = rbBufferDrawable {
                    enqueueCenterReadback(blit: blit, texture: drawable.texture, buffer: buf)
                }
                if let bufROI = rbBufferDrawableROI {
                    enqueueROIReadback(blit: blit, texture: drawable.texture, halfSize: debugROIHSize, buffer: bufROI)
                }
                blit.endEncoding()
            }
        }
        
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
            clearOffscreenTextures(reason: "Allocate on renderToImage()")
        }
        if drawData.clearAll {
            os_log("RenderToImage: Clear requested via drawData.clearAll (reason=UserClearAll)", log: log, type: .info)
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
        
        // 1) Base layer: render sprites onto persistent base texture (no clear)
        if let baseTex = layerTex.base, !drawData.baseSprites.isEmpty {
            os_log("renderSprites(headless): target=%{public}@ ptr=%{public}@ count=%{public}d",
                   log: log, type: .debug,
                   baseTex.label ?? "Base?", ptrString(baseTex), drawData.baseSprites.count)
            renderSprites(into: baseTex,
                          sprites: drawData.baseSprites,
                          viewport: drawData.size,
                          commandBuffer: commandBuffer)
        }
        
        // 2) Satellites trail: decay then draw (with optional diagnostics)
        if let _ = layerTex.satellites {
            var keep = drawData.satellitesKeepFactor
            if debugForceDecayPulseEveryNFrames > 0 && (headlessFrameCounter % debugForceDecayPulseEveryNFrames == 0) {
                keep = min(keep, debugDecayPulseKeep)
                logDecayDecision(layer: "Satellites(headless)", texture: layerTex.satellites!, keep: keep, action: "PULSE")
            } else {
                logDecayDecision(layer: "Satellites(headless)", texture: layerTex.satellites!, keep: keep, action: keep < 1.0 ? (keep <= 0 ? "CLEAR" : "DECAY_SAMPLE") : "SKIP(keep=1)")
            }
            if keep < 1.0 {
                applyDecay(into: .satellites, keepFactor: keep, commandBuffer: commandBuffer)
            }
            if debugDrawDecayProbe && !decayProbeInitializedSat, let dst = layerTex.satellites {
                drawDecayProbe(into: dst, viewport: drawData.size, commandBuffer: commandBuffer, label: "SatProbe(headless)")
                decayProbeInitializedSat = true
                scheduleProbeCenterReadbacks(commandBuffer: commandBuffer)
            }
            if !drawData.satellitesSprites.isEmpty, let dst = layerTex.satellites {
                os_log("renderSprites(headless): target=%{public}@ ptr=%{public}@ count=%{public}d",
                       log: log, type: .debug,
                       dst.label ?? "Satellites?", ptrString(dst), drawData.satellitesSprites.count)
                renderSprites(into: dst,
                              sprites: drawData.satellitesSprites,
                              viewport: drawData.size,
                              commandBuffer: commandBuffer)
            }
        }
        
        // 3) Shooting stars trail: decay then draw (with optional diagnostics)
        if let _ = layerTex.shooting {
            var keep = drawData.shootingKeepFactor
            if debugForceDecayPulseEveryNFrames > 0 && (headlessFrameCounter % debugForceDecayPulseEveryNFrames == 0) {
                keep = min(keep, debugDecayPulseKeep)
                logDecayDecision(layer: "Shooting(headless)", texture: layerTex.shooting!, keep: keep, action: "PULSE")
            } else {
                logDecayDecision(layer: "Shooting(headless)", texture: layerTex.shooting!, keep: keep, action: keep < 1.0 ? (keep <= 0 ? "CLEAR" : "DECAY_SAMPLE") : "SKIP(keep=1)")
            }
            if keep < 1.0 {
                applyDecay(into: .shooting, keepFactor: keep, commandBuffer: commandBuffer)
            }
            if debugDrawDecayProbe && !decayProbeInitializedShoot, let dst = layerTex.shooting {
                drawDecayProbe(into: dst, viewport: drawData.size, commandBuffer: commandBuffer, label: "ShootProbe(headless)")
                decayProbeInitializedShoot = true
                scheduleProbeCenterReadbacks(commandBuffer: commandBuffer)
            }
            if !drawData.shootingSprites.isEmpty, let dst = layerTex.shooting {
                os_log("renderSprites(headless): target=%{public}@ ptr=%{public}@ count=%{public}d",
                       log: log, type: .debug,
                       dst.label ?? "Shooting?", ptrString(dst), drawData.shootingSprites.count)
                renderSprites(into: dst,
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
        encoder.pushDebugGroup("Headless Composite+Moon")
        
        let vp = MTLViewport(originX: 0, originY: 0,
                             width: Double(finalTarget.width),
                             height: Double(finalTarget.height),
                             znear: 0, zfar: 1)
        encoder.setViewport(vp)
        
        // Composite base, satellites, shooting with per-layer tint
        encoder.setRenderPipelineState(compositePipeline)
        if let quad = quadVertexBuffer {
            encoder.setVertexBuffer(quad, offset: 0, index: 0)
        } else {
            os_log("WARN(headless): quadVertexBuffer is nil during composite", log: log, type: .error)
        }
        func tint(_ r: Float, _ g: Float, _ b: Float) -> SIMD4<Float> {
            return debugTintLayers ? SIMD4<Float>(r, g, b, 1.0) : SIMD4<Float>(1, 1, 1, 1)
        }
        func drawTex(_ tex: MTLTexture?, tintColor: SIMD4<Float>) {
            guard let t = tex else { return }
            var color = tintColor
            encoder.setFragmentTexture(t, index: 0)
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        drawTex(layerTex.base, tintColor: tint(0.7, 0.9, 1.0))       // bluish
        drawTex(layerTex.satellites, tintColor: tint(0.6, 1.0, 0.6)) // greenish
        drawTex(layerTex.shooting, tintColor: tint(1.0, 0.5, 0.5))   // reddish
        
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
        
        // Log texture identity (addresses) to confirm distinct allocations
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
    
    private func ensureDebugTrailsComposite(size: CGSize) {
        if debugTrailsComposite != nil { return }
        let w = max(1, Int(max(1, size.width)))
        let h = max(1, Int(max(1, size.height)))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: w,
                                                            height: h,
                                                            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        debugTrailsComposite = device.makeTexture(descriptor: desc)
        debugTrailsComposite?.label = "DebugTrailsComposite"
    }
    
    private func clearOffscreenTextures(reason: String = "unspecified") {
        lastClearReason = reason
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
        
        // Reset probe flags after full clear
        decayProbeInitializedSat = false
        decayProbeInitializedShoot = false
        probeCheckScheduled = false
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
        encoder.pushDebugGroup("RenderSprites -> \(target.label ?? "tex")")
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
        encoder.popDebugGroup()
        encoder.endEncoding()
    }
    
    private enum TrailLayer {
        case satellites
        case shooting
    }
    
    private func applyDecay(into which: TrailLayer,
                            keepFactor: Float,
                            commandBuffer: MTLCommandBuffer) {
        // If keepFactor == 0 -> clear the current target texture
        if keepFactor <= 0 {
            let target: MTLTexture? = (which == .satellites) ? layerTex.satellites : layerTex.shooting
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd),
               let t = target {
                enc.pushDebugGroup("Decay Clear -> \(t.label ?? "tex")")
                // Set viewport to texture size
                let vp = MTLViewport(originX: 0, originY: 0,
                                     width: Double(t.width), height: Double(t.height),
                                     znear: 0, zfar: 1)
                enc.setViewport(vp)
                enc.popDebugGroup()
                enc.endEncoding()
            }
            return
        }
        
        // Sample-based decay: render keep * src into the scratch texture, then swap.
        guard let src = (which == .satellites) ? layerTex.satellites : layerTex.shooting else { return }
        guard let dst = (which == .satellites) ? layerTex.satellitesScratch : layerTex.shootingScratch else { return }
        
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        encoder.pushDebugGroup("DecaySampled src=\(src.label ?? "src") -> dst=\(dst.label ?? "dst")")
        // Set viewport to target size
        let vp = MTLViewport(originX: 0, originY: 0,
                             width: Double(dst.width),
                             height: Double(dst.height),
                             znear: 0, zfar: 1)
        encoder.setViewport(vp)
        
        encoder.setRenderPipelineState(decaySampledPipeline)
        if let quad = quadVertexBuffer {
            encoder.setVertexBuffer(quad, offset: 0, index: 0)
        } else {
            os_log("WARN: quadVertexBuffer is nil during decay-sampled", log: log, type: .error)
        }
        var keepColor = SIMD4<Float>(repeating: keepFactor)
        encoder.setFragmentTexture(src, index: 0)
        encoder.setFragmentBytes(&keepColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.popDebugGroup()
        encoder.endEncoding()
        
        // Swap textures so that the decayed result becomes the new current layer.
        if which == .satellites {
            let tmp = layerTex.satellites
            layerTex.satellites = layerTex.satellitesScratch
            layerTex.satellitesScratch = tmp
        } else {
            let tmp = layerTex.shooting
            layerTex.shooting = layerTex.shootingScratch
            layerTex.shootingScratch = tmp
        }
        os_log("Decay swap(%{public}@): now current=%{public}@ scratch=%{public}@",
               log: log, type: .debug,
               which == .satellites ? "Sat" : "Shoot",
               ptrString((which == .satellites) ? layerTex.satellites! : layerTex.shooting!),
               ptrString((which == .satellites) ? layerTex.satellitesScratch! : layerTex.shootingScratch!))
    }
    
    // Draw a small bright probe dot once; if decay works, this dot will fade over time.
    private func drawDecayProbe(into target: MTLTexture,
                                viewport: CGSize,
                                commandBuffer: MTLCommandBuffer,
                                label: String) {
        let cx = Float(viewport.width * 0.5)
        let cy = Float(viewport.height * 0.5)
        let half: Float = 2.0 // 4x4 px
        let colorPremul = SIMD4<Float>(1.0, 1.0, 1.0, 1.0) // opaque white
        var sprites: [SpriteInstance] = []
        sprites.append(SpriteInstance(centerPx: SIMD2<Float>(cx, cy),
                                      halfSizePx: SIMD2<Float>(half, half),
                                      colorPremul: colorPremul,
                                      shape: .rect))
        renderSprites(into: target, sprites: sprites, viewport: viewport, commandBuffer: commandBuffer)
        os_log("DecayProbe: drew one-time probe dot into %{public}@ at (%{public}.0f,%{public}.0f) on tex=%{public}@ ptr=%{public}@",
               log: log, type: .info, label, Double(cx), Double(cy), target.label ?? "unnamed", ptrString(target))
    }
    
    // MARK: - Readback diagnostics
    
    private func shouldReadbackThisFrame() -> Bool {
        return debugReadbackEveryNFrames > 0 && (frameCounter % debugReadbackEveryNFrames == 0)
    }
    
    private func ensureReadbackBuffers() {
        let len = 256 // bytesPerRow alignment requirement for texture->buffer blits
        if rbBufferSat == nil { rbBufferSat = device.makeBuffer(length: len, options: .storageModeShared) }
        if rbBufferShoot == nil { rbBufferShoot = device.makeBuffer(length: len, options: .storageModeShared) }
        if rbBufferBase == nil { rbBufferBase = device.makeBuffer(length: len, options: .storageModeShared) }
        if rbBufferDrawable == nil { rbBufferDrawable = device.makeBuffer(length: len, options: .storageModeShared) }
        if rbBufferTrailsCenter == nil { rbBufferTrailsCenter = device.makeBuffer(length: len, options: .storageModeShared) }
        // ROI buffer for 64x64 pixels with bytesPerRow=256
        let roiBytesPerRow = 256
        let roiHeight = 64
        let roiLen = roiBytesPerRow * roiHeight
        if rbBufferTrailsROI == nil || rbBufferTrailsROI!.length < roiLen {
            rbBufferTrailsROI = device.makeBuffer(length: roiLen, options: .storageModeShared)
        }
        if rbBufferBaseROI == nil || rbBufferBaseROI!.length < roiLen {
            rbBufferBaseROI = device.makeBuffer(length: roiLen, options: .storageModeShared)
        }
        if rbBufferSatROI == nil || rbBufferSatROI!.length < roiLen {
            rbBufferSatROI = device.makeBuffer(length: roiLen, options: .storageModeShared)
        }
        if rbBufferShootROI == nil || rbBufferShootROI!.length < roiLen {
            rbBufferShootROI = device.makeBuffer(length: roiLen, options: .storageModeShared)
        }
        if rbBufferDrawableROI == nil || rbBufferDrawableROI!.length < roiLen {
            rbBufferDrawableROI = device.makeBuffer(length: roiLen, options: .storageModeShared)
        }
        rbBufferSat?.label = "RB_Sat_Center"
        rbBufferShoot?.label = "RB_Shoot_Center"
        rbBufferBase?.label = "RB_Base_Center"
        rbBufferDrawable?.label = "RB_Drawable_Center"
        rbBufferTrailsCenter?.label = "RB_TrailsOnly_Center"
        rbBufferTrailsROI?.label = "RB_TrailsOnly_ROI64"
        rbBufferBaseROI?.label = "RB_Base_ROI64"
        rbBufferSatROI?.label = "RB_Sat_ROI64"
        rbBufferShootROI?.label = "RB_Shoot_ROI64"
        rbBufferDrawableROI?.label = "RB_Drawable_ROI64"
        
        // Probe buffers (single pixels)
        if rbProbeBase == nil { rbProbeBase = device.makeBuffer(length: len, options: .storageModeShared) }
        if rbProbeSat == nil { rbProbeSat = device.makeBuffer(length: len, options: .storageModeShared) }
        if rbProbeShoot == nil { rbProbeShoot = device.makeBuffer(length: len, options: .storageModeShared) }
        rbProbeBase?.label = "RB_Probe_Base_Center"
        rbProbeSat?.label = "RB_Probe_Sat_Center"
        rbProbeShoot?.label = "RB_Probe_Shoot_Center"
    }
    
    private func ensurePhaseReadbackBuffers() {
        let len = 256
        if rbSatPre == nil { rbSatPre = device.makeBuffer(length: len, options: .storageModeShared) }
        if rbSatPostDecay == nil { rbSatPostDecay = device.makeBuffer(length: len, options: .storageModeShared) }
        if rbSatPostEmit == nil { rbSatPostEmit = device.makeBuffer(length: len, options: .storageModeShared) }
        if rbShootPre == nil { rbShootPre = device.makeBuffer(length: len, options: .storageModeShared) }
        if rbShootPostDecay == nil { rbShootPostDecay = device.makeBuffer(length: len, options: .storageModeShared) }
        if rbShootPostEmit == nil { rbShootPostEmit = device.makeBuffer(length: len, options: .storageModeShared) }
        rbSatPre?.label = "RB_Sat_PreDecay"
        rbSatPostDecay?.label = "RB_Sat_PostDecay"
        rbSatPostEmit?.label = "RB_Sat_PostEmit"
        rbShootPre?.label = "RB_Shoot_PreDecay"
        rbShootPostDecay?.label = "RB_Shoot_PostDecay"
        rbShootPostEmit?.label = "RB_Shoot_PostEmit"
    }
    
    private func enqueueCenterReadback(blit: MTLBlitCommandEncoder, texture: MTLTexture, buffer: MTLBuffer) {
        let x = texture.width / 2
        let y = texture.height / 2
        let region = MTLRegionMake2D(x, y, 1, 1)
        blit.copy(from: texture,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: region.origin,
                  sourceSize: region.size,
                  to: buffer,
                  destinationOffset: 0,
                  destinationBytesPerRow: 256,
                  destinationBytesPerImage: 256)
    }
    
    private func enqueueROIReadback(blit: MTLBlitCommandEncoder, texture: MTLTexture, halfSize: Int, buffer: MTLBuffer) {
        let cx = texture.width / 2
        let cy = texture.height / 2
        let width = min(halfSize * 2, texture.width)
        let height = min(halfSize * 2, texture.height)
        let originX = max(0, cx - halfSize)
        let originY = max(0, cy - halfSize)
        let region = MTLRegionMake2D(originX, originY, width, height)
        // bytesPerRow must be >= width*4 and multiple of 256; we chose width=64 so width*4=256.
        blit.copy(from: texture,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: region.origin,
                  sourceSize: region.size,
                  to: buffer,
                  destinationOffset: 0,
                  destinationBytesPerRow: 256,
                  destinationBytesPerImage: 256 * height)
    }
    
    private func compositeTrailsOnly(into target: MTLTexture, viewport: CGSize, commandBuffer: MTLCommandBuffer) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        encoder.pushDebugGroup("CompositeTrailsOnly")
        let vp = MTLViewport(originX: 0, originY: 0,
                             width: Double(target.width),
                             height: Double(target.height),
                             znear: 0, zfar: 1)
        encoder.setViewport(vp)
        encoder.setRenderPipelineState(compositePipeline)
        if let quad = quadVertexBuffer {
            encoder.setVertexBuffer(quad, offset: 0, index: 0)
        }
        // Draw satellites + shooting only (omit base)
        func setTintAndDraw(_ tex: MTLTexture?, r: Float, g: Float, b: Float) {
            guard let t = tex else { return }
            var color: SIMD4<Float> = debugTintLayers ? SIMD4<Float>(r, g, b, 1.0) : SIMD4<Float>(1, 1, 1, 1)
            encoder.setFragmentTexture(t, index: 0)
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        setTintAndDraw(layerTex.satellites, r: 0.6, g: 1.0, b: 0.6)
        setTintAndDraw(layerTex.shooting,   r: 1.0, g: 0.5, b: 0.5)
        encoder.popDebugGroup()
        encoder.endEncoding()
    }
    
    private func scheduleProbeCenterReadbacks(commandBuffer: MTLCommandBuffer) {
        guard !probeCheckScheduled else { return }
        ensureReadbackBuffers()
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "ProbeCenterReadbacks"
        if let base = layerTex.base, let buf = rbProbeBase {
            enqueueCenterReadback(blit: blit, texture: base, buffer: buf)
        }
        if let sat = layerTex.satellites, let buf = rbProbeSat {
            enqueueCenterReadback(blit: blit, texture: sat, buffer: buf)
        }
        if let shoot = layerTex.shooting, let buf = rbProbeShoot {
            enqueueCenterReadback(blit: blit, texture: shoot, buffer: buf)
        }
        blit.endEncoding()
        probeCheckScheduled = true
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.logProbeCenters()
        }
    }
    
    private func logProbeCenters() {
        probeCheckScheduled = false
        func read(_ buf: MTLBuffer?) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8)? {
            guard let buf = buf else { return nil }
            let p = buf.contents().assumingMemoryBound(to: UInt8.self)
            return (p[0], p[1], p[2], p[3])
        }
        if let v = read(rbProbeBase) {
            os_log("PROBE Base center BGRA=(%{public}u,%{public}u,%{public}u,%{public}u)", log: log, type: .error, v.0, v.1, v.2, v.3)
        } else {
            os_log("PROBE Base center: nil", log: log, type: .error)
        }
        if let v = read(rbProbeSat) {
            os_log("PROBE Satellites center BGRA=(%{public}u,%{public}u,%{public}u,%{public}u)", log: log, type: .error, v.0, v.1, v.2, v.3)
        } else {
            os_log("PROBE Satellites center: nil", log: log, type: .error)
        }
        if let v = read(rbProbeShoot) {
            os_log("PROBE Shooting center BGRA=(%{public}u,%{public}u,%{public}u,%{public}u)", log: log, type: .error, v.0, v.1, v.2, v.3)
        } else {
            os_log("PROBE Shooting center: nil", log: log, type: .error)
        }
    }
    
    private func logReadbackValues() {
        rbLogCounter &+= 1
        func read(_ buf: MTLBuffer?) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8)? {
            guard let buf = buf else { return nil }
            let p = buf.contents().assumingMemoryBound(to: UInt8.self)
            // BGRA8 in little-endian
            let b = p[0]
            let g = p[1]
            let r = p[2]
            let a = p[3]
            return (b,g,r,a)
        }
        func roiStats(_ buf: MTLBuffer?) -> (avgA: Double, maxA: UInt8)? {
            guard let buf = buf else { return nil }
            let ptr = buf.contents().assumingMemoryBound(to: UInt8.self)
            var sumA: UInt64 = 0
            var maxA: UInt8 = 0
            let width = 64
            let height = 64
            let rowBytes = 256
            for y in 0..<height {
                let row = ptr + y * rowBytes
                var x = 0
                while x < width {
                    let a = row[x*4 + 3] // BGRA
                    sumA &+= UInt64(a)
                    if a > maxA { maxA = a }
                    x &+= 1
                }
            }
            let avgA: Double = Double(sumA) / Double(width * height)
            return (avgA, maxA)
        }
        
        let sat = read(rbBufferSat)
        let shoot = read(rbBufferShoot)
        let base = read(rbBufferBase)
        let draw = read(rbBufferDrawable)
        let trailsC = read(rbBufferTrailsCenter)
        
        let baseROI = roiStats(rbBufferBaseROI)
        let satROI = roiStats(rbBufferSatROI)
        let shootROI = roiStats(rbBufferShootROI)
        let trailsROI = roiStats(rbBufferTrailsROI)
        let drawableROI = roiStats(rbBufferDrawableROI)
        
        // Log every time (temporary) to catch state precisely
        if let v = base {
            os_log("RB Base center BGRA=(%{public}u,%{public}u,%{public}u,%{public}u)", log: log, type: .info, v.b, v.g, v.r, v.a)
        } else {
            os_log("RB Base center: nil", log: log, type: .info)
        }
        if let v = sat {
            os_log("RB Sat center BGRA=(%{public}u,%{public}u,%{public}u,%{public}u)", log: log, type: .info, v.b, v.g, v.r, v.a)
        }
        if let v = shoot {
            os_log("RB Shoot center BGRA=(%{public}u,%{public}u,%{public}u,%{public}u)", log: log, type: .info, v.b, v.g, v.r, v.a)
        }
        if let d = draw {
            os_log("RB Drawable(center) BGRA=(%{public}u,%{public}u,%{public}u,%{public}u)", log: log, type: .info, d.b, d.g, d.r, d.a)
        } else {
            os_log("RB Drawable(center): nil (no onscreen readback this frame)", log: log, type: .info)
        }
        if let t = trailsC {
            os_log("RB TrailsOnly center BGRA=(%{public}u,%{public}u,%{public}u,%{public}u)", log: log, type: .info, t.b, t.g, t.r, t.a)
        } else {
            os_log("RB TrailsOnly center: nil (readback not enqueued?)", log: log, type: .error)
        }
        if let s = baseROI {
            os_log("RB Base ROI64 alpha avg=%{public}.1f max=%{public}u", log: log, type: .info, s.avgA, s.maxA)
        }
        if let s = satROI {
            os_log("RB Sat ROI64 alpha avg=%{public}.1f max=%{public}u", log: log, type: .info, s.avgA, s.maxA)
        }
        if let s = shootROI {
            os_log("RB Shoot ROI64 alpha avg=%{public}.1f max=%{public}u", log: log, type: .info, s.avgA, s.maxA)
        }
        if let s = trailsROI {
            os_log("RB TrailsOnly ROI64 alpha avg=%{public}.1f max=%{public}u", log: log, type: .info, s.avgA, s.maxA)
        }
        if let s = drawableROI {
            os_log("RB Drawable ROI64 alpha avg=%{public}.1f max=%{public}u", log: log, type: .info, s.avgA, s.maxA)
        }
        
        // Phase diagnostics: compare measured decay to keep factor
        if debugPhaseReadbacks {
            let satPre = read(rbSatPre)
            let satPost = read(rbSatPostDecay)
            let satEmit = read(rbSatPostEmit)
            let shPre = read(rbShootPre)
            let shPost = read(rbShootPostDecay)
            let shEmit = read(rbShootPostEmit)
            func frac(_ num: UInt8, _ den: UInt8) -> Double {
                if den == 0 { return Double.nan }
                return Double(num) / Double(den)
            }
            if let pre = satPre, let post = satPost {
                let k = Double(lastKeepSatUsed)
                let ratioA = frac(post.a, pre.a)
                os_log("PHASE Sat: keep=%.3f preA=%{public}u postDecayA=%{public}u ratio=%.3f postEmitA=%{public}@",
                       log: log, type: .info, k, pre.a, post.a, ratioA,
                       satEmit != nil ? "\(satEmit!.a)" : "nil")
            }
            if let pre = shPre, let post = shPost {
                let k = Double(lastKeepShootUsed)
                let ratioA = frac(post.a, pre.a)
                os_log("PHASE Shoot: keep=%.3f preA=%{public}u postDecayA=%{public}u ratio=%.3f postEmitA=%{public}@",
                       log: log, type: .info, k, pre.a, post.a, ratioA,
                       shEmit != nil ? "\(shEmit!.a)" : "nil")
            }
        }
        
        // Compute and compare expected composite from layers vs actual drawable (premultiplied alpha)
        if let b = base, let s = sat, let sh = shoot, let d = draw {
            func norm(_ u: UInt8) -> Float { return Float(u) / 255.0 }
            func denorm(_ f: Float) -> UInt8 {
                let clamped = max(0.0, min(1.0, f))
                return UInt8(roundf(clamped * 255.0))
            }
            struct RGBAf { var r: Float; var g: Float; var b: Float; var a: Float }
            func toRGBAf(_ v: (b: UInt8, g: UInt8, r: UInt8, a: UInt8)) -> RGBAf {
                return RGBAf(r: norm(v.r), g: norm(v.g), b: norm(v.b), a: norm(v.a))
            }
            func blend(dst: RGBAf, src: RGBAf) -> RGBAf {
                // Premultiplied alpha blending: out = src + dst * (1 - src.a)
                let oneMinusA = (1.0 - src.a)
                return RGBAf(r: src.r + dst.r * oneMinusA,
                             g: src.g + dst.g * oneMinusA,
                             b: src.b + dst.b * oneMinusA,
                             a: src.a + dst.a * oneMinusA)
            }
            let cb = toRGBAf(b)
            let cs = toRGBAf(s)
            let csh = toRGBAf(sh)
            // Layers-only prediction (what we had before)
            let out1 = cb
            let out2 = blend(dst: out1, src: cs)     // base then satellites
            let out3 = blend(dst: out2, src: csh)    // then shooting
            let predLayers = (b: denorm(out3.b), g: denorm(out3.g), r: denorm(out3.r), a: denorm(out3.a))
            // Prediction including drawable clear background (opaque black)
            let bg = RGBAf(r: 0, g: 0, b: 0, a: 1)   // clearColor = (0,0,0,1)
            let outB1 = blend(dst: bg, src: cb)
            let outB2 = blend(dst: outB1, src: cs)
            let outB3 = blend(dst: outB2, src: csh)
            let predWithBg = (b: denorm(outB3.b), g: denorm(outB3.g), r: denorm(outB3.r), a: denorm(outB3.a))
            let actual = d
            os_log("Composite check (layers-only): predicted BGRA=(%{public}u,%{public}u,%{public}u,%{public}u)",
                   log: log, type: .info, predLayers.b, predLayers.g, predLayers.r, predLayers.a)
            os_log("Composite check (incl bg, NOTE: onscreen uses tint=%{public}@): predicted BGRA=(%{public}u,%{public}u,%{public}u,%{public}u) vs drawable BGRA=(%{public}u,%{public}u,%{public}u,%{public}u)",
                   log: log, type: .info,
                   debugTintLayers ? "YES" : "no",
                   predWithBg.b, predWithBg.g, predWithBg.r, predWithBg.a, actual.b, actual.g, actual.r, actual.a)
            let db = Int32(actual.b) - Int32(predWithBg.b)
            let dg = Int32(actual.g) - Int32(predWithBg.g)
            let dr = Int32(actual.r) - Int32(predWithBg.r)
            let da = Int32(actual.a) - Int32(predWithBg.a)
            if abs(db) > 3 || abs(dg) > 3 || abs(dr) > 3 || abs(da) > 3 {
                os_log("Composite deviation (incl bg): ΔBGRA=(%{public}d,%{public}d,%{public}d,%{public}d)",
                       log: log, type: .error, db, dg, dr, da)
            }
        }
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
    
    private func ptrString(_ t: MTLTexture) -> String {
        let p = Unmanaged.passUnretained(t as AnyObject).toOpaque()
        return String(describing: p)
    }
}
