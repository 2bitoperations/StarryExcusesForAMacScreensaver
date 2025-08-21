import Foundation
import Metal
import QuartzCore
import CoreGraphics
import os
import AppKit

/// Holds per-frame CPU-rendered layer contexts + dirty flags for Metal upload.
struct StarryMetalFrameUpdate {
    let size: CGSize
    let baseContext: CGContext
    let satellitesContext: CGContext?
    let satellitesChanged: Bool
    let shootingStarsContext: CGContext?
    let shootingStarsChanged: Bool
    let moonContext: CGContext?
    let moonChanged: Bool
    let debugContext: CGContext?
    let debugChanged: Bool
}

/// Metal renderer responsible only for:
/// 1. Creating & resizing per-layer textures
/// 2. Uploading changed CPU layer bitmaps into those textures
/// 3. Compositing the textures in the correct order into the CAMetalLayer drawable
///
/// Phase 1: All drawing still occurs on CPU (CoreGraphics) inside StarryEngine.
/// Phase 2 (future): Individual layers will move their drawing onto the GPU.
final class StarryMetalRenderer {
    
    // MARK: - Nested Types
    
    private struct LayerTextures {
        var base: MTLTexture?
        var satellites: MTLTexture?
        var shootingStars: MTLTexture?
        var moon: MTLTexture?
        var debug: MTLTexture?
        var size: CGSize = .zero
    }
    
    // MARK: - Properties
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private weak var metalLayer: CAMetalLayer?
    private let log: OSLog
    
    private var pipelineState: MTLRenderPipelineState!
    
    private var layerTextures = LayerTextures()
    
    // Reusable vertex buffer for a full-screen quad (two triangles).
    private var quadVertexBuffer: MTLBuffer?
    
    // Synchronization: all access happens on screensaver animation thread; no locking needed today.
    
    // MARK: - Init
    
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
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.isOpaque = true
        
        do {
            try buildPipeline()
            buildQuad()
        } catch {
            os_log("Failed to build Metal pipeline: %{public}@", log: log, type: .fault, "\(error)")
            return nil
        }
    }
    
    // MARK: - Setup
    
    private func buildPipeline() throws {
        let librarySource: String? = nil // we rely on Shaders.metal being part of the target
        let library: MTLLibrary
        if let src = librarySource {
            library = try device.makeLibrary(source: src, options: nil)
        } else {
            library = try device.makeDefaultLibrary(bundle: Bundle(for: StarryMetalRenderer.self))
        }
        guard
            let vFunc = library.makeFunction(name: "TexturedQuadVertex"),
            let fFunc = library.makeFunction(name: "TexturedQuadFragment")
        else {
            throw NSError(domain: "StarryMetalRenderer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Shader functions missing"])
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "StarryCompositePipeline"
        desc.vertexFunction = vFunc
        desc.fragmentFunction = fFunc
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        // Premultiplied alpha blending
        let blend = desc.colorAttachments[0]
        blend?.isBlendingEnabled = true
        blend?.sourceRGBBlendFactor = .one
        blend?.sourceAlphaBlendFactor = .one
        blend?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        blend?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        blend?.rgbBlendOperation = .add
        blend?.alphaBlendOperation = .add
        
        pipelineState = try device.makeRenderPipelineState(descriptor: desc)
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
        guard let layer = metalLayer else { return }
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: size.width * scale,
                                    height: size.height * scale)
    }
    
    /// Render the frame described by the CPU contexts.
    func render(frame: StarryMetalFrameUpdate) {
        guard let layer = metalLayer else { return }
        // Resize textures if needed
        if frame.size != layerTextures.size {
            allocateTextures(size: frame.size)
        }
        
        uploadIfNeeded(context: frame.baseContext,
                       existing: &layerTextures.base,
                       dirty: true, // base always changes
                       label: "Base")
        if let satCtx = frame.satellitesContext {
            uploadIfNeeded(context: satCtx,
                           existing: &layerTextures.satellites,
                           dirty: frame.satellitesChanged,
                           label: "Satellites")
        } else {
            layerTextures.satellites = nil
        }
        if let ssCtx = frame.shootingStarsContext {
            uploadIfNeeded(context: ssCtx,
                           existing: &layerTextures.shootingStars,
                           dirty: frame.shootingStarsChanged,
                           label: "ShootingStars")
        } else {
            layerTextures.shootingStars = nil
        }
        if let moonCtx = frame.moonContext {
            uploadIfNeeded(context: moonCtx,
                           existing: &layerTextures.moon,
                           dirty: frame.moonChanged,
                           label: "Moon")
        } else {
            layerTextures.moon = nil
        }
        if let dbgCtx = frame.debugContext {
            uploadIfNeeded(context: dbgCtx,
                           existing: &layerTextures.debug,
                           dirty: frame.debugChanged,
                           label: "Debug")
        } else {
            layerTextures.debug = nil
        }
        
        guard
            let drawable = layer.nextDrawable(),
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }
        
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        
        guard
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd),
            let quad = quadVertexBuffer
        else {
            commandBuffer.commit()
            return
        }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(quad, offset: 0, index: 0)
        
        func drawTexture(_ tex: MTLTexture?) {
            guard let t = tex else { return }
            encoder.setFragmentTexture(t, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        
        // Composite order: base -> satellites -> shooting stars -> moon -> debug
        drawTexture(layerTextures.base)
        drawTexture(layerTextures.satellites)
        drawTexture(layerTextures.shootingStars)
        drawTexture(layerTextures.moon)
        drawTexture(layerTextures.debug)
        
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    // MARK: - Allocation & Upload
    
    private func allocateTextures(size: CGSize) {
        layerTextures.size = size
        let w = Int(size.width)
        let h = Int(size.height)
        guard w > 0, h > 0 else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: w,
                                                            height: h,
                                                            mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        // Create (or recreate) all textures
        layerTextures.base = device.makeTexture(descriptor: desc)
        layerTextures.base?.label = "BaseLayer"
        layerTextures.satellites = device.makeTexture(descriptor: desc)
        layerTextures.satellites?.label = "SatellitesLayer"
        layerTextures.shootingStars = device.makeTexture(descriptor: desc)
        layerTextures.shootingStars?.label = "ShootingStarsLayer"
        layerTextures.moon = device.makeTexture(descriptor: desc)
        layerTextures.moon?.label = "MoonLayer"
        layerTextures.debug = device.makeTexture(descriptor: desc)
        layerTextures.debug?.label = "DebugLayer"
    }
    
    private func uploadIfNeeded(context: CGContext,
                                existing: inout MTLTexture?,
                                dirty: Bool,
                                label: String) {
        guard dirty else { return }
        guard let dataPtr = context.data else { return }
        let width = context.width
        let height = context.height
        if existing == nil ||
            existing?.width != width ||
            existing?.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                width: width,
                                                                height: height,
                                                                mipmapped: false)
            desc.usage = [.shaderRead]
            desc.storageMode = .private
            existing = device.makeTexture(descriptor: desc)
            existing?.label = "\(label)Texture"
        }
        guard let tex = existing else { return }
        // Copy entire bitmap
        let region = MTLRegionMake2D(0, 0, width, height)
        tex.replace(region: region,
                    mipmapLevel: 0,
                    withBytes: dataPtr,
                    bytesPerRow: context.bytesPerRow)
    }
}
