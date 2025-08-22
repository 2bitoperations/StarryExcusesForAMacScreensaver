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
    // Kept local to avoid any cross-file visibility issues; layout must match Shaders.metal.
    private struct MoonUniformsSwift {
        var viewportSize: SIMD2<Float>
        var centerPx: SIMD2<Float>
        var radiusPx: Float
        var phase: Float
        var brightBrightness: Float
        var darkBrightness: Float
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
    private var quadVertexBuffer: MTLBuffer? // for textured composite
    // Instanced sprite data (resized per frame)
    private var spriteBuffer: MTLBuffer?
    
    // Moon albedo
    private var moonAlbedoTexture: MTLTexture?
    
    // Offscreen composite target for headless preview rendering
    private var offscreenComposite: MTLTexture?
    private var offscreenSize: CGSize = .zero
    
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
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: StarryMetalRenderer.self))
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
        // Decay pipeline: multiply destination by blendColor (src=0, dst=blendColor)
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "Decay"
            desc.vertexFunction = library.makeFunction(name: "TexturedQuadVertex") // any fullscreen quad
            desc.fragmentFunction = library.makeFunction(name: "DecayFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            let blend = desc.colorAttachments[0]
            blend?.isBlendingEnabled = true
            blend?.sourceRGBBlendFactor = .zero
            blend?.sourceAlphaBlendFactor = .zero
            blend?.destinationRGBBlendFactor = .blendColor
            blend?.destinationAlphaBlendFactor = .blendColor
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
        if let layer = metalLayer {
            layer.contentsScale = scale
            layer.drawableSize = CGSize(width: size.width * scale,
                                        height: size.height * scale)
        }
        if size != layerTex.size {
            allocateTextures(size: size)
            // If headless, reset offscreen composite as well
            if metalLayer == nil {
                offscreenComposite = nil
                offscreenSize = .zero
            }
        }
    }
    
    func setMoonAlbedo(image: CGImage) {
        // Upload as R8 texture
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                                                            width: width,
                                                            height: height,
                                                            mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        
        // Extract raw grayscale bytes from CGImage (will convert if not grayscale)
        guard let provider = image.dataProvider,
              let data = provider.data else {
            return
        }
        let nsdata = data as Data
        // If image is not 8bpp gray tight, we convert into tight buffer.
        // We'll draw into a grayscale context to guarantee layout.
        var bytes: [UInt8]
        var bytesPerRow = width
        if image.bitsPerPixel == 8, image.colorSpace?.model == .monochrome, image.bytesPerRow == width {
            bytes = [UInt8](nsdata)
        } else {
            bytes = [UInt8](repeating: 0, count: width * height)
            let cs = CGColorSpaceCreateDeviceGray()
            if let ctx = CGContext(data: &bytes,
                                   width: width,
                                   height: height,
                                   bitsPerComponent: 8,
                                   bytesPerRow: width,
                                   space: cs,
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: bytes,
                    bytesPerRow: bytesPerRow)
        moonAlbedoTexture = tex
    }
    
    func render(drawData: StarryDrawData) {
        // Upload moon albedo if provided
        if let img = drawData.moonAlbedoImage {
            setMoonAlbedo(image: img)
        }
        // Ensure textures
        if drawData.size != layerTex.size {
            allocateTextures(size: drawData.size)
            // Newly allocated: clear all
            clearOffscreenTextures()
        }
        if drawData.clearAll {
            clearOffscreenTextures()
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        
        // 1) Base layer: render sprites onto persistent base texture (no clear)
        if let baseTex = layerTex.base, !drawData.baseSprites.isEmpty {
            renderSprites(into: baseTex,
                          sprites: drawData.baseSprites,
                          viewport: drawData.size,
                          commandBuffer: commandBuffer)
        }
        
        // 2) Satellites trail: decay then draw
        if let satTex = layerTex.satellites {
            if drawData.satellitesKeepFactor < 1.0 {
                applyDecay(into: satTex,
                           keepFactor: drawData.satellitesKeepFactor,
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
            if drawData.shootingKeepFactor < 1.0 {
                applyDecay(into: shootTex,
                           keepFactor: drawData.shootingKeepFactor,
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
            // Uniforms
            var uni = MoonUniformsSwift(
                viewportSize: SIMD2<Float>(Float(drawData.size.width), Float(drawData.size.height)),
                centerPx: moon.centerPx,
                radiusPx: moon.radiusPx,
                phase: moon.phaseFraction,
                brightBrightness: moon.brightBrightness,
                darkBrightness: moon.darkBrightness
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
        // Upload moon albedo if provided
        if let img = drawData.moonAlbedoImage {
            setMoonAlbedo(image: img)
        }
        
        // Ensure persistent textures
        if drawData.size != layerTex.size {
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
        
        // 1) Base layer: render sprites onto persistent base texture (no clear)
        if let baseTex = layerTex.base, !drawData.baseSprites.isEmpty {
            renderSprites(into: baseTex,
                          sprites: drawData.baseSprites,
                          viewport: drawData.size,
                          commandBuffer: commandBuffer)
        }
        
        // 2) Satellites trail: decay then draw
        if let satTex = layerTex.satellites {
            if drawData.satellitesKeepFactor < 1.0 {
                applyDecay(into: satTex,
                           keepFactor: drawData.satellitesKeepFactor,
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
            if drawData.shootingKeepFactor < 1.0 {
                applyDecay(into: shootTex,
                           keepFactor: drawData.shootingKeepFactor,
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
            var uni = MoonUniformsSwift(
                viewportSize: SIMD2<Float>(Float(drawData.size.width), Float(drawData.size.height)),
                centerPx: moon.centerPx,
                radiusPx: moon.radiusPx,
                phase: moon.phaseFraction,
                brightBrightness: moon.brightBrightness,
                darkBrightness: moon.darkBrightness
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
        let w = max(1, Int(size.width))
        let h = max(1, Int(size.height))
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
                                     width: Double(target.width),
                                     height: Double(target.height),
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
        }
        // Multiply destination by keepFactor via blend constant
        encoder.setBlendColor(red: keepFactor, green: keepFactor, blue: keepFactor, alpha: keepFactor)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }
}
