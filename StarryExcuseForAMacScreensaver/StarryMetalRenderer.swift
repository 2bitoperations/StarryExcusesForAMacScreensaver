import Foundation
import Metal
import QuartzCore
import CoreGraphics
import ImageIO
import os
import simd

// StarryMetalRenderer notifications
// Post these to either NotificationCenter.default or DistributedNotificationCenter.default().
// All notifications accept a userInfo dictionary with the keys noted below.
//
// Names:
// - "StarryDebugCompositeMode"
//     userInfo: ["mode": Int] where 0=normal, 1=satellitesOnly, 2=baseOnly
//
// - "StarryDiagnostics"
//     userInfo keys (all optional; only provided keys are applied):
//       "enabled": Bool                         -> diagnosticsEnabled
//       "everyNFrames" | "debugLogEveryN": Int -> diagnosticsEveryNFrames
//       "skipSatellitesDraw": Bool             -> debugSkipSatellitesDraw
//       "overlayEnabled": Bool                 -> debugOverlayEnabled
//       "satellitesHalfLifeSeconds": Double    -> satellitesHalfLifeSeconds
//       "shootingHalfLifeSeconds": Double      -> shootingHalfLifeSeconds
//       "dropBaseEveryN": Int                  -> clears BaseLayer every N frames (0 disables)
//       "dumpLayersNextFrame": Bool            -> one-time dump of layers as PNGs to Desktop
//
//     Notes for keys intended for StarryEngine (not handled here):
//       "starsPerUpdate": Int
//       "buildingLightsPerUpdate": Int
//
// - "StarryClear"
//     userInfo:
//       "target": String -> one of "all", "base", "satellites", "shooting" (default all)
//
final class StarryMetalRenderer {
    
    // MARK: - Nested Types
    
    private struct LayerTextures {
        var base: MTLTexture?
        var baseScratch: MTLTexture?
        var satellites: MTLTexture?
        var satellitesScratch: MTLTexture?
        var shooting: MTLTexture?
        var shootingScratch: MTLTexture?
        var size: CGSize = .zero
    }
    
    private struct MoonUniformsSwift {
        var viewportSize: SIMD2<Float>
        var centerPx: SIMD2<Float>
        var params0: SIMD4<Float>
        var params1: SIMD4<Float>
    }
    
    private enum FragmentBufferIndex {
        static let quadUniforms = 0
    }
    
    enum CompositeDebugMode: Int {
        case normal = 0
        case satellitesOnly = 1
        case baseOnly = 2
    }
    
    enum LayerProvenance {
        case base
        case satellites
        case shooting
        case other
    }
    
    // MARK: - Debug Notifications
    
    private static let debugCompositeModeNotification = Notification.Name("StarryDebugCompositeMode")
    private static let diagnosticsNotification = Notification.Name("StarryDiagnostics")
    private static let clearNotification = Notification.Name("StarryClear")
    
    static func postCompositeMode(_ mode: CompositeDebugMode) {
        NotificationCenter.default.post(name: debugCompositeModeNotification,
                                        object: nil,
                                        userInfo: ["mode": mode.rawValue])
        DistributedNotificationCenter.default().post(name: debugCompositeModeNotification,
                                                     object: nil,
                                                     userInfo: ["mode": mode.rawValue])
    }
    
    // MARK: - Properties
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private weak var metalLayer: CAMetalLayer?
    private let log: OSLog
    
    // Pipelines
    private var compositePipeline: MTLRenderPipelineState!
    private var spriteOverPipeline: MTLRenderPipelineState!
    private var spriteAdditivePipeline: MTLRenderPipelineState!
    private var decayInPlacePipeline: MTLRenderPipelineState!
    private var moonPipeline: MTLRenderPipelineState!
    
    private var layerTex = LayerTextures()
    
    private var quadVertexBuffer: MTLBuffer?
    
    private struct SpriteBufferSet {
        var staging: MTLBuffer?
        var device: MTLBuffer?
        var capacity: Int = 0
    }
    private var baseSpriteBuffers = SpriteBufferSet()
    private var satellitesSpriteBuffers = SpriteBufferSet()
    private var shootingSpriteBuffers = SpriteBufferSet()
    private var otherSpriteBuffers = SpriteBufferSet()
    
    private var moonAlbedoTexture: MTLTexture?
    private var moonAlbedoStagingTexture: MTLTexture?
    private var moonAlbedoNeedsBlit: Bool = false
    
    private var offscreenComposite: MTLTexture?
    private var offscreenSize: CGSize = .zero
    
    private var lastAppliedDrawableSize: CGSize = .zero
    
    private var debugOverlayEnabled: Bool = false
    
    private var satellitesHalfLifeSeconds: Double = 0.5
    private var shootingHalfLifeSeconds: Double = 0.5
    
    private var lastRenderTime: CFTimeInterval?
    private var lastHeadlessRenderTime: CFTimeInterval?
    
    private var diagnosticsEnabled: Bool = true
    private var diagnosticsEveryNFrames: Int = 30
    private var frameIndex: UInt64 = 0
    private var debugSkipSatellitesDraw: Bool = false
    private var debugCompositeMode: CompositeDebugMode = .normal
    private var debugClearBasePending: Bool = false
    private var dropBaseEveryNFrames: Int = 0
    
    private var debugObserversInstalled: Bool = false
    
    // One-shot layer dumps
    private var dumpLayersNextFrame: Bool = false
    
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
        layer.framebufferOnly = false
        layer.isOpaque = true
        
        do {
            try buildPipelines()
            buildQuad()
            installDebugObservers()
        } catch {
            os_log("Failed to build Metal pipelines: %{public}@", log: log, type: .fault, "\(error)")
            return nil
        }
    }
    
    // MARK: - Init (headless/offscreen)
    
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
            installDebugObservers()
        } catch {
            os_log("Failed to build Metal pipelines (headless): %{public}@", log: log, type: .fault, "\(error)")
            return nil
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }
    
    // MARK: - Debug control observers
    
    private func installDebugObservers() {
        guard !debugObserversInstalled else { return }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleCompositeModeNotification(_:)),
                                               name: StarryMetalRenderer.debugCompositeModeNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleDiagnosticsNotification(_:)),
                                               name: StarryMetalRenderer.diagnosticsNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleClearNotification(_:)),
                                               name: StarryMetalRenderer.clearNotification,
                                               object: nil)
        DistributedNotificationCenter.default().addObserver(self,
                                                            selector: #selector(handleCompositeModeNotification(_:)),
                                                            name: StarryMetalRenderer.debugCompositeModeNotification,
                                                            object: nil)
        DistributedNotificationCenter.default().addObserver(self,
                                                            selector: #selector(handleDiagnosticsNotification(_:)),
                                                            name: StarryMetalRenderer.diagnosticsNotification,
                                                            object: nil)
        DistributedNotificationCenter.default().addObserver(self,
                                                            selector: #selector(handleClearNotification(_:)),
                                                            name: StarryMetalRenderer.clearNotification,
                                                            object: nil)
        debugObserversInstalled = true
    }
    
    @objc private func handleCompositeModeNotification(_ note: Notification) {
        if let raw = note.userInfo?["mode"] as? Int,
           let mode = CompositeDebugMode(rawValue: raw) {
            debugCompositeMode = mode
            os_log("Debug: composite mode changed via notification to %{public}@",
                   log: log, type: .info,
                   mode == .normal ? "NORMAL" : (mode == .satellitesOnly ? "SATELLITES-ONLY" : "BASE-ONLY"))
        }
    }
    
    @objc private func handleDiagnosticsNotification(_ note: Notification) {
        let ui = note.userInfo
        var applied: [String] = []
        
        if let v: Bool = value("enabled", from: ui) {
            diagnosticsEnabled = v
            applied.append("diagnosticsEnabled=\(v)")
        }
        if let n: Int = value("everyNFrames", from: ui) ?? value("debugLogEveryN", from: ui) {
            diagnosticsEveryNFrames = max(1, n)
            applied.append("diagnosticsEveryNFrames=\(diagnosticsEveryNFrames)")
        }
        if let v: Bool = value("skipSatellitesDraw", from: ui) {
            debugSkipSatellitesDraw = v
            applied.append("skipSatellitesDraw=\(v)")
        }
        if let v: Bool = value("overlayEnabled", from: ui) {
            debugOverlayEnabled = v
            applied.append("overlayEnabled=\(v)")
        }
        if let d: Double = value("satellitesHalfLifeSeconds", from: ui) {
            satellitesHalfLifeSeconds = max(1e-6, d)
            applied.append(String(format: "satellitesHalfLife=%.4f", satellitesHalfLifeSeconds))
        }
        if let d: Double = value("shootingHalfLifeSeconds", from: ui) {
            shootingHalfLifeSeconds = max(1e-6, d)
            applied.append(String(format: "shootingHalfLife=%.4f", shootingHalfLifeSeconds))
        }
        if let n: Int = value("dropBaseEveryN", from: ui) {
            dropBaseEveryNFrames = max(0, n)
            applied.append("dropBaseEveryN=\(dropBaseEveryNFrames)")
        }
        if let dump: Bool = value("dumpLayersNextFrame", from: ui), dump {
            dumpLayersNextFrame = true
            applied.append("dumpLayersNextFrame")
        }
        
        var ignored: [String] = []
        if ui?["starsPerUpdate"] != nil { ignored.append("starsPerUpdate") }
        if ui?["buildingLightsPerUpdate"] != nil { ignored.append("buildingLightsPerUpdate") }
        // Legacy / removed keys (GPU capture) — ignore silently if present
        if ui?["gpuCaptureStart"] != nil { ignored.append("gpuCaptureStart(removed)") }
        if ui?["gpuCaptureStop"] != nil { ignored.append("gpuCaptureStop(removed)") }
        if ui?["gpuCaptureFrames"] != nil { ignored.append("gpuCaptureFrames(removed)") }
        if ui?["gpuCapturePath"] != nil { ignored.append("gpuCapturePath(removed)") }
        
        if !ignored.isEmpty {
            os_log("Diagnostics notification contained ignored keys: %{public}@",
                   log: log, type: .info, ignored.joined(separator: ","))
        }
        
        if applied.isEmpty {
            os_log("Diagnostics notification received, no applicable keys found", log: log, type: .info)
        } else {
            os_log("Diagnostics updated via notification: %{public}@", log: log, type: .info, applied.joined(separator: ", "))
        }
    }
    
    @objc private func handleClearNotification(_ note: Notification) {
        let target: String = (note.userInfo?["target"] as? String)?.lowercased() ?? "all"
        if target == "all" {
            clearOffscreenTextures(reason: "Notification(all)")
            return
        }
        guard let cb = commandQueue.makeCommandBuffer() else {
            os_log("Clear notification: failed to make command buffer", log: log, type: .error)
            return
        }
        func clr(_ t: MTLTexture?, label: String) {
            guard let t = t else { return }
            clearTexture(t, commandBuffer: cb, label: "Clear via notification: \(label)")
        }
        switch target {
        case "base":
            clr(layerTex.base, label: "base")
            clr(layerTex.baseScratch, label: "baseScratch")
        case "satellites":
            clr(layerTex.satellites, label: "satellites")
            clr(layerTex.satellitesScratch, label: "satellitesScratch")
        case "shooting":
            clr(layerTex.shooting, label: "shooting")
            clr(layerTex.shootingScratch, label: "shootingScratch")
        default:
            os_log("Clear notification: unknown target '%{public}@' — clearing ALL instead", log: log, type: .error, target)
            clearOffscreenTextures(reason: "Notification(invalid \(target))")
            return
        }
        cb.commit()
        cb.waitUntilCompleted()
        os_log("Clear notification: '%{public}@' complete", log: log, type: .info, target)
    }
    
    // MARK: - Setup
    
    private func buildPipelines() throws {
        let library = try makeShaderLibrary()
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
        // Removed DecaySampled pipeline (sampling-based decay). We now use only in-place decay.
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "DecayInPlace"
            desc.vertexFunction = library.makeFunction(name: "TexturedQuadVertex")
            desc.fragmentFunction = library.makeFunction(name: "SolidBlackFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            let blend = desc.colorAttachments[0]!
            blend.isBlendingEnabled = true
            blend.sourceRGBBlendFactor = .zero
            blend.sourceAlphaBlendFactor = .zero
            blend.destinationRGBBlendFactor = .blendColor
            blend.destinationAlphaBlendFactor = .blendAlpha
            blend.rgbBlendOperation = .add
            blend.alphaBlendOperation = .add
            decayInPlacePipeline = try device.makeRenderPipelineState(descriptor: desc)
        }
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
    
    private func makeShaderLibrary() throws -> MTLLibrary {
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
        do {
            let lib = try device.makeDefaultLibrary(bundle: bundle)
            os_log("Loaded default Metal library via bundle", log: log, type: .info)
            return lib
        } catch {
            os_log("makeDefaultLibrary(bundle:) failed: %{public}@", log: log, type: .error, "\(error)")
        }
        if let lib = device.makeDefaultLibrary() {
            os_log("Loaded process default Metal library", log: log, type: .info)
            return lib
        }
        throw NSError(domain: "StarryMetalRenderer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to load any Metal shader library"])
    }
    
    private func buildQuad() {
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
        guard scale > 0 else { return }
        let wPx = Int(round(size.width * scale))
        let hPx = Int(round(size.height * scale))
        guard wPx > 0, hPx > 0 else { return }
        
        if let layer = metalLayer {
            let newDrawable = CGSize(width: CGFloat(wPx), height: CGFloat(hPx))
            if newDrawable != lastAppliedDrawableSize {
                layer.contentsScale = scale
                layer.drawableSize = newDrawable
                lastAppliedDrawableSize = newDrawable
            } else {
                layer.contentsScale = scale
            }
        }
        if size.width >= 1, size.height >= 1, size != layerTex.size {
            allocateTextures(size: size)
            clearOffscreenTextures(reason: "Resize/allocate")
            os_log("updateDrawableSize: allocated and cleared layer textures for size %{public}.0fx%{public}.0f",
                   log: log, type: .info, Double(size.width), Double(size.height))
            if metalLayer == nil {
                offscreenComposite = nil
                offscreenSize = .zero
            }
        }
    }
    
    func setDebugOverlayEnabled(_ enabled: Bool) {
        debugOverlayEnabled = enabled
    }
    
    func setDiagnostics(enabled: Bool, everyNFrames: Int = 60) {
        diagnosticsEnabled = enabled
        diagnosticsEveryNFrames = max(1, everyNFrames)
        os_log("Diagnostics %{public}@", log: log, type: .info, enabled ? "ENABLED" : "disabled")
    }
    
    func setSkipSatellitesDrawingForDebug(_ skip: Bool) {
        debugSkipSatellitesDraw = skip
        os_log("Debug: skip satellites draw is %{public}@", log: log, type: .info, skip ? "ON" : "off")
    }
    
    func setCompositeSatellitesOnlyForDebug(_ enabled: Bool) {
        let wasSatOnly = (debugCompositeMode == .satellitesOnly)
        debugCompositeMode = enabled ? .satellitesOnly : .normal
        os_log("Debug: composite mode set to %{public}@", log: log, type: .info,
               enabled ? "SATELLITES-ONLY" : "NORMAL")
        if wasSatOnly && !enabled {
            debugClearBasePending = true
            os_log("Debug: scheduling one-time BASE clear on next frame (leaving satellites-only)", log: log, type: .info)
        }
    }
    
    func setCompositeBaseOnlyForDebug(_ enabled: Bool) {
        debugCompositeMode = enabled ? .baseOnly : .normal
        os_log("Debug: composite mode set to %{public}@", log: log, type: .info, enabled ? "BASE-ONLY" : "NORMAL")
    }
    
    func setTrailHalfLives(satellites: Double?, shooting: Double?) {
        satellitesHalfLifeSeconds = satellites ?? 0.5
        shootingHalfLifeSeconds = shooting ?? 0.5
        os_log("Trail half-lives updated: satellites=%{public}.3f s, shooting=%{public}.3f s",
               log: log, type: .info, satellitesHalfLifeSeconds, shootingHalfLifeSeconds)
    }
    
    func setMoonAlbedo(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return }
        os_log("setMoonAlbedo: preparing upload via staging+blit (%{public}dx%{public}d)", log: log, type: .info, width, height)
        
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
        
        let stagingDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                                                                   width: width,
                                                                   height: height,
                                                                   mipmapped: false)
        stagingDesc.storageMode = .shared
        stagingDesc.usage = []
        guard let staging = device.makeTexture(descriptor: stagingDesc) else {
            os_log("setMoonAlbedo: failed to create staging texture", log: log, type: .error)
            return
        }
        staging.label = "MoonAlbedo (staging)"
        
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
        staging.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: uploadBytes,
                        bytesPerRow: bytesPerRow)
        
        moonAlbedoStagingTexture = staging
        moonAlbedoNeedsBlit = true
        os_log("setMoonAlbedo: staged bytes; will blit to private on next command buffer", log: log, type: .info)
    }
    
    func render(drawData: StarryDrawData) {
        if let img = drawData.moonAlbedoImage {
            setMoonAlbedo(image: img)
        }
        if drawData.size.width >= 1, drawData.size.height >= 1, drawData.size != layerTex.size {
            allocateTextures(size: drawData.size)
            clearOffscreenTextures(reason: "Allocate on render()")
        }
        if drawData.clearAll {
            os_log("Render: Clear requested via drawData.clearAll", log: log, type: .info)
            clearOffscreenTextures(reason: "UserClearAll")
        }
        
        let now = CACurrentMediaTime()
        let dt: CFTimeInterval? = lastRenderTime.map { now - $0 }
        lastRenderTime = now
        
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
        
        logFrameDiagnostics(prefix: "", drawData: drawData, dt: dt)
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "Starry Frame CommandBuffer"
        
        if moonAlbedoNeedsBlit, let staging = moonAlbedoStagingTexture, let dst = moonAlbedoTexture {
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.label = "Blit MoonAlbedo staging->private"
                let size = MTLSize(width: staging.width, height: staging.height, depth: 1)
                blit.copy(from: staging,
                          sourceSlice: 0,
                          sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: size,
                          to: dst,
                          destinationSlice: 0,
                          destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
                os_log("render: enqueued moon albedo GPU blit (%{public}dx%{public}d)", log: log, type: .info, dst.width, dst.height)
            }
            moonAlbedoNeedsBlit = false
            moonAlbedoStagingTexture = nil
        }
        
        encodeScenePasses(commandBuffer: commandBuffer,
                          drawData: drawData,
                          dt: dt,
                          headless: false)
        
        guard let drawable = metalLayer?.nextDrawable() else {
            os_log("No CAMetalLayer drawable available this frame", log: log, type: .error)
            commandBuffer.commit()
            frameIndex &+= 1
            return
        }
        
        encodeCompositeAndMoon(commandBuffer: commandBuffer,
                               target: drawable.texture,
                               drawData: drawData,
                               headless: false)
        
        if dumpLayersNextFrame {
            enqueueLayerDumps(commandBuffer: commandBuffer)
            dumpLayersNextFrame = false
        }
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
        frameIndex &+= 1
    }
    
    func renderToImage(drawData: StarryDrawData) -> CGImage? {
        if let img = drawData.moonAlbedoImage {
            setMoonAlbedo(image: img)
        }
        if drawData.size.width >= 1, drawData.size.height >= 1, drawData.size != layerTex.size {
            allocateTextures(size: drawData.size)
            clearOffscreenTextures(reason: "Allocate on renderToImage()")
        }
        if drawData.clearAll {
            os_log("RenderToImage: Clear requested via drawData.clearAll", log: log, type: .info)
            clearOffscreenTextures(reason: "UserClearAll(headless)")
        }
        ensureOffscreenComposite(size: drawData.size)
        guard let finalTarget = offscreenComposite else { return nil }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        commandBuffer.label = "Starry Headless CommandBuffer"
        
        if moonAlbedoNeedsBlit, let staging = moonAlbedoStagingTexture, let dst = moonAlbedoTexture {
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.label = "Blit MoonAlbedo staging->private (headless)"
                let size = MTLSize(width: staging.width, height: staging.height, depth: 1)
                blit.copy(from: staging,
                          sourceSlice: 0,
                          sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: size,
                          to: dst,
                          destinationSlice: 0,
                          destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
                os_log("renderToImage: enqueued moon albedo GPU blit (%{public}dx%{public}d)", log: log, type: .info, dst.width, dst.height)
            }
            moonAlbedoNeedsBlit = false
            moonAlbedoStagingTexture = nil
        }
        
        let now = CACurrentMediaTime()
        let dt: CFTimeInterval? = lastHeadlessRenderTime.map { now - $0 }
        lastHeadlessRenderTime = now
        
        logFrameDiagnostics(prefix: "[Headless] ", drawData: drawData, dt: dt)
        
        encodeScenePasses(commandBuffer: commandBuffer,
                          drawData: drawData,
                          dt: dt,
                          headless: true)
        
        encodeCompositeAndMoon(commandBuffer: commandBuffer,
                               target: finalTarget,
                               drawData: drawData,
                               headless: true)
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        return textureToImage(finalTarget)
    }
    
    // MARK: - Scene passes (immutability verification removed)
    
    private func encodeScenePasses(commandBuffer: MTLCommandBuffer,
                                   drawData: StarryDrawData,
                                   dt: CFTimeInterval?,
                                   headless: Bool) {
        // Optional periodic forced base clear
        if dropBaseEveryNFrames > 0,
           let baseTex = layerTex.base,
           (frameIndex % UInt64(dropBaseEveryNFrames) == 0) {
            clearTexture(baseTex, commandBuffer: commandBuffer,
                         label: headless ? "DropBaseEveryN (headless N=\(dropBaseEveryNFrames))" : "DropBaseEveryN (N=\(dropBaseEveryNFrames))")
            if let baseScratch = layerTex.baseScratch {
                clearTexture(baseScratch, commandBuffer: commandBuffer,
                             label: headless ? "DropBaseEveryN Scratch (headless)" : "DropBaseEveryN Scratch")
            }
        }
        
        // One-time pending base clear (debug)
        if debugClearBasePending {
            if let baseTex = layerTex.base {
                clearTexture(baseTex, commandBuffer: commandBuffer,
                             label: headless ? "Debug One-Time Base Clear (headless)" : "Debug One-Time Base Clear")
            }
            if let baseScratch = layerTex.baseScratch {
                clearTexture(baseScratch, commandBuffer: commandBuffer,
                             label: headless ? "Debug One-Time BaseScratch Clear (headless)" : "Debug One-Time BaseScratch Clear")
            }
            debugClearBasePending = false
        }
        
        // --- BASE PASS ---
        if let baseTex = layerTex.base, let baseScratch = layerTex.baseScratch {
            if !drawData.baseSprites.isEmpty {
                renderSprites(into: baseTex,
                              sprites: drawData.baseSprites,
                              pipeline: spriteOverPipeline,
                              commandBuffer: commandBuffer,
                              provenance: .base)
            }
            blitCopy(from: baseTex, to: baseScratch, using: commandBuffer,
                     label: headless ? "Base copy -> Scratch (headless)" : "Base copy -> Scratch")
        } else if let baseTex = layerTex.base {
            if !drawData.baseSprites.isEmpty {
                renderSprites(into: baseTex,
                              sprites: drawData.baseSprites,
                              pipeline: spriteOverPipeline,
                              commandBuffer: commandBuffer,
                              provenance: .base)
            }
        }
        
        if debugCompositeMode != .baseOnly {
            // Satellites
            if layerTex.satellites != nil {
                applyDecay(into: .satellites, dt: dt, commandBuffer: commandBuffer)
                if !debugSkipSatellitesDraw && !drawData.satellitesSprites.isEmpty {
                    if let safeDst = safeLayerTarget(.satellites) {
                        renderSprites(into: safeDst,
                                      sprites: drawData.satellitesSprites,
                                      pipeline: spriteAdditivePipeline,
                                      commandBuffer: commandBuffer,
                                      provenance: .satellites)
                    } else {
                        os_log("ALERT: No safe satellites target — skipping satellites draw", log: log, type: .fault)
                    }
                }
            }
            // Shooting
            if layerTex.shooting != nil {
                applyDecay(into: .shooting, dt: dt, commandBuffer: commandBuffer)
                if !drawData.shootingSprites.isEmpty {
                    if let safeDst = safeLayerTarget(.shooting) {
                        renderSprites(into: safeDst,
                                      sprites: drawData.shootingSprites,
                                      pipeline: spriteAdditivePipeline,
                                      commandBuffer: commandBuffer,
                                      provenance: .shooting)
                    } else {
                        os_log("ALERT: No safe shooting target — skipping shooting draw", log: log, type: .fault)
                    }
                }
            }
        }
    }
    
    private func encodeCompositeAndMoon(commandBuffer: MTLCommandBuffer,
                                        target: MTLTexture,
                                        drawData: StarryDrawData,
                                        headless: Bool) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else {
            return
        }
        encoder.pushDebugGroup(headless ? "Headless Composite+Moon" : "Composite+Moon")
        
        let vp = MTLViewport(originX: 0, originY: 0,
                             width: Double(target.width),
                             height: Double(target.height),
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
            encoder.setFragmentBytes(&whiteTint,
                                     length: MemoryLayout<SIMD4<Float>>.stride,
                                     index: FragmentBufferIndex.quadUniforms)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        switch debugCompositeMode {
        case .satellitesOnly:
            drawTex(layerTex.satellites)
        case .baseOnly:
            drawTex(layerTex.baseScratch)
        case .normal:
            drawTex(layerTex.baseScratch)
            drawTex(layerTex.satellites)
            drawTex(layerTex.shooting)
        }
        
        if debugCompositeMode == .normal, let moon = drawData.moon {
            encoder.setRenderPipelineState(moonPipeline)
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
        layerTex.baseScratch = device.makeTexture(descriptor: desc)
        layerTex.baseScratch?.label = "BaseLayerScratch"
        layerTex.satellites = device.makeTexture(descriptor: desc)
        layerTex.satellites?.label = "SatellitesLayer"
        layerTex.satellitesScratch = device.makeTexture(descriptor: desc)
        layerTex.satellitesScratch?.label = "SatellitesLayerScratch"
        layerTex.shooting = device.makeTexture(descriptor: desc)
        layerTex.shooting?.label = "ShootingStarsLayer"
        layerTex.shootingScratch = device.makeTexture(descriptor: desc)
        layerTex.shootingScratch?.label = "ShootingStarsLayerScratch"
        
        os_log("Allocated textures: base=%{public}@ baseScratch=%{public}@ sat=%{public}@ satScratch=%{public}@ shoot=%{public}@ shootScratch=%{public}@",
               log: log, type: .info,
               ptrString(layerTex.base!),
               ptrString(layerTex.baseScratch!),
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
        clear(texture: layerTex.baseScratch)
        clear(texture: layerTex.satellites)
        clear(texture: layerTex.satellitesScratch)
        clear(texture: layerTex.shooting)
        clear(texture: layerTex.shootingScratch)
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        os_log("ClearOffscreenTextures: complete (reason=%{public}@)", log: log, type: .info, reason)
    }
    
    private func clearTexture(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer, label: String) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.pushDebugGroup(label)
        let vp = MTLViewport(originX: 0, originY: 0,
                             width: Double(texture.width),
                             height: Double(texture.height),
                             znear: 0, zfar: 1)
        enc.setViewport(vp)
        enc.popDebugGroup()
        enc.endEncoding()
    }
    
    // Upload sprite instances using staging (.shared) -> device (.private) BLIT
    private func uploadSpriteInstances(_ sprites: [SpriteInstance],
                                       provenance: LayerProvenance,
                                       commandBuffer: MTLCommandBuffer) -> MTLBuffer? {
        let requiredBytes = sprites.count * MemoryLayout<SpriteInstance>.stride
        guard requiredBytes > 0 else { return nil }
        let minAlloc = 16 * 1024
        
        func grow(set: inout SpriteBufferSet, labelBase: String) {
            if set.capacity >= requiredBytes { return }
            var newCap = max(requiredBytes, minAlloc)
            let page = 4096
            newCap = ((newCap + page - 1) / page) * page
            set.staging = device.makeBuffer(length: newCap, options: .storageModeShared)
            set.staging?.label = "\(labelBase)-Staging(\(newCap))"
            set.device = device.makeBuffer(length: newCap, options: .storageModePrivate)
            set.device?.label = "\(labelBase)-Device(\(newCap))"
            set.capacity = newCap
        }
        
        var targetSet: UnsafeMutablePointer<SpriteBufferSet>
        switch provenance {
        case .base:
            targetSet = withUnsafeMutablePointer(to: &baseSpriteBuffers) { $0 }
        case .satellites:
            targetSet = withUnsafeMutablePointer(to: &satellitesSpriteBuffers) { $0 }
        case .shooting:
            targetSet = withUnsafeMutablePointer(to: &shootingSpriteBuffers) { $0 }
        case .other:
            targetSet = withUnsafeMutablePointer(to: &otherSpriteBuffers) { $0 }
        }
        
        grow(set: &targetSet.pointee, labelBase: "SpriteInstances-\(provenanceString(provenance))")
        guard let staging = targetSet.pointee.staging,
              let deviceBuf = targetSet.pointee.device else {
            os_log("uploadSpriteInstances: allocation failed provenance=%{public}@ bytes=%{public}d",
                   log: log, type: .fault, provenanceString(provenance), requiredBytes)
            return nil
        }
        
        sprites.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(staging.contents(), base, requiredBytes)
            }
        }
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "Blit SpriteInstances \(provenanceString(provenance)) (\(requiredBytes) bytes)"
            blit.copy(from: staging,
                      sourceOffset: 0,
                      to: deviceBuf,
                      destinationOffset: 0,
                      size: requiredBytes)
            blit.endEncoding()
        }
        return deviceBuf
    }
    
    private func renderSprites(into target: MTLTexture,
                               sprites: [SpriteInstance],
                               pipeline: MTLRenderPipelineState,
                               commandBuffer: MTLCommandBuffer,
                               provenance: LayerProvenance) {
        guard !sprites.isEmpty else { return }
        
        // Upload
        guard let deviceBuffer = uploadSpriteInstances(sprites,
                                                       provenance: provenance,
                                                       commandBuffer: commandBuffer) else { return }
        
        if (pipeline === spriteAdditivePipeline) &&
            (isSameTexture(target, layerTex.base) ||
             isSameTexture(target, layerTex.baseScratch) ||
             labelContains(target, "BaseLayer")) {
            os_log("ALERT: Skipping additive draw into BaseLayer (provenance=%{public}@)", log: log, type: .fault, provenanceString(provenance))
            return
        }
        
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        encoder.pushDebugGroup("RenderSprites -> \(target.label ?? "tex") count=\(sprites.count)")
        let vp = MTLViewport(originX: 0, originY: 0,
                             width: Double(target.width),
                             height: Double(target.height),
                             znear: 0, zfar: 1)
        encoder.setViewport(vp)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(deviceBuffer, offset: 0, index: 1)
        var uni = SpriteUniforms(viewportSize: SIMD2<Float>(Float(target.width), Float(target.height)))
        encoder.setVertexBytes(&uni, length: MemoryLayout<SpriteUniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle,
                               vertexStart: 0,
                               vertexCount: 6,
                               instanceCount: sprites.count)
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
            return 1.0 / 60.0
        }()
        return Float(pow(0.5, dtSec / max(halfLife, 1e-6)))
    }
    
    private func applyDecay(into which: TrailLayer,
                            dt: CFTimeInterval?,
                            commandBuffer: MTLCommandBuffer) {
        let halfLife: Double = (which == .satellites) ? satellitesHalfLifeSeconds : shootingHalfLifeSeconds
        let keep = decayKeep(forHalfLife: halfLife, dt: dt)
        
        if diagnosticsEnabled && frameIndex % UInt64(diagnosticsEveryNFrames) == 0 {
            os_log("Decay in-place %{public}@ keep=%{public}.4f (halfLife=%{public}.3f dt=%{public}.4f)",
                   log: log, type: .debug,
                   (which == .satellites ? "satellites" : "shooting"),
                   keep, halfLife, (dt ?? 0))
        }
        
        let target: MTLTexture? = (which == .satellites) ? layerTex.satellites : layerTex.shooting
        guard let tex = target else {
            os_log("applyDecay: missing target texture for %{public}@ layer", log: log, type: .error, which == .satellites ? "satellites" : "shooting")
            return
        }
        
        if keep <= 1e-6 {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = tex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                enc.pushDebugGroup("Decay Clear -> \(tex.label ?? "tex")")
                let vp = MTLViewport(originX: 0, originY: 0,
                                     width: Double(tex.width), height: Double(tex.height),
                                     znear: 0, zfar: 1)
                enc.setViewport(vp)
                enc.popDebugGroup()
                enc.endEncoding()
            }
            return
        }
        
        // In-place decay: draw fullscreen quad with SolidBlackFragment; blending scales destination by keep.
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        encoder.pushDebugGroup("DecayInPlace -> \(tex.label ?? "tex") keep=\(keep)")
        let vp = MTLViewport(originX: 0, originY: 0,
                             width: Double(tex.width),
                             height: Double(tex.height),
                             znear: 0, zfar: 1)
        encoder.setViewport(vp)
        encoder.setRenderPipelineState(decayInPlacePipeline)
        if let quad = quadVertexBuffer {
            encoder.setVertexBuffer(quad, offset: 0, index: 0)
        }
        encoder.setBlendColor(red: keep, green: keep, blue: keep, alpha: keep)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.popDebugGroup()
        encoder.endEncoding()
    }
    
    private func ptrString(_ t: MTLTexture) -> String {
        let p = Unmanaged.passUnretained(t as AnyObject).toOpaque()
        return String(describing: p)
    }
    
    private func isSameTexture(_ a: MTLTexture?, _ b: MTLTexture?) -> Bool {
        guard let a = a, let b = b else { return false }
        let pa = Unmanaged.passUnretained(a as AnyObject).toOpaque()
        let pb = Unmanaged.passUnretained(b as AnyObject).toOpaque()
        return pa == pb
    }
    
    private func labelContains(_ t: MTLTexture?, _ needle: String) -> Bool {
        guard let lbl = t?.label else { return false }
        return lbl.contains(needle)
    }
    
    private func safeLayerTarget(_ which: TrailLayer) -> MTLTexture? {
        switch which {
        case .satellites:
            let a = layerTex.satellites
            let b = layerTex.satellitesScratch
            let aIsBase = labelContains(a, "BaseLayer") || isSameTexture(a, layerTex.base) || isSameTexture(a, layerTex.baseScratch)
            let bIsBase = labelContains(b, "BaseLayer") || isSameTexture(b, layerTex.base) || isSameTexture(b, layerTex.baseScratch)
            if a != nil && !aIsBase { return a }
            if b != nil && !bIsBase { return b }
            return nil
        case .shooting:
            let a = layerTex.shooting
            let b = layerTex.shootingScratch
            let aIsBase = labelContains(a, "BaseLayer") || isSameTexture(a, layerTex.base) || isSameTexture(a, layerTex.baseScratch)
            let bIsBase = labelContains(b, "BaseLayer") || isSameTexture(b, layerTex.base) || isSameTexture(b, layerTex.baseScratch)
            if a != nil && !aIsBase { return a }
            if b != nil && !bIsBase { return b }
            return nil
        }
    }
    
    private func provenanceString(_ p: LayerProvenance) -> String {
        switch p {
        case .base: return "base"
        case .satellites: return "satellites"
        case .shooting: return "shooting"
        case .other: return "other"
        }
    }
    
    private func blitCopy(from src: MTLTexture, to dst: MTLTexture, using cb: MTLCommandBuffer, label: String) {
        guard let blit = cb.makeBlitCommandEncoder() else { return }
        blit.label = label
        let size = MTLSize(width: min(src.width, dst.width),
                           height: min(src.height, dst.height),
                           depth: 1)
        blit.copy(from: src,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: size,
                  to: dst,
                  destinationSlice: 0,
                  destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
    }
    
    private func textureToImage(_ tex: MTLTexture) -> CGImage? {
        let w = tex.width
        let h = tex.height
        guard w > 0, h > 0 else { return nil }
        let bpp = 4
        let rowBytes = w * bpp
        var bytes = [UInt8](repeating: 0, count: rowBytes * h)
        let region = MTLRegionMake2D(0, 0, w, h)
        tex.getBytes(&bytes, bytesPerRow: rowBytes, from: region, mipmapLevel: 0)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: NSData(bytes: &bytes, length: bytes.count)) else { return nil }
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
    
    private func savePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            os_log("PNG save: failed to create destination for %{public}@", log: log, type: .error, url.path)
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        if CGImageDestinationFinalize(dest) {
            os_log("PNG saved -> %{public}@", log: log, type: .info, url.path)
        } else {
            os_log("PNG save failed -> %{public}@", log: log, type: .error, url.path)
        }
    }
    
    private func enqueueLayerDumps(commandBuffer: MTLCommandBuffer) {
        func snapshot(_ t: MTLTexture?) -> MTLTexture? {
            guard let t = t else { return nil }
            let snapDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: t.pixelFormat,
                                                                    width: t.width,
                                                                    height: t.height,
                                                                    mipmapped: false)
            snapDesc.usage = [.shaderRead]
            snapDesc.storageMode = .shared
            guard let snap = device.makeTexture(descriptor: snapDesc) else { return nil }
            blitCopy(from: t, to: snap, using: commandBuffer, label: "Dump snapshot \(t.label ?? "tex")")
            return snap
        }
        let baseSnap = snapshot(layerTex.base)
        let satSnap = snapshot(layerTex.satellites)
        let satScratchSnap = snapshot(layerTex.satellitesScratch)
        let shootSnap = snapshot(layerTex.shooting)
        let shootScratchSnap = snapshot(layerTex.shootingScratch)
        let frame = frameIndex
        let stamp = ISO8601DateFormatter().string(from: Date())
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent("StarryLayerDump-\(stamp)-f\(frame)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            os_log("DumpLayers: failed to create directory %{public}@ (%{public}@)",
                   log: log, type: .error, dir.path, "\(error)")
        }
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self = self else { return }
            func write(_ tex: MTLTexture?, name: String) {
                guard let tex = tex, let img = self.textureToImage(tex) else { return }
                let filename = "\(name)-\(tex.label ?? "tex")-\(self.ptrString(tex)).png"
                let url = dir.appendingPathComponent(filename, isDirectory: false)
                self.savePNG(img, to: url)
            }
            write(baseSnap, name: "Base")
            write(satSnap, name: "Sat")
            write(satScratchSnap, name: "SatScratch")
            write(shootSnap, name: "Shoot")
            write(shootScratchSnap, name: "ShootScratch")
            os_log("DumpLayers: completed -> %{public}@", log: self.log, type: .info, dir.path)
        }
    }
    
    // MARK: - Notification value parsing
    
    private func value<T>(_ key: String, from userInfo: [AnyHashable: Any]?) -> T? {
        guard let ui = userInfo, let raw = ui[key] else { return nil }
        if let v = raw as? T { return v }
        if T.self == Bool.self {
            if let n = raw as? NSNumber { return (n.boolValue as! T) }
            if let s = raw as? String {
                let lowered = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let truthy: Set<String> = ["1","true","yes","on","y"]
                let falsy: Set<String> = ["0","false","no","off","n"]
                if truthy.contains(lowered) { return (true as! T) }
                if falsy.contains(lowered) { return (false as! T) }
            }
        } else if T.self == Int.self {
            if let n = raw as? NSNumber { return (n.intValue as! T) }
            if let s = raw as? String, let iv = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return (iv as! T)
            }
        } else if T.self == Double.self {
            if let n = raw as? NSNumber { return (n.doubleValue as! T) }
            if let s = raw as? String, let dv = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return (dv as! T)
            }
        }
        return nil
    }
    
    // MARK: - Diagnostics logger
    
    private func logFrameDiagnostics(prefix: String, drawData: StarryDrawData, dt: CFTimeInterval?) {
        guard diagnosticsEnabled && frameIndex % UInt64(diagnosticsEveryNFrames) == 0 else { return }
        let satCount = drawData.satellitesSprites.count
        let shootCount = drawData.shootingSprites.count
        let dtSec = (dt ?? 0)
        let keepSat = decayKeep(forHalfLife: satellitesHalfLifeSeconds, dt: dt)
        let keepShoot = decayKeep(forHalfLife: shootingHalfLifeSeconds, dt: dt)
        var alphaSamples: [Float] = []
        for i in 0..<min(3, satCount) {
            alphaSamples.append(drawData.satellitesSprites[i].colorPremul.w)
        }
        os_log("%{public}@Frame #%{public}llu dt=%{public}.4f s | satSprites=%{public}d alphaSamples=%{public}@ shootSprites=%{public}d keep(sat)=%{public}.4f keep(shoot)=%{public}.4f",
               log: log, type: .debug,
               prefix, frameIndex, dtSec, satCount, alphaSamples.description, shootCount, keepSat, keepShoot)
    }
}
