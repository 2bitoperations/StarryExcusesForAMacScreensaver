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
//       "verifyBaseImmutability": Bool         -> debugVerifyBaseImmutability
//       "verifyBaseIsolation": Bool            -> debugVerifyBaseIsolation (incremental checks after each non-base step; base NOT suppressed)
//       "overlayEnabled": Bool                 -> debugOverlayEnabled
//       "satellitesHalfLifeSeconds": Double    -> satellitesHalfLifeSeconds
//       "shootingHalfLifeSeconds": Double      -> shootingHalfLifeSeconds
//       "dropBaseEveryN": Int                  -> clears BaseLayer every N frames (0 disables)
//       "gpuCaptureStart": Bool                -> begin programmatic GPU capture on next frame
//       "gpuCaptureFrames": Int               -> number of frames to capture (default 1)
//       "gpuCapturePath": String              -> output .gputrace path (optional; defaults to Desktop or temp)
//       "gpuCaptureStop": Bool                -> stop capture immediately (if active)
//       "dumpLayersNextFrame": Bool           -> one-time dump of Base/Sat/SatScratch/Shoot/ShootScratch as PNGs to Desktop
//
//     Notes for keys intended for StarryEngine (not handled here):
//       "starsPerUpdate": Int                  -> requires StarryEngine (not set here)
//       "buildingLightsPerUpdate": Int         -> requires StarryEngine (not set here)
//
// - "StarryClear"
//     userInfo:
//       "target": String                       -> one of "all", "base", "satellites", "shooting"
//     If missing or invalid, "all" is assumed.
//
// Convenience posting example (Swift):
// DistributedNotificationCenter.default().post(
//     name: Notification.Name("StarryDiagnostics"),
//     object: nil,
//     userInfo: ["enabled": true, "everyNFrames": 120, "dropBaseEveryN": 300]
// )

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
    private var decaySampledPipeline: MTLRenderPipelineState!
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
    
    private var debugVerifyBaseImmutability: Bool = false
    private var baseSnapshotBefore: MTLTexture?
    private var baseSnapshotAfter: MTLTexture?
    
    private var debugVerifyBaseIsolation: Bool = false
    private var baseIsoPerPassSnapshots: [(tag: String, snap: MTLTexture)] = []
    
    private var gpuCapturePendingStart: Bool = false
    private var gpuCaptureActive: Bool = false
    private var gpuCaptureFramesRemaining: Int = 0
    private var gpuCaptureOutputURL: URL?
    
    private var dumpLayersNextFrame: Bool = false
    
    private var isolationDumpDir: URL?
    
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
        if let v: Bool = value("verifyBaseImmutability", from: ui) {
            debugVerifyBaseImmutability = v
            applied.append("verifyBaseImmutability=\(v)")
        }
        if let v: Bool = value("verifyBaseIsolation", from: ui) {
            debugVerifyBaseIsolation = v
            applied.append("verifyBaseIsolation=\(v)")
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
        if let start: Bool = value("gpuCaptureStart", from: ui), start {
            let frames: Int = max(1, (value("gpuCaptureFrames", from: ui) as Int?) ?? 1)
            let path: String? = value("gpuCapturePath", from: ui)
            if let path = path, !path.isEmpty {
                gpuCaptureOutputURL = URL(fileURLWithPath: path)
            } else {
                gpuCaptureOutputURL = nil
            }
            if MTLCaptureManager.shared().isCapturing {
                MTLCaptureManager.shared().stopCapture()
                gpuCaptureActive = false
            }
            gpuCaptureFramesRemaining = frames
            gpuCapturePendingStart = true
            applied.append("gpuCaptureStart(frames=\(frames), path=\(gpuCaptureOutputURL?.path ?? "auto"))")
        }
        if let stop: Bool = value("gpuCaptureStop", from: ui), stop {
            if MTLCaptureManager.shared().isCapturing {
                MTLCaptureManager.shared().stopCapture()
            }
            gpuCaptureActive = false
            gpuCapturePendingStart = false
            gpuCaptureFramesRemaining = 0
            applied.append("gpuCaptureStop")
        }
        if let dump: Bool = value("dumpLayersNextFrame", from: ui), dump {
            dumpLayersNextFrame = true
            applied.append("dumpLayersNextFrame")
        }
        
        var ignored: [String] = []
        if ui?["starsPerUpdate"] != nil { ignored.append("starsPerUpdate") }
        if ui?["buildingLightsPerUpdate"] != nil { ignored.append("buildingLightsPerUpdate") }
        if !ignored.isEmpty {
            os_log("Diagnostics notification contained engine keys not handled by MetalRenderer: %{public}@",
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
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "DecaySampled"
            desc.vertexFunction = library.makeFunction(name: "TexturedQuadVertex")
            desc.fragmentFunction = library.makeFunction(name: "DecaySampledFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = false
            decaySampledPipeline = try device.makeRenderPipelineState(descriptor: desc)
        }
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
    
    func setDebugVerifyBaseImmutability(_ enabled: Bool) {
        debugVerifyBaseImmutability = enabled
        os_log("Debug: verify BaseLayer immutability is %{public}@", log: log, type: .info, enabled ? "ENABLED" : "disabled")
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
        startGpuCaptureIfArmed()
        
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
        
        let baselineForIsolation = encodeScenePasses(commandBuffer: commandBuffer,
                                                     drawData: drawData,
                                                     dt: dt,
                                                     enableImmutabilityVerification: true,
                                                     enableIsolationVerification: true,
                                                     headless: false)
        
        guard let drawable = metalLayer?.nextDrawable() else {
            os_log("No CAMetalLayer drawable available this frame", log: log, type: .error)
            commandBuffer.commit()
            noteFrameCommittedForGpuCapture()
            frameIndex &+= 1
            return
        }
        
        encodeCompositeAndMoon(commandBuffer: commandBuffer,
                               target: drawable.texture,
                               drawData: drawData,
                               headless: false,
                               baseIsolationBaseline: baselineForIsolation)
        
        if debugVerifyBaseIsolation {
            enqueuePerFrameIsolationDumps(commandBuffer: commandBuffer,
                                          finalTarget: drawable.texture,
                                          headless: false)
        }
        
        if dumpLayersNextFrame {
            enqueueLayerDumps(commandBuffer: commandBuffer)
            dumpLayersNextFrame = false
        }
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
        noteFrameCommittedForGpuCapture()
        frameIndex &+= 1
    }
    
    func renderToImage(drawData: StarryDrawData) -> CGImage? {
        startGpuCaptureIfArmed()
        
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
        
        _ = encodeScenePasses(commandBuffer: commandBuffer,
                              drawData: drawData,
                              dt: dt,
                              enableImmutabilityVerification: false,
                              enableIsolationVerification: false,
                              headless: true)
        
        encodeCompositeAndMoon(commandBuffer: commandBuffer,
                               target: finalTarget,
                               drawData: drawData,
                               headless: true,
                               baseIsolationBaseline: nil)
        
        if debugVerifyBaseIsolation {
            enqueuePerFrameIsolationDumps(commandBuffer: commandBuffer,
                                          finalTarget: finalTarget,
                                          headless: true)
        }
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        noteFrameCommittedForGpuCapture()
        
        return textureToImage(finalTarget)
    }
    
    // MARK: - Shared encoders
    
    private func encodeScenePasses(commandBuffer: MTLCommandBuffer,
                                   drawData: StarryDrawData,
                                   dt: CFTimeInterval?,
                                   enableImmutabilityVerification: Bool,
                                   enableIsolationVerification: Bool,
                                   headless: Bool) -> MTLTexture? {
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
        
        baseIsoPerPassSnapshots.removeAll(keepingCapacity: true)
        
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
        
        let shouldVerifyBase = enableImmutabilityVerification &&
            debugVerifyBaseImmutability &&
            drawData.baseSprites.isEmpty &&
            (layerTex.base != nil)
        
        if shouldVerifyBase, let baseTex = layerTex.base {
            baseSnapshotBefore = makeSnapshotTextureLike(baseTex)
            if let snap = baseSnapshotBefore {
                blitCopy(from: baseTex, to: snap, using: commandBuffer,
                         label: "Snapshot Base BEFORE (immutability)")
            }
        }
        
        var baseIsolationBaseline: MTLTexture?
        if enableIsolationVerification,
           debugVerifyBaseIsolation,
           let baseTex = layerTex.base,
           let baseline = makeSnapshotTextureLike(baseTex) {
            blitCopy(from: baseTex, to: baseline, using: commandBuffer, label: "Isolation Baseline AFTER BASE-PASS")
            baseIsolationBaseline = baseline
            baseIsoPerPassSnapshots.append(("baseline", baseline))
        }
        
        func checkpointIsolation(_ tag: String) {
            guard let baseline = baseIsolationBaseline,
                  enableIsolationVerification,
                  debugVerifyBaseIsolation,
                  let baseTex = layerTex.base,
                  let snap = makeSnapshotTextureLike(baseTex) else { return }
            blitCopy(from: baseTex, to: snap, using: commandBuffer, label: "Isolation snapshot \(tag)")
            baseIsoPerPassSnapshots.append((tag, snap))
            commandBuffer.addCompletedHandler { [weak self] _ in
                guard let self = self else { return }
                let sumBaseline = self.computeChecksum(of: baseline)
                let sumStep = self.computeChecksum(of: snap)
                if sumBaseline != sumStep {
                    os_log("ALERT: BaseLayer changed after step '%{public}@' (baseline=%{public}@, current=%{public}@)",
                           log: self.log, type: .fault,
                           tag,
                           String(format: "0x%016llx", sumBaseline),
                           String(format: "0x%016llx", sumStep))
                } else {
                    os_log("VerifyBaseIsolation: no change after '%{public}@' (checksum=%{public}@)",
                           log: self.log, type: .debug,
                           tag,
                           String(format: "0x%016llx", sumBaseline))
                }
            }
        }
        
        if debugCompositeMode == .baseOnly {
            os_log(headless ? "[Headless] BASE-ONLY: skipping satellites/shooting" :
                              "BASE-ONLY: skipping satellites/shooting",
                   log: log, type: .debug)
        } else {
            if layerTex.satellites != nil {
                applyDecay(into: .satellites, dt: dt, commandBuffer: commandBuffer)
                checkpointIsolation("after-sat-decay")
                if !debugSkipSatellitesDraw && !drawData.satellitesSprites.isEmpty {
                    if let safeDst = safeLayerTarget(.satellites) {
                        renderSprites(into: safeDst,
                                      sprites: drawData.satellitesSprites,
                                      pipeline: spriteAdditivePipeline,
                                      commandBuffer: commandBuffer,
                                      provenance: .satellites)
                        checkpointIsolation("after-sat-draw")
                    } else {
                        os_log("ALERT: No safe satellites target — skipping draw", log: log, type: .fault)
                        checkpointIsolation("after-sat-no-target")
                    }
                } else {
                    checkpointIsolation("after-sat-noop")
                }
            }
            
            if layerTex.shooting != nil {
                applyDecay(into: .shooting, dt: dt, commandBuffer: commandBuffer)
                checkpointIsolation("after-shoot-decay")
                if !drawData.shootingSprites.isEmpty {
                    if let safeDst = safeLayerTarget(.shooting) {
                        renderSprites(into: safeDst,
                                      sprites: drawData.shootingSprites,
                                      pipeline: spriteAdditivePipeline,
                                      commandBuffer: commandBuffer,
                                      provenance: .shooting)
                        checkpointIsolation("after-shoot-draw")
                    } else {
                        os_log("ALERT: No safe shooting target — skipping draw", log: log, type: .fault)
                        checkpointIsolation("after-shoot-no-target")
                    }
                } else {
                    checkpointIsolation("after-shoot-noop")
                }
            }
        }
        
        if shouldVerifyBase, let baseTex = layerTex.base {
            baseSnapshotAfter = makeSnapshotTextureLike(baseTex)
            if let snap = baseSnapshotAfter {
                blitCopy(from: baseTex, to: snap, using: commandBuffer,
                         label: "Snapshot Base AFTER (immutability)")
            }
            let before = baseSnapshotBefore
            let after = baseSnapshotAfter
            commandBuffer.addCompletedHandler { [weak self] _ in
                guard let self = self, let b = before, let a = after else { return }
                let sumB = self.computeChecksum(of: b)
                let sumA = self.computeChecksum(of: a)
                if sumB != sumA {
                    os_log("ALERT: BaseLayer changed in frame with ZERO baseSprites (before=%{public}@ after=%{public}@)",
                           log: self.log, type: .fault,
                           String(format: "0x%016llx", sumB),
                           String(format: "0x%016llx", sumA))
                } else {
                    os_log("VerifyBase: no change (checksum=%{public}@) with zero baseSprites",
                           log: self.log, type: .debug,
                           String(format: "0x%016llx", sumB))
                }
            }
        }
        
        return baseIsolationBaseline
    }
    
    private func encodeCompositeAndMoon(commandBuffer: MTLCommandBuffer,
                                        target: MTLTexture,
                                        drawData: StarryDrawData,
                                        headless: Bool,
                                        baseIsolationBaseline: MTLTexture?) {
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
        
        if let baseline = baseIsolationBaseline,
           debugVerifyBaseIsolation,
           let baseTex = layerTex.base,
           let snap = makeSnapshotTextureLike(baseTex) {
            blitCopy(from: baseTex, to: snap, using: commandBuffer,
                     label: "Isolation snapshot after-composite+moon")
            baseIsoPerPassSnapshots.append(("after-composite+moon", snap))
            commandBuffer.addCompletedHandler { [weak self] _ in
                guard let self = self else { return }
                let sumBaseline = self.computeChecksum(of: baseline)
                let sumStep = self.computeChecksum(of: snap)
                if sumBaseline != sumStep {
                    os_log("ALERT: BaseLayer changed after step '%{public}@' (baseline=%{public}@, current=%{public}@)",
                           log: self.log, type: .fault,
                           "after-composite+moon",
                           String(format: "0x%016llx", sumBaseline),
                           String(format: "0x%016llx", sumStep))
                } else {
                    os_log("VerifyBaseIsolation: no change after '%{public}@' (checksum=%{public}@)",
                           log: self.log, type: .debug,
                           "after-composite+moon",
                           String(format: "0x%016llx", sumBaseline))
                }
                if self.baseIsoPerPassSnapshots.count >= 2 {
                    var prevSum: UInt64?
                    var prevTag: String = ""
                    for (tag, tex) in self.baseIsoPerPassSnapshots {
                        let sum = self.computeChecksum(of: tex)
                        os_log("IsolationTrace: Base checksum after '%{public}@' = %{public}@",
                               log: self.log, type: .debug,
                               tag, String(format: "0x%016llx", sum))
                        if let p = prevSum, p != sum {
                            os_log("ALERT: Base changed between '%{public}@' and '%{public}@'",
                                   log: self.log, type: .fault, prevTag, tag)
                        }
                        prevSum = sum
                        prevTag = tag
                    }
                }
            }
        }
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
        
        if diagnosticsEnabled && !debugVerifyBaseIsolation && frameIndex % UInt64(diagnosticsEveryNFrames) == 0 {
            os_log("Decay pass %{public}@ keep=%{public}.4f (halfLife=%{public}.3f dt=%{public}.4f)",
                   log: log, type: .debug,
                   (which == .satellites ? "satellites" : "shooting"),
                   keep, halfLife, (dt ?? 0))
        }
        
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
                                     width: Double(t.width),
                                     height: Double(t.height),
                                     znear: 0, zfar: 1)
                enc.setViewport(vp)
                enc.popDebugGroup()
                enc.endEncoding()
            }
            return
        }
        
        let src: MTLTexture?
        let scratch: MTLTexture?
        switch which {
        case .satellites:
            src = layerTex.satellites
            scratch = layerTex.satellitesScratch
        case .shooting:
            src = layerTex.shooting
            scratch = layerTex.shootingScratch
        }
        guard let srcTex = src, let dstScratch = scratch else {
            os_log("applyDecay: missing textures for %{public}@ layer (src=%{public}@ scratch=%{public}@)",
                   log: log, type: .error,
                   (which == .satellites ? "satellites" : "shooting"),
                   String(describing: src),
                   String(describing: scratch))
            return
        }
        
        if labelContains(dstScratch, "BaseLayer") ||
            isSameTexture(dstScratch, layerTex.base) ||
            isSameTexture(dstScratch, layerTex.baseScratch) {
            os_log("ALERT: Decay scratch is BaseLayer for %{public}@ — skipping",
                   log: log, type: .fault, which == .satellites ? "satellites" : "shooting")
            return
        }
        if labelContains(srcTex, "BaseLayer") ||
            isSameTexture(srcTex, layerTex.base) ||
            isSameTexture(srcTex, layerTex.baseScratch) {
            os_log("ALERT: Decay src is BaseLayer for %{public}@ — skipping",
                   log: log, type: .fault, which == .satellites ? "satellites" : "shooting")
            return
        }
        
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dstScratch
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        encoder.pushDebugGroup("DecaySampled -> \(dstScratch.label ?? "scratch") keep=\(keep)")
        let vp = MTLViewport(originX: 0, originY: 0,
                             width: Double(dstScratch.width),
                             height: Double(dstScratch.height),
                             znear: 0, zfar: 1)
        encoder.setViewport(vp)
        encoder.setRenderPipelineState(decaySampledPipeline)
        if let quad = quadVertexBuffer {
            encoder.setVertexBuffer(quad, offset: 0, index: 0)
        }
        encoder.setFragmentTexture(srcTex, index: 0)
        var keepColor = SIMD4<Float>(repeating: keep)
        encoder.setFragmentBytes(&keepColor,
                                 length: MemoryLayout<SIMD4<Float>>.stride,
                                 index: FragmentBufferIndex.quadUniforms)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.popDebugGroup()
        encoder.endEncoding()
        
        if diagnosticsEnabled && !debugVerifyBaseIsolation {
            os_log("DecaySampled: %{public}@ src=%{public}@ -> dst=%{public}@",
                   log: log, type: .debug,
                   which == .satellites ? "SATELLITES" : "SHOOTING",
                   srcTex.label ?? "tex",
                   dstScratch.label ?? "tex")
        }
        
        swapTrailTextures(which)
    }
    
    private func swapTrailTextures(_ which: TrailLayer) {
        switch which {
        case .satellites:
            let a = layerTex.satellites
            layerTex.satellites = layerTex.satellitesScratch
            layerTex.satellitesScratch = a
        case .shooting:
            let a = layerTex.shooting
            layerTex.shooting = layerTex.shootingScratch
            layerTex.shootingScratch = a
        }
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
    
    // MARK: - Debug helpers
    
    private func provenanceString(_ p: LayerProvenance) -> String {
        switch p {
        case .base: return "base"
        case .satellites: return "satellites"
        case .shooting: return "shooting"
        case .other: return "other"
        }
    }
    
    private func makeSnapshotTextureLike(_ src: MTLTexture) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: src.pixelFormat,
                                                            width: src.width,
                                                            height: src.height,
                                                            mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)
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
    
    private func computeChecksum(of tex: MTLTexture) -> UInt64 {
        let w = tex.width
        let h = tex.height
        let bpp = 4
        let rowBytes = w * bpp
        var bytes = [UInt8](repeating: 0, count: rowBytes * h)
        let region = MTLRegionMake2D(0, 0, w, h)
        tex.getBytes(&bytes, bytesPerRow: rowBytes, from: region, mipmapLevel: 0)
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for b in bytes {
            hash ^= UInt64(b)
            hash &*= prime
        }
        return hash
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
            let snap = makeSnapshotTextureLike(t)
            if let snap = snap {
                blitCopy(from: t, to: snap, using: commandBuffer, label: "Dump snapshot \(t.label ?? "tex")")
            }
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
    
    // MARK: - Per-frame isolation dump
    
    private func ensureIsolationDumpDirectory() -> URL {
        if let dir = isolationDumpDir {
            return dir
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent("StarryIsolation-\(stamp)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            isolationDumpDir = base
            os_log("IsolationDump: created %{public}@", log: log, type: .info, base.path)
        } catch {
            os_log("IsolationDump: failed to create dir %{public}@ (%{public}@). Falling back to temp",
                   log: log, type: .error, base.path, "\(error)")
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("StarryIsolation-\(stamp)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                isolationDumpDir = tmp
                os_log("IsolationDump: created temp %{public}@", log: log, type: .info, tmp.path)
            } catch {
                isolationDumpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                os_log("IsolationDump: using temp root %{public}@", log: log, type: .error, isolationDumpDir!.path)
            }
        }
        return isolationDumpDir!
    }
    
    private func enqueuePerFrameIsolationDumps(commandBuffer: MTLCommandBuffer, finalTarget: MTLTexture?, headless: Bool) {
        let dir = ensureIsolationDumpDirectory()
        func snapshot(_ t: MTLTexture?) -> MTLTexture? {
            guard let t = t else { return nil }
            let snap = makeSnapshotTextureLike(t)
            if let snap = snap {
                blitCopy(from: t, to: snap, using: commandBuffer, label: "Isolation snapshot \(t.label ?? "tex")")
            }
            return snap
        }
        let baseSnap = snapshot(layerTex.base)
        let baseScratchSnap = snapshot(layerTex.baseScratch)
        let satSnap = snapshot(layerTex.satellites)
        let satScratchSnap = snapshot(layerTex.satellitesScratch)
        let compositeSnap = snapshot(finalTarget)
        let frame = frameIndex
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self = self else { return }
            func write(_ tex: MTLTexture?, name: String) {
                guard let tex = tex, let img = self.textureToImage(tex) else { return }
                let url = dir.appendingPathComponent(String(format: "f%06llu-%@.png", frame, name), isDirectory: false)
                self.savePNG(img, to: url)
            }
            write(baseSnap, name: "base")
            write(baseScratchSnap, name: "baseScratch")
            write(satSnap, name: "satellites")
            write(satScratchSnap, name: "satellitesScratch")
            write(compositeSnap, name: headless ? "composite-headless" : "composite-onscreen")
            os_log("IsolationDump: wrote PNGs for frame #%{public}llu to %{public}@",
                   log: self.log, type: .info, frame, dir.path)
        }
    }
    
    // MARK: - GPU capture
    
    private func startGpuCaptureIfArmed() {
        guard gpuCapturePendingStart, !gpuCaptureActive else { return }
        let manager = MTLCaptureManager.shared()
        if manager.isCapturing {
            os_log("GPU Capture: already capturing; stopping existing capture before restarting", log: log, type: .error)
            manager.stopCapture()
        }
        
        let desc = MTLCaptureDescriptor()
        desc.captureObject = commandQueue
        desc.destination = .gpuTraceDocument
        let url = gpuCaptureOutputURL ?? defaultGpuTraceURL()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        } catch {
            os_log("GPU Capture: failed to create directory for %{public}@ (%{public}@). Falling back to temp",
                   log: log, type: .error, url.path, "\(error)")
        }
        desc.outputURL = url
        
        do {
            try manager.startCapture(with: desc)
            gpuCaptureActive = true
            gpuCapturePendingStart = false
            os_log("GPU Capture: STARTED -> %{public}@ (frames=%{public}d)",
                   log: log, type: .info, (desc.outputURL?.path ?? "unknown"), gpuCaptureFramesRemaining)
        } catch {
            os_log("GPU Capture: FAILED to start (%{public}@)", log: log, type: .error, "\(error)")
            gpuCaptureActive = false
            gpuCapturePendingStart = false
            gpuCaptureFramesRemaining = 0
        }
    }
    
    private func defaultGpuTraceURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let desktopURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        let desktopCandidate = desktopURL.appendingPathComponent("StarryCapture-\(stamp).gputrace", isDirectory: true)
        return desktopCandidate.standardizedFileURL.resolvingSymlinksInPath().absoluteURL
    }
    
    private func noteFrameCommittedForGpuCapture() {
        guard gpuCaptureActive else { return }
        if gpuCaptureFramesRemaining > 0 {
            gpuCaptureFramesRemaining -= 1
        }
        if gpuCaptureFramesRemaining <= 0 {
            MTLCaptureManager.shared().stopCapture()
            os_log("GPU Capture: STOPPED", log: log, type: .info)
            gpuCaptureActive = false
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
